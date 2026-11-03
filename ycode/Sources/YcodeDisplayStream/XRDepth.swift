// The headset mode's depth (specs/simulator/xr-depth.md, display-stream.md
// §19): a "frame depth" message (0x0C) follows the frame message it belongs
// to and carries the guest's depth of that picture at reduced size, so the
// viewer can re-project the picture to every headset frame's pose and make
// both eyes from one view.
//
// Samples are 16-bit **inverse depth**: q / 65535 = near / z, z the view
// distance along −Z in metres (the guest's own reverse-Z, infinite-far
// depth, xr-depth.md §2), q = 0 nothing drawn (infinitely far). Inverse
// depth is what a re-projection needs (parallax is linear in it), and 16
// bits of it resolve about 4 mm at 5 m with near 0.1 m.

import Foundation

/// How a frame depth message's samples are packed (`XRFrameDepth.encoding`).
public enum XRDepthEncoding: UInt8, Sendable, Codable {
    /// zlib (RFC 1950) of the row-delta samples split into byte planes
    /// (xr-depth.md §4.2; `XRDepthCodec` in YcodeXRReprojection).
    case zlibPlanes = 1
    /// The samples as they are (u16 little-endian rows; tests, diagnostics).
    case raw = 2
}

/// A frame depth message (0x0C, server → client), just after its frame (0x03).
public struct XRFrameDepth: Equatable, Sendable {
    /// Bits of `flags`.
    public struct Flags: OptionSet, Sendable, Equatable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }
        /// The depth was captured for a different guest frame than the picture's (the nearest the server had).
        public static let otherFrame = Flags(rawValue: 1)
        /// The windows layer's depth is merged into the room's (closest wins).
        public static let windowsMerged = Flags(rawValue: 2)
        /// The windows layer's depth could not be read: windows carry the room's depth.
        public static let roomOnly = Flags(rawValue: 4)
        /// A sample's low bit says whose it is: 1 the windows layer, 0 the room (xr-depth.md §3.1).
        public static let windowsMarked = Flags(rawValue: 8)
    }

    /// The frame message (0x03) this depth belongs to.
    public var frameSequence: UInt64
    /// The guest frame (the frame record's counter) of that picture.
    public var guestFrame: UInt64
    public var encoding: XRDepthEncoding
    /// The view the picture was rendered for (as its frame view, 0x0A).
    public var view: XRView
    public var flags: Flags
    /// The depth image's size (the picture's size divided by the depth downscale, rounded up).
    public var width: UInt16, height: UInt16
    /// The projection's near distance in metres (the guest's: 0.1).
    public var near: Float
    /// The projection the depth was rendered with (normally the frame view's).
    public var fov: XRFieldOfView
    /// The server's monotonic ns when the GPU finished the depth copy (0: unknown).
    public var capturedAt: UInt64
    /// The packed samples (`encoding`).
    public var data: [UInt8]

    public init(frameSequence: UInt64, guestFrame: UInt64, encoding: XRDepthEncoding = .zlibPlanes, view: XRView = .mono,
                flags: Flags = [], width: UInt16, height: UInt16, near: Float = 0.1,
                fov: XRFieldOfView = .guest(width: 3840, height: 2160), capturedAt: UInt64 = 0, data: [UInt8]) {
        (self.frameSequence, self.guestFrame, self.encoding, self.view, self.flags) = (frameSequence, guestFrame, encoding, view, flags)
        (self.width, self.height, self.near, self.fov, self.capturedAt, self.data) = (width, height, near, fov, capturedAt, data)
    }

    /// The payload (after the type byte).
    public func payload() -> [UInt8] {
        var b: [UInt8] = []
        b.reserveCapacity(60 + data.count)
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { b += $0 } }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { b += $0 } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { b += $0 } }
        func f32(_ v: Float) { u32((v.isFinite ? v : 0).bitPattern) }
        u64(frameSequence)
        u64(guestFrame)
        b.append(encoding.rawValue)
        b.append(view.rawValue)
        u16(flags.rawValue)
        u16(width)
        u16(height)
        f32(near)
        let t = fov.tangents
        for v in [t.left, t.right, t.up, t.down] { f32(Float(v)) }
        u64(capturedAt)
        u32(UInt32(data.count))
        b += data
        return b
    }

    /// Parses a payload; nil when it is malformed.
    public init?(payload p: [UInt8]) {
        var i = 0
        func take(_ n: Int) -> ArraySlice<UInt8>? { guard i + n <= p.count else { return nil }; defer { i += n }; return p[i..<i + n] }
        func u(_ n: Int) -> UInt64? {
            guard let s = take(n) else { return nil }
            var v: UInt64 = 0
            for (k, x) in s.enumerated() { v |= UInt64(x) << (8 * UInt64(k)) }
            return v
        }
        func f() -> Float? { u(4).map { Float(bitPattern: UInt32($0)) } }
        guard let seq = u(8), let guest = u(8), let enc = u(1), let encoding = XRDepthEncoding(rawValue: UInt8(enc)),
              let rawView = u(1), let view = XRView(rawValue: UInt8(rawView)), let flags = u(2),
              let w = u(2), let h = u(2), let near = f(),
              let l = f(), let r = f(), let up = f(), let dn = f(), let captured = u(8), let n = u(4),
              let body = take(Int(n)) else { return nil }
        self.init(frameSequence: seq, guestFrame: guest, encoding: encoding, view: view, flags: Flags(rawValue: UInt16(flags)),
                  width: UInt16(w), height: UInt16(h), near: near,
                  fov: XRFieldOfView(tangentLeft: Double(l), right: Double(r), up: Double(up), down: Double(dn)),
                  capturedAt: captured, data: Array(body))
    }
}

/// Inverse-depth quantisation (xr-depth.md §2).
public enum XRDepthSample {
    /// The u16 sample of a reverse-Z depth value d (= near / z; 0 at infinity, 1 at the near plane).
    @inline(__always)
    public static func quantize(reverseZ d: Float) -> UInt16 {
        guard d.isFinite, d > 0 else { return 0 }
        if d >= 1 { return 65535 }
        return UInt16(max(1, min(65535, (d * 65535).rounded())))
    }

    /// The reverse-Z value of a sample.
    @inline(__always)
    public static func reverseZ(_ q: UInt16) -> Float { Float(q) / 65535 }

    /// The view distance (metres) of a sample; infinity for 0.
    public static func distance(_ q: UInt16, near: Float) -> Float {
        q == 0 ? .infinity : near / reverseZ(q)
    }

    /// The sample of a view distance.
    public static func sample(distance z: Float, near: Float) -> UInt16 {
        guard z.isFinite, z > 0 else { return 0 }
        return quantize(reverseZ: near / z)
    }
}

/// The room's environment (message 0x0D, server → client; xr-depth.md §4.3):
/// the guest's environment cube, sent when a viewer asks (`xr.environment`)
/// and again whenever it changes. The viewer draws it at infinity behind
/// everything until the world cache covers a direction.
public struct XREnvironment: Equatable, Sendable {
    public enum Format: UInt8, Sendable { case rgba16Float = 1, rgba8sRGB = 2 }

    /// Increments with every change.
    public var serial: UInt32
    /// 1: zlib (RFC 1950) of the faces; 2: the faces as they are.
    public var compressed: Bool
    public var format: Format
    public var faceSize: UInt16
    /// The cube's mip level the faces are.
    public var level: UInt8
    /// Bit 0: `orientation` is known (else identity, the viewer may calibrate).
    public var orientationKnown: Bool
    /// The cube's frame → the stage frame.
    public var orientation: SpatialQuaternion
    public var exposure: Float
    /// Six faces (+X, −X, +Y, −Y, +Z, −Z), rows top to bottom, packed per `compressed`.
    public var data: [UInt8]

    public init(serial: UInt32, compressed: Bool, format: Format = .rgba16Float, faceSize: UInt16, level: UInt8,
                orientationKnown: Bool = false, orientation: SpatialQuaternion = .identity, exposure: Float = 1, data: [UInt8]) {
        (self.serial, self.compressed, self.format, self.faceSize, self.level) = (serial, compressed, format, faceSize, level)
        (self.orientationKnown, self.orientation, self.exposure, self.data) = (orientationKnown, orientation, exposure, data)
    }

    public var bytesPerTexel: Int { format == .rgba16Float ? 8 : 4 }

    public func payload() -> [UInt8] {
        var b: [UInt8] = []
        b.reserveCapacity(40 + data.count)
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { b += $0 } }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { b += $0 } }
        func f32(_ v: Float) { u32((v.isFinite ? v : 0).bitPattern) }
        u32(serial)
        b.append(compressed ? 1 : 2)
        b.append(format.rawValue)
        u16(faceSize)
        b.append(level)
        b.append(orientationKnown ? 1 : 0)
        u16(0)
        for v in [orientation.x, orientation.y, orientation.z, orientation.w] { f32(Float(v)) }
        f32(exposure)
        u32(UInt32(data.count))
        b += data
        return b
    }

    public init?(payload p: [UInt8]) {
        var i = 0
        func u(_ n: Int) -> UInt64? {
            guard i + n <= p.count else { return nil }
            var v: UInt64 = 0
            for k in 0..<n { v |= UInt64(p[i + k]) << (8 * UInt64(k)) }
            i += n
            return v
        }
        func f() -> Float? { u(4).map { Float(bitPattern: UInt32($0)) } }
        guard let serial = u(4), let enc = u(1), let fmt = u(1), let format = Format(rawValue: UInt8(fmt)), let size = u(2),
              let level = u(1), let flags = u(1), u(2) != nil, let x = f(), let y = f(), let z = f(), let w = f(),
              let exposure = f(), let n = u(4), i + Int(n) <= p.count, enc == 1 || enc == 2 else { return nil }
        self.init(serial: UInt32(serial), compressed: enc == 1, format: format, faceSize: UInt16(size), level: UInt8(level),
                  orientationKnown: flags & 1 != 0, orientation: SpatialQuaternion(x: Double(x), y: Double(y), z: Double(z), w: Double(w)),
                  exposure: exposure, data: Array(p[i..<(i + Int(n))]))
    }
}
