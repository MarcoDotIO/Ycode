import Foundation
import Testing
@testable import YcodeIDECore

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// reference-ui-5.md §1–§2 behavior: titles in context (§1.3), conditional
/// items and separators (§1.5), the system's items (§1.6), menus filled
/// from state, the jump-bar keyboard menus (§2.4, §6.1.3), Quick Actions
/// (§2.4 item 5) and the commands added with the menu bar.
@MainActor
@Suite(.serialized) struct MenuBarBehaviorTests {
    @Test func titlesInContext() {
        // No workspace: the generic titles.
        #expect(MenuTitles.title(generic: "Close Document", in: nil) == "Close Document")
        var c = MenuContext()
        c.containerKind = .package
        c.workspaceName = "Obs"
        c.fileName = "Model.swift"
        c.caretLine = 12
        #expect(MenuTitles.title(generic: "Close Tab, Editor Pane, Window Tab, or Window", in: c) == "Close Window")
        c.editorTabCount = 2
        #expect(MenuTitles.title(generic: "Close Tab, Editor Pane, Window Tab, or Window", in: c) == "Close Tab")
        #expect(MenuTitles.title(generic: "Close Document", in: c) == "Close \u{201C}Model.swift\u{201D}")
        #expect(MenuTitles.title(generic: "Close Workspace", in: c) == "Close Package")
        #expect(MenuTitles.title(generic: "Workspace Settings…", in: c) == "Package Settings…")
        #expect(MenuTitles.title(generic: "Add Files…", in: c) == "Add Files to \u{201C}Obs\u{201D}…")
        #expect(MenuTitles.title(generic: "Find in Workspace", in: c) == "Find in Package")
        #expect(MenuTitles.title(generic: "Find and Replace in Workspace…", in: c) == "Find and Replace in Package…")
        #expect(MenuTitles.title(generic: "Find in Selected Groups…", in: c) == "Find in Selected Groups…")
        #expect(MenuTitles.title(generic: "Jump to Line…", in: c) == "Jump to Line in \u{201C}Model.swift\u{201D}…")
        #expect(MenuTitles.title(generic: "Compile File", in: c) == "Compile \u{201C}Model.swift\u{201D}")
        #expect(MenuTitles.title(generic: "Bookmark Line", in: c) == "Bookmark \u{201C}Model.swift\u{201D} Line 12")
        #expect(MenuTitles.title(generic: "Bookmark File With Dialog", in: c) == "Bookmark \u{201C}Model.swift\u{201D}…")
        #expect(MenuTitles.title(generic: "Stage Selected Files", in: c) == "Stage Changes in \u{201C}Model.swift\u{201D}")
        #expect(MenuTitles.title(generic: "Discard Changes in Selected Files…", in: c) == "Discard Changes in \u{201C}Model.swift\u{201D}…")
        #expect(MenuTitles.title(generic: "Mark as Resolved", in: c) == "Mark Selected Files as Resolved")
        c.hasNavigatorFileSelection = true
        #expect(MenuTitles.title(generic: "Stage Selected Files", in: c) == "Stage Changes in Selected Files")
        c.selectedFileIsUntracked = true
        #expect(MenuTitles.title(generic: "Discard Changes in Selected Files…", in: c) == "Move Selected Files to Trash…")
        c.containerKind = .project
        #expect(MenuTitles.title(generic: "Find Next in Workspace", in: c) == "Find Next in Project")
        #expect(MenuTitles.title(generic: "Close Workspace", in: c) == "Close Project")
        c.windowTabCount = 2
        #expect(MenuTitles.title(generic: "Close Window", in: c) == "Close Window Tab")
        c.isPaused = true
        c.breakpointsActive = false
        #expect(MenuTitles.title(generic: "Pause", in: c) == "Continue")
        #expect(MenuTitles.title(generic: "Deactivate Breakpoints", in: c) == "Activate Breakpoints")
    }

    @Test func separatorsCollapseAroundHiddenItems() {
        // item, —, (hidden), —, item, —, (hidden) → one separator, none trailing.
        let shown = MenuConditions.visibleSeparators(isSeparator: [false, true, false, true, false, true, false],
                                                     isVisible: [true, false, false, false, true, false, false])
        #expect(shown == [false, true, false, false, false, false, false])
        #expect(MenuConditions.visibleSeparators(isSeparator: [true, false, true], isVisible: [false, true, false]) == [false, false, false])
    }

    /// §1.1: a disabled command keeps its shortcut; Key Bindings reports it
    /// as a conflict.
    @Test func disabledCommandsHoldTheirShortcuts() {
        let t = TestDefaults("menu-keys")
        defer { t.remove() }
        let p = Preferences(defaults: t.defaults, themesDirectory: ycodeDir.appendingPathComponent(".build-ide/menu-keys/Themes"))
        let build = KeyBindings.entries(p).first { $0.title == "Build" }!
        let c = KeyBindings.set(build.id, key: "b", modifiers: [.command, .control], p)
        #expect(c.map(\.title) == ["Compile File"])
        // Any spelling of a keystroke: "{" with ⌘ is ⇧⌘[.
        let c2 = KeyBindings.conflicts(key: "[", modifiers: [.command, .shift], excluding: build.id, p)
        #expect(c2.map(\.title) == ["Show Previous Tab"])
        #expect(p.keyBindingOverrides.isEmpty)
    }
}
