import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let shotsEnabled = ProcessInfo.processInfo.environment["YCODE_R4_EDITOR_SHOTS"] != nil

/// Screenshots of council round 4's editor rows (83–88) into
/// `.build-ide/b4-shots/` (opt-in: `YCODE_R4_EDITOR_SHOTS=1`): the bands
/// file and a Swift file with declarations, in dark and light, and a split
/// whose second pane has no focus. Ycode's own windows only, ordered behind
/// every other window.
@MainActor
@Suite(.serialized, .enabled(if: shotsEnabled)) struct EditorR4ShotTests {
    let out = ycodeDir.appendingPathComponent(".build-ide/b4-shots")

    /// Comment lines, then "// " and 110 full blocks per band line.
    static func bands() -> String {
        var s = "import Foundation\n\n"
        for n in 0..<6 { s += "// Section \(n): a comment that wraps inside the 1100-point split, so that text passes under the toolbar as the editor scrolls.\n" }
        s += "\n"
        for _ in 0..<24 { s += "// " + String(repeating: "\u{2588}", count: 110) + "\n" }
        return s
    }

    static let swift = """
    import Foundation

    /// A greeting.
    struct Greeting {
        static let defaultName = "World"
        let name: String
        var count = 7

        func describe() -> String {
            // A comment.
            "Hello, \\(name)! \\(count + 100)"
        }
    }

    enum Kind: Int { case plain, fancy }

    func farewell(_ g: Greeting) -> String { "Bye, " + g.name }

    """

    func shoot(_ win: NSWindow, _ name: String) {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        win.contentView?.layoutSubtreeIfNeeded()
        win.displayIfNeeded()
        UISpacingProbeTests.shot(win, out.appendingPathComponent("r4-editor-\(name).png"))
    }

    @Test(arguments: ["dark", "light"]) func editorShots(_ mode: String) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let fc = FidelityCouncilTests()
        let dir = try fc.project("r4-editor-shots-\(mode)")
        try Self.bands().write(to: dir.appendingPathComponent("GlassScroll/Bands.swift"), atomically: true, encoding: .utf8)
        try Self.swift.write(to: dir.appendingPathComponent("GlassScroll/Greeting.swift"), atomically: true, encoding: .utf8)
        let wc = try fc.window(dir)
        let win = try #require(wc.window)
        win.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        // On the Retina display when there is one (the council's 2x).
        let screen = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor }
        let origin = screen.map { NSPoint(x: $0.frame.minX + 20, y: $0.frame.maxY - 900) } ?? NSPoint(x: 40, y: 40)
        win.setFrame(NSRect(origin: origin, size: NSSize(width: 1400, height: 880)), display: true)
        win.orderBack(nil)
        func pump(_ s: Double = 0.5) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

        wc.open(path: dir.appendingPathComponent("GlassScroll/Bands.swift").path, line: nil)
        pump()
        shoot(win, "bands-\(mode)")
        wc.open(path: dir.appendingPathComponent("GlassScroll/Greeting.swift").path, line: nil)
        wc.editor.textView.setSelectedRange(NSRange(location: 60, length: 0))
        pump()
        shoot(win, "swift-\(mode)")
        // A split: the second pane has focus, the first draws the faint band.
        wc.split(sideBySide: true)
        pump()
        shoot(win, "split-\(mode)")
        win.close()
    }
}
