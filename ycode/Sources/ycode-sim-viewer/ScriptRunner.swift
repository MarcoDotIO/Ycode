// `ycode-sim-viewer --script <file>`: drives the viewer with a recorded
// sequence, for tests without a person at the Mac. Clicks, drags, and keys
// are synthesized as AppKit events and given to the device view, so they
// take the same path as real mouse and keyboard input. One command a line:
//
//   wait-live [timeout s]            until the device is live and a frame is shown
//   wait-quiet [ms] [timeout s]      until no frame came for ms (default 1500), at least ms from now
//   wait-frame [timeout s]           until the next frame (a change on screen) arrives
//   wait-home [timeout s]            until the shown image is a lit screen (less than 90 % of its
//                                    samples darker than 24, in two looks 0.5 s apart: the home
//                                    screen after the boot logo, light or dark appearance)
//   wait-change [percent] [timeout s]  until the shown image differs from the one at the start
//                                    of the command in more than percent (default 20) of its samples
//   sleep <ms>
//   stats-begin / stats-end [label]  frames received, guest frames, bytes over the span
//   tap <x> <y>                      device points
//   drag <x1> <y1> <x2> <y2> [ms] [steps]
//   pinch <x> <y> <scale> [ms]       option-drag from (x, y) to its image scaled about the center
//   scroll <x> <y> <dx> <dy> [steps] scroll-wheel drag starting at (x, y), by (dx, dy) points
//   type <text>                      US-layout text through key events
//   key <usage>                      press and release a HID usage (hex 0x.. or decimal)
//   button home|lock|volumeUp|volumeDown|side
//   shot <path.png>                  the image the viewer shows
//   server-shot <path.png>           a full-resolution PNG from the server
//   log <text>
//   quit
//
// Lines starting with # are comments. Every step is logged to stdout.

#if os(macOS)
import AppKit
import YcodeDisplayStream

final class ScriptRunner: @unchecked Sendable {
    let lines: [String]
    unowned let controller: ViewerController
    let started = Date()
    private var lastFrameAt = Date.distantPast
    // stats-begin / stats-end: frames, bytes, and guest frames over a span.
    private var statFrames = 0, statBytes = 0, statFirstGuest: UInt64?, statLastGuest: UInt64 = 0, statStart = Date()
    private let frameLock = NSLock()

    init(path: String, controller: ViewerController) throws {
        lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        self.controller = controller
    }

    func log(_ text: String) {
        let t = String(format: "%7.2f", Date().timeIntervalSince(started))
        FileHandle.standardOutput.write(Data("[\(t)] \(text)\n".utf8))
    }

    @MainActor func start() {
        controller.onFrame = { [weak self] frame in
            guard let self else { return }
            self.frameLock.withLock {
                self.lastFrameAt = Date()
                self.statFrames += 1
                self.statBytes += frame.byteCount
                if self.statFirstGuest == nil { self.statFirstGuest = frame.guestFrame }
                self.statLastGuest = frame.guestFrame
            }
        }
        Thread.detachNewThread { [self] in
            var status: Int32 = 0
            for (n, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                log("> \(line)")
                do {
                    if try !run(line) { break }
                } catch {
                    log("script line \(n + 1): \(error)")
                    status = 1
                    break
                }
            }
            log("script done")
            DispatchQueue.main.async {
                if !self.controller.latencies.isEmpty {
                    let ms = self.controller.latencies.map(\.ms).sorted()
                    self.log(String(format: "latency summary: %d inputs, median %.0f ms, min %.0f, max %.0f", ms.count, ms[ms.count / 2],
                                    ms.first!, ms.last!))
                }
                exit(status)
            }
        }
    }

    struct ScriptError: Error, CustomStringConvertible { let description: String }

    private func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T { DispatchQueue.main.sync { MainActor.assumeIsolated { body() } } }

    private func number(_ words: [String], _ i: Int, default d: Double? = nil) throws -> Double {
        if i < words.count {
            let w = words[i]
            if w.hasPrefix("0x"), let v = UInt64(w.dropFirst(2), radix: 16) { return Double(v) }
            if let v = Double(w) { return v }
            throw ScriptError(description: "not a number: \(w)")
        }
        if let d { return d }
        throw ScriptError(description: "missing argument \(i)")
    }

    /// A device point → a window point of the device view.
    private func windowPoint(_ x: Double, _ y: Double) -> CGPoint {
        onMain {
            let v = controller.deviceView
            return v.convert(v.viewPoint(device: CGPoint(x: x, y: y)), to: nil)
        }
    }

    private func mouse(_ type: NSEvent.EventType, _ p: CGPoint, flags: NSEvent.ModifierFlags = []) {
        onMain {
            let v = controller.deviceView
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags,
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: controller.window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { return }
            switch type {
            case .leftMouseDown: v.mouseDown(with: e)
            case .leftMouseDragged: v.mouseDragged(with: e)
            case .leftMouseUp: v.mouseUp(with: e)
            default: break
            }
        }
    }

    private func key(_ code: UInt16, down: Bool, shift: Bool, chars: String) {
        onMain {
            let v = controller.deviceView
            if shift && down, let f = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .shift, timestamp: 0,
                                                       windowNumber: controller.window.windowNumber, context: nil, characters: "",
                                                       charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0x38) {
                v.flagsChanged(with: f)
            }
            if let e = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: shift ? .shift : [],
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.window.windowNumber,
                                        context: nil, characters: chars, charactersIgnoringModifiers: chars.lowercased(),
                                        isARepeat: false, keyCode: code) {
                if down { v.keyDown(with: e) } else { v.keyUp(with: e) }
            }
            if shift && !down, let f = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 0,
                                                        windowNumber: controller.window.windowNumber, context: nil, characters: "",
                                                        charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0x38) {
                v.flagsChanged(with: f)
            }
        }
    }

    private func pause(_ ms: Double) { Thread.sleep(forTimeInterval: ms / 1000) }

    private func save(_ png: [UInt8]?, _ path: String) throws {
        guard let png else { throw ScriptError(description: "no image to save") }
        try Data(png).write(to: URL(fileURLWithPath: path))
        log("saved \(path) (\(png.count) bytes)")
    }

    /// Runs one command; false ends the script.
    private func run(_ line: String) throws -> Bool {
        let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        switch words[0] {
        case "wait-live":
            let deadline = Date().addingTimeInterval(try number(words, 1, default: 900))
            while !onMain({ controller.isLiveWithImage }) {
                if Date() > deadline { throw ScriptError(description: "not live in time") }
                pause(200)
            }
            log("live")
        case "wait-quiet":
            let quiet = try number(words, 1, default: 1500) / 1000
            let deadline = Date().addingTimeInterval(try number(words, 2, default: 120))
            // Quiet since this command started too: an answer to the last input may still be on its way.
            let since = Date()
            while Date().timeIntervalSince(max(since, frameLock.withLock { lastFrameAt })) < quiet {
                if Date() > deadline { log("still changing at the timeout"); break }
                pause(100)
            }
        case "wait-frame":
            let since = Date()
            let deadline = since.addingTimeInterval(try number(words, 1, default: 120))
            while frameLock.withLock({ lastFrameAt }) <= since {
                if Date() > deadline { throw ScriptError(description: "no frame in time") }
                pause(50)
            }
        case "wait-home":
            let deadline = Date().addingTimeInterval(try number(words, 1, default: 900))
            var lit = 0
            while lit < 2 {
                if Date() > deadline { throw ScriptError(description: "no lit screen in time") }
                let samples = onMain { controller.deviceView.image.map(Self.samples) } ?? []
                let dark = samples.filter { $0 < 24 }.count
                lit = !samples.isEmpty && Double(dark) < 0.9 * Double(samples.count) ? lit + 1 : 0
                pause(500)
            }
            log("home screen (lit) shown")
        case "wait-change":
            let percent = try number(words, 1, default: 20)
            let deadline = Date().addingTimeInterval(try number(words, 2, default: 120))
            let start = Date()
            guard let before = onMain({ controller.deviceView.image.map(Self.samples) }) else { throw ScriptError(description: "no image yet") }
            while true {
                if Date() > deadline { throw ScriptError(description: "the screen did not change in time") }
                if let now = onMain({ controller.deviceView.image.map(Self.samples) }), now.count == before.count {
                    let changed = zip(before, now).filter { abs($0 - $1) > 24 }.count
                    if Double(changed) * 100 >= percent * Double(now.count) {
                        log(String(format: "screen changed (%.0f%% of samples) after %.2f s", Double(changed) * 100 / Double(now.count),
                                   Date().timeIntervalSince(start)))
                        break
                    }
                }
                pause(100)
            }
        case "stats-begin":
            frameLock.withLock { statFrames = 0; statBytes = 0; statFirstGuest = nil; statStart = Date() }
        case "stats-end":
            let (n, b, g0, g1, t0) = frameLock.withLock { (statFrames, statBytes, statFirstGuest ?? 0, statLastGuest, statStart) }
            let secs = Date().timeIntervalSince(t0)
            log(String(format: "stats %@: %.1f s, %d frames received (%.1f fps), guest presented %llu frames (%.1f fps), %.0f KB (%.0f KB/s)",
                       words.dropFirst().joined(separator: " "), secs, n, Double(n) / secs, g1 - min(g0, g1),
                       Double(g1 - min(g0, g1)) / secs, Double(b) / 1000, Double(b) / 1000 / secs))
        case "sleep":
            pause(try number(words, 1))
        case "tap":
            let p = windowPoint(try number(words, 1), try number(words, 2))
            mouse(.leftMouseDown, p)
            pause(60)
            mouse(.leftMouseUp, p)
        case "drag":
            let a = windowPoint(try number(words, 1), try number(words, 2))
            let b = windowPoint(try number(words, 3), try number(words, 4))
            let ms = try number(words, 5, default: 300), steps = max(1, Int(try number(words, 6, default: 12)))
            mouse(.leftMouseDown, a)
            for i in 1...steps {
                pause(ms / Double(steps))
                let t = CGFloat(i) / CGFloat(steps)
                mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
            mouse(.leftMouseUp, b)
        case "pinch":
            let x = try number(words, 1), y = try number(words, 2), scale = try number(words, 3)
            let ms = try number(words, 4, default: 400)
            let size = onMain { controller.deviceView.pointSize }
            let cx = Double(size.width) / 2, cy = Double(size.height) / 2
            let a = windowPoint(x, y), b = windowPoint(cx + (x - cx) * scale, cy + (y - cy) * scale)
            mouse(.leftMouseDown, a, flags: .option)
            for i in 1...12 {
                pause(ms / 12)
                let t = CGFloat(i) / 12
                mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), flags: .option)
            }
            mouse(.leftMouseUp, b, flags: .option)
        case "scroll":
            let x = try number(words, 1), y = try number(words, 2), dx = try number(words, 3), dy = try number(words, 4)
            let steps = max(1, Int(try number(words, 5, default: 10)))
            onMain {
                let v = controller.deviceView
                v.beginScroll(at: v.viewPoint(device: CGPoint(x: x, y: y)))
            }
            for _ in 0..<steps {
                pause(16)
                onMain {
                    let v = controller.deviceView
                    let k = v.bounds.width / v.pointSize.width
                    v.scrollBy(dx: CGFloat(dx) * k / CGFloat(steps), dy: CGFloat(dy) * k / CGFloat(steps))
                }
            }
            onMain { controller.deviceView.endScroll() }
        case "type":
            let text = line.dropFirst(4).drop(while: { $0 == " " })
            for ch in text {
                guard let (code, shift) = KeyMap.keyCode(for: ch) else { log("no key for \(ch)"); continue }
                key(code, down: true, shift: shift, chars: String(ch))
                pause(30)
                key(code, down: false, shift: shift, chars: String(ch))
                pause(30)
            }
        case "key":
            let usage = UInt16(try number(words, 1))
            onMain {
                controller.sendKey(usage: usage, down: true, label: "key \(usage)")
            }
            pause(60)
            onMain { controller.sendKey(usage: usage, down: false, label: nil) }
        case "button":
            guard words.count > 1, let b = DisplayButton.allCases.first(where: { $0.name == words[1] }) else {
                throw ScriptError(description: "button home|lock|volumeUp|volumeDown|side")
            }
            onMain { controller.press(b) }
            pause(200)  // the release goes out 100 ms after the press
        case "shot":
            guard words.count > 1 else { throw ScriptError(description: "shot <path>") }
            try save(onMain { controller.shownPNG() }, words[1])
        case "server-shot":
            guard words.count > 1 else { throw ScriptError(description: "server-shot <path>") }
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var result: [UInt8]?
            DispatchQueue.main.async { self.controller.requestScreenshot { result = $0; done.signal() } }
            done.wait()
            try save(result, words[1])
        case "log":
            log(String(line.dropFirst(4)))
        case "quit":
            return false
        default:
            throw ScriptError(description: "unknown command \(words[0])")
        }
        return true
    }
}

extension ScriptRunner {
    /// The image as 48 × 64 grey samples (0…255), for wait-home and wait-change.
    static func samples(_ image: CGImage) -> [Double] {
        let w = 48, h = 64
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return px.map(Double.init)
    }
}

extension ViewerController {
    var isLiveWithImage: Bool { deviceView.image != nil && statusIsLive }
}
#endif
