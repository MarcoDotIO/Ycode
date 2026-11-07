import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let recordDir = ProcessInfo.processInfo.environment["YCODE_FLICK_RECORD_DIR"]
private let wincapPath = ProcessInfo.processInfo.environment["YCODE_WINCAP"]
private let onScreenRun = ProcessInfo.processInfo.environment["YCODE_TESTS_ON_SCREEN"] == "1"

/// Row 40 measured on screen: a 1400 × 880 workspace window showing a long
/// file, a momentum flick toward the top delivered as scroll events, and
/// the window recorded with `tools/capture/wincap` for
/// `tools/capture/motion.py`. Opt-in: set `YCODE_FLICK_RECORD_DIR` (the
/// output folder) and `YCODE_WINCAP` (the wincap binary).
///
/// The only suite that truly needs a display: the recording is the window
/// as the window server composites it at the display's refresh, which a
/// window off every display does not get. So it also needs
/// `YCODE_TESTS_ON_SCREEN=1` (README "Nothing on screen"), set only by the
/// owner for a recording they run by hand; the window then appears at
/// (60, 60) for about ten seconds.
@MainActor
@Suite(.serialized, .enabled(if: recordDir != nil && wincapPath != nil && onScreenRun)) struct FlickRecordingTests {
    @Test(arguments: [false, true]) func recordFlick(bounce: Bool) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let dir = ycodeDir.appendingPathComponent(".build-ide/flick-project")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"GlassScroll\")\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        // Lines of different lengths, so no stretch of the file repeats
        // (the measurement matches rows between frames).
        var long = "import Foundation\n\n"
        for i in 0..<160 {
            let words = (0..<(1 + (i * 7) % 11)).map { "w\((i * 31 + $0 * 17) % 97)" }.joined(separator: " ")
            long += i % 5 == 0 ? "// \(words)\n" : "let value\(i) = \"\(words)\"\n"
        }
        let file = dir.appendingPathComponent("Long.swift")
        try long.write(to: file, atomically: true, encoding: .utf8)
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)), loadDestinations: false,
                                           startLanguageService: false)
        wc.applyDefaultLayout()
        let window = try #require(wc.window)
        window.setFrame(NSRect(x: 60, y: 60, width: 1400, height: 880), display: true)
        window.orderFrontRegardless()
        wc.open(path: file.path, line: nil)
        let scroll = try #require(wc.editor.scrollView as? EditorScrollView)
        scroll.topBounce.isEnabled = bounce
        let clip = scroll.contentView
        let top = EditorTopBounce.top(of: scroll)
        func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        pump(1)
        clip.scroll(to: NSPoint(x: 0, y: top + 600))
        scroll.reflectScrolledClipView(clip)
        pump(0.5)
        let out = URL(fileURLWithPath: recordDir!).appendingPathComponent(bounce ? "after-flick.mov" : "before-flick.mov")
        let rec = Process()
        rec.executableURL = URL(fileURLWithPath: wincapPath!)
        rec.arguments = ["record", "--pid", "\(getpid())", "--window-id", "\(window.windowNumber)", "-o", out.path, "--duration", "3", "--fps", "120"]
        rec.standardOutput = FileHandle.nullDevice
        try rec.run()
        pump(1)
        // editor-area.md §D.4's input: 8 gesture events of 40 points over
        // 60 ms, then 173 momentum events (1544 points over 1.43 s) decaying
        // with a 0.33 s time constant.
        let location = NSPoint(x: 700, y: 400)
        func send(_ d: Double, phase: Int64, momentum: Int64) {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(d.rounded()), wheel2: 0, wheel3: 0)!
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: d)
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: d)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            cg.timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1e9)
            if let ev = NSEvent(cgEvent: cg) { scroll.scrollWheel(with: ev) }
            _ = location
        }
        for i in 0..<8 { send(40, phase: i == 0 ? 1 : 2, momentum: 0); pump(0.0075) }
        send(0, phase: 4, momentum: 0)
        let tau = 0.33, n = 173, total = 1.43
        let dt = total / Double(n)
        let v0 = 1544 / (tau * (1 - exp(-total / tau)))
        for i in 0..<n {
            let t0 = Double(i) * dt
            send(v0 * tau * (exp(-t0 / tau) - exp(-(t0 + dt) / tau)), phase: 0, momentum: i == 0 ? 1 : 2)
            pump(dt)
        }
        send(0, phase: 0, momentum: 3)
        pump(1.5)
        rec.waitUntilExit()
        if bounce { print("flick: peak \(scroll.topBounce.lastPeak)") }
        window.close()
    }
}
