// Video frames for the display stream (display-stream.md §14): the damage
// the mirror found is copied into NVENC's input picture (which keeps the
// rest of the previous frame), and the whole picture is encoded as one
// access unit. Hardware encoding through CYcodeVideo (the NVIDIA driver's
// NVENC, opened at run time); the server offers a codec only where its
// runtime capability check passes.

#if os(Linux) && arch(arm64)
import CYcodeVideo
import Foundation
import YcodeDisplayStream

final class VideoFrameEncoder {
    let width: Int, height: Int, bitrate: Int
    private let encoder: OpaquePointer

    /// The default bit rate (kbit/s): YCODE_DISPLAY_VIDEO_KBPS, else 20 Mbit/s.
    static var defaultBitrate: Int { Int(ProcessInfo.processInfo.environment["YCODE_DISPLAY_VIDEO_KBPS"] ?? "") ?? 20_000 }

    static let available: Bool = yvid_enc_available() != 0

    /// What this host's NVENC can encode for the stream, best first (§14).
    static let offered: [DisplayEncoding] = {
        guard available else { return [] }
        var out: [DisplayEncoding] = []
        var hevc = yvid_enc_caps(), h264 = yvid_enc_caps(), err = [CChar](repeating: 0, count: 160)
        if yvid_enc_query(Int32(YVID_HEVC), &hevc, &err, err.count) == 0, hevc.supported != 0 {
            if hevc.yuv444 != 0 { out.append(.hevc444) }
            out.append(.hevc)
        }
        if yvid_enc_query(Int32(YVID_H264), &h264, &err, err.count) == 0, h264.supported != 0 { out.append(.h264) }
        return out
    }()

    /// The capabilities, for the server's log: codecs, 4:4:4, 10-bit, sizes (AV1 too: measured, not offered).
    static var capabilityLine: String {
        var parts: [String] = []
        for (name, codec) in [("h264", YVID_H264), ("hevc", YVID_HEVC), ("av1", YVID_AV1)] {
            var c = yvid_enc_caps(), err = [CChar](repeating: 0, count: 160)
            let rc = yvid_enc_query(Int32(codec), &c, &err, err.count)
            parts.append(rc != 0 ? "\(name): query failed" : c.supported == 0 ? "\(name): no"
                : "\(name): up to \(c.maxWidth)x\(c.maxHeight), 4:4:4 \(c.yuv444 != 0 ? "yes" : "no"), 10-bit \(c.tenBit != 0 ? "yes" : "no")")
        }
        return parts.joined(separator: "; ")
    }

    /// `qp` > 0: constant QP; else `constantBitrate`: CBR, VBV of one picture at `fps`; else VBR (§14).
    init?(encoding: DisplayEncoding, width: Int, height: Int, fps: Int, bitrateKbps: Int, qp: Int = 0, constantBitrate: Bool = false, log: (String) -> Void) {
        var err = [CChar](repeating: 0, count: 160)
        let codec = encoding == .h264 ? Int32(YVID_H264) : Int32(YVID_HEVC)
        var params = yvid_enc_params(codec: codec, yuv444: encoding == .hevc444 ? 1 : 0, fps: Int32(fps), bitrateKbps: Int32(bitrateKbps),
                                     qp: Int32(qp), constantBitrate: constantBitrate ? 1 : 0)
        guard let e = yvid_enc_open2(Int32(width), Int32(height), &params, &err, err.count) else {
            log("display server: WARNING: the \(encoding.name) encoder cannot open: \(String(cString: err))")
            return nil
        }
        encoder = e
        (self.width, self.height, self.bitrate) = (width, height, bitrateKbps)
    }

    deinit { yvid_enc_close(encoder) }

    /// Encodes the mirror's picture after `rects` changed; one tile, or nil on a failure.
    func encode(mirror: DisplayMirror, rects: [PixelRect], keyframe: Bool) -> (tile: DisplayTile, idr: Bool)? {
        var quads: [Int32] = []
        quads.reserveCapacity(rects.count * 4)
        for r in rects { quads += [Int32(r.x), Int32(r.y), Int32(r.width), Int32(r.height)] }
        var out: UnsafePointer<UInt8>?
        var size = 0
        var idr: Int32 = 0
        let rc = quads.withUnsafeBufferPointer { q in
            yvid_enc_encode(encoder, mirror.pixels.assumingMemoryBound(to: UInt8.self), mirror.stride, q.baseAddress,
                            keyframe ? -1 : Int32(rects.count), keyframe ? 1 : 0, &out, &size, &idr)
        }
        guard rc == 0, let out, size > 0 else { return nil }
        return (DisplayTile(x: 0, y: 0, width: width, height: height, data: Array(UnsafeBufferPointer(start: out, count: size))), idr != 0)
    }
}
#endif
