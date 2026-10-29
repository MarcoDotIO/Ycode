import Foundation

/// Code Review (comparison) mode data (`specs/ide/reference-ui-4.md` §15).
public enum ComparisonStyle: Sendable, Equatable { case inline, sideBySide }

/// One side of a comparison.
public enum ReviewSource: Equatable, Sendable {
    /// The working copy, including unsaved edits.
    case uncommittedChanges
    /// The index compared to the working copy.
    case unstagedChanges
    /// HEAD compared to the index.
    case stagedChanges
    /// HEAD.
    case lastCommit
    case commit(hash: String, title: String)
    case branch(String)

    public var title: String {
        switch self {
        case .uncommittedChanges: "Uncommitted Changes"
        case .unstagedChanges: "Unstaged Changes"
        case .stagedChanges: "Staged Changes"
        case .lastCommit: "Last Commit"
        case .commit(_, let t): t
        case .branch(let b): b
        }
    }

    /// The text of this source when it is the left-hand (newer) side.
    func leftContents(of path: String, in repo: GitRepository) -> String? {
        switch self {
        case .uncommittedChanges: try? String(contentsOfFile: path, encoding: .utf8)
        case .unstagedChanges: try? String(contentsOfFile: path, encoding: .utf8)
        case .stagedChanges: repo.contents(of: path, at: nil)
        case .lastCommit: repo.headContents(of: path)
        case .commit(let h, _): repo.contents(of: path, at: h)
        case .branch(let b): repo.contents(of: path, at: b)
        }
    }

    /// The text this source compares against the working copy (the
    /// "old" side): nil revision means the index.
    func baseline(of path: String, in repo: GitRepository) -> String? {
        switch self {
        case .uncommittedChanges, .lastCommit, .stagedChanges: repo.headContents(of: path)
        case .unstagedChanges: repo.contents(of: path, at: nil) ?? repo.headContents(of: path)
        case .commit(let h, _): repo.contents(of: path, at: h)
        case .branch(let b): repo.contents(of: path, at: b)
        }
    }
}

/// A run of changed rows: the lines of the working copy it covers (empty
/// for a pure deletion, which sits before `newStart`).
public struct ReviewChange: Equatable, Sendable {
    public var kind: LineDiff.Row.Kind
    /// First working-copy line (1-based) of the change, or the line the
    /// deletion sits before.
    public var newStart: Int
    public var newCount: Int
    public var oldStart: Int
    public var oldCount: Int
}

/// Code Review mode's change list and source picker
/// (`specs/ide/reference-ui-4.md` §15).
public enum CodeReviewModel {
    /// Groups consecutive non-`same` rows into changes.
    public static func changes(_ rows: [LineDiff.Row]) -> [ReviewChange] {
        var out: [ReviewChange] = []
        var nextNew = 1, nextOld = 1
        var open: ReviewChange?
        func close() { if let o = open { out.append(o) }; open = nil }
        for r in rows {
            if r.kind == .same {
                close()
                nextNew = (r.right?.number ?? nextNew) + 1
                nextOld = (r.left?.number ?? nextOld) + 1
                continue
            }
            if open == nil { open = ReviewChange(kind: r.kind, newStart: nextNew, newCount: 0, oldStart: nextOld, oldCount: 0) }
            if let rn = r.right?.number { open!.newCount += 1; nextNew = rn + 1 }
            if let ln = r.left?.number { open!.oldCount += 1; nextOld = ln + 1 }
            if open!.kind != r.kind { open!.kind = .changed }
        }
        close()
        return out
    }

    /// Per working-copy line: the kind of change (tints and gutter bars);
    /// deletions are keyed by the line they sit before, as `.removed`.
    public static func lineMarks(_ changes: [ReviewChange]) -> [Int: LineDiff.Row.Kind] {
        var m: [Int: LineDiff.Row.Kind] = [:]
        for c in changes {
            if c.newCount == 0 { m[c.newStart] = m[c.newStart] ?? .removed; continue }
            for l in c.newStart..<(c.newStart + c.newCount) { m[l] = c.kind == .removed ? .changed : c.kind }
        }
        return m
    }

    /// "1 change", "3 changes" (the stepper's label).
    public static func stepperTitle(_ count: Int) -> String { count == 1 ? "1 change" : "\(count) changes" }

    /// The change index after stepping from `current` (wraps).
    public static func step(from current: Int?, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let c = current else { return forward ? 0 : count - 1 }
        return ((c + (forward ? 1 : -1)) % count + count) % count
    }

    /// The source picker's two columns.
    public struct PickerColumns: Equatable {
        public var branches: [String]   // "Recents" first, then branches; current marked "(current)"
        public var commits: [String]    // fixed rows, then "author · date · hash · subject"
    }

    /// The source picker's two columns: "Recents" and recent branches, then
    /// all branches (the current one marked); then the fixed working-copy rows
    /// and one row per commit.
    public static func pickerColumns(branches: [GitRepository.Ref], recents: [String], commits: [GitRepository.CommitSummary]) -> PickerColumns {
        var b: [String] = []
        if !recents.isEmpty { b.append("Recents"); b += recents }
        b += branches.map { $0.isCurrent ? "\($0.name) (current)" : $0.name }
        let c = ["Uncommitted Changes", "Unstaged Changes", "Staged Changes"]
            + commits.map { "\($0.author) · \($0.date) · \($0.shortHash) · \($0.subject)" }
        return PickerColumns(branches: b, commits: c)
    }
}
