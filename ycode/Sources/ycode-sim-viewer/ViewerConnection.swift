// The viewer's side of the display stream (specs/simulator/display-stream.md):
// connects (and reconnects) to the display server, decodes frame tiles into
// a canvas on its own thread, and hands finished images to the main thread.

#if os(macOS)
import AppKit
import Accelerate
import Compression
import Foundation
import ImageIO
import YcodeDisplayStream

/// The stream image the tiles are drawn into (BGRA, top row first in memory).
final class FrameCanvas: @unchecked Sendable {
    let width: Int, height: Int
    let context: CGContext

    init?(width: Int, height: Int) {
        guard width > 0, height > 0,
              let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        self.width = width
        self.height = height
        context = c
        c.setFillColor(gray: 0, alpha: 1)
        c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        c.interpolationQuality = .none
    }

    /// Draws one tile; false when it could not be decoded.
    func apply(_ tile: DisplayTile, encoding: DisplayEncoding) -> Bool {
        applyAll([tile], encoding: encoding)
    }

    /// Draws a frame's tiles; false when one could not be decoded. Tiles
    /// cover disjoint rectangles, so they are decoded and written into the
    /// canvas memory in parallel (the server cuts tall changes into bands,
    /// display-stream.md §4.3); a JPEG whose decoded layout is not the
    /// usual 32-bit one is drawn through Core Graphics afterwards.
    func applyAll(_ tiles: [DisplayTile], encoding: DisplayEncoding) -> Bool {
        let ok = TileFlags(count: tiles.count)
        let fallback = FallbackImages(count: tiles.count)
        let work: @Sendable (Int) -> Void = { i in
            let tile = tiles[i]
            guard tile.width > 0, tile.height > 0, tile.x + tile.width <= self.width, tile.y + tile.height <= self.height else { return }
            switch encoding {
            case .jpeg:
                guard let image = Self.decodeJPEG(tile.data) else { return }
                if self.copyPixels(of: image, to: tile) { ok.set(i) } else { fallback.set(i, image) }
            case .zlibBGRA:
                if self.inflate(tile) { ok.set(i) }
            }
        }
        if tiles.count == 1 { work(0) } else { DispatchQueue.concurrentPerform(iterations: tiles.count, execute: work) }
        for (i, image) in fallback.images.enumerated() {
            guard let image else { continue }
            let t = tiles[i]
            context.draw(image, in: CGRect(x: t.x, y: height - t.y - t.height, width: t.width, height: t.height))
            ok.set(i)
        }
        return ok.all
    }

    static func decodeJPEG(_ data: [UInt8]) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(Data(data) as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Copies a decoded 8-bit, 32-bit-per-pixel RGB image into the canvas
    /// (BGRX) at the tile's place; false for any other layout.
    private func copyPixels(of image: CGImage, to tile: DisplayTile) -> Bool {
        guard image.width == tile.width, image.height == tile.height, image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              let base = context.data, let data = image.dataProvider?.data, let src = CFDataGetBytePtr(data) else { return false }
        let alpha = image.alphaInfo, order = image.bitmapInfo.intersection(.byteOrderMask)
        // Byte positions of B, G, R in one source pixel.
        let map: (Int, Int, Int)
        switch (alpha, order) {
        case (.noneSkipLast, .byteOrder32Big), (.noneSkipLast, []), (.premultipliedLast, .byteOrder32Big), (.premultipliedLast, []):
            map = (2, 1, 0)  // R G B X
        case (.noneSkipFirst, .byteOrder32Little), (.premultipliedFirst, .byteOrder32Little):
            map = (0, 1, 2)  // B G R X
        case (.noneSkipFirst, .byteOrder32Big), (.noneSkipFirst, []), (.premultipliedFirst, .byteOrder32Big), (.premultipliedFirst, []):
            map = (3, 2, 1)  // X R G B
        default:
            return false
        }
        let srcRow = image.bytesPerRow, dstRow = context.bytesPerRow
        let dst = base.assumingMemoryBound(to: UInt8.self)
        var sb = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src), height: vImagePixelCount(tile.height),
                               width: vImagePixelCount(tile.width), rowBytes: srcRow)
        var db = vImage_Buffer(data: dst + tile.y * dstRow + tile.x * 4, height: vImagePixelCount(tile.height),
                               width: vImagePixelCount(tile.width), rowBytes: dstRow)
        // The fourth byte (X) comes from the unused source byte: canvas alpha is skipped.
        let fourth = 6 - map.0 - map.1 - map.2
        let permute: [UInt8] = [UInt8(map.0), UInt8(map.1), UInt8(map.2), UInt8(fourth)]
        return vImagePermuteChannels_ARGB8888(&sb, &db, permute, vImage_Flags(kvImageDoNotTile)) == kvImageNoError
    }

    private func inflate(_ tile: DisplayTile) -> Bool {
        // zlib = 2-byte header + raw deflate + Adler-32; Compression's ZLIB is raw deflate.
        let count = tile.width * tile.height * 4
        guard tile.data.count > 6, let base = context.data else { return false }
        var pixels = [UInt8](repeating: 0, count: count)
        let n = tile.data.withUnsafeBufferPointer { src in
            compression_decode_buffer(&pixels, count, src.baseAddress! + 2, src.count - 6, nil, COMPRESSION_ZLIB)
        }
        guard n == count else { return false }
        let rowBytes = context.bytesPerRow
        pixels.withUnsafeBytes { p in
            for row in 0..<tile.height {
                memcpy(base + (tile.y + row) * rowBytes + tile.x * 4, p.baseAddress! + row * tile.width * 4, tile.width * 4)
            }
        }
        return true
    }

    func image() -> CGImage? { context.makeImage() }
}

/// Per-tile results, written by the decoding threads.
private final class TileFlags: @unchecked Sendable {
    private var flags: [Bool]
    private let lock = NSLock()
    init(count: Int) { flags = [Bool](repeating: false, count: count) }
    func set(_ i: Int) { lock.withLock { flags[i] = true } }
    var all: Bool { lock.withLock { !flags.contains(false) } }
}

private final class FallbackImages: @unchecked Sendable {
    private var slots: [CGImage?]
    private let lock = NSLock()
    init(count: Int) { slots = [CGImage?](repeating: nil, count: count) }
    func set(_ i: Int, _ image: CGImage) { lock.withLock { slots[i] = image } }
    var images: [CGImage?] { lock.withLock { slots } }
}

@MainActor
protocol ViewerConnectionDelegate: AnyObject {
    func connection(_ c: ViewerConnection, phase: String, detail: String?)
    func connection(_ c: ViewerConnection, hello: DisplayServerHello)
    func connection(_ c: ViewerConnection, status: DisplayStatus)
    func connection(_ c: ViewerConnection, image: CGImage, frame: DisplayFrame, receivedAt: UInt64)
    func connection(_ c: ViewerConnection, notice: String)
    func connection(_ c: ViewerConnection, screenshot png: [UInt8], token: UInt32)
    func connection(_ c: ViewerConnection, pongToken token: UInt64, rttMilliseconds: Double)
}

func nowNanoseconds() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

final class ViewerConnection: @unchecked Sendable {
    let address: DisplayAddress
    var settings: DisplayClientHello
    weak var delegate: ViewerConnectionDelegate?
    private let lock = NSLock()
    private var connection: DisplayConnection?
    private var stopped = false
    private var inputSequence: UInt32 = 0
    private var pings: [UInt64: UInt64] = [:]
    private var nextPing: UInt64 = 1
    /// The newest decoded image waiting for the main thread (under the lock).
    private var pending: (CGImage, DisplayFrame, UInt64)?

    // Statistics (main thread reads; written under the lock).
    private(set) var bytesReceived = 0
    private(set) var framesReceived = 0

    init(address: DisplayAddress, settings: DisplayClientHello) {
        self.address = address
        self.settings = settings
    }

    func start() {
        let t = Thread { [self] in run() }
        t.name = "viewer-connection"
        t.start()
    }

    func stop() {
        let c = lock.withLock { () -> DisplayConnection? in stopped = true; return connection }
        c?.close()
    }

    var stats: (bytes: Int, frames: Int) { lock.withLock { (bytesReceived, framesReceived) } }

    private func main(_ body: @escaping @MainActor @Sendable () -> Void) { DispatchQueue.main.async { MainActor.assumeIsolated { body() } } }

    private func run() {
        var attempt = 0
        while !lock.withLock({ stopped }) {
            attempt += 1
            let detail = attempt > 1 ? "attempt \(attempt)" : nil
            main { self.delegate?.connection(self, phase: "connecting", detail: detail) }
            let c: DisplayConnection
            do {
                c = try DisplayConnection.connect(to: address)
            } catch {
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            lock.withLock { connection = c }
            try? c.send(.clientHello(settings))
            var parser = DisplayMessageParser()
            var canvas: FrameCanvas?
            var gotHello = false
            while let bytes = c.receive(max: 1 << 20) {
                lock.withLock { bytesReceived += bytes.count }
                parser.append(bytes)
                do {
                    while let m = try parser.next() {
                        if case .hello = m { gotHello = true }
                        handle(m, canvas: &canvas)
                    }
                } catch {
                    main { self.delegate?.connection(self, notice: "protocol error: \(error)") }
                    break
                }
            }
            c.close()
            lock.withLock { connection = nil }
            if lock.withLock({ stopped }) { break }
            main { self.delegate?.connection(self, phase: "disconnected", detail: gotHello ? "the device stopped or the link dropped" : nil) }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private func handle(_ m: DisplayMessage, canvas: inout FrameCanvas?) {
        switch m {
        case .hello(let h):
            main { self.delegate?.connection(self, hello: h) }
        case .status(let s):
            main { self.delegate?.connection(self, status: s) }
        case .notice(let text):
            main { self.delegate?.connection(self, notice: text) }
        case .screenshot(let token, let png):
            main { self.delegate?.connection(self, screenshot: png, token: token) }
        case .pong(let token, _):
            let sent = lock.withLock { pings.removeValue(forKey: token) }
            if let sent {
                let rtt = Double(nowNanoseconds() - sent) / 1e6
                main { self.delegate?.connection(self, pongToken: token, rttMilliseconds: rtt) }
            }
        case .frame(let f):
            let received = nowNanoseconds()
            if canvas == nil || canvas!.width != f.width || canvas!.height != f.height {
                canvas = FrameCanvas(width: f.width, height: f.height)
                if !f.isFull { send(.keyframeRequest) }
            }
            guard let canvas else { return }
            if !canvas.applyAll(f.tiles, encoding: f.encoding) { send(.keyframeRequest) }
            lock.withLock { framesReceived += 1 }
            guard let image = canvas.image() else { return }
            // One hand-off to the main thread at a time: frames that arrive
            // while it is busy replace the waiting one (the newest image
            // wins; no queue of stale images builds up behind a slow main thread).
            let post = lock.withLock { () -> Bool in
                defer { pending = (image, f, received) }
                return pending == nil
            }
            if post {
                main {
                    guard let p = self.lock.withLock({ () -> (CGImage, DisplayFrame, UInt64)? in
                        defer { self.pending = nil }
                        return self.pending
                    }) else { return }
                    self.delegate?.connection(self, image: p.0, frame: p.1, receivedAt: p.2)
                }
            }
        default:
            break
        }
    }

    // MARK: Sending (any thread)

    @discardableResult
    func send(_ m: DisplayMessage) -> Bool {
        guard let c = lock.withLock({ connection }) else { return false }
        do { try c.send(m) } catch { return false }
        return true
    }

    /// Sends an input event with the next sequence number; returns it (0: not connected).
    @discardableResult
    func sendInput(_ make: (UInt32) -> DisplayInput) -> UInt32 {
        let seq = lock.withLock { () -> UInt32 in inputSequence &+= 1; return inputSequence }
        return send(.input(make(seq))) ? seq : 0
    }

    func ping() {
        let token = lock.withLock { () -> UInt64 in
            nextPing += 1
            pings[nextPing] = nowNanoseconds()
            if pings.count > 32 { pings.removeAll() }
            return nextPing
        }
        send(.ping(token: token))
    }

    func updateSettings(_ s: DisplayClientHello) {
        settings = s
        send(.clientHello(s))
    }
}

#endif
