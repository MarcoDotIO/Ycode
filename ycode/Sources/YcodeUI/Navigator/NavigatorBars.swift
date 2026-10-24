import AppKit

/// Each navigator's bottom bar, header and empty state
/// (`specs/ide/reference-ui-5.md` §5.2): the left pull-down button, the
/// in-field toggles with their titles, tooltips and defaults, and the
/// two-line empty state.
public struct NavigatorBarSpec: Equatable, Sendable {
    /// The pull-down at the bar's left end.
    public enum LeftButton: Equatable, Sendable {
        /// None: the filter takes the full width.
        case none
        /// "+", with its tooltip (nil: none observed).
        case add(String?)
        /// "…" (more).
        case more
        /// A pull-down whose contents are still to observe.
        case pullDown
    }

    /// An in-field toggle: its accessibility title, tooltip, glyph, the
    /// filter-options menu title, and whether it starts on.
    public struct Toggle: Equatable, Sendable {
        public var title: String
        public var toolTip: String
        public var symbol: String
        public var menuTitle: String
        public var defaultOn: Bool
        public init(_ title: String, _ toolTip: String, _ symbol: String, menu: String, on: Bool = false) {
            self.title = title
            self.toolTip = toolTip
            self.symbol = symbol
            self.menuTitle = menu
            self.defaultOn = on
        }
    }

    public var left: LeftButton
    public var toggles: [Toggle]
    /// The empty state's lines (none, one or two).
    public var emptyState: [String]
}

public enum NavigatorBars {
    /// The selector buttons' tooltips, exactly (§5.2).
    public static let selectorToolTips = [
        "Show the Project navigator", "Show the Source Control navigator", "Show the Bookmark navigator", "Show the Find navigator",
        "Show the Issue navigator", "Show the Test navigator", "Show the Debug Navigator", "Show the Breakpoints Navigator",
        "Show the Report navigator",
    ]

    public static let filterPlaceholder = "Filter"

    /// Per navigator, in selector order.
    public static let specs: [NavigatorBarSpec] = {
        typealias T = NavigatorBarSpec.Toggle
        return [
            // Project
            .init(left: .add(nil), toggles: [
                T("Recent files", "Show only recent files", "clock", menu: "Show Only Recent Files"),
                T("Files with source-control status", "Show only files with source-control status", "plusminus.circle",
                  menu: "Show Only Files with Source-Control Status"),
            ], emptyState: []),
            // Source Control: Ycode keeps its "No Repository".
            .init(left: .pullDown, toggles: [], emptyState: ["No Repository"]),
            // Bookmarks
            .init(left: .more, toggles: [
                T("Incomplete Items", "Show only incomplete items", "checklist", menu: "Show Only Incomplete Items"),
            ], emptyState: ["No Bookmarks", "Click the '…' button to add bookmarks"]),
            // Find: a plain filter, no empty state.
            .init(left: .none, toggles: [], emptyState: []),
            // Issues
            .init(left: .none, toggles: [
                T("Show only latest issues", "Show only issues from open documents and recently built sources", "clock",
                  menu: "Show Only Latest Issues"),
                T("Only errors", "Show only errors", "xmark.octagon", menu: "Show Only Errors"),
            ], emptyState: ["No Issues"]),
            // Tests
            .init(left: .add("Add a new test target or class"), toggles: [
                T("Show Only Included Tests", "Show Only Included Tests", "checkmark.circle", menu: "Show Only Included Tests"),
                T("Recent Tests", "Show only recent tests and open documents", "clock", menu: "Show Only Recent Tests"),
            ], emptyState: ["No Tests", "Click the \u{2295} button to add test targets"]),
            // Debug
            .init(left: .none, toggles: [
                T("Show compressed stack frames", "Show only stack frames with debug symbols and between libraries",
                  "arrow.down.right.and.arrow.up.left", menu: "Show Compressed Stack Frames", on: true),
                T("Show only interesting content", "Show only crashed threads and threads with debug symbols", "star.circle",
                  menu: "Show Only Interesting Content"),
                T("Show only running blocks", "Show only running blocks when in Queues view", "play.circle",
                  menu: "Show Only Running Blocks", on: true),
            ], emptyState: ["No Debug Session"]),
            // Breakpoints
            .init(left: .add("Create a breakpoint"), toggles: [
                T("Modified breakpoints", "Show only modified breakpoints", "slider.horizontal.3", menu: "Show Only Modified Breakpoints"),
                T("Enabled breakpoints", "Show only enabled breakpoints", "checkmark.circle", menu: "Show Only Enabled Breakpoints"),
            ], emptyState: ["No Breakpoints"]),
            // Reports
            .init(left: .pullDown, toggles: [
                T("Recent reports filter", "Show only recent reports", "clock", menu: "Show Only Recent Reports"),
            ], emptyState: ["No Logs"]),
        ]
    }()

    /// The Report navigator's Local | Cloud tooltips.
    public static let reportScopeToolTips = ["Show Local Reports", "Show Cloud Reports"]
    /// The Test navigator's Mode radio buttons.
    public static let testModes = ["Group by Test Hierarchy", "Group by Tags"]
    /// The group of tests without tags, last in Group by Tags.
    public static let untaggedTests = "Untagged Tests"
}

/// swift-testing tags of a test, read from its `@Test(… .tags(…) …)` and
/// its suite's `@Suite(… .tags(…) …)` attributes.
public enum TestTags {
    /// Tag names in `.tags(.a, .b, Tag.c)` inside `attribute` text.
    public static func names(inAttribute attribute: String) -> [String] {
        guard let r = attribute.range(of: ".tags(") else { return [] }
        var depth = 1
        var inside = ""
        for c in attribute[r.upperBound...] {
            if c == "(" { depth += 1 } else if c == ")" { depth -= 1; if depth == 0 { break } }
            inside.append(c)
        }
        return inside.split(separator: ",").compactMap { part in
            let t = part.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = t.split(separator: ".").last.map(String.init) ?? t
            return name.isEmpty || !name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) ? nil : name
        }
    }

    /// The attribute text right above a declaration line (1-based): the
    /// lines going up from it while they belong to attributes.
    static func attributes(above line: Int, in lines: [Substring]) -> String {
        guard line >= 1, line <= lines.count else { return "" }
        var out: [Substring] = [lines[line - 1]]
        var i = line - 2
        while i >= 0 {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("@") || t.hasPrefix(".") || t.hasPrefix(")") || t.hasSuffix(",") || t.hasSuffix("(") else { break }
            out.insert(lines[i], at: 0)
            i -= 1
        }
        return out.joined(separator: "\n")
    }

    /// The test's tags and its suite's, without duplicates, in order.
    public static func tags(of test: DiscoveredTest, text: String) -> [String] {
        guard test.kind == .swiftTesting else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var out: [String] = []
        for l in [test.suiteLine, test.line].compactMap({ $0 }) {
            for n in names(inAttribute: attributes(above: l, in: lines)) where !out.contains(n) { out.append(n) }
        }
        return out
    }
}

extension NavigatorAreaController {
    /// The Test navigator's header (reference-ui-5.md §5.2): the test-plan
    /// pop-up and the Mode radio buttons.
    func configureTestHeader() {
        testPlanPopUp.controlSize = .small
        testPlanPopUp.font = .systemFont(ofSize: 11)
        testPlanPopUp.isBordered = false
        testPlanPopUp.addItem(withTitle: testPlanName)
        testPlanPopUp.setAccessibilityLabel("Test Plan")
        testModeControl.controlSize = .small
        testModeControl.selectedSegment = 0
        testModeControl.setAccessibilityLabel("Mode")
        for (i, t) in NavigatorBars.testModes.enumerated() {
            testModeControl.setToolTip(t, forSegment: i)
            testModeControl.setLabel("", forSegment: i)
        }
        testModeControl.target = self
        testModeControl.action = #selector(testModeChosen)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        testPlanPopUp.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        for v in [testPlanPopUp, spacer, testModeControl] as [NSView] { testHeader.addArrangedSubview(v) }
        testHeader.orientation = .horizontal
        testHeader.spacing = 4
        testHeader.isHidden = true
    }

    @objc func testModeChosen() { groupTestsByTags = testModeControl.selectedSegment == 1 }

    /// Adds a glyph at a row's right end.
    func addTrailingGlyph(_ symbol: String, tint: NSColor?, to cell: NSView, label: NSView) {
        let v = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        v.contentTintColor = tint ?? .secondaryLabelColor
        v.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(v)
        NSLayoutConstraint.activate([
            v.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            v.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: v.leadingAnchor, constant: -4),
        ])
    }

    /// A bookmark row's context-menu items.
    public func bookmarkMenuItems(_ b: Bookmark) -> [NSMenuItem] {
        let done = b.done == true
        let item = NSMenuItem(title: done ? "Mark as Not Done" : "Mark as Done", action: #selector(bookmarkDoneChosen(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = BookmarkBox(b)
        return [item]
    }

    @objc func bookmarkDoneChosen(_ item: NSMenuItem) {
        guard let b = (item.representedObject as? BookmarkBox)?.bookmark else { return }
        onSetBookmarkDone?(b, b.done != true)
    }
}

/// A bookmark carried by a menu item.
final class BookmarkBox: NSObject {
    let bookmark: Bookmark
    init(_ b: Bookmark) { bookmark = b }
}
