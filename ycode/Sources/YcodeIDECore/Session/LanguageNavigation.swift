import Foundation
import YcodeLanguage

// Language-server navigation and refactoring as values both IDEs share
// (`specs/ide/language.md` §Features, `specs/ide/refactoring.md`): edits
// applied to text, the rename preview, references and callers as Find
// results. The macOS window and the Linux shell draw them their own way.

/// Text edits (LSP `TextEdit`, 0-based lines and UTF-16 columns) applied
/// to text (`refactoring.md` §Applying edits).
public enum TextEditApplication {
    /// The edits as UTF-16 ranges of `text` with their new text, in the
    /// order given. Positions past a line's end are clamped to it.
    public static func ranges(_ edits: [TextEdit], in text: String) -> [(range: NSRange, newText: String)] {
        let index = LineIndex(text)
        return edits.map { e in
            let a = index.offset(of: e.start), b = index.offset(of: e.end)
            return (NSRange(location: a, length: max(0, b - a)), e.newText)
        }
    }

    /// The text with the edits made (last first, so earlier ranges stay valid).
    public static func apply(_ edits: [TextEdit], to text: String) -> String {
        let ns = NSMutableString(string: text)
        for r in ranges(edits, in: text).sorted(by: { $0.range.location > $1.range.location }) {
            ns.replaceCharacters(in: r.range, with: r.newText)
        }
        return ns as String
    }
}

/// What a rename will change, file by file (`refactoring.md` §Rename, the
/// preview sheet): each changed line before and after.
public struct RenamePreview: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        /// 1-based.
        public var line: Int
        public var before: String
        public var after: String
    }

    public struct File: Equatable, Sendable {
        public var path: String
        /// Edits in the file (occurrences renamed).
        public var editCount: Int
        public var lines: [Line]
        public var name: String { (path as NSString).lastPathComponent }
        /// "3 changes".
        public var countText: String { "\(editCount) change\(editCount == 1 ? "" : "s")" }
    }

    public var oldName: String
    public var newName: String
    public var edit: WorkspaceEdit
    public var files: [File]

    /// `text` reads a file's current text (the editor's buffer when it is
    /// open, else the disk); a file it cannot read is listed without lines.
    public init(edit: WorkspaceEdit, oldName: String, newName: String, text: (URL) -> String?) {
        self.oldName = oldName
        self.newName = newName
        self.edit = edit
        files = edit.files.compactMap { url in
            let edits = edit.changes[url] ?? []
            guard !edits.isEmpty else { return nil }
            let path = url.standardizedFileURL.path
            guard let old = text(url) else { return File(path: path, editCount: edits.count, lines: []) }
            let new = TextEditApplication.apply(edits, to: old)
            let oldLines = old.components(separatedBy: "\n"), newLines = new.components(separatedBy: "\n")
            // Edits of a rename keep the line count: line n before is line n after.
            let touched = Set(edits.flatMap { $0.start.line...max($0.start.line, $0.end.line) }).sorted()
            let lines = touched.compactMap { n -> Line? in
                guard n < oldLines.count else { return nil }
                let after = oldLines.count == newLines.count && n < newLines.count ? newLines[n] : oldLines[n]
                return Line(line: n + 1, before: oldLines[n].trimmingCharacters(in: .whitespaces),
                            after: after.trimmingCharacters(in: .whitespaces))
            }
            return File(path: path, editCount: edits.count, lines: lines)
        }
    }

    public var editCount: Int { files.reduce(0) { $0 + $1.editCount } }

    /// "Rename 4 occurrences in 2 files".
    public var summary: String {
        let n = editCount, f = files.count
        return "Rename \(n) occurrence\(n == 1 ? "" : "s") in \(f) file\(f == 1 ? "" : "s")"
    }
}

/// References and callers as Find navigator results (`refactoring.md` §Find):
/// files in path order, then the locations by line, each row the trimmed
/// line with the symbol marked.
public enum SymbolResults {
    /// "greet — 3 references".
    public static func referencesTitle(_ name: String, count: Int) -> String {
        "\(name) — \(count) reference\(count == 1 ? "" : "s")"
    }

    /// "Callers of greet".
    public static func callersTitle(_ name: String) -> String { "Callers of \(name)" }

    /// The locations as Find results. `text` reads a file's current text.
    public static func fileResults(_ locations: [Location], text: (String) -> String?) -> [WorkspaceSearch.FileResult] {
        let byFile = Dictionary(grouping: locations) { $0.url.standardizedFileURL.path }
        return byFile.keys.sorted().map { path in
            let source = text(path) ?? ""
            let index = LineIndex(source)
            let ns = source as NSString
            var seen = Set<Position>()
            let locs = byFile[path]!.filter { seen.insert($0.start).inserted }
                .sorted { ($0.start.line, $0.start.character) < ($1.start.line, $1.start.character) }
            let matches = locs.map { l -> WorkspaceSearch.Match in
                let lineRange = index.range(ofLine: l.start.line + 1) ?? NSRange(location: 0, length: 0)
                let raw = lineRange.length > 0 ? ns.substring(with: lineRange) : ""
                let trimmed = raw.drop(while: { $0 == " " || $0 == "\t" })
                let lead = raw.utf16.count - String(trimmed).utf16.count
                let start = index.offset(of: l.start)
                var end = index.offset(of: l.end)
                if end <= start { end = start + identifierLength(ns, at: start) }
                let column = start - lineRange.location
                let length = max(0, min(end, NSMaxRange(lineRange)) - start)
                let highlight = NSRange(location: max(0, column - lead), length: length)
                return WorkspaceSearch.Match(line: l.start.line + 1, text: String(trimmed), range: NSRange(location: start, length: length),
                                             column: column + 1, highlight: highlight, matchedText: ns.substring(with: NSRange(location: start, length: length)))
            }
            return WorkspaceSearch.FileResult(path: path, matches: matches)
        }
    }

    /// The identifier's length at `offset` (a location without a range).
    static func identifierLength(_ ns: NSString, at offset: Int) -> Int {
        var end = offset
        while end < ns.length, let u = Unicode.Scalar(ns.character(at: end)),
              CharacterSet.alphanumerics.contains(u) || u == "_" { end += 1 }
        return end - offset
    }
}

extension WorkspaceSession {
    /// `textDocument/prepareRename`: the symbol's range and its name; nil
    /// when the position cannot be renamed or there is no server.
    public func prepareRename(_ url: URL, at p: Position) async -> (start: Position, end: Position, placeholder: String?)? {
        guard let language else { return nil }
        return try? await language.client.prepareRename(url, at: p)
    }

    /// `textDocument/rename`; nil when the server gives no edit.
    public func rename(_ url: URL, at p: Position, to newName: String) async -> WorkspaceEdit? {
        guard let language, let edit = try? await language.client.rename(url, at: p, to: newName), !edit.isEmpty else { return nil }
        return edit
    }

    /// `textDocument/references`, the declaration included.
    public func references(_ url: URL, at p: Position) async -> [Location] {
        guard let language else { return [] }
        return (try? await language.client.references(url, at: p)) ?? []
    }

    /// Navigate ▸ Jump to Original Source: the declaration, else the definition.
    public func declarationOrDefinition(_ url: URL, at p: Position) async -> Location? {
        guard let language else { return nil }
        if let d = (try? await language.client.declaration(url, at: p))?.first { return d }
        return (try? await language.client.definition(url, at: p))?.first
    }

    /// Find ▸ Find Call Hierarchy: the symbol at `p` and the places that
    /// call it (each caller's call sites); nil when it is not callable.
    public func callers(_ url: URL, at p: Position) async -> (name: String, sites: [Location])? {
        guard let language, let item = (try? await language.client.prepareCallHierarchy(url, at: p))?.first else { return nil }
        let calls = (try? await language.client.incomingCalls(item)) ?? []
        let sites = calls.flatMap { c in
            (c.ranges.isEmpty ? [c.caller.selection] : c.ranges).map { Location(url: c.caller.url, start: $0, end: $0) }
        }
        return (item.name, sites)
    }
}

/// A file's declarations for the jump bar (`navigators.md` §Symbols): the
/// one the insertion point is in (the symbol component) and the document
/// items menu. Both IDEs read them from `SymbolScanner`.
public enum DocumentSymbols {
    /// The innermost declaration whose body holds 1-based `line`: the last
    /// one starting at or before it, if the line is not past its end, then
    /// the same among its members.
    public static func enclosing(_ symbols: [SymbolScanner.Symbol], line: Int, text: NSString, index: LineIndex) -> SymbolScanner.Symbol? {
        var best: SymbolScanner.Symbol?
        var level = symbols
        while let s = level.last(where: { $0.line <= line }), line <= endLine(of: s, text: text, index: index) {
            best = s
            level = s.children
        }
        return best
    }

    /// The line of a declaration's closing brace (its own line when it has
    /// no body). Braces in strings and comments are not skipped (an
    /// approximation for the jump bar).
    public static func endLine(of s: SymbolScanner.Symbol, text ns: NSString, index: LineIndex) -> Int {
        guard let start = index.range(ofLine: s.line) else { return s.line }
        var depth = 0, opened = false, i = start.location
        let open = UInt16(UInt8(ascii: "{")), close = UInt16(UInt8(ascii: "}")), nl = UInt16(UInt8(ascii: "\n"))
        while i < ns.length {
            let c = ns.character(at: i)
            if c == open { depth += 1; opened = true }
            else if c == close { depth -= 1; if opened && depth == 0 { return index.line(at: i) } }
            else if c == nl && !opened && i > start.location + start.length { return s.line }
            i += 1
        }
        return opened ? index.line(at: max(0, ns.length - 1)) : s.line
    }

    /// Every declaration depth first, with its nesting depth (the document
    /// items menu, indented).
    public static func flattened(_ symbols: [SymbolScanner.Symbol], depth: Int = 0) -> [(depth: Int, symbol: SymbolScanner.Symbol)] {
        symbols.flatMap { [(depth, $0)] + flattened($0.children, depth: depth + 1) }
    }

    /// The letter badge of a kind (C class, S struct, E enum, P protocol, X
    /// extension, A actor, F function, T typealias, M macro, V property,
    /// I initializer), Ycode's own style.
    public static func badge(_ k: SymbolScanner.Symbol.Kind) -> String {
        switch k {
        case .class, .interface, .implementation: "C"
        case .struct: "S"
        case .enum, .enumCase: "E"
        case .protocol: "P"
        case .extension: "X"
        case .actor: "A"
        case .function: "F"
        case .typealias: "T"
        case .macro: "M"
        case .property: "V"
        case .initializer: "I"
        }
    }
}
