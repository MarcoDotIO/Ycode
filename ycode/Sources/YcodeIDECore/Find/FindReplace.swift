import Foundation

/// Replace mode of the Find navigator: which matches are replaced (per
/// match and per file), the preview of each, and Replace All. See
/// `specs/ide/navigators.md` §Find navigator, "Ycode implementation".
public struct ReplacePlan: Equatable, Sendable {
    public struct File: Equatable, Sendable {
        public var path: String
        public var matches: [WorkspaceSearch.Match]
        /// One flag per match: replaced or left alone.
        public var included: [Bool]
        public var isIncluded: Bool { included.contains(true) }
        public var includedCount: Int { included.filter { $0 }.count }
    }

    public var query: FindQuery
    public var replacement: String
    public var files: [File]

    /// Every match starts included.
    public init(query: FindQuery, replacement: String, results: [WorkspaceSearch.FileResult]) {
        self.query = query
        self.replacement = replacement
        files = results.map { File(path: $0.path, matches: $0.matches, included: Array(repeating: true, count: $0.matches.count)) }
    }

    /// Includes or leaves out one match, or (`match` nil) all of a file's.
    public mutating func setIncluded(_ on: Bool, file: Int, match: Int? = nil) {
        guard files.indices.contains(file) else { return }
        if let m = match {
            guard files[file].included.indices.contains(m) else { return }
            files[file].included[m] = on
        } else {
            files[file].included = Array(repeating: on, count: files[file].matches.count)
        }
    }

    public var includedCount: Int { files.reduce(0) { $0 + $1.includedCount } }
    public var includedFileCount: Int { files.filter(\.isIncluded).count }

    /// The text that replaces a match: the replacement as typed, or for a
    /// regular expression the template with `$0`…`$9` (and `\` escapes)
    /// expanded from the match's groups.
    public func replacementText(for m: WorkspaceSearch.Match, in text: String) -> String {
        guard query.kind == .regularExpression, let regex = query.matcher()?.expression else { return replacement }
        let ns = text as NSString
        guard NSMaxRange(m.range) <= ns.length,
              let r = regex.firstMatch(in: text, options: [.anchored, .withTransparentBounds],
                                       range: NSRange(location: m.range.location, length: ns.length - m.range.location)),
              r.range == m.range else { return replacement }
        return regex.replacementString(for: r, in: text, offset: 0, template: replacement)
    }

    /// The match's line before and after replacing that match alone.
    public func preview(file: Int, match: Int, text: String) -> (before: String, after: String) {
        let m = files[file].matches[match]
        let ns = text as NSString
        let index = LineIndex(text)
        guard NSMaxRange(m.range) <= ns.length, let first = index.range(ofLine: m.line) else { return (m.text, m.text) }
        let lastLine = index.line(at: max(m.range.location, NSMaxRange(m.range) - 1))
        let last = index.range(ofLine: lastLine) ?? first
        let span = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let before = ns.substring(with: span)
        let local = NSRange(location: m.range.location - span.location, length: m.range.length)
        let after = (before as NSString).replacingCharacters(in: local, with: replacementText(for: m, in: text))
        return (before.trimmingCharacters(in: .whitespacesAndNewlines), after.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// One file's new text. Matches whose text is no longer at their range
    /// (the file changed since the search) are left alone and counted as
    /// stale; overlapping matches keep the first.
    public func newText(file: Int, text: String) -> (text: String, replaced: Int, stale: Int) {
        let f = files[file]
        let ns = text as NSString
        var picked: [(NSRange, String)] = []
        var stale = 0
        var end = 0
        for (i, m) in f.matches.enumerated() where f.included[i] {
            guard NSMaxRange(m.range) <= ns.length, m.matchedText.isEmpty || ns.substring(with: m.range) == m.matchedText else { stale += 1; continue }
            guard m.range.location >= end else { continue }
            picked.append((m.range, replacementText(for: m, in: text)))
            end = NSMaxRange(m.range)
        }
        let out = NSMutableString(string: text)
        for (r, s) in picked.reversed() { out.replaceCharacters(in: r, with: s) }
        return (out as String, picked.count, stale)
    }

    /// Replace All: every included match of every file, through `io`.
    /// Returns the transaction to record for undo.
    public func apply(_ io: ReplaceIO) -> ReplaceTransaction {
        var t = ReplaceTransaction(title: "Replace \(includedCount) Occurrence\(includedCount == 1 ? "" : "s")")
        for (i, f) in files.enumerated() where f.isIncluded {
            guard let old = io.read(f.path) else { t.failed.append(f.path); continue }
            let (new, n, stale) = newText(file: i, text: old)
            if stale > 0 { t.stale.append(f.path) }
            guard n > 0, new != old else { continue }
            if io.write(f.path, new) {
                t.changes.append(ReplaceChange(path: f.path, oldText: old, newText: new, count: n))
            } else {
                t.failed.append(f.path)
            }
        }
        return t
    }
}

/// How Replace reads and writes a file: an open editor's text (an
/// unsaved buffer included) or the file on disk.
public struct ReplaceIO {
    public var read: (String) -> String?
    public var write: (String, String) -> Bool
    public init(read: @escaping (String) -> String?, write: @escaping (String, String) -> Bool) {
        self.read = read
        self.write = write
    }

    /// Files on disk only (UTF-8).
    public static var disk: ReplaceIO {
        ReplaceIO(read: { try? String(contentsOfFile: $0, encoding: .utf8) },
                  write: { path, text in (try? text.write(toFile: path, atomically: true, encoding: .utf8)) != nil })
    }
}

public struct ReplaceChange: Equatable, Sendable {
    public var path: String
    public var oldText: String
    public var newText: String
    public var count: Int
}

/// One Replace All: the files it changed, and those it could not.
public struct ReplaceTransaction: Equatable, Sendable {
    public var title: String
    public var changes: [ReplaceChange] = []
    /// Files with matches that were no longer there.
    public var stale: [String] = []
    /// Files that could not be read or written.
    public var failed: [String] = []
    public var replacedCount: Int { changes.reduce(0) { $0 + $1.count } }
    public init(title: String) { self.title = title }
}

/// Undo and redo of Replace All across files: one step restores every
/// file of the transaction. A file edited since is left alone (a
/// conflict) so no later work is lost.
public final class ReplaceHistory {
    public struct Outcome: Equatable, Sendable {
        public var restored: [String] = []
        public var conflicts: [String] = []
    }

    public private(set) var undoStack: [ReplaceTransaction] = []
    public private(set) var redoStack: [ReplaceTransaction] = []
    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func record(_ t: ReplaceTransaction) {
        guard !t.changes.isEmpty else { return }
        undoStack.append(t)
        redoStack.removeAll()
    }

    /// Restores the text before the last Replace All.
    @discardableResult
    public func undo(_ io: ReplaceIO) -> Outcome {
        guard let t = undoStack.popLast() else { return Outcome() }
        redoStack.append(t)
        return Self.restore(t, io, toOriginal: true)
    }

    /// Replays the last undone Replace All.
    @discardableResult
    public func redo(_ io: ReplaceIO) -> Outcome {
        guard let t = redoStack.popLast() else { return Outcome() }
        undoStack.append(t)
        return Self.restore(t, io, toOriginal: false)
    }

    /// Puts every file of a transaction back to its text before
    /// (`toOriginal`) or after the replace; a file whose current text is
    /// neither expected one is a conflict and stays as it is.
    public static func restore(_ t: ReplaceTransaction, _ io: ReplaceIO, toOriginal: Bool) -> Outcome {
        let from: KeyPath<ReplaceChange, String> = toOriginal ? \.newText : \.oldText
        let to: KeyPath<ReplaceChange, String> = toOriginal ? \.oldText : \.newText
        var o = Outcome()
        for c in t.changes {
            if io.read(c.path) == c[keyPath: from], io.write(c.path, c[keyPath: to]) { o.restored.append(c.path) } else { o.conflicts.append(c.path) }
        }
        return o
    }
}
