import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// Settings automation (OpenViews only), started from ShellDriver:
//
//   YCODE_IDE_SETTINGS=<p>  open Settings with Ctrl+,, visit every pane with
//                           the pointer, change one setting in each (through
//                           its control where the driver can reach it),
//                           photograph each pane as <p>-<pane>.png, then a
//                           few panes in the Dark appearance chosen in the
//                           pane (<p>-dark-<pane>.png); with a workspace
//                           open, a changed shortcut is pressed in the
//                           workspace window to show the menus took it.
//                           Prints "settings values: …" at the start and the
//                           end, so a second launch shows what persisted.
//   YCODE_IDE_SETTINGS_VERIFY=1  only print "settings values: …" and quit.
//
// Run it with XDG_CONFIG_HOME and XDG_DATA_HOME pointing at a scratch
// folder: the user defaults and themes it changes are the user's own.

#if os(Linux)
@MainActor
enum SettingsDriver {
    static var say: (String) -> Void { ShellDriver.say }

    /// The settings the run changes, in one line.
    static func values() -> String {
        let p = Preferences.shared
        let overrides = p.keyBindingOverrides.map { "\($0.key)=\(ShortcutNotation.linux.text(key: $0.value.key, modifiers: $0.value.mods))" }.sorted()
        return "settings values: comment=\(p.theme.tokens["comment"] ?? "-") fileExtensions=\(p.fileExtensions.rawValue) stopOnError=\(p.stopBuildOnFirstError) theme=\(p.themeName) "
            + "appearance=\(p.appearance.rawValue) keyword=\(p.theme.tokens["keyword"] ?? "-") lineNumbers=\(p.showLineNumbers) "
            + "tabWidth=\(p.tabWidth) optionClick=\(p.optionClickOnCode.rawValue) notifyRunStarts=\(p.behavior(.runStarts).notify) "
            + "buildStarts=\(p.behavior(.buildStarts).actionTitles) sourceControl=\(p.sourceControlEnabled) bindings=\(overrides)"
    }

    static func frame(_ name: String) -> CGRect? { OpenViewsAutomation.identifiedFrames(1)[name] }

    /// Scrolls the pane until a named view is in the window (the cards
    /// run past the 452-point window).
    static func reveal(_ name: String) async {
        let height = OpenViewsAutomation.windowSize(1)?.points.height ?? SettingsLayout.windowSize.height
        let top = SettingsLayout.titleAreaHeight + 4
        for _ in 0..<12 {
            let f = frame(name)
            if let f, f.minY >= top, f.maxY <= height - 4 { return }
            // Scroll by the distance (points), or a screenful when the view is not laid out yet.
            let dy = f.map { $0.maxY > height - 4 ? -($0.maxY - height + 60) : top + 40 - $0.minY } ?? -200
            OpenViewsAutomation.scroll(at: CGPoint(x: SettingsLayout.windowSize.width - 120, y: height / 2),
                                       delta: CGSize(width: 0, height: dy), window: 1)
            await ShellDriver.pause(0.25)
        }
    }

    /// Clicks a named view of the Settings window.
    static func click(_ name: String, dx: CGFloat? = nil) async {
        await reveal(name)
        guard let f = frame(name) else {
            say("settings: no target \(name)")
            return
        }
        await OpenViewsAutomation.click(at: CGPoint(x: dx.map { f.minX + $0 } ?? f.midX, y: f.midY), window: 1)
        await ShellDriver.pause(0.35)
    }

    /// Clicks a field of the Settings window and replaces its text.
    static func type(_ text: String, into name: String) async {
        await click(name)
        OpenViewsAutomation.press(.character("a"), modifiers: [.control], window: 1)
        await ShellDriver.pause(0.1)
        OpenViewsAutomation.press(.backspace, window: 1)
        OpenViewsAutomation.type(text, window: 1)
        await ShellDriver.pause(0.3)
    }

    static func shot(_ prefix: String, _ name: String) async {
        await ShellDriver.pause(0.6)
        say("settings \(name): " + OpenViewsAutomation.screenshot(1, to: "\(prefix)-\(name).png"))
    }

    static func open(_ pane: ShellSettingsPane) async {
        await click("settings pane \(pane.rawValue)")
        say("settings pane \(pane.rawValue): shown=\(ShellSettingsModel.shared.pane.rawValue)")
    }

    /// Checks the window's measured layout and prints one line per check
    /// and "settings layout: ok" or "settings layout: FAILED …".
    static func checkLayout() {
        var failures: [String] = []
        func near(_ a: CGFloat?, _ b: CGFloat, _ what: String, _ tolerance: CGFloat = 0.6) {
            let ok = a.map { abs($0 - b) <= tolerance } ?? false
            say("settings layout: \(what) \(a.map { "\($0)" } ?? "missing") (\(b)) \(ok ? "yes" : "NO")")
            if !ok { failures.append(what) }
        }
        if let s = OpenViewsAutomation.windowSize(1) {
            near(s.points.width, SettingsLayout.windowSize.width, "window width")
            near(s.points.height, SettingsLayout.windowSize.height, "window height")
        }
        for (i, p) in ShellSettingsPane.allCases.enumerated() {
            let f = frame("settings pane \(p.rawValue)")
            near(f?.minY, SettingsLayout.sidebarTop + CGFloat(i) * SettingsLayout.sidebarRowHeight, "\(p.rawValue) row top")
            near(f?.height, SettingsLayout.sidebarRowHeight, "\(p.rawValue) row height")
        }
        near(frame("settings pane general")?.minX, 0, "sidebar flush")
        near(frame("settings pane general")?.width, SettingsLayout.sidebarWidth, "sidebar width")
        near(frame("settings back")?.minX, SettingsLayout.capsuleFrame.minX, "capsule x")
        near(frame("settings forward")?.maxX, SettingsLayout.capsuleFrame.maxX, "capsule end")
        near(frame("settings back")?.height, SettingsLayout.capsuleFrame.height, "capsule height")
        near(frame("settings title")?.minX, SettingsLayout.titleX, "title x", 1)
        // The General pane: controls end 10 inside the card (x 680).
        let cardEnd = SettingsLayout.windowSize.width - SettingsLayout.cardInset
        near(frame("settings navigator size")?.maxX, cardEnd - SettingsLayout.controlInset, "pop-up end")
        near(frame("settings sidebar widths")?.maxX, cardEnd - SettingsLayout.controlInset, "switch end")
        near(frame("settings sidebar widths")?.width, SettingsLayout.switchSize.width, "switch width")
        near(frame("settings sidebar widths")?.height, SettingsLayout.switchSize.height, "switch height")
        say(failures.isEmpty ? "settings layout: ok" : "settings layout: FAILED \(failures)")
    }

    /// Checks the Editing pane's cards (R4.1): the navigation rows 44 tall
    /// from y 72, text encoding alone in a card at 216, line endings and the
    /// convert switch in the next at 263.5, When Editing's card at 394.
    /// Prints "settings editing layout: ok" or "… FAILED …".
    static func checkEditingLayout() {
        var failures: [String] = []
        func near(_ a: CGFloat?, _ b: CGFloat, _ what: String, _ tolerance: CGFloat = 0.6) {
            let ok = a.map { abs($0 - b) <= tolerance } ?? false
            say("settings editing layout: \(what) \(a.map { "\($0)" } ?? "missing") (\(b)) \(ok ? "yes" : "NO")")
            if !ok { failures.append(what) }
        }
        let row = SettingsLayout.navigationRowHeight + SettingsLayout.separatorHeight
        for (i, name) in ["display", "completion", "indentation"].enumerated() {
            let f = frame("settings editing \(name)")
            near(f?.minY, SettingsLayout.firstCardTop + CGFloat(i) * row, "\(name) row top")
            near(f?.height, SettingsLayout.navigationRowHeight, "\(name) row height")
            near(f?.minX, SettingsLayout.detailX + SettingsLayout.cardInset, "\(name) row x")
        }
        let line = SettingsLayout.rowHeight
        near(frame("settings text encoding")?.midY, 216 + line / 2, "text encoding card")
        near(frame("settings line endings")?.midY, 263.5 + line / 2, "line endings card")
        near(frame("settings convert on save")?.midY, 263.5 + line + 1 + line / 2, "convert row", 1)
        near(frame("settings trim whitespace")?.midY, 394 + line / 2, "When Editing card", 1.5)
        near(frame("settings convert on save")?.width, SettingsLayout.switchSize.width, "switch width")
        let controlEnd = SettingsLayout.windowSize.width - SettingsLayout.cardInset - SettingsLayout.controlInset
        near(frame("settings text encoding")?.maxX, controlEnd, "pop-up end")
        say(failures.isEmpty ? "settings editing layout: ok" : "settings editing layout: FAILED \(failures)")
    }

    static func run(_ app: ShellAppModel, prefix: String) async {
        say(values())
        OpenViewsAutomation.press(.character(","), modifiers: [.control])
        for _ in 0..<20 where OpenViewsAutomation.windowCount < 2 { await ShellDriver.pause(0.2) }
        guard OpenViewsAutomation.windowCount >= 2 else {
            say("settings: the window did not open")
            return
        }
        await ShellDriver.pause(0.8)
        if let s = OpenViewsAutomation.windowSize(1) { say("settings window \(s.points.width)x\(s.points.height) pt") }
        let model = ShellSettingsModel.shared
        let prefs = Preferences.shared
        // The light shots first (the Dark ones come from Appearance below).
        prefs.appearance = .light
        await ShellDriver.pause(0.6)
        say("settings workspace: " + OpenViewsAutomation.screenshot(to: "\(prefix)-workspace-light.png"))

        // The window, sidebar and General cards (settings.md R3.1–R3.3).
        checkLayout()
        // General: a switch, and File extensions through the model.
        await shot(prefix, "general")
        await click("settings stop on error")
        prefs.fileExtensions = .show
        await shot(prefix, "general-changed")

        // Appearance: pick Dusk, duplicate it, recolor its keywords.
        await open(.appearance)
        prefs.themeName = "Ycode Dusk"
        await shot(prefix, "appearance")
        await click("settings theme duplicate")
        say("settings theme after Duplicate: \(prefs.themeName)")
        // The colour well edits in a popover; set the colour as it would.
        prefs.editSelectedTheme { $0.tokens["comment"] = "#FF8A3D" }
        await ShellDriver.pause(0.4)
        say("settings comment color: \(prefs.theme.tokens["comment"] ?? "-")")
        await shot(prefix, "appearance-user-theme")
        if let list = OpenViewsAutomation.identifiedFrames(1)["settings"] {
            OpenViewsAutomation.scroll(at: CGPoint(x: list.midX + 100, y: list.midY), delta: CGSize(width: 0, height: -12), window: 1)
            await shot(prefix, "appearance-scrolled")
        }

        // Accounts: the empty list, and the sheet + shows (AccountsDriver
        // checks the page in detail).
        await open(.accounts)
        await shot(prefix, "accounts")
        await click("settings accounts add")
        await shot(prefix, "accounts-sheet")
        model.isAccountsSheetShown = false

        // Behaviors: the list, then an event's page with Notify checked.
        await open(.behaviors)
        await shot(prefix, "behaviors")
        await click("settings behavior buildStarts")
        await click("settings behavior notify")
        await shot(prefix, "behaviors-event")
        model.behaviorEvent = nil

        // Navigation.
        await open(.navigation)
        prefs.optionClickOnCode = .definition
        await shot(prefix, "navigation")

        // Notifications.
        await open(.notifications)
        await click("settings notify runStarts")
        await shot(prefix, "notifications")

        // Editing and its pages.
        await open(.editing)
        checkEditingLayout()
        await shot(prefix, "editing")
        await click("settings editing display")
        await click("settings line numbers")
        await shot(prefix, "editing-display")
        await click("settings editing back")
        await click("settings editing indentation")
        prefs.tabWidth = 2
        await shot(prefix, "editing-indentation")
        await click("settings editing back")
        await click("settings editing completion")
        await shot(prefix, "editing-completion")
        await click("settings editing back")

        // Shortcuts: filter, refuse a taken shortcut, set a free one.
        await open(.shortcuts)
        await shot(prefix, "shortcuts")
        await type("issue", into: "settings shortcuts filter")
        await click("settings shortcut Issues")
        await type("Ctrl+B", into: "settings shortcut field")
        await click("settings shortcut set")
        say("settings conflict: \(OpenViewsAutomation.texts(1).first { $0.text.contains("is not set") }?.text ?? "none")")
        await shot(prefix, "shortcuts-conflict")
        // A keystroke no command has.
        let free = "jkyuh".map(String.init).first { KeyBindings.conflicts(key: $0, modifiers: [.command, .option, .shift], excluding: "", in: .linux).isEmpty } ?? "y"
        await type("Ctrl+Alt+Shift+\(free.uppercased())", into: "settings shortcut field")
        await click("settings shortcut set")
        await shot(prefix, "shortcuts-set")

        // Source Control and Locations.
        await open(.sourceControl)
        await click("settings source control")
        await ShellDriver.pause(1)
        await shot(prefix, "source-control")
        prefs.sourceControlEnabled = true
        await open(.components)
        await ShellDriver.pause(0.5)
        say("settings components platforms: \(frame("settings components row iOS") != nil)")
        await shot(prefix, "components")
        await open(.locations)
        await ShellDriver.pause(1)
        await shot(prefix, "locations")

        // The Dark appearance, chosen in Appearance, applies at once.
        await open(.appearance)
        await click("settings appearance dark")
        await shot(prefix, "dark-appearance")
        await open(.shortcuts)
        await shot(prefix, "dark-shortcuts")
        await open(.general)
        await shot(prefix, "dark-general")
        await open(.navigation)
        await shot(prefix, "dark-navigation")
        await open(.accounts)
        await shot(prefix, "dark-accounts")
        await open(.editing)
        await shot(prefix, "dark-editing")
        checkEditingLayout()

        // The changed shortcut works in the workspace window's menus.
        if let w = app.workspace {
            w.navigator = .project
            await ShellDriver.pause(0.4)
            OpenViewsAutomation.press(.character(Character(free)), modifiers: [.control, .option, .shift])
            await ShellDriver.pause(0.6)
            say("settings shortcut in the menus: navigator=\(w.navigator.rawValue) (expected issues)")
            w.navigator = .project
            await ShellDriver.pause(0.6)
            say("settings project rows: \(w.projectRows.map(\.title)) (File extensions: Show All)")
            say("settings workspace: " + OpenViewsAutomation.screenshot(to: "\(prefix)-workspace-dark.png"))
        }
        say(values())
    }
}
#endif
