import Foundation

/// The navigators' bottom-bar filter (P-037, `navigators.md` §Filter):
/// what both IDEs share. Rows filter shortly after the last key; a row's
/// matched part is drawn in bold and the rest dimmed; with no row left the
/// navigator shows "No Filter Results" and the inspector "No Selection";
/// while text is in the field the options glyph is drawn in the accent
/// colour; the options menu holds the recent filters and Clear Recents.
public enum NavigatorFilterModel {
    /// The pause after the last key before the rows filter. The reference
    /// shows filtered rows ≈ 70 ms after the last key (P-037); one or two
    /// display frames of redraw follow the pause.
    public static let settleDelay = 0.05
    /// The empty state when the filter leaves no row.
    public static let noResults = "No Filter Results"
    /// The inspector's placeholder while the filter leaves no row.
    public static let inspectorNoResults = "No Selection"
    /// The options menu's last item.
    public static let clearRecents = "Clear Recents"
    /// How many recent filters a navigator keeps.
    public static let recentLimit = 10
    /// The opacity of a filtered row's unmatched text (the matched part is
    /// bold at full opacity).
    public static let unmatchedOpacity = 0.55

    /// A title split around its first case-insensitive match of the query.
    public struct Emphasis: Equatable, Sendable {
        public var before: String
        public var match: String
        public var after: String
        public init(before: String, match: String, after: String) {
            self.before = before
            self.match = match
            self.after = after
        }
    }

    /// The query as rows are matched against it: trimmed of white space
    /// at both ends.
    public static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a title passes the filter (an empty query passes every row).
    public static func matches(_ title: String, query: String) -> Bool {
        let q = normalized(query)
        return q.isEmpty || title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// The title split around the query's first match; nil when the query
    /// is empty or the title has no match (a group kept for its children).
    public static func emphasis(_ title: String, query: String) -> Emphasis? {
        let q = normalized(query)
        guard !q.isEmpty, let r = title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        return Emphasis(before: String(title[..<r.lowerBound]), match: String(title[r]), after: String(title[r.upperBound...]))
    }

    /// Whether the options glyph shows the filter as active (accent colour
    /// with its chevron).
    public static func isActive(_ text: String) -> Bool { !normalized(text).isEmpty }

    /// The empty state's lines: "No Filter Results" when the filter left
    /// no row of a navigator that had some; else the navigator's own
    /// (`NavigatorBars.specs`), when it has no rows at all.
    public static func emptyState(navigator index: Int, filterText: String, hadRows: Bool, shownRows: Int) -> [String] {
        guard shownRows == 0 else { return [] }
        if hadRows, isActive(filterText) { return [noResults] }
        guard NavigatorBars.specs.indices.contains(index) else { return [] }
        return NavigatorBars.specs[index].emptyState
    }

    /// One entry of the filter options menu.
    public enum MenuEntry: Equatable, Sendable {
        /// A recent filter: choosing it puts it back in the field.
        case recent(String)
        case separator
        /// Clear Recents (disabled when there are none).
        case clearRecents(enabled: Bool)
    }

    /// The options menu of a navigator with these recent filters: the
    /// filters (newest first), a separator and Clear Recents.
    public static func menu(recents: [String]) -> [MenuEntry] {
        var out: [MenuEntry] = []
        if !recents.isEmpty {
            out += recents.map(MenuEntry.recent)
            out.append(.separator)
        }
        out.append(.clearRecents(enabled: !recents.isEmpty))
        return out
    }
}

/// The recent filters of each navigator, newest first.
public struct NavigatorFilterRecents: Equatable, Codable, Sendable {
    public private(set) var byNavigator: [Int: [String]] = [:]

    public init() {}

    public func recents(_ navigator: Int) -> [String] { byNavigator[navigator] ?? [] }

    /// Notes a filter that settled (the field ended editing or the
    /// navigator was left with text in it): it moves to the front.
    public mutating func note(_ text: String, navigator: Int) {
        let t = NavigatorFilterModel.normalized(text)
        guard !t.isEmpty else { return }
        var list = recents(navigator)
        list.removeAll { $0.caseInsensitiveCompare(t) == .orderedSame }
        list.insert(t, at: 0)
        byNavigator[navigator] = Array(list.prefix(NavigatorFilterModel.recentLimit))
    }

    public mutating func clear(_ navigator: Int) { byNavigator[navigator] = nil }
}
