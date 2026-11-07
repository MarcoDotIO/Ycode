import AppKit
import QuartzCore
import YcodeIDECore

/// A measurement of the inspector's slide in the running app
/// (`specs/ide/editor-area.md` F.5, checklist row 106):
/// `YCODE_MOTION_PROBE=<out.txt>` with `YCODE_MOTION_PROBE_FILE=<a source
/// file>` and `YCODE_MOTION_PROBE_PROJECT=<.xcodeproj or package folder>`
/// opens the project in a workspace window at 1400 × 880 (shown without
/// activating the app), opens the file, hides and shows the inspector
/// twice, and writes for each slide when its frames came (the display
/// link's frame times), then quits. Only Ycode's own window is involved;
/// the user's preferences and the project's user data are not touched.
@MainActor
public enum MotionProbe {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    public static var isRequested: Bool { environment["YCODE_MOTION_PROBE"]?.isEmpty == false }
    private static var wc: WorkspaceWindowController?
    private static var lines: [String] = []

    /// Before anything reads the preferences: a fresh domain in a
    /// temporary folder (as the layout probe does).
    public static func prepareIfRequested() {
        guard isRequested else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-motion-probe-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = UserDefaults(suiteName: dir.appendingPathComponent("defaults").path) {
            Preferences.shared = Preferences(defaults: d, themesDirectory: dir.appendingPathComponent("Themes"))
        }
    }

    /// Starts the probe when asked; true when it runs.
    public static func startIfRequested() -> Bool {
        guard let out = environment["YCODE_MOTION_PROBE"], !out.isEmpty, let project = environment["YCODE_MOTION_PROBE_PROJECT"] else { return false }
        do {
            let state = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-motion-probe-\(UUID().uuidString).json")
            let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: URL(fileURLWithPath: project))),
                                               loadDestinations: false, startLanguageService: false, openFirstFile: false, userStateURL: state)
            self.wc = wc
            guard let win = wc.window, let screen = NSScreen.main?.visibleFrame else { return false }
            win.setFrameAutosaveName("")
            win.isRestorable = false
            if environment["YCODE_MOTION_PROBE_APPEARANCE"] == "dark" { win.appearance = NSAppearance(named: .darkAqua) }
            win.setFrame(NSRect(x: screen.minX + 20, y: screen.maxY - 900, width: 1400, height: 880), display: false)
            wc.applyDefaultLayout()
            if let file = environment["YCODE_MOTION_PROBE_FILE"] { wc.open(path: file, line: nil) }
            win.orderFrontRegardless()
        } catch {
            write(out, ["could not open the project: \(error)"])
            NSApp.terminate(nil)
            return true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            for round in 0..<2 {
                for hide in [true, false] { await slide(name: "\(hide ? "hide" : "show") \(round + 1)") }
            }
            wc?.window?.orderOut(nil)
            write(out, lines)
            NSApp.terminate(nil)
        }
        return true
    }

    /// One slide: the frame times (ms from the press) and the progress.
    private static func slide(name: String) async {
        guard let wc else { return }
        let press = CACurrentMediaTime()
        wc.toggleInspector(nil)
        let state = wc.inspectorSlide
        var frames: [(Double, CGFloat)] = []
        if let step = state.onFrame {
            state.onFrame = { p in
                step(p)
                frames.append(((CACurrentMediaTime() - press) * 1000, p))
            }
        }
        while wc.isInspectorSliding { try? await Task.sleep(nanoseconds: 5_000_000) }
        try? await Task.sleep(nanoseconds: 600_000_000)
        let moving = frames.filter { $0.1 > 0 }
        let gaps = zip(moving.dropFirst(), moving).map { $0.0 - $1.0 }
        let first = moving.first?.0 ?? 0, last = moving.last?.0 ?? 0
        lines.append(String(format: "%@: first motion %.0f ms, last %.0f ms, %d frames moving, mean gap %.1f ms, max gap %.1f ms", name, first, last,
                            moving.count, gaps.isEmpty ? 0 : gaps.reduce(0, +) / Double(gaps.count), gaps.max() ?? 0))
        lines.append("  " + moving.map { String(format: "%.0f:%.2f", $0.0, Double($0.1)) }.joined(separator: " "))
    }

    private static func write(_ out: String, _ lines: [String]) {
        try? (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
    }
}
