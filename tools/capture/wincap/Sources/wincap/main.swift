// wincap: capture one window, or one app's windows, with ScreenCaptureKit.
//
//   wincap check
//   wincap list   [--bundle ID | --pid N]
//   wincap still  TARGET -o out.png
//   wincap record TARGET -o out.mov [--duration S] [--fps N] [--codec C]
//
// TARGET is --bundle ID or --pid N, optionally narrowed by --window-id W or
// --title TEXT (substring). Without either, the frontmost on-screen normal
// window of the app is used. Nothing outside the chosen window (or, with --mode app, outside
// that app's windows) is captured: the window does not need to be frontmost.
//
// Other options:
//   --mode window|app   window (default): that window alone, with its sheets
//                       and child windows. app: every window of that app (so
//                       menus and popovers too) inside the chosen window's
//                       frame plus --margin points; other apps are not drawn.
//   --margin PT         extra points around the window in app mode (default 0)
//   --shadow            keep the window shadow (window mode)
//   --cursor            draw the pointer
//   --colorspace srgb|p3    (default srgb)
//   --fps N             frame rate cap for record (default 60)
//   --codec prores4444|prores422hq|hevc|h264    (default prores4444)
//   --duration S        stop after S seconds; otherwise SIGINT or SIGTERM stops
//
// record prints JSON lines on stdout ("ready", "first_frame", "done") and
// writes OUT.json next to the video: the window, the scale, the display
// refresh rate and each written frame's time (relative and wall clock).
// Exit status 3 means Screen Recording permission is missing.

import AppKit
import AVFoundation
import CoreMedia
import Darwin
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

// MARK: - Options

struct Options {
    var command = ""
    var bundle: String?
    var pid: pid_t?
    var windowID: CGWindowID?
    var title: String?
    var output: String?
    var duration: Double?
    var fps = 60
    var codec = "prores4444"
    var mode = "window"
    var margin: Double = 0
    var shadow = false
    var cursor = false
    var colorspace = "srgb"
}

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(("wincap: " + message + "\n").data(using: .utf8)!)
    exit(code)
}

func number<T: LosslessStringConvertible>(_ text: String, _ name: String) -> T {
    guard let v = T(text) else { fail("\(name) needs a number, not \(text)") }
    return v
}

func parse(_ args: [String]) -> Options {
    var o = Options()
    guard let first = args.first else { fail("usage: wincap check|list|still|record [options]") }
    o.command = first
    var i = 1
    func value() -> String {
        i += 1
        guard i < args.count else { fail("\(args[i - 1]) needs a value") }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--bundle": o.bundle = value()
        case "--pid": o.pid = number(value(), "--pid")
        case "--window-id": o.windowID = number(value(), "--window-id")
        case "--title": o.title = value()
        case "-o", "--output": o.output = value()
        case "--duration": o.duration = number(value(), "--duration")
        case "--fps": o.fps = number(value(), "--fps")
        case "--codec": o.codec = value()
        case "--mode": o.mode = value()
        case "--margin": o.margin = number(value(), "--margin")
        case "--shadow": o.shadow = true
        case "--cursor": o.cursor = true
        case "--colorspace": o.colorspace = value()
        default: fail("unknown option \(args[i])")
        }
        i += 1
    }
    guard ["window", "app"].contains(o.mode) else { fail("--mode is window or app") }
    guard ["srgb", "p3"].contains(o.colorspace) else { fail("--colorspace is srgb or p3") }
    return o
}

// MARK: - Output

let outputLock = NSLock()
func emit(_ object: [String: Any]) {
    outputLock.lock(); defer { outputLock.unlock() }
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + "\n".data(using: .utf8)!)
}

func writeJSON(_ object: Any, to path: String) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: path))
}

func rectArray(_ r: CGRect) -> [Double] {
    [Double(r.origin.x), Double(r.origin.y), Double(r.width), Double(r.height)]
}

// MARK: - Permission

/// The executable path and parent of a process, from the kernel.
func processInfo(_ pid: pid_t) -> (path: String, parent: pid_t)? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: 4096)
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    let path = length > 0 ? String(cString: buffer) : "?"
    return (path, info.kp_eproc.e_ppid)
}

/// The chain of processes from this one up to launchd. macOS attributes the
/// permission to the "responsible" app in this chain, usually the terminal or
/// agent host that started us, not to wincap itself.
func ancestry() -> [String] {
    var chain: [String] = []
    var pid = getpid()
    while pid > 1, let p = processInfo(pid), chain.count < 12 {
        chain.append("\(pid) \(p.path)")
        pid = p.parent
    }
    return chain
}

func permissionReport() -> [String: Any] {
    [
        "screen_recording": CGPreflightScreenCaptureAccess(),
        "process_chain": ancestry(),
        "how_to_grant": "System Settings > Privacy & Security > Screen & System Audio Recording: "
            + "turn on the app that runs this command (the terminal or agent host near the top "
            + "of process_chain that is an .app), then restart that app.",
    ]
}

// MARK: - Window lookup

struct Target {
    let window: SCWindow
    let filter: SCContentFilter
    let captureRect: CGRect   // points: content rect (window mode) or source rect (app mode)
    let scale: CGFloat
    let display: SCDisplay?
}

func shareableContent() async -> SCShareableContent {
    do {
        return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    } catch {
        var report = permissionReport()
        report["error"] = "\(error)"
        emit(report)
        fail("ScreenCaptureKit refused: \(error.localizedDescription)", code: 3)
    }
}

func matches(_ w: SCWindow, _ o: Options) -> Bool {
    guard let app = w.owningApplication else { return false }
    if let b = o.bundle, app.bundleIdentifier != b { return false }
    if let p = o.pid, app.processID != p { return false }
    if let id = o.windowID { return w.windowID == id }
    if let t = o.title, !(w.title ?? "").localizedCaseInsensitiveContains(t) { return false }
    return w.windowLayer == 0
}

/// Front-to-back position of each on-screen window (0 = frontmost).
let zOrder: [CGWindowID: Int] = {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    var order: [CGWindowID: Int] = [:]
    for (i, w) in list.enumerated() {
        if let n = w[kCGWindowNumber as String] as? Int { order[CGWindowID(n)] = i }
    }
    return order
}()

func windowJSON(_ w: SCWindow) -> [String: Any] {
    [
        "z": zOrder[w.windowID] ?? -1,
        "id": Int(w.windowID),
        "title": w.title ?? "",
        "app": w.owningApplication?.applicationName ?? "",
        "bundle_id": w.owningApplication?.bundleIdentifier ?? "",
        "pid": Int(w.owningApplication?.processID ?? 0),
        "frame_pt": rectArray(w.frame),
        "layer": w.windowLayer,
        "on_screen": w.isOnScreen,
        "active": w.isActive,
    ]
}

func resolve(_ o: Options) async -> Target {
    guard o.bundle != nil || o.pid != nil || o.windowID != nil else { fail("give --bundle, --pid or --window-id") }
    let content = await shareableContent()
    // On-screen first, then the frontmost, then the largest.
    let candidates = content.windows.filter { matches($0, o) }.sorted {
        if $0.isOnScreen != $1.isOnScreen { return $0.isOnScreen }
        let za = zOrder[$0.windowID] ?? Int.max, zb = zOrder[$1.windowID] ?? Int.max
        if za != zb { return za < zb }
        return $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height
    }
    guard let w = candidates.first else { fail("no matching window (try `wincap list`)", code: 4) }
    let display = content.displays.max { a, b in
        let ia = a.frame.intersection(w.frame), ib = b.frame.intersection(w.frame)
        return ia.width * ia.height < ib.width * ib.height
    }
    if o.mode == "app" {
        guard let app = w.owningApplication, let display else { fail("app mode needs the window's app and display") }
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        var rect = w.frame.insetBy(dx: -o.margin, dy: -o.margin)
            .offsetBy(dx: -display.frame.origin.x, dy: -display.frame.origin.y)
        rect = rect.intersection(CGRect(origin: .zero, size: display.frame.size)).integral
        let scale = CGFloat(SCShareableContent.info(for: filter).pointPixelScale)
        return Target(window: w, filter: filter, captureRect: rect, scale: scale, display: display)
    }
    let filter = SCContentFilter(desktopIndependentWindow: w)
    let info = SCShareableContent.info(for: filter)
    return Target(window: w, filter: filter, captureRect: info.contentRect,
                  scale: CGFloat(info.pointPixelScale), display: display)
}

func configuration(_ t: Target, _ o: Options) -> SCStreamConfiguration {
    let c = SCStreamConfiguration()
    c.width = Int((t.captureRect.width * t.scale).rounded())
    c.height = Int((t.captureRect.height * t.scale).rounded())
    c.pixelFormat = kCVPixelFormatType_32BGRA
    c.colorSpaceName = o.colorspace == "p3" ? CGColorSpace.displayP3 : CGColorSpace.sRGB
    c.showsCursor = o.cursor
    c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, o.fps)))
    c.queueDepth = 8
    c.scalesToFit = false
    c.captureResolution = .best
    if o.mode == "app" {
        c.sourceRect = t.captureRect
        c.backgroundColor = .clear
    } else {
        c.ignoreShadowsSingleWindow = !o.shadow
    }
    c.includeChildWindows = true
    return c
}

func displayInfo(_ d: SCDisplay?) -> [String: Any] {
    guard let d else { return [:] }
    let mode = CGDisplayCopyDisplayMode(d.displayID)
    return [
        "id": Int(d.displayID),
        "frame_pt": rectArray(d.frame),
        "refresh_hz": mode?.refreshRate ?? 0,
        "mode_px": [mode?.pixelWidth ?? 0, mode?.pixelHeight ?? 0],
    ]
}

func describe(_ t: Target, _ o: Options, _ c: SCStreamConfiguration) -> [String: Any] {
    [
        "tool": "wincap",
        "format_version": 1,
        "mode": o.mode,
        "window": windowJSON(t.window),
        "capture_rect_pt": rectArray(t.captureRect),
        "pixel_scale": Double(t.scale),
        "size_px": [c.width, c.height],
        "colorspace": o.colorspace,
        "cursor": o.cursor,
        "shadow": o.shadow,
        "display": displayInfo(t.display),
    ]
}

// MARK: - Still

func still(_ o: Options) async {
    guard let out = o.output else { fail("still needs -o out.png") }
    let t = await resolve(o)
    let c = configuration(t, o)
    let image: CGImage
    do {
        image = try await SCScreenshotManager.captureImage(contentFilter: t.filter, configuration: c)
    } catch {
        var report = permissionReport(); report["error"] = "\(error)"; emit(report)
        fail("capture failed: \(error.localizedDescription)", code: 3)
    }
    let url = URL(fileURLWithPath: out)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("cannot write \(out)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("cannot write \(out)") }
    var d = describe(t, o, c)
    d["file"] = out
    d["wall"] = Date().timeIntervalSince1970
    d["size_px"] = [image.width, image.height]
    try? writeJSON(d, to: out + ".json")
    emit(["event": "still", "file": out, "size_px": [image.width, image.height], "pixel_scale": Double(t.scale)])
}

// MARK: - Record

func hostSeconds() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let queue = DispatchQueue(label: "wincap.frames")
    /// wall clock = host clock + offset
    let wallOffset = Date().timeIntervalSince1970 - hostSeconds()
    var firstPTS: CMTime?
    var frames: [[String: Double]] = []
    var dropped = 0
    var skipped = 0
    var failure: String?

    init(path: String, codec: String, width: Int, height: Int, fps: Int, colorspace: String) throws {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: url)
        let type: AVFileType = path.hasSuffix(".mp4") ? .mp4 : .mov
        writer = try AVAssetWriter(outputURL: url, fileType: type)
        var settings: [String: Any] = [AVVideoWidthKey: width, AVVideoHeightKey: height]
        switch codec {
        case "prores4444": settings[AVVideoCodecKey] = AVVideoCodecType.proRes4444
        case "prores422hq": settings[AVVideoCodecKey] = AVVideoCodecType.proRes422HQ
        case "hevc":
            settings[AVVideoCodecKey] = AVVideoCodecType.hevc
            settings[AVVideoCompressionPropertiesKey] = [AVVideoQualityKey: 1.0,
                                                         AVVideoExpectedSourceFrameRateKey: fps]
        case "h264":
            settings[AVVideoCodecKey] = AVVideoCodecType.h264
            settings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: width * height * fps / 2,
                                                         AVVideoExpectedSourceFrameRateKey: fps,
                                                         AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]
        default: fail("unknown --codec \(codec)")
        }
        settings[AVVideoColorPropertiesKey] = [
            AVVideoColorPrimariesKey: colorspace == "p3" ? AVVideoColorPrimaries_P3_D65 : AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { fail("the writer refuses these settings") }
        writer.add(input)
        guard writer.startWriting() else { fail("cannot start writing: \(writer.error?.localizedDescription ?? "?")") }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete else {
            skipped += 1   // idle (unchanged), blank or suspended frames carry no new image
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        if firstPTS == nil {
            firstPTS = pts
            writer.startSession(atSourceTime: pts)
            emit(["event": "first_frame", "wall": pts.seconds + wallOffset])
        }
        guard input.isReadyForMoreMediaData else { dropped += 1; return }
        if input.append(buffer) {
            frames.append(["pts": (pts - firstPTS!).seconds, "wall": pts.seconds + wallOffset])
        } else {
            dropped += 1
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        failure = "\(error)"
        emit(["event": "error", "error": "\(error)"])
    }

    func finish() async {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            queue.async { k.resume() }   // drain frames already queued
        }
        if firstPTS == nil {
            writer.cancelWriting()
            return
        }
        // Make the last frame last until now, so a static end state has a duration.
        let end = CMTime(seconds: hostSeconds(), preferredTimescale: 1_000_000)
        input.markAsFinished()
        writer.endSession(atSourceTime: max(end, firstPTS! + CMTime(value: 1, timescale: 600)))
        await writer.finishWriting()
    }
}

func record(_ o: Options) async {
    guard let out = o.output else { fail("record needs -o out.mov") }
    let t = await resolve(o)
    let c = configuration(t, o)
    let recorder: Recorder
    do {
        recorder = try Recorder(path: out, codec: o.codec, width: c.width, height: c.height, fps: o.fps,
                                colorspace: o.colorspace)
    } catch { fail("cannot create \(out): \(error.localizedDescription)") }
    let stream = SCStream(filter: t.filter, configuration: c, delegate: recorder)
    do {
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue)
        try await stream.startCapture()
    } catch {
        var report = permissionReport(); report["error"] = "\(error)"; emit(report)
        fail("capture failed: \(error.localizedDescription)", code: 3)
    }
    let startWall = Date().timeIntervalSince1970
    emit(["event": "ready", "wall": startWall, "size_px": [c.width, c.height], "pixel_scale": Double(t.scale),
          "window": windowJSON(t.window)])

    // Stop on duration, SIGINT, SIGTERM or end of stdin, whichever comes first.
    let stopSignal = AsyncStream<String> { continuation in
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { continuation.yield("signal \(sig)") }
            source.resume()
            _signalSources.append(source)
        }
        if let d = o.duration {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { continuation.yield("duration") }
        }
    }
    var reason = "?"
    for await r in stopSignal { reason = r; break }

    do { try await stream.stopCapture() } catch { emit(["event": "warning", "stop": "\(error)"]) }
    await recorder.finish()
    let stopWall = Date().timeIntervalSince1970
    var d = describe(t, o, c)
    d["file"] = out
    d["codec"] = o.codec
    d["fps_requested"] = o.fps
    d["start_wall"] = startWall
    d["stop_wall"] = stopWall
    d["stop_reason"] = reason
    d["first_frame_wall"] = recorder.frames.first?["wall"] ?? NSNull()
    d["frames"] = recorder.frames
    d["frames_written"] = recorder.frames.count
    d["frames_dropped"] = recorder.dropped
    d["frames_without_new_content"] = recorder.skipped
    d["error"] = recorder.failure ?? NSNull()
    try? writeJSON(d, to: out + ".json")
    emit(["event": "done", "file": out, "frames": recorder.frames.count, "dropped": recorder.dropped,
          "reason": reason])
    if recorder.frames.isEmpty { exit(5) }
}

nonisolated(unsafe) var _signalSources: [DispatchSourceSignal] = []

// MARK: - List and check

func list(_ o: Options) async {
    let content = await shareableContent()
    let windows = content.windows.filter { w in
        guard let app = w.owningApplication else { return false }
        if let b = o.bundle, app.bundleIdentifier != b { return false }
        if let p = o.pid, app.processID != p { return false }
        return true
    }
    let data = try! JSONSerialization.data(withJSONObject: windows.map(windowJSON), options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data + "\n".data(using: .utf8)!)
}

func check() async {
    var report = permissionReport()
    // The preflight can be stale; asking for the window list is the real test.
    do {
        _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        report["screencapturekit"] = "ok"
    } catch {
        report["screencapturekit"] = "\(error)"
        report["screen_recording"] = false
    }
    emit(report)
    if (report["screen_recording"] as? Bool) != true { exit(3) }
}

// MARK: - Main

// A connection to the window server; also keeps any Dock icon away.
NSApplication.shared.setActivationPolicy(.prohibited)
let options = parse(Array(CommandLine.arguments.dropFirst()))
Task {
    switch options.command {
    case "check": await check()
    case "list": await list(options)
    case "still": await still(options)
    case "record": await record(options)
    default: fail("unknown command \(options.command)")
    }
    exit(0)
}
dispatchMain()
