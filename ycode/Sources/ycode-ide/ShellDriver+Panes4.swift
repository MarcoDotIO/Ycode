import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_PANES4=<prefix>: beta 4's B4-PANES states on the workspace given
// as the path (`specs/ide/parity-inventory.md`), in the appearance set by
// OV_COLOR_SCHEME:
//
//   toggle        ⌘5 (Ctrl+5) twice: the Issue navigator hides, then shows (P-036)
//   repositories  Source Control ▸ Repositories: the grey group glyphs (P-047)
//   settings-*    Editing ▸ Display pushed (the title "Display", no "‹ Editing"),
//                 back to Editing, Behaviors ▸ an event, back (P-138);
//                 Components' first frame (P-140)
//
// Each state writes <prefix>-<state>.png and prints a "panes4 …" line.
extension ShellDriver {
    #if os(Linux)
    static func panes4Walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("panes4: no workspace"); return }
        func shot(_ state: String, window: Int = 0) async {
            await pause(0.7)
            say("panes4 \(state): " + OpenViewsAutomation.screenshot(window, to: "\(prefix)-\(state).png"))
        }

        // P-036: the navigator's command on the navigator shown hides it.
        w.perform(.showIssueNavigator)
        await pause(0.3)
        let shown = w.isNavigatorShown && w.navigator == .issues
        w.perform(.showIssueNavigator)
        await pause(0.3)
        let hidden = !w.isNavigatorShown
        await shot("toggle-hidden")
        w.perform(.showIssueNavigator)
        await pause(0.3)
        say("panes4 toggle: shown=\(shown) hidden=\(hidden) again=\(w.isNavigatorShown && w.navigator == .issues)")

        // P-047: the Repositories view's glyphs.
        w.perform(.showSourceControlNavigator)
        await pause(0.4)
        w.sourceControl.mode = .repositories
        await shot("repositories")

        // P-138, P-140: Settings.
        OpenViewsAutomation.press(.character(","), modifiers: [.control])
        for _ in 0..<20 where OpenViewsAutomation.windowCount < 2 { await pause(0.2) }
        guard OpenViewsAutomation.windowCount >= 2 else { say("panes4: Settings did not open"); return }
        await pause(0.8)
        let model = ShellSettingsModel.shared
        await SettingsDriver.open(.components)
        // The first frame after the click: the values read when the window opened.
        say("panes4 components: " + OpenViewsAutomation.screenshot(1, to: "\(prefix)-settings-components.png")
            + " inventory=\(model.componentsInventory != nil)")
        await SettingsDriver.open(.editing)
        await SettingsDriver.click("settings editing display")
        await pause(0.4)
        let texts = OpenViewsAutomation.texts(1).map(\.text)
        say("panes4 display: title=\(model.title) backLink=\(texts.contains { $0.hasPrefix("\u{2039}") }) back=\(model.back.count)")
        await SettingsDriver.shot(prefix, "settings-display")
        await SettingsDriver.click("settings back")
        say("panes4 back: pane=\(model.pane.rawValue) page=\(model.editingPage.rawValue) title=\(model.title)")
        await SettingsDriver.shot(prefix, "settings-editing")
        await SettingsDriver.open(.behaviors)
        await SettingsDriver.click("settings behavior buildStarts")
        say("panes4 behavior: title=\(model.title)")
        await SettingsDriver.shot(prefix, "settings-behavior")
        await SettingsDriver.click("settings back")
        say("panes4 behavior back: title=\(model.title) event=\(model.behaviorEvent.map(\.rawValue) ?? "none")")
    }
    #endif
}
