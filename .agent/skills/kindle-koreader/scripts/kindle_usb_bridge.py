#!/usr/bin/env python3
"""
macOS & Linux USB Debug host bridge & auto-discovery for jailbroken Kindles running usbdebug.koplugin.

Supports:
  - Mode 1 (0x1949:0x9983): Native USB CDC-NCM / CDC-ECM Ethernet (192.168.15.1:2222)
  - Mode 2 (0x1949:0x9982): FunctionFS Bulk TCP multiplexer over libusb-1.0 -> 127.0.0.1:2222

Subcommands:
  host                    Resolve active Kindle SSH host (spawning FFS bridge daemon if needed).
  probe                   Inspect connected Kindle USB state (NCM/ECM, FFS, or MTP).
  daemon [--port 2222]    Run FunctionFS -> 127.0.0.1:PORT multiplexer daemon.
  stop                    Stop background FFS bridge daemon.
  selftest                Run local framing, struct-size, and mux loopback self-tests.
"""

import argparse
import ctypes
import ctypes.util
import glob
import json
import os
import queue
import re
import signal
import socket
import struct
import subprocess
import sys
import threading
import time

sys.dont_write_bytecode = True

KINDLE_VID = 0x1949
KINDLE_MTP_PID = 0x9981
KINDLE_FFS_PID = 0x9982
KINDLE_NET_PID = 0x9983

NET_KINDLE_IP = "192.168.15.1"
DEFAULT_SSH_PORT = 2222
PID_FILE = "/tmp/kindle_usb_bridge.pid"
LOG_FILE = "/tmp/kindle_usb_bridge.log"

KDBG_MAGIC = b"KDBG"
KDBG_HDR_FMT = "<4sBBHI"
KDBG_HDR_SIZE = 12
MAX_FRAME_PAYLOAD = 8192

CMD_OPEN = 1
CMD_DATA = 2
CMD_CLOSE = 3
CMD_PING = 4
CMD_PONG = 5
FLAG_PAD = 1

LIBUSB_SUCCESS = 0
LIBUSB_ERROR_IO = -1
LIBUSB_ERROR_TIMEOUT = -7
LIBUSB_ERROR_PIPE = -9
LIBUSB_ERROR_NO_DEVICE = -4
LIBUSB_ENDPOINT_IN = 0x80
LIBUSB_TRANSFER_TYPE_MASK = 0x03
LIBUSB_TRANSFER_TYPE_BULK = 0x02


class LibusbEndpointDescriptor(ctypes.Structure):
    _fields_ = [
        ("bLength", ctypes.c_uint8),
        ("bDescriptorType", ctypes.c_uint8),
        ("bEndpointAddress", ctypes.c_uint8),
        ("bmAttributes", ctypes.c_uint8),
        ("wMaxPacketSize", ctypes.c_uint16),
        ("bInterval", ctypes.c_uint8),
        ("bRefresh", ctypes.c_uint8),
        ("bSynchAddress", ctypes.c_uint8),
        ("extra", ctypes.c_void_p),
        ("extra_length", ctypes.c_int),
    ]


class LibusbInterfaceDescriptor(ctypes.Structure):
    _fields_ = [
        ("bLength", ctypes.c_uint8),
        ("bDescriptorType", ctypes.c_uint8),
        ("bInterfaceNumber", ctypes.c_uint8),
        ("bAlternateSetting", ctypes.c_uint8),
        ("bNumEndpoints", ctypes.c_uint8),
        ("bInterfaceClass", ctypes.c_uint8),
        ("bInterfaceSubClass", ctypes.c_uint8),
        ("bInterfaceProtocol", ctypes.c_uint8),
        ("iInterface", ctypes.c_uint8),
        ("endpoint", ctypes.POINTER(LibusbEndpointDescriptor)),
        ("extra", ctypes.c_void_p),
        ("extra_length", ctypes.c_int),
    ]


class LibusbInterface(ctypes.Structure):
    _fields_ = [
        ("altsetting", ctypes.POINTER(LibusbInterfaceDescriptor)),
        ("num_altsetting", ctypes.c_int),
    ]


class LibusbConfigDescriptor(ctypes.Structure):
    _fields_ = [
        ("bLength", ctypes.c_uint8),
        ("bDescriptorType", ctypes.c_uint8),
        ("wTotalLength", ctypes.c_uint16),
        ("bNumInterfaces", ctypes.c_uint8),
        ("bConfigurationValue", ctypes.c_uint8),
        ("iConfiguration", ctypes.c_uint8),
        ("bmAttributes", ctypes.c_uint8),
        ("MaxPower", ctypes.c_uint8),
        ("interface", ctypes.POINTER(LibusbInterface)),
        ("extra", ctypes.c_void_p),
        ("extra_length", ctypes.c_int),
    ]


def load_libusb():
    candidates = [
        "/opt/homebrew/lib/libusb-1.0.dylib",
        "/usr/local/lib/libusb-1.0.dylib",
        "libusb-1.0.dylib",
        "libusb-1.0.so.0",
        "libusb-1.0.so",
    ]
    found_lib = ctypes.util.find_library("usb-1.0")
    if found_lib:
        candidates.insert(0, found_lib)
    lib = None
    for path in candidates:
        if path.startswith("/") and not os.path.exists(path):
            continue
        try:
            lib = ctypes.CDLL(path)
            break
        except OSError:
            continue
    if lib is None:
        raise RuntimeError(
            "libusb-1.0 not found (macOS: brew install libusb; Linux: apt install libusb-1.0-0)"
        )

    lib.libusb_init.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
    lib.libusb_init.restype = ctypes.c_int

    lib.libusb_exit.argtypes = [ctypes.c_void_p]
    lib.libusb_exit.restype = None

    lib.libusb_open_device_with_vid_pid.argtypes = [
        ctypes.c_void_p,
        ctypes.c_uint16,
        ctypes.c_uint16,
    ]
    lib.libusb_open_device_with_vid_pid.restype = ctypes.c_void_p

    lib.libusb_get_device.argtypes = [ctypes.c_void_p]
    lib.libusb_get_device.restype = ctypes.c_void_p

    lib.libusb_get_active_config_descriptor.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.POINTER(LibusbConfigDescriptor)),
    ]
    lib.libusb_get_active_config_descriptor.restype = ctypes.c_int

    lib.libusb_free_config_descriptor.argtypes = [ctypes.POINTER(LibusbConfigDescriptor)]
    lib.libusb_free_config_descriptor.restype = None

    lib.libusb_claim_interface.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.libusb_claim_interface.restype = ctypes.c_int

    lib.libusb_release_interface.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.libusb_release_interface.restype = ctypes.c_int

    lib.libusb_close.argtypes = [ctypes.c_void_p]
    lib.libusb_close.restype = None

    lib.libusb_bulk_transfer.argtypes = [
        ctypes.c_void_p,
        ctypes.c_ubyte,
        ctypes.POINTER(ctypes.c_ubyte),
        ctypes.c_int,
        ctypes.POINTER(ctypes.c_int),
        ctypes.c_uint,
    ]
    lib.libusb_bulk_transfer.restype = ctypes.c_int
    return lib


def encode_frame(cmd: int, stream_id: int, payload: bytes = b"") -> bytes:
    if len(payload) > MAX_FRAME_PAYLOAD:
        raise ValueError(f"payload too large: {len(payload)}")
    wire_len = KDBG_HDR_SIZE + len(payload)
    flags = 0
    pad = b""
    if wire_len % 64 == 0:
        flags = FLAG_PAD
        pad = b"\x00"
    hdr = struct.pack(KDBG_HDR_FMT, KDBG_MAGIC, cmd, flags, len(payload), stream_id)
    return hdr + payload + pad


class FrameDecoder:
    def __init__(self) -> None:
        self.buf = bytearray()

    def feed(self, data: bytes) -> list[tuple[int, int, bytes]]:
        if data:
            self.buf.extend(data)
        frames: list[tuple[int, int, bytes]] = []
        while True:
            idx = self.buf.find(KDBG_MAGIC)
            if idx < 0:
                if len(self.buf) > 3:
                    del self.buf[:-3]
                break
            if idx > 0:
                del self.buf[:idx]
            if len(self.buf) < KDBG_HDR_SIZE:
                break
            _magic, cmd, flags, plen, stream_id = struct.unpack_from(KDBG_HDR_FMT, self.buf, 0)
            if plen > MAX_FRAME_PAYLOAD:
                del self.buf[:4]
                continue
            need = KDBG_HDR_SIZE + plen + (1 if (flags & FLAG_PAD) else 0)
            if len(self.buf) < need:
                break
            payload = bytes(self.buf[KDBG_HDR_SIZE : KDBG_HDR_SIZE + plen])
            del self.buf[:need]
            frames.append((cmd, stream_id, payload))
        return frames


def _record_usb_device(found: dict, vid: int, pid: int, product: str, serial: str) -> None:
    if vid != KINDLE_VID:
        return
    entry = {
        "vid": f"{vid:04x}",
        "pid": f"{pid:04x}",
        "product": product,
        "serial": serial,
    }
    if entry not in found["devices"]:
        found["devices"].append(entry)
    if pid == KINDLE_NET_PID:
        found["net"] = True
    elif pid == KINDLE_FFS_PID:
        found["ffs"] = True
    elif pid == KINDLE_MTP_PID:
        found["mtp"] = True


def _read_sysfs_str(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return ""


def scan_usb_kindle() -> dict:
    found = {"net": False, "ffs": False, "mtp": False, "devices": []}
    if sys.platform == "darwin":
        out = subprocess.check_output(
            ["ioreg", "-r", "-c", "IOUSBHostDevice", "-l", "-w", "0"],
            text=True,
            errors="replace",
        )
        for block in out.split("+-o "):
            vid_m = re.search(r'"idVendor"\s*=\s*(\d+)', block)
            pid_m = re.search(r'"idProduct"\s*=\s*(\d+)', block)
            if not vid_m or not pid_m:
                continue
            vid = int(vid_m.group(1))
            pid = int(pid_m.group(1))
            prod_m = re.search(r'"USB Product Name"\s*=\s*"([^"]+)"', block)
            ser_m = re.search(r'"USB Serial Number"\s*=\s*"([^"]+)"', block)
            _record_usb_device(
                found,
                vid,
                pid,
                prod_m.group(1) if prod_m else "",
                ser_m.group(1) if ser_m else "",
            )
        return found

    if sys.platform.startswith("linux"):
        for vid_path in glob.glob("/sys/bus/usb/devices/*/idVendor"):
            dev_dir = os.path.dirname(vid_path)
            vid_hex = _read_sysfs_str(vid_path)
            pid_hex = _read_sysfs_str(os.path.join(dev_dir, "idProduct"))
            if not vid_hex or not pid_hex:
                continue
            try:
                vid = int(vid_hex, 16)
                pid = int(pid_hex, 16)
            except ValueError:
                continue
            _record_usb_device(
                found,
                vid,
                pid,
                _read_sysfs_str(os.path.join(dev_dir, "product")),
                _read_sysfs_str(os.path.join(dev_dir, "serial")),
            )
    return found


def check_ssh_banner(host: str, port: int, timeout: float = 1.2) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout) as s:
            s.settimeout(timeout)
            banner = s.recv(64)
            return banner.startswith(b"SSH-")
    except OSError:
        return False


def is_daemon_alive() -> int:
    if not os.path.exists(PID_FILE):
        return 0
    try:
        with open(PID_FILE, "r", encoding="utf-8") as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError):
        return 0


def find_ffs_endpoints(lib, handle):
    dev = lib.libusb_get_device(handle)
    cfg_ptr = ctypes.POINTER(LibusbConfigDescriptor)()
    rc = lib.libusb_get_active_config_descriptor(dev, ctypes.byref(cfg_ptr))
    if rc != 0 or not cfg_ptr:
        raise RuntimeError(f"libusb_get_active_config_descriptor failed: {rc}")
    try:
        cfg = cfg_ptr.contents
        for i in range(cfg.bNumInterfaces):
            iface = cfg.interface[i]
            for a in range(iface.num_altsetting):
                alt = iface.altsetting[a]
                if (
                    alt.bInterfaceClass == 0xFF
                    and alt.bInterfaceSubClass == 0x42
                    and alt.bInterfaceProtocol == 0x03
                ) or cfg.bNumInterfaces == 1:
                    ep_in = None
                    ep_out = None
                    for e in range(alt.bNumEndpoints):
                        ep = alt.endpoint[e]
                        if (ep.bmAttributes & LIBUSB_TRANSFER_TYPE_MASK) != LIBUSB_TRANSFER_TYPE_BULK:
                            continue
                        if ep.bEndpointAddress & LIBUSB_ENDPOINT_IN:
                            ep_in = ep.bEndpointAddress
                        else:
                            ep_out = ep.bEndpointAddress
                    if ep_in is not None and ep_out is not None:
                        return alt.bInterfaceNumber, ep_in, ep_out
        raise RuntimeError("no suitable bulk IN/OUT interface found")
    finally:
        lib.libusb_free_config_descriptor(cfg_ptr)


class USBBridgeSession:
    def __init__(self, send_fn, log_fn=print) -> None:
        self.send_fn = send_fn
        self.log = log_fn
        self.lock = threading.Lock()
        self.streams: dict[int, socket.socket] = {}
        self.next_id = 1
        self.out_q: queue.Queue[bytes | None] = queue.Queue(maxsize=512)
        self.closed = threading.Event()
        self.pong_events: dict[int, threading.Event] = {}

    def start_writer(self) -> threading.Thread:
        t = threading.Thread(target=self._writer_loop, daemon=True)
        t.start()
        return t

    def _writer_loop(self) -> None:
        while not self.closed.is_set():
            try:
                pkt = self.out_q.get(timeout=0.25)
            except queue.Empty:
                continue
            if pkt is None:
                break
            try:
                self.send_fn(pkt)
            except Exception as exc:
                self.log(f"usb send error: {exc}")
                self.close()
                break

    def enqueue(self, cmd: int, stream_id: int, payload: bytes = b"") -> None:
        if self.closed.is_set():
            return
        pkt = encode_frame(cmd, stream_id, payload)
        while not self.closed.is_set():
            try:
                self.out_q.put(pkt, timeout=0.25)
                return
            except queue.Full:
                continue

    def ping(self, timeout: float = 2.0) -> bool:
        with self.lock:
            sid = self.next_id
            self.next_id += 1
            ev = threading.Event()
            self.pong_events[sid] = ev
        self.enqueue(CMD_PING, sid, b"ok")
        ok = ev.wait(timeout)
        with self.lock:
            self.pong_events.pop(sid, None)
        return ok

    def attach_client(self, conn: socket.socket) -> None:
        if self.closed.is_set():
            conn.close()
            return
        with self.lock:
            sid = self.next_id
            self.next_id += 1
            self.streams[sid] = conn

        self.enqueue(CMD_OPEN, sid)

        def reader() -> None:
            try:
                while not self.closed.is_set():
                    data = conn.recv(MAX_FRAME_PAYLOAD)
                    if not data:
                        break
                    self.enqueue(CMD_DATA, sid, data)
            except OSError:
                pass
            finally:
                self.close_stream(sid, notify=True)

        threading.Thread(target=reader, daemon=True).start()

    def close_stream(self, sid: int, notify: bool) -> None:
        with self.lock:
            conn = self.streams.pop(sid, None)
        if conn is not None:
            try:
                conn.close()
            except OSError:
                pass
            if notify:
                self.enqueue(CMD_CLOSE, sid)

    def handle_usb_frame(self, cmd: int, sid: int, payload: bytes) -> None:
        if cmd == CMD_PONG:
            with self.lock:
                ev = self.pong_events.get(sid)
            if ev:
                ev.set()
            return
        if cmd == CMD_CLOSE:
            self.close_stream(sid, notify=False)
            return
        if cmd == CMD_DATA:
            with self.lock:
                conn = self.streams.get(sid)
            if conn is None:
                return
            try:
                conn.sendall(payload)
            except OSError:
                self.close_stream(sid, notify=True)

    def close(self) -> None:
        if self.closed.is_set():
            return
        self.closed.set()
        try:
            self.out_q.put_nowait(None)
        except queue.Full:
            pass
        with self.lock:
            conns = list(self.streams.values())
            self.streams.clear()
            evs = list(self.pong_events.values())
            self.pong_events.clear()
        for c in conns:
            try:
                c.close()
            except OSError:
                pass
        for ev in evs:
            ev.set()


def run_daemon(port: int, vid: int, pid: int) -> int:
    lib = load_libusb()
    ctx = ctypes.c_void_p()
    if lib.libusb_init(ctypes.byref(ctx)) != 0:
        print("error: libusb_init failed", file=sys.stderr)
        return 1

    with open(PID_FILE, "w", encoding="utf-8") as f:
        f.write(f"{os.getpid()}\n")

    stop_ev = threading.Event()

    def on_sig(_signum, _frame):
        stop_ev.set()

    signal.signal(signal.SIGINT, on_sig)
    signal.signal(signal.SIGTERM, on_sig)

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(16)
    srv.settimeout(0.5)

    active_session: list[USBBridgeSession | None] = [None]
    session_lock = threading.Lock()

    def accept_loop() -> None:
        while not stop_ev.is_set():
            try:
                conn, _addr = srv.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with session_lock:
                sess = active_session[0]
            if sess is None or sess.closed.is_set():
                conn.close()
                continue
            sess.attach_client(conn)

    accept_t = threading.Thread(target=accept_loop, daemon=True)
    accept_t.start()

    print(f"kindle_usb_bridge listening on 127.0.0.1:{port} for {vid:04x}:{pid:04x}", flush=True)

    try:
        while not stop_ev.is_set():
            handle = lib.libusb_open_device_with_vid_pid(ctx, vid, pid)
            if not handle:
                time.sleep(0.5)
                continue

            iface_num = None
            sess = None
            try:
                iface_num, ep_in, ep_out = find_ffs_endpoints(lib, handle)
                rc = lib.libusb_claim_interface(handle, iface_num)
                if rc != 0:
                    print(f"libusb_claim_interface({iface_num}) failed: {rc}", file=sys.stderr, flush=True)
                    time.sleep(0.5)
                    continue

                def send_usb(pkt: bytes) -> None:
                    off = 0
                    while off < len(pkt):
                        chunk = pkt[off:]
                        arr = (ctypes.c_ubyte * len(chunk)).from_buffer_copy(chunk)
                        xfer = ctypes.c_int(0)
                        ret = lib.libusb_bulk_transfer(
                            handle, ep_out, arr, len(chunk), ctypes.byref(xfer), 5000
                        )
                        if ret != 0:
                            raise RuntimeError(f"bulk OUT error {ret}")
                        if xfer.value <= 0:
                            raise RuntimeError("bulk OUT transferred 0 bytes")
                        off += xfer.value

                sess = USBBridgeSession(send_usb, log_fn=lambda m: print(m, file=sys.stderr, flush=True))
                sess.start_writer()
                with session_lock:
                    active_session[0] = sess

                print(f"USB FFS attached (iface={iface_num} ep_in=0x{ep_in:02x} ep_out=0x{ep_out:02x})", flush=True)

                decoder = FrameDecoder()
                in_buf = (ctypes.c_ubyte * 16384)()
                xfer = ctypes.c_int(0)

                while not stop_ev.is_set() and not sess.closed.is_set():
                    ret = lib.libusb_bulk_transfer(
                        handle, ep_in, in_buf, 16384, ctypes.byref(xfer), 500
                    )
                    n = xfer.value
                    if n > 0:
                        raw = bytes(in_buf[:n])
                        for cmd, sid, payload in decoder.feed(raw):
                            sess.handle_usb_frame(cmd, sid, payload)
                    if ret in (LIBUSB_SUCCESS, LIBUSB_ERROR_TIMEOUT):
                        continue
                    print(f"bulk IN ended with rc={ret}", file=sys.stderr, flush=True)
                    break
            except Exception as exc:
                print(f"USB session error: {exc}", file=sys.stderr, flush=True)
            finally:
                with session_lock:
                    if active_session[0] is sess:
                        active_session[0] = None
                if sess is not None:
                    sess.close()
                if iface_num is not None:
                    lib.libusb_release_interface(handle, iface_num)
                lib.libusb_close(handle)
                time.sleep(0.3)
    finally:
        stop_ev.set()
        try:
            srv.close()
        except OSError:
            pass
        if os.path.exists(PID_FILE):
            try:
                os.remove(PID_FILE)
            except OSError:
                pass
        lib.libusb_exit(ctx)
    return 0


def cmd_probe() -> int:
    info = scan_usb_kindle()
    info["bridge_pid"] = is_daemon_alive()
    info["net_ssh_ready"] = check_ssh_banner(NET_KINDLE_IP, DEFAULT_SSH_PORT, 0.8) if info["net"] else False
    info["ffs_ssh_ready"] = check_ssh_banner("127.0.0.1", DEFAULT_SSH_PORT, 0.8) if info["ffs"] else False
    print(json.dumps(info, indent=2))
    return 0


def cmd_host(port: int) -> int:
    info = scan_usb_kindle()
    if info["net"]:
        if sys.platform == "darwin":
            subprocess.run(["networksetup", "-detectnewhardware"], capture_output=True)
        deadline = time.time() + 4.0
        while time.time() < deadline:
            if check_ssh_banner(NET_KINDLE_IP, port, 0.6):
                print(NET_KINDLE_IP)
                return 0
            time.sleep(0.3)
        print(
            f"error: Kindle USBNet (1949:9983) detected on USB, but {NET_KINDLE_IP}:{port} is not reachable yet",
            file=sys.stderr,
        )
        return 1

    if info["ffs"]:
        if is_daemon_alive() == 0:
            logf = open(LOG_FILE, "ab")
            subprocess.Popen(
                [sys.executable, "-B", os.path.abspath(__file__), "daemon", "--port", str(port)],
                stdin=subprocess.DEVNULL,
                stdout=logf,
                stderr=logf,
                start_new_session=True,
            )
            logf.close()
        deadline = time.time() + 5.0
        while time.time() < deadline:
            if check_ssh_banner("127.0.0.1", port, 0.8):
                print("127.0.0.1")
                return 0
            time.sleep(0.25)
        print(
            f"error: Kindle USBDebug FFS (1949:9982) detected, but 127.0.0.1:{port} SSH bridge did not answer",
            file=sys.stderr,
        )
        return 1

    if info["mtp"]:
        print(
            "error: Kindle is in stock MTP mode (1949:9981). Open KOReader on the Kindle to enable USB Debug.",
            file=sys.stderr,
        )
        return 1

    print("error: no USB Kindle detected (set KINDLE_HOST explicitly for Wi-Fi SSH)", file=sys.stderr)
    return 1


def cmd_stop() -> int:
    pid = is_daemon_alive()
    if pid > 0:
        os.kill(pid, signal.SIGTERM)
        for _ in range(25):
            if is_daemon_alive() == 0:
                break
            time.sleep(0.1)
    if os.path.exists(PID_FILE):
        os.remove(PID_FILE)
    print("stopped")
    return 0


def cmd_selftest() -> int:
    lib = load_libusb()
    assert ctypes.sizeof(LibusbEndpointDescriptor) == 32, ctypes.sizeof(LibusbEndpointDescriptor)
    assert ctypes.sizeof(LibusbInterfaceDescriptor) == 40, ctypes.sizeof(LibusbInterfaceDescriptor)
    assert ctypes.sizeof(LibusbInterface) == 16, ctypes.sizeof(LibusbInterface)
    assert ctypes.sizeof(LibusbConfigDescriptor) == 40, ctypes.sizeof(LibusbConfigDescriptor)

    dec = FrameDecoder()
    for plen in (0, 52, 500, 501, 1012, MAX_FRAME_PAYLOAD):
        payload = b"x" * plen
        wire = encode_frame(CMD_DATA, 11, payload)
        assert len(wire) % 64 != 0, f"wire length {len(wire)} divisible by 64"
        frames = dec.feed(wire[:7]) + dec.feed(wire[7:])
        assert frames == [(CMD_DATA, 11, payload)], frames

    # Multiplexer loopback test over in-memory socket pair + frame pipe.
    echo_srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    echo_srv.bind(("127.0.0.1", 0))
    echo_srv.listen(4)
    echo_port = echo_srv.getsockname()[1]

    def echo_accept():
        c, _ = echo_srv.accept()
        with c:
            while True:
                d = c.recv(4096)
                if not d:
                    break
                c.sendall(d)

    threading.Thread(target=echo_accept, daemon=True).start()

    dev_dec = FrameDecoder()
    dev_conns: dict[int, socket.socket] = {}
    sess_holder: list[USBBridgeSession | None] = [None]

    def sim_host_to_dev(pkt: bytes) -> None:
        for cmd, sid, payload in dev_dec.feed(pkt):
            if cmd == CMD_PING:
                sess_holder[0].handle_usb_frame(CMD_PONG, sid, payload)
            elif cmd == CMD_OPEN:
                c = socket.create_connection(("127.0.0.1", echo_port))
                dev_conns[sid] = c

                def dev_reader(conn: socket.socket, s_id: int) -> None:
                    try:
                        while True:
                            d = conn.recv(4096)
                            if not d:
                                break
                            sess_holder[0].handle_usb_frame(CMD_DATA, s_id, d)
                    except OSError:
                        pass
                    finally:
                        try:
                            conn.close()
                        except OSError:
                            pass
                        sess_holder[0].handle_usb_frame(CMD_CLOSE, s_id, b"")

                threading.Thread(target=dev_reader, args=(c, sid), daemon=True).start()
            elif cmd == CMD_DATA and sid in dev_conns:
                dev_conns[sid].sendall(payload)
            elif cmd == CMD_CLOSE and sid in dev_conns:
                dev_conns.pop(sid).close()

    sess = USBBridgeSession(sim_host_to_dev)
    sess_holder[0] = sess
    sess.start_writer()
    assert sess.ping(timeout=1.5), "ping failed"

    c1, c2 = socket.socketpair()
    sess.attach_client(c1)
    test_payload = b"hello-usb-debug-" * 40
    c2.sendall(test_payload)
    got = bytearray()
    c2.settimeout(2.0)
    while len(got) < len(test_payload):
        got.extend(c2.recv(4096))
    assert bytes(got) == test_payload
    c2.close()
    sess.close()
    echo_srv.close()
    _ = lib
    print("SELFTEST_OK")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Kindle USB Debug bridge for macOS")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_host = sub.add_parser("host")
    p_host.add_argument("--port", type=int, default=DEFAULT_SSH_PORT)
    sub.add_parser("probe")
    p_daemon = sub.add_parser("daemon")
    p_daemon.add_argument("--port", type=int, default=DEFAULT_SSH_PORT)
    p_daemon.add_argument("--vid", type=lambda x: int(x, 0), default=KINDLE_VID)
    p_daemon.add_argument("--pid", type=lambda x: int(x, 0), default=KINDLE_FFS_PID)
    sub.add_parser("stop")
    sub.add_parser("selftest")

    args = parser.parse_args()
    if args.cmd == "host":
        return cmd_host(args.port)
    if args.cmd == "probe":
        return cmd_probe()
    if args.cmd == "daemon":
        return run_daemon(args.port, args.vid, args.pid)
    if args.cmd == "stop":
        return cmd_stop()
    if args.cmd == "selftest":
        return cmd_selftest()
    return 2


if __name__ == "__main__":
    sys.exit(main())
