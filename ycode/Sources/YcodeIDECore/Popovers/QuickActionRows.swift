import Foundation

// Quick Actions' results (⇧⌘A, P-086; `specs/ide/popovers.md` §5.1), one
// model for both IDEs: two-line 56-point rows with the command's glyph, its
// title (with the sub-menu path, the matched part semibold) and its parent
// menu path, the key equivalent at the right; the ranking; the metrics and
// colours both IDEs draw from.

/// One command Quick Actions can list.
public struct QuickActionEntry: Equatable, Sendable {
    /// The menus above the command, top first: ["Product", "Build For"].
    public var menuPath: [String]
    /// The command's own title: "Running".
    public var title: String
    /// Its key equivalent in menu notation ("⌘B"), empty for none.
    public var shortcut: String

    public init(menuPath: [String], title: String, shortcut: String = "") {
        self.menuPath = menuPath
        self.title = title
        self.shortcut = shortcut
    }

    /// The separator between the levels of a path (the spec's "〉", drawn
    /// as a single right-pointing angle quotation mark, which every Ycode
    /// font has).
    public static let pathSeparator = " › "

    /// Line 1: a command in a sub-menu shows the sub-menu's path below the
    /// top menu ("Build For › Running"); a top-level command its title.
    public var displayTitle: String { (Array(menuPath.dropFirst()) + [title]).joined(separator: Self.pathSeparator) }
    /// Line 2: the parent's menu path ("Product", "Product › Build For").
    public var subtitle: String { menuPath.joined(separator: Self.pathSeparator) }
    /// The glyph (`QuickActionGlyphs`).
    public var symbol: String { QuickActionGlyphs.symbol(title: title, menuPath: menuPath) }
}

/// The ranking (§5.1, "build"): titles that begin with the query first,
/// top-level commands before sub-menu ones (the reference listed Build and
/// Build Documentation before Build For › Running, whatever the menu's
/// own order), each in menu order; then sub-menu commands whose own title
/// begins with it; then (Ycode's, beyond what was recorded: OPEN) titles
/// with a word beginning with it, then titles containing it, in menu
/// order.
public enum QuickActionRanking {
    /// The entries matching `query`, best first (indices into `entries`,
    /// which are in menu order). Nothing for an empty query (the capsule
    /// is empty until something is typed, §5).
    public static func rank(_ entries: [QuickActionEntry], query: String) -> [Int] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var groups: [[Int]] = [[], [], [], []]
        for (i, e) in entries.enumerated() {
            let shown = e.displayTitle.lowercased(), own = e.title.lowercased()
            if shown.hasPrefix(q) { groups[0].append(i) }
            else if own.hasPrefix(q) { groups[1].append(i) }
            else if wordStarts(in: shown).contains(where: { shown[$0...].hasPrefix(q) }) { groups[2].append(i) }
            else if shown.contains(q) { groups[3].append(i) }
        }
        // Within the first group, shallower commands first (a stable sort).
        groups[0] = groups[0].enumerated().sorted {
            let a = entries[$0.element].menuPath.count, b = entries[$1.element].menuPath.count
            return a != b ? a < b : $0.offset < $1.offset
        }.map(\.element)
        return groups.flatMap { $0 }
    }

    /// The character ranges of `entry.displayTitle` drawn semibold for
    /// `query`: the matched text where it begins the title, the command's
    /// own title or a word, else where it first occurs.
    public static func matchedRanges(_ entry: QuickActionEntry, query: String) -> [Range<Int>] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = entry.displayTitle.lowercased()
        guard !q.isEmpty else { return [] }
        let n = q.count
        if shown.hasPrefix(q) { return [0..<n] }
        let ownStart = shown.count - entry.title.count
        if entry.title.lowercased().hasPrefix(q) { return [ownStart..<(ownStart + n)] }
        if let w = wordStarts(in: shown).first(where: { shown[$0...].hasPrefix(q) }) {
            let at = shown.distance(from: shown.startIndex, to: w)
            return [at..<(at + n)]
        }
        if let r = shown.range(of: q) {
            let at = shown.distance(from: shown.startIndex, to: r.lowerBound)
            return [at..<(at + n)]
        }
        return []
    }

    static func wordStarts(in s: String) -> [String.Index] {
        var out: [String.Index] = []
        var prev: Character?
        for i in s.indices {
            if let p = prev, !(p.isWhitespace || p == "›" || p == "(" || p == "-" || p == "/") { prev = s[i]; continue }
            if !s[i].isWhitespace { out.append(i) }
            prev = s[i]
        }
        return out
    }
}

/// The command's glyph (§5.1: a hammer for Build, a page for Build
/// Documentation, a play triangle for Build For › Running). Neutral
/// symbols that both IDEs draw (on macOS the system's, on Linux OpenViews'
/// own artwork), none depicting a product: by a word of the command's own
/// title first, then by its top menu.
public enum QuickActionGlyphs {
    /// Title words and their glyphs, in order of precedence.
    public static let byWord: [(String, String)] = [
        ("documentation", "doc.text"), ("running", "play"), ("run", "play"), ("testing", "checkmark.diamond"),
        ("test", "checkmark.diamond"), ("tests", "checkmark.diamond"), ("profiling", "gauge.with.dots.needle.33percent"),
        ("profile", "gauge.with.dots.needle.33percent"), ("timing", "timer"), ("analyze", "text.magnifyingglass"),
        ("archive", "archivebox"), ("clean", "trash"), ("stop", "stop"), ("build", "hammer"), ("delete", "trash"),
        ("close", "xmark"), ("find", "magnifyingglass"), ("search", "magnifyingglass"), ("replace", "magnifyingglass"),
        ("save", "square.and.arrow.down"), ("export", "square.and.arrow.up"), ("share", "square.and.arrow.up"),
        ("open", "folder"), ("new", "plus"), ("add", "plus"), ("duplicate", "plus.rectangle.on.rectangle"),
        ("copy", "rectangle.on.rectangle"), ("paste", "rectangle.on.rectangle"), ("library", "plus.rectangle.on.rectangle"),
        ("inspector", "sidebar.right"), ("inspectors", "sidebar.right"), ("navigator", "sidebar.left"), ("navigators", "sidebar.left"),
        ("debug", "rectangle.bottomthird.inset.filled"), ("console", "terminal"), ("terminal", "terminal"),
        ("assistant", "rectangle.split.2x1"), ("editor", "rectangle.split.2x1"), ("comment", "text.bubble"),
        ("breakpoint", "bookmark"), ("breakpoints", "bookmark"), ("bookmark", "bookmark"), ("commit", "arrow.triangle.branch"),
        ("branch", "arrow.triangle.branch"), ("pull", "arrow.down"), ("push", "arrow.up"), ("fetch", "arrow.clockwise"),
        ("refresh", "arrow.clockwise"), ("settings", "gearshape"), ("scheme", "gearshape.2"), ("destination", "desktopcomputer"),
        ("devices", "desktopcomputer"), ("simulator", "desktopcomputer"), ("window", "macwindow"), ("zoom", "plus.circle"),
        ("help", "questionmark.circle"), ("undo", "arrow.left"), ("redo", "arrow.right"), ("back", "chevron.left"),
        ("forward", "chevron.right"), ("jump", "arrow.turn.down.right"), ("reveal", "arrow.right.circle.fill"),
        ("quick", "info.circle"), ("package", "shippingbox"), ("packages", "shippingbox"), ("coloring", "chevron.left.forwardslash.chevron.right"),
    ]

    /// A top menu's glyph, for a command no word names.
    public static let byMenu: [String: String] = [
        "Ycode": "gearshape", "File": "doc", "Edit": "slider.horizontal.3", "View": "eye", "Find": "magnifyingglass",
        "Navigate": "arrow.turn.down.right", "Editor": "chevron.left.forwardslash.chevron.right", "Product": "shippingbox",
        "Debug": "point.3.connected.trianglepath.dotted", "Integrate": "arrow.triangle.branch", "Window": "macwindow",
        "Help": "questionmark.circle",
    ]

    public static func symbol(title: String, menuPath: [String]) -> String {
        let words = Set(title.lowercased().split { !$0.isLetter }.map(String.init))
        if let hit = byWord.first(where: { words.contains($0.0) }) { return hit.1 }
        return menuPath.first.flatMap { byMenu[$0] } ?? "square"
    }
}

/// The capsule's layout with results (§5.1), x from the panel's left edge,
/// y from its top; colours sRGB.
public enum QuickActionRowMetrics {
    /// The field row (the 55-point capsule) ends with a 1-pt hairline.
    public static let hairlineY = 55.0
    /// The first row's top: 10 below the hairline.
    public static let rowsTop = 66.0
    /// Two-line rows, touching.
    public static let rowHeight = 56.0
    /// The panel grows downward to at most this (the list scrolls inside).
    public static let maximumPanelHeight = 495.0
    /// Under the last row.
    public static let bottomPadding = 10.0
    /// The glyph: a 28-pt column centred 33 from the left, the symbol ≈ 24.
    public static let glyphCenterX = 33.0
    public static let glyphColumn = 28.0
    public static let glyphPointSize = 22.0
    /// The text column (aligned with the search field's text).
    public static let textX = 64.0
    public static let titleFontSize = 17.0
    public static let subtitleFontSize = 14.0
    /// Line centres below the row's top.
    public static let titleCenterY = 18.0
    public static let subtitleCenterY = 39.0
    /// The key equivalent ends this far left of the highlight's right edge.
    public static let keyFontSize = 14.0
    public static let keyRightInset = 30.0
    /// The selected row: inset 8 from the left, 21 from the right (the
    /// scroller's lane), radius 14, the row's full height.
    public static let highlightLeft = 8.0
    public static let highlightRight = 21.0
    public static let highlightRadius = 14.0

    /// The panel's height for `count` results.
    public static func panelHeight(count: Int, base: Double = InWindowPanel.quickActions.height) -> Double {
        guard count > 0 else { return base }
        return min(maximumPanelHeight, rowsTop + Double(count) * rowHeight + bottomPadding)
    }

    /// The scrolling list's height for `count` results.
    public static func listHeight(count: Int) -> Double {
        guard count > 0 else { return 0 }
        return panelHeight(count: count) - rowsTop - bottomPadding
    }

    /// The selected row's highlight in a list `width` wide (the panel's).
    public static func highlightFrame(row i: Int, width: Double) -> CGRect {
        CGRect(x: highlightLeft, y: Double(i) * rowHeight, width: width - highlightLeft - highlightRight, height: rowHeight)
    }

    // Colours (dark, council round 12; light is OPEN and follows the
    // system's label colours).
    public static func highlight(dark: Bool) -> UInt32 { dark ? 0x0059D1 : 0x0064E1 }
    /// The title's unmatched part.
    public static func title(dark: Bool) -> UInt32 { dark ? 0xD0D0D0 : 0x3C3C43 }
    /// The matched part (semibold).
    public static func match(dark: Bool) -> UInt32 { dark ? 0xFFFFFF : 0x000000 }
    public static func subtitle(dark: Bool) -> UInt32 { dark ? 0xB0B0B4 : 0x6E6E73 }
    public static func key(dark: Bool) -> UInt32 { dark ? 0xA8A8A8 : 0x6E6E73 }
    public static func glyph(dark: Bool) -> UInt32 { dark ? 0xD0D0D0 : 0x3C3C43 }
    /// The hairline under the field: lighter than the body.
    public static func hairline(dark: Bool) -> UInt32 { dark ? 0x5A5858 : 0xDCDCDC }
}
