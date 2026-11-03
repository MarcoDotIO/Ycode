// `ycode-xr-viewer --record <file.mp4>` (specs/simulator/xr-viewer.md §7.1):
// what the wearer sees in the left eye — the simulator's picture with the
// rendered hands drawn over it — as a 1920 × 1080 H.264 MP4 at 60 frames per
// second. Frames are handed over by the headset loop without copying (the
// newest wins; the recorder never makes it wait). During the session the
// recorder's own thread scales, draws and JPEG-compresses each frame on the
// CPU into a spool file next to the MP4; the GPU's video encoder is left to
// the OpenXR runtime (WiVRn streams to the headset with it, and sharing it
// slowed the headset to about 20 Hz in run 3). When the session ends the
// spool is encoded to H.264 (NVENC through CYcodeVideo) and the spool removed.
// Nothing of the eye tracking is recorded unless `--record-cursor` asks for
// the gaze cursor to be drawn.
//
// The MP4 is written by Ycode's own minimal writer (ISO/IEC 14496-12 boxes
// and 14496-15's avcC; one track, one chunk): ftyp, mdat, then moov.

import CYcodeCodec
import CYcodeVideo
import Foundation
import YcodeDisplayStream
import YcodeRemoteViewer

/// One recorded frame: the picture's canvas and how it was rendered, the
/// hands and (optionally) the gaze in the XR base space.
struct XRRecordJob {
    var canvas: StreamCanvas
    var rendered: SpatialPose
    var fov: XRFieldOfView
    var hands: [XRHandJoints?]
    var pinching: [Bool]
    var gaze: SpatialPose?
    var time: UInt64
}

final class XRVideoRecorder: @unchecked Sendable {
    static let width = 1920, height = 1080
    let path: String
    /// Frames per second and the H.264 bit rate (kbit/s) of the file: 30 and
    /// 1000 by default (about 7.5 MB a minute at 1080p).
    let fps: Int, bitrateKbps: Int
    private let cond = NSCondition()
    private var pending: XRRecordJob?
    private var stopping = false
    private var thread: Thread?
    private(set) var framesWritten = 0, framesDropped = 0, encodeFailures = 0
    private var busyNs: UInt64 = 0
    private var writer: XRMP4Writer?
    private var encoder: OpaquePointer?
    private var spool: FileHandle?
    private var spooled = 0
    var spoolPath: String { path + ".spool" }
    private var image = [UInt8](repeating: 0, count: XRVideoRecorder.width * XRVideoRecorder.height * 4)
    private var scratch: [UInt8] = []
    let log: (String) -> Void

    init(path: String, fps: Int = 30, bitrateKbps: Int = 1000, log: @escaping (String) -> Void) {
        self.path = path
        self.fps = max(1, min(60, fps))
        self.bitrateKbps = max(200, min(50_000, bitrateKbps))
        self.log = log
    }

    func start() -> Bool {
        guard yvid_enc_available() != 0 else { log("ycode-xr-viewer: recording: no H.264 encoder (NVENC) here"); return false }
        guard ycodec_jpeg_available() != 0, ycodec_jpeg_decode_available() != 0 else {
            log("ycode-xr-viewer: recording: JPEG is not available in this build"); return false
        }
        FileManager.default.createFile(atPath: spoolPath, contents: nil)
        guard let f = FileHandle(forWritingAtPath: spoolPath) else { log("ycode-xr-viewer: recording: cannot write \(spoolPath)"); return false }
        spool = f
        let t = Thread { [self] in run() }
        t.name = "xr-record"
        t.qualityOfService = .utility
        thread = t
        t.start()
        return true
    }

    /// From the headset loop: the newest state (no copy, never waits).
    func submit(_ job: XRRecordJob) {
        cond.withLock {
            pending = job
            cond.signal()
        }
    }

    func stop() -> String {
        cond.withLock { stopping = true; cond.signal() }
        while thread?.isFinished == false { Thread.sleep(forTimeInterval: 0.01) }
        try? spool?.close()
        spool = nil
        let ms = spooled > 0 ? Double(busyNs) / 1e6 / Double(spooled) : 0
        let live = String(format: "%.1f ms of CPU work per frame on the recorder's thread during the session", ms)
        // After the session: the spool to H.264 and MP4.
        let t0 = viewerNanoseconds()
        let ok = encodeSpool()
        try? FileManager.default.removeItem(atPath: spoolPath)
        return "recording \(path): \(framesWritten) frames, \(framesDropped) dropped, \(encodeFailures) encode failures; \(live); "
            + String(format: "encoded in %.1f s after the session", Double(viewerNanoseconds() - t0) / 1e9) + (ok ? "" : " (not finished)")
    }

    /// The spooled JPEG frames → NVENC → MP4.
    private func encodeSpool() -> Bool {
        guard let data = FileManager.default.contents(atPath: spoolPath), !data.isEmpty else { return false }
        var err = [CChar](repeating: 0, count: 200)
        guard let e = yvid_enc_open(Int32(Self.width), Int32(Self.height), Int32(fps), Int32(bitrateKbps), &err, err.count) else {
            log("ycode-xr-viewer: recording: no H.264 encoder (\(text(err)))"); return false
        }
        encoder = e
        defer { yvid_enc_close(e); encoder = nil }
        do { writer = try XRMP4Writer(path: path, width: Self.width, height: Self.height) } catch {
            log("ycode-xr-viewer: recording: \(error)"); return false
        }
        let bytes = [UInt8](data)
        var at = 0
        func u(_ n: Int) -> UInt64 { var v: UInt64 = 0; for i in 0..<n { v |= UInt64(bytes[at + i]) << (8 * UInt64(i)) }; at += n; return v }
        while at + 12 <= bytes.count {
            let time = u(8), size = Int(u(4))
            guard at + size <= bytes.count else { break }
            let ok = bytes.withUnsafeBufferPointer { b in
                image.withUnsafeMutableBytes { d in
                    ycodec_jpeg_decode_bgra(b.baseAddress! + at, size, Int32(Self.width), Int32(Self.height),
                                            d.baseAddress!.assumingMemoryBound(to: UInt8.self), Self.width * 4)
                }
            }
            at += size
            if ok == 0 { encode(at: time) } else { encodeFailures += 1 }
        }
        return (try? writer?.finish()) != nil
    }

    /// The drawn frame as a JPEG into the spool (CPU only).
    private func spoolFrame(at time: UInt64) {
        var out: UnsafeMutablePointer<UInt8>?
        var size = 0
        let rc = image.withUnsafeBufferPointer { ycodec_jpeg_encode_bgra($0.baseAddress, Int32(Self.width), Int32(Self.height), Self.width * 4, 90, &out, &size) }
        guard rc == 0, let out else { encodeFailures += 1; return }
        defer { ycodec_free(out) }
        var head = [UInt8]()
        for i in 0..<8 { head.append(UInt8(truncatingIfNeeded: time >> (8 * UInt64(i)))) }
        for i in 0..<4 { head.append(UInt8(truncatingIfNeeded: UInt32(size) >> (8 * UInt32(i)))) }
        spool?.write(Data(head) + Data(bytes: out, count: size))
        spooled += 1
    }

    /// `fps` frames a second on the recorder's own clock, each from the newest
    /// state the headset loop handed over; a tick that falls behind is skipped.
    private func run() {
        let period: UInt64 = 1_000_000_000 / UInt64(fps)
        var next = viewerNanoseconds()
        while true {
            let job: XRRecordJob? = cond.withLock {
                while pending == nil && !stopping { cond.wait() }
                return stopping ? nil : pending
            }
            guard let job else { return }
            // Only while the headset is worn: the loop hands frames over only
            // while it tracks; a stale state is not repeated into the file.
            if viewerNanoseconds() &- job.time > 200_000_000 {
                Thread.sleep(forTimeInterval: 0.02)
                next = viewerNanoseconds()
                continue
            }
            let now = viewerNanoseconds()
            if now < next {
                Thread.sleep(forTimeInterval: Double(next - now) / 1e9)
            } else if now - next > period {
                framesDropped += Int((now - next) / period)
                next = now
            }
            let t0 = viewerNanoseconds()
            render(job)
            spoolFrame(at: next)
            busyNs += viewerNanoseconds() - t0
            next += period
        }
    }

    // MARK: Drawing

    private func render(_ j: XRRecordJob) {
        let W = Self.width, H = Self.height
        let c = j.canvas
        // The picture, scaled to 1920 × 1080 (a 2 × 2 box from the full size).
        if c.format == .nv12 {
            if scratch.count < c.width * c.height * 4 { scratch = [UInt8](repeating: 0, count: c.width * c.height * 4) }
            _ = c.withNV12 { y, uv, pitch, _ in
                scratch.withUnsafeMutableBytes { yvid_nv12_to_bgrx(y, uv, Int32(pitch), Int32(c.width), Int32(c.height), $0.baseAddress!.assumingMemoryBound(to: UInt8.self), c.width * 4) }
            }
            scratch.withUnsafeBytes { scale(from: $0.baseAddress!, width: c.width, height: c.height, stride: c.width * 4) }
        } else {
            c.withPixels { base, stride, _ in scale(from: base, width: c.width, height: c.height, stride: stride) }
        }
        // The hands, as the left eye sees them over the picture (in the
        // cropped part's pixels: the picture's focal length scaled to it).
        let crop = Self.crop(width: c.width, height: c.height)
        let k = Double(W) / Double(crop.width)
        let fFull = Double(c.width) / 2 / tan(max(0.1, j.fov.right))
        let cx = (Double(c.width) / 2 - Double(crop.x)) * k, cy = (Double(c.height) / 2 - Double(crop.y)) * k
        let f = fFull * k
        let inv = j.rendered.rotation.conjugate
        func project(_ p: SpatialVector) -> (Double, Double, Double)? {
            let q = inv.rotate(p - j.rendered.position)
            guard q.z < -0.05 else { return nil }
            return (cx + f * q.x / -q.z, cy - f * q.y / -q.z, f / -q.z)
        }
        for s in XRHandModel.sprites(hands: j.hands, pinching: j.pinching, eye: j.rendered.position) {
            guard let (x, y, k) = project(s.pose.position) else { continue }
            disc(x: x, y: y, radius: s.size / 2 * k, highlight: s.highlight)
        }
        if let g = j.gaze, let (x, y, _) = project(g.position + g.forward * 2) {
            ring(x: x, y: y, radius: 14)
        }
    }

    /// The centred 16:9 part of a picture of `w` × `h` (a tall or square
    /// display is cropped top and bottom, a wide one at the sides).
    static func crop(width w: Int, height h: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        if w * 9 >= h * 16 { let cw = h * 16 / 9; return ((w - cw) / 2, 0, cw, h) }
        let ch = w * 9 / 16
        return (0, (h - ch) / 2, w, ch)
    }

    private func scale(from src: UnsafeRawPointer, width fullW: Int, height fullH: Int, stride: Int) {
        let W = Self.width, H = Self.height
        let c = Self.crop(width: fullW, height: fullH)
        let s = src.assumingMemoryBound(to: UInt8.self).advanced(by: c.y * stride + c.x * 4)
        let (w, h) = (c.width, c.height)
        image.withUnsafeMutableBufferPointer { d in
            if w == 2 * W && h == 2 * H {
                for y in 0..<H {
                    let r0 = s + 2 * y * stride, r1 = r0 + stride
                    for x in 0..<W {
                        let o = (y * W + x) * 4, i = 8 * x
                        for ch in 0..<3 {
                            d[o + ch] = UInt8((Int(r0[i + ch]) + Int(r0[i + 4 + ch]) + Int(r1[i + ch]) + Int(r1[i + 4 + ch]) + 2) >> 2)
                        }
                        d[o + 3] = 255
                    }
                }
            } else {
                for y in 0..<H {
                    let row = s + (y * h / H) * stride
                    for x in 0..<W {
                        let i = (x * w / W) * 4, o = (y * W + x) * 4
                        (d[o], d[o + 1], d[o + 2], d[o + 3]) = (row[i], row[i + 1], row[i + 2], 255)
                    }
                }
            }
        }
    }

    private func disc(x: Double, y: Double, radius r: Double, highlight: Bool) {
        let W = Self.width, H = Self.height
        let (b, g, rr, peak): (Double, Double, Double, Double) = highlight ? (255, 210, 90, 0.95) : (240, 240, 240, 0.55)
        let x0 = max(0, Int(x - r)), x1 = min(W - 1, Int(x + r)), y0 = max(0, Int(y - r)), y1 = min(H - 1, Int(y + r))
        guard r > 0.5, x0 <= x1, y0 <= y1 else { return }
        image.withUnsafeMutableBufferPointer { d in
            for py in y0...y1 {
                for px in x0...x1 {
                    let dist = ((Double(px) - x) * (Double(px) - x) + (Double(py) - y) * (Double(py) - y)).squareRoot() / r
                    guard dist < 1 else { continue }
                    let a = peak * min(1, (1 - dist) / 0.25)
                    let o = (py * W + px) * 4
                    d[o] = UInt8(Double(d[o]) * (1 - a) + b * a)
                    d[o + 1] = UInt8(Double(d[o + 1]) * (1 - a) + g * a)
                    d[o + 2] = UInt8(Double(d[o + 2]) * (1 - a) + rr * a)
                }
            }
        }
    }

    private func ring(x: Double, y: Double, radius r: Double) {
        let W = Self.width, H = Self.height
        image.withUnsafeMutableBufferPointer { d in
            for py in max(0, Int(y - r - 2))...min(H - 1, Int(y + r + 2)) {
                for px in max(0, Int(x - r - 2))...min(W - 1, Int(x + r + 2)) {
                    let dist = ((Double(px) - x) * (Double(px) - x) + (Double(py) - y) * (Double(py) - y)).squareRoot()
                    guard abs(dist - r) < 2 else { continue }
                    let o = (py * W + px) * 4
                    (d[o], d[o + 1], d[o + 2]) = (255, 255, 255)
                }
            }
        }
    }

    // MARK: Encoding

    private func encode(at time: UInt64) {
        guard let e = encoder, let writer else { return }
        var out: UnsafePointer<UInt8>?
        var size = 0
        var idr: Int32 = 0
        // An IDR every 2 s: the file can be cut and seeked.
        let force: Int32 = framesWritten % (2 * fps) == 0 ? 1 : 0
        let rc = image.withUnsafeBufferPointer { yvid_enc_encode(e, $0.baseAddress, Self.width * 4, nil, -1, force, &out, &size, &idr) }
        guard rc == 0, let out, size > 0 else { encodeFailures += 1; return }
        do {
            try writer.append(annexB: UnsafeBufferPointer(start: out, count: size), time: time)
            framesWritten += 1
        } catch {
            encodeFailures += 1
        }
    }
}

// MARK: - MP4

/// A minimal MP4 writer for one H.264 track (Annex B access units in).
final class XRMP4Writer {
    enum WriterError: Error, CustomStringConvertible {
        case cannotOpen(String), noParameterSets
        var description: String {
            switch self {
            case .cannotOpen(let p): "cannot write \(p)"
            case .noParameterSets: "the stream had no SPS/PPS"
            }
        }
    }

    let width: Int, height: Int
    private let file: FileHandle
    private var sps: [UInt8]?, pps: [UInt8]?
    private var sizes: [UInt32] = [], times: [UInt64] = [], sync: [UInt32] = []
    private var mdatStart: UInt64 = 0, offset: UInt64 = 0
    static let timescale: UInt64 = 90_000

    init(path: String, width: Int, height: Int) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let f = FileHandle(forWritingAtPath: path) else { throw WriterError.cannotOpen(path) }
        file = f
        (self.width, self.height) = (width, height)
        var ftyp = XRBox("ftyp")
        ftyp.fourcc("isom"); ftyp.u32(512); for b in ["isom", "iso2", "avc1", "mp41"] { ftyp.fourcc(b) }
        try write(ftyp.bytes)
        // mdat with a 64-bit size, patched at the end.
        var head = [UInt8]()
        head += XRBox.be32(1) + Array("mdat".utf8) + XRBox.be64(0)
        mdatStart = offset
        try write(head)
    }

    private func write(_ b: [UInt8]) throws {
        try file.write(contentsOf: Data(b))
        offset += UInt64(b.count)
    }

    /// The NAL units of an Annex B access unit.
    static func nalUnits(_ p: UnsafeBufferPointer<UInt8>) -> [ArraySlice<UInt8>] {
        let a = Array(p)
        var starts: [(Int, Int)] = []  // (start code position, payload start)
        var i = 0
        while i + 3 <= a.count {
            if a[i] == 0, a[i + 1] == 0, a[i + 2] == 1 { starts.append((i > 0 && a[i - 1] == 0 ? i - 1 : i, i + 3)); i += 3 } else { i += 1 }
        }
        return starts.enumerated().map { k, s in a[s.1..<(k + 1 < starts.count ? starts[k + 1].0 : a.count)] }
    }

    func append(annexB p: UnsafeBufferPointer<UInt8>, time: UInt64) throws {
        var sample: [UInt8] = []
        var key = false
        for nal in Self.nalUnits(p) where !nal.isEmpty {
            switch nal.first! & 0x1F {
            case 7: if sps == nil { sps = Array(nal) }
            case 8: if pps == nil { pps = Array(nal) }
            case 9: break
            default:
                if nal.first! & 0x1F == 5 { key = true }
                sample += XRBox.be32(UInt32(nal.count)) + Array(nal)
            }
        }
        guard !sample.isEmpty else { return }
        if sizes.isEmpty && !key { return }  // the file starts at an IDR
        try write(sample)
        sizes.append(UInt32(sample.count))
        times.append(time)
        if key { sync.append(UInt32(sizes.count)) }
    }

    func finish() throws {
        defer { try? file.close() }
        guard let sps, let pps, sps.count >= 4, !sizes.isEmpty else { throw WriterError.noParameterSets }
        // Durations from the frames' times (variable rate), the last one 1/60 s.
        var durations: [UInt32] = []
        for k in 0..<times.count {
            let d = k + 1 < times.count ? (times[k + 1] &- times[k]) * Self.timescale / 1_000_000_000 : Self.timescale / 60
            durations.append(UInt32(max(1, min(d, Self.timescale))))
        }
        let total = durations.reduce(UInt64(0)) { $0 + UInt64($1) }
        // Patch mdat's size.
        try file.seek(toOffset: mdatStart + 8)
        try file.write(contentsOf: Data(XRBox.be64(offset - mdatStart)))
        try file.seekToEnd()
        let dataStart = mdatStart + 16
        let movieDuration = total * 1000 / Self.timescale

        var mvhd = XRBox("mvhd")
        mvhd.u32(0); mvhd.u32(0); mvhd.u32(0); mvhd.u32(1000); mvhd.u32(UInt32(movieDuration))
        mvhd.u32(0x0001_0000); mvhd.u16(0x0100); mvhd.zeros(10); mvhd.matrix(); mvhd.zeros(24); mvhd.u32(2)
        var tkhd = XRBox("tkhd")
        tkhd.u32(3); tkhd.u32(0); tkhd.u32(0); tkhd.u32(1); tkhd.u32(0); tkhd.u32(UInt32(movieDuration))
        tkhd.zeros(8); tkhd.u16(0); tkhd.u16(0); tkhd.u16(0); tkhd.u16(0); tkhd.matrix()
        tkhd.u32(UInt32(width) << 16); tkhd.u32(UInt32(height) << 16)
        var mdhd = XRBox("mdhd")
        mdhd.u32(0); mdhd.u32(0); mdhd.u32(0); mdhd.u32(UInt32(Self.timescale)); mdhd.u32(UInt32(total)); mdhd.u16(0x55C4); mdhd.u16(0)
        var hdlr = XRBox("hdlr")
        hdlr.u32(0); hdlr.u32(0); hdlr.fourcc("vide"); hdlr.zeros(12); hdlr.raw(Array("Ycode headset view".utf8) + [0])
        var vmhd = XRBox("vmhd"); vmhd.u32(1); vmhd.zeros(8)
        var url = XRBox("url "); url.u32(1)
        var dref = XRBox("dref"); dref.u32(0); dref.u32(1); dref.child(url)
        var dinf = XRBox("dinf"); dinf.child(dref)
        var avcC = XRBox("avcC")
        avcC.raw([1, sps[1], sps[2], sps[3], 0xFF, 0xE1]); avcC.u16(UInt16(sps.count)); avcC.raw(sps)
        avcC.raw([1]); avcC.u16(UInt16(pps.count)); avcC.raw(pps)
        var avc1 = XRBox("avc1")
        avc1.zeros(6); avc1.u16(1); avc1.zeros(16); avc1.u16(UInt16(width)); avc1.u16(UInt16(height))
        avc1.u32(0x0048_0000); avc1.u32(0x0048_0000); avc1.u32(0); avc1.u16(1); avc1.zeros(32); avc1.u16(0x18); avc1.u16(0xFFFF)
        avc1.child(avcC)
        var stsd = XRBox("stsd"); stsd.u32(0); stsd.u32(1); stsd.child(avc1)
        var stts = XRBox("stts"); stts.u32(0)
        var runs: [(UInt32, UInt32)] = []
        for d in durations { if let last = runs.last, last.1 == d { runs[runs.count - 1].0 += 1 } else { runs.append((1, d)) } }
        stts.u32(UInt32(runs.count)); for r in runs { stts.u32(r.0); stts.u32(r.1) }
        var stss = XRBox("stss"); stss.u32(0); stss.u32(UInt32(sync.count)); for s in sync { stss.u32(s) }
        var stsc = XRBox("stsc"); stsc.u32(0); stsc.u32(1); stsc.u32(1); stsc.u32(UInt32(sizes.count)); stsc.u32(1)
        var stsz = XRBox("stsz"); stsz.u32(0); stsz.u32(0); stsz.u32(UInt32(sizes.count)); for s in sizes { stsz.u32(s) }
        var co64 = XRBox("co64"); co64.u32(0); co64.u32(1); co64.u64(dataStart)
        var stbl = XRBox("stbl"); for b in [stsd, stts, stss, stsc, stsz, co64] { stbl.child(b) }
        var minf = XRBox("minf"); minf.child(vmhd); minf.child(dinf); minf.child(stbl)
        var mdia = XRBox("mdia"); mdia.child(mdhd); mdia.child(hdlr); mdia.child(minf)
        var trak = XRBox("trak"); trak.child(tkhd); trak.child(mdia)
        var moov = XRBox("moov"); moov.child(mvhd); moov.child(trak)
        try write(moov.bytes)
    }
}

/// An ISO base media box being built.
struct XRBox {
    let type: String
    var body: [UInt8] = []
    init(_ type: String) { self.type = type }

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func be64(_ v: UInt64) -> [UInt8] { be32(UInt32(v >> 32)) + be32(UInt32(v & 0xFFFF_FFFF)) }

    mutating func u16(_ v: UInt16) { body += [UInt8(v >> 8), UInt8(v & 0xFF)] }
    mutating func u32(_ v: UInt32) { body += Self.be32(v) }
    mutating func u64(_ v: UInt64) { body += Self.be64(v) }
    mutating func fourcc(_ s: String) { body += Array(s.utf8.prefix(4)) }
    mutating func zeros(_ n: Int) { body += [UInt8](repeating: 0, count: n) }
    mutating func raw(_ b: [UInt8]) { body += b }
    mutating func child(_ b: XRBox) { body += b.bytes }
    /// The identity transformation matrix of mvhd and tkhd.
    mutating func matrix() { for v: UInt32 in [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000] { u32(v) } }

    var bytes: [UInt8] { Self.be32(UInt32(8 + body.count)) + Array(type.utf8) + body }
}
