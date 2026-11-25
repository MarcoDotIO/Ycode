import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_TOOLBAR5=<prefix>: B5-TOOLBAR's states (P-025, P-028, P-029,
// P-204) on the workspace given as the path, in light and dark:
//
//   w<width>        the toolbar at 1400, 1100, 900 and 760 points: what
//                   stays and what is in "»" (P-025)
//   overflow-760    the "»" menu open at 760 points: glyphs and sub-menus
//   building-<w>    "Building • 40/76" at 1400 and 1100: the ring, the
//                   subtitle truncated to the room (P-029), Run enabled
//                   (L-017), Stop enabled (P-204)
//   inactive        the window inactive while building: both lines dimmed
//                   (L-016)
//   run-menu        Run's menu (P-028), opened through the menu itself
//
// Each state writes <prefix>-<state>-<appearance>.png and .txt (texts and
// identified views); the walk prints what each state shows.
extension ShellDriver {
    #if os(Linux)
    static func toolbar5Walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("toolbar5: no workspace"); return }
        func shot(_ state: String, settle: Double = 0.6, popups: Bool = false) async {
            await pause(settle)
            let top = ShellMetrics.menuBarHeight
            var lines: [String] = []
            func box(_ f: CGRect) -> String { String(format: "%.1f %.1f %.1f %.1f", f.minX, f.minY - top, f.width, f.height) }
            for t in OpenViewsAutomation.texts(0) where !t.text.isEmpty { lines.append("text \"\(t.text)\" \(box(t.frame))") }
            for (id, f) in OpenViewsAutomation.identifiedFrames(0).sorted(by: { $0.key < $1.key }) {
                lines.append("view \(box(f)) id=\(id.replacingOccurrences(of: " ", with: "_"))")
            }
            try? lines.joined(separator: "\n").write(toFile: "\(prefix)-\(state).txt", atomically: true, encoding: .utf8)
            let path = "\(prefix)-\(state).png"
            say("toolbar5 \(state): " + (popups ? OpenViewsAutomation.screenshotWithPopups(0, to: path) : OpenViewsAutomation.screenshot(0, to: path)))
        }
        // The center row ViewThatFits chose (`CenterToolbar.stages`): what
        // gave way and which items are in "»".
        func shown() -> String {
            let f = OpenViewsAutomation.identifiedFrames(0)
            guard let n = (0..<CenterToolbar.stages.count).first(where: { (f["tb overflow \($0)"]?.width ?? 0) > 0 }) else {
                return "stage 0 or 1 (no »), scheme \(f["tb destination"].map { "\($0.width)" } ?? "-")"
            }
            let st = CenterToolbar.stages[n]
            return "stage \(n): scheme glyphs \(st.fit.schemeGlyphsOnly), modes in » \(st.fit.editorModesInOverflow), subtitle truncates \(st.truncates), "
                + "» holds \(st.out.map(\.rawValue))" + (f["tb run"].map { ", run at \($0.minX)" } ?? "")
        }
        // The chosen row's "»" (each row has its own target).
        func overflowFrame() -> CGRect? {
            let f = OpenViewsAutomation.identifiedFrames(0)
            return (0..<CenterToolbar.stages.count).compactMap { f["tb overflow \($0)"] }.first { $0.width > 0 }
        }
        func resize(_ width: Double) async {
            OpenViewsAutomation.resize(0, to: CGSize(width: width, height: 880))
            await pause(0.8)
        }
        let wide = OpenViewsAutomation.windowSize(0)?.points ?? CGSize(width: 1400, height: 880)
        for mode in [Preferences.Appearance.light, .dark] {
            Preferences.shared.appearance = mode
            let a = mode.rawValue.lowercased()
            OpenViewsAutomation.move(to: CGPoint(x: 5, y: 600))
            // P-025: what stays as the window narrows.
            for width in [1400.0, 1100, 900, 760] {
                await resize(width)
                say("toolbar5 \(a) \(Int(width)): \(shown())")
                await shot("w\(Int(width))-\(a)")
            }
            if let f = overflowFrame() {
                await OpenViewsAutomation.click(at: CGPoint(x: f.midX, y: f.midY))
                await pause(0.5)
                let rows = OpenViewsAutomation.texts(0).map(\.text).filter { !$0.isEmpty }
                say("toolbar5 \(a) overflow menu: popups \(OpenViewsAutomation.openPopupCount), texts \(rows.suffix(12))")
                await shot("overflow-760-\(a)", settle: 0.2, popups: true)
                OpenViewsAutomation.press(.escape)
                OpenViewsAutomation.move(to: CGPoint(x: 5, y: 600))   // no tooltip in the next shots
                await pause(0.3)
            }
            // P-029, P-204, L-017: while building.
            w.session.noteToolActivity(.building(WorkspaceSession.BuildActivityText.progress(done: 40, total: 76)))
            for width in [1400.0, 1100] {
                await resize(width)
                say("toolbar5 \(a) building \(Int(width)): Product ▸ Run \(w.isEnabled(.run)), Stop \(w.isEnabled(.stop)); \(shown())")
                await shot("building-\(Int(width))-\(a)")
            }
            let ax = OpenViewsAutomation.accessibilityDump(0).split(separator: "\n")
                .filter { ["Stop", "Run", "Build", "title area", "GlassScroll"].contains(where: $0.contains) }
            say("toolbar5 \(a) accessibility while building:\n" + ax.joined(separator: "\n"))
            OpenViewsAutomation.setActiveState(.inactive)
            await shot("inactive-\(a)")
            OpenViewsAutomation.setActiveState(nil)
            w.session.noteToolActivity(.idle)
            await resize(wide.width)
            // P-028: Run's menu rows (OpenViews opens a menu with a primary
            // action on its primary action only, so the rows are opened
            // through the overflow's Run entry at 760).
            await resize(760)
            if let f = overflowFrame() {
                await OpenViewsAutomation.click(at: CGPoint(x: f.midX, y: f.midY))
                await pause(0.5)
                say("toolbar5 \(a) run rows: \(RunButtonMenu.rows.map(\.title)) linux commands \(RunButtonMenu.rows.map { RunHoldMenuItems.command($0)?.rawValue ?? "none" })")
                OpenViewsAutomation.press(.escape)
                await pause(0.3)
            }
            await resize(wide.width)
        }
    }
    #endif
}
