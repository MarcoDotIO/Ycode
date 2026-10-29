// V4L2 cameras (camera-host.md §2, §3): discovery, format negotiation, and
// memory-mapped streaming, through CYcodeCamera's ioctl wrappers. Written
// from the public Linux media API (V4L2) documentation. Off Linux there are
// no V4L2 devices (every call reports ENOSYS).

import CYcodeCamera
import Foundation

/// V4L2 device access: the constants Ycode uses (values from the public
/// `videodev2.h`), node discovery, and the capture-device operations
/// (`camera-host.md` §2, §3).
public enum V4L2 {
    // Capability bits (videodev2.h).
    /// `V4L2_CAP_VIDEO_CAPTURE`: the node captures video (`camera-host.md` §2.1).
    public static let capVideoCapture: UInt32 = 0x0000_0001
    /// `V4L2_CAP_STREAMING`: the node supports streaming I/O (`camera-host.md` §2.1).
    public static let capStreaming: UInt32 = 0x0400_0000
    // Buffer flags.
    static let bufFlagError: UInt32 = 0x0000_0040
    static let bufTimestampMask: UInt32 = 0x0000_e000
    static let bufTimestampMonotonic: UInt32 = 0x0000_2000
    // Colorimetry.
    static let colorspaceJPEG: UInt32 = 7
    static let colorspaceREC709: UInt32 = 3
    static let ycbcrEnc601: UInt32 = 1
    static let ycbcrEnc709: UInt32 = 2
    static let quantizationFull: UInt32 = 1
    static let quantizationLimited: UInt32 = 2

    /// The device nodes `/dev/video<N>`, in number order.
    public static func nodes(directory: String = "/dev") -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("video"), let n = Int(name.dropFirst(5)) else { return nil }
            return (n, directory + "/" + name)
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// The capture devices (nodes with video capture and streaming; a UVC
    /// camera's metadata node is left out), with their formats, sizes and
    /// intervals. Nodes that cannot be opened are skipped; their errors
    /// come back in `problems`.
    public static func devices(directory: String = "/dev") -> (devices: [CameraDevice], problems: [String]) {
        var devices: [CameraDevice] = [], problems: [String] = []
        for path in nodes(directory: directory) {
            let fd = ycam_open(path)
            guard fd >= 0 else {
                problems.append(CameraError.errno("open", -fd, path: path).message)
                continue
            }
            defer { ycam_close(fd) }
            var caps = ycam_caps()
            guard ycam_query_caps(fd, &caps) == 0 else { continue }
            guard caps.device_caps & capVideoCapture != 0, caps.device_caps & capStreaming != 0 else { continue }
            let card = string(&caps.card), bus = string(&caps.bus_info), driver = string(&caps.driver)
            devices.append(CameraDevice(id: "v4l2:" + (bus.isEmpty ? path : bus), kind: .v4l2, name: card, path: path,
                                        driver: driver, busInfo: bus, formats: formats(fd)))
        }
        return (devices, problems)
    }

    static func string<T>(_ tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// VIDIOC_ENUM_FMT, _FRAMESIZES, _FRAMEINTERVALS for one open node.
    static func formats(_ fd: Int32) -> [CameraFormatDescription] {
        var result: [CameraFormatDescription] = []
        var index: UInt32 = 0
        while true {
            var code: UInt32 = 0, flags: UInt32 = 0
            var desc = [CChar](repeating: 0, count: 32)
            guard ycam_enum_format(fd, index, &code, &flags, &desc) == 0 else { break }
            index += 1
            let name = desc.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            let format = CameraSourceFormat(rawValue: code)
            result.append(CameraFormatDescription(format: format, name: name, sizes: sizes(fd, format)))
        }
        return result
    }

    /// Common sizes offered from a stepwise or continuous range.
    static let commonSizes = [(160, 120), (320, 240), (352, 288), (640, 360), (640, 480), (800, 600), (960, 540),
                              (1024, 576), (1280, 720), (1280, 960), (1600, 900), (1920, 1080), (2560, 1440), (3840, 2160)]

    static func sizes(_ fd: Int32, _ format: CameraSourceFormat) -> [CameraFrameSize] {
        var out: [CameraFrameSize] = []
        var index: UInt32 = 0
        while true {
            var type: UInt32 = 0
            var v = [UInt32](repeating: 0, count: 6)
            guard ycam_enum_framesize(fd, format.rawValue, index, &type, &v) == 0 else { break }
            index += 1
            if type == 1 {
                out.append(CameraFrameSize(width: Int(v[0]), height: Int(v[1]),
                                           intervals: intervals(fd, format, v[0], v[1])))
            } else {
                let (minW, maxW, stepW, minH, maxH, stepH) = (v[0], v[1], max(v[2], 1), v[3], v[4], max(v[5], 1))
                for (w, h) in commonSizes {
                    let (w, h) = (UInt32(w), UInt32(h))
                    guard w >= minW, w <= maxW, h >= minH, h <= maxH, (w - minW) % stepW == 0, (h - minH) % stepH == 0 else { continue }
                    out.append(CameraFrameSize(width: Int(w), height: Int(h), intervals: intervals(fd, format, w, h)))
                }
                break
            }
        }
        return out
    }

    static func intervals(_ fd: Int32, _ format: CameraSourceFormat, _ w: UInt32, _ h: UInt32) -> [CameraFrameInterval] {
        var out: [CameraFrameInterval] = []
        var index: UInt32 = 0
        while true {
            var type: UInt32 = 0
            var v = [UInt32](repeating: 0, count: 6)
            guard ycam_enum_frameinterval(fd, format.rawValue, w, h, index, &type, &v) == 0 else { break }
            index += 1
            if type == 1 {
                if v[0] > 0, v[1] > 0 { out.append(CameraFrameInterval(numerator: v[0], denominator: v[1])) }
            } else {
                // Stepwise: the fastest and slowest ends, and 30 fps when inside.
                let fastest = CameraFrameInterval(numerator: v[0], denominator: v[1])
                let slowest = CameraFrameInterval(numerator: v[2], denominator: v[3])
                out.append(fastest)
                if fastest.framesPerSecond > 30, slowest.framesPerSecond < 30 { out.append(CameraFrameInterval(numerator: 1, denominator: 30)) }
                if slowest != fastest { out.append(slowest) }
                break
            }
        }
        return out
    }
}

/// Format negotiation (§3.2), a pure function of what the device offers.
public enum CameraNegotiation {
    public struct Choice: Equatable, Sendable {
        public var format: CameraSourceFormat
        public var width: Int, height: Int
        public var interval: CameraFrameInterval
    }

    /// The best (format, size, interval) for a request:
    /// 1. size: the requested size; else the smallest size that covers it
    ///    (both sides at least as large); else the largest smaller size;
    /// 2. a format whose rate at that size reaches the request (within 5 %);
    /// 3. format preference: NV12, YUYV, UYVY, YU12, YV12, then MJPEG;
    /// 4. the faster rate.
    /// The interval is the slowest one that still reaches the requested
    /// rate, or the fastest when none does. Unsupported formats are skipped.
    public static func choose(_ formats: [CameraFormatDescription], width: Int, height: Int, framesPerSecond: Double,
                              only: CameraSourceFormat? = nil) -> Choice? {
        typealias Key = (Int, Int, Int, Int, Double)
        var best: (key: Key, choice: Choice)?
        for f in formats where f.format.isSupported && (only == nil || only == f.format) {
            let rank = CameraSourceFormat.supported.firstIndex(of: f.format)!
            for s in f.sizes where !s.intervals.isEmpty {
                let sizeClass: Int, areaKey: Int
                let area = s.width * s.height
                if s.width == width && s.height == height {
                    (sizeClass, areaKey) = (0, 0)
                } else if s.width >= width && s.height >= height {
                    (sizeClass, areaKey) = (1, area)
                } else {
                    (sizeClass, areaKey) = (2, -area)
                }
                let maxFPS = s.maxFramesPerSecond
                let meets = maxFPS >= framesPerSecond * 0.95
                let key: Key = (sizeClass, areaKey, meets ? 0 : 1, rank, -maxFPS)
                if best == nil || key < best!.key {
                    let reaching = s.intervals.filter { $0.framesPerSecond >= framesPerSecond * 0.95 }
                    let interval = reaching.min { $0.framesPerSecond < $1.framesPerSecond } ?? s.intervals[0]
                    best = (key, Choice(format: f.format, width: s.width, height: s.height, interval: interval))
                }
            }
        }
        return best?.choice
    }
}

/// An open, streaming V4L2 capture device.
public final class V4L2Capture: CameraCapture, @unchecked Sendable {
    public let device: CameraDevice
    public private(set) var format: CameraStreamFormat
    private var fd: Int32
    private var buffers: [(address: UnsafeMutableRawPointer, length: UInt32)] = []
    private var streaming = false
    private let path: String
    /// Frames the driver flagged as corrupt or empty (skipped).
    public private(set) var corruptFrames = 0

    /// Opens `device`, negotiates (§3.2), maps `bufferCount` buffers and
    /// starts streaming.
    public init(device: CameraDevice, configuration: CameraConfiguration, bufferCount: Int = 4) throws {
        guard let path = device.path else { throw CameraError(.noDevice, "\(device.id) has no device node") }
        self.device = device
        self.path = path
        guard let choice = CameraNegotiation.choose(device.formats, width: configuration.width, height: configuration.height,
                                                    framesPerSecond: configuration.framesPerSecond,
                                                    only: configuration.sourceFormat) else {
            throw CameraError(.unsupported, "\(path): no format Ycode converts (\(device.formats.map { "\($0.format)" }.joined(separator: ", ")))")
        }
        let fd = ycam_open(path)
        guard fd >= 0 else { throw CameraError.errno("open", -fd, path: path) }
        self.fd = fd
        format = CameraStreamFormat(source: choice.format, width: choice.width, height: choice.height, interval: choice.interval,
                                    colorimetry: .video601, output: configuration.output)
        do {
            try configure(choice, bufferCount: bufferCount)
        } catch {
            close()
            throw error
        }
    }

    private func configure(_ choice: CameraNegotiation.Choice, bufferCount: Int) throws {
        var f = ycam_format()
        f.width = UInt32(choice.width)
        f.height = UInt32(choice.height)
        f.pixelformat = choice.format.rawValue
        var r = ycam_set_format(fd, &f, 0)
        guard r == 0 else { throw CameraError.errno("VIDIOC_S_FMT", -r, path: path) }
        let got = CameraSourceFormat(rawValue: f.pixelformat)
        guard got.isSupported else { throw CameraError(.unsupported, "\(path): driver chose \(got)") }
        var num = choice.interval.numerator, den = choice.interval.denominator
        let interval = ycam_set_interval(fd, &num, &den) == 0 && num > 0 && den > 0
            ? CameraFrameInterval(numerator: num, denominator: den) : choice.interval
        format = CameraStreamFormat(source: got, width: Int(f.width), height: Int(f.height), interval: interval,
                                    colorimetry: Self.colorimetry(f), output: format.output)
        bytesPerLine = Int(f.bytesperline) > 0 ? Int(f.bytesperline) : (got == .yuyv || got == .uyvy ? Int(f.width) * 2 : Int(f.width))
        r = ycam_request_buffers(fd, UInt32(bufferCount))
        guard r > 0 else { throw CameraError.errno("VIDIOC_REQBUFS", r == 0 ? ENOMEM : -r, path: path) }
        for i in 0..<UInt32(r) {
            var address: UnsafeMutableRawPointer?
            var length: UInt32 = 0
            let m = ycam_map_buffer(fd, i, &address, &length)
            guard m == 0, let address else { throw CameraError.errno("mmap", -m, path: path) }
            buffers.append((address, length))
        }
        for i in buffers.indices {
            let q = ycam_queue(fd, UInt32(i))
            guard q == 0 else { throw CameraError.errno("VIDIOC_QBUF", -q, path: path) }
        }
        r = ycam_stream(fd, 1)
        guard r == 0 else { throw CameraError.errno("VIDIOC_STREAMON", -r, path: path) }
        streaming = true
    }

    private var bytesPerLine = 0

    /// The Y'CbCr encoding the driver reports (§4.1). JPEG is full range;
    /// otherwise the driver's quantization and encoding, defaulting (as the
    /// V4L2 colorspace rules do for sRGB-family sources) to video range and
    /// BT.601, or BT.709 for the REC709 colorspace.
    static func colorimetry(_ f: ycam_format) -> CameraColorimetry {
        if f.pixelformat == CameraSourceFormat.mjpeg.rawValue || f.colorspace == V4L2.colorspaceJPEG {
            return .full601
        }
        let full = f.quantization == V4L2.quantizationFull
        let matrix = f.ycbcr_enc == V4L2.ycbcrEnc709 || (f.ycbcr_enc == 0 && f.colorspace == V4L2.colorspaceREC709) ? 709 : 601
        return CameraColorimetry(fullRange: full, matrix: matrix)
    }

    public func next(timeoutMilliseconds: Int) throws -> CameraRawFrame? {
        guard fd >= 0 else { throw CameraError(.gone, "\(path): closed") }
        while true {
            let w = ycam_wait(fd, Int32(timeoutMilliseconds))
            if w == 0 { return nil }
            if w < 0 { throw CameraError.errno("poll", -w, path: path) }
            var d = ycam_dequeued()
            let r = ycam_dequeue(fd, &d)
            if r == -EAGAIN { continue }
            if r == -EIO {
                corruptFrames += 1
                continue
            }
            guard r == 0 else { throw CameraError.errno("VIDIOC_DQBUF", -r, path: path) }
            let index = Int(d.index)
            guard index < buffers.count else { continue }
            let used = Int(min(d.bytesused, buffers[index].length))
            let bytes = UnsafeRawBufferPointer(start: buffers[index].address, count: used)
            let jpegOK = format.source != .mjpeg || (used > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8)
            if d.flags & V4L2.bufFlagError != 0 || used == 0 || !jpegOK {
                corruptFrames += 1
                _ = ycam_queue(fd, d.index)
                continue
            }
            let monotonic = d.flags & V4L2.bufTimestampMask == V4L2.bufTimestampMonotonic && d.timestamp_ns > 0
            return CameraRawFrame(format: format.source, width: format.width, height: format.height, bytesPerLine: bytesPerLine,
                                  bytes: bytes, colorimetry: format.colorimetry, deviceSequence: d.sequence,
                                  timestamp: monotonic ? d.timestamp_ns : ycam_monotonic_ns(), synthetic: false, token: index)
        }
    }

    public func recycle(_ frame: CameraRawFrame) {
        guard fd >= 0 else { return }
        _ = ycam_queue(fd, UInt32(frame.token))
    }

    public func close() {
        guard fd >= 0 else { return }
        if streaming { _ = ycam_stream(fd, 0) }
        streaming = false
        for b in buffers { ycam_unmap_buffer(b.address, b.length) }
        buffers = []
        _ = ycam_request_buffers(fd, 0)
        ycam_close(fd)
        fd = -1
    }

    deinit { close() }
}
