import Foundation
import YcodeIDECore

/// The menu commands the L1 shell performs. Titles and shortcuts come from
/// the core's `CommandTable` (by action), dynamic titles from
/// `MenuTitles`, so the SwiftUI shell's menus match the AppKit shell's
/// (`specs/ide/menus.md`).
public enum ShellCommand: String, CaseIterable, Sendable {
    // File
    case open, closeWorkspace, newProject
    // View
    case showProjectNavigator, showFindNavigator, showIssueNavigator
    case toggleNavigator, toggleInspector, toggleDebugArea, activateConsole
    // Find
    case findInWorkspace
    // Navigate
    case revealInProjectNavigator, goBack, goForward, nextIssue, previousIssue
    // Product
    case run, test, stop, build, clean
    // Window
    case welcome
    // Ycode, Help, Integrate
    case about, help, releaseNotes, reportBug, swiftBook, clone

    /// The `CommandTable` action (and tag) of the command.
    public var action: (selector: String, tag: Int) {
        switch self {
        case .open: ("openDocument:", 0)
        case .newProject: ("newProject:", 0)
        case .closeWorkspace: ("closeWorkspace:", 0)
        case .showProjectNavigator: ("showNavigator:", ShellNavigator.project.selectorIndex)
        case .showFindNavigator: ("showNavigator:", ShellNavigator.find.selectorIndex)
        case .showIssueNavigator: ("showNavigator:", ShellNavigator.issues.selectorIndex)
        case .toggleNavigator: ("toggleNavigator:", 0)
        case .toggleInspector: ("toggleInspector:", 0)
        case .toggleDebugArea: ("toggleDebugArea:", 0)
        case .activateConsole: ("activateConsole:", 0)
        case .findInWorkspace: ("findInWorkspace:", 0)
        case .revealInProjectNavigator: ("revealInProjectNavigator:", 0)
        case .goBack: ("goBack:", 0)
        case .goForward: ("goForward:", 0)
        case .nextIssue: ("jumpToNextIssue:", 0)
        case .previousIssue: ("jumpToPreviousIssue:", 0)
        case .run: ("runProduct:", 0)
        case .test: ("testProduct:", 0)
        case .stop: ("stopProduct:", 0)
        case .build: ("buildProduct:", 0)
        case .clean: ("cleanProduct:", 0)
        case .welcome: ("showWelcomeWindow:", 0)
        case .about: ("showAboutWindow:", 0)
        case .help: ("showYcodeHelp:", 0)
        case .releaseNotes: ("showReleaseNotes:", 0)
        case .reportBug: ("reportBug:", 0)
        case .swiftBook: ("showSwiftBook:", 0)
        case .clone: ("scmClone:", 0)
        }
    }

    /// The menu the command is in (`CommandTable.menus` titles).
    public var menu: String {
        switch self {
        case .open, .closeWorkspace, .newProject: "File"
        case .showProjectNavigator, .showFindNavigator, .showIssueNavigator, .toggleNavigator, .toggleInspector, .toggleDebugArea,
             .activateConsole: "View"
        case .findInWorkspace: "Find"
        case .revealInProjectNavigator, .goBack, .goForward, .nextIssue, .previousIssue: "Navigate"
        case .run, .test, .stop, .build, .clean: "Product"
        case .welcome: "Window"
        case .about: "Ycode"
        case .help, .releaseNotes, .reportBug, .swiftBook: "Help"
        case .clone: "Integrate"
        }
    }

    /// The core's entry for the command (nil if the table lost it; a test
    /// checks there is one for every case).
    public var menuCommand: MenuCommand? {
        let (selector, tag) = action
        return Self.table.first { $0.action == selector && $0.tag == tag && !$0.isAlternate }
    }

    /// The title in context: the generic title with the dynamic titles
    /// applied ("Hide Navigator", "Close Package", "Find in Package").
    public func title(in context: MenuContext?) -> String {
        guard let c = menuCommand else { return rawValue }
        if self == .findInWorkspace, let ctx = context { return "Find in \(ctx.scopeName)" }
        return MenuTitles.title(for: c, in: context)
    }

    /// The default shortcut with shifted punctuation spelled as ⇧ plus the
    /// unshifted key ("⌘\"" → ⇧⌘'), the form toolkits other than AppKit
    /// take. Nil for a command without one.
    public var shortcut: ShellShortcut? { menuCommand.flatMap(ShellShortcut.init(command:)) }

    /// Every command of the core's menu bar, flattened.
    static let table: [MenuCommand] = {
        var out: [MenuCommand] = []
        func walk(_ items: [MenuItemSpec]) {
            for i in items {
                switch i {
                case .command(let c): out.append(c)
                case .submenu(_, let sub): walk(sub)
                case .separator, .label: break
                }
            }
        }
        for (_, items) in CommandTable.menus { walk(items) }
        return out
    }()
}

/// A key and modifiers in the core's terms (`MenuCommand.Key` characters
/// for arrows and function keys); each toolkit converts it.
public struct ShellShortcut: Equatable, Hashable, Sendable {
    public var key: String
    public var modifiers: MenuCommand.Modifiers
    public init(key: String, modifiers: MenuCommand.Modifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    /// A command's shortcut in this form (nil for none): shifted
    /// punctuation spelled as ⇧ plus the unshifted key.
    public init?(command c: MenuCommand) {
        guard !c.key.isEmpty else { return nil }
        if let base = Key.shiftedBase[c.key] { self.init(key: base, modifiers: c.modifiers.union(.shift)) } else {
            self.init(key: c.key, modifiers: c.modifiers)
        }
    }

    /// Menu notation (⇧⌘K), as the macOS shell shows it.
    public var text: String { Shortcut.text(key: key, modifiers: modifiers) }
}

/// The navigators L1 offers, in selector-bar order; each keeps its index
/// in the full bar (⌘1 Project, ⌘4 Find, ⌘5 Issues).
public enum ShellNavigator: String, CaseIterable, Sendable, Identifiable {
    case project, find, issues

    public var id: String { rawValue }

    public var selectorIndex: Int {
        switch self {
        case .project: 0
        case .find: 3
        case .issues: 4
        }
    }

    public var title: String { CommandTable.navigators[selectorIndex] }

    public var symbolName: String {
        switch self {
        case .project: "folder"
        case .find: "magnifyingglass"
        case .issues: "exclamationmark.triangle"
        }
    }

    public var command: ShellCommand {
        switch self {
        case .project: .showProjectNavigator
        case .find: .showFindNavigator
        case .issues: .showIssueNavigator
        }
    }
}
