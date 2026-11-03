// The stream image a portable viewer draws into (display-stream.md §4.3):
// device pixels / downscale, BGRX in memory (byte 0 blue; the fourth byte
// is opaque), top row first. JPEG tiles are decoded by CYcodeCodec (the
// system's libjpeg, loaded at run time) straight into the canvas, zlib
// tiles are inflated into it; tiles never overlap, so a frame's tiles are
// decoded in parallel. The canvas keeps the union of the rectangles
// written since the front end last took it, so a window uploads only what
// changed.

import CYcodeCodec
import CYcodeVideo
import Foundation
import YcodeDisplayStream

/// A rectangle in stream-image pixels.
public struct PixelRect: Equatable, Sendable {
    public var x: Int, y: Int, width: Int, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) { (self.x, self.y, self.width, self.height) = (x, y, width, height) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public func union(_ o: PixelRect) -> PixelRect {
        if isEmpty { return o }
        if o.isEmpty { return self }
        let x0 = min(x, o.x), y0 = min(y, o.y)
        let x1 = max(x + width, o.x + o.width), y1 = max(y + height, o.y + o.height)
        return PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

public final class StreamCanvas: @unchecked Sendable {
    /// What the canvas holds: BGRX pixels (tiles) or the last decoded video
    /// picture as planes (§14; NV12, which the window shows without
    /// converting, or planar 4:4:4).
    public enum Format: Sendable { case bgrx, nv12, yuv444 }
    /// A decoded video picture: `u` is the interleaved chroma of NV12, `v` nil then.
    public struct VideoPlanes {
        public var format: Format
        public var y: UnsafePointer<UInt8>, u: UnsafePointer<UInt8>, v: UnsafePointer<UInt8>?
        public var pitch: Int
    }
    public let width: Int, height: Int
    public private(set) var format = Format.bgrx
    private var decoder: OpaquePointer?
    private var decoderEncoding: DisplayEncoding?
    private var planes: VideoPlanes?
    /// The planes were converted into `memory` since they arrived.
    private var planesConverted = false
    public let bytesPerRow: Int
    /// The pixels (BGRX). Read them only under `withPixels`.
    private let memory: UnsafeMutableRawPointer
    private let lock = NSLock()
    private var dirty = PixelRect(x: 0, y: 0, width: 0, height: 0)

    public init?(width: Int, height: Int) {
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { return nil }
        self.width = width
        self.height = height
        bytesPerRow = width * 4
        memory = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * height, alignment: 64)
        // Opaque black.
        let words = memory.bindMemory(to: UInt32.self, capacity: width * height)
        words.initialize(repeating: 0xFF00_0000, count: width * height)
        dirty = PixelRect(x: 0, y: 0, width: width, height: height)
    }

    deinit {
        memory.deallocate()
        if let decoder { yvid_dec_close(decoder) }
    }

    /// Whether this host can decode an encoding (JPEG needs libjpeg at build
    /// and run time, zlib needs libz at run time, video NVDEC for that codec).
    public static func canDecode(_ e: DisplayEncoding) -> Bool { decodeProblem(e) == nil }

    /// Why this host cannot decode an encoding (nil: it can).
    public static func decodeProblem(_ e: DisplayEncoding) -> String? {
        func video(_ codec: Int32, _ yuv444: Int32, _ what: String) -> String? {
            guard yvid_dec_available() != 0 else { return "no NVDEC here (libnvcuvid or an NVIDIA GPU is missing)" }
            var caps = yvid_dec_caps()
            guard yvid_dec_query(codec, yuv444, 8, &caps) == 0 else { return "NVDEC's capabilities could not be read" }
            return caps.supported != 0 ? nil : "this GPU's NVDEC has no \(what)"
        }
        switch e {
        case .jpeg: return ycodec_jpeg_decode_available() != 0 ? nil : "JPEG is compiled out of this viewer (jpeglib.h was missing when it was built) or libjpeg is missing"
        case .zlibBGRA: return ycodec_zlib_available() != 0 ? nil : "libz is missing"
        case .h264: return video(Int32(YVID_H264), 0, "8-bit H.264 4:2:0")
        case .hevc: return video(Int32(YVID_HEVC), 0, "8-bit HEVC 4:2:0")
        case .hevc444: return video(Int32(YVID_HEVC), 1, "8-bit HEVC 4:4:4")
        }
    }

    /// The encodings this host decodes, in order of preference (a window
    /// shows NV12 on the GPU, so 4:4:4 is left to whoever asks for it).
    public static var decodableEncodings: [String] {
        [DisplayEncoding.hevc, .h264, .jpeg, .zlibBGRA].filter(canDecode).map(\.name)
    }

    /// Draws a frame's tiles; false when one was out of bounds or could not
    /// be decoded (the viewer then asks for a keyframe).
    public func apply(_ frame: DisplayFrame) -> Bool {
        guard frame.width == width, frame.height == height else { return false }
        if frame.encoding.isVideo { return applyVideo(frame) }
        let tiles = frame.tiles
        let results = UnsafeMutableBufferPointer<Bool>.allocate(capacity: max(tiles.count, 1))
        results.initialize(repeating: false)
        defer { results.deallocate() }
        // Addresses as integers: the closure runs on several threads, each
        // writing its own tile's rectangle and its own result slot.
        let baseBits = UInt(bitPattern: memory), outBits = UInt(bitPattern: results.baseAddress!)
        let row = bytesPerRow, w = width, h = height, encoding = frame.encoding
        let work: @Sendable (Int) -> Void = { i in
            let base = UnsafeMutableRawPointer(bitPattern: baseBits)!, out = UnsafeMutableRawPointer(bitPattern: outBits)!
            let t = tiles[i]
            guard t.width > 0, t.height > 0, t.x >= 0, t.y >= 0, t.x + t.width <= w, t.y + t.height <= h else { return }
            let dst = base + t.y * row + t.x * 4
            let ok = t.data.withUnsafeBufferPointer { src -> Bool in
                guard let s = src.baseAddress else { return false }
                switch encoding {
                case .jpeg:
                    return ycodec_jpeg_decode_bgra(s, src.count, Int32(t.width), Int32(t.height), dst.assumingMemoryBound(to: UInt8.self), row) == 0
                case .zlibBGRA:
                    return Self.inflate(s, src.count, into: dst, rowBytes: row, width: t.width, height: t.height)
                case .h264, .hevc, .hevc444:
                    return false  // whole pictures: applyVideo
                }
            }
            out.storeBytes(of: ok, toByteOffset: i * MemoryLayout<Bool>.stride, as: Bool.self)
        }
        lock.lock()
        // Tiles draw into the BGRX pixels again (a stream that left video).
        if planes != nil {
            convertPlanes()
            format = .bgrx
            planes = nil
        }
        if tiles.count == 1 { work(0) } else if !tiles.isEmpty { DispatchQueue.concurrentPerform(iterations: tiles.count, execute: work) }
        for t in tiles { dirty = dirty.union(PixelRect(x: t.x, y: t.y, width: min(t.width, w - t.x), height: min(t.height, h - t.y))) }
        lock.unlock()
        return tiles.indices.allSatisfy { results[$0] }
    }

    /// A video access unit: decoded by NVDEC; the canvas then shows its planes.
    private func applyVideo(_ frame: DisplayFrame) -> Bool {
        guard let tile = frame.tiles.first, frame.tiles.count == 1 else { return false }
        lock.lock()
        defer { lock.unlock() }
        if decoder == nil || decoderEncoding != frame.encoding {
            if let decoder { yvid_dec_close(decoder) }
            let codec = frame.encoding == .h264 ? Int32(YVID_H264) : Int32(YVID_HEVC)
            decoder = yvid_dec_open2(codec, nil, 0)
            decoderEncoding = frame.encoding
        }
        guard let decoder else { return false }
        var pic = yvid_picture()
        let rc = tile.data.withUnsafeBufferPointer { yvid_dec_decode2(decoder, $0.baseAddress, $0.count, &pic) }
        if rc < 0 { return false }
        if rc == 1, let y = pic.y, let u = pic.u, Int(pic.width) == width, Int(pic.height) == height {
            let f: Format = pic.format == Int32(YVID_YUV444) ? .yuv444 : .nv12
            planes = VideoPlanes(format: f, y: y, u: u, v: pic.v, pitch: Int(pic.pitch))
            planesConverted = false
            format = f
            dirty = PixelRect(x: 0, y: 0, width: width, height: height)
        }
        return true
    }

    /// The planes into the BGRX memory, once per picture (on the CPU: screenshots,
    /// image checks and a stream that left video; not the display path).
    private func convertPlanes() {
        guard let p = planes, !planesConverted else { return }
        let dst = memory.assumingMemoryBound(to: UInt8.self)
        if p.format == .yuv444, let v = p.v {
            yvid_yuv444_to_bgrx(p.y, p.u, v, Int32(p.pitch), Int32(width), Int32(height), dst, bytesPerRow)
        } else {
            yvid_nv12_to_bgrx(p.y, p.u, Int32(p.pitch), Int32(width), Int32(height), dst, bytesPerRow)
        }
        planesConverted = true
    }

    /// Runs `body` with the NV12 planes of the last video picture and whether
    /// they changed since the last call (nil: no NV12 picture).
    public func withNV12<T>(_ body: (UnsafePointer<UInt8>, UnsafePointer<UInt8>, Int, Bool) -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let p = planes, p.format == .nv12 else { return nil }
        let changed = !dirty.isEmpty
        dirty = PixelRect(x: 0, y: 0, width: 0, height: 0)
        return body(p.y, p.u, p.pitch, changed)
    }

    /// Runs `body` with the last video picture's planes (nil: no video picture).
    public func withVideoPlanes<T>(_ body: (VideoPlanes, Bool) -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let p = planes else { return nil }
        let changed = !dirty.isEmpty
        dirty = PixelRect(x: 0, y: 0, width: 0, height: 0)
        return body(p, changed)
    }

    /// One pixel as blue, green, red, whatever the canvas holds. Cheap for a
    /// few thousand samples, where converting a whole picture would stall the caller.
    public func samplesBGR(_ points: [(x: Int, y: Int)]) -> [(UInt8, UInt8, UInt8)] {
        lock.lock()
        defer { lock.unlock() }
        func clamp(_ v: Int) -> UInt8 { UInt8(max(0, min(255, v))) }
        return points.map { point in
            let x = min(width - 1, max(0, point.x)), y = min(height - 1, max(0, point.y))
            guard let p = planes else {
                let o = memory.assumingMemoryBound(to: UInt8.self) + y * bytesPerRow + x * 4
                return (o[0], o[1], o[2])
            }
            let c = Int(p.y[y * p.pitch + x]) - 16
            let d: Int, e: Int
            if p.format == .yuv444, let v = p.v {
                d = Int(p.u[y * p.pitch + x]) - 128
                e = Int(v[y * p.pitch + x]) - 128
            } else {
                d = Int(p.u[(y / 2) * p.pitch + (x & ~1)]) - 128
                e = Int(p.u[(y / 2) * p.pitch + (x & ~1) + 1]) - 128
            }
            return (clamp((298 * c + 541 * d + 128) >> 8), clamp((298 * c - 55 * d - 136 * e + 128) >> 8), clamp((298 * c + 459 * e + 128) >> 8))
        }
    }

    private static func inflate(_ src: UnsafePointer<UInt8>, _ n: Int, into dst: UnsafeMutableRawPointer, rowBytes: Int,
                                width: Int, height: Int) -> Bool {
        let count = width * height * 4
        if rowBytes == width * 4 {
            var size = count
            return ycodec_zlib_uncompress(src, n, dst.assumingMemoryBound(to: UInt8.self), &size) == 0 && size == count
        }
        let tmp = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { tmp.deallocate() }
        var size = count
        guard ycodec_zlib_uncompress(src, n, tmp, &size) == 0, size == count else { return false }
        for r in 0..<height { memcpy(dst + r * rowBytes, tmp + r * width * 4, width * 4) }
        return true
    }

    /// Runs `body` with the pixels and the rectangle changed since the last
    /// call (empty: nothing), then clears it.
    public func withPixels<T>(_ body: (UnsafeRawPointer, Int, PixelRect) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        convertPlanes()
        let d = dirty
        dirty = PixelRect(x: 0, y: 0, width: 0, height: 0)
        return body(UnsafeRawPointer(memory), bytesPerRow, d)
    }

    /// Marks everything changed (a new texture must get all of it).
    public func invalidate() { lock.withLock { dirty = PixelRect(x: 0, y: 0, width: width, height: height) } }

    /// A copy of the pixels as RGBA rows (for PNGs and image checks).
    public func rgba() -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        var out = [UInt8](repeating: 0, count: width * height * 4)
        convertPlanes()
        let src = memory.assumingMemoryBound(to: UInt8.self)
        out.withUnsafeMutableBufferPointer { d in
            for i in 0..<(width * height) {
                d[i * 4] = src[i * 4 + 2]
                d[i * 4 + 1] = src[i * 4 + 1]
                d[i * 4 + 2] = src[i * 4]
                d[i * 4 + 3] = 0xFF
            }
        }
        return out
    }

    /// Grey samples of the image on a grid (rows × columns), 0–255: what
    /// the script's `wait-home` and `wait-change` look at.
    public func greySamples(rows: Int = 64, columns: Int = 48) -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        let src = memory.assumingMemoryBound(to: UInt8.self)
        var out: [UInt8] = []
        out.reserveCapacity(rows * columns)
        if let p = planes {
            // The luma plane is the grey image (video range, close enough for the checks).
            for r in 0..<rows {
                let y = min(height - 1, (2 * r + 1) * height / (2 * rows))
                for c in 0..<columns { out.append(p.y[y * p.pitch + min(width - 1, (2 * c + 1) * width / (2 * columns))]) }
            }
            return out
        }
        for r in 0..<rows {
            let y = min(height - 1, (2 * r + 1) * height / (2 * rows))
            for c in 0..<columns {
                let x = min(width - 1, (2 * c + 1) * width / (2 * columns))
                let p = src + y * bytesPerRow + x * 4
                out.append(UInt8((UInt32(p[0]) * 29 + UInt32(p[1]) * 150 + UInt32(p[2]) * 77) >> 8))
            }
        }
        return out
    }
}

/// Image checks of the script commands (display-stream.md §7).
public enum ImageChecks {
    /// A lit screen: less than 90 % of the samples darker than 24.
    public static func isLit(_ samples: [UInt8]) -> Bool {
        guard !samples.isEmpty else { return false }
        let dark = samples.filter { $0 < 24 }.count
        return Double(dark) < 0.9 * Double(samples.count)
    }

    /// The share (0–100) of samples that differ by more than 24 levels.
    public static func changedPercent(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 100 }
        let n = zip(a, b).filter { abs(Int($0) - Int($1)) > 24 }.count
        return 100 * Double(n) / Double(a.count)
    }
}
