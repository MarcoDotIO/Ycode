// The host camera layer's vocabulary (specs/simulator/camera-host.md §2,
// §3): devices, the formats a device offers, what a stream asks for and what
// it got, and the frames it delivers.

import Foundation

/// A source pixel layout as V4L2 names it (`v4l2_fourcc`: the first
/// character in the low byte).
public struct CameraSourceFormat: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ code: String) {
        let b = Array(code.utf8) + [32, 32, 32, 32]
        rawValue = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    /// Packed 4:2:2, Y0 Cb Y1 Cr.
    public static let yuyv = CameraSourceFormat("YUYV")
    /// Packed 4:2:2, Cb Y0 Cr Y1.
    public static let uyvy = CameraSourceFormat("UYVY")
    /// Bi-planar 4:2:0, Y then interleaved Cb Cr.
    public static let nv12 = CameraSourceFormat("NV12")
    /// Planar 4:2:0, Y, Cb, Cr (I420).
    public static let yu12 = CameraSourceFormat("YU12")
    /// Planar 4:2:0, Y, Cr, Cb.
    public static let yv12 = CameraSourceFormat("YV12")
    /// Motion-JPEG: one baseline JPEG per frame.
    public static let mjpeg = CameraSourceFormat("MJPG")

    /// The formats Ycode converts, best first when a stream can have its
    /// rate in more than one (§3.2): uncompressed before compressed.
    public static let supported: [CameraSourceFormat] = [.nv12, .yuyv, .uyvy, .yu12, .yv12, .mjpeg]

    public var isSupported: Bool { Self.supported.contains(self) }
    public var isCompressed: Bool { self == .mjpeg }

    public var description: String {
        String(decoding: (0..<4).map { UInt8(truncatingIfNeeded: rawValue >> (8 * $0)) }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// The pixel formats Ycode hands the guest, as CoreVideo pixel format types
/// (OSType: the first character in the high byte; public CVPixelBuffer.h
/// values).
public enum CameraPixelFormat: UInt32, Sendable, CaseIterable, CustomStringConvertible {
    /// `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`, '420v'.
    case biPlanar420Video = 0x3432_3076
    /// `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`, '420f'.
    case biPlanar420Full = 0x3432_3066
    /// `kCVPixelFormatType_32BGRA`, 'BGRA'.
    case bgra = 0x4247_5241

    public var description: String {
        String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: rawValue >> $0) }, as: UTF8.self)
    }

    public init?(name: String) {
        guard let f = Self.allCases.first(where: { $0.description == name || "\($0)".lowercased() == name.lowercased() })
        else { return nil }
        self = f
    }

    public var isBiPlanar: Bool { self != .bgra }
    public var isFullRange: Bool { self == .biPlanar420Full }
}

/// A frame interval: `numerator / denominator` seconds per frame.
public struct CameraFrameInterval: Hashable, Sendable, CustomStringConvertible {
    public var numerator: UInt32, denominator: UInt32
    public init(numerator: UInt32, denominator: UInt32) { (self.numerator, self.denominator) = (numerator, denominator) }
    public init(fps: Double) {
        let f = max(fps, 0.001)
        if f.rounded() == f { self.init(numerator: 1, denominator: UInt32(f)) } else { self.init(numerator: 1000, denominator: UInt32(f * 1000)) }
    }
    public var framesPerSecond: Double { numerator == 0 ? 0 : Double(denominator) / Double(numerator) }
    public var nanoseconds: Int64 { denominator == 0 ? 0 : Int64(numerator) * 1_000_000_000 / Int64(denominator) }
    public var description: String {
        let f = framesPerSecond
        return f.rounded() == f ? "\(Int(f)) fps" : String(format: "%.2f fps", f)
    }
}

/// A frame size and the intervals a device offers for it, fastest first.
public struct CameraFrameSize: Hashable, Sendable {
    public var width: Int, height: Int
    public var intervals: [CameraFrameInterval]
    public init(width: Int, height: Int, intervals: [CameraFrameInterval]) {
        (self.width, self.height) = (width, height)
        self.intervals = intervals.sorted { $0.framesPerSecond > $1.framesPerSecond }
    }
    public var maxFramesPerSecond: Double { intervals.first?.framesPerSecond ?? 0 }
}

/// One pixel format of a device with its sizes.
public struct CameraFormatDescription: Hashable, Sendable {
    public var format: CameraSourceFormat
    public var name: String
    public var sizes: [CameraFrameSize]
    public init(format: CameraSourceFormat, name: String, sizes: [CameraFrameSize]) {
        (self.format, self.name, self.sizes) = (format, name, sizes)
    }
}

/// A camera the host can open.
public struct CameraDevice: Hashable, Sendable {
    public enum Kind: String, Sendable { case v4l2, synthetic }
    /// Stable while the device stays on the same port: `v4l2:<bus info>`,
    /// or `synthetic`.
    public var id: String
    public var kind: Kind
    public var name: String
    /// The device node (V4L2).
    public var path: String?
    public var driver: String
    public var busInfo: String
    public var formats: [CameraFormatDescription]
    public init(id: String, kind: Kind, name: String, path: String?, driver: String, busInfo: String,
                formats: [CameraFormatDescription]) {
        (self.id, self.kind, self.name, self.path) = (id, kind, name, path)
        (self.driver, self.busInfo, self.formats) = (driver, busInfo, formats)
    }
}

/// What a stream asks for (§3.2). The output has the negotiated size: Ycode
/// does not scale.
public struct CameraConfiguration: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var framesPerSecond: Double
    public var output: CameraPixelFormat
    /// Surfaces in the ring (§5.2).
    public var ringSize: Int
    /// Frames stay held after delivery until `CameraHostService.release`.
    public var holdFramesUntilReleased: Bool
    /// While the device is absent (unplugged mid-stream), deliver the
    /// synthetic pattern at the stream's size instead of nothing (§6).
    public var syntheticWhileAbsent: Bool
    /// Restrict negotiation to one source format (diagnostics).
    public var sourceFormat: CameraSourceFormat?

    public init(width: Int = 1280, height: Int = 720, framesPerSecond: Double = 30, output: CameraPixelFormat = .biPlanar420Video,
                ringSize: Int = 4, holdFramesUntilReleased: Bool = false, syntheticWhileAbsent: Bool = true,
                sourceFormat: CameraSourceFormat? = nil) {
        (self.width, self.height, self.framesPerSecond, self.output) = (width, height, framesPerSecond, output)
        (self.ringSize, self.holdFramesUntilReleased, self.syntheticWhileAbsent) = (ringSize, holdFramesUntilReleased, syntheticWhileAbsent)
        self.sourceFormat = sourceFormat
    }
}

/// The Y'CbCr encoding of a source (§4.1).
public struct CameraColorimetry: Hashable, Sendable {
    public var fullRange: Bool
    /// 601 or 709.
    public var matrix: Int
    public init(fullRange: Bool, matrix: Int) { (self.fullRange, self.matrix) = (fullRange, matrix) }
    public static let video601 = CameraColorimetry(fullRange: false, matrix: 601)
    public static let full601 = CameraColorimetry(fullRange: true, matrix: 601)
}

/// What a stream got from its device.
public struct CameraStreamFormat: Hashable, Sendable, CustomStringConvertible {
    public var source: CameraSourceFormat
    public var width: Int, height: Int
    public var interval: CameraFrameInterval
    public var colorimetry: CameraColorimetry
    public var output: CameraPixelFormat
    public init(source: CameraSourceFormat, width: Int, height: Int, interval: CameraFrameInterval,
                colorimetry: CameraColorimetry, output: CameraPixelFormat) {
        (self.source, self.width, self.height, self.interval) = (source, width, height, interval)
        (self.colorimetry, self.output) = (colorimetry, output)
    }
    public var description: String {
        "\(source) \(width)x\(height) @ \(interval) -> \(output) (source: \(colorimetry.fullRange ? "full" : "video") range, BT.\(colorimetry.matrix))"
    }
}

/// One delivered frame (§5.3): the surface it is in and when it was taken.
public struct CameraFrame: Sendable, Equatable {
    /// Ycode's frame counter for the stream, from 0.
    public var sequence: UInt64
    /// The device's counter (V4L2 `sequence`; the synthetic frame number).
    public var deviceSequence: UInt32
    /// The IOSurface ID (guests look it up with Method 2 `LookupID`).
    public var surfaceID: UInt32
    /// The surface's Method-14 port (a host-task receive right; a send right
    /// made from it gives a guest the surface by port).
    public var surfacePort: UInt32
    /// The surface's seed after the write.
    public var seed: UInt32
    /// The ring slot.
    public var slot: Int
    public var format: CameraPixelFormat
    public var width: Int, height: Int
    /// Capture time on the host's CLOCK_MONOTONIC, in nanoseconds.
    public var presentationTime: Int64
    /// The stream's nominal frame duration, in nanoseconds.
    public var duration: Int64
    /// Frames dropped (no free surface, corrupt data) since the one before.
    public var droppedBefore: Int
    /// True for a synthetic frame (the synthetic device, or a stand-in
    /// while the device is absent).
    public var synthetic: Bool
}

/// Stream events (§6).
public enum CameraEvent: Sendable, Equatable {
    case started(CameraStreamFormat)
    /// The device went away (unplugged, driver error); `fallback` tells
    /// whether synthetic frames follow.
    case disconnected(deviceID: String, fallback: Bool)
    /// The device came back and the stream resumed on it.
    case reconnected(CameraStreamFormat)
    case stopped
}

public struct CameraError: Error, CustomStringConvertible, Equatable {
    public enum Code: Sendable { case noDevice, busy, unsupported, io, permission, gone }
    public var code: Code
    public var message: String
    public init(_ code: Code, _ message: String) { (self.code, self.message) = (code, message) }
    public var description: String { message }

    static func errno(_ what: String, _ e: Int32, path: String) -> CameraError {
        let text = "\(path): \(what): \(String(cString: strerror(e)))"
        switch e {
        case EBUSY: return CameraError(.busy, text + " (another program holds the camera)")
        case EACCES, EPERM: return CameraError(.permission, text + " (the account needs the video group)")
        case ENODEV, ENXIO, ENOENT: return CameraError(.gone, text)
        default: return CameraError(.io, text)
        }
    }
}
