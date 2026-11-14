import Foundation
import YcodeBuild

/// An unresolved merge is an issue of the workspace (`workspace-window.md`
/// W7.2, council row 188): while git reports a file as conflicted (a
/// merge, rebase, cherry-pick, pull or stash apply that stopped), that file
/// has one error at its first conflict marker, so the toolbar's issue
/// capsule, the jump bars' stepper and the Issue navigator show it in the
/// same states, the merge sheet's time included. Ycode's own words.
public enum ConflictIssues {
    public static let message = "Unresolved merge conflict"

    /// One error per conflicted file (absolute paths), at the line of its
    /// first "<<<<<<<" marker (line 1 when the file has none).
    public static func diagnostics(conflicted paths: [String], read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> [Diagnostic] {
        paths.sorted().map { path in
            Diagnostic(severity: .error, message: message, location: .init(file: path, line: markerLine(read(path) ?? ""), column: 1))
        }
    }

    /// The 1-based line of the first conflict marker.
    static func markerLine(_ text: String) -> Int {
        var n = 1
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("<<<<<<<") { return n }
            n += 1
        }
        return 1
    }

    /// The conflicted files of a source-control snapshot, as absolute paths.
    public static func conflictedPaths(_ snapshot: SourceControlSnapshot) -> [String] {
        guard let root = snapshot.repository?.root else { return [] }
        return snapshot.changes.filter { $0.status == .conflicted }.map { root.appendingPathComponent($0.path).standardizedFileURL.path }
    }
}

extension WorkspaceSession {
    /// The source control read again: its conflicted files become issues
    /// (only a change notifies).
    public func noteConflicts(_ snapshot: SourceControlSnapshot) {
        let list = ConflictIssues.diagnostics(conflicted: ConflictIssues.conflictedPaths(snapshot))
        if list.map(\.description) != conflictIssues.map(\.description) { conflictIssues = list }
    }
}
