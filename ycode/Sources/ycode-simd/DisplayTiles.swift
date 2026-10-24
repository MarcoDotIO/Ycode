// The display server's pure parts (DisplayServer.swift; display-stream.md
// §4): the frame record, the client's mirror of the display with the tile
// comparison, tile encoding, and compressed PNG screenshots. Not tied to
// the VMM, so they build and are tested on every platform.

import CYcodeCodec
import Foundation
import YcodeDisplayStream
import YcodeHostServices

/// The frame record of the headless framebuffer library
/// (SimGuestFrameworks/SimFramebuffer/simframebuffer.c).
struct FrameRecord: Equatable {
    var surface: UInt32
    var frame: UInt64

    static func parse(_ text: Substring) -> FrameRecord? {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard let s = words.firstIndex(of: "surface"), s + 1 < words.count, let surface = UInt32(words[s + 1]) else { return nil }
        var frame: UInt64 = 0
        if let f = words.firstIndex(of: "frame"), f + 1 < words.count { frame = UInt64(words[f + 1]) ?? 0 }
        return FrameRecord(surface: surface, frame: frame)
    }
}

/// A rectangle in device pixels.
struct PixelRect: Equatable {
    var x: Int, y: Int, width: Int, height: Int
    var area: Int { width * height }
}

/// The client's copy of the display (device pixels, packed BGRA) and the
/// tile comparison against the presented surface (display-stream.md §4.2).
final class DisplayMirror: @unchecked Sendable {
    let width: Int, height: Int
    let tile: Int
    private(set) var pixels: UnsafeMutableRawPointer
    var stride: Int { width * 4 }

    init(width: Int, height: Int, tile: Int) {
        self.width = width
        self.height = height
        self.tile = tile
        pixels = UnsafeMutableRawPointer.allocate(byteCount: max(1, width * height * 4), alignment: 64)
        pixels.initializeMemory(as: UInt8.self, repeating: 0, count: width * height * 4)
    }

    deinit { pixels.deallocate() }

    /// Rectangles whose pixels differ from `source` (rows `bytesPerRow`
    /// apart), merged; their pixels are copied into the mirror. `full`:
    /// the whole image, whatever changed.
    func update(from source: UnsafeRawPointer, bytesPerRow: Int, full: Bool) -> [PixelRect] {
        let tilesX = (width + tile - 1) / tile, tilesY = (height + tile - 1) / tile
        var rects: [PixelRect] = []
        if full {
            rects = [PixelRect(x: 0, y: 0, width: width, height: height)]
        } else {
            var dirty = [Bool](repeating: false, count: tilesX * tilesY)
            var any = false
            for ty in 0..<tilesY {
                let y0 = ty * tile, y1 = min(height, y0 + tile)
                var left = tilesX
                for y in y0..<y1 where left > 0 {
                    let s = source + y * bytesPerRow, m = pixels + y * stride
                    if memcmp(s, m, stride) == 0 { continue }
                    for tx in 0..<tilesX where !dirty[ty * tilesX + tx] {
                        let x0 = tx * tile, w = min(width, x0 + tile) - x0
                        if memcmp(s + x0 * 4, m + x0 * 4, w * 4) != 0 {
                            dirty[ty * tilesX + tx] = true
                            left -= 1
                            any = true
                        }
                    }
                }
            }
            guard any else { return [] }
            rects = Self.merge(dirty: dirty, tilesX: tilesX, tilesY: tilesY, tile: tile, width: width, height: height)
        }
        for r in rects {
            for y in r.y..<(r.y + r.height) {
                memcpy(pixels + y * stride + r.x * 4, source + y * bytesPerRow + r.x * 4, r.width * 4)
            }
        }
        return rects
    }

    /// Dirty tiles → rectangles: runs per tile row (gaps of up to two tiles
    /// joined), runs with the same span in consecutive rows joined; many
    /// pieces, or most of the screen, become one bounding box.
    static func merge(dirty: [Bool], tilesX: Int, tilesY: Int, tile: Int, width: Int, height: Int) -> [PixelRect] {
        var done: [(x0: Int, x1: Int, y0: Int, y1: Int)] = []
        var open: [(x0: Int, x1: Int, y0: Int, y1: Int)] = []
        for ty in 0..<tilesY {
            var runs: [(Int, Int)] = []
            var tx = 0
            while tx < tilesX {
                guard dirty[ty * tilesX + tx] else { tx += 1; continue }
                var end = tx + 1
                while end < tilesX {
                    if dirty[ty * tilesX + end] { end += 1; continue }
                    if end + 1 < tilesX && dirty[ty * tilesX + end + 1] { end += 2; continue }
                    if end + 2 < tilesX && dirty[ty * tilesX + end + 2] { end += 3; continue }
                    break
                }
                runs.append((tx, end))
                tx = end
            }
            var next: [(x0: Int, x1: Int, y0: Int, y1: Int)] = []
            for (a, b) in runs {
                if let i = open.firstIndex(where: { $0.x0 == a && $0.x1 == b }) {
                    var r = open.remove(at: i)
                    r.y1 = ty + 1
                    next.append(r)
                } else {
                    next.append((a, b, ty, ty + 1))
                }
            }
            done += open
            open = next
        }
        done += open
        var rects = done.map { r in
            PixelRect(x: r.x0 * tile, y: r.y0 * tile, width: min(width, r.x1 * tile) - r.x0 * tile,
                      height: min(height, r.y1 * tile) - r.y0 * tile)
        }
        let area = rects.reduce(0) { $0 + $1.area }
        if rects.count > 24 || area * 10 > width * height * 6 {
            let x0 = rects.map(\.x).min()!, y0 = rects.map(\.y).min()!
            let x1 = rects.map { $0.x + $0.width }.max()!, y1 = rects.map { $0.y + $0.height }.max()!
            rects = [PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)]
        }
        return rects
    }
}

/// Encodes mirror rectangles into tiles (display-stream.md §4.3).
struct TileEncoder {
    var encoding: DisplayEncoding
    var quality: Int
    var downscale: Int
    private var scratch: [UInt8] = []

    /// Rectangles taller than this many stream rows are cut into bands of
    /// this height, encoded in parallel (and decodable in parallel by the
    /// viewer): a whole-screen change costs about a quarter of the time of
    /// one JPEG (display-stream.md §4.3).
    static let bandRows = 256
    /// At most this many bands are encoded at once.
    static let maxParallel = 4

    init(encoding: DisplayEncoding, quality: Int, downscale: Int) {
        self.encoding = encoding
        self.quality = quality
        self.downscale = downscale
    }

    /// `rects` cut into bands of at most `bandRows` stream rows (device rows
    /// a multiple of the tile size, so bands start on 32-pixel stream rows).
    static func bands(_ rects: [PixelRect], downscale f: Int, bandRows: Int = TileEncoder.bandRows) -> [PixelRect] {
        let band = bandRows * f
        var out: [PixelRect] = []
        for r in rects {
            if r.height <= band { out.append(r); continue }
            var y = r.y
            while y < r.y + r.height {
                // Align the cuts to multiples of `band` from the image top.
                let next = min(r.y + r.height, (y / band + 1) * band)
                out.append(PixelRect(x: r.x, y: y, width: r.width, height: next - y))
                y = next
            }
        }
        return out
    }

    /// Encodes every rectangle, banded, on up to `maxParallel` threads; the
    /// tiles come back in order. Nil entries (encoder failures) are dropped.
    func encodeAll(_ rects: [PixelRect], mirror: DisplayMirror) -> [DisplayTile] {
        let pieces = Self.bands(rects, downscale: downscale)
        if pieces.count == 1 {
            var e = self
            return e.encode(pieces[0], mirror: mirror).map { [$0] } ?? []
        }
        let results = BandResults(count: pieces.count)
        let workers = min(Self.maxParallel, pieces.count)
        let me = self
        DispatchQueue.concurrentPerform(iterations: workers) { w in
            var e = me
            var i = w
            while i < pieces.count {
                // Each band reads only its own rows of the mirror and writes only its own slot.
                results.set(i, e.encode(pieces[i], mirror: mirror))
                i += workers
            }
        }
        return results.tiles
    }

    /// One slot per band, filled by the encoding threads.
    private final class BandResults: @unchecked Sendable {
        private var slots: [DisplayTile?]
        private let lock = NSLock()
        init(count: Int) { slots = [DisplayTile?](repeating: nil, count: count) }
        func set(_ i: Int, _ t: DisplayTile?) { lock.withLock { slots[i] = t } }
        var tiles: [DisplayTile] { lock.withLock { slots.compactMap { $0 } } }
    }

    mutating func encode(_ r: PixelRect, mirror: DisplayMirror) -> DisplayTile? {
        let f = downscale
        let ox = r.x / f, oy = r.y / f
        let ow = (r.x + r.width + f - 1) / f - ox, oh = (r.y + r.height + f - 1) / f - oy
        let source = UnsafeRawPointer(mirror.pixels) + r.y * mirror.stride + r.x * 4
        var data: [UInt8]?
        let packedCount = ow * oh * 4
        let needsPacked = f != 1 || encoding == .zlibBGRA
        if needsPacked && scratch.count < packedCount { scratch = [UInt8](repeating: 0, count: packedCount) }
        scratch.withUnsafeMutableBytes { tmp in
            let base: UnsafeRawPointer
            let bpr: Int
            if needsPacked {
                ycodec_downscale_bgra(source.assumingMemoryBound(to: UInt8.self), mirror.stride, Int32(r.width), Int32(r.height),
                                      Int32(f), tmp.baseAddress!.assumingMemoryBound(to: UInt8.self), ow * 4)
                base = UnsafeRawPointer(tmp.baseAddress!)
                bpr = ow * 4
            } else {
                base = source
                bpr = mirror.stride
            }
            switch encoding {
            case .jpeg:
                var out: UnsafeMutablePointer<UInt8>?
                var size = 0
                if ycodec_jpeg_encode_bgra(base.assumingMemoryBound(to: UInt8.self), Int32(ow), Int32(oh), bpr, Int32(quality),
                                           &out, &size) == 0, let out {
                    data = Array(UnsafeBufferPointer(start: out, count: size))
                    ycodec_free(out)
                }
            case .zlibBGRA:
                var cap = ycodec_zlib_bound(packedCount)
                guard cap > 0 else { return }
                var out = [UInt8](repeating: 0, count: cap)
                if out.withUnsafeMutableBufferPointer({
                    ycodec_zlib_compress(base.assumingMemoryBound(to: UInt8.self), packedCount, 1, $0.baseAddress, &cap)
                }) == 0 {
                    out.removeSubrange(cap...)
                    data = out
                }
            }
        }
        guard let data else { return nil }
        return DisplayTile(x: ox, y: oy, width: ow, height: oh, data: data)
    }
}

/// PNG with zlib compression (screenshots for the viewer).
enum CompressedPNG {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

    static func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let body = Array(type.utf8) + data
        return be32(UInt32(data.count)) + body + be32(crc(body))
    }

    /// RGBA → PNG; falls back to the uncompressed writer without zlib.
    static func encode(width: Int, height: Int, rgba: [UInt8]) -> [UInt8] {
        guard ycodec_zlib_available() != 0 else { return PNG.encode(width: width, height: height, rgba: rgba) }
        var raw = [UInt8]()
        raw.reserveCapacity((width * 4 + 1) * height)
        for y in 0..<height {
            raw.append(0)
            raw += rgba[(y * width * 4)..<((y + 1) * width * 4)]
        }
        var cap = ycodec_zlib_bound(raw.count)
        var z = [UInt8](repeating: 0, count: cap)
        let ok = z.withUnsafeMutableBufferPointer { ycodec_zlib_compress(raw, raw.count, 6, $0.baseAddress, &cap) } == 0
        guard ok else { return PNG.encode(width: width, height: height, rgba: rgba) }
        z.removeSubrange(cap...)
        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        out += chunk("IHDR", be32(UInt32(width)) + be32(UInt32(height)) + [8, 6, 0, 0, 0])
        out += chunk("IDAT", z)
        out += chunk("IEND", [])
        return out
    }
}

