// The depth codec of the frame depth message (specs/simulator/xr-depth.md
// §4.2): lossless. Each row is delta-coded from its left neighbour (the
// first sample from the one above), the u16 deltas are split into a plane of
// low bytes and a plane of high bytes (smooth surfaces make the high plane
// almost all zero or 0xFF), and both planes are compressed with zlib
// (RFC 1950; the system's libz through CYcodeCodec).

import CYcodeCodec
import Foundation
import YcodeDisplayStream

public enum XRDepthCodec {
    public enum Failure: Error, Equatable { case noZlib, size, corrupt }

    /// The packed form of `samples` (width × height, rows top to bottom).
    public static func encode(_ samples: [UInt16], width: Int, height: Int, level: Int32 = 1) throws -> [UInt8] {
        guard width > 0, height > 0, samples.count == width * height else { throw Failure.size }
        let n = samples.count
        var planes = [UInt8](repeating: 0, count: 2 * n)
        samples.withUnsafeBufferPointer { s in
            planes.withUnsafeMutableBufferPointer { p in
                for y in 0..<height {
                    let row = y * width
                    var previous: UInt16 = y > 0 ? s[row - width] : 0
                    for x in 0..<width {
                        let v = s[row + x]
                        let d = v &- previous
                        p[row + x] = UInt8(truncatingIfNeeded: d)
                        p[n + row + x] = UInt8(truncatingIfNeeded: d >> 8)
                        previous = v
                    }
                }
            }
        }
        guard ycodec_zlib_available() != 0 else { throw Failure.noZlib }
        var out = [UInt8](repeating: 0, count: ycodec_zlib_bound(planes.count))
        var size = out.count
        let rc = planes.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                ycodec_zlib_compress(src.baseAddress, src.count, level, dst.baseAddress, &size)
            }
        }
        guard rc == 0 else { throw Failure.corrupt }
        out.removeSubrange(size...)
        return out
    }

    /// The samples of a packed image.
    public static func decode(_ data: [UInt8], width: Int, height: Int) throws -> [UInt16] {
        guard width > 0, height > 0 else { throw Failure.size }
        let n = width * height
        var planes = [UInt8](repeating: 0, count: 2 * n)
        var size = planes.count
        guard ycodec_zlib_available() != 0 else { throw Failure.noZlib }
        let rc = data.withUnsafeBufferPointer { src in
            planes.withUnsafeMutableBufferPointer { dst in ycodec_zlib_uncompress(src.baseAddress, src.count, dst.baseAddress, &size) }
        }
        guard rc == 0, size == 2 * n else { throw Failure.corrupt }
        var samples = [UInt16](repeating: 0, count: n)
        planes.withUnsafeBufferPointer { p in
            samples.withUnsafeMutableBufferPointer { s in
                for y in 0..<height {
                    let row = y * width
                    var previous: UInt16 = y > 0 ? s[row - width] : 0
                    for x in 0..<width {
                        let d = UInt16(p[row + x]) | UInt16(p[n + row + x]) << 8
                        previous = previous &+ d
                        s[row + x] = previous
                    }
                }
            }
        }
        return samples
    }

    /// The samples of a frame depth message.
    public static func samples(of d: XRFrameDepth) throws -> [UInt16] {
        let w = Int(d.width), h = Int(d.height)
        switch d.encoding {
        case .zlibPlanes:
            return try decode(d.data, width: w, height: h)
        case .raw:
            guard d.data.count == 2 * w * h else { throw Failure.size }
            return (0..<(w * h)).map { UInt16(d.data[2 * $0]) | UInt16(d.data[2 * $0 + 1]) << 8 }
        }
    }
}

/// A decoded depth image with its projection: what the re-projection reads.
public struct XRDepthImage: Equatable, Sendable {
    public var width: Int, height: Int
    /// Inverse-depth samples (q / 65535 = near / z; 0: nothing drawn).
    public var samples: [UInt16]
    public var near: Float
    public var fov: XRFieldOfView

    public init(width: Int, height: Int, samples: [UInt16], near: Float = 0.1, fov: XRFieldOfView) {
        (self.width, self.height, self.samples, self.near, self.fov) = (width, height, samples, near, fov)
    }

    public init(_ d: XRFrameDepth) throws {
        self.init(width: Int(d.width), height: Int(d.height), samples: try XRDepthCodec.samples(of: d), near: d.near, fov: d.fov)
    }

    /// The sample nearest to source coordinates (u, v) ∈ [0, 1]² (v down).
    public func sample(u: Double, v: Double) -> UInt16 {
        let x = min(width - 1, max(0, Int(u * Double(width)))), y = min(height - 1, max(0, Int(v * Double(height))))
        return samples[y * width + x]
    }
}
