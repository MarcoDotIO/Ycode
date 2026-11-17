import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_B4POLISH=<prefix>: B4-POLISH (1.0.0-beta.4, council round 11) on
// the Linux IDE, as the macOS IDE's `B4PolishTests`. Open a workspace with
// a Swift file that declares a `#Preview` and a property list.
//
//   find-closed / find-open / find-escape
//                    P-003: Ctrl+F shows the bar above the text and its
//                    gutter (line 1's number and text move together);
//                    Escape in the field closes it (`b4polish find …`)
//   assistant        P-026: Ctrl+0 shows the Coding Assistant at the
//                    navigator's width, Ctrl+1 keeps it (`b4polish left …`)
//   band             P-035: the open file's row after Ctrl+2…5 and Ctrl+1
//   canvas-*         the canvas beside the previewable file, gone for the
//                    property list editor, back with the file
//   paused           the title area while paused: the mark, no ring
//   settings-900     P-139: the Settings window widened to 900 × 760
//
// Each state writes <prefix>-<state>.png and prints a "b4polish …" line.
extension ShellDriver {
    #if os(Linux)
    static func b4PolishWalk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("b4polish: no workspace"); return }
        func shot(_ state: String, window: Int = 0, settle: Double = 0.7) async {
            await pause(settle)
            say("b4polish \(state): " + OpenViewsAutomation.screenshot(window, to: "\(prefix)-\(state).png"))
        }
        func frame(_ name: String, window: Int = 0) -> CGRect? {
            let all = OpenViewsAutomation.identifiedFrames(window)
            return all[name] ?? all[name.replacingOccurrences(of: " ", with: "_")]
        }
        let files = w.root.allFiles.compactMap(\.path).filter { $0.hasSuffix(".swift") && !$0.hasSuffix("Package.swift") }
        let previewable = files.first { (try? String(contentsOfFile: $0, encoding: .utf8))?.contains("#Preview") == true }
        guard let path = previewable ?? files.first else { say("b4polish: no Swift file"); return }
        let ids = w.root.idPath(to: path) ?? []
        for id in ids.dropLast() { w.setExpanded(id, true) }
        w.selection = ids.last
        w.open(path)
        await pause(1.0)

        // P-003: the find bar pushes the text and its gutter down together.
        await shot("find-closed")
        OpenViewsAutomation.press(.character("f"), modifiers: [.control])
        await shot("find-open")
        let field = frame("find field")
        say("b4polish find open=\(w.findBar.isShown) field=\(field.map { "y \($0.minY)…\($0.maxY)" } ?? "-") jumpBarEnd=\(frame("jump bar").map { "\($0.maxY)" } ?? "-")")
        OpenViewsAutomation.press(.escape)
        await shot("find-escape")
        say("b4polish find after Escape: shown=\(w.findBar.isShown)")

        // P-026: the Coding Assistant at the navigator's width.
        let navWidth = { frame("tb back").map { "\($0.minX)" } ?? "-" }
        let left0 = navWidth()
        w.perform(.showCodingAssistant)
        await shot("assistant")
        let left1 = navWidth()
        let pane = frame("assistant new conversation").map { "\($0.minX)" } ?? "-"
        w.perform(.showProjectNavigator)
        await pause(0.5)
        say("b4polish left: navigator \(left0) → Ctrl+0 \(left1) (pane's first button at x \(pane)) → Ctrl+1 \(navWidth())")

        // P-035: the band after the other navigators.
        for c in [ShellCommand.showSourceControlNavigator, .showSymbolNavigator, .showFindNavigator, .showIssueNavigator] {
            w.perform(c)
            await pause(0.25)
        }
        w.perform(.showProjectNavigator)
        await shot("band")
        say("b4polish band: navigator=\(w.navigator) row=\(w.projectSelection == ids.last ? "the open file's" : String(describing: w.projectSelection))")

        // The canvas beside editors that can't preview.
        say("b4polish canvas source: shown=\(w.previewCanvas.isShown)")
        await shot("canvas-source", settle: 1.2)
        if let plist = w.root.allFiles.compactMap(\.path).first(where: { $0.hasSuffix(".plist") }) {
            w.open(plist)
            await shot("canvas-plist")
            say("b4polish canvas plist: structured=\(w.structuredEditor != nil) shown=\(w.previewCanvas.isShown) mode=\(w.previewCanvas.isModeOn)")
            w.open(path)
            await shot("canvas-source-again", settle: 1.2)
            say("b4polish canvas back: shown=\(w.previewCanvas.isShown)")
        }

        // The title area while paused.
        w.session.noteToolActivity(.running("Running Demo"))
        await shot("running")
        say("b4polish running: icon=\(w.titleAreaIcon) ")
        w.session.noteToolActivity(.paused("Paused Demo"))
        await shot("paused")
        say("b4polish paused: icon=\(w.titleAreaIcon) text=\"\(w.activityText)\"")
        w.session.noteToolActivity(.idle)

        // P-139: the Settings window widens.
        OpenViewsAutomation.press(.character(","), modifiers: [.control])
        for _ in 0..<20 where OpenViewsAutomation.windowCount < 2 { await pause(0.2) }
        guard OpenViewsAutomation.windowCount >= 2 else { say("b4polish: Settings did not open"); return }
        await pause(0.8)
        let opened = OpenViewsAutomation.windowSize(1)?.points ?? .zero
        await shot("settings-710", window: 1)
        OpenViewsAutomation.resize(1, to: CGSize(width: 900, height: 760))
        await pause(1.0)
        let wide = OpenViewsAutomation.windowSize(1)?.points ?? .zero
        let control = frame("settings navigator size", window: 1)?.maxX ?? -1
        await shot("settings-900", window: 1)
        say("b4polish settings: opened \(opened.width)×\(opened.height) → \(wide.width)×\(wide.height), General pop-up ends at \(control) (card end − 10 = \(wide.width - SettingsLayout.cardInset - SettingsLayout.controlInset))")
        for pane in [ShellSettingsPane.appearance, .editing] {
            await SettingsDriver.open(pane)
            await shot("settings-900-\(pane.rawValue)", window: 1)
        }
    }
    #endif
}
