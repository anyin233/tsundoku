package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"io"
	"net"
	"testing"
	"time"
)

func TestBuildDHCPReplyOfferAndAck(t *testing.T) {
	buildReq := func(msgType byte) []byte {
		req := make([]byte, 300)
		req[0] = 1
		req[1] = 1
		req[2] = 6
		copy(req[4:8], []byte{0x12, 0x34, 0x56, 0x78})
		copy(req[28:34], []byte{0x02, 0x19, 0x49, 0x6b, 0x68, 0x01})
		copy(req[236:240], dhcpMagicCookie)
		req[240] = 53
		req[241] = 1
		req[242] = msgType
		req[243] = 255
		return req
	}

	for _, tc := range []struct {
		reqType  byte
		wantType byte
	}{
		{1, 2}, // DISCOVER -> OFFER
		{3, 5}, // REQUEST -> ACK
	} {
		resp, rtype, ok := buildDHCPReply(buildReq(tc.reqType))
		if !ok || rtype != tc.wantType {
			t.Fatalf("req=%d: got ok=%v type=%d, want %d", tc.reqType, ok, rtype, tc.wantType)
		}
		if resp[0] != 2 || !bytes.Equal(resp[16:20], dhcpClientIP) || !bytes.Equal(resp[20:24], dhcpServerIP) {
			t.Fatalf("unexpected DHCP addresses in reply")
		}
		// Ensure Option 3 (Router) and Option 6 (DNS) are omitted.
		i := 240
		for i < len(resp) && resp[i] != 255 {
			opt := resp[i]
			if opt == 3 || opt == 6 {
				t.Fatalf("unexpected option %d in DHCP reply", opt)
			}
			olen := int(resp[i+1])
			i += 2 + olen
		}
	}
}

func TestEncodeFrameBoundaryPadding(t *testing.T) {
	for _, plen := range []int{0, 52, 500, 501, 1012, 8192} {
		payload := bytes.Repeat([]byte{0xAB}, plen)
		wire, err := encodeFrame(cmdData, 42, payload)
		if err != nil {
			t.Fatalf("encodeFrame(%d) err: %v", plen, err)
		}
		if len(wire)%64 == 0 {
			t.Fatalf("plen=%d produced wireLen=%d divisible by 64 (would require USB ZLP)", plen, len(wire))
		}
		f, err := readFrame(bufio.NewReader(bytes.NewReader(wire)))
		if err != nil {
			t.Fatalf("readFrame(%d) err: %v", plen, err)
		}
		if f.cmd != cmdData || f.streamID != 42 || !bytes.Equal(f.payload, payload) {
			t.Fatalf("round-trip mismatch for plen=%d", plen)
		}
	}
}

func TestFFSDescriptorsAndStringsLayout(t *testing.T) {
	desc := buildFFSDescriptors()
	if len(desc) != 66 {
		t.Fatalf("descriptor length=%d, want 66", len(desc))
	}
	if binary.LittleEndian.Uint32(desc[0:4]) != ffsDescMagicV2 {
		t.Fatalf("bad descriptors magic")
	}
	if binary.LittleEndian.Uint32(desc[4:8]) != 66 {
		t.Fatalf("bad descriptors length field")
	}
	strs := buildFFSStrings()
	if binary.LittleEndian.Uint32(strs[0:4]) != ffsStringsMagic {
		t.Fatalf("bad strings magic")
	}
	if int(binary.LittleEndian.Uint32(strs[4:8])) != len(strs) {
		t.Fatalf("bad strings length field")
	}
}

func TestStreamMuxLoopback(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()

	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				_, _ = io.Copy(conn, conn)
			}(c)
		}
	}()

	hostToDevR, hostToDevW := io.Pipe()
	devToHostR, devToHostW := io.Pipe()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	mux := newStreamMux(ln.Addr().String(), func(string, ...any) {})
	go func() {
		_ = mux.run(ctx, hostToDevR, devToHostW)
	}()

	writeHost := func(cmd byte, sid uint32, p []byte) {
		pkt, err := encodeFrame(cmd, sid, p)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := hostToDevW.Write(pkt); err != nil {
			t.Fatal(err)
		}
	}

	br := bufio.NewReader(devToHostR)
	writeHost(cmdPing, 7, []byte("hi"))
	f, err := readFrame(br)
	if err != nil || f.cmd != cmdPong || f.streamID != 7 || string(f.payload) != "hi" {
		t.Fatalf("ping/pong failed: err=%v frame=%+v", err, f)
	}

	// Test boundary payload size 500 (12+500=512 -> padded to 513).
	msg := bytes.Repeat([]byte("Z"), 500)
	writeHost(cmdOpen, 99, nil)
	time.Sleep(30 * time.Millisecond)
	writeHost(cmdData, 99, msg)
	got := make([]byte, 0, len(msg))
	for len(got) < len(msg) {
		f, err := readFrame(br)
		if err != nil {
			t.Fatalf("readFrame echo: %v", err)
		}
		if f.cmd == cmdData && f.streamID == 99 {
			got = append(got, f.payload...)
		}
	}
	if !bytes.Equal(got, msg) {
		t.Fatalf("echo payload mismatch: len=%d", len(got))
	}
	writeHost(cmdClose, 99, nil)
}
