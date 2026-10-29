// Record Screen (device-hub.md §4.4, "Ycode implementation"): the pictures
// the viewer receives become an H.264 QuickTime movie on the Mac, each at
// the time it arrived. Ycode decision: the movie has the size of the first
// picture (even width and height); a later picture of another shape (a
// rotation, the iPhone Duo's other panel) is fitted into it, centred on
// black. Encoding runs on the recorder's own queue.

#if os(macOS)
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

public final class ScreenRecorder: @unchecked Sendable {
    public let url: URL
    private let queue = DispatchQueue(label: "ycode.screen-recorder")
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var size: CGSize?
    private var start: CFTimeInterval?
    private var lastTime = CMTime.invalid
    public private(set) var frameCount = 0

    public init(url: URL) throws {
        self.url = url
        try? FileManager.default.removeItem(at: url)
    }

    /// Adds a picture at the current time.
    public func append(_ image: CGImage) {
        let now = CACurrentMediaTime()
        queue.async { [self] in appendLocked(image, at: now) }
    }

    private var lastImage: CGImage?

    private func appendLocked(_ image: CGImage, at now: CFTimeInterval) {
        lastImage = image
        if writer == nil {
            let w = max(2, image.width & ~1), h = max(2, image.height & ~1)
            guard let wr = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
            let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h]
            let inp = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            inp.expectsMediaDataInRealTime = true
            let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: inp, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            ])
            guard wr.canAdd(inp) else { return }
            wr.add(inp)
            guard wr.startWriting() else { return }
            wr.startSession(atSourceTime: .zero)
            writer = wr
            input = inp
            adaptor = ad
            size = CGSize(width: w, height: h)
            start = now
        }
        guard let input, let adaptor, let size, let start, input.isReadyForMoreMediaData,
              let pool = adaptor.pixelBufferPool else { return }
        var t = CMTime(seconds: max(0, now - start), preferredTimescale: 600)
        if lastTime.isValid, t <= lastTime { t = CMTimeAdd(lastTime, CMTime(value: 1, timescale: 600)) }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                               bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: Self.fitted(CGSize(width: image.width, height: image.height), in: size))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        if adaptor.append(buffer, withPresentationTime: t) {
            lastTime = t
            frameCount += 1
        }
    }

    /// A picture of `image` size fitted into `box`, centred.
    static func fitted(_ image: CGSize, in box: CGSize) -> CGRect {
        let s = min(box.width / image.width, box.height / image.height)
        let w = image.width * s, h = image.height * s
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    /// Ends the movie; `done` gets its URL (nil: nothing was recorded).
    public func finish(_ done: @escaping @Sendable (URL?) -> Void) {
        let now = CACurrentMediaTime()
        queue.async { [self] in
            // The stream sends pictures only when the screen changes: the
            // last one is repeated at the stop, so the movie lasts as long
            // as the recording did.
            if let lastImage { appendLocked(lastImage, at: now) }
            guard let writer, let input else { done(nil); return }
            input.markAsFinished()
            if lastTime.isValid { writer.endSession(atSourceTime: lastTime) }
            let url = self.url
            writer.finishWriting { done(writer.status == .completed ? url : nil) }
        }
    }
}
#endif
