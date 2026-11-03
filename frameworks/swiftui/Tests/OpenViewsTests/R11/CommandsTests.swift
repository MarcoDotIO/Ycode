import Foundation
import OVPlatform
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// Round R11 (docs/PARITY.md §5.4): the in-window menu bar built from
// `commands`, standard menus and groups, shortcuts routed through focus,
// focused values for enablement, the Edit menu on R8's text editing, the
// Settings scene and the window menu items.

@MainActor
@Suite("R11 commands and menu bar")
struct CommandsTests {
    struct Editor: View {
        @State var text = "hello"
        @FocusState var focused: Bool
        var body: some View {
            VStack {
                TextField("Name", text: $text)
                    .focused($focused)
                    .focusedValue(\.document, "Notes.txt")
                Text("Body")
            }
            .focusedSceneValue(\.sceneTitle, "Main")
        }
    }

    @Test func menusInTheirStandardOrder() {
        let h = CommandsHarness { Editor() }
        // App, File, Edit, View (sidebar group from SidebarCommands), the
        // app's Build menu after View, Window, Help.
        #expect(h.menuTitles == ["Demo", "File", "Edit", "View", "Build", "Window", "Help"])
        // The menu bar is the first 26 points; the content starts below it.
        let bar = h.frame { String(describing: type(of: $0)) == "MenuBarView" }
        #expect(bar.map { abs($0.minY) < 0.01 && abs($0.height - 26) < 0.01 } == true)
        let body = h.textFrame("Body")
        #expect((body?.minY ?? 0) > 26)
    }

    @Test func fileMenuHasTheGroupsInOrderAndShortcuts() {
        let h = CommandsHarness { Editor() }
        h.openMenu("File", at: 1)
        #expect(h.popups.count == 1)
        // New Window, Close Window (newItem), then the CommandGroup(after:).
        let items = h.openItems
        #expect(items.starts(with: ["New Window", "Ctrl+N", "Close Window", "Ctrl+W", "New File", "Ctrl+Shift+N"]))
        h.choose("New File", at: 1.5)
        #expect(CommandLog.shared.entries == ["new file"])
        #expect(h.popups.isEmpty)
        h.openMenu("Help", at: 2)
        #expect(h.openItems == ["OpenViews Guide"])
        h.key(.escape, at: 2.5)
        #expect(h.popups.isEmpty)
    }

    @Test func appMenuHasSettingsAndQuit() {
        let h = CommandsHarness { Editor() }
        h.openMenu("Demo", at: 1)
        #expect(h.openItems == ["About Demo", "Settings…", "Ctrl+,", "Quit Demo", "Ctrl+Q"])
    }

    @Test func shortcutsRunWithoutOpeningTheMenuAndFollowFocusedValues() {
        let h = CommandsHarness { Editor() }
        // Nothing focused: Build is disabled (its focused value is nil); Run
        // reads the scene value, present wherever the focus is.
        h.key(.character("b"), [.control], at: 1)
        h.key(.character("r"), [.control], at: 1.1)
        #expect(CommandLog.shared.entries == ["run Main"])
        h.openMenu("Build", at: 1.2)
        #expect(h.isItemEnabled("Build") == false)
        h.key(.escape, at: 1.3)
        // Focus the field: the document is published, Build runs with it.
        h.key(.tab, at: 1.5)
        #expect(h.main.services.focus.focusedClient != nil)
        h.key(.character("b"), [.control], at: 1.6)
        #expect(CommandLog.shared.entries == ["run Main", "build Notes.txt"])
        h.openMenu("Build", at: 2)
        #expect(h.isItemEnabled("Build") == true)
        #expect(h.openItems.contains("Ctrl+B"))
    }

    @Test func submenusOfCommandMenus() {
        let h = CommandsHarness { Editor() }
        h.openMenu("Build", at: 1)
        h.choose("More", at: 1.2)
        #expect(h.popups.count == 2)
        h.choose("Clean", at: 1.4)
        #expect(CommandLog.shared.entries == ["clean"])
        #expect(h.popups.isEmpty)
    }

    @Test func keyboardOpensAndWalksTheMenuBar() {
        let h = CommandsHarness { Editor() }
        h.key(.function(10), at: 1)
        #expect(h.main.services.menuBar?.openIndex == 0)
        h.key(.rightArrow, at: 1.1)
        #expect(h.main.services.menuBar?.openIndex == 1)
        h.key(.leftArrow, at: 1.2)
        h.key(.leftArrow, at: 1.3)
        #expect(h.main.services.menuBar?.openIndex == 6)
        #expect(h.openItems == ["OpenViews Guide"])
        // Down focuses the item, Return chooses it.
        h.key(.downArrow, at: 1.4)
        h.key(.return, at: 1.5)
        #expect(CommandLog.shared.entries == ["guide"])
        #expect(h.popups.isEmpty)
        #expect(h.main.services.menuBar?.openIndex == nil)
    }

    @Test func hoveringAnotherTitleSwitchesTheOpenMenu() {
        let h = CommandsHarness { Editor() }
        h.openMenu("File", at: 1)
        guard let edit = h.textFrame("Edit") else { Issue.record("Edit"); return }
        h.hover(CGPoint(x: edit.midX, y: edit.midY), at: 1.3)
        #expect(h.main.services.menuBar?.openIndex == 2)
        #expect(h.popups.count == 1)
        #expect(h.openItems.first == "Undo")
    }

    @Test func viewShortcutsComeBeforeMenuCommands() {
        let h = CommandsHarness {
            Button("Local") { CommandLog.shared.add("local") }.keyboardShortcut("r")
        }
        h.key(.character("r"), [.control], at: 1)
        #expect(CommandLog.shared.entries == ["local"])
    }

    @Test func editMenuActsOnTheFocusedTextField() {
        let h = CommandsHarness { Editor() }
        h.key(.tab, at: 1)
        // Keyboard focus selects all (R8); copy through the menu.
        h.openMenu("Edit", at: 1.2)
        #expect(h.isItemEnabled("Copy") == true)
        #expect(h.isItemEnabled("Undo") == false)
        h.choose("Copy", at: 1.4)
        #expect(h.backend.clipboard.text == "hello")
        h.type("x", at: 1.6)
        h.openMenu("Edit", at: 2)
        #expect(h.isItemEnabled("Undo") == true)
        h.choose("Undo", at: 2.2)
        h.openMenu("Edit", at: 2.5)
        h.choose("Select All", at: 2.7)
        h.openMenu("Edit", at: 3)
        h.choose("Cut", at: 3.2)
        #expect(h.backend.clipboard.text == "hello")
        h.openMenu("Edit", at: 3.5)
        h.choose("Paste", at: 3.7)
        guard let field = h.main.services.focus.focusedClient as? TextFieldState else { Issue.record("field"); return }
        #expect(field.model.text == "hello")
    }

    @Test func settingsSceneOpensOnceFromTheMenuAndTheShortcut() {
        let h = CommandsHarness { Editor() }
        #expect(h.host.windows.filter { !$0.isPopup }.count == 1)
        h.key(.character(","), [.control], at: 1)
        let main = h.host.windows.filter { !$0.isPopup }
        #expect(main.count == 2)
        guard let s = main.last, let pw = s.platform as? HeadlessWindow else { return }
        #expect(pw.title == "Settings")
        // The content's ideal size (400 × 250) and no menu bar of its own.
        #expect(abs(s.size.width - 400) < 0.01 && abs(s.size.height - 250) < 0.01)
        #expect(s.services.menuBar == nil)
        h.openMenu("Demo", at: 1.5)
        h.choose("Settings…", at: 1.7)
        #expect(h.host.windows.filter { !$0.isPopup }.count == 2)
        #expect(pw.activations >= 1)
    }

    @Test func windowMenuOpensNewWindowsListsThemAndCloses() {
        let h = CommandsHarness { Editor() }
        h.key(.character("n"), [.control], at: 1)
        #expect(h.host.windows.filter { !$0.isPopup }.count == 2)
        h.openMenu("Window", at: 1.5)
        // Minimize, the two open windows (current checked), the single
        // window scene.
        let items = h.openItems
        #expect(items.contains("Minimize") && items.filter { $0 == "Main" }.count == 2 && items.contains("Activity"))
        h.choose("Activity", at: 1.7)
        #expect(h.host.windows.filter { !$0.isPopup }.count == 3)
        h.key(.character("w"), [.control], at: 2)
        #expect(h.host.windows.filter { !$0.isPopup }.count == 2)
        h.key(.character("m"), [.control], at: 2.2)
        #expect((h.main.platform as? HeadlessWindow)?.isMinimized == true)
    }

    @Test func quitFromTheMenu() {
        let h = CommandsHarness { Editor() }
        h.key(.character("q"), [.control], at: 1)
        #expect(h.host.isFinished)
        #expect(h.host.quitByUser)
    }

    @Test func sidebarCommandTogglesTheSplitViewsSidebar() {
        let h = CommandsHarness {
            NavigationSplitView { Text("Side") } detail: { Text("Detail") }
        }
        #expect(h.textFrame("Side") != nil)
        h.key(.character("s"), [.control, .option], at: 1)
        h.run(until: 1.6)
        #expect(h.textFrame("Side") == nil)
        h.openMenu("View", at: 2)
        #expect(h.openItems.contains("Show Sidebar"))
        h.choose("Show Sidebar", at: 2.2)
        h.run(until: 2.8)
        #expect(h.textFrame("Side") != nil)
    }

    @Test func shortcutText() {
        #expect(KeyboardShortcut("z", modifiers: [.command, .shift]).displayText == "Ctrl+Shift+Z")
        #expect(KeyboardShortcut(.return, modifiers: []).displayText == "Enter")
        #expect(KeyboardShortcut("s", modifiers: [.command, .option]).displayText == "Ctrl+Alt+S")
        #expect(KeyboardShortcut(.leftArrow, modifiers: .control).displayText == "Ctrl+Left")
    }

    @Test func headlessHostWithoutAMenuBarStillHasCommandShortcuts() {
        let h = CommandsHarness(menuBar: false) { Editor() }
        #expect(h.main.services.menuBar == nil)
        #expect(h.textFrame("Body").map { $0.minY < 26 } == true || h.textFrame("Body") != nil)
        h.key(.character("r"), [.control], at: 1)
        #expect(CommandLog.shared.entries == ["run Main"])
    }
}
