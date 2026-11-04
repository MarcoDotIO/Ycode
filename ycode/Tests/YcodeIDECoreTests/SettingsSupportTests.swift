import Foundation
import Testing
@testable import YcodeIDECore

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The toolkit-free Settings logic both IDEs share (`SettingsSupport.swift`,
/// `specs/ide/settings.md`): shortcut notation and parsing, conflicts per
/// host, behavior actions, user-theme edits.
@MainActor
@Suite(.serialized) struct SettingsSupportTests {
    func prefs(_ name: String) -> (Preferences, TestDefaults) {
        let t = TestDefaults(name)
        let dir = ycodeDir.appendingPathComponent(".build-ide/\(name)/Themes")
        try? FileManager.default.removeItem(at: dir)
        return (Preferences(defaults: t.defaults, themesDirectory: dir), t)
    }

    @Test func linuxNotation() {
        let n = ShortcutNotation.linux
        #expect(n.text(key: "k", modifiers: [.command, .shift]) == "Ctrl+Shift+K")
        #expect(n.text(key: "b", modifiers: [.command, .control]) == "Super+Ctrl+B")
        #expect(n.text(key: "{", modifiers: [.command]) == "Ctrl+Shift+[")
        #expect(n.text(key: Key.return, modifiers: [.command]) == "Ctrl+Enter")
        #expect(n.text(key: Key.function(6), modifiers: [.control]) == "Ctrl+F6")
        #expect(n.text(key: "", modifiers: [.command]) == "")
        #expect(ShortcutNotation.mac.text(key: "k", modifiers: [.command, .shift]) == "⇧⌘K")
    }

    /// A parsed shortcut in menu notation ("" for none, nil if unreadable).
    func parsed(_ text: String) -> String? { KeyBindings.parse(text).map { ShortcutNotation.mac.text(key: $0.key, modifiers: $0.modifiers) } }

    @Test func parsesBothNotations() {
        #expect(parsed("⌃⇧⌘K") == "⌃⇧⌘K")
        #expect(parsed("Ctrl+Shift+K") == "⇧⌘K")
        #expect(parsed("super+ctrl+alt+f") == "⌃⌥⌘F")
        #expect(parsed("Ctrl+Enter") == "⌘↩")
        #expect(parsed("⌘↩") == "⌘↩")
        #expect(parsed("Ctrl+F6") == "⌘F6")
        #expect(parsed("Ctrl++") == "⌘+")
        #expect(parsed("  ") == "")
        #expect(parsed("Ctrl+Hyper+K") == nil)
        #expect(parsed("Ctrl+KK") == nil)
    }

    @Test func linuxConflictsFoldCommandAndControl() {
        let (p, t) = prefs("settings-conflicts")
        defer { t.remove() }
        let build = KeyBindings.entries(p).first { $0.title == "Build" }!
        // ⌘B is Build, and on Linux ⌃B is the same keystroke (Ctrl+B).
        let other = KeyBindings.entries(p).first { $0.id != build.id && $0.command.key.isEmpty }!
        #expect(KeyBindings.conflicts(key: "b", modifiers: [.control], excluding: other.id, in: .mac, p).map(\.id).contains(build.id) == false)
        let refused = KeyBindings.set(other.id, key: "b", modifiers: [.control], in: .linux, p)
        #expect(refused.map(\.id).contains(build.id))
        #expect(p.keyBindingOverrides[other.id] == nil)
        #expect(KeyBindings.conflictMessage(refused).contains("Build (Product)"))
        // A free keystroke is saved, and an empty one removes the shortcut.
        #expect(KeyBindings.set(other.id, key: "y", modifiers: [.command, .option, .shift], in: .linux, p).isEmpty)
        #expect(KeyBindings.effective(other.command, p).key == "y")
        #expect(KeyBindings.set(build.id, key: "", modifiers: [], in: .linux, p).isEmpty)
        #expect(KeyBindings.entries(p).first { $0.id == build.id }!.command.key.isEmpty)
        #expect(KeyBindings.entries(p).first { $0.id == build.id }!.customized)
    }

    @Test func behaviorActions() {
        var b = Preferences.Behavior()
        for a in Preferences.Behavior.addableActions() { b.add(action: a) }
        #expect(b.showNavigator == CommandTable.navigators.count - 1)
        #expect(b.notify && b.hideDebugAreaIfNoOutput && b.sound == "Hero")
        for a in b.actionTitles { b.remove(action: a) }
        #expect(b == Preferences.Behavior())
        #expect(Preferences.Event.buildSucceeds.notificationTitle == "Build succeeds")
    }

    @Test func editsOnlyUserThemes() throws {
        let (p, t) = prefs("settings-themes")
        defer { t.remove() }
        #expect(!p.editSelectedTheme { $0.tokens["keyword"] = "#123456" })
        let copy = try p.duplicate(EditorTheme.builtIns[2])
        #expect(p.themeName == copy.name)
        #expect(p.editSelectedTheme { $0.tokens["keyword"] = "#123456" })
        #expect(p.theme.tokens["keyword"] == "#123456")
        #expect(EditorTheme.builtIns[2].tokens["keyword"] != "#123456")
    }
}
