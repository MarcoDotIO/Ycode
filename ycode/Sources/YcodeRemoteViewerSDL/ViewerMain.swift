// `ycode-sim-viewer` on Linux (display-stream.md §13): parses the viewer's
// options, connects (a display socket address, or Ycode's own link to a
// simulator host with `--link`, sim-link.md), and runs the SDL window; with
// `--headless` no window: the stream is received and decoded only (a probe
// for measurements on hosts without a display).

import Foundation
import YcodeDisplayStream
import YcodeRemoteViewer
import YcodeSimLink

extension RemoteDeviceWindow: ViewerScriptHost {}

public enum LinuxViewer {
    public static let usage = """
        usage: ycode-sim-viewer [--connect <address> | --link <device> [--host <name>] [--media udp|tcp]] [--scale fit|point|pixel] [--fps N] [--encoding jpeg|zlib]
                                [--quality Q] [--downscale N] [--no-bezels] [--status] [--timing]
                                [--script <file>] [--measure <file.tsv>] [--headless] [--verbose]

          --connect    the display server: <host>:<port>, <port> (127.0.0.1), or unix:<path>
                       (default 127.0.0.1:47100, or $YCODE_SIM_VIEWER_CONNECT)
          --link       a device of a paired simulator host over Ycode's own link (sim-link.md; `ycode sim remote pair`);
                       --host names the host when several are paired; --media tcp keeps frames off UDP
          --scale      fit (the window), point (one device point per window unit) or pixel
          --fps        frames per second at most (default 120: the guest paces itself; display-stream.md 12.4)
          --encoding   jpeg (default), zlib (lossless, more bandwidth), h264 (NVDEC here, NVENC on the host; §14)
                       or auto (h264 where this machine decodes it)
          --audio      the device's sound: pulse (default: PulseAudio/PipeWire), null (no speaker; with --audio-wav) or off
          --audio-latency  ms added to the device's play time (default 10; display-stream.md 15)
          --audio-wav  also write what goes to the speaker to a WAV file
          --bitrate    the video bit rate in kbit/s (h264; default the host's, 20000)
          --quality    JPEG quality 1-100 (default 80)
          --downscale  send 1/N of the device pixels per axis (default 1)
          --timing     ask the server for each frame's stage times (display-stream.md 12)
          --measure    write every shown frame's stage times (client clock, ns) to a TSV file at exit
          --script     run a test script (ViewerScript.swift) and exit with its status
          --headless   no window: receive and decode only (with --script: waits, stats, shots)

        Mouse: click and drag = one finger; Alt-drag = pinch/rotate about the centre; Alt-Shift-drag =
        two-finger pan; the wheel = a drag (a watch: the crown). Click the frame's buttons to press them.
        Keys go to the device; Ctrl shortcuts stay with the window: Ctrl+Shift+H home, Ctrl+L lock,
        Ctrl+Up/Down volume, Ctrl+Left/Right rotate, Ctrl+Shift+S screenshot, Ctrl+1/2/3 scale,
        Ctrl+B bezels, Ctrl+F status line, Ctrl+R refresh, Ctrl+Q quit.
        """

    public struct Options {
        public var address: DisplayAddress = DisplayAddress(ProcessInfo.processInfo.environment["YCODE_SIM_VIEWER_CONNECT"] ?? "")
            ?? .tcp(host: "127.0.0.1", port: 47100)
        public var settings = DisplayClientHello(client: "ycode-sim-viewer-linux", maxFPS: 120, encoding: "jpeg", quality: 80, downscale: 1)
        public var scale = ViewerScaleMode.fit
        public var bezels = true
        public var status = false
        public var script: String?
        public var measure: String?
        public var headless = false
        public var verbose = false
        public var linkDevice: String?
        public var linkHost: String?
        public var media = true
        public var audio = "pulse"
        public var audioLatency = 10.0
        public var audioWAV: String?
        public init() {}
    }

    public enum ParseResult { case run(Options), exit(Int32, String) }

    public static func parse(_ arguments: [String]) -> ParseResult {
        var o = Options()
        var it = arguments.makeIterator()
        func value(_ name: String) -> String? { it.next() }
        while let a = it.next() {
            switch a {
            case "--connect":
                guard let v = value(a), let addr = DisplayAddress(v) else { return .exit(64, "--connect needs an address") }
                o.address = addr
            case "--scale":
                guard let v = value(a), let m = ViewerScaleMode(argument: v) else { return .exit(64, "--scale fit|point|pixel") }
                o.scale = m
            case "--fps":
                guard let v = value(a).flatMap(Int.init), (1...120).contains(v) else { return .exit(64, "--fps 1-120") }
                o.settings.maxFPS = v
            case "--quality":
                guard let v = value(a).flatMap(Int.init), (1...100).contains(v) else { return .exit(64, "--quality 1-100") }
                o.settings.quality = v
            case "--downscale":
                guard let v = value(a).flatMap(Int.init), (1...4).contains(v) else { return .exit(64, "--downscale 1-4") }
                o.settings.downscale = v
            case "--encoding":
                guard let v = value(a), v == "auto" || DisplayEncoding(name: v) != nil else { return .exit(64, "--encoding jpeg|zlib|h264|hevc|hevc444|auto") }
                o.settings.encoding = v
            case "--bitrate":
                guard let v = value(a).flatMap(Int.init), (500...200_000).contains(v) else { return .exit(64, "--bitrate 500-200000 (kbit/s)") }
                o.settings.videoBitrate = v
            case "--timing": o.settings.timing = true
            case "--no-bezels": o.bezels = false
            case "--status": o.status = true
            case "--script":
                guard let v = value(a) else { return .exit(64, "--script <file>") }
                o.script = v
            case "--measure":
                guard let v = value(a) else { return .exit(64, "--measure <file>") }
                o.measure = v
                o.settings.timing = true
            case "--link":
                guard let v = value(a) else { return .exit(64, "--link <device>") }
                o.linkDevice = v
            case "--host":
                guard let v = value(a) else { return .exit(64, "--host <name>") }
                o.linkHost = v
            case "--media":
                guard let v = value(a), v == "udp" || v == "tcp" else { return .exit(64, "--media udp|tcp") }
                o.media = v == "udp"
            case "--audio":
                guard let v = value(a), ["pulse", "null", "off"].contains(v) else { return .exit(64, "--audio pulse|null|off") }
                o.audio = v
            case "--audio-latency":
                guard let v = value(a).flatMap(Double.init), (0...500).contains(v) else { return .exit(64, "--audio-latency 0-500 (ms)") }
                o.audioLatency = v
            case "--audio-wav":
                guard let v = value(a) else { return .exit(64, "--audio-wav <file.wav>") }
                o.audioWAV = v
            case "--headless": o.headless = true
            case "--verbose": o.verbose = true
            case "-h", "--help": return .exit(0, usage)
            default: return .exit(64, "unknown argument \(a)\n\(usage)")
            }
        }
        return .run(o)
    }

    /// Runs the viewer; returns the exit status.
    public static func main(_ arguments: [String], connect: (@Sendable () throws -> DisplayTransport)? = nil) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        // A parent may start us with signals blocked (a Swift program's
        // Process inherits its thread's mask): Stop's SIGTERM must reach SDL,
        // which turns it into a quit event.
        var none = sigset_t()
        sigemptyset(&none)
        pthread_sigmask(SIG_SETMASK, &none, nil)
        signal(SIGTERM, SIG_DFL)
        signal(SIGINT, SIG_DFL)
        let o: Options
        switch parse(arguments) {
        case .exit(let code, let text):
            FileHandle(fileDescriptor: code == 0 ? 1 : 2).write(Data((text + "\n").utf8))
            return code
        case .run(let opts): o = opts
        }
        var settings = o.settings
        // auto: the best this host decodes that the server offers (display-stream.md §14).
        if settings.encoding == "auto" {
            settings.encoding = StreamCanvas.decodableEncodings.first ?? "zlib"
            settings.encodings = StreamCanvas.decodableEncodings
            if DisplayEncoding(name: settings.encoding)?.isVideo != true {
                let missing = [DisplayEncoding.hevc, .h264].compactMap { e in StreamCanvas.decodeProblem(e).map { (name: e.name, why: $0) } }
                if let w = DisplayCodecChoice.warning(viewer: "ycode-sim-viewer", wishes: ["hevc", "h264", settings.encoding], missing: missing, offered: nil, chosen: settings.encoding) {
                    FileHandle.standardError.write(Data((w + "\n").utf8))
                }
            }
        }
        if DisplayEncoding(name: settings.encoding).map(StreamCanvas.canDecode) != true {
            FileHandle.standardError.write(Data("ycode-sim-viewer: no \(settings.encoding) decoder here; using \(StreamCanvas.decodableEncodings.first ?? "zlib")\n".utf8))
        }
        if DisplayEncoding(name: settings.encoding).map(StreamCanvas.canDecode) != true { settings.encoding = StreamCanvas.decodableEncodings.first ?? "zlib" }
        let address = o.address
        var connector = connect ?? { try DisplayConnection.connect(to: address) }
        if connect == nil, let device = o.linkDevice {
            do {
                let link = try LinkClient()
                let host = try link.host(named: o.linkHost)
                let media = o.media
                connector = { try link.display(host, device: device, media: media) }
                FileHandle.standardError.write(Data("ycode-sim-viewer: \(device) on \(host.name) (\(host.host):\(host.controlPort)) over the link\(media ? ", frames by udp \(host.mediaPort)" : "")\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("ycode-sim-viewer: \(error)\n".utf8))
                return 69
            }
        }
        var player: AudioPlayer?
        if o.audio != "off" {
            let p = AudioPlayer(output: o.audio == "null" ? .null : .pulse, targetMilliseconds: o.audioLatency, wavPath: o.audioWAV)
            p.log = { FileHandle.standardError.write(Data(("ycode-sim-viewer: " + $0 + "\n").utf8)) }
            if p.start() {
                player = p
                settings.audio = AudioPlayer.codecs
            }
        }
        let client = DisplayStreamClient(settings: settings, connect: connector)
        let session = RemoteDeviceSession(client: client, audio: player)
        session.scaleMode = o.scale
        session.bezels = o.bezels
        let text = o.script.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        if o.script != nil, text == nil { FileHandle.standardError.write(Data("cannot read \(o.script!)\n".utf8)); return 66 }
        let status = StatusBox()
        if o.headless {
            let code = runHeadless(session, script: text, measure: o.measure, verbose: o.verbose, status: status)
            player?.stop()
            if let player { FileHandle.standardOutput.write(Data(("ycode-sim-viewer: " + player.summary + "\n").utf8)) }
            return code
        }

        guard let sdl = SDL() else {
            FileHandle.standardError.write(Data("ycode-sim-viewer: libSDL3 not found (set YCODE_SDL3_LIBRARY; tried \(SDL.candidates().joined(separator: ", ")))\n".utf8))
            return 69
        }
        let captures = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YCODE_DEVICE_CAPTURE_DIR"]
                           ?? (NSHomeDirectory() + "/Pictures"), isDirectory: true)
        guard let win = RemoteDeviceWindow(sdl: sdl, session: session, captureDirectory: captures) else { return 70 }
        win.showStatus = o.status
        let script = text.map { ViewerScript(text: $0, session: session, host: win) }
        if o.verbose || script != nil {
            session.log = { [weak script] s in if let script { script.log(s) } else { FileHandle.standardOutput.write(Data((s + "\n").utf8)) } }
        }
        guard win.open() else { return 69 }
        if o.scale != .fit { win.setScale(o.scale) }
        session.start()
        script?.start { code in status.value = code; win.stop() }
        win.run()
        session.stop()
        player?.stop()
        if let player { FileHandle.standardOutput.write(Data(("ycode-sim-viewer: " + player.summary + "\n").utf8)) }
        if let m = o.measure { writeMeasurements(session, to: m) }
        let up = win.uploads
        if o.verbose || script != nil {
            let (bytes, frames, dec) = client.statistics
            print(String(format: "ycode-sim-viewer: %d frames, %.1f MB, decode %.2f ms/frame, upload %.2f ms/frame, present %.2f ms total",
                         frames, Double(bytes) / 1e6, frames > 0 ? Double(dec) / 1e6 / Double(frames) : 0,
                         Double(up.ns) / 1e6 / Double(max(up.count, 1)), Double(win.presentNanoseconds) / 1e6))
        }
        return status.value
    }

    final class StatusBox: @unchecked Sendable { var value: Int32 = 0 }

    final class HeadlessHost: ViewerScriptHost, @unchecked Sendable {
        let stopped = DispatchSemaphore(value: 0)
        func captureWindow(to path: String, done: @escaping @Sendable (Bool) -> Void) { done(false) }
        func setScale(_ m: ViewerScaleMode) {}
        func stop() { stopped.signal() }
    }

    static func runHeadless(_ session: RemoteDeviceSession, script: String?, measure: String?, verbose: Bool, status: StatusBox) -> Int32 {
        let host = HeadlessHost()
        let s = script.map { ViewerScript(text: $0, session: session, host: host) }
        if verbose || s != nil { session.log = { [weak s] t in if let s { s.log(t) } else { FileHandle.standardOutput.write(Data((t + "\n").utf8)) } } }
        // The "front end": drain on a timer, present at once (no window).
        let wake = DispatchSemaphore(value: 0)
        session.wake = { wake.signal() }
        session.start()
        s?.start { code in status.value = code; host.stop() }
        var lastTick = viewerNanoseconds()
        while host.stopped.wait(timeout: .now()) != .success {
            _ = wake.wait(timeout: .now() + 0.02)
            if session.drain(), let f = session.lastFrame { session.presented(sequence: f.frame.sequence) }
            let now = viewerNanoseconds()
            session.idle(now: Double(now) / 1e9)
            if now - lastTick >= 1_000_000_000 { lastTick = now; session.tick(now: now) }
            if script == nil, session.client.hasEnded { break }
        }
        session.stop()
        if let measure { writeMeasurements(session, to: measure) }
        return status.value
    }

    static func writeMeasurements(_ session: RemoteDeviceSession, to path: String) {
        var out = "sequence\tguestFrame\tbytes\tinput\trecordSeen\tcaptureStart\tencodeEnd\tsendEnd\treceived\tdecoded\tpresented\n"
        for s in session.shown {
            out += [String(s.sequence), String(s.guestFrame), String(s.bytes), String(s.inputSequence), String(s.recordSeen), String(s.captureStart),
                    String(s.encodeEnd), String(s.sendEnd), String(s.received), String(s.decoded), String(s.presented)].joined(separator: "\t") + "\n"
        }
        out += "# clock offset (server - client) ns: \(session.client.clock.offset ?? 0), uncertainty ns: \(session.client.clock.uncertainty ?? 0)\n"
        for l in session.presentLatencies { out += "# latency presented \(l.label) \(String(format: "%.2f", l.ms))\n" }
        for l in session.latencies { out += "# latency received \(l.label) \(String(format: "%.2f", l.ms))\n" }
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
