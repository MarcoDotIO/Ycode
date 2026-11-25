import Foundation
import YcodeBuild
import YcodeIDECore

/// One visible row of a navigator outline, flattened: the shell draws the
/// rows itself so their metrics are the AppKit outline's
/// (`WorkspaceChrome`: 22-point rows, 14 points of indentation per level,
/// the disclosure triangle, a 16-point icon and the label 4 after it).
public struct OutlineRow: Identifiable, Equatable, Sendable {
    /// `icon`: the project navigator's colour families (`WorkspaceChrome.iconTint`).
    public enum Tint: Equatable, Sendable { case accent, secondary, error, warning, success, icon(WorkspaceChrome.IconTint) }

    public var id: String
    public var level: Int
    public var title: String
    /// Grey text after the title ("1 issue"), or under it (an issue's
    /// location).
    public var detail: String?
    public var symbol: String
    public var tint: Tint
    public var isBold = false
    /// Containers: a disclosure triangle.
    public var isExpandable = false
    public var isExpanded = false
    /// A Find match: the title split around the matched text.
    public var match: (before: String, match: String, after: String)?
    /// Lines the title may wrap onto (issues and matches: 2).
    public var lineLimit = 1
    public var isDimmed = false
    /// What selecting the row opens (files, matches, issues).
    public var opens = false
    /// A file with unsaved changes.
    public var isEdited = false
    /// A source-control status letter in a box at the row's right end
    /// ("M", "A", "?"; `specs/ide/source-control.md`).
    public var badge: String?
    /// Secondary text at the row's right end (a count).
    public var trailing: String?
    /// `detail` in secondary text (a branch after a repository's name).
    public var detailIsSecondary = false
    /// A symbol at the row's right end (a test's result diamond).
    public var trailingSymbol: String?
    public var trailingTint: Tint = .secondary
    /// A project row's logo or Ycode mark (nil: `symbol`; `NavigatorRowIcon`, row 192).
    public var icon: NavigatorRowIcon?
    /// While the navigator's filter has text: the title around the match
    /// (bold) and whether the row is drawn dimmed (a row kept for a
    /// matching descendant; `NavigatorFilterModel`, P-037).
    public var filterMatch: NavigatorFilterModel.Emphasis?
    public var isFilterContext = false

    /// A row as the keyboard and the filter see it (id, level, title,
    /// expansion), for outlines that draw rows of their own.
    public static func plain(id: String, level: Int, title: String, isExpandable: Bool = false, isExpanded: Bool = false) -> OutlineRow {
        OutlineRow(id: id, level: level, title: title, symbol: "", tint: .secondary, isExpandable: isExpandable, isExpanded: isExpanded)
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.level == b.level && a.title == b.title && a.detail == b.detail && a.symbol == b.symbol && a.tint == b.tint
            && a.isBold == b.isBold && a.isExpandable == b.isExpandable && a.isExpanded == b.isExpanded
            && a.match?.before == b.match?.before && a.match?.match == b.match?.match && a.match?.after == b.match?.after
            && a.lineLimit == b.lineLimit && a.isDimmed == b.isDimmed && a.opens == b.opens && a.isEdited == b.isEdited
            && a.badge == b.badge && a.trailing == b.trailing && a.detailIsSecondary == b.detailIsSecondary
            && a.trailingSymbol == b.trailingSymbol && a.trailingTint == b.trailingTint && a.icon == b.icon
            && a.filterMatch == b.filterMatch && a.isFilterContext == b.isFilterContext
    }
}

public enum OutlineRows {
    /// How long rows take to appear or go when a row expands or collapses
    /// (P-194, `Motion.outlineDuration`): Left ≈ 75 ms, Right and the
    /// triangle ≈ 175 ms.
    public static func toggleDuration(expanding: Bool, byKey: Bool) -> Double {
        Motion.outlineDuration(expand: expanding, byKey: byKey)
    }

    /// The Project navigator: the tree with `expanded` open; file names
    /// without their extension when `hideExtensions` (Settings ▸ General ▸
    /// File Extensions, as the AppKit navigator shows them).
    /// `badges`: source-control letters by file path.
    /// `filter`: while it is active (`NavigatorFilterModel.isActive`) only
    /// the files that pass it (and `keep`, the in-field toggles) are shown,
    /// with every group and folder on the way to them, open; groups whose
    /// name matches are shown too (P-037).
    public static func project(_ root: NavigatorItem, expanded: Set<String>, hideExtensions: Bool, edited: Set<String> = [],
                               badges: [String: String] = [:], filter: String = "",
                               keep: ((NavigatorItem) -> Bool)? = nil, sections: [NavigatorItem] = []) -> [OutlineRow] {
        var out: [OutlineRow] = []
        let filtering = NavigatorFilterModel.isActive(filter) || keep != nil
        func title(_ item: NavigatorItem) -> String {
            item.isFile ? WorkspaceChrome.jumpBarFileTitle(item.name, hideExtension: hideExtensions) : item.name
        }
        func passes(_ item: NavigatorItem) -> Bool {
            guard item.kind != .container else { return false }
            if item.isFile, let keep, !keep(item) { return false }
            return NavigatorFilterModel.matches(title(item), query: filter) && (item.isFile || keep == nil)
        }
        // Rows that pass, or lead to one that does.
        var shown: Set<String> = []
        @discardableResult
        func mark(_ item: NavigatorItem) -> Bool {
            var any = passes(item)
            for c in item.children ?? [] where mark(c) { any = true }
            if any { shown.insert(item.id) }
            return any
        }
        if filtering { mark(root); sections.forEach { mark($0) } }
        func walk(_ item: NavigatorItem, _ level: Int) {
            if filtering, !shown.contains(item.id), level > 0 { return }
            let open = filtering ? (item.children ?? []).contains { shown.contains($0.id) } : expanded.contains(item.id)
            let t = title(item)
            var row = OutlineRow(id: item.id, level: level, title: t, detail: nil,
                                 symbol: WorkspaceChrome.symbol(kind: item.kind, name: item.name, path: item.path),
                                 tint: .icon(WorkspaceChrome.iconTint(kind: item.kind, name: item.name)),
                                 isExpandable: item.children != nil, isExpanded: open, opens: item.isFile,
                                 isEdited: item.path.map(edited.contains) ?? false,
                                 badge: item.isFile ? item.path.flatMap { badges[$0] } : nil)
            row.icon = NavigatorRowIcon.of(kind: item.kind, name: item.name, path: item.path)
            if filtering, level > 0 {
                row.filterMatch = passes(item) ? NavigatorFilterModel.emphasis(t, query: filter) : nil
                row.isFilterContext = !passes(item)
            }
            out.append(row)
            if open { for c in item.children ?? [] { walk(c, level + 1) } }
        }
        walk(root, 0)
        // Sections after the project (Package Dependencies), drawn as roots.
        for section in sections where !filtering || shown.contains(section.id) {
            out.append(OutlineRow(id: section.id, level: 0, title: section.name, symbol: "shippingbox", tint: .secondary, isBold: false,
                                  isExpandable: true, isExpanded: filtering || expanded.contains(section.id)))
            if filtering || expanded.contains(section.id) { for c in section.children ?? [] { walk(c, 1) } }
        }
        return out
    }

    /// A navigator's rows through its filter (P-037): the rows whose title
    /// matches, and the rows above them (by level) they need; a matching
    /// row's title is split for the bold match, the others are dimmed.
    public static func filtered(_ rows: [OutlineRow], query: String) -> [OutlineRow] {
        guard NavigatorFilterModel.isActive(query) else { return rows }
        var keep = [Bool](repeating: false, count: rows.count)
        for (i, r) in rows.enumerated() where NavigatorFilterModel.matches(r.title, query: query) {
            keep[i] = true
            // The nearest row above on each shallower level.
            var level = r.level
            var j = i - 1
            while j >= 0, level > 0 {
                if rows[j].level < level { keep[j] = true; level = rows[j].level }
                j -= 1
            }
        }
        return rows.indices.filter { keep[$0] }.map { i in
            var r = rows[i]
            r.filterMatch = NavigatorFilterModel.emphasis(r.title, query: query)
            r.isFilterContext = r.filterMatch == nil
            return r
        }
    }

    /// Type-select (P-051): the row after `current` (from it, when the
    /// typed text is longer than one character) whose title starts with
    /// `prefix`, wrapping; nil when none does.
    public static func typeSelect(_ rows: [OutlineRow], current: String?, prefix: String) -> String? {
        let p = prefix.lowercased()
        guard !p.isEmpty, !rows.isEmpty else { return nil }
        let at = current.flatMap { c in rows.firstIndex { $0.id == c } }
        let start = at.map { p.count > 1 ? $0 : $0 + 1 } ?? 0
        for k in 0..<rows.count {
            let r = rows[(start + k) % rows.count]
            if r.title.lowercased().hasPrefix(p) { return r.id }
        }
        return nil
    }

    /// The Find navigator's results: "name (N)" per file, each match under it.
    public static func find(_ files: [FindFileRow], collapsed: Set<String>) -> [OutlineRow] {
        var out: [OutlineRow] = []
        for f in files {
            let open = !collapsed.contains(f.id)
            out.append(OutlineRow(id: f.id, level: 0, title: f.title, symbol: "doc.text", tint: .accent, isBold: true, isExpandable: true,
                                  isExpanded: open))
            guard open else { continue }
            for m in f.matches {
                out.append(OutlineRow(id: m.id, level: 1, title: m.before + m.match + m.after, symbol: "text.magnifyingglass",
                                      tint: .secondary, match: (m.before, m.match, m.after), lineLimit: 2, opens: true))
            }
        }
        return out
    }

    /// The Issue navigator: the project and targets ("Greeter  1 issue"),
    /// their files, then the issues.
    public static func issues(_ groups: [IssueGroupRow], collapsed: Set<String>) -> [OutlineRow] {
        var out: [OutlineRow] = []
        func issue(_ r: IssueRow, _ level: Int) -> OutlineRow {
            OutlineRow(id: r.id, level: level, title: r.message, detail: nil, symbol: r.symbolName,
                       tint: r.severity == .error ? .error : (r.severity == .warning ? .warning : .secondary),
                       // An issue with no file is the whole message: nothing to open and read it in.
                       lineLimit: r.file == nil ? 8 : 2, isDimmed: r.isStale, opens: true)
        }
        for g in groups {
            let open = !collapsed.contains(g.id)
            out.append(OutlineRow(id: g.id, level: 0, title: g.title, detail: g.countText, symbol: "app.dashed", tint: .accent,
                                  isBold: true, isExpandable: true, isExpanded: open))
            guard open else { continue }
            for f in g.files {
                let fo = !collapsed.contains(f.id)
                out.append(OutlineRow(id: f.id, level: 1, title: f.title, symbol: WorkspaceChrome.fileSymbol(String(f.id.split(separator: "|").last ?? "")), tint: .accent,
                                      isBold: true, isExpandable: true, isExpanded: fo))
                if fo { out += f.issues.map { issue($0, 2) } }
            }
            out += g.issues.map { issue($0, 1) }
        }
        return out
    }
}
