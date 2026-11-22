#!/usr/bin/env python3
"""Convert a binary P6 PPM to PNG. No third-party modules."""

import struct
import sys
import zlib


def read_ppm(path):
    data = open(path, "rb").read()
    if not data.startswith(b"P6"):
        raise SystemExit("not a binary PPM")
    i = 2
    toks = []
    while len(toks) < 3:
        while i < len(data) and data[i] in b" \t\r\n":
            i += 1
        if i < len(data) and data[i] == ord("#"):
            while i < len(data) and data[i] not in b"\r\n":
                i += 1
            continue
        start = i
        while i < len(data) and data[i] not in b" \t\r\n":
            i += 1
        toks.append(data[start:i])
    w, h, maxval = (int(t) for t in toks)
    if maxval != 255:
        raise SystemExit("only maxval 255")
    if i < len(data) and data[i] in b" \t\r\n":
        i += 1
    raw = data[i:]
    if len(raw) < w * h * 3:
        raise SystemExit("truncated PPM")
    return w, h, raw[: w * h * 3]


def chunk(tag, payload):
    return (
        struct.pack(">I", len(payload))
        + tag
        + payload
        + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
    )


def write_png(path, w, h, rgb):
    rows = b"".join(
        b"\x00" + rgb[y * w * 3 : (y + 1) * w * 3] for y in range(h)
    )
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(rows, 9))
    png += chunk(b"IEND", b"")
    open(path, "wb").write(png)


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: ppm2png.py in.ppm out.png")
    w, h, rgb = read_ppm(sys.argv[1])
    write_png(sys.argv[2], w, h, rgb)
    print(f"wrote {sys.argv[2]} ({w}x{h})")


if __name__ == "__main__":
    main()
