import Accelerate
import AppKit
import YcodeIDECore

/// Content seen through a bar keeps its shape (`liquid-glass.md` §9.1,
/// §9.2; checklist rows 68 and 69): the views under the bar are drawn
/// into a bitmap, blurred with a Gaussian of σ about 6 points and laid
/// over the bar's background at the bar's share of the content's
/// darkness. The system's header material averaged the content to a flat
/// tint; this keeps the bands under the jump bar as bands.
@MainActor
enum StructureBlur {
    /// The blur's standard deviation, in points (§8.3: about 6).
    static let sigma = CGFloat(BarBlur.sigma)
    /// Pixels per point of the blurred bitmap: σ 6 loses nothing at half
    /// resolution, and the bitmap is a quarter of the work.
    static let pixelsPerPoint: CGFloat = 0.5

    /// `rect` (in `target`'s coordinates) of `sources` drawn over
    /// `background` and blurred; nil when nothing could be drawn.
    static func image(of rect: NSRect, in target: NSView, sources: [NSView], background: NSColor) -> CGImage? {
        guard rect.width >= 1, rect.height >= 1, let window = target.window else { return nil }
        let margin = ceil(3 * sigma)
        let area = rect.insetBy(dx: -margin, dy: -margin)
        let w = Int(ceil(area.width * pixelsPerPoint)), h = Int(ceil(area.height * pixelsPerPoint))
        guard w > 0, h > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                         bytesPerRow: w * 4, bitsPerPixel: 32),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = area.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        (background.usingColorSpace(.deviceRGB) ?? background).setFill()
        NSRect(origin: .zero, size: area.size).fill()
        for v in sources where v.window === window && !v.isHiddenOrHasHiddenAncestor {
            let r = v.convert(area, from: target)
            let visible = r.intersection(v.bounds)
            // Drawn straight at the blurred bitmap's resolution, not at the
            // screen's and then scaled down (a sixteenth of the pixels at 2x;
            // row 106).
            guard !visible.isEmpty, let part = lowResolutionRep(for: visible) else { continue }
            v.cacheDisplay(in: visible, to: part)
            // Where the part sits in the area, from the area's bottom left.
            let inTarget = target.convert(visible, from: v)
            let x = inTarget.minX - area.minX
            let y = target.isFlipped ? area.maxY - inTarget.maxY : inTarget.minY - area.minY
            part.draw(in: NSRect(x: x, y: y, width: inTarget.width, height: inTarget.height), from: .zero, operation: .sourceOver,
                      fraction: 1, respectFlipped: false, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return nil }
        blur(data, width: w, height: h, rowBytes: rep.bytesPerRow, sigma: sigma * pixelsPerPoint)
        return rep.cgImage
    }

    /// A bitmap for `rect` (points) at `pixelsPerPoint`.
    static func lowResolutionRep(for rect: NSRect) -> NSBitmapImageRep? {
        let w = max(1, Int(ceil(rect.width * pixelsPerPoint))), h = max(1, Int(ceil(rect.height * pixelsPerPoint)))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)
        rep?.size = rect.size
        return rep
    }

    /// A separable Gaussian blur in place (edges extended).
    static func blur(_ data: UnsafeMutablePointer<UInt8>, width: Int, height: Int, rowBytes: Int, sigma: CGFloat) {
        let kernel = GaussianKernel.weights(sigma: Double(sigma))
        guard kernel.count > 1 else { return }
        let scaled = kernel.map { Int16(($0 * 4096).rounded()) }
        let divisor = Int32(scaled.reduce(0) { $0 + Int32($1) })
        var src = vImage_Buffer(data: data, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
        guard let tmpData = malloc(rowBytes * height) else { return }
        defer { free(tmpData) }
        var tmp = vImage_Buffer(data: tmpData, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
        var bg: [UInt8] = [0, 0, 0, 0]
        scaled.withUnsafeBufferPointer { k in
            _ = vImageConvolve_ARGB8888(&src, &tmp, nil, 0, 0, k.baseAddress!, 1, UInt32(k.count), divisor, &bg, vImage_Flags(kvImageEdgeExtend))
            _ = vImageConvolve_ARGB8888(&tmp, &src, nil, 0, 0, k.baseAddress!, UInt32(k.count), 1, divisor, &bg, vImage_Flags(kvImageEdgeExtend))
        }
    }

    /// Draws `image` (from `image(of:in:sources:background:)` for
    /// `rect`) into `rect` at `share` over what is already there.
    static func draw(_ image: CGImage, for rect: NSRect, in view: NSView, share: CGFloat, clip: NSRect? = nil) {
        let margin = ceil(3 * sigma)
        let area = rect.insetBy(dx: -margin, dy: -margin)
        NSGraphicsContext.saveGraphicsState()
        (clip ?? rect).clip()
        NSImage(cgImage: image, size: area.size).draw(in: area, from: .zero, operation: .sourceOver, fraction: share,
                                                      respectFlipped: true, hints: [.interpolation: NSNumber(value: NSImageInterpolation.low.rawValue)])
        NSGraphicsContext.restoreGraphicsState()
    }
}
