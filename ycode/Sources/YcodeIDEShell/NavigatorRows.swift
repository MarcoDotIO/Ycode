import Foundation
import YcodeBuild
import YcodeIDECore

/// Find navigator rows (`navigators.md` §Find navigator): one row per file,
/// "name (N)", with one child per match showing the trimmed line.
public struct FindFileRow: Identifiable, Equatable, Sendable {
    public var path: String
    public var matches: [FindMatchRow]
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    /// "name  (N)": two spaces, as the AppKit Find navigator writes it.
    public var title: String { "\(name)  (\(matches.count))" }
}

public struct FindMatchRow: Identifiable, Equatable, Sendable {
    public var path: String
    public var index: Int
    public var line: Int
    public var column: Int
    /// The trimmed line split around the match.
    public var before: String, match: String, after: String
    public var id: String { "\(path)#\(index)" }

    init(path: String, index: Int, _ m: WorkspaceSearch.Match) {
        self.path = path
        self.index = index
        line = m.line
        column = m.column
        let ns = m.text as NSString
        let h = NSIntersectionRange(m.highlight, NSRange(location: 0, length: ns.length))
        before = ns.substring(to: h.location)
        match = ns.substring(with: h)
        after = ns.substring(from: NSMaxRange(h))
    }

    static func rows(_ results: [WorkspaceSearch.FileResult]) -> [FindFileRow] {
        results.map { f in FindFileRow(path: f.path, matches: f.matches.enumerated().map { FindMatchRow(path: f.path, index: $0.offset, $0.element) }) }
    }
}

/// Issue navigator rows (`navigators.md` §Issue navigator, the core's
/// `IssueNavigatorModel.tree`): the project row and one row per target, then
/// files, then issues by line.
public struct IssueGroupRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var countText: String
    /// Issues with no file (the project row's own).
    public var issues: [IssueRow]
    public var files: [IssueFileRow]
}

public struct IssueFileRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var issues: [IssueRow]
}

public struct IssueRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var severity: Diagnostic.Severity
    public var message: String
    public var file: String?
    public var line: Int?
    public var column: Int?
    public var isStale: Bool

    public var symbolName: String { ShellSymbols.severity(severity) }
    /// "main.swift:12" for an issue with a location.
    public var locationText: String? {
        guard let f = file else { return nil }
        let name = (f as NSString).lastPathComponent
        return line.map { "\(name):\($0)" } ?? name
    }
}

public enum IssueRows {
    /// The navigator's rows for the session's issues, grouped as the core
    /// groups them. Row ids are unique within the tree.
    public static func tree(_ diagnostics: [Diagnostic], grouping: IssueGrouping, model: IssueNavigatorModel = IssueNavigatorModel()) -> [IssueGroupRow] {
        let entries = model.entries(fresh: diagnostics)
        var counter = 0
        func row(_ e: IssueNavigatorModel.Entry, _ scope: String) -> IssueRow {
            counter += 1
            let d = e.diagnostic
            return IssueRow(id: "\(scope)#\(counter)", severity: d.severity, message: d.message, file: d.location?.file,
                            line: d.location?.line, column: d.location.map { max(1, $0.column) }, isStale: e.isStale)
        }
        return IssueNavigatorModel.tree(entries, grouping: grouping).map { g in
            let gid = "\(g.kind == .project ? "project" : "target"):\(g.title)"
            return IssueGroupRow(id: gid, title: g.title, countText: g.countText, issues: g.entries.map { row($0, gid) },
                                 files: g.files.map { f in
                                     let fid = gid + "|" + f.file
                                     return IssueFileRow(id: fid, title: f.title, issues: f.entries.map { row($0, fid) })
                                 })
        }
    }

    /// Every issue in navigator order (⌘' and ⇧⌘' step through these).
    public static func flattened(_ groups: [IssueGroupRow]) -> [IssueRow] {
        groups.flatMap { g in g.files.flatMap(\.issues) + g.issues }
    }
}
