import Foundation

/// Find and replace inside one text. See `specs/ide/source-editor.md`
/// §Find bar.
public struct EditorFind: Equatable {
    public var query = ""
    public var replacement = ""
    public var options = WorkspaceSearch.Options()
    public private(set) var matches: [NSRange] = []
    /// Index of the current match, if any.
    public private(set) var current: Int?

    public init() {}

    /// Recomputes matches; the current match becomes the first one at or
    /// after `from`.
    public mutating func update(text: String, from: Int = 0) {
        guard !query.isEmpty, let regex = options.expression(for: query) else {
            matches = []
            current = nil
            return
        }
        matches = WorkspaceSearch.search(regex, inText: text).map(\.range)
        current = matches.isEmpty ? nil : (matches.firstIndex { $0.location >= from } ?? 0)
    }

    /// Moves to the next (or previous) match, wrapping around.
    public mutating func step(_ forward: Bool) {
        guard !matches.isEmpty else { return }
        let c = current ?? (forward ? -1 : 0)
        current = ((c + (forward ? 1 : -1)) % matches.count + matches.count) % matches.count
    }

    public var currentRange: NSRange? { current.map { matches[$0] } }

    /// The text that replaces `range` (regex templates expand `$1` …).
    public func replacementText(in text: String, range: NSRange) -> String {
        guard options.regularExpression, let regex = options.expression(for: query),
              let m = regex.firstMatch(in: text, range: range) else { return replacement }
        return regex.replacementString(for: m, in: text, offset: 0, template: replacement)
    }

    /// The whole text with every match replaced.
    public func replacingAll(in text: String) -> (String, Int) {
        guard !query.isEmpty, let regex = options.expression(for: query) else { return (text, 0) }
        let ns = text as NSString
        let count = regex.numberOfMatches(in: text, range: NSRange(location: 0, length: ns.length))
        let template = options.regularExpression ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        return (regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: template), count)
    }
}
