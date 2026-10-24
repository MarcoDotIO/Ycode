import Foundation

/// The menu bar as data: menu titles, items, key equivalents and the action
/// each item sends up the responder chain. See `specs/ide/menus.md` and the
/// normative menu bar of `specs/ide/reference-ui-5.md` §1–§2.
public struct MenuCommand: Equatable, Sendable {
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1)
        public static let shift = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let control = Modifiers(rawValue: 8)
    }

    /// The generic title: the one shown with no workspace window
    /// (reference-ui-5.md §1.3). `MenuTitles` gives the title in context.
    public var title: String
    /// The key as AppKit expects it: lowercase letters (with `.shift` for
    /// ⇧), the shifted character for shifted punctuation ("{" for ⇧[, §1.8),
    /// AppKit's private-use characters for arrows and function keys (see
    /// `Key`). Empty for no shortcut.
    public var key: String
    /// The shortcut's modifiers. For an alternate without a shortcut, the
    /// modifiers that reveal it.
    public var modifiers: Modifiers
    /// Objective-C selector name, e.g. `"buildProduct:"`.
    public var action: String
    /// For navigator / inspector selection commands: the index to select.
    public var tag: Int
    /// An alternate of the item just above it, shown only while its extra
    /// modifiers are held (§1.2).
    public var isAlternate: Bool
    /// Shown only while this holds (§1.5); nil = always.
    public var condition: MenuCondition?

    public init(_ title: String, _ key: String = "", _ modifiers: Modifiers = [], _ action: String, tag: Int = 0,
                isAlternate: Bool = false, condition: MenuCondition? = nil) {
        self.title = title
        self.key = key
        self.modifiers = key.isEmpty && !isAlternate ? [] : modifiers
        self.action = action
        self.tag = tag
        self.isAlternate = isAlternate
        self.condition = condition
    }

    /// A command whose shortcut is written in menu notation ("⌥⇧⌘W",
    /// "⌃F6", "⌘{"). See `Shortcut.parse`.
    public init(_ title: String, shortcut: String, _ action: String, tag: Int = 0, isAlternate: Bool = false, condition: MenuCondition? = nil) {
        let (k, m) = Shortcut.parse(shortcut)
        self.init(title, k, m, action, tag: tag, isAlternate: isAlternate, condition: condition)
    }

    /// The shortcut in menu notation, e.g. `⇧⌘K`. Order: ⌃⌥⇧⌘.
    public var shortcutText: String {
        guard !key.isEmpty else { return "" }
        return Shortcut.text(key: key, modifiers: modifiers)
    }

    /// The keystroke in one canonical spelling, for comparisons: shifted
    /// punctuation becomes ⇧ plus the unshifted key ("⌘{" → "⇧⌘["), so two
    /// spellings of one keystroke compare equal.
    public var canonicalShortcut: String {
        guard !key.isEmpty else { return "" }
        return Shortcut.canonical(key: key, modifiers: modifiers)
    }

    /// Whether Ycode performs this command (§1.1: the others are listed
    /// disabled).
    public var isAvailable: Bool { !action.hasPrefix("ycodeUnavailable") }
}

/// Characters AppKit uses for non-printing keys in key equivalents.
public enum Key {
    public static let up = "\u{F700}", down = "\u{F701}", left = "\u{F702}", right = "\u{F703}"
    public static let f6 = "\u{F709}", f7 = "\u{F70A}", f8 = "\u{F70B}"
    public static let `return` = "\r", space = " ", delete = "\u{8}", tab = "\t"
    /// F1…F12.
    public static func function(_ n: Int) -> String { String(UnicodeScalar(0xF703 + n)!) }
    static let names: [String: String] = {
        var n: [String: String] = [up: "↑", down: "↓", left: "←", right: "→", `return`: "↩", space: "Space", delete: "⌫", tab: "⇥"]
        for i in 1...12 { n[function(i)] = "F\(i)" }
        return n
    }()
    /// The unshifted key of each shifted character on a US keyboard
    /// (reference-ui-5.md §1.8: "⇧⌘[" and "⌘{" are one keystroke).
    public static let shiftedBase: [String: String] = [
        "{": "[", "}": "]", "<": ",", ">": ".", "?": "/", ":": ";", "|": "\\", "\"": "'", "~": "`", "_": "-", "+": "=",
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
    ]
}

/// Menu shortcut notation (⌃⌥⇧⌘, then the key).
public enum Shortcut {
    /// Parses "⌥⇧⌘W" into AppKit's key and modifiers. Letters become
    /// lowercase (⇧ stays a modifier); "↩", arrows, "Space", "⌫", "⇥" and
    /// "F1"…"F12" become AppKit's characters; other characters are kept
    /// (write "⌘{" for ⇧⌘[, as AppKit expects). Modifiers alone ("⌥")
    /// give an empty key (an alternate without a shortcut).
    public static func parse(_ s: String) -> (String, MenuCommand.Modifiers) {
        var mods: MenuCommand.Modifiers = []
        var rest = Substring(s)
        while let c = rest.first, let m = modifier(c) {
            mods.insert(m)
            rest = rest.dropFirst()
        }
        let r = String(rest)
        if r.isEmpty { return ("", mods) }
        if let (k, _) = Key.names.first(where: { $0.value == r }) { return (k, mods) }
        if r.count == 1, let ch = r.first, ch.isLetter { return (r.lowercased(), mods) }
        return (r, mods)
    }

    static func modifier(_ c: Character) -> MenuCommand.Modifiers? {
        switch c {
        case "⌃": .control
        case "⌥": .option
        case "⇧": .shift
        case "⌘": .command
        default: nil
        }
    }

    static func modifierText(_ m: MenuCommand.Modifiers) -> String {
        var s = ""
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        return s
    }

    public static func text(key: String, modifiers: MenuCommand.Modifiers) -> String {
        modifierText(modifiers) + (Key.names[key] ?? key.uppercased())
    }

    public static func canonical(key: String, modifiers: MenuCommand.Modifiers) -> String {
        var k = key, m = modifiers
        if let base = Key.shiftedBase[k] { k = base; m.insert(.shift) }
        if k.count == 1, let ch = k.first, ch.isLetter, ch.isUppercase { k = k.lowercased(); m.insert(.shift) }
        return text(key: k, modifiers: m)
    }

    /// The canonical form of a shortcut written in menu notation.
    public static func canonical(_ s: String) -> String {
        let (k, m) = parse(s)
        return k.isEmpty ? modifierText(m) : canonical(key: k, modifiers: m)
    }
}

/// When a conditional item is shown (reference-ui-5.md §1.5).
public enum MenuCondition: String, Sendable, Equatable {
    /// A source editor has focus (Navigate ▸ counterparts, line, placeholders, changes).
    case sourceEditorFocused
    /// The workspace's repository has a remote (Integrate ▸ Create Pull Request…).
    case repositoryHasRemote
    /// A debug session is running (Debug ▸ Debug Workflow ▸ Load Symbols…).
    case debugging
    /// The separate Close Window ⇧⌘W item: hidden while ⌘W itself reads
    /// Close Window (one editor tab; reference-ui-3.md §5.2).
    case separateCloseWindow
}

public enum MenuItemSpec: Equatable, Sendable {
    case command(MenuCommand)
    case separator
    case submenu(String, [MenuItemSpec])
    /// A section label: a disabled title heading a section (§1.4).
    case label(String)
}

/// The menu bar, in order. The application menu is first.
public enum CommandTable {
    public typealias M = MenuCommand.Modifiers

    /// Navigators in selector-bar order; ⌘1…⌘9 select them (reference-ui.md §2).
    public static let navigators = ["Project", "Source Control", "Bookmarks", "Find", "Issues", "Tests", "Debug", "Breakpoints", "Reports"]
    /// Inspectors for source files in tab order; ⌥⌘1… select them.
    public static let inspectors = ["File", "History", "Quick Help"]

    /// A command Ycode does not perform yet: listed (so the menus match
    /// the reference) with an action nothing implements, so AppKit shows
    /// it disabled. Each gets its own selector name. It keeps its
    /// reference shortcut so nothing else can take it (§1.1).
    static func unavailable(_ title: String) -> MenuItemSpec { u(title) }

    static func unavailableAction(_ title: String) -> String {
        "ycodeUnavailable\(title.filter { $0.isLetter || $0.isNumber }):"
    }

    // Builders, so the table reads like the spec.
    static func c(_ t: String, _ s: String = "", _ a: String, tag: Int = 0, when: MenuCondition? = nil) -> MenuItemSpec {
        .command(.init(t, shortcut: s, a, tag: tag, condition: when))
    }
    static func u(_ t: String, _ s: String = "", when: MenuCondition? = nil) -> MenuItemSpec {
        .command(.init(t, shortcut: s, unavailableAction(t), condition: when))
    }
    /// An alternate of the item above; `a` nil = not performed yet.
    static func alt(_ t: String, _ s: String, _ a: String? = nil, when: MenuCondition? = nil) -> MenuItemSpec {
        .command(.init(t, shortcut: s, a ?? unavailableAction(t), isAlternate: true, condition: when))
    }
    static let sep = MenuItemSpec.separator

    /// The menu bar, in reference-ui-5.md §2 order.
    public static let menus: [(String, [MenuItemSpec])] = [
        ("Ycode", appMenu),
        ("File", fileMenu),
        ("Edit", editMenu),
        ("View", viewMenu),
        ("Find", findMenu),
        ("Navigate", navigateMenu),
        ("Editor", EditorMenu.items),  // §2.7; see EditorMenu.swift
        ("Product", productMenu),
        ("Debug", debugMenu),
        ("Integrate", integrateMenu),
        ("Window", windowMenu),
        ("Help", helpMenu),
    ]

    /// §2.1. Services ▸ is the system's (an empty submenu AppKit fills).
    static var appMenu: [MenuItemSpec] {
        [
            c("About Ycode", "", "orderFrontStandardAboutPanel:"),
            u("Ycode Extensions…"),
            sep,
            c("Settings…", "⌘,", "showSettings:"),
            .submenu("Behaviors", [u("No Custom Behaviors"), sep, c("Edit Behaviors…", "", "showBehaviorsSettings:")]),
            sep,
            // The tools found in the developer directory go before the separator.
            .submenu("Open Developer Tool", [sep, c("More Developer Tools…", "", "openMoreDeveloperTools:")]),
            .submenu("Services", []),
            sep,
            c("Hide Ycode", "⌘H", "hide:"),
            c("Hide Others", "⌥⌘H", "hideOtherApplications:"),
            c("Show All", "", "unhideAllApplications:"),
            sep,
            c("Quit Ycode", "⌘Q", "terminate:"),
            alt("Quit and Keep Windows", "⌥⌘Q"),
        ]
    }

    /// §2.2.
    static var fileMenu: [MenuItemSpec] {
        [
            .submenu("New", [
                u("Conversation", "⌃⌘H"),
                alt("Conversation in New Tab", "⌃⌥⌘H"),
                alt("Conversation in Editor Pane", "⌃⌥⇧⌘H"),
                sep,
                c("Tab", "⌘T", "newTab:"),
                sep,
                c("Editor Pane On Right", "⌃⌘T", "splitEditor:"),
                c("Editor Pane Below", "⌃⌥⌘T", "splitEditorBelow:"),
                c("Window Tab", "", "newWindowForTab:"),
                c("Window", "⇧⌘T", "newWorkspaceWindow:"),
                sep,
                c("Empty File", "", "newEmptyFile:"),
                u("New File from Clipboard"),
                c("File from Template…", "⌘N", "newFile:"),
                u("Target…"),
                sep,
                c("Project…", "⇧⌘N", "newProject:"),
                alt("Choose Template…", "⌥⇧⌘N"),
                u("Workspace…", "⌃⌘N"),
                sep,
                u("Group"),
                u("Group without Folder"),
                u("Group from Selection"),
                u("Group from Selection without Folder"),
                c("Folder", "⌥⌘N", "newFolder:"),
                u("Folder from Selection"),
            ]),
            sep,
            u("Add Files…", "⌥⌘A"),
            c("Add Package Dependencies…", "", "addPackageDependencies:"),
            sep,
            c("Open…", "⌘O", "openDocument:"),
            // §3.2: filled from RecentProjects when opened (RecentProjectsMenuDelegate).
            .submenu("Open Recent", [c("Clear Menu", "", "clearRecentProjects:")]),
            c("Open Quickly…", "⇧⌘O", "openQuickly:"),
            sep,
            c("Close Tab, Editor Pane, Window Tab, or Window", "⌘W", "closeTab:"),
            alt("Close Other Tabs", "⌥⌘W", "closeOtherTabs:"),
            c("Close Document", "⌃⌘W", "closeDocument:"),
            c("Close Editor Pane", "⌃⇧⌘W", "closeEditor:"),
            alt("Close Other Editor Panes", "⌃⌥⇧⌘W"),
            c("Close Window", "⇧⌘W", "performClose:", when: .separateCloseWindow),
            alt("Close Other Window Tabs", "⌥⇧⌘W", "closeOtherWindowTabs:", when: .separateCloseWindow),
            c("Close Workspace", "⌃⌥⌘W", "closeWorkspace:"),
            sep,
            c("Duplicate Editor Tab", "", "duplicateEditorTab:"),
            c("Save", "⌘S", "saveDocument:"),
            u("Save All", "⌥⌘S"),
            u("Duplicate…", "⇧⌘S"),
            u("Save As…", "⌥⇧⌘S"),
            c("Revert to Saved…", "", "revertDocumentToSaved:"),
            u("Unlock…"),
            u("Export…"),
            sep,
            c("Show in Finder", "", "showInFinder:"),
            u("Open Terminal at Location"),
            c("Open in New Tab", "⌥⌘O", "openInNewTab:"),
            u("Open in New Window"),
            c("Open with External Editor", "", "openWithExternalEditor:"),
            sep,
            .submenu("Packages", [
                u("Reset Package Caches"),
                c("Resolve Package Versions", "", "resolvePackages:"),
                sep,
                u("Update to Latest Package Versions"),
            ]),
            sep,
            u("Save As Workspace…"),
            u("Workspace Settings…"),
            sep,
            c("Page Setup…", "", "runPageLayout:"),
            u("Print…", "⌘P"),
        ]
    }

    /// §2.3. AutoFill, Start Dictation… and Emoji & Symbols are the
    /// system's; AppKit adds them.
    static var editMenu: [MenuItemSpec] {
        [
            c("Undo", "⌘Z", "undo:"),
            c("Redo", "⇧⌘Z", "redo:"),
            sep,
            c("Cut", "⌘X", "cut:"),
            c("Copy", "⌘C", "copy:"),
            alt("Copy File and Line", "⌃⌥⌘C", "copyFileAndLine:"),
            alt("Copy Symbol Name", "⌃⇧⌘C", "copySymbolName:"),
            alt("Copy Qualified Symbol Name", "⌃⌥⇧⌘C", "copyQualifiedSymbolName:"),
            c("Paste", "⌘V", "paste:"),
            alt("Move Item Here", "⌥⌘V"),
            alt("Paste and Preserve Formatting", "⌥⇧⌘V"),
            c("Duplicate", "⌘D", "duplicateSelection:"),
            c("Delete", "⌘⌫", "delete:"),
            sep,
            c("Select All", "⌘A", "selectAll:"),
            sep,
            c("Bookmark Line", "⌃⌘'", "bookmarkLine:"),
            c("Bookmark Line With Dialog", "⌃⌥⌘'", "bookmarkLineWithDialog:"),
            c("Bookmark File", "⌃⌘\"", "bookmarkFile:"),
            c("Bookmark File With Dialog", "⌃⌥⌘\"", "bookmarkFileWithDialog:"),
            sep,
            .submenu("Sort", [u("By Name"), u("By Type")]),
            .submenu("Format", formatMenu),
            sep,
            .submenu("Convert", [u("To Group"), u("To Folder"), u("Preflight Conversion To Folder"), u("To String Catalogs…")]),
        ]
    }

    /// Edit ▸ Format: the standard macOS text Format menu (§2.3 item 10),
    /// with AppKit's standard text actions. Only Show Fonts and the two
    /// spelling items carry shortcuts, so ⌘B, ⌘I, ⌘U … stay with Build,
    /// Profile and Test.
    static var formatMenu: [MenuItemSpec] {
        [
            c("Show Fonts", "⌃⇧⌘T", "orderFrontFontPanel:"),
            c("Show Colors", "", "orderFrontColorPanel:"),
            .submenu("Font", [
                c("Bold", "", "addFontTrait:", tag: 2),
                c("Italic", "", "addFontTrait:", tag: 1),
                c("Underline", "", "underline:"),
                sep,
                c("Bigger", "", "modifyFont:", tag: 3),
                c("Smaller", "", "modifyFont:", tag: 4),
            ]),
            .submenu("Text", [
                c("Align Left", "", "alignLeft:"),
                c("Center", "", "alignCenter:"),
                c("Justify", "", "alignJustified:"),
                c("Align Right", "", "alignRight:"),
            ]),
            .submenu("Spelling and Grammar", [
                c("Show Spelling and Grammar", "⌘:", "showGuessPanel:"),
                c("Check Document Now", "⌘;", "checkSpelling:"),
                sep,
                c("Check Spelling While Typing", "", "toggleContinuousSpellChecking:"),
                c("Check Grammar With Spelling", "", "toggleGrammarChecking:"),
                c("Correct Spelling Automatically", "", "toggleAutomaticSpellingCorrection:"),
            ]),
            .submenu("Substitutions", [
                c("Show Substitutions", "", "orderFrontSubstitutionsPanel:"),
                sep,
                c("Smart Copy/Paste", "", "toggleSmartInsertDelete:"),
                c("Smart Quotes", "", "toggleAutomaticQuoteSubstitution:"),
                c("Smart Dashes", "", "toggleAutomaticDashSubstitution:"),
                c("Smart Links", "", "toggleAutomaticLinkDetection:"),
                c("Data Detectors", "", "toggleAutomaticDataDetection:"),
                c("Text Replacement", "", "toggleAutomaticTextReplacement:"),
            ]),
            .submenu("Transformations", [
                c("Make Upper Case", "", "uppercaseWord:"),
                c("Make Lower Case", "", "lowercaseWord:"),
                c("Capitalize", "", "capitalizeWord:"),
            ]),
            .submenu("Speech", [
                c("Start Speaking", "", "startSpeaking:"),
                c("Stop Speaking", "", "stopSpeaking:"),
            ]),
        ]
    }

    /// §2.4. View ▸ Editor holds the jump-bar keyboard menus (M4).
    static var viewMenu: [MenuItemSpec] {
        [
            .submenu("Editor", [
                u("Focus Editor Pane", "⌃⇧⌘↩"),
                sep,
                c("Show Related Items", "⌃1", "showRelatedItemsMenu:"),
                c("Show Previous History", "⌃2", "showPreviousHistoryMenu:"),
                c("Show Previous Files History", "⌃⌘2", "showPreviousFilesHistoryMenu:"),
                c("Show Next History", "⌃3", "showNextHistoryMenu:"),
                c("Show Next Files History", "⌃⌘3", "showNextFilesHistoryMenu:"),
                c("Show Top Level Items", "⌃4", "showTopLevelItemsMenu:"),
                c("Show Group Files", "⌃5", "showGroupFilesMenu:"),
                c("Show Document Items", "⌃6", "showDocumentItemsMenu:"),
            ]),
            sep,
            c("Show Editor Tab Bar", "", "toggleEditorTabBar:"),
            c("Pin Editor Tab", "⇧⌘P", "togglePinEditorTab:"),
            u("Change Editor Orientation"),
            u("Reset Editor Sizes"),
            u("Reset Assistant Selection", "⌥⇧⌘Z"),
            sep,
            c("Show Quick Actions…", "⇧⌘A", "showQuickActions:"),
            sep,
            .submenu("Navigators", navigators.enumerated().map { i, n in c(n, "⌘\(i + 1)", "showNavigator:", tag: i) } + [
                sep,
                c("Show Coding Assistant", "⌘0", "showCodingAssistant:"),
                c("Show Navigator", "", "toggleNavigator:"),
                c("Filter in Navigator", "⌥⌘J", "filterInNavigator:"),
            ]),
            .submenu("Debug Area", [
                c("Activate Console", "⇧⌘C", "activateConsole:"),
                sep,
                c("Show Debug Area", "⇧⌘Y", "toggleDebugArea:"),
            ]),
            // The focused editor's inspectors replace the first group at display.
            .submenu("Inspectors", inspectors.enumerated().map { i, n in c(n, "⌥⌘\(i + 1)", "showInspector:", tag: i) } + [
                sep,
                c("Show Inspector", "", "toggleInspector:"),
            ]),
            c("Show Library", "⇧⌘L", "showLibrary:"),
            u("Open Library", "⌥⇧⌘L"),
            u("Reload Organizer", "⌃R"),
            sep,
            c("Choose Theme…", "", "chooseTheme:"),
            sep,
            c("Show Toolbar", "⌥⌘T", "toggleToolbarShown:"),
            c("Customize Toolbar…", "", "runToolbarCustomizationPalette:"),
            c("Show Window Tab Bar", "", "toggleWindowTabBar:"),
            c("Show All Window Tabs", "⌘|", "showAllWindowTabs:"),
            sep,
            // Its own action: AppKit rebinds a toggleFullScreen: item to fn-F (§1.6).
            c("Enter Full Screen", "⌃⌘F", "toggleWorkspaceFullScreen:"),
        ]
    }

    /// §2.5. "Workspace" is the generic scope; `MenuTitles` names the
    /// container (Project, Workspace, Package).
    static var findMenu: [MenuItemSpec] {
        [
            c("Find in Workspace", "⇧⌘F", "findInWorkspace:"),
            u("Find and Replace in Workspace…", "⌥⇧⌘F"),
            u("Find Next in Workspace", "⌃⌘G"),
            u("Find Previous in Workspace", "⌃⇧⌘G"),
            sep,
            u("Find Selected Text in Workspace"),
            u("Find Selected Words in Workspace"),
            c("Find Selected Symbol in Workspace", "⌃⇧⌘F", "findSelectedSymbol:"),
            c("Find Call Hierarchy", "⌃⇧⌘H", "showCallHierarchy:"),
            u("Find Ancestor Types"),
            u("Find Descendent Types"),
            u("Find Conforming Types"),
            u("Find in Selected Groups…"),
            sep,
            c("Find…", "⌘F", "performFindPanelAction:", tag: 1),
            c("Find and Replace…", "⌥⌘F", "performFindPanelAction:", tag: 12),
            c("Find Next", "⌘G", "performFindPanelAction:", tag: 2),
            c("Find Previous", "⇧⌘G", "performFindPanelAction:", tag: 3),
            u("Find and Select Next", "⌥⌘G"),
            u("Find and Select Previous", "⌥⇧⌘G"),
            sep,
            c("Replace", "", "performFindPanelAction:", tag: 5),
            c("Replace All", "", "performFindPanelAction:", tag: 4),
            c("Replace and Find Next", "", "performFindPanelAction:", tag: 6),
            u("Replace and Find Previous"),
            sep,
            c("Use Selection for Find", "⌘E", "performFindPanelAction:", tag: 7),
            u("Use Selection for Replace", "⇧⌘E"),
            u("Select Next Occurrence", "⌥⌘E"),
            u("Select Previous Occurrence", "⌥⇧⌘E"),
            sep,
            c("Select All Find Matches", "", "performFindPanelAction:", tag: 9),
            c("Select Find Matches in Selection", "", "performFindPanelAction:", tag: 10),
            sep,
            c("Hide Find Bar", "", "hideFindBar:"),
        ]
    }

    /// §2.6.
    static var navigateMenu: [MenuItemSpec] {
        let src = MenuCondition.sourceEditorFocused
        return [
            c("Reveal in Project Navigator", "⇧⌘J", "revealInProjectNavigator:"),
            u("Reveal in Changes Navigator", "⇧⌘M"),
            u("Reveal in Debug Navigator", "⇧⌘D"),
            u("Open using Tab", "⌥⌘,"),
            alt("Open in Next Editor Pane", "⌥⌘<"),
            sep,
            u("Move Focus to Next Area", "⌥⌘`"),
            u("Move Focus to Previous Area", "⌥⌘~"),
            u("Move Focus to Next Editor Pane", "⌃`"),
            u("Move Focus to Previous Editor Pane", "⌃~"),
            u("Move Focus to Editor Pane…", "⌘J"),
            sep,
            c("Show Previous Tab", "⌘{", "showPreviousTab:"),
            c("Show Next Tab", "⌘}", "showNextTab:"),
            sep,
            c("Show Next Location in History", "⌃⌘→", "goForward:"),
            alt("Show Next Location in History using Tab", "⌃⌥⌘→"),
            alt("Show Next Location in History in Next Editor Pane", "⌃⌥⇧⌘→"),
            c("Show Previous Location in History", "⌃⌘←", "goBack:"),
            alt("Show Previous Location in History using Tab", "⌃⌥⌘←"),
            alt("Show Previous Location in History in Next Editor Pane", "⌃⌥⇧⌘←"),
            sep,
            u("Jump to Next Active Conversation", "⌃⌘K"),
            sep,
            c("Jump to Selection", "⌥⌘L", "jumpToSelection:"),
            c("Jump to Definition", "⌃⌘J", "jumpToDefinition:"),
            alt("Jump to Definition using Tab", "⌃⌥⌘J"),
            alt("Jump to Definition in Next Editor Pane", "⌃⌥⇧⌘J"),
            c("Jump to Original Source/Generated Interface", "", "jumpToOriginalSource:"),
            u("Jump to Last Destination"),
            sep,
            c("Jump to Next Issue", "⌘'", "jumpToNextIssue:"),
            c("Jump to Previous Issue", "⌘\"", "jumpToPreviousIssue:"),
            sep,
            c("Jump to Next Bookmark", "⌃;", "jumpToNextBookmark:"),
            c("Jump to Next Bookmark In Workspace", "⌃⌥;", "jumpToNextBookmarkInWorkspace:"),
            c("Jump to Previous Bookmark", "⌃:", "jumpToPreviousBookmark:"),
            c("Jump to Previous Bookmark In Workspace", "⌃⌥:", "jumpToPreviousBookmarkInWorkspace:"),
            sep,
            c("Jump to Program Counter", "⌃⌘P", "jumpToProgramCounter:"),
            sep,
            c("Jump to Next Counterpart", "⌃⌘↑", "jumpToNextCounterpart:", when: src),
            alt("Jump to Next Counterpart using Tab", "⌃⌥⌘↑", "jumpToNextCounterpartUsingTab:", when: src),
            alt("Jump to Next Counterpart in Next Editor Pane", "⌃⌥⇧⌘↑", "jumpToNextCounterpartInNextEditorPane:", when: src),
            c("Jump to Previous Counterpart", "⌃⌘↓", "jumpToPreviousCounterpart:", when: src),
            alt("Jump to Previous Counterpart using Tab", "⌃⌥⌘↓", "jumpToPreviousCounterpartUsingTab:", when: src),
            alt("Jump to Previous Counterpart in Next Editor Pane", "⌃⌥⇧⌘↓", "jumpToPreviousCounterpartInNextEditorPane:", when: src),
            c("Jump to Line…", "⌘L", "jumpToLine:", when: src),
            sep,
            c("Jump to Next Placeholder", "⌃/", "jumpToNextPlaceholder:", when: src),
            c("Jump to Previous Placeholder", "⌃?", "jumpToPreviousPlaceholder:", when: src),
            sep,
            c("Jump to Next Change", "⌃\\", "jumpToNextChange:", when: src),
            alt("Jump to Next Local or Upstream Change", "⌃⌥\\", "jumpToNextLocalOrUpstreamChange:", when: src),
            c("Jump to Previous Change", "⌃|", "jumpToPreviousChange:", when: src),
            alt("Jump to Previous Local or Upstream Change", "⌃⌥|", "jumpToPreviousLocalOrUpstreamChange:", when: src),
        ]
    }

    /// §2.9. Ycode has no profiler, so Profile and its variants stay
    /// listed but disabled; Build For ▸ Profiling builds with the Profile
    /// action's configuration.
    static var productMenu: [MenuItemSpec] {
        [
            c("Run", "⌘R", "runProduct:"),
            alt("Run…", "⌥⌘R", "runProductEditingScheme:"),
            c("Test", "⌘U", "testProduct:"),
            alt("Test…", "⌥⌘U", "testProductEditingScheme:"),
            c("Profile", "⌘I", "profileProduct:"),
            alt("Profile…", "⌥⌘I"),
            c("Analyze", "⇧⌘B", "analyzeProduct:"),
            alt("Analyze…", "⌥⇧⌘B", "analyzeProductEditingScheme:"),
            c("Archive", "", "archiveProduct:"),
            alt("Archive…", "⌥", "archiveProductEditingScheme:"),
            c("Stop", "⌘.", "stopProduct:"),
            sep,
            .submenu("Build For", [
                c("Running", "⇧⌘R", "buildForRunning:"),
                c("Testing", "⇧⌘U", "buildForTesting:"),
                c("Profiling", "⇧⌘I", "buildForProfiling:"),
            ]),
            .submenu("Perform Action", [
                c("Run Without Building", "⌃⌘R", "runWithoutBuilding:"),
                c("Test Without Building", "⌃⌘U", "testWithoutBuilding:"),
                u("Profile Without Building", "⌃⌘I"),
                sep,
                u("Build with Timing Summary"),
                u("Build and Export Test Products"),
                sep,
                c("Test", "⌃⌥⌘U", "testSelectedTests:"),
                c("Test Again", "⌃⌥⌘G", "testAgain:"),
                c("Test Without Building Again", "", "testWithoutBuildingAgain:"),
                u("Profile"),
                u("Profile Again"),
                sep,
                c("Compile File", "⌃⌘B", "compileFile:"),
                c("Analyze File", "⌃⇧⌘B", "analyzeFile:"),
                sep,
                c("Preprocess File", "", "preprocessFile:"),
                c("Assemble File", "", "assembleFile:"),
                sep,
                u("Generate Optimization Profile…"),
            ]),
            sep,
            c("Build", "⌘B", "buildProduct:"),
            c("Clean Build Folder…", "⇧⌘K", "cleanProduct:"),
            c("Clean Build Folder Immediately", "⌥⇧⌘K", "cleanProductImmediately:"),
            u("Delete Derived Data…"),
            c("Clear Test Results", "⌃⌥⌘K", "clearTestResults:"),
            c("Clear All Issues", "", "clearAllIssues:"),
            sep,
            u("Build Documentation", "⌃⇧⌘D"),
            sep,
            c("Show Build Folder in Finder", "", "showBuildFolderInFinder:"),
            c("Copy Build Folder Path", "", "copyBuildFolderPath:"),
            sep,
            u("Export Localizations…"),
            u("Import Localizations…"),
            sep,
            // reference-ui-2.md §7.8; the scheme rows follow, filled at display.
            .submenu("Scheme", [
                c("Choose Scheme", "⌃0", "chooseScheme:"),
                c("Select Next Scheme", "⌃⌘]", "selectNextScheme:"),
                c("Select Previous Scheme", "⌃⌘[", "selectPreviousScheme:"),
                sep,
                c("Edit Scheme…", "⌘<", "editScheme:"),
                u("New Scheme…"),
                c("Manage Schemes…", "", "manageSchemes:"),
            ]),
            // The device, simulator and generic rows follow their labels,
            // filled at display (§11.4; DynamicMenus.fillDestinations).
            .submenu("Destination", [
                c("Choose Destination", "⌃)", "chooseDestination:"),
                c("Select Next Destination", "⌃⌥⌘]", "selectNextDestination:"),
                c("Select Previous Destination", "⌃⌥⌘[", "selectPreviousDestination:"),
                sep,
                c("Show All Run Destinations", "", "showAllRunDestinations:"),
                sep,
                .label("Devices"),
                sep,
                .label("Simulators"),
                sep,
                .label("Build"),
                sep,
                .submenu("Incompatible", []),
                sep,
                c("Manage Devices…", "⇧⌘2", "showDevices:"),
            ]),
            // One row per test plan follows, filled at display.
            .submenu("Test Plan", [
                c("Select Next Test Plan", "", "selectNextTestPlan:"),
                c("Select Previous Test Plan", "", "selectPreviousTestPlan:"),
                sep,
                u("Edit Test Plan", "⌘>"),
                u("New Test Plan…"),
                u("Manage Test Plans…"),
            ]),
            sep,
            u("App Shortcuts Preview"),
        ]
    }

    /// §2.10. Commands Ycode's lldb-dap session supports work (§10.2); the
    /// others (follow program counter, library info, symbols, memory,
    /// interrupt, crash logs, GPU, view debugging, StoreKit) stay disabled.
    static var debugMenu: [MenuItemSpec] {
        let similar = ["Type", "Process", "PID", "Library", "Subsystem", "Category", "TID"]
        return [
            c("Pause", "⌃⌘Y", "pauseOrContinue:"),
            c("Continue To Current Line", "⌃⌘C", "continueToCurrentLine:"),
            c("Step Over", "F6", "stepOver:"),
            c("Step Over Instruction", "⌃F6", "stepOverInstruction:"),
            c("Step Over Thread", "⌃⇧F6", "stepOverThread:"),
            c("Step Into", "F7", "stepInto:"),
            c("Step Into Instruction", "⌃F7", "stepIntoInstruction:"),
            c("Step Into Thread", "⌃⇧F7", "stepIntoThread:"),
            c("Step Out", "F8", "stepOut:"),
            sep,
            u("Step Over and Follow Program Counter"),
            u("Step Into and Follow Program Counter"),
            u("Step Out and Follow Program Counter"),
            sep,
            c("Deactivate Breakpoints", "⌘Y", "toggleBreakpointsActive:"),
            .submenu("Breakpoints", [
                c("Create Breakpoint at Current Line", "⌘\\", "toggleBreakpointAtCurrentLine:"),
                c("Enable Breakpoints at Current Line", "", "toggleBreakpointsEnabledAtCurrentLine:"),
                c("Create Column Breakpoint", "", "createColumnBreakpoint:"),
                c("Delete Column Breakpoints at Current Line", "", "deleteColumnBreakpointsAtCurrentLine:"),
                c("Create Swift Error Breakpoint", "", "createSwiftErrorBreakpoint:"),
                c("Create Exception Breakpoint…", "", "createExceptionBreakpoint:"),
                c("Create Symbolic Breakpoint…", "⌥⌘\\", "createSymbolicBreakpoint:"),
                c("Create Test Failure Breakpoint", "", "createTestFailureBreakpoint:"),
                c("Delete All Breakpoints", "", "deleteAllBreakpoints:"),
            ]),
            sep,
            .submenu("Console", [
                c("Copy Row with Visible Metadata", "⌥⇧C", "copyConsoleRowWithVisibleMetadata:"),
                c("Copy Row with All Metadata", "", "copyConsoleRowWithAllMetadata:"),
                c("Copy Row without Metadata", "", "copyConsoleRowWithoutMetadata:"),
                sep,
                c("Jump To Source", "⌥⇧⌘J", "jumpToConsoleSource:"),
                sep,
                .submenu("Hide Similar Items", similar.map { u($0) }),
                .submenu("Show Similar Items", similar.map { u($0) }),
                sep,
                c("Clear Console", "⌘K", "clearConsole:"),
                c("Reload Console", "⌥⌘K", "reloadConsole:"),
                c("Select Last Output", "⌥⇧⌘A", "selectLastConsoleOutput:"),
            ]),
            .submenu("Debug Workflow", [
                c("Navigate to Source File when Process Pauses", "", "toggleNavigateToSourceOnPause:"),
                c("Synchronize Insertion Point to Program Counter", "", "toggleSynchronizeInsertionPoint:"),
                c("Always Show Disassembly", "", "toggleAlwaysShowDisassembly:"),
                u("Show Library Info…"),
                u("Load Symbols…", when: .debugging),
                u("View Memory", "⌃⌥⇧⌘M"),
                u("Interrupt Debugger Operation", "⌃C"),
            ]),
            sep,
            c("Attach to Process by PID or Name…", "", "attachToProcess:"),
            .submenu("Attach to Process", [u("Getting Process List…")]),
            c("Detach", "", "detachDebugger:"),
            c("Debug Executable…", "", "debugExecutable:"),
            u("Debug Crash Log…"),
            sep,
            u("Capture GPU Workload"),
            .submenu("Simulate Location", []),
            .submenu("Induce Device Conditions", []),
            .submenu("View Debugging", [
                // D4: disabled until the simulator can capture views.
                u("Capture View Hierarchy"),
                sep,
                u("Show View Frames"),
                u("Show Alignment Rectangles"),
                u("Show View Drawing"),
                u("Show Responsive Scrolling Status"),
                sep,
                c("Configure Environment Overrides…", "", "showEnvironmentOverrides:"),
                u("Disable All Environment Overrides"),
                sep,
                .submenu("Rendering", [
                    u("Color Blended Layers"), u("Color Hits Green and Misses Red"), u("Color Copied Images"),
                    u("Color Layer Formats"), u("Color Immediately"), u("Color Misaligned Images"),
                    u("Color Offscreen-Rendered Yellow"), u("Color Compositing Fast-Path Blue"), u("Flash Updated Regions"),
                ]),
                .submenu("Appearance", [
                    u("System Appearance"), sep, u("Light"), u("Dark"), u("High Contrast Light"), u("High Contrast Dark"),
                ]),
            ]),
            sep,
            .submenu("StoreKit", [
                u("Manage Transactions…"),
                sep,
                u("Approve Transaction"),
                u("Decline Transaction"),
                u("Refund Purchase"),
                u("Resolve Issue"),
                u("Request Price Increase Consent"),
                u("Edit Subscription"),
                sep,
                u("Delete Transaction"),
            ]),
            .submenu("GameKit", [u("Manage Game Progress…")]),
        ]
    }

    /// §2.11. Generic titles are the ones shown with no workspace; the
    /// enablement rules are `IntegrateMenuState`'s.
    static var integrateMenu: [MenuItemSpec] {
        [
            .label("Source Control"),
            c("Commit…", "⌥⌘C", "showCommitSheet:"),
            c("Push…", "", "scmPush:"),
            c("Pull…", "⌥⌘X", "scmPull:"),
            c("Fetch Changes", "", "scmFetch:"),
            c("Refresh File Status", "", "refreshFileStatus:"),
            sep,
            c("Stage All Changes", "", "scmStageAll:"),
            c("Stage Selected Files", "", "scmStageSelected:"),
            c("Unstage All Changes", "", "scmUnstageAll:"),
            c("Unstage Selected Files", "", "scmUnstageSelected:"),
            c("Mark as Resolved", "", "scmMarkResolved:"),
            sep,
            c("Add", "", "scmAddSelected:"),
            c("Cherry-Pick…", "", "scmCherryPick:"),
            c("Stash Changes…", "", "scmStash:"),
            sep,
            u("Create Pull Request…", when: .repositoryHasRemote),
            sep,
            c("Discard All Changes…", "", "scmDiscardAll:"),
            c("Discard Changes in Selected Files…", "", "scmDiscardSelected:"),
            sep,
            c("Clone…", "", "scmClone:"),
            c("New Git Repository…", "", "scmNewRepository:"),
            sep,
            // The reference's cloud CI section; Ycode has no such service.
            .label("Cloud"),
            u("Create Workflow…"),
            u("Manage Workflows…"),
        ]
    }

    /// §2.12. Minimize All, Zoom All, Fill and Center, the tiling
    /// submenus, Touch Bar, Arrange in Front and the window list are the
    /// system's; AppKit adds them.
    static var windowMenu: [MenuItemSpec] {
        [
            c("Minimize", "⌘M", "performMiniaturize:"),
            c("Zoom", "", "performZoom:"),
            sep,
            u("Rename Window Tab…", "⌥⇧⌘T"),
            c("Show Previous Window Tab", "⌃⇧⇥", "showPreviousWindowTab:"),
            c("Show Next Window Tab", "⌃⇥", "showNextWindowTab:"),
            c("Move Tab to New Window", "", "moveTabToNewWindow:"),
            c("Merge All Windows", "", "mergeAllWindows:"),
            sep,
            c("Developer Documentation", "⇧⌘0", "showDeveloperDocumentation:"),
            // §3.1 (AppDelegate.showWelcomeWindow).
            c("Welcome to Ycode", "⇧⌘1", "showWelcomeWindow:"),
            c("Downloads", "⇧⌘9", "showDownloads:"),
            c("Organizer", "⌥⇧⌘O", "showOrganizer:"),
            sep,
            c("Bring All to Front", "", "arrangeInFront:"),
        ]
    }

    /// §2.13.
    static var helpMenu: [MenuItemSpec] {
        [
            c("Developer Documentation", "⇧⌘0", "showDeveloperDocumentation:"),
            c("Human Interface Guidelines", "⇧⌘H", "showHumanInterfaceGuidelines:"),
            sep,
            u("Ycode Help"),
            u("What's New in Ycode"),
            u("Release Notes"),
            c("The Swift Programming Language", "", "showSwiftBook:"),
            u("Provide Feedback…"),
            sep,
            u("Show Keyboard Hints", "⌥⌘?"),
            c("Show Quick Help for Selected Item", "⌃⌘?", "showQuickHelpForSelection:"),
            c("Search Documentation for Selected Text", "⌃⌥⌘/", "searchDocumentationForSelection:"),
        ]
    }

    /// Every command, flattened, for shortcut lookups and conflict tests.
    public static var allCommands: [MenuCommand] { commands(in: menus.flatMap(\.1)) }

    public static func commands(in items: [MenuItemSpec]) -> [MenuCommand] {
        items.flatMap { item -> [MenuCommand] in
            switch item {
            case .command(let c): [c]
            case .separator, .label: []
            case .submenu(_, let sub): commands(in: sub)
            }
        }
    }

    public static func command(titled title: String) -> MenuCommand? {
        allCommands.first { $0.title == title }
    }

    /// The table's command for an action and tag (its generic title).
    public static func command(action: String, tag: Int = 0) -> MenuCommand? {
        byAction["\(action)#\(tag)"]
    }

    private static let byAction: [String: MenuCommand] = {
        var d: [String: MenuCommand] = [:]
        for c in allCommands where d["\(c.action)#\(c.tag)"] == nil { d["\(c.action)#\(c.tag)"] = c }
        return d
    }()
}

/// ⌘W with one editor tab (`specs/ide/reference-ui-3.md` §5.2): the File
/// menu's ⌘W item reads Close Window and the separate ⇧⌘W Close Window
/// item is hidden; with two or more tabs ⌘W is Close Tab.
public enum CloseShortcutRule {
    public static func commandWTitle(tabCount: Int) -> String { tabCount <= 1 ? "Close Window" : "Close Tab" }
    public static func showsSeparateCloseWindow(tabCount: Int) -> Bool { tabCount > 1 }
}
