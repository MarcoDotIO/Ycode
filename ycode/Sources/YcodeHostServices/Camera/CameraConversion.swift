// Frame conversion (camera-host.md §4): a captured frame in its source
// layout goes into a guest surface layout ('420v', '420f', 'BGRA'). The
// arithmetic is CYcodeCamera's (convert.c, jpeg.c).

import CYcodeCamera
import Foundation

/// A captured frame in its source layout. The bytes are valid until the
/// capture gets it back (`CameraCapture.recycle`).
public struct CameraRawFrame: @unchecked Sendable {
    public var format: CameraSourceFormat
    public var width: Int, height: Int
    /// Bytes per row of the first plane (packed formats: of the image).
    public var bytesPerLine: Int
    public var bytes: UnsafeRawBufferPointer
    public var colorimetry: CameraColorimetry
    public var deviceSequence: UInt32
    /// CLOCK_MONOTONIC, nanoseconds.
    public var timestamp: Int64
    public var synthetic: Bool
    /// The capture's own handle (the V4L2 buffer index).
    public var token: Int

    public init(format: CameraSourceFormat, width: Int, height: Int, bytesPerLine: Int, bytes: UnsafeRawBufferPointer,
                colorimetry: CameraColorimetry, deviceSequence: UInt32, timestamp: Int64, synthetic: Bool, token: Int) {
        (self.format, self.width, self.height, self.bytesPerLine, self.bytes) = (format, width, height, bytesPerLine, bytes)
        (self.colorimetry, self.deviceSequence, self.timestamp, self.synthetic, self.token) =
            (colorimetry, deviceSequence, timestamp, synthetic, token)
    }
}

/// Where a surface's pixels go (§5.1).
public struct CameraSurfaceLayout: Equatable, Sendable {
    public var format: CameraPixelFormat
    public var width: Int, height: Int
    /// Top level: 4 and the row stride for 'BGRA'; 1 and 0 for the
    /// bi-planar formats, whose planes carry their own.
    public var bytesPerElement: Int, bytesPerRow: Int
    public var allocationSize: Int
    public var planes: [IOSurfaceHostService.HostPlane]

    /// Row strides are multiples of 128 bytes and plane offsets multiples
    /// of 16 KiB (the alignments the IOSurface service reports in `Limits`,
    /// iosurface-remote.md §4.4).
    public static let rowAlignment = 128
    public static let planeAlignment = 16384

    public static func make(_ format: CameraPixelFormat, width: Int, height: Int) -> CameraSurfaceLayout {
        func align(_ v: Int, _ a: Int) -> Int { (v + a - 1) / a * a }
        switch format {
        case .bgra:
            let row = align(width * 4, rowAlignment)
            return CameraSurfaceLayout(format: format, width: width, height: height, bytesPerElement: 4, bytesPerRow: row,
                                       allocationSize: align(row * height, planeAlignment), planes: [])
        case .biPlanar420Video, .biPlanar420Full:
            let cw = (width + 1) / 2, ch = (height + 1) / 2
            let yRow = align(width, rowAlignment), cRow = align(cw * 2, rowAlignment)
            let y = IOSurfaceHostService.HostPlane(offset: 0, width: width, height: height, bytesPerRow: yRow, bytesPerElement: 1,
                                                   size: yRow * height)
            let cOffset = align(y.size, planeAlignment)
            let c = IOSurfaceHostService.HostPlane(offset: cOffset, width: cw, height: ch, bytesPerRow: cRow, bytesPerElement: 2,
                                                   size: cRow * ch)
            return CameraSurfaceLayout(format: format, width: width, height: height, bytesPerElement: 1, bytesPerRow: 0,
                                       allocationSize: align(cOffset + c.size, planeAlignment), planes: [y, c])
        }
    }

    /// The colour attachments (iosurface-remote.md §3.2; ISO/IEC 23001-8
    /// code points: matrix 6 = BT.601, 1 = BT.709; primaries and transfer
    /// 1 = BT.709) of a surface holding `colorimetry`.
    public func attachments(_ colorimetry: CameraColorimetry) -> [String: UInt64] {
        guard format.isBiPlanar else { return [:] }
        return ["YCbCrMatrixIndex": colorimetry.matrix == 709 ? 1 : 6, "ColorPrimariesIndex": 1, "TransferFunctionIndex": 1]
    }
}

public enum CameraConversionError: Error, Equatable {
    case sizeMismatch, shortFrame, unsupported(CameraSourceFormat), jpeg(Int32)
}

/// Converts raw frames into surface memory. Keeps one JPEG decoder.
public final class CameraConverter: @unchecked Sendable {
    private var decoder: OpaquePointer?
    nonisolated(unsafe) private static let neutralChroma: UnsafeMutablePointer<UInt8> = {
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        p.pointee = 128
        return p
    }()

    public init() {}
    deinit { if let decoder { ycam_jpeg_free(decoder) } }

    /// Writes `frame` into `memory` laid out as `layout` (same size).
    /// The colorimetry of a JPEG frame is full-range BT.601 (JFIF).
    public func convert(_ frame: CameraRawFrame, into memory: UnsafeMutableRawPointer, layout: CameraSurfaceLayout) throws {
        guard frame.width == layout.width, frame.height == layout.height else { throw CameraConversionError.sizeMismatch }
        if frame.format == .mjpeg {
            try convertJPEG(frame, into: memory, layout: layout)
            return
        }
        guard let base = frame.bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { throw CameraConversionError.shortFrame }
        let w = frame.width, h = frame.height, bpl = frame.bytesPerLine
        var s = ycam_ycbcr_source()
        s.width = Int32(w)
        s.height = Int32(h)
        s.full_range = frame.colorimetry.fullRange ? 1 : 0
        s.matrix = Int32(frame.colorimetry.matrix)
        let needed: Int
        switch frame.format {
        case .yuyv, .uyvy:
            needed = bpl * (h - 1) + w * 2
            let y = frame.format == .yuyv ? 0 : 1, cb = frame.format == .yuyv ? 1 : 0
            (s.y, s.cb, s.cr) = (UnsafePointer(base + y), UnsafePointer(base + cb), UnsafePointer(base + cb + 2))
            (s.ystep, s.cstep, s.ystride, s.cstride, s.hsub, s.vsub) = (2, 4, bpl, bpl, 2, 1)
        case .nv12:
            needed = bpl * h + bpl * ((h + 1) / 2 - 1) + (w + 1) / 2 * 2
            let uv = base + bpl * h
            (s.y, s.cb, s.cr) = (UnsafePointer(base), UnsafePointer(uv), UnsafePointer(uv + 1))
            (s.ystep, s.cstep, s.ystride, s.cstride, s.hsub, s.vsub) = (1, 2, bpl, bpl, 2, 2)
        case .yu12, .yv12:
            let cs = bpl / 2, ch = (h + 1) / 2
            needed = bpl * h + 2 * cs * ch
            let first = base + bpl * h, second = first + cs * ch
            let (cb, cr) = frame.format == .yu12 ? (first, second) : (second, first)
            (s.y, s.cb, s.cr) = (UnsafePointer(base), UnsafePointer(cb), UnsafePointer(cr))
            (s.ystep, s.cstep, s.ystride, s.cstride, s.hsub, s.vsub) = (1, 1, bpl, cs, 2, 2)
        default:
            throw CameraConversionError.unsupported(frame.format)
        }
        guard frame.bytes.count >= needed else { throw CameraConversionError.shortFrame }
        write(&s, into: memory, layout: layout)
    }

    private func convertJPEG(_ frame: CameraRawFrame, into memory: UnsafeMutableRawPointer, layout: CameraSurfaceLayout) throws {
        if decoder == nil { decoder = ycam_jpeg_new() }
        guard let decoder, let base = frame.bytes.baseAddress else { throw CameraConversionError.jpeg(-3) }
        let r = ycam_jpeg_decode(decoder, base.assumingMemoryBound(to: UInt8.self), frame.bytes.count)
        guard r == 0 else { throw CameraConversionError.jpeg(r) }
        var image = ycam_jpeg_image()
        ycam_jpeg_image_info(decoder, &image)
        guard Int(image.width) == layout.width, Int(image.height) == layout.height else { throw CameraConversionError.sizeMismatch }
        var s = ycam_ycbcr_source()
        s.width = image.width
        s.height = image.height
        s.full_range = 1
        s.matrix = 601
        s.y = image.plane.0
        s.ystride = Int(image.stride.0)
        s.ystep = 1
        if image.components == 3 {
            // Cb and Cr share their sampling in every camera stream we know;
            // a stream where they differ is refused.
            guard image.h.1 == image.h.2, image.v.1 == image.v.2,
                  image.hmax == image.h.0, image.vmax == image.v.0 else { throw CameraConversionError.jpeg(-2) }
            s.hsub = image.hmax / image.h.1
            s.vsub = image.vmax / image.v.1
            s.cb = image.plane.1
            s.cr = image.plane.2
            s.cstride = Int(image.stride.1)
            s.cstep = 1
        } else {
            // Grey: neutral chroma from one byte (step and stride 0).
            s.cb = UnsafePointer(Self.neutralChroma)
            s.cr = UnsafePointer(Self.neutralChroma)
            (s.hsub, s.vsub, s.cstep, s.cstride) = (1, 1, 0, 0)
        }
        write(&s, into: memory, layout: layout)
    }

    private func write(_ s: inout ycam_ycbcr_source, into memory: UnsafeMutableRawPointer, layout: CameraSurfaceLayout) {
        let m = memory.assumingMemoryBound(to: UInt8.self)
        switch layout.format {
        case .bgra:
            ycam_to_bgra(&s, m, layout.bytesPerRow)
        case .biPlanar420Video, .biPlanar420Full:
            let y = layout.planes[0], c = layout.planes[1]
            ycam_to_biplanar420(&s, m + y.offset, y.bytesPerRow, m + c.offset, c.bytesPerRow, layout.format.isFullRange ? 1 : 0)
        }
    }

    /// A surface's pixels as packed RGBA (PNG output, tests).
    public static func rgba(from memory: UnsafeRawPointer, layout: CameraSurfaceLayout) -> [UInt8] {
        let w = layout.width, h = layout.height
        var bgra = [UInt8](repeating: 0, count: w * h * 4)
        let m = memory.assumingMemoryBound(to: UInt8.self)
        switch layout.format {
        case .bgra:
            for row in 0..<h { bgra.withUnsafeMutableBytes { _ = memcpy($0.baseAddress! + row * w * 4, m + row * layout.bytesPerRow, w * 4) } }
        case .biPlanar420Video, .biPlanar420Full:
            let y = layout.planes[0], c = layout.planes[1]
            var s = ycam_ycbcr_source()
            (s.y, s.cb, s.cr) = (UnsafePointer(m + y.offset), UnsafePointer(m + c.offset), UnsafePointer(m + c.offset + 1))
            (s.ystep, s.cstep, s.ystride, s.cstride, s.hsub, s.vsub) = (1, 2, y.bytesPerRow, c.bytesPerRow, 2, 2)
            (s.width, s.height, s.full_range, s.matrix) = (Int32(w), Int32(h), layout.format.isFullRange ? 1 : 0, 601)
            bgra.withUnsafeMutableBytes { ycam_to_bgra(&s, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), w * 4) }
        }
        return PNG.rgba(fromBGRA: bgra, width: w, height: h, bytesPerRow: w * 4)
    }

    /// Packed RGBA downscaled by an integer factor (box filter).
    public static func downscale(rgba: [UInt8], width: Int, height: Int, factor: Int) -> (rgba: [UInt8], width: Int, height: Int) {
        guard factor > 1 else { return (rgba, width, height) }
        let ow = width / factor, oh = height / factor
        var out = [UInt8](repeating: 0, count: ow * oh * 4)
        rgba.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                ycam_bgra_downscale(src.baseAddress!.assumingMemoryBound(to: UInt8.self), Int32(width), Int32(height), width * 4,
                                    Int32(factor), dst.baseAddress!.assumingMemoryBound(to: UInt8.self), ow * 4)
            }
        }
        return (out, ow, oh)
    }
}
