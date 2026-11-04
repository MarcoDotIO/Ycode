import Foundation
import YcodeBuild
import YcodeIDECore

/// One visible row of a navigator outline, flattened: the shell draws the
/// rows itself so their metrics are the AppKit outline's
/// (`WorkspaceChrome`: 22-point rows, 12 points of indentation per level,
/// the disclosure triangle, a 16-point icon and the label 4 after it).
public struct OutlineRow: Identifiable, Equatable, Sendable {
    public enum Tint: Equatable, Sendable { case accent, secondary, error, warning, success }

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

    public static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.level == b.level && a.title == b.title && a.detail == b.detail && a.symbol == b.symbol && a.tint == b.tint
            && a.isBold == b.isBold && a.isExpandable == b.isExpandable && a.isExpanded == b.isExpanded
            && a.match?.before == b.match?.before && a.match?.match == b.match?.match && a.match?.after == b.match?.after
            && a.lineLimit == b.lineLimit && a.isDimmed == b.isDimmed && a.opens == b.opens && a.isEdited == b.isEdited
            && a.badge == b.badge && a.trailing == b.trailing && a.detailIsSecondary == b.detailIsSecondary
            && a.trailingSymbol == b.trailingSymbol && a.trailingTint == b.trailingTint
    }
}

public enum OutlineRows {
    /// The Project navigator: the tree with `expanded` open; file names
    /// without their extension when `hideExtensions` (Settings ▸ General ▸
    /// File Extensions, as the AppKit navigator shows them).
    /// `badges`: source-control letters by file path.
    public static func project(_ root: NavigatorItem, expanded: Set<String>, hideExtensions: Bool, edited: Set<String> = [],
                               badges: [String: String] = [:]) -> [OutlineRow] {
        var out: [OutlineRow] = []
        func walk(_ item: NavigatorItem, _ level: Int) {
            let open = expanded.contains(item.id)
            let title = item.isFile ? WorkspaceChrome.jumpBarFileTitle(item.name, hideExtension: hideExtensions) : item.name
            out.append(OutlineRow(id: item.id, level: level, title: title, detail: nil,
                                  symbol: WorkspaceChrome.symbol(kind: item.kind, name: item.name, path: item.path), tint: .accent,
                                  isExpandable: item.children != nil, isExpanded: open, opens: item.isFile,
                                  isEdited: item.path.map(edited.contains) ?? false,
                                  badge: item.isFile ? item.path.flatMap { badges[$0] } : nil))
            if open { for c in item.children ?? [] { walk(c, level + 1) } }
        }
        walk(root, 0)
        return out
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
