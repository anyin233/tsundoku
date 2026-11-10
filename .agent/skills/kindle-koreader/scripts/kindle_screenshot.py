#!/usr/bin/env python3
"""
Zero-dependency Kindle KOReader framebuffer screenshot capture & UI coordinate inspector.

Subcommands:
  capture <out.png>             Stream /dev/fb0 over SSH, auto-detect geometry/stride/bpp, save PNG.
  lines   <img.png>             List horizontal separator y-coordinates, row centers, and top-bar icon x-clusters.
  diff    <before.png> <after.png>
                                Compute exact pixel bounding box of a newly opened modal, menu, or keyboard.
"""

import gzip
import os
import re
import struct
import subprocess
import sys
import zlib


def ssh_base_cmd():
    host = os.environ.get("KINDLE_HOST", "").strip()
    if not host:
        sys.exit("error: KINDLE_HOST is not set (e.g. export KINDLE_HOST=192.168.x.x)")
    port = os.environ.get("KINDLE_PORT", "2222").strip()
    user = os.environ.get("KINDLE_USER", "root").strip()
    return [
        "ssh",
        "-o", "LogLevel=error",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "ConnectTimeout=8",
        "-p", port,
        f"{user}@{host}",
    ]


def probe_fb_geometry():
    probe_sh = (
        "(/mnt/us/koreader/fbink -e 2>/dev/null || /mnt/us/libkh/bin/fbink -e 2>/dev/null || true); "
        "echo __SYSFS__; "
        "cat /sys/class/graphics/fb0/virtual_size 2>/dev/null || true; "
        "echo __BPP__; "
        "cat /sys/class/graphics/fb0/bits_per_pixel 2>/dev/null || true; "
        "echo __STRIDE__; "
        "cat /sys/class/graphics/fb0/stride 2>/dev/null || true"
    )
    res = subprocess.run(ssh_base_cmd() + [probe_sh], capture_output=True, text=True, check=True)
    out = res.stdout

    width = height = bpp = stride = None

    m_var = re.search(r"Variable fb info:\s*(\d+)x(\d+),\s*(\d+)bpp", out)
    if m_var:
        width, height, bpp = int(m_var.group(1)), int(m_var.group(2)), int(m_var.group(3))
    m_fix = re.search(r"line length:\s*(\d+)", out)
    if m_fix:
        stride = int(m_fix.group(1))

    m_fbink_env = re.search(r"viewWidth=(\d+).*?viewHeight=(\d+)", out)
    if m_fbink_env and not width:
        width, height = int(m_fbink_env.group(1)), int(m_fbink_env.group(2))
    m_bpp_env = re.search(r"bpp=(\d+)", out)
    if m_bpp_env and not bpp:
        bpp = int(m_bpp_env.group(1))

    if not width or not height:
        m_vs = re.search(r"__SYSFS__\s*(\d+),(\d+)", out)
        if m_vs:
            width, height = int(m_vs.group(1)), int(m_vs.group(2))
    if not bpp:
        m_b = re.search(r"__BPP__\s*(\d+)", out)
        bpp = int(m_b.group(1)) if m_b else 8
    if not stride:
        m_s = re.search(r"__STRIDE__\s*(\d+)", out)
        stride = int(m_s.group(1)) if m_s else (width * max(1, bpp // 8))

    if not width or not height:
        sys.exit(f"error: could not determine framebuffer geometry from Kindle:\n{out}")

    return width, height, bpp, stride


def png_chunk(tag: bytes, data: bytes) -> bytes:
    crc = zlib.crc32(tag + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)


def write_gray8_png(path: str, width: int, height: int, gray_rows: list[bytes]) -> None:
    raw = b"".join(b"\x00" + row[:width] for row in gray_rows)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0)
    png = (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", ihdr)
        + png_chunk(b"IDAT", zlib.compress(raw, 6))
        + png_chunk(b"IEND", b"")
    )
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "wb") as f:
        f.write(png)


def decode_fb_to_gray_rows(buf: bytes, width: int, height: int, bpp: int, stride: int) -> list[bytes]:
    rows = []
    for y in range(height):
        line = buf[y * stride : (y + 1) * stride]
        if len(line) < stride:
            line = line + b"\xff" * (stride - len(line))
        if bpp == 8:
            rows.append(line[:width])
        elif bpp == 4:
            out = bytearray(width)
            for i in range(width):
                byte = line[i // 2]
                nib = (byte >> 4) if (i % 2 == 0) else (byte & 0x0F)
                out[i] = nib * 17
            rows.append(bytes(out))
        elif bpp == 16:
            out = bytearray(width)
            for i in range(width):
                px = struct.unpack_from("<H", line, i * 2)[0]
                r = ((px >> 11) & 0x1F) * 255 // 31
                g = ((px >> 5) & 0x3F) * 255 // 63
                b = (px & 0x1F) * 255 // 31
                out[i] = (r * 77 + g * 150 + b * 29) >> 8
            rows.append(bytes(out))
        elif bpp == 32:
            out = bytearray(width)
            for i in range(width):
                b, g, r = line[i * 4], line[i * 4 + 1], line[i * 4 + 2]
                out[i] = (r * 77 + g * 150 + b * 29) >> 8
            rows.append(bytes(out))
        else:
            sys.exit(f"error: unsupported framebuffer bpp={bpp}")
    return rows


def read_gray8_png(path: str) -> tuple[int, int, list[bytes]]:
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        sys.exit(f"error: not a PNG file: {path}")
    pos = 8
    width = height = bit_depth = color_type = 0
    idat = bytearray()
    while pos < len(data):
        length = struct.unpack(">I", data[pos : pos + 4])[0]
        tag = data[pos + 4 : pos + 8]
        chunk = data[pos + 8 : pos + 8 + length]
        if tag == b"IHDR":
            width, height, bit_depth, color_type = struct.unpack(">IIBB", chunk[:10])
        elif tag == b"IDAT":
            idat.extend(chunk)
        pos += 12 + length
    if bit_depth != 8 or color_type != 0:
        sys.exit(f"error: expected 8-bit grayscale PNG (got depth={bit_depth}, color={color_type})")
    raw = zlib.decompress(bytes(idat))
    row_bytes = width + 1
    rows = []
    prev = bytearray(width)
    for y in range(height):
        flt = raw[y * row_bytes]
        cur = bytearray(raw[y * row_bytes + 1 : (y + 1) * row_bytes])
        if flt == 1:  # Sub
            for x in range(1, width):
                cur[x] = (cur[x] + cur[x - 1]) & 0xFF
        elif flt == 2:  # Up
            for x in range(width):
                cur[x] = (cur[x] + prev[x]) & 0xFF
        rows.append(bytes(cur))
        prev = cur
    return width, height, rows


def cmd_capture(out_path: str) -> None:
    width, height, bpp, stride = probe_fb_geometry()
    # Read exact visible height * stride bytes; if virtual_size height is double-buffered, clamp to 1 frame.
    if height > width * 2:
        height = height // 2
    dd_cmd = f"dd if=/dev/fb0 bs={stride} count={height} 2>/dev/null | gzip -c"
    res = subprocess.run(ssh_base_cmd() + [dd_cmd], capture_output=True, check=True)
    raw = gzip.decompress(res.stdout)
    gray_rows = decode_fb_to_gray_rows(raw, width, height, bpp, stride)
    write_gray8_png(out_path, width, height, gray_rows)
    print(f"Saved {out_path} ({width}x{height}, {bpp}bpp, stride={stride})")


def cmd_lines(img_path: str) -> None:
    w, h, rows = read_gray8_png(img_path)
    print(f"Image: {w}x{h}")
    seps = []
    margin = max(20, w // 32)
    threshold = int((w - 2 * margin) * 0.72)
    for y in range(h):
        dark = sum(1 for x in range(margin, w - margin) if rows[y][x] < 200)
        if dark >= threshold and (not seps or y - seps[-1] > 16):
            seps.append(y)
    print("Horizontal separators y:", seps)
    for i in range(len(seps) - 1):
        gap = seps[i + 1] - seps[i]
        if 40 <= gap <= 260:
            print(f"  Band {i + 1:2d}: y={seps[i]}..{seps[i + 1]} -> tap_y={(seps[i] + seps[i + 1]) // 2}")

    top_h = min(110, h)
    cols = [sum(1 for y in range(15, top_h) if rows[y][x] < 150) for x in range(w)]
    in_cluster, start = False, 0
    clusters = []
    for x in range(w):
        if cols[x] > 2 and not in_cluster:
            in_cluster, start = True, x
        elif cols[x] <= 2 and in_cluster:
            in_cluster = False
            if x - start >= 10:
                clusters.append((start, x, (start + x) // 2))
    print("Top bar icon x-clusters (start, end, center_x):", clusters)


def cmd_diff(before_path: str, after_path: str) -> None:
    w0, h0, r0 = read_gray8_png(before_path)
    w1, h1, r1 = read_gray8_png(after_path)
    if (w0, h0) != (w1, h1):
        sys.exit(f"error: size mismatch {w0}x{h0} vs {w1}x{h1}")
    ys = []
    min_x, max_x = w0, 0
    for y in range(h0):
        diffs = [x for x in range(w0) if r0[y][x] != r1[y][x]]
        if len(diffs) > 30:
            ys.append(y)
            if diffs[0] < min_x:
                min_x = diffs[0]
            if diffs[-1] > max_x:
                max_x = diffs[-1]
    if not ys:
        print("No significant UI region difference detected.")
        return
    print(f"Changed bbox: x={min_x}..{max_x} (w={max_x - min_x}), y={ys[0]}..{ys[-1]} (h={ys[-1] - ys[0]})")
    print(f"Center point: ({(min_x + max_x) // 2}, {(ys[0] + ys[-1]) // 2})")


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__.strip())
    cmd = sys.argv[1]
    if cmd == "capture":
        cmd_capture(sys.argv[2])
    elif cmd == "lines":
        cmd_lines(sys.argv[2])
    elif cmd == "diff" and len(sys.argv) >= 4:
        cmd_diff(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__.strip())


if __name__ == "__main__":
    main()
