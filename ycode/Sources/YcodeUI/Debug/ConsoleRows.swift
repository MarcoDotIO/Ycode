import AppKit

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
    /// belongs to the entry it starts in.
    public static func rows(_ entries: [ConsoleEntry]) -> [ConsoleRow] {
        var out: [ConsoleRow] = []
        var line = ""
        var owner: ConsoleEntry?
        for e in entries {
            for ch in e.text {
                if owner == nil { owner = e }
                if ch == "\n" {
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

extension DebugAreaController {
    /// The console row at the caret or selection start: an index into the
    /// rows of the unfiltered console text (the bar's text filter shows a
    /// subset of its lines).
    public var selectedConsoleRow: Int? {
        _ = view
        let shown = consoleView.string as NSString
        let location = min(consoleView.selectedRange().location, shown.length)
        guard shown.length > 0 else { return nil }
        var shownLine = 0
        var i = 0
        while i < location { if shown.character(at: i) == 10 { shownLine += 1 }; i += 1 }
        let f = consoleSearch.stringValue
        guard !f.isEmpty else { return shownLine }
        let raw = consoleRaw.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = raw.indices.filter { raw[$0].localizedCaseInsensitiveContains(f) }
        return kept.indices.contains(shownLine) ? kept[shownLine] : nil
    }

    /// Puts the caret in a row of the shown text (tests, Jump To Source).
    public func placeConsoleCaret(line: Int) {
        _ = view
        let ns = consoleView.string as NSString
        var loc = 0
        var n = 0
        while n < line, loc < ns.length {
            let r = ns.range(of: "\n", range: NSRange(location: loc, length: ns.length - loc))
            guard r.location != NSNotFound else { break }
            loc = NSMaxRange(r)
            n += 1
        }
        consoleView.setSelectedRange(NSRange(location: loc, length: 0))
    }

    /// Debug ▸ Console ▸ Select Last Output: selects the console's last
    /// paragraph. Returns the selected text.
    @discardableResult
    public func selectLastOutput() -> String? {
        _ = view
        guard let r = ConsoleRows.lastParagraph(in: consoleView.string) else { return nil }
        consoleView.setSelectedRange(r)
        consoleView.scrollRangeToVisible(r)
        view.window?.makeFirstResponder(consoleView)
        return (consoleView.string as NSString).substring(with: r)
    }

    /// The selected text of the console (tests).
    public var consoleSelection: String {
        _ = view
        return (consoleView.string as NSString).substring(with: consoleView.selectedRange())
    }
}
