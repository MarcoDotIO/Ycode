import Foundation

/// Live issues on the line being typed wait until typing pauses (parity
/// inventory P-080): typing "Co" on a new line must not mark the line
/// "Cannot find 'Co' in scope" at once, nor "Expected member name" right
/// after a ".". The language server's diagnostics for that line are held
/// back while the user is still typing on it; the rest of the file's
/// diagnostics show at once. When the hold ends the held ones appear.
///
/// **Decision:** a hold of 1.5 s after the last edit on the line, Ycode's
/// own value (the reference shows no error while the completion list is
/// up and the word is unfinished; no duration was measured).
public struct LiveIssueHold: Sendable {
    public static let defaultDuration: TimeInterval = 1.5

    public var duration: TimeInterval
    /// The line (0-based) last edited per file path, and when.
    private var edits: [String: (line: Int, at: Date)] = [:]

    public init(duration: TimeInterval = defaultDuration) { self.duration = duration }

    /// Notes an edit of `path` from `old` to `new` text: the first line that
    /// differs is the line being typed.
    public mutating func noteEdit(path: String, old: String?, new: String, at now: Date = Date()) {
        guard let old else { return }
        guard let line = Self.firstChangedLine(old, new) else { return }
        edits[path] = (line, now)
    }

    /// Forgets the file (closed, or the server restarted).
    public mutating func forget(_ path: String) { edits[path] = nil }

    /// The line held for `path` at `now`, if its hold has not ended.
    public func heldLine(_ path: String, at now: Date = Date()) -> Int? {
        guard let e = edits[path], now.timeIntervalSince(e.at) < duration else { return nil }
        return e.line
    }

    /// When the hold of `path` ends (nil when nothing is held).
    public func holdEnd(_ path: String, at now: Date = Date()) -> Date? {
        guard let e = edits[path], now.timeIntervalSince(e.at) < duration else { return nil }
        return e.at.addingTimeInterval(duration)
    }

    /// The diagnostics to show now: those starting on the held line are
    /// left out while the hold lasts.
    public func visible(_ list: [LSPDiagnostic], path: String, at now: Date = Date()) -> [LSPDiagnostic] {
        guard let line = heldLine(path, at: now) else { return list }
        return list.filter { $0.start.line != line }
    }

    /// The 0-based line of the first difference between two texts (nil when
    /// they are equal).
    public static func firstChangedLine(_ a: String, _ b: String) -> Int? {
        var line = 0
        var ia = a.utf16.makeIterator(), ib = b.utf16.makeIterator()
        while true {
            let ca = ia.next(), cb = ib.next()
            if ca == nil, cb == nil { return nil }
            if ca != cb { return line }
            if ca == 10 { line += 1 }
        }
    }
}
