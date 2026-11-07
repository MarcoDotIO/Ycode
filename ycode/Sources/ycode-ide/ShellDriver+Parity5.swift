import Foundation
import SwiftUI
import YcodeBuild
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_PARITY5=<prefix>: the Linux half of the cross-platform parity
// audit (`specs/ide/cross-platform-parity.md`; CrossPlatformParityShotTests
// is the macOS half), on the repositories of
// scripts/linux-ui-parity/make-parity5.sh. YCODE_IDE_PARITY5_PART chooses
// the states:
//
//   main (default)  the rest copy: empty, rest (Sample.swift), debug, image
//                   (Stripes.png), changes, repositories
//   narrow          rest only (run with YCODE_IDE_WINDOW_SIZE=1100x880)
//   merge           the merge copy: alert, sheet
//   welcome         no path: welcome, settings-general, settings-editing,
//                   settings-components, runtime-host (the wizard's host step)
//
// Each state writes <prefix>-<state>.png and <prefix>-<state>.txt: the
// window's size and scale, then every Text ("text", with its frame) and
// every identified view ("view") in points from the top left of the area
// under the in-window menu bar (the Settings window has none).
extension ShellDriver {
    #if os(Linux)
    static func parity5Walk(_ app: ShellAppModel, prefix: String) async {
        let part = env["YCODE_IDE_PARITY5_PART"] ?? "main"
        func dump(_ index: Int, _ state: String) {
            // The main window has the in-window menu bar; Settings and the
            // runtime wizard (a hidden title bar, menus on demand) have none.
            let top = index == 0 ? ShellMetrics.menuBarHeight : 0
            let size = OpenViewsAutomation.windowSize(index)
            var lines = [String(format: "window %.1f %.1f scale %.2f", size?.points.width ?? 0, (size?.points.height ?? 0) - top,
                                size.map { Double($0.pixels.width) / max(1, $0.points.width) } ?? 1)]
            func box(_ f: CGRect) -> String { String(format: "%.1f %.1f %.1f %.1f", f.minX, f.minY - top, f.width, f.height) }
            for t in OpenViewsAutomation.texts(index) where !t.text.isEmpty {
                let s = t.text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "'")
                lines.append("text \"\(s)\" \(box(t.frame))\(t.inPopup ? " popup" : "")")
            }
            for (id, f) in OpenViewsAutomation.identifiedFrames(index).sorted(by: { $0.key < $1.key }) {
                lines.append("view \(box(f)) id=\(id.replacingOccurrences(of: " ", with: "_"))")
            }
            try? lines.joined(separator: "\n").write(toFile: "\(prefix)-\(state).txt", atomically: true, encoding: .utf8)
        }
        func shot(_ state: String, window index: Int = 0, settle: Double = 0.8) async {
            await pause(settle)
            dump(index, state)
            say("parity5 \(state): " + OpenViewsAutomation.screenshot(index, to: "\(prefix)-\(state).png"))
        }

        guard let w = app.workspace else {
            await shot("welcome")
            OpenViewsAutomation.press(.character(","), modifiers: [.control])
            for _ in 0..<20 where OpenViewsAutomation.windowCount < 2 { await pause(0.2) }
            if OpenViewsAutomation.windowCount >= 2 {
                for pane in [ShellSettingsPane.general, .editing, .components] {
                    ShellSettingsModel.shared.select(pane)
                    await shot("settings-\(pane.rawValue)", window: 1)
                }
            } else {
                say("parity5: the Settings window did not open")
            }
            // The wizard is a window of its own (the last one).
            let windows = OpenViewsAutomation.windowCount
            app.showRuntimeSetup(step: .host)
            for _ in 0..<20 where OpenViewsAutomation.windowCount <= windows { await pause(0.2) }
            await shot("runtime-host", window: OpenViewsAutomation.windowCount - 1, settle: 1.2)
            app.closeRuntimeSetup()
            return
        }
        let scm = w.sourceControl
        func idle() async {
            for _ in 0..<100 where scm.busy != nil { await pause(0.1) }
            await scm.idle()
        }
        await idle()
        let files = w.root.allFiles.compactMap(\.path)
        func path(_ name: String) -> String? { files.first { $0.hasSuffix("/" + name) } }
        func openSample() {
            guard let p = path("Sample.swift") else { say("parity5: no Sample.swift"); return }
            if let ids = w.root.idPath(to: p) { for id in ids.dropLast() { w.setExpanded(id, true) } }
            w.open(p)
        }
        switch part {
        case "merge":
            await click("selector 1")
            await click("scm mode 1")
            await idle()
            scm.choose(.merge("feature"))
            await shot("alert")
            await click("merge alert merge")
            await idle()
            for _ in 0..<100 where !(scm.conflictEditor.map { $0.state.document != nil && !$0.isLoading } ?? false) { await pause(0.1) }
            if let e = scm.conflictEditor { await e.idle() }
            await shot("sheet", settle: 1.2)
        case "narrow":
            openSample()
            if let e = frame("editor") { await OpenViewsAutomation.click(at: CGPoint(x: e.midX, y: e.minY + 40)) }
            await shot("narrow")
            w.perform(.splitEditor)
            await shot("narrow-split")
        default:
            if w.document != nil { w.perform(.closeDocument) }
            await shot("empty")
            openSample()
            if let e = frame("editor") { await OpenViewsAutomation.click(at: CGPoint(x: e.midX, y: e.minY + 40)) }
            await shot("rest")
            w.isDebugAreaShown = true
            await shot("debug")
            w.isDebugAreaShown = false
            // Editor panes (EditorPanes.swift): the new pane on the right has focus.
            w.perform(.splitEditor)
            await shot("split")
            // The issue stepper in both panes with a project warning (row 139).
            w.session.packageIssues = [Diagnostic(severity: .warning, message: "Update to recommended settings", location: nil)]
            await shot("stepper")
            w.session.packageIssues = []
            if let added = w.panes.panes.last, w.panes.isSplit { w.closePane(added.id) }
            if let png = path("Stripes.png") { w.open(png) }
            await shot("image", settle: 1.2)
            openSample()
            await click("selector 1")
            await click("scm mode 0")
            await idle()
            await shot("changes")
            await click("scm mode 1")
            await idle()
            await shot("repositories")
        }
    }
    #endif
}
