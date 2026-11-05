import Foundation

/// One console row: a line of the console's text and the output entry it
/// starts in (for its metadata). See `specs/ide/reference-ui-5.md` §2.10
/// (Debug ▸ Console) and §10.2.
public struct ConsoleRow: Equatable, Sendable {
    public var text: String
    public var entry: ConsoleEntry
}

public enum ConsoleRows {
    /// The rows of the entries' text: one per line, in order. A line that
    /// spans several entries (output without a line break, then more)
    /// belongs to the entry it starts in. "\r\n" (a pseudo-terminal's line
    /// end, one `Character`) ends a line as "\n" does.
    public static func rows(_ entries: [ConsoleEntry]) -> [ConsoleRow] {
        var out: [ConsoleRow] = []
        var line = ""
        var owner: ConsoleEntry?
        for e in entries {
            for ch in e.text {
                if owner == nil { owner = e }
                if ch == "\n" || ch == "\r\n" {
                    out.append(ConsoleRow(text: line, entry: owner!))
                    line = ""
                    owner = nil
                } else {
                    line.append(ch)
                }
            }
        }
        if let owner, !line.isEmpty { out.append(ConsoleRow(text: line, entry: owner)) }
        return out
    }

    /// Every column the console has data for (Copy Row with All Metadata).
    public static var allMetadata: ConsoleMetadata {
        var m = ConsoleMetadata()
        for i in ConsoleMetadata.supportedColumns { m.set(i, true) }
        return m
    }

    /// A row as copied: with `metadata`'s columns as its prefix, or bare
    /// (Copy Row without Metadata passes nil).
    public static func copyText(_ row: ConsoleRow, metadata: ConsoleMetadata?) -> String {
        guard let metadata else { return row.text }
        var e = row.entry
        e.text = row.text
        return WorkspaceSession.consoleText([e], metadata: metadata)
    }

    /// A source location named in a row: `path:line` (with an optional
    /// `:column`), or "file <path>, line <n>". Nil when there is none.
    public static func sourceLocation(in text: String) -> (path: String, line: Int)? {
        let patterns = [
            #"((?:~|/)?(?:[\w.+\-]+/)*[\w.+\-]+\.[A-Za-z][\w]*):(\d+)"#,
            #"file ((?:~|/)?(?:[\w.+\-]+/)*[\w.+\-]+\.[A-Za-z][\w]*), line (\d+)"#,
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let pr = Range(m.range(at: 1), in: text), let lr = Range(m.range(at: 2), in: text),
                  let line = Int(text[lr]), line > 0 else { continue }
            return (String(text[pr]), line)
        }
        return nil
    }

    /// Resolves a row's path: an existing absolute path, else the
    /// workspace file whose path ends with it (the shortest such path).
    public static func resolve(_ path: String, files: [String]) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/"), FileManager.default.fileExists(atPath: expanded) { return expanded }
        let tail = "/" + path.split(separator: "/").suffix(path.hasPrefix("/") ? 2 : 8).joined(separator: "/")
        let name = "/" + (path.split(separator: "/").last.map(String.init) ?? path)
        let matches = files.filter { $0.hasSuffix(tail) }
        if let best = matches.min(by: { $0.count < $1.count }) { return best }
        return files.filter { $0.hasSuffix(name) }.min { $0.count < $1.count }
    }

    /// The range of the text's last paragraph (lines between blank lines),
    /// without its line breaks; nil for empty text.
    public static func lastParagraph(in text: String) -> NSRange? {
        let ns = text as NSString
        var end = ns.length
        while end > 0, ns.character(at: end - 1) == 10 { end -= 1 }
        guard end > 0 else { return nil }
        let blank = ns.range(of: "\n\n", options: .backwards, range: NSRange(location: 0, length: end))
        let start = blank.location == NSNotFound ? 0 : NSMaxRange(blank)
        return NSRange(location: start, length: end - start)
    }
}
