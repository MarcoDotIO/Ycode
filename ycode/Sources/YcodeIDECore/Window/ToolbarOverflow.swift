import Foundation

/// The workspace toolbar in a narrow window (P-025; `liquid-glass.md` §8.2,
/// `editor-area.md` G.4, council rows 34, 107 and 218): which items stay the
/// longest, and what the "»" overflow menu shows for each item that left.
/// Both IDEs read it: the AppKit toolbar sets each item's visibility
/// priority from `rank(_:)` and its menu form from `entry(_:)`; the Linux
/// shell takes the items out in `leavingOrder` and draws the same menu.
///
/// The reference at about 817 points keeps Navigators, Run | Stop,
/// Back | Forward and the title area, and has moved New Conversation, the
/// scheme, the destination, the issues, Add Editor, Editor Options and the
/// editor modes into "»", a menu with glyphs and sub-menus. At its minimum
/// width (503, with the navigator hidden) Navigators and Run | Stop are back
/// and the title is the item that went. Council round 12 adds the
/// navigator-hidden states and the content-section model (§2.3): each right
/// item enters "»" below a fixed width of the content section. So the title area outranks the
/// right group, and Navigators and Run | Stop outrank the title. At 700 the
/// reference's navigator shrinks and Navigators and Run | Stop leave with
/// its section; that follows the navigator's width (P-024), not the ranks.
public enum ToolbarOverflow {
    /// The toolbar's items, by their toolbar identifiers, in toolbar order.
    public enum Item: String, CaseIterable, Sendable {
        case leftPanes, run, history, activity, newConversation, scheme, issues, addEditor, editorOptions, editorModes, inspectorToggle
    }

    /// How long an item stays as the room shrinks: higher stays longer.
    /// The values are AppKit's visibility priorities (low −1000, standard
    /// 0, high 1000, user 2000), so the AppKit toolbar uses them as they
    /// are. Show Inspector and Back | Forward never leave. Run | Stop,
    /// Navigators and the title area rank above the toolbar's fixed spaces
    /// (high), so the spaces between the right group's capsules go before
    /// them and never before a capsule they separate. Below 850 points the
    /// reference's Navigators (800) and Run | Stop (725) leave with the
    /// navigator they track and the title last (625); with the navigator
    /// hidden in a live resize the leading items come back and the title
    /// goes (`window-layout.md` §4 rule 2), so they outrank the title here.
    /// The right group is about standard; the editor modes go first (low;
    /// `ToolbarFit`).
    public static func rank(_ item: Item) -> Int {
        switch item {
        case .inspectorToggle: 2000
        // Run | Stop and Navigators never enter "»" with the navigator
        // hidden (`window-layout.md` §5.1); Back | Forward does, at the
        // minimum (§2.3: 500 → 450 pt), after the title.
        case .run: 1400
        case .leftPanes: 1350
        case .history: 1300
        case .activity: 1200
        // The right group from its right end leftward, as the reference
        // moves it into "»" (b5-obs 2026-11-20: Editor Options 1075, Add
        // Editor 1050, Issues 1000, the scheme capsule 950, New
        // Conversation 875).
        case .newConversation: 50
        case .scheme: 40
        case .issues: 30
        case .addEditor: 20
        case .editorOptions: 10
        case .editorModes: -1000
        }
    }

    // MARK: The content section (council round 12, `window-layout.md` §2.3)

    /// The toolbar's leading section: the navigator's column when it is
    /// shown, ≈ 255 points (to the end of Run | Stop) when it is hidden.
    public static func leadingSection(navigator: Double?) -> Double { navigator ?? 255 }
    /// The trailing section: the inspector's column when it is shown, ≈ 50
    /// (the inspector toggle) when it is hidden.
    public static func trailingSection(inspector: Double?) -> Double { inspector ?? 50 }

    /// The content section: the window less both sections.
    public static func contentWidth(window: Double, navigator: Double?, inspector: Double?) -> Double {
        window - leadingSection(navigator: navigator) - trailingSection(inspector: inspector)
    }

    /// The content width below which each item is in "»" (§2.3's model,
    /// which fits b5-obs's both-shown thresholds and both of round 12's
    /// states to 25 points): the editor modes (» appears) ≈ 600, Editor
    /// Options ≈ 525–560 (540), Add Editor ≈ 500 (505), Issues ≈ 450 (455),
    /// the scheme capsule ≈ 400 (405), New Conversation ≈ 310–325 (318).
    /// The middle of each measured range; the title, Back | Forward and the
    /// leading items follow the room, not this table.
    public static let contentThresholds: [(item: Item, below: Double)] = [
        (.editorModes, 600), (.editorOptions, 540), (.addEditor, 505), (.issues, 455), (.scheme, 405), (.newConversation, 318),
    ]

    /// The items in "»" for a content section `content` points wide, by the
    /// model (an IDE may move more when its items do not fit).
    public static func forcedOut(content: Double) -> [Item] {
        contentThresholds.filter { content < $0.below }.map(\.item)
    }

    /// The order items leave in: lowest rank first (and, for equal ranks,
    /// from the trailing end), as the AppKit toolbar takes them
    /// (`Beta5ToolbarTests.itemsLeaveInTheSharedOrder`). Show Inspector is
    /// not in it.
    public static let leavingOrder: [Item] = Item.allCases.filter { $0 != .inspectorToggle }
        .enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            return ra != rb ? ra < rb : a.offset > b.offset
        }
        .map(\.element)

    /// The items out of the toolbar once `count` items have left.
    public static func leaving(_ count: Int) -> [Item] { Array(leavingOrder.prefix(max(0, count))) }

    /// One entry of the "»" menu: its title, its glyph (the item's symbol
    /// in the toolbar, as a system symbol on macOS and OpenViews' own
    /// artwork of the same name on Linux), and whether it opens a sub-menu
    /// (the item's own menu or its segments).
    public struct Entry: Equatable, Sendable {
        public var title: String
        public var symbol: String
        public var hasSubmenu: Bool
    }

    /// The menu entry of an item that left the toolbar. The scheme's entry
    /// holds the schemes and, after them, the run destinations: one
    /// toolbar item has one entry in the AppKit menu, and the scheme
    /// capsule is one item. An empty symbol means the IDE draws the
    /// item's own picture (Ycode's mark for the title area) or none (the
    /// scheme, as the reference's Scheme and Destination entries); the
    /// issues entry takes the most severe kind's symbol and lists each
    /// kind's count.
    public static func entry(_ item: Item) -> Entry {
        switch item {
        case .leftPanes: Entry(title: "Navigators", symbol: WorkspaceChrome.leftPanes.symbols[0], hasSubmenu: true)
        case .run: Entry(title: "Run", symbol: WorkspaceChrome.runStop.symbols[0], hasSubmenu: true)
        case .history: Entry(title: "Back/Forward", symbol: WorkspaceChrome.history.symbols[0], hasSubmenu: true)
        // Disabled in the menu, as the reference's (`window-layout.md` §2.1).
        case .activity: Entry(title: "Window Title/Activity", symbol: "", hasSubmenu: false)
        case .newConversation: Entry(title: "New Conversation", symbol: WorkspaceChrome.newConversation.symbols[0], hasSubmenu: false)
        case .scheme: Entry(title: "Scheme", symbol: "", hasSubmenu: true)
        case .issues: Entry(title: "Issues", symbol: "exclamationmark.triangle", hasSubmenu: true)
        case .addEditor: Entry(title: "Add Editor", symbol: WorkspaceChrome.addEditor.symbols[0], hasSubmenu: true)
        case .editorOptions: Entry(title: "Editor Options", symbol: WorkspaceChrome.editorOptions.symbols[0], hasSubmenu: true)
        case .editorModes: Entry(title: "Editor Mode", symbol: WorkspaceChrome.editorModes.symbols[0], hasSubmenu: true)
        case .inspectorToggle: Entry(title: "Inspector", symbol: WorkspaceChrome.inspectorToggle.symbols[0], hasSubmenu: false)
        }
    }

    /// The sub-menu of a segmented item: one row per segment, with its
    /// glyph (Navigators | Coding Assistant, Back | Forward, the editor
    /// modes).
    public static func segments(_ item: Item) -> [(title: String, symbol: String)] {
        func rows(_ titles: [String], _ t: WorkspaceChrome.ToolbarItem) -> [(title: String, symbol: String)] {
            zip(titles, t.symbols).map { ($0, $1) }
        }
        switch item {
        case .leftPanes: return rows(["Navigators", "Coding Assistant"], WorkspaceChrome.leftPanes)
        case .history: return rows(["Go Back", "Go Forward"], WorkspaceChrome.history)
        case .editorModes: return rows(["Canvas", "Assistant", "Code Review"], WorkspaceChrome.editorModes)
        default: return []
        }
    }

    /// A row of the Issues entry: the kind's count ("1 Error", "2 Warnings",
    /// "3 Test Failures").
    public static func issueRow(_ kind: IssueSummary.Kind, count: Int) -> String {
        let one = count == 1
        switch kind {
        case .error: return "\(count) " + (one ? "Error" : "Errors")
        case .warning: return "\(count) " + (one ? "Warning" : "Warnings")
        case .testFailure: return "\(count) " + (one ? "Test Failure" : "Test Failures")
        }
    }

    /// The scheme entry's second section, after the schemes.
    public static let destinationsHeading = "Run Destination"
}

/// The Run button's press-and-hold menu (P-028): holding the mouse on Run
/// shows Run, Test, Profile and Analyze, the Product menu's actions with
/// the scheme editor's action glyphs; a click runs at once. Both IDEs show
/// the same rows. The rows carry no key equivalents: the Product menu
/// owns ⌘R, ⌘U, ⌘I and ⇧⌘B.
public enum RunButtonMenu {
    public struct Row: Equatable, Sendable {
        public var title: String
        /// The action's selector (the Product menu's).
        public var selector: String
        public var symbol: String
    }

    public static let rows: [Row] = [
        Row(title: "Run", selector: "runProduct:", symbol: "play"),
        Row(title: "Test", selector: "testProduct:", symbol: "checkmark.diamond"),
        Row(title: "Profile", selector: "profileProduct:", symbol: "gauge.with.dots.needle.33percent"),
        Row(title: "Analyze", selector: "analyzeProduct:", symbol: "magnifyingglass"),
    ]

    /// How long the mouse is held on Run before the menu shows: the
    /// reference's menu appears about 374 ms after the mouse goes down
    /// (its pressed tint at about 37 ms). A motion constant: B5-MOTION's
    /// shared timing table takes it over.
    public static let holdDelay = Motion.runMenuHoldDelay   // B5-MOTION's shared constant
}
