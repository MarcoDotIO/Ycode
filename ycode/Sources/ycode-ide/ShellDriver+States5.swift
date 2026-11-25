import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_STATES5=<prefix>: B5-STATES on the Linux IDE (P-198, #58,
// #64; `specs/ui/control-states.md`, `specs/ui/glass-materials.md`). Open a
// workspace whose Sources hold `Sticky.swift` (a struct of 60 lines from
// line 21). Writes <prefix>-st5-<state>.png and prints one line per step:
// the sticky line scrolled 392 points, the inspector's lens held and
// dragged (selection on release), the Settings pop-up's hover bezel, its
// menu open on mouse-down and a sidebar row selected on mouse-down.
extension ShellDriver {
    #if os(Linux)
    static func states5Walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("st5: no workspace"); return }
        // Scrolls the editor to `y`.
        func scrollEditor(to y: CGFloat) async {
            guard let doc = w.editor else { return say("st5: no editor") }
            let c = SourceEditorController.of(doc)
            // The caret inside the scrolled part, so nothing scrolls back to it.
            let line = Int(y / c.lineHeight) + 10
            if line < doc.buffer.lineCount { doc.buffer.setCaret(doc.buffer.document.lineStart(line)) }
            c.scroll(x: 0, y: y)
            say("st5 scroll \(doc.path) lines=\(doc.buffer.lineCount) viewport=\(c.viewport) content=\(c.contentHeight) top=\(c.top)")
            await pause(0.4)
        }
        func shot(_ name: String, window index: Int = 0, popups: Bool = false) async {
            await pause(0.5)
            let path = "\(prefix)-st5-\(name).png"
            say("st5 \(name): " + (popups ? OpenViewsAutomation.screenshotWithPopups(index, to: path) : OpenViewsAutomation.screenshot(index, to: path)))
        }
        // #58: the sticky line of the enclosing declaration.
        if let file = w.root.allFiles.compactMap(\.path).first(where: { $0.hasSuffix("Sticky.swift") }) {
            if let ids = w.root.idPath(to: file) { for id in ids.dropLast() { w.setExpanded(id, true) } }
            w.open(file)
            // The pane's restored position is applied on its first frames.
            await pause(2.5)
            await scrollEditor(to: 392)
            if let doc = w.editor {
                let c = SourceEditorController.of(doc)
                say("st5 sticky: lines \(SourceEditorPainter.stickyLines(c)) top \(c.top)")
            }
            await shot("sticky-392")
            await scrollEditor(to: 48)
            if let doc = w.editor {
                let c = SourceEditorController.of(doc)
                say("st5 sticky at 48: lines \(SourceEditorPainter.stickyLines(c)) top \(c.top)")
            }
            await shot("sticky-48")
        } else {
            say("st5: no Sticky.swift under the workspace")
        }
        // §3: the inspector's glass lens, held and dragged.
        w.isInspectorShown = true
        await pause(0.8)
        if let t1 = frame("inspector tab 1"), let t2 = frame("inspector tab 2") {
            let before = w.languageFeatures.inspectorTab
            OpenViewsAutomation.mouse(.down, at: CGPoint(x: t2.midX, y: t2.midY))
            await shot("inspector-lens-held")
            say("st5 lens held on 2: tab \(w.languageFeatures.inspectorTab) (before \(before))")
            OpenViewsAutomation.mouse(.moved, at: CGPoint(x: t1.midX, y: t1.midY + 40))
            await shot("inspector-lens-dragged")
            OpenViewsAutomation.mouse(.up, at: CGPoint(x: t1.midX, y: t1.midY + 40))
            await pause(0.4)
            say("st5 lens released off the bar over 1: tab \(w.languageFeatures.inspectorTab)")
            await click("inspector tab 0")
        } else {
            say("st5: no inspector tabs")
        }
        // §2: toolbar glass: Run's hover bezel; Stop held (disabled: no
        // press look, the window may move).
        if let run = frame("tb run") {
            OpenViewsAutomation.move(to: CGPoint(x: run.midX, y: run.midY))
            await shot("toolbar-run-hover")
            OpenViewsAutomation.move(to: CGPoint(x: run.midX, y: run.maxY + 200))
        }
        if let toggle = frame("tb inspector") {
            OpenViewsAutomation.mouse(.down, at: CGPoint(x: toggle.midX, y: toggle.midY))
            await shot("toolbar-inspector-held")
            OpenViewsAutomation.mouse(.up, at: CGPoint(x: toggle.midX, y: toggle.midY))
            await pause(0.4)
        }
        // §4: Settings.
        OpenViewsAutomation.press(.character(","), modifiers: [.control])
        for _ in 0..<20 where OpenViewsAutomation.windowCount < 2 { await pause(0.2) }
        guard OpenViewsAutomation.windowCount >= 2 else { say("st5: the Settings window did not open"); return }
        let settings = OpenViewsAutomation.windowCount - 1
        let m = ShellSettingsModel.shared
        m.select(.general)
        await pause(0.8)
        let frames = OpenViewsAutomation.identifiedFrames(settings)
        if let popUp = frames["settings navigator size"] {
            OpenViewsAutomation.move(to: CGPoint(x: popUp.midX, y: popUp.midY), window: settings)
            await shot("settings-popup-hover", window: settings)
            say("st5 pop-up hover: control \(popUp)")
            OpenViewsAutomation.mouse(.down, at: CGPoint(x: popUp.midX, y: popUp.midY), window: settings)
            await pause(0.4)
            say("st5 pop-up mouse-down: menus open \(OpenViewsAutomation.popupFrames(settings).count) (button still down)")
            await shot("settings-popup-down", window: settings, popups: true)
            OpenViewsAutomation.mouse(.up, at: CGPoint(x: popUp.midX, y: popUp.midY), window: settings)
            await pause(0.3)
            say("st5 pop-up released: menus open \(OpenViewsAutomation.popupFrames(settings).count)")
            OpenViewsAutomation.press(.escape, window: settings)
            await pause(0.3)
            OpenViewsAutomation.move(to: CGPoint(x: 5, y: 5), window: settings)
        } else {
            say("st5: no navigator size pop-up")
        }
        if let row = frames["settings pane appearance"] {
            OpenViewsAutomation.mouse(.down, at: CGPoint(x: row.midX, y: row.midY), window: settings)
            await pause(0.4)
            say("st5 sidebar mouse-down: pane \(m.pane.rawValue) (button still down)")
            await shot("settings-row-down", window: settings)
            OpenViewsAutomation.mouse(.up, at: CGPoint(x: row.midX, y: row.midY), window: settings)
            await pause(0.3)
        }
    }
    #endif
}
