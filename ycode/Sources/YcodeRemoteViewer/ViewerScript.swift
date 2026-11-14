// `ycode-sim-viewer --script <file>` for the portable viewers (display-
// stream.md §13.3): the macOS viewer's script language, run against a
// RemoteDeviceSession. Pointer steps go through the session's window-unit
// input (the path real mouse events take); one command a line:
//
//   wait-live [timeout s]              until live with a frame shown
//   wait-frame [timeout s]             until the next frame arrives
//   wait-quiet [ms] [timeout s]        until no frame for ms (default 1500)
//   wait-home [timeout s]              until the image is lit (past the boot logo)
//   wait-change [percent] [timeout s]  until the image differs in percent (default 20) of its samples
//   sleep <ms>
//   tap <x> <y>                        device points of the shown screen
//   drag <x1> <y1> <x2> <y2> [ms] [steps]
//   pinch <x> <y> <scale> [ms]
//   scroll <x> <y> <dy-lines> [steps]
//   type <text>                        US-layout text as key events
//   key <usage>                        press and release (hex 0x.. or decimal)
//   button home|lock|volumeUp|volumeDown|side
//   rotate left|right
//   scale fit|point|pixel
//   device-type <type id>              draw that device type's frame before any server's hello
//                                      (iphone-duo, iphone-18-pro, …; pictures of the window)
//   shot <path.png>                    the stream image
//   server-shot <path.png>             the server's full-resolution PNG
//   window-shot <path.png>             the window as drawn (frame, controls)
//   chrome more|close|hover <control>|click <control>|appearance light|dark
//                                      the window's chrome: open or close More Actions, hover a
//                                      capsule control until its tooltip shows, click one (a
//                                      DeviceCommand name: home, screenshot, recordScreen, …);
//                                      with the toolbar also `toolbar <item>`, `inspector show|hide`
//                                      and `window <w>x<h>` (the window's size)
//   stats-begin / stats-end [label]    frames, bytes, guest frames, and the stage medians over the span
//   latency-summary [label]            the input latencies so far
//   audio-summary                      the sound's packets, losses and timing so far
//   av-probe <x> <y> <n>               tap n times (an app that flashes white and beeps at once,
//                                      Samples/StreamSamples AVSync) and log, per tap, when the white
//                                      picture was presented and when the beep plays here: the A/V offset
//   log <text>
//   quit
//
// Lines starting with # are comments. Every step is logged.

import Foundation
import YcodeDeviceModel
import YcodeDisplayStream

/// What a script needs from the window beyond the session.
public protocol ViewerScriptHost: AnyObject, Sendable {
    /// A PNG of the window's next drawing; `done(true)` once written.
    func captureWindow(to path: String, done: @escaping @Sendable (Bool) -> Void)
    func setScale(_ m: ViewerScaleMode)
    func stop()
    /// A `chrome` step (the window's controls); false: not understood.
    func chrome(_ words: [String]) -> Bool
}

extension ViewerScriptHost {
    public func chrome(_ words: [String]) -> Bool { false }
}

public final class ViewerScript: @unchecked Sendable {
    public let lines: [String]
    public let session: RemoteDeviceSession
    public weak var host: ViewerScriptHost?
    public let started = viewerNanoseconds()
    private let lock = NSLock()
    private var frames = 0, statFrames = 0, statBytes = 0, statFirstGuest: UInt64?, statLastGuest: UInt64 = 0, statStart = viewerNanoseconds()
    private var lastFrameAt: UInt64 = 0
    private var statShownIndex = 0
    public var output: (String) -> Void = { s in FileHandle.standardOutput.write(Data((s + "\n").utf8)) }

    public init(text: String, session: RemoteDeviceSession, host: ViewerScriptHost?) {
        lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        self.session = session
        self.host = host
    }

    public func log(_ text: String) {
        output(String(format: "[%7.2f] ", Double(viewerNanoseconds() - started) / 1e9) + text)
    }

    /// Runs on its own thread; `done` gets the exit status.
    public func start(done: @escaping @Sendable (Int32) -> Void) {
        let previous = session.onFrame
        session.onFrame = { [weak self] f in
            previous?(f)
            guard let self else { return }
            self.lock.withLock {
                self.frames += 1
                self.lastFrameAt = viewerNanoseconds()
                self.statFrames += 1
                self.statBytes += f.frame.bytes
                if self.statFirstGuest == nil { self.statFirstGuest = f.frame.guestFrame }
                self.statLastGuest = f.frame.guestFrame
            }
        }
        Thread.detachNewThread { [self] in
            var status: Int32 = 0
            for raw in lines {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                log("> \(line)")
                do {
                    if try !step(line) { break }
                } catch {
                    log("error: \(error)")
                    status = 1
                    break
                }
            }
            done(status)
        }
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    /// Runs `body` on the front end's thread and waits for it.
    private func onWindow<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T {
        let sem = DispatchSemaphore(value: 0)
        let box = Box<T>()
        session.perform { box.value = body(); sem.signal() }
        sem.wait()
        return box.value!
    }

    private final class Box<T>: @unchecked Sendable { var value: T? }

    private func waitUntil(_ timeout: Double, _ what: String, _ check: () -> Bool) throws {
        let deadline = viewerNanoseconds() + UInt64(timeout * 1e9)
        while !check() {
            if viewerNanoseconds() > deadline { throw Failure(description: "timed out (\(timeout) s) waiting for \(what)") }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func samples() -> [UInt8]? { session.client.currentCanvas?.greySamples() }

    /// A device point of the shown screen → window units.
    private func windowPoint(_ x: Double, _ y: Double) -> (Double, Double) {
        onWindow { [session] in
            let s = session.layout.screen, p = session.shownPointSize
            return (s.x + x / p.width * s.width, s.y + y / p.height * s.height)
        }
    }

    private func step(_ line: String) throws -> Bool {
        let w = line.split(separator: " ").map(String.init)
        let cmd = w[0]
        func num(_ i: Int, _ d: Double? = nil) throws -> Double {
            if i < w.count, let v = Double(w[i]) { return v }
            if let d { return d }
            throw Failure(description: "\(cmd): argument \(i) missing")
        }
        let rest = w.count > 1 ? String(line.dropFirst(cmd.count + 1)) : ""
        switch cmd {
        case "wait-live":
            try waitUntil(try num(1, 300), "live") { onWindow { [session] in session.phase == "live" && session.hasImage } }
            log("live")
        case "wait-frame":
            let n = lock.withLock { frames }
            try waitUntil(try num(1, 30), "a frame") { lock.withLock { frames } > n }
        case "wait-quiet":
            let ms = try num(1, 1500)
            let start = viewerNanoseconds()
            try waitUntil(try num(2, 60), "quiet") {
                let now = viewerNanoseconds(), last = lock.withLock { lastFrameAt }
                return now - start > UInt64(ms * 1e6) && now - max(last, start) > UInt64(ms * 1e6)
            }
        case "wait-home":
            let start = viewerNanoseconds()
            try waitUntil(try num(1, 300), "the home screen") {
                guard let a = samples(), ImageChecks.isLit(a) else { return false }
                Thread.sleep(forTimeInterval: 0.5)
                guard let b = samples() else { return false }
                return ImageChecks.isLit(b)
            }
            log(String(format: "home after %.1f s", Double(viewerNanoseconds() - start) / 1e9))
        case "wait-change":
            let pct = try num(1, 20)
            let base = samples() ?? []
            let start = viewerNanoseconds()
            try waitUntil(try num(2, 30), "a change of \(pct) %") {
                guard let s = samples() else { return false }
                return ImageChecks.changedPercent(base, s) > pct
            }
            log(String(format: "changed after %.0f ms", Double(viewerNanoseconds() - start) / 1e6))
        case "sleep":
            Thread.sleep(forTimeInterval: try num(1) / 1000)
        case "tap":
            let (x, y) = windowPoint(try num(1), try num(2))
            onWindow { [session] in session.pointerDown(x: x, y: y, multiTouch: false, shift: false) }
            Thread.sleep(forTimeInterval: 0.08)
            onWindow { [session] in session.pointerUp(x: x, y: y) }
        case "drag", "pinch":
            let (x1, y1) = windowPoint(try num(1), try num(2))
            let (x2, y2): (Double, Double)
            let ms: Double, steps: Int
            if cmd == "drag" {
                (x2, y2) = windowPoint(try num(3), try num(4))
                ms = try num(5, 300)
                steps = Int(try num(6, 20))
            } else {
                let scale = try num(3)
                let c = onWindow { [session] in (session.layout.screen.x + session.layout.screen.width / 2, session.layout.screen.y + session.layout.screen.height / 2) }
                (x2, y2) = (c.0 + (x1 - c.0) * scale, c.1 + (y1 - c.1) * scale)
                ms = try num(4, 400)
                steps = 20
            }
            let multi = cmd == "pinch"
            onWindow { [session] in session.pointerDown(x: x1, y: y1, multiTouch: multi, shift: false) }
            for i in 1...max(1, steps) {
                Thread.sleep(forTimeInterval: ms / 1000 / Double(steps))
                let t = Double(i) / Double(steps)
                let (x, y) = (x1 + (x2 - x1) * t, y1 + (y2 - y1) * t)
                onWindow { [session] in session.pointerMoved(x: x, y: y, multiTouch: multi) }
            }
            onWindow { [session] in session.pointerUp(x: x2, y: y2) }
        case "scroll":
            let (x, y) = windowPoint(try num(1), try num(2))
            let dy = try num(3), steps = Int(try num(4, 10))
            for _ in 0..<steps {
                onWindow { [session] in session.wheel(x: x, y: y, dx: 0, dy: dy / Double(steps), now: Double(viewerNanoseconds()) / 1e9) }
                Thread.sleep(forTimeInterval: 0.016)
            }
        case "type":
            for e in HIDKeys.events(typing: rest) {
                onWindow { [session] in session.key(usage: e.usage, down: e.down) }
                Thread.sleep(forTimeInterval: e.down ? 0.03 : 0.02)
            }
        case "key":
            let v = w.count > 1 ? w[1] : ""
            guard let u = v.hasPrefix("0x") ? UInt16(v.dropFirst(2), radix: 16) : UInt16(v) else { throw Failure(description: "key: bad usage \(v)") }
            onWindow { [session] in session.key(usage: u, down: true) }
            Thread.sleep(forTimeInterval: 0.05)
            onWindow { [session] in session.key(usage: u, down: false) }
        case "button":
            guard w.count > 1, let b = DisplayButton.allCases.first(where: { $0.name == w[1] }) else { throw Failure(description: "button: name?") }
            onWindow { [session] in session.press(b) }
        case "rotate":
            let left = w.count > 1 && w[1] == "left"
            onWindow { [session] in session.rotate(left: left) }
        case "device-type":
            guard w.count > 1, let spec = DeviceFrameSpec.named(typeID: w[1]) else { throw Failure(description: "device-type <type id>") }
            onWindow { [session] in session.preview(spec: spec) }
        case "scale":
            guard w.count > 1, let m = ViewerScaleMode(argument: w[1]) else { throw Failure(description: "scale fit|point|pixel") }
            onWindow { [host] in host?.setScale(m) }
        case "shot":
            guard w.count > 1, let png = session.shownPNG() else { throw Failure(description: "shot: no image") }
            try Data(png).write(to: URL(fileURLWithPath: w[1]))
            log("wrote \(w[1])")
        case "server-shot":
            guard w.count > 1 else { throw Failure(description: "server-shot <path>") }
            let sem = DispatchSemaphore(value: 0)
            let box = Box<[UInt8]>()
            session.perform { [session] in session.requestScreenshot { png in box.value = png; sem.signal() } }
            guard sem.wait(timeout: .now() + 15) == .success, let png = box.value, !png.isEmpty else { throw Failure(description: "no screenshot from the server") }
            try Data(png).write(to: URL(fileURLWithPath: w[1]))
            log("wrote \(w[1]) (\(png.count) bytes)")
        case "window-shot":
            guard w.count > 1, let host else { throw Failure(description: "window-shot <path> (needs a window)") }
            let sem = DispatchSemaphore(value: 0)
            let box = Box<Bool>()
            host.captureWindow(to: w[1]) { ok in box.value = ok; sem.signal() }
            guard sem.wait(timeout: .now() + 10) == .success, box.value == true else { throw Failure(description: "window-shot failed") }
            log("wrote \(w[1])")
        case "chrome":
            let words = Array(w.dropFirst())
            let done = onWindow { [host] in host?.chrome(words) ?? false }
            guard done else { throw Failure(description: "chrome \(rest): not done") }
            if words.first == "hover" { Thread.sleep(forTimeInterval: DeviceWindowChrome.tooltipDelay + 0.2) }
        case "stats-begin":
            lock.withLock { statFrames = 0; statBytes = 0; statFirstGuest = nil; statStart = viewerNanoseconds() }
            statShownIndex = onWindow { [session] in session.shown.count }
        case "stats-end":
            let (f, b, g0, g1, t0) = lock.withLock { (statFrames, statBytes, statFirstGuest, statLastGuest, statStart) }
            let secs = Double(viewerNanoseconds() - t0) / 1e9
            let from = statShownIndex
            let stages = onWindow { [session] in Array(session.shown.dropFirst(from)) }
            log(String(format: "stats %@: %.1f s, %d frames received (%.1f fps), guest frames %llu (%.1f fps), %.0f KB/s",
                       w.count > 1 ? w[1] : "", secs, f, Double(f) / secs, (g1 &- (g0 ?? g1)), Double(g1 &- (g0 ?? g1)) / secs,
                       Double(b) / 1000 / secs))
            log("stages " + StageSummary(stages).text)
            let (rtt, unc) = onWindow { [session] in (session.rttMilliseconds, session.client.clock.uncertainty) }
            log(String(format: "round trip %.2f ms (clock offset known to ±%.2f ms)", rtt ?? -1, Double(unc ?? -1_000_000) / 1e6))
        case "latency-summary":
            let (l, p) = onWindow { [session] in (session.latencies.map(\.ms), session.presentLatencies.map(\.ms)) }
            log("latency received: " + StageSummary.describe(l) + "; presented: " + StageSummary.describe(p))
        case "av-probe":
            guard let audio = session.audio else { throw Failure(description: "av-probe needs the sound (--audio)") }
            let (x, y) = windowPoint(try num(1), try num(2))
            let n = Int(try num(3, 5))
            onWindow { [session] in session.tracksBrightness = true }
            var offsets: [Double] = [], tapToPicture: [Double] = [], tapToSound: [Double] = []
            for i in 0..<n {
                let onsets0 = audio.onsets.count
                let tapAt = viewerNanoseconds()
                onWindow { [session] in session.pointerDown(x: x, y: y, multiTouch: false, shift: false) }
                Thread.sleep(forTimeInterval: 0.05)
                onWindow { [session] in session.pointerUp(x: x, y: y) }
                var tv: UInt64?, ta: UInt64?
                let deadline = tapAt + 3_000_000_000
                while viewerNanoseconds() < deadline && (tv == nil || ta == nil) {
                    if tv == nil { tv = onWindow { [session] in session.brightness.first { $0.at > tapAt && $0.mean > 128 }?.at } }
                    if ta == nil { let o = audio.onsets; if o.count > onsets0 { ta = o[onsets0] } }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                guard let tv, let ta else { log("av-probe \(i + 1): \(tv == nil ? "no white picture" : "") \(ta == nil ? "no sound" : "")"); Thread.sleep(forTimeInterval: 0.8); continue }
                let off = (Double(ta) - Double(tv)) / 1e6
                offsets.append(off)
                tapToPicture.append(Double(tv - tapAt) / 1e6)
                tapToSound.append((Double(ta) - Double(tapAt)) / 1e6)
                log(String(format: "av-probe %d: tap → picture %.1f ms, tap → sound %.1f ms, sound − picture %+.1f ms", i + 1,
                           tapToPicture.last!, tapToSound.last!, off))
                Thread.sleep(forTimeInterval: 0.8)
            }
            onWindow { [session] in session.tracksBrightness = false }
            log("av-probe: sound − picture " + StageSummary.describe(offsets) + "; tap → picture " + StageSummary.describe(tapToPicture)
                + "; tap → sound " + StageSummary.describe(tapToSound))
        case "audio-summary":
            log(session.audio?.summary ?? "audio: off")
        case "log":
            log(rest)
        case "quit":
            host?.stop()
            return false
        default:
            throw Failure(description: "unknown command \(cmd)")
        }
        return true
    }
}

/// Medians of the stages of a run of frames (display-stream.md §12).
public struct StageSummary: Sendable {
    public var count: Int
    public var stages: [(name: String, values: [Double])]

    public init(_ frames: [FrameStages]) {
        count = frames.count
        func ms(_ a: UInt64, _ b: UInt64) -> Double? { a > 0 && b > 0 && b >= a ? Double(b - a) / 1e6 : nil }
        stages = [
            ("seen→capture", frames.compactMap { ms($0.recordSeen, $0.captureStart) }),
            ("capture→encoded", frames.compactMap { ms($0.captureStart, $0.encodeEnd) }),
            ("encoded→sent", frames.compactMap { ms($0.encodeEnd, $0.sendEnd) }),
            ("sent→received", frames.compactMap { ms($0.sendEnd, $0.received) }),
            ("received→decoded", frames.compactMap { ms($0.received, $0.decoded) }),
            ("decoded→presented", frames.compactMap { ms($0.decoded, $0.presented) }),
            ("seen→presented", frames.compactMap { ms($0.recordSeen, $0.presented) }),
        ]
    }

    public static func percentile(_ v: [Double], _ p: Double) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
    }

    public static func describe(_ v: [Double]) -> String {
        guard let p50 = percentile(v, 0.5), let p90 = percentile(v, 0.9) else { return "none" }
        return String(format: "n %d p50 %.2f p90 %.2f max %.2f ms", v.count, p50, p90, v.max()!)
    }

    public var text: String {
        "(\(count) frames): " + stages.map { "\($0.name) " + (Self.percentile($0.values, 0.5).map { String(format: "%.2f", $0) } ?? "-")
            + "/" + (Self.percentile($0.values, 0.9).map { String(format: "%.2f", $0) } ?? "-") }.joined(separator: ", ") + " ms (p50/p90)"
    }
}
