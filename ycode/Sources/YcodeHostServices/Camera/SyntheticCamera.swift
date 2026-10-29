// The synthetic camera (camera-host.md §7): a test pattern behind the same
// interface as a V4L2 device, for tests and for hosts without a camera.
// It sends YUYV, video range, BT.601 (what a webcam sends), so its frames
// take the same conversion path as a real camera's.

import CYcodeCamera
import Foundation

/// A source of raw frames (a V4L2 device or the synthetic pattern), pulled
/// by the camera service's capture thread.
public protocol CameraCapture: AnyObject, Sendable {
    var device: CameraDevice { get }
    /// What the open stream delivers.
    var format: CameraStreamFormat { get }
    /// The next frame, or nil when none came within the timeout. Throws
    /// `CameraError` with code `.gone` when the device went away.
    func next(timeoutMilliseconds: Int) throws -> CameraRawFrame?
    /// Gives a frame's buffer back (after conversion).
    func recycle(_ frame: CameraRawFrame)
    /// Stops streaming and releases the device.
    func close()
}

public final class SyntheticCamera: CameraCapture, @unchecked Sendable {
    /// The synthetic device as `CameraHostService.devices` lists it.
    public static let device: CameraDevice = {
        let sizes = [(320, 240), (640, 480), (1280, 720), (1920, 1080)].map {
            CameraFrameSize(width: $0.0, height: $0.1, intervals: [CameraFrameInterval(numerator: 1, denominator: 60),
                                                                  CameraFrameInterval(numerator: 1, denominator: 30),
                                                                  CameraFrameInterval(numerator: 1, denominator: 15)])
        }
        return CameraDevice(id: "synthetic", kind: .synthetic, name: "Ycode Synthetic Camera", path: nil, driver: "ycode",
                            busInfo: "synthetic", formats: [CameraFormatDescription(format: .yuyv, name: "YUYV 4:2:2", sizes: sizes)])
    }()

    public let device: CameraDevice = SyntheticCamera.device
    public let format: CameraStreamFormat
    /// Sleep until each frame's time (a live stream); off for tests.
    public let paced: Bool
    public let width: Int, height: Int
    public let bytesPerLine: Int
    private let start: Int64
    private var frameNumber: UInt32
    private let background: [UInt8]
    private let buffer: UnsafeMutablePointer<UInt8>
    private var closed = false

    /// `width` and `height` are rounded down to even numbers (at least
    /// 64 x 48).
    public init(width: Int, height: Int, interval: CameraFrameInterval = CameraFrameInterval(numerator: 1, denominator: 30),
                output: CameraPixelFormat = .biPlanar420Video, paced: Bool = true, firstFrame: UInt32 = 0,
                startTime: Int64? = nil) {
        let w = max(64, width & ~1), h = max(48, height & ~1)
        self.width = w
        self.height = h
        bytesPerLine = w * 2
        self.paced = paced
        frameNumber = firstFrame
        start = startTime ?? ycam_monotonic_ns()
        format = CameraStreamFormat(source: .yuyv, width: w, height: h, interval: interval, colorimetry: .video601, output: output)
        background = Self.renderBackground(width: w, height: h)
        buffer = .allocate(capacity: w * h * 2)
    }

    deinit { buffer.deallocate() }

    // MARK: Pattern geometry (§7.1)

    /// 75 % colour bars (R, G, B at 0 or 191): white, yellow, cyan, green,
    /// magenta, red, blue, black.
    public static let bars: [(r: Int, g: Int, b: Int)] = [(191, 191, 191), (191, 191, 0), (0, 191, 191), (0, 191, 0),
                                                         (191, 0, 191), (191, 0, 0), (0, 0, 191), (0, 0, 0)]

    /// BT.601 video-range Y'CbCr of an R'G'B' colour (0...255), rounded.
    public static func ycbcr(r: Int, g: Int, b: Int) -> (y: UInt8, cb: UInt8, cr: UInt8) {
        let (R, G, B) = (Double(r) / 255, Double(g) / 255, Double(b) / 255)
        let y = 0.299 * R + 0.587 * G + 0.114 * B
        let cb = (B - y) / 1.772, cr = (R - y) / 1.402
        return (UInt8((16 + 219 * y).rounded()), UInt8((128 + 224 * cb).rounded()), UInt8((128 + 224 * cr).rounded()))
    }

    /// The rows of the bars (from 0), of the grey ramp, and of the counter strip.
    public static func regions(height h: Int) -> (barsEnd: Int, stripTop: Int) {
        let strip = max(4, (h / 24) & ~1)
        return ((h * 2 / 3) & ~1, h - strip)
    }

    /// The moving box: its side and its left edge in frame `n` (it moves
    /// across the bars and back).
    public static func box(frame n: UInt32, width w: Int, height h: Int) -> (x: Int, y: Int, side: Int) {
        let side = max(8, (h / 6) & ~1)
        let travel = max(2, w - side)
        let speed = max(2, (w / 64) & ~1)
        let period = 2 * travel
        let p = Int(UInt64(n) * UInt64(speed) % UInt64(period))
        let x = (p < travel ? p : period - p) & ~1
        let barsEnd = regions(height: h).barsEnd
        return (x, max(0, (barsEnd - side) / 2) & ~1, side)
    }

    /// The counter strip has 32 cells, most significant bit first: luma 235
    /// for 1, 16 for 0.
    public static let counterCells = 32

    private static func renderBackground(width w: Int, height h: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: w * h * 2)
        let (barsEnd, stripTop) = regions(height: h)
        let colours = bars.map { ycbcr(r: $0.r, g: $0.g, b: $0.b) }
        let barWidth = w / 8
        for y in 0..<h {
            for x in stride(from: 0, to: w, by: 2) {
                let at = (y * w + x) * 2
                var y0: UInt8, y1: UInt8, cb: UInt8 = 128, cr: UInt8 = 128
                if y < barsEnd {
                    let c = colours[min(7, x / barWidth)]
                    (y0, y1, cb, cr) = (c.y, c.y, c.cb, c.cr)
                } else if y < stripTop {
                    y0 = UInt8(16 + 219 * x / (w - 1))
                    y1 = UInt8(16 + 219 * (x + 1) / (w - 1))
                } else {
                    (y0, y1) = (16, 16)
                }
                (b[at], b[at + 1], b[at + 2], b[at + 3]) = (y0, cb, y1, cr)
            }
        }
        return b
    }

    /// 3 x 5 digit glyphs, one row per 3 bits (bit 2 = left column).
    static let glyphs: [[UInt8]] = [
        [7, 5, 5, 5, 7], [2, 6, 2, 2, 7], [7, 1, 7, 4, 7], [7, 1, 7, 1, 7], [5, 5, 7, 1, 1],
        [7, 4, 7, 1, 7], [7, 4, 7, 5, 7], [7, 1, 1, 1, 1], [7, 5, 7, 5, 7], [7, 5, 7, 1, 7],
    ]

    /// Renders frame `n` into `bytes` (YUYV, `width * 2` bytes per row).
    public func render(frame n: UInt32, into bytes: UnsafeMutablePointer<UInt8>) {
        let w = width, h = height
        background.withUnsafeBufferPointer { _ = memcpy(bytes, $0.baseAddress!, $0.count) }
        func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ luma: UInt8) {
            let xa = max(0, x0), xb = min(w, x1), ya = max(0, y0), yb = min(h, y1)
            guard xa < xb, ya < yb else { return }
            for y in ya..<yb {
                let row = bytes + y * w * 2
                for x in xa..<xb { row[2 * x] = luma }
                for x in stride(from: xa & ~1, to: xb, by: 2) {
                    row[2 * x + 1] = 128
                    row[2 * x + 3] = 128
                }
            }
        }
        // The moving box.
        let box = Self.box(frame: n, width: w, height: h)
        fill(box.x, box.y, box.x + box.side, box.y + box.side, 235)
        // The frame number in decimal, top left, white on black.
        let k = max(2, h / 48)
        let digits = Array(String(n % 100_000_000))
        fill(k, k, k + (digits.count * 4 + 1) * k, k + 7 * k, 16)
        for (i, ch) in digits.enumerated() {
            let glyph = Self.glyphs[Int(ch.asciiValue! - 48)]
            for (gy, bits) in glyph.enumerated() {
                for gx in 0..<3 where bits & (4 >> gx) != 0 {
                    let x = k * 2 + (i * 4 + gx) * k, y = k * 2 + gy * k
                    fill(x, y, x + k, y + k, 235)
                }
            }
        }
        // The counter strip.
        let stripTop = Self.regions(height: h).stripTop
        let cell = w / Self.counterCells
        for i in 0..<Self.counterCells where (n >> UInt32(Self.counterCells - 1 - i)) & 1 != 0 {
            fill(i * cell, stripTop, (i + 1) * cell, h, 235)
        }
    }

    /// Reads the counter strip back from any image's luma (or a grey
    /// channel): `luma(x, y)`. Nil when the strip is not two-level.
    public static func readCounter(width w: Int, height h: Int, luma: (Int, Int) -> UInt8) -> UInt32? {
        let stripTop = regions(height: h).stripTop
        let y = (stripTop + h) / 2, cell = w / counterCells
        var n: UInt32 = 0
        for i in 0..<counterCells {
            let v = luma(i * cell + cell / 2, y)
            guard v < 60 || v > 180 else { return nil }
            n = n << 1 | (v > 180 ? 1 : 0)
        }
        return n
    }

    // MARK: CameraCapture

    public func next(timeoutMilliseconds: Int) throws -> CameraRawFrame? {
        guard !closed else { throw CameraError(.gone, "synthetic camera closed") }
        let n = frameNumber
        let pts = start + Int64(n) * format.interval.nanoseconds
        if paced {
            let wait = pts - ycam_monotonic_ns()
            if wait > Int64(timeoutMilliseconds) * 1_000_000 {
                usleep(UInt32(timeoutMilliseconds) * 1000)
                return nil
            }
            if wait > 0 { usleep(UInt32(wait / 1000)) }
        }
        frameNumber &+= 1
        render(frame: n, into: buffer)
        let bytes = UnsafeRawBufferPointer(start: buffer, count: width * height * 2)
        return CameraRawFrame(format: .yuyv, width: width, height: height, bytesPerLine: bytesPerLine, bytes: bytes,
                              colorimetry: .video601, deviceSequence: n, timestamp: pts, synthetic: true, token: 0)
    }

    public func recycle(_ frame: CameraRawFrame) {}

    public func close() { closed = true }
}
