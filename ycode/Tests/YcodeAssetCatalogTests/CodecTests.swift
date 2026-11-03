import Foundation
import Testing
@testable import YcodeAssetCatalog
#if canImport(Compression)
import Compression
#endif
#if canImport(ImageIO)
import ImageIO
#endif

/// The codecs under the car writer: LZFSE (LZVN blocks), zlib/DEFLATE and
/// PNG. On macOS the system decoders check that our streams are standard.
struct CodecTests {
    static func samples() -> [[UInt8]] {
        var rng = SystemRandomNumberGenerator()
        let random = (0..<5000).map { _ in UInt8.random(in: 0...255, using: &rng) }
        var pixels: [UInt8] = []
        for i in 0..<(64 * 64) {
            let r = UInt8(i % 7 * 30), b = UInt8(i / 64 * 4)
            pixels += [r, 40, b, 255]
        }
        let text = Array(String(repeating: "the quick brown fox jumps over the lazy dog ", count: 200).utf8)
        let farRepeat = random + [UInt8](repeating: 9, count: 3000) + random + Array(random[100..<1600])
        let solid = [UInt8](repeating: 0x7F, count: 300_000)
        return [[], [1], [1, 2, 3], random, pixels, text, farRepeat, solid, Array(random.prefix(40)) + Array(random.prefix(40))]
    }

    @Test func lzfseRoundTripsThroughOurDecoder() throws {
        for s in Self.samples() {
            let e = LZFSE.encode(s)
            #expect(Array(e.suffix(4)) == Array("bvx$".utf8))
            #expect(try LZFSE.decode(e[...], expectedSize: s.count) == s)
        }
    }

    @Test func repetitiveDataIsCompressed() {
        let solid = [UInt8](repeating: 0x7F, count: 1024 * 1024 * 4 / 3)
        let e = LZFSE.encode(solid)
        #expect(Array(e.prefix(4)) == Array("bvxn".utf8))
        #expect(e.count < solid.count / 50)
    }

    #if canImport(Compression)
    @Test func systemDecoderReadsOurLZFSE() {
        for s in Self.samples() where !s.isEmpty {
            let e = LZFSE.encode(s)
            var out = [UInt8](repeating: 0, count: s.count + 64)
            let n = out.withUnsafeMutableBufferPointer { o in
                e.withUnsafeBufferPointer { compression_decode_buffer(o.baseAddress!, o.count, $0.baseAddress!, e.count, nil, COMPRESSION_LZFSE) }
            }
            #expect(n == s.count)
            #expect(Array(out.prefix(n)) == s)
        }
    }

    /// Mixed data (runs, repeats at every distance, random bytes) from a
    /// fixed seed, through the system decoder.
    @Test func systemDecoderReadsOurLZFSEOnMixedData() {
        var seed: UInt64 = 0x5EED
        func next(_ n: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(n))
        }
        for _ in 0..<40 {
            var s: [UInt8] = []
            let target = 10 + next(70_000)
            while s.count < target {
                switch next(4) {
                case 0: s += (0..<(1 + next(50))).map { _ in UInt8(next(256)) }
                case 1: s += [UInt8](repeating: UInt8(next(4)), count: 1 + next(600))
                case 2 where s.count > 4:
                    let d = 1 + next(min(s.count, 70_000))
                    for _ in 0..<(1 + next(40)) { s.append(s[s.count - d]) }
                default: s += Array("abcab".utf8)
                }
            }
            let e = LZFSE.encode(s)
            var out = [UInt8](repeating: 0, count: s.count + 64)
            let n = out.withUnsafeMutableBufferPointer { o in
                e.withUnsafeBufferPointer { compression_decode_buffer(o.baseAddress!, o.count, $0.baseAddress!, e.count, nil, COMPRESSION_LZFSE) }
            }
            #expect(n == s.count && Array(out.prefix(n)) == s)
        }
    }

    @Test func ourDecoderReadsSystemLZFSE() throws {
        for s in Self.samples() where s.count > 100 {
            var out = [UInt8](repeating: 0, count: s.count + 4096)
            let n = out.withUnsafeMutableBufferPointer { o in
                s.withUnsafeBufferPointer { compression_encode_buffer(o.baseAddress!, o.count, $0.baseAddress!, s.count, nil, COMPRESSION_LZFSE) }
            }
            #expect(try LZFSE.decode(out[0..<n], expectedSize: s.count) == s)
        }
    }

    @Test func systemZlibReadsOurDeflate() throws {
        for s in Self.samples() {
            let z = Zlib.compress(s)
            // NSData's zlib algorithm is raw DEFLATE: drop the 2-byte header and the Adler-32.
            let raw = Data(z[2..<(z.count - 4)])
            let back = try (raw as NSData).decompressed(using: .zlib) as Data
            #expect([UInt8](back) == s)
        }
    }
    #endif

    @Test func zlibRoundTrips() throws {
        for s in Self.samples() { #expect(try Zlib.decompress(Zlib.compress(s)) == s) }
        #expect(Zlib.adler32(Array("Wikipedia".utf8)) == 0x11E6_0398)
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
    }

    #if canImport(Compression)
    @Test func inflateReadsTheSystemsDynamicHuffmanStreams() throws {
        let text = Data(String(repeating: "hello, asset catalog; ", count: 500).utf8 + Array(0...255))
        let raw = try (text as NSData).compressed(using: .zlib) as Data
        #expect(try Inflate.inflate([UInt8](raw), from: 0) == [UInt8](text))
    }
    #endif

    static func gradient(_ w: Int, _ h: Int, alpha: Bool) -> Bitmap {
        var px: [UInt8] = []
        for y in 0..<h {
            for x in 0..<w { px += [UInt8(x * 255 / max(w - 1, 1)), UInt8(y * 255 / max(h - 1, 1)), 128, alpha ? UInt8((x + y) % 256) : 255] }
        }
        return Bitmap(width: w, height: h, rgba: px)
    }

    @Test func pngRoundTrips() throws {
        for b in [Self.gradient(1, 1, alpha: false), Self.gradient(37, 19, alpha: true), Self.gradient(64, 64, alpha: false)] {
            #expect(try PNG.decode(PNG.encode(b)) == b)
            if b.isOpaque { #expect(try PNG.decode(PNG.encode(b, dropAlpha: true)) == b) }
        }
    }

    @Test func premultipliedBGRARoundTripsOpaquePixels() {
        let b = Self.gradient(16, 8, alpha: false)
        let p = b.premultipliedBGRA
        #expect(Array(p.prefix(4)) == [128, 0, 0, 255])
        #expect(Bitmap(width: 16, height: 8, premultipliedBGRA: p) == b)
        let half = Bitmap(width: 1, height: 1, rgba: [200, 100, 50, 128])
        #expect(half.premultipliedBGRA == [25, 50, 100, 128])
    }

    @Test func resizeAveragesWhenShrinking() {
        let b = Bitmap(width: 2, height: 2, rgba: [255, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255, 255, 0, 0, 255])
        let r = b.resized(width: 1, height: 1)
        #expect(r.rgba == [128, 0, 128, 255])
        #expect(Bitmap(width: 4, height: 4, fill: (0, 1, 0, 1)).resized(width: 9, height: 9) == Bitmap(width: 9, height: 9, fill: (0, 1, 0, 1)))
    }

    #if canImport(ImageIO)
    @Test func imageIOReadsOurPNGsAndWeReadImageIOs() throws {
        let b = Self.gradient(33, 21, alpha: false)
        let data = PNG.encode(b) as CFData
        let src = try #require(CGImageSourceCreateWithData(data, nil))
        let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(img.width == 33 && img.height == 21)
        // Draw it into a known RGBA buffer and compare.
        var px = [UInt8](repeating: 0, count: 33 * 21 * 4)
        let ok = px.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: 33, height: 21, bitsPerComponent: 8, bytesPerRow: 33 * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: 33, height: 21))
            return true
        }
        #expect(ok)
        #expect(px == b.rgba)
        // And the other way: ImageIO's PNG through our decoder.
        let out = NSMutableData()
        let dst = try #require(CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dst, img, nil)
        #expect(CGImageDestinationFinalize(dst))
        let back = try PNG.decode(out as Data)
        #expect(back.width == 33 && back.height == 21)
        #expect(back.rgba == b.rgba)
    }
    #endif

    @Test func palettedGrayAndInterlacedPNGsDecode() throws {
        func png(_ ihdr: [UInt8], _ extra: [(String, [UInt8])], _ raw: [UInt8]) -> Data {
            var w = ByteWriter()
            w.append(PNG.signature)
            func chunk(_ t: String, _ b: [UInt8]) {
                w.u32be(UInt32(b.count))
                w.append(Array(t.utf8))
                w.append(b)
                w.u32be(CRC32.checksum(Array(t.utf8) + b))
            }
            chunk("IHDR", ihdr)
            for (t, b) in extra { chunk(t, b) }
            chunk("IDAT", Zlib.compress(raw))
            chunk("IEND", [])
            return Data(w.bytes)
        }
        // 2×1 palette, 1 bit: indices 1, 0; palette red, blue; index 0 half transparent.
        let pal = try PNG.decode(png([0, 0, 0, 2, 0, 0, 0, 1, 1, 3, 0, 0, 0], [("PLTE", [255, 0, 0, 0, 0, 255]), ("tRNS", [128])], [0, 0b1000_0000]))
        #expect(pal.rgba == [0, 0, 255, 255, 255, 0, 0, 128])
        // 1×2 16-bit gray with alpha.
        let ga = try PNG.decode(png([0, 0, 0, 1, 0, 0, 0, 2, 16, 4, 0, 0, 0], [], [0, 0x80, 0, 0xFF, 0xFF, 0, 0x10, 0, 0, 0]))
        #expect(ga.rgba == [128, 128, 128, 255, 16, 16, 16, 0])
        // 3×3 RGB, Adam7: passes 1 (0,0), 6 (1,0), 7 rows 1 — build by the pass rules.
        var raw: [UInt8] = []
        func px(_ x: Int, _ y: Int) -> [UInt8] { [UInt8(x * 10), UInt8(y * 10), 7] }
        for (x0, y0, dx, dy) in [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)] {
            let xs = Array(stride(from: x0, to: 3, by: dx)), ys = Array(stride(from: y0, to: 3, by: dy))
            guard !xs.isEmpty else { continue }
            for y in ys { raw += [0] + xs.flatMap { px($0, y) } }
        }
        let il = try PNG.decode(png([0, 0, 0, 3, 0, 0, 0, 3, 8, 2, 0, 0, 1], [], raw))
        #expect(il.rgba == (0..<3).flatMap { y in (0..<3).flatMap { x in px(x, y) + [255] } })
    }
}
