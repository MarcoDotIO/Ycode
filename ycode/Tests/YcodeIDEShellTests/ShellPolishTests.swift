import Foundation
import Testing
import YcodeBuild
import YcodeIDECore
@testable import YcodeIDEShell

/// The Linux IDE's polish pass (Ycode beta 2): the console rows' Copy items,
/// the shortcuts of Deactivate Breakpoints and Redo on Linux, and the
/// Symbol navigator's place in the selector bar.
@MainActor
@Suite struct ShellPolishTests {
    @Test func consoleRowsAreCopiedFromTheMenuAndTheirContextMenu() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        // A pseudo-terminal's output: lines end with "\r\n".
        m.session.appendConsole("Hello, Ada!\r\nHello, Grace!\r\n", kind: .target)
        m.session.appendConsole("Process 7 exited\n", kind: .debugger)
        #expect(m.debug.consoleRows.map(\.text) == ["Hello, Ada!", "Hello, Grace!", "Process 7 exited"])
        // Nothing selected: the items are disabled.
        #expect(!m.isEnabled(.copyConsoleRowWithoutMetadata))
        m.debug.selectedConsoleRow = 1
        for c in [ShellCommand.copyConsoleRowWithVisibleMetadata, .copyConsoleRowWithAllMetadata, .copyConsoleRowWithoutMetadata] {
            #expect(m.isEnabled(c), "\(c)")
            #expect(c.menu == "Debug" && c.menuCommand != nil, "\(c)")
        }
        m.perform(.copyConsoleRowWithoutMetadata)
        #expect(ShellPasteboard.lastCopied == "Hello, Grace!")
        m.perform(.copyConsoleRowWithAllMetadata)
        // Type and time in front ("17:05:01.123 [Target] Hello, Grace!").
        let all = try #require(ShellPasteboard.lastCopied)
        #expect(all.hasSuffix("[Target] Hello, Grace!") && all.count > "[Target] Hello, Grace!".count)
        // The Linux console shows no metadata: "visible" is the bare row.
        m.perform(.copyConsoleRowWithVisibleMetadata)
        #expect(ShellPasteboard.lastCopied == "Hello, Grace!")
        #expect(ShellCommand.copyConsoleRowWithVisibleMetadata.shortcut?.text == "⌥⇧C")
    }

    @Test func deactivateBreakpointsIsCtrlYAndRedoCtrlShiftZOnLinux() {
        let deactivate = ShellCommand.toggleBreakpointsActive.menuCommand
        #expect(deactivate.map { ShortcutNotation.linux.text($0) } == "Ctrl+Y")
        // Settings ▸ Key Bindings: the defaults say the same.
        let entries = KeyBindings.entries(Preferences(defaults: UserDefaults(suiteName: "ycode-polish-\(UUID().uuidString)")!), includingUnavailable: true)
        #expect(entries.first { $0.command.action == "toggleBreakpointsActive:" }.map { ShortcutNotation.linux.text($0.command) } == "Ctrl+Y")
        #expect(entries.first { $0.command.action == "redo:" }.map { ShortcutNotation.linux.text($0.command) } == "Ctrl+Shift+Z")
        // No other command takes Ctrl+Y on Linux.
        #expect(KeyBindings.conflicts(key: "y", modifiers: [.command], excluding: "toggleBreakpointsActive:#0", in: .linux,
                                      Preferences(defaults: UserDefaults(suiteName: "ycode-polish-\(UUID().uuidString)")!)).isEmpty)
    }

    @Test func theSymbolNavigatorHasItsOwnSelectorButton() {
        let b = ShellNavigator.selectorButtons
        #expect(b.count == 9)
        #expect(b[2].symbol == "list.bullet.indent" && b[2].toolTip == "Show the Symbol navigator" && b[2].title == "Symbols")
        #expect(b[0].symbol == "folder" && b[0].toolTip == "Show the Project navigator")
        #expect(b[3].toolTip == "Show the Find navigator")
    }
}
