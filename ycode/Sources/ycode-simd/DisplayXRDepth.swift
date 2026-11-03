// The headset mode's depth and environment (specs/simulator/xr-depth.md §4):
// with `xr.depthDownscale` in the client hello, each frame the server sends
// is followed by the depth the GPU backend's tap captured for the surface it
// shows (frame depth 0x0C); with `xr.environment`, the room's environment
// cube goes out once and again whenever it changes (0x0D).

import CYcodeCodec
import Foundation
import YcodeDisplayStream
import YcodeHypervisor
import YcodeVulkan
import YcodeXRReprojection

#if os(Linux) && arch(arm64)

final class DisplayXRDepthSender: @unchecked Sendable {
    let downscale: Int
    let environment: Bool
    private var lastSerial: UInt64 = 0
    private var lastData: [UInt8] = []
    private var lastSize = (0, 0)
    private var environmentSerial: UInt64 = 0
    private(set) var sent = 0, exact = 0, missing = 0, bytes = 0, encodeNs: UInt64 = 0, environments = 0
    private var ages: [UInt64] = []

    init(request: XRClientRequest) {
        downscale = min(8, max(0, request.depthDownscale ?? 0))
        environment = request.environment == true
        XRDepthTap.shared.request(downscale: downscale)
        XRDepthTap.shared.request(environment: environment)
    }

    var active: Bool { downscale > 0 || environment }

    func stop() {
        XRDepthTap.shared.request(downscale: 0)
        XRDepthTap.shared.request(environment: false)
    }

    /// After a frame: its depth (nothing when the tap has none yet). False on a send error.
    func afterFrame(_ connection: DisplayConnection, sequence: UInt64, guestFrame: UInt64, view: XRView,
                    fov: XRFieldOfView, surface: UInt32) -> Bool {
        guard downscale > 0 else { return true }
        guard let (c, isExact) = XRDepthTap.shared.depth(forSurface: surface) else { missing += 1; return true }
        let t0 = monotonicNanoseconds()
        if c.serial != lastSerial || lastData.isEmpty {
            guard let packed = try? XRDepthCodec.encode(c.samples, width: c.width, height: c.height) else { return true }
            (lastSerial, lastData, lastSize) = (c.serial, packed, (c.width, c.height))
        }
        encodeNs += monotonicNanoseconds() - t0
        var flags: XRFrameDepth.Flags = isExact ? [] : [.otherFrame]
        flags.insert(c.windowsPasses > 0 ? .windowsMerged : .roomOnly)
        flags.insert(.windowsMarked)
        let d = XRFrameDepth(frameSequence: sequence, guestFrame: guestFrame, view: view, flags: flags, width: UInt16(lastSize.0),
                             height: UInt16(lastSize.1), near: 0.1, fov: fov, capturedAt: c.recordedAt, data: lastData)
        do { try connection.send(.frameDepth(d)) } catch { return false }
        sent += 1
        if isExact { exact += 1 }
        bytes += lastData.count + 60
        if ages.count < 100_000 { ages.append(t0 &- c.recordedAt) }
        return true
    }

    /// The environment when it is new. False on a send error.
    func sendEnvironment(_ connection: DisplayConnection) -> Bool {
        guard environment, let e = XRDepthTap.shared.newestEnvironment(), e.serial != environmentSerial else { return true }
        environmentSerial = e.serial
        var out = [UInt8](repeating: 0, count: ycodec_zlib_bound(e.halfFloats.count))
        var size = out.count
        let rc = e.halfFloats.withUnsafeBufferPointer { src in out.withUnsafeMutableBufferPointer { ycodec_zlib_compress(src.baseAddress, src.count, 3, $0.baseAddress, &size) } }
        let compressed = rc == 0
        let m = XREnvironment(serial: UInt32(truncatingIfNeeded: e.serial), compressed: compressed, faceSize: UInt16(e.size), level: UInt8(e.level),
                              data: compressed ? Array(out[0..<size]) : e.halfFloats)
        do { try connection.send(.environment(m)) } catch { return false }
        environments += 1
        bytes += m.data.count
        return true
    }

    var summary: String {
        let a = ages.sorted()
        let age = a.isEmpty ? 0 : Double(a[a.count / 2]) / 1e6
        return String(format: "depth 1/%d: %d sent (%d paired by provenance, %d frames without), %.1f MB, encode %.2f ms each, capture age p50 %.1f ms; %d environments; ",
                      downscale, sent, exact, missing, Double(bytes) / 1e6, sent > 0 ? Double(encodeNs) / 1e6 / Double(sent) : 0, age, environments)
            + XRDepthTap.shared.summary
    }
}

#endif
