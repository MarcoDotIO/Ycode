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

    /// Clicks a named view of the Settings window.
    static func click(_ name: String, dx: CGFloat? = nil) async {
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

        // General: a checkbox, and File extensions through the model.
        await shot(prefix, "general")
        await click("settings stop on error", dx: 8)
        prefs.fileExtensions = .show
        await shot(prefix, "general-changed")

        // Appearance: pick Dusk, duplicate it, recolor its keywords.
        await open(.appearance)
        prefs.themeName = "Ycode Dusk"
        await shot(prefix, "appearance")
        await click("settings theme duplicate")
        say("settings theme after Duplicate: \(prefs.themeName)")
        await type("#FF8A3D", into: "settings color comment")
        await ShellDriver.pause(0.4)
        say("settings comment color: \(prefs.theme.tokens["comment"] ?? "-")")
        await shot(prefix, "appearance-user-theme")
        if let list = OpenViewsAutomation.identifiedFrames(1)["settings"] {
            OpenViewsAutomation.scroll(at: CGPoint(x: list.midX + 100, y: list.midY), delta: CGSize(width: 0, height: -12), window: 1)
            await shot(prefix, "appearance-scrolled")
        }

        // Behaviors: the list, then an event's page with Notify checked.
        await open(.behaviors)
        await shot(prefix, "behaviors")
        await click("settings behavior buildStarts")
        await click("settings behavior notify", dx: 8)
        await shot(prefix, "behaviors-event")
        model.behaviorEvent = nil

        // Navigation.
        await open(.navigation)
        prefs.optionClickOnCode = .definition
        await shot(prefix, "navigation")

        // Notifications.
        await open(.notifications)
        await click("settings notify runStarts", dx: 8)
        await shot(prefix, "notifications")

        // Editing and its pages.
        await open(.editing)
        await shot(prefix, "editing")
        await click("settings editing display")
        await click("settings line numbers", dx: 8)
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
        await click("settings source control", dx: 8)
        await ShellDriver.pause(1)
        await shot(prefix, "source-control")
        prefs.sourceControlEnabled = true
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
        await open(.editing)
        await shot(prefix, "dark-editing")

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
