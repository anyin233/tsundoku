package main

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	ffsMountPoint = "/dev/usb-ffs/usbdbg"

	ffsDescMagicV2 = 3
	ffsStringsMagic = 2
	ffsHasFS       = 1
	ffsHasHS       = 2

	kdbgHeaderLen   = 12
	maxFramePayload = 8192

	cmdOpen  byte = 1
	cmdData  byte = 2
	cmdClose byte = 3
	cmdPing  byte = 4
	cmdPong  byte = 5

	frameFlagPad byte = 1
)

var kdbgMagic = [4]byte{'K', 'D', 'B', 'G'}

// buildFFSDescriptors returns the 66-byte FunctionFS v2 descriptors blob (FS + HS).
func buildFFSDescriptors() []byte {
	fsDescs := []byte{
		// Interface descriptor (9 bytes)
		9, 4, 0, 0, 2, 0xFF, 0x42, 0x03, 1,
		// EP1 IN bulk descriptor (7 bytes, wMaxPacketSize = 64)
		7, 5, 0x81, 2, 64, 0, 0,
		// EP2 OUT bulk descriptor (7 bytes, wMaxPacketSize = 64)
		7, 5, 0x02, 2, 64, 0, 0,
	}
	hsDescs := []byte{
		// Interface descriptor (9 bytes)
		9, 4, 0, 0, 2, 0xFF, 0x42, 0x03, 1,
		// EP1 IN bulk descriptor (7 bytes, wMaxPacketSize = 512)
		7, 5, 0x81, 2, 0x00, 0x02, 0,
		// EP2 OUT bulk descriptor (7 bytes, wMaxPacketSize = 512)
		7, 5, 0x02, 2, 0x00, 0x02, 0,
	}

	totalLen := 12 + 8 + len(fsDescs) + len(hsDescs)
	buf := make([]byte, totalLen)
	binary.LittleEndian.PutUint32(buf[0:4], ffsDescMagicV2)
	binary.LittleEndian.PutUint32(buf[4:8], uint32(totalLen))
	binary.LittleEndian.PutUint32(buf[8:12], ffsHasFS|ffsHasHS)
	binary.LittleEndian.PutUint32(buf[12:16], 3) // fs_count
	binary.LittleEndian.PutUint32(buf[16:20], 3) // hs_count
	copy(buf[20:], fsDescs)
	copy(buf[20+len(fsDescs):], hsDescs)
	return buf
}

func buildFFSStrings() []byte {
	s := "KOReader USB Debug\x00"
	totalLen := 16 + 2 + len(s)
	buf := make([]byte, totalLen)
	binary.LittleEndian.PutUint32(buf[0:4], ffsStringsMagic)
	binary.LittleEndian.PutUint32(buf[4:8], uint32(totalLen))
	binary.LittleEndian.PutUint32(buf[8:12], 1)  // str_count
	binary.LittleEndian.PutUint32(buf[12:16], 1) // lang_count
	binary.LittleEndian.PutUint16(buf[16:18], 0x0409)
	copy(buf[18:], s)
	return buf
}

type kdbgFrame struct {
	cmd      byte
	streamID uint32
	payload  []byte
}

func encodeFrame(cmd byte, streamID uint32, payload []byte) ([]byte, error) {
	if len(payload) > maxFramePayload {
		return nil, fmt.Errorf("payload too large: %d > %d", len(payload), maxFramePayload)
	}
	wireLen := kdbgHeaderLen + len(payload)
	var flags byte
	if wireLen%64 == 0 {
		// Append 1 pad byte so USB Bulk transfers never end on a 64B or 512B boundary.
		flags = frameFlagPad
		wireLen++
	}
	buf := make([]byte, wireLen)
	copy(buf[0:4], kdbgMagic[:])
	buf[4] = cmd
	buf[5] = flags
	binary.LittleEndian.PutUint16(buf[6:8], uint16(len(payload)))
	binary.LittleEndian.PutUint32(buf[8:12], streamID)
	if len(payload) > 0 {
		copy(buf[12:12+len(payload)], payload)
	}
	return buf, nil
}

func readFrame(r *bufio.Reader) (kdbgFrame, error) {
	var f kdbgFrame
	var hdr [kdbgHeaderLen]byte

	// Resynchronize on "KDBG" magic if stray bytes appear after reconnect.
	if _, err := io.ReadFull(r, hdr[:4]); err != nil {
		return f, err
	}
	for hdr[0] != kdbgMagic[0] || hdr[1] != kdbgMagic[1] || hdr[2] != kdbgMagic[2] || hdr[3] != kdbgMagic[3] {
		b, err := r.ReadByte()
		if err != nil {
			return f, err
		}
		hdr[0], hdr[1], hdr[2], hdr[3] = hdr[1], hdr[2], hdr[3], b
	}
	if _, err := io.ReadFull(r, hdr[4:]); err != nil {
		return f, err
	}

	f.cmd = hdr[4]
	flags := hdr[5]
	plen := int(binary.LittleEndian.Uint16(hdr[6:8]))
	f.streamID = binary.LittleEndian.Uint32(hdr[8:12])
	if plen > maxFramePayload {
		return f, fmt.Errorf("invalid frame payload length %d", plen)
	}
	if plen > 0 {
		f.payload = make([]byte, plen)
		if _, err := io.ReadFull(r, f.payload); err != nil {
			return f, err
		}
	}
	if flags&frameFlagPad != 0 {
		if _, err := r.ReadByte(); err != nil {
			return f, err
		}
	}
	return f, nil
}

type streamMux struct {
	targetAddr string
	outCh      chan []byte
	logf       func(string, ...any)

	mu      sync.Mutex
	streams map[uint32]net.Conn
}

func newStreamMux(targetAddr string, logf func(string, ...any)) *streamMux {
	return &streamMux{
		targetAddr: targetAddr,
		outCh:      make(chan []byte, 256),
		logf:       logf,
		streams:    make(map[uint32]net.Conn),
	}
}

func (m *streamMux) enqueue(cmd byte, streamID uint32, payload []byte) {
	pkt, err := encodeFrame(cmd, streamID, payload)
	if err != nil {
		m.logf("encodeFrame error: %v", err)
		return
	}
	m.outCh <- pkt
}

func (m *streamMux) closeAllStreams() {
	m.mu.Lock()
	defer m.mu.Unlock()
	for id, conn := range m.streams {
		_ = conn.Close()
		delete(m.streams, id)
	}
}

func (m *streamMux) closeStream(id uint32, notify bool) {
	m.mu.Lock()
	conn, ok := m.streams[id]
	if ok {
		delete(m.streams, id)
	}
	m.mu.Unlock()
	if ok {
		_ = conn.Close()
		if notify {
			m.enqueue(cmdClose, id, nil)
		}
	}
}

func (m *streamMux) handleOpen(ctx context.Context, id uint32) {
	m.closeStream(id, false)

	conn, err := net.DialTimeout("tcp", m.targetAddr, 2*time.Second)
	if err != nil {
		m.logf("ffs dial %s failed for stream %d: %v", m.targetAddr, id, err)
		m.enqueue(cmdClose, id, nil)
		return
	}

	m.mu.Lock()
	m.streams[id] = conn
	m.mu.Unlock()

	go func() {
		buf := make([]byte, maxFramePayload)
		for {
			n, err := conn.Read(buf)
			if n > 0 {
				chunk := make([]byte, n)
				copy(chunk, buf[:n])
				m.enqueue(cmdData, id, chunk)
			}
			if err != nil {
				m.closeStream(id, ctx.Err() == nil)
				return
			}
		}
	}()
}

func (m *streamMux) handleData(id uint32, payload []byte) {
	if len(payload) == 0 {
		return
	}
	m.mu.Lock()
	conn := m.streams[id]
	m.mu.Unlock()
	if conn == nil {
		return
	}
	if _, err := conn.Write(payload); err != nil {
		m.closeStream(id, true)
	}
}

func (m *streamMux) run(ctx context.Context, r io.Reader, w io.Writer) error {
	br := bufio.NewReaderSize(r, 32*1024)
	errCh := make(chan error, 2)

	// Writer goroutine serializes all outbound frames onto Bulk IN.
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case pkt := <-m.outCh:
				off := 0
				for off < len(pkt) {
					n, err := w.Write(pkt[off:])
					if err != nil {
						errCh <- err
						return
					}
					off += n
				}
			}
		}
	}()

	go func() {
		for {
			frame, err := readFrame(br)
			if err != nil {
				errCh <- err
				return
			}
			switch frame.cmd {
			case cmdOpen:
				m.handleOpen(ctx, frame.streamID)
			case cmdData:
				m.handleData(frame.streamID, frame.payload)
			case cmdClose:
				m.closeStream(frame.streamID, false)
			case cmdPing:
				m.enqueue(cmdPong, frame.streamID, frame.payload)
			}
		}
	}()

	select {
	case <-ctx.Done():
		m.closeAllStreams()
		return ctx.Err()
	case err := <-errCh:
		m.closeAllStreams()
		return err
	}
}

// retryUSBReader adapts /dev/usb-ffs/usbdbg/ep2 reads so cable unplugs or UDC resets
// back off and retry instead of crashing the daemon. Every read from ep2 uses a
// fixed 16384-byte buffer (exact multiple of 512) and queues excess bytes safely.
type retryUSBReader struct {
	ctx     context.Context
	f       *os.File
	onErr   func()
	logf    func(string, ...any)
	readBuf []byte
	pending []byte
}

func (rr *retryUSBReader) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	if len(rr.pending) > 0 {
		n := copy(p, rr.pending)
		rr.pending = rr.pending[n:]
		return n, nil
	}
	if len(rr.readBuf) == 0 {
		rr.readBuf = make([]byte, 16384)
	}
	for {
		if rr.ctx.Err() != nil {
			return 0, io.EOF
		}
		n, err := rr.f.Read(rr.readBuf)
		if n > 0 {
			copied := copy(p, rr.readBuf[:n])
			if copied < n {
				rr.pending = rr.readBuf[copied:n]
			}
			return copied, nil
		}
		if err != nil {
			if rr.ctx.Err() != nil {
				return 0, io.EOF
			}
			if rr.onErr != nil {
				rr.onErr()
			}
			select {
			case <-rr.ctx.Done():
				return 0, io.EOF
			case <-time.After(200 * time.Millisecond):
			}
		}
	}
}

type retryUSBWriter struct {
	ctx  context.Context
	f    *os.File
	logf func(string, ...any)
}

func (rw *retryUSBWriter) Write(p []byte) (int, error) {
	for tries := 0; tries < 25; tries++ {
		if rw.ctx.Err() != nil {
			return 0, io.ErrClosedPipe
		}
		n, err := rw.f.Write(p)
		if err == nil {
			return n, nil
		}
		if errors.Is(err, os.ErrClosed) {
			return 0, err
		}
		time.Sleep(100 * time.Millisecond)
	}
	return 0, fmt.Errorf("ep1 write timed out")
}

type ffsSession struct {
	ep0 *os.File
	ep1 *os.File
	ep2 *os.File
}

func (s *ffsSession) Close() {
	if s.ep2 != nil {
		_ = s.ep2.Close()
	}
	if s.ep1 != nil {
		_ = s.ep1.Close()
	}
	if s.ep0 != nil {
		_ = s.ep0.Close()
	}
	_ = unmountFunctionFS(ffsMountPoint)
}

func startFunctionFSSession(ctx context.Context, gadgetDir, udcName string, logf func(string, ...any)) (*ffsSession, error) {
	fnDir := filepath.Join(gadgetDir, "functions", "ffs.usbdbg")
	if err := os.MkdirAll(fnDir, 0755); err != nil {
		return nil, fmt.Errorf("mkdir ffs.usbdbg: %w", err)
	}
	_ = unmountFunctionFS(ffsMountPoint)
	if err := mountFunctionFS(ffsMountPoint); err != nil {
		return nil, err
	}

	ep0Path := filepath.Join(ffsMountPoint, "ep0")
	ep0, err := os.OpenFile(ep0Path, os.O_RDWR, 0)
	if err != nil {
		_ = unmountFunctionFS(ffsMountPoint)
		return nil, fmt.Errorf("open ep0: %w", err)
	}

	cleanupOnErr := func() {
		_ = ep0.Close()
		_ = unmountFunctionFS(ffsMountPoint)
	}

	if _, err := ep0.Write(buildFFSDescriptors()); err != nil {
		cleanupOnErr()
		return nil, fmt.Errorf("write ffs descriptors: %w", err)
	}
	if _, err := ep0.Write(buildFFSStrings()); err != nil {
		cleanupOnErr()
		return nil, fmt.Errorf("write ffs strings: %w", err)
	}

	// Open ep1 (Bulk IN, O_WRONLY) and ep2 (Bulk OUT, O_RDONLY) before binding UDC
	// so FunctionFS endpoints are immediately ready when the host enumerates.
	ep1, err := os.OpenFile(filepath.Join(ffsMountPoint, "ep1"), os.O_WRONLY, 0)
	if err != nil {
		cleanupOnErr()
		return nil, fmt.Errorf("open ep1: %w", err)
	}
	ep2, err := os.OpenFile(filepath.Join(ffsMountPoint, "ep2"), os.O_RDONLY, 0)
	if err != nil {
		_ = ep1.Close()
		cleanupOnErr()
		return nil, fmt.Errorf("open ep2: %w", err)
	}

	if err := os.Symlink(fnDir, filepath.Join(gadgetDir, "configs", "c.1", "ffs.usbdbg")); err != nil {
		_ = ep2.Close()
		_ = ep1.Close()
		cleanupOnErr()
		return nil, fmt.Errorf("symlink ffs.usbdbg: %w", err)
	}
	if err := os.WriteFile(filepath.Join(gadgetDir, "UDC"), []byte(udcName+"\n"), 0644); err != nil {
		_ = ep2.Close()
		_ = ep1.Close()
		cleanupOnErr()
		return nil, fmt.Errorf("bind UDC %s: %w", udcName, err)
	}

	// Drain 12-byte usb_functionfs_event packets from ep0.
	go func() {
		evBuf := make([]byte, 12*8)
		for {
			if ctx.Err() != nil {
				return
			}
			n, err := ep0.Read(evBuf)
			if err != nil {
				if ctx.Err() != nil {
					return
				}
				time.Sleep(200 * time.Millisecond)
				continue
			}
			for off := 0; off+12 <= n; off += 12 {
				evType := evBuf[off+8]
				logf("ffs ep0 event type=%d", evType)
				if evType == 4 { // FUNCTIONFS_SETUP: stall unexpected control request
					bRequestType := evBuf[off]
					if bRequestType&0x80 != 0 {
						_, _ = ep0.Read([]byte{})
					} else {
						_, _ = ep0.Write([]byte{})
					}
				}
			}
		}
	}()

	mux := newStreamMux("127.0.0.1:2222", logf)
	rr := &retryUSBReader{
		ctx:   ctx,
		f:     ep2,
		onErr: mux.closeAllStreams,
		logf:  logf,
	}
	rw := &retryUSBWriter{
		ctx:  ctx,
		f:    ep1,
		logf: logf,
	}
	go func() {
		for ctx.Err() == nil {
			if err := mux.run(ctx, rr, rw); err != nil && ctx.Err() == nil {
				logf("ffs mux restarting after error: %v", err)
				time.Sleep(200 * time.Millisecond)
			}
		}
	}()

	return &ffsSession{ep0: ep0, ep1: ep1, ep2: ep2}, nil
}
