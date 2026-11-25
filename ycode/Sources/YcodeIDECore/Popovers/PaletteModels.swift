import Foundation

/// A palette's result list (Quick Actions, Quick New Project): the
/// matches of the query, best first, and the highlighted one. Quick
/// Actions lists nothing until something is typed (`popovers.md` §5: an
/// empty list that grows with results); Quick New Project lists all its
/// rows (P-180).
public struct PaletteList<Item: Sendable>: Sendable {
    public private(set) var all: [Item]
    public private(set) var shown: [Item]
    public private(set) var query = ""
    public var selected = 0
    let title: @Sendable (Item) -> String
    let emptyQueryShowsAll: Bool
    /// The matches' indices for a query, best first (nil: fuzzy by title).
    let rank: (@Sendable ([Item], String) -> [Int])?

    public init(_ items: [Item], emptyQueryShowsAll: Bool, rank: (@Sendable ([Item], String) -> [Int])? = nil,
                title: @escaping @Sendable (Item) -> String) {
        all = items
        self.title = title
        self.emptyQueryShowsAll = emptyQueryShowsAll
        self.rank = rank
        shown = emptyQueryShowsAll ? items : []
    }

    /// Fuzzy matches by title, best first; ties keep list order.
    public mutating func setQuery(_ q: String) {
        query = q
        let t = q.trimmingCharacters(in: .whitespaces)
        if t.isEmpty {
            shown = emptyQueryShowsAll ? all : []
        } else if let rank {
            shown = rank(all, t).map { all[$0] }
        } else {
            shown = all.enumerated()
                .compactMap { i, a in FuzzyMatch.score(t, title(a)).map { (i, a, $0) } }
                .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
                .map(\.1)
        }
        selected = 0
    }

    /// Down +1, Up -1, stopping at the ends.
    public mutating func move(_ delta: Int) {
        guard !shown.isEmpty else { return }
        selected = min(max(selected + delta, 0), shown.count - 1)
    }

    public var current: Item? { shown.indices.contains(selected) ? shown[selected] : nil }
}

/// Quick New Project (⌘⇧N with a workspace open, P-180; `popovers.md`
/// §10): an Open-Quickly-style panel, 640 × 355, a + glyph and a search
/// field over the compact picker's rows, each with its glyph and subtitle.
public enum QuickNewProject {
    public static let panel = InWindowPanel.quickNewProject
    /// The panel with all five rows.
    public static let height = 355.0
    public static let rowHeight = 56.0
    public static let rowInset = 10.0
    public static let rowCornerRadius = 12.0
    /// The rows' glyphs (neutral shapes), in `NewProjectPicker.rows` order.
    public static let symbols = ["app.dashed", "terminal", "shippingbox", "play.rectangle", "square.grid.2x2"]
    public static let headerSymbol = "plus"

    public struct Row: Equatable, Sendable {
        /// The row's index in `NewProjectPicker.rows` (what choosing it does).
        public var index: Int
        public var title: String
        public var subtitle: String
        public var symbol: String
    }

    public static var rows: [Row] {
        NewProjectPicker.rows.enumerated().map { i, r in
            Row(index: i, title: r.title, subtitle: r.subtitle, symbol: symbols.indices.contains(i) ? symbols[i] : "doc")
        }
    }

    public static func list() -> PaletteList<Row> { PaletteList(rows, emptyQueryShowsAll: true) { $0.title } }

    /// The panel's height for `count` rows.
    public static func height(rows count: Int) -> Double {
        panel.height + (count == 0 ? 0 : rowInset * 2 + Double(count) * rowHeight)
    }
}

/// Jump to Line's field (⌘L, P-086): a line number, or line:column; what
/// it accepts.
public enum JumpToLineInput {
    /// The 1-based line in a file of `lineCount` lines (clamped), nil when
    /// the text is not a number.
    public static func line(_ text: String, lineCount: Int) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces)
        let head = t.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? t
        guard let n = Int(head) else { return nil }
        return min(max(n, 1), max(lineCount, 1))
    }
}
