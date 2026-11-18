package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"net"
	"syscall"
	"time"
)

var dhcpMagicCookie = []byte{99, 130, 83, 99}

var (
	dhcpServerIP    = net.IPv4(192, 168, 15, 1).To4()
	dhcpClientIP    = net.IPv4(192, 168, 15, 10).To4()
	dhcpSubnetBcast = net.IPv4(192, 168, 15, 255).To4()
	dhcpNetmask     = net.IPv4(255, 255, 255, 0).To4()
)

func parseDHCPMessageType(pkt []byte) (byte, bool) {
	if len(pkt) < 240 {
		return 0, false
	}
	if pkt[0] != 1 { // BOOTREQUEST
		return 0, false
	}
	if !bytes.Equal(pkt[236:240], dhcpMagicCookie) {
		return 0, false
	}
	i := 240
	for i < len(pkt) {
		opt := pkt[i]
		if opt == 255 {
			break
		}
		if opt == 0 {
			i++
			continue
		}
		if i+1 >= len(pkt) {
			break
		}
		olen := int(pkt[i+1])
		if i+2+olen > len(pkt) {
			break
		}
		if opt == 53 && olen >= 1 {
			return pkt[i+2], true
		}
		i += 2 + olen
	}
	return 0, false
}

// buildDHCPReply builds a minimal DHCPOFFER or DHCPACK packet without router or DNS options
// so macOS keeps its existing default routes and DNS untouched.
func buildDHCPReply(req []byte) ([]byte, byte, bool) {
	msgType, ok := parseDHCPMessageType(req)
	if !ok {
		return nil, 0, false
	}
	var replyType byte
	switch msgType {
	case 1: // DHCPDISCOVER -> DHCPOFFER
		replyType = 2
	case 3: // DHCPREQUEST -> DHCPACK
		replyType = 5
	default:
		return nil, 0, false
	}

	resp := make([]byte, 300)
	resp[0] = 2      // BOOTREPLY
	resp[1] = req[1] // htype
	resp[2] = req[2] // hlen
	resp[3] = 0      // hops
	copy(resp[4:8], req[4:8])
	copy(resp[10:12], req[10:12]) // flags
	copy(resp[16:20], dhcpClientIP)
	copy(resp[20:24], dhcpServerIP)
	hlen := int(req[2])
	if hlen > 16 {
		hlen = 16
	}
	copy(resp[28:28+hlen], req[28:28+hlen])
	copy(resp[236:240], dhcpMagicCookie)

	pos := 240
	writeOpt := func(code byte, data []byte) {
		resp[pos] = code
		resp[pos+1] = byte(len(data))
		copy(resp[pos+2:pos+2+len(data)], data)
		pos += 2 + len(data)
	}

	writeOpt(53, []byte{replyType})
	writeOpt(54, dhcpServerIP)
	var lease [4]byte
	binary.BigEndian.PutUint32(lease[:], 3600)
	writeOpt(51, lease[:])
	writeOpt(1, dhcpNetmask)
	resp[pos] = 255
	pos++

	if pos < 300 {
		pos = 300
	}
	return resp[:pos], replyType, true
}

func startDHCPServer(ctx context.Context, ifname string, logf func(string, ...any)) {
	lc := net.ListenConfig{
		Control: func(network, address string, c syscall.RawConn) error {
			var sockErr error
			if err := c.Control(func(fd uintptr) {
				sockErr = bindSocketToDevice(fd, ifname)
			}); err != nil {
				return err
			}
			return sockErr
		},
	}

	pc, err := lc.ListenPacket(ctx, "udp4", "0.0.0.0:67")
	if err != nil {
		logf("dhcp listen on %s:67 failed: %v", ifname, err)
		return
	}
	logf("dhcp server listening on %s:67 (offering %s -> gw %s)", ifname, dhcpClientIP, dhcpServerIP)

	go func() {
		<-ctx.Done()
		_ = pc.Close()
	}()

	go func() {
		buf := make([]byte, 1500)
		bcastAddr := &net.UDPAddr{IP: net.IPv4bcast, Port: 68}
		subnetBcastAddr := &net.UDPAddr{IP: dhcpSubnetBcast, Port: 68}
		for {
			n, _, err := pc.ReadFrom(buf)
			if err != nil {
				if ctx.Err() != nil {
					return
				}
				time.Sleep(100 * time.Millisecond)
				continue
			}
			reply, rtype, ok := buildDHCPReply(buf[:n])
			if !ok {
				continue
			}
			ensureNetIfConfigured(ifname, logf)
			if _, err := pc.WriteTo(reply, bcastAddr); err != nil {
				// Airplane mode (no default route) can return ENETUNREACH for 255.255.255.255;
				// fall back to the directed subnet broadcast on ifname.
				if _, err2 := pc.WriteTo(reply, subnetBcastAddr); err2 != nil {
					if ctx.Err() == nil {
						logf("dhcp write error: %v (subnet fallback: %v)", err, err2)
					}
				} else {
					logf("dhcp sent type=%d to %s", rtype, subnetBcastAddr)
				}
			} else {
				logf("dhcp sent type=%d to %s", rtype, bcastAddr)
			}
		}
	}()
}
