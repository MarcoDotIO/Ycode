import Foundation

/// What the conflict editor shows and how its controls change it
/// (`specs/ide/comparison.md`, "Conflict editor"), without a user
/// interface: the conflicted files and the shown one, its `MergeDocument`,
/// the selected hunk, the pair of versions compared, hand editing, and
/// every title, count and enablement the views display. The AppKit
/// `ConflictEditorController` and the Linux IDE's conflict editor draw
/// this one state, so both behave the same; reading and writing git is
/// left to them (it runs off the main actor).
public struct ConflictEditorState: Equatable, Sendable {
    /// Which two of the three versions the comparison shows.
    public enum Pair: Int, CaseIterable, Sendable { case leftRight, baseLeft, baseRight }
    public static let pairTitles = ["Left \u{2194} Right", "Base \u{2194} Left", "Base \u{2194} Right"]
    public static let choiceTitles = ["Left", "Right", "Left + Right", "Right + Left", "Base", "Edit"]
    /// The choices of the choice control's segments before Edit.
    public static let segmentChoices: [MergeDocument.Choice] = [.ours, .theirs, .oursThenTheirs, .theirsThenOurs, .base]
    /// The choice control's Edit segment.
    public static let editSegment = 5

    /// A repository's conflicted files, or files compared (Compare Files)
    /// with or without a common ancestor.
    public enum Source: Equatable, Sendable {
        case repository
        case files(hasAncestor: Bool)
    }

    public let source: Source
    /// The conflicted files (repository); the shown one.
    public var files: [String] = []
    public var currentFile: String?
    public private(set) var document: MergeDocument?
    /// The selected hunk (an index into `document.hunks`).
    public private(set) var currentHunk: Int?
    public private(set) var pair: Pair = .leftRight
    /// The selected hunk's text is being written by hand.
    public private(set) var isEditing = false
    public var integration: GitRepository.IntegrationState = .none
    /// The last failed write (shown in place of the status).
    public var lastError: String?
    /// The merge sheet's other files, with the choices made in them while
    /// another file is shown (`ConflictEditorState+Sheet.swift`).
    public internal(set) var otherDocuments: [String: MergeDocument] = [:]
    /// The sheet's footers: the current side and the incoming side.
    public var leftFooter: MergeSheetFooter?
    public var rightFooter: MergeSheetFooter?

    public init(source: Source = .repository) {
        self.source = source
    }

    public var isComparingFiles: Bool { source != .repository }
    /// Whether there is a base version (Base, the pair control).
    public var hasBase: Bool { if case .files(let a) = source { a } else { true } }

    // MARK: Changes

    /// Shows a document: the first unresolved hunk is selected (else the
    /// first hunk).
    public mutating func load(_ doc: MergeDocument?) {
        document = doc
        isEditing = false
        currentHunk = doc.flatMap { $0.step(from: nil, forward: true, unresolvedOnly: true) ?? $0.step(from: nil, forward: true) }
        syncEditing()
    }

    /// Selects a hunk; a hand-written one opens in the editor.
    public mutating func selectHunk(_ h: Int?) {
        guard let doc = document, let h, doc.hunks.indices.contains(h) else { return }
        currentHunk = h
        syncEditing()
    }

    public mutating func nextHunk() { selectHunk(document?.step(from: currentHunk, forward: true)) }
    public mutating func previousHunk() { selectHunk(document?.step(from: currentHunk, forward: false)) }

    /// Applies a choice to the selected hunk. A decision other than Edit
    /// moves on to the next undecided conflict.
    public mutating func choose(_ choice: MergeDocument.Choice) {
        guard var doc = document, let h = currentHunk else { return }
        doc.choose(choice, hunk: h)
        document = doc
        if case .custom = choice { isEditing = true; return }
        isEditing = false
        if choice != .unresolved, let next = doc.step(from: h, forward: true, unresolvedOnly: true), next != h {
            selectHunk(next)
        }
    }

    /// The choice control's segment: one of `segmentChoices`, or Edit.
    public mutating func chooseSegment(_ i: Int) {
        if i == Self.editSegment { beginEditing(); return }
        if Self.segmentChoices.indices.contains(i) { choose(Self.segmentChoices[i]) }
    }

    /// Edit: the selected hunk becomes hand-written, starting from what it
    /// has (ours then theirs for an undecided conflict).
    public mutating func beginEditing() {
        guard let doc = document, let h = currentHunk else { return }
        let c = doc.chunks[doc.hunks[h]]
        let start: [String] = switch doc.choices[h] {
        case .unresolved: c.ours + c.theirs
        case .custom(let l): l
        default: doc.lines(forHunk: h)
        }
        choose(.custom(start))
    }

    /// Replaces the selected hunk's hand-written text.
    public mutating func setEditedText(_ text: String) {
        guard isEditing, var doc = document, let h = currentHunk else { return }
        doc.choose(.custom(LineDiff.lines(text)), hunk: h)
        document = doc
    }

    /// The selected hunk's hand-written text, for the editor.
    public var editedText: String {
        guard let doc = document, let h = currentHunk, case .custom(let l) = doc.choices[h] else { return "" }
        return l.isEmpty ? "" : l.joined(separator: "\n") + "\n"
    }

    private mutating func syncEditing() {
        guard let doc = document, let h = currentHunk else { isEditing = false; return }
        if case .custom = doc.choices[h] { isEditing = true } else { isEditing = false }
    }

    public mutating func setPair(_ p: Pair) { pair = hasBase ? p : .leftRight }

    // MARK: Snapshot

    /// What follows a new read of git.
    public enum Follow: Equatable, Sendable {
        /// The shown file is still conflicted (or none was shown).
        case keep
        /// The shown file was resolved elsewhere: show this one (nil: none left).
        case show(String?)
    }

    /// The window's latest read of git.
    public mutating func update(integration: GitRepository.IntegrationState, conflicted: [String]) -> Follow {
        self.integration = integration
        guard conflicted != files else { return .keep }
        files = conflicted
        otherDocuments = otherDocuments.filter { conflicted.contains($0.key) }
        if let f = currentFile, !conflicted.contains(f) { return .show(conflicted.first) }
        return .keep
    }

    /// Which file to show after the list is read: the wanted one while it
    /// is conflicted, else the first.
    public static func target(wanted: String?, in files: [String]) -> String? {
        wanted.flatMap { w in files.contains(w) ? w : nil } ?? files.first
    }

    // MARK: What the views show

    /// "Conflicts in <file>", or "No Conflicts" (repository).
    public var title: String {
        currentFile.map { "Conflicts in \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "No Conflicts"
    }

    /// The conflicted files' names, for the file pop-up.
    public var fileNames: [String] { files.map { URL(fileURLWithPath: $0).lastPathComponent } }

    /// "2 conflicts unresolved", "Resolved", "All conflicts resolved", or the
    /// last error.
    public var statusText: String {
        if let lastError { return lastError }
        guard let doc = document else { return source == .repository && files.isEmpty ? "All conflicts resolved" : "" }
        let n = doc.unresolvedCount
        if n == 0 { return doc.hunks.isEmpty ? "No differences" : "Resolved" }
        return "\(n) conflict\(n == 1 ? "" : "s") unresolved"
    }

    /// Mark as Resolved: a file is shown and nothing is undecided.
    public var canMarkResolved: Bool {
        guard source == .repository, currentFile != nil, let doc = document else { return false }
        return doc.isResolved
    }

    /// "Change 2 of 5 (conflict)", "Difference 1 of 3" (two files).
    public var hunkLabel: String {
        let total = document?.hunks.count ?? 0
        let noun = isComparingFiles && !hasBase ? "Difference" : "Change"
        if let doc = document, let h = currentHunk, total > 0 {
            return "\(noun) \(h + 1) of \(total)" + (doc.chunks[doc.hunks[h]].kind == .conflict ? " (conflict)" : "")
        }
        return total == 0 ? "No \(noun.lowercased())s" : "\(total) \(noun.lowercased())\(total == 1 ? "" : "s")"
    }

    public var hasHunks: Bool { !(document?.hunks.isEmpty ?? true) }

    /// Whether the selected hunk conflicts.
    public var currentIsConflict: Bool {
        guard let doc = document, let h = currentHunk else { return false }
        return doc.chunks[doc.hunks[h]].kind == .conflict
    }

    /// The choice control's selected segment (nil while undecided).
    public var selectedSegment: Int? {
        guard let doc = document, let h = currentHunk else { return nil }
        switch doc.choices[h] {
        case .ours: return 0
        case .theirs: return 1
        case .oursThenTheirs: return 2
        case .theirsThenOurs: return 3
        case .base: return 4
        case .custom: return Self.editSegment
        case .unresolved: return nil
        }
    }

    /// Whether a choice segment applies (Base needs an ancestor).
    public func isSegmentEnabled(_ i: Int) -> Bool { currentHunk != nil && (i != 4 || hasBase) }

    /// Continue and Abort show while an operation is stopped (repository).
    public var showsIntegrationButtons: Bool { source == .repository && integration.isInProgress }
    /// Continue applies once no file is conflicted.
    public var canContinue: Bool { showsIntegrationButtons && files.isEmpty }
    public var continueTitle: String { integration.verb.isEmpty ? "Continue" : "Continue \(integration.verb)" }
    public var abortTitle: String { integration.verb.isEmpty ? "Abort" : "Abort \(integration.verb)" }

    /// The two versions compared, older on the left, with their titles.
    public var comparison: (old: String, new: String, oldTitle: String, newTitle: String) {
        guard let doc = document else { return ("", "", "", "") }
        return switch pair {
        case .leftRight: (doc.oursText, doc.theirsText, "Left: " + doc.oursLabel, "Right: " + doc.theirsLabel)
        case .baseLeft: (doc.baseText, doc.oursText, "Base: " + doc.baseLabel, "Left: " + doc.oursLabel)
        case .baseRight: (doc.baseText, doc.theirsText, "Base: " + doc.baseLabel, "Right: " + doc.theirsLabel)
        }
    }

    /// The comparison's rows (`LineDiff.sideBySide`).
    public var comparisonRows: [LineDiff.Row] {
        let c = comparison
        return LineDiff.sideBySide(LineDiff.diff(LineDiff.lines(c.old), LineDiff.lines(c.new)))
    }

    /// The comparison row where the selected hunk starts (scrolling).
    public func comparisonRow(in rows: [LineDiff.Row]) -> Int? {
        guard let doc = document, let h = currentHunk else { return nil }
        let starts = doc.sideStarts(forHunk: h)
        let leftStart = pair == .leftRight ? starts.ours : starts.base
        return rows.firstIndex { ($0.left?.number ?? 0) > leftStart } ?? 0
    }

    /// One line of the result and the hunk it belongs to.
    public struct ResultLine: Equatable, Sendable {
        public enum Tint: Equatable, Sendable { case none, unresolved, resolved }
        public var text: String
        public var hunk: Int?
        public var tint: Tint
        public var isSelected: Bool
    }

    /// The result's lines, each hunk's tinted (red undecided, green
    /// decided; the selected one darker).
    public var resultLines: [ResultLine] {
        guard let doc = document else { return [] }
        let (lines, ranges) = doc.layout()
        var hunkOf: [Int: Int] = [:]
        for (h, r) in ranges.enumerated() { for l in r { hunkOf[l] = h } }
        return lines.enumerated().map { i, text in
            guard let h = hunkOf[i] else { return ResultLine(text: text, hunk: nil, tint: .none, isSelected: false) }
            return ResultLine(text: text, hunk: h, tint: doc.choices[h] == .unresolved ? .unresolved : .resolved, isSelected: h == currentHunk)
        }
    }

    /// The first result line of the selected hunk (scrolling).
    public var resultStartLine: Int? {
        guard let doc = document, let h = currentHunk else { return nil }
        let ranges = doc.layout().hunkRanges
        return ranges.indices.contains(h) ? ranges[h].lowerBound : nil
    }
}
