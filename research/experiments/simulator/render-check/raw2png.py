#!/usr/bin/env python3
"""raw2png: convert a captured surface dump to PNG (Ycode research R6, original code).

Usage: python3 -I raw2png.py <name>.raw [out.png]
Reads <name>.txt (key=value: width, height, bytes_per_row, pixel_format) next to the
.raw file. Only pixel format 0x42475241 ('BGRA', 4 bytes per pixel, byte order B,G,R,A
in memory) is handled. Writes an 8-bit RGB PNG (alpha dropped: the display buffer is
opaque) with the standard library only (zlib). Prints a short pixel summary.
"""
import struct, sys, zlib

def header(path):
    h = {}
    for line in open(path):
        if '=' in line:
            k, v = line.strip().split('=', 1)
            h[k] = v
    return h

def png_chunk(kind, data):
    c = struct.pack('>I', len(data)) + kind + data
    return c + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)

def main():
    raw = sys.argv[1]
    base = raw[:-4] if raw.endswith('.raw') else raw
    out = sys.argv[2] if len(sys.argv) > 2 else base + '.png'
    h = header(base + '.txt')
    w, ht, bpr = int(h['width']), int(h['height']), int(h['bytes_per_row'])
    fmt = int(h['pixel_format'], 16)
    if fmt != 0x42475241:
        sys.exit('unsupported pixel format 0x%08x' % fmt)
    buf = open(raw, 'rb').read()
    if len(buf) < bpr * ht:
        sys.exit('short dump: %d < %d' % (len(buf), bpr * ht))
    rows = bytearray()
    nonblack = 0
    colors = set()
    for y in range(ht):
        row = buf[y * bpr: y * bpr + w * 4]
        rgb = bytearray(w * 3)
        rgb[0::3] = row[2::4]
        rgb[1::3] = row[1::4]
        rgb[2::3] = row[0::4]
        rows += b'\x00' + rgb
        if y % 8 == 0:
            for x in range(0, w, 8):
                p = row[x * 4: x * 4 + 3]
                if p != b'\x00\x00\x00':
                    nonblack += 1
                if len(colors) < 100000:
                    colors.add(bytes(p))
    png = b'\x89PNG\r\n\x1a\n' + png_chunk(b'IHDR', struct.pack('>IIBBBBB', w, ht, 8, 2, 0, 0, 0))
    png += png_chunk(b'IDAT', zlib.compress(bytes(rows), 6)) + png_chunk(b'IEND', b'')
    open(out, 'wb').write(png)
    samples = ((ht + 7) // 8) * ((w + 7) // 8)
    print('%s: %dx%d bpr %d surface %s seed %s frame %s; sampled %d px, non-black %d, distinct colours %d'
          % (out, w, ht, bpr, h.get('surface_id'), h.get('seed'), h.get('frame_seq'), samples, nonblack, len(colors)))

if __name__ == '__main__':
    main()
