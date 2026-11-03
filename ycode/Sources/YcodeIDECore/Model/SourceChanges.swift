import Foundation

/// One bar of the source editor's change gutter (`specs/ide/reference-ui-5.md`
/// §6.3): a run of added or modified lines, or a deletion between lines.
public struct SourceChangeRegion: Equatable, Sendable {
    public enum Kind: Sendable, Equatable { case added, modified, deleted }
    public var kind: Kind
    /// First line (1-based) of the region in the editor's text; for a
    /// deletion, the line the removed lines sat before.
    public var firstLine: Int
    /// Lines covered (0 for a deletion).
    public var lineCount: Int
    /// The change is in the index (HEAD differs from the index there, and
    /// the working text matches the index).
    public var staged: Bool

    public init(kind: Kind, firstLine: Int, lineCount: Int, staged: Bool) {
        self.kind = kind
        self.firstLine = firstLine
        self.lineCount = lineCount
        self.staged = staged
    }

    public var lastLine: Int { firstLine + max(lineCount, 1) - 1 }

    public func contains(line: Int) -> Bool { line >= firstLine && line <= lastLine }

    /// The bar's accessibility description (§6.3.3).
    public var accessibilityDescription: String {
        lastLine > firstLine ? "Local modification on lines \(firstLine) through \(lastLine)" : "Local modification on line \(firstLine)"
    }

    /// The change column's tooltip over this bar (§6.3.3).
    public var toolTip: String { staged ? "Staged change" : "Unstaged change" }
}

/// The change gutter's regions: the editor's text against the index
/// (unstaged) and the index against HEAD (staged), with the same line diff
/// Code Review uses (`LineDiff`, `CodeReviewModel.changes`).
public enum SourceChanges {
    /// `index` is the file's staged contents (nil when it is not in the
    /// index), `head` its committed contents (nil when not committed).
    /// A file in neither has no regions.
    public static func regions(text: String, index: String?, head: String?) -> [SourceChangeRegion] {
        guard index != nil || head != nil else { return [] }
        let new = LineDiff.lines(text)
        func changes(_ base: String) -> [ReviewChange] {
            CodeReviewModel.changes(LineDiff.sideBySide(LineDiff.diff(LineDiff.lines(base), new)))
        }
        func region(_ c: ReviewChange, staged: Bool) -> SourceChangeRegion {
            let kind: SourceChangeRegion.Kind = c.newCount == 0 ? .deleted : (c.kind == .added ? .added : .modified)
            return SourceChangeRegion(kind: kind, firstLine: max(1, c.newStart), lineCount: c.newCount, staged: staged)
        }
        let unstaged = changes(index ?? head ?? "").map { region($0, staged: false) }
        // Everything not committed; what the unstaged diff does not cover is staged.
        let uncommitted = index == nil || index == head ? [] : changes(head ?? "").map { region($0, staged: true) }
        let staged = uncommitted.filter { s in !unstaged.contains { overlaps($0, s) } }
        return (unstaged + staged).sorted { ($0.firstLine, $0.lineCount) < ($1.firstLine, $1.lineCount) }
    }

    static func overlaps(_ a: SourceChangeRegion, _ b: SourceChangeRegion) -> Bool {
        a.firstLine <= b.lastLine && b.firstLine <= a.lastLine
    }

    /// Navigate ▸ Jump to Next / Previous Change (§2.6): the region after
    /// (or before) `line`, wrapping.
    public static func step(from line: Int, in regions: [SourceChangeRegion], forward: Bool) -> SourceChangeRegion? {
        guard !regions.isEmpty else { return nil }
        if forward { return regions.first { $0.firstLine > line } ?? regions.first }
        return regions.last { $0.firstLine < line } ?? regions.last
    }
}
