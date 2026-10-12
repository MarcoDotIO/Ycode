#!/usr/bin/env python3
"""pngdiff: compare two 8-bit PNGs of the same size (Ycode research R6, original code).

Usage: python3 -I pngdiff.py a.png b.png [x,y ...]
Decodes non-interlaced 8-bit RGB/RGBA PNGs with the standard library, prints the
pixel at each given point (default: centre), the mean absolute difference per
channel, and the share of pixels that differ by more than 8 in any channel.
"""
import struct, sys, zlib

def load(path):
    d = open(path, 'rb').read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n', path
    pos, idat = 8, b''
    while pos < len(d):
        n, kind = struct.unpack('>I4s', d[pos:pos + 8])
        body = d[pos + 8: pos + 8 + n]
        if kind == b'IHDR':
            w, h, depth, ctype, _, _, inter = struct.unpack('>IIBBBBB', body)
        elif kind == b'IDAT':
            idat += body
        pos += 12 + n
    assert depth == 8 and ctype in (2, 6) and inter == 0, (path, depth, ctype, inter)
    bpp = 3 if ctype == 2 else 4
    raw = zlib.decompress(idat)
    stride = w * bpp
    out = bytearray(h * stride)
    prev = bytearray(stride)
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1: (y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return w, h, bpp, out

def px(img, x, y):
    w, h, bpp, d = img
    o = (y * w + x) * bpp
    return tuple(d[o:o + 3])

def main():
    A, B = load(sys.argv[1]), load(sys.argv[2])
    if A[:2] != B[:2]:
        sys.exit('sizes differ: %s vs %s' % (A[:2], B[:2]))
    w, h = A[:2]
    pts = [tuple(map(int, p.split(','))) for p in sys.argv[3:]] or [(w // 2, h // 2)]
    for x, y in pts:
        print('(%d,%d): %s vs %s' % (x, y, px(A, x, y), px(B, x, y)))
    tot, diff, n = [0, 0, 0], 0, 0
    for y in range(0, h, 2):
        for x in range(0, w, 2):
            a, b = px(A, x, y), px(B, x, y)
            dd = [abs(a[i] - b[i]) for i in range(3)]
            for i in range(3): tot[i] += dd[i]
            diff += max(dd) > 8
            n += 1
    print('mean abs diff RGB %.2f %.2f %.2f; pixels differing >8: %.2f%% (every 2nd pixel sampled)'
          % (tot[0] / n, tot[1] / n, tot[2] / n, 100.0 * diff / n))

if __name__ == '__main__':
    main()
