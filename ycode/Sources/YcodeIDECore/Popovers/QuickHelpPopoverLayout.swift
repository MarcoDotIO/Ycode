import Foundation

// Quick Help's popover (P-083; `specs/ide/popovers.md` §4, §4.1, §4.2),
// one layout for both IDEs: the 417-point body, the borderless declaration
// box with modifiers on their own line, the file link, and Quick Help for a
// module named in an `import` from Ycode's documentation source (a DocC
// catalog in the workspace).

/// The popover's metrics (§4.2), points; y down from the body's top.
public enum QuickHelpPopoverMetrics {
    /// Every Quick Help popover's body (§4 item 4, §4.2): 417 wide, the
    /// height from the content.
    public static let width = 417.0
    /// The content's inset from the body's left and right edges.
    public static let sideInset = 16.0
    public static let topInset = 14.0
    public static let bottomInset = 14.0
    public static let titleFontSize = 15.0
    /// From the title to the declaration box.
    public static let titleToDeclaration = 8.0
    /// The declaration box: the body's width less the insets (385), no
    /// border, corners 6, 17.5-point lines with 7.5 above and below (50 for
    /// two lines).
    public static var declarationWidth: Double { width - 2 * sideInset }
    public static let declarationLinePitch = 17.5
    public static let declarationVerticalPadding = 7.5
    public static let declarationHorizontalPadding = 8.0
    public static let declarationRadius = 6.0
    public static let declarationFontSize = 12.0
    /// From the box to the file link.
    public static let declarationToFile = 12.0
    public static let bodyFontSize = 12.0
    /// A module's "Overview" heading: bold, smaller than the title.
    public static let overviewFontSize = 13.0
    public static let linkFontSize = 11.0

    public static func declarationHeight(lines: Int) -> Double {
        Double(max(1, lines)) * declarationLinePitch + 2 * declarationVerticalPadding
    }

    /// The box's fill: ≈ #262626 in dark (§4.2), white in light.
    public static func declarationFill(dark: Bool) -> UInt32 { dark ? 0x262626 : 0xFFFFFF }
    /// The module popover's hairline under the abstract.
    public static func hairline(dark: Bool) -> UInt32 { dark ? 0x5A5A5A : 0xD0D0D0 }
}

/// The declaration's lines in the box (§4.2): attributes and modifiers
/// before the declaration's keyword on their own line, then the rest
/// (`nonisolated` over `let name: String`). Several attributes stay on one
/// line together (OPEN: one case recorded). A declaration that already
/// has line breaks keeps them.
public enum QuickHelpDeclarationLines {
    static let introducers: Set<String> = ["func", "var", "let", "struct", "class", "enum", "protocol", "actor", "typealias",
                                           "associatedtype", "case", "init", "deinit", "subscript", "macro", "extension",
                                           "operator", "precedencegroup", "import"]

    public static func lines(_ declaration: String) -> [String] {
        let d = declaration.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty else { return [] }
        if d.contains("\n") { return d.components(separatedBy: "\n") }
        // Top-level words (outside parentheses and angle brackets).
        var depth = 0
        var wordStart: String.Index?
        var keywordAt: String.Index?
        func check(_ start: String.Index, _ end: String.Index) -> Bool {
            let w = String(d[start..<end])
            return introducers.contains(w)
        }
        var i = d.startIndex
        while i < d.endIndex {
            let c = d[i]
            if c == "(" || c == "<" { depth += 1 } else if c == ")" || c == ">" { depth = max(0, depth - 1) }
            let isWordChar = c.isLetter || c.isNumber || c == "_" || c == "@"
            if depth == 0 && isWordChar && wordStart == nil { wordStart = i }
            if let s = wordStart, !isWordChar || depth > 0 {
                if check(s, i) { keywordAt = s; break }
                wordStart = nil
            }
            i = d.index(after: i)
        }
        if keywordAt == nil, let s = wordStart, check(s, d.endIndex) { keywordAt = s }
        guard let k = keywordAt else { return [d] }
        let prefix = d[..<k].trimmingCharacters(in: .whitespaces)
        guard !prefix.isEmpty else { return [d] }
        return [prefix, String(d[k...])]
    }
}

/// Quick Help for a module (§4.1): the module named at an offset of an
/// `import` line, and its document from Ycode's documentation source.
public enum ModuleQuickHelp {
    /// The module whose name is at `offset` (UTF-16) in `text`, when that
    /// line is an import declaration (`import Foundation`, `@testable import
    /// MyKit`, `import struct MyKit.Thing`, `import MyKit.Sub`); the first
    /// component of a dotted path names the module. Nil elsewhere.
    public static func moduleName(in text: String, at offset: Int) -> String? {
        let ns = text as NSString
        guard offset >= 0, offset <= ns.length else { return nil }
        let lineRange = ns.lineRange(for: NSRange(location: min(offset, max(0, ns.length - 1)), length: 0))
        let line = ns.substring(with: lineRange)
        let column = offset - lineRange.location
        // Words with their UTF-16 ranges in the line.
        var words: [(String, NSRange)] = []
        let l = line as NSString
        var i = 0
        while i < l.length {
            let c = l.character(at: i)
            if isIdentifier(c) || c == 0x40 /* @ */ {
                let s = i
                while i < l.length, isIdentifier(l.character(at: i)) || l.character(at: i) == 0x40 { i += 1 }
                words.append((l.substring(with: NSRange(location: s, length: i - s)), NSRange(location: s, length: i - s)))
            } else if c == 0x2F, i + 1 < l.length, l.character(at: i + 1) == 0x2F {
                break   // a comment
            } else {
                i += 1
            }
        }
        guard let at = words.firstIndex(where: { $0.0 == "import" }) else { return nil }
        // Only attributes (and their arguments) may come before `import`.
        guard words[..<at].allSatisfy({ $0.0.hasPrefix("@") || $0.0.first?.isLowercase == true }) else { return nil }
        let kinds: Set<String> = ["struct", "class", "enum", "protocol", "typealias", "func", "var", "let", "actor"]
        var m = at + 1
        if m < words.count, kinds.contains(words[m].0) { m += 1 }
        guard m < words.count else { return nil }
        let r = words[m].1
        guard column >= r.location, column <= r.location + r.length else { return nil }
        return words[m].0
    }

    /// The folder a workspace's catalogs are searched from: the container's
    /// folder (a project, a workspace or `Package.swift`), or the package
    /// folder itself.
    public static func searchRoot(container url: URL) -> URL {
        url.pathExtension.isEmpty ? url : url.deletingLastPathComponent()
    }

    /// The UTF-16 offset of an LSP position (0-based line, UTF-16 column).
    public static func offset(in text: String, line: Int, character: Int) -> Int {
        var off = 0, l = 0
        for u in text.utf16 {
            if l == line { break }
            off += 1
            if u == 0x0A { l += 1 }
        }
        return off + character
    }

    private static func isIdentifier(_ c: unichar) -> Bool {
        guard let u = Unicode.Scalar(c) else { return false }
        return CharacterSet.alphanumerics.contains(u) || c == 0x5F
    }

    /// The module's document: its title, and the abstract and Overview from
    /// the module's DocC catalog under one of `roots` (the catalog's root
    /// article, `# ``Module```); the title and the documentation link alone
    /// when there is none (never nothing, §4.1).
    public static func document(module: String, roots: [URL]) -> QuickHelpDocument {
        var doc = QuickHelpDocument()
        if let article = catalogArticle(module: module, roots: roots) {
            doc = document(article: article)
        }
        doc.title = module
        doc.isModule = true
        doc.declaration = ""
        doc.file = nil
        return doc
    }

    /// A catalog root article's document: the abstract (the first
    /// paragraph after the title) and the Overview section's blocks.
    public static func document(article: String) -> QuickHelpDocument {
        var lines = article.components(separatedBy: "\n")
        if let t = lines.firstIndex(where: { $0.hasPrefix("# ") }) { lines.removeSubrange(0...t) }
        // Directives (@Metadata { … }) are not text.
        var body: [String] = []
        var directiveDepth = 0
        for l in lines {
            let t = l.trimmingCharacters(in: .whitespaces)
            if directiveDepth > 0 || (t.hasPrefix("@") && t.contains("{")) {
                directiveDepth += t.filter { $0 == "{" }.count - t.filter { $0 == "}" }.count
                continue
            }
            body.append(l)
        }
        // The abstract: the first paragraph.
        var i = 0
        while i < body.count, body[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
        var abstract: [String] = []
        while i < body.count, !body[i].trimmingCharacters(in: .whitespaces).isEmpty, !body[i].hasPrefix("#") {
            abstract.append(body[i].trimmingCharacters(in: .whitespaces))
            i += 1
        }
        // The Overview: from "## Overview" to the next level-2 heading.
        var overview: [String] = []
        if let o = body.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "## overview" }) {
            var j = o + 1
            while j < body.count, !body[j].hasPrefix("## ") {
                overview.append(body[j])
                j += 1
            }
        }
        // The Markup parser: the first paragraph is the summary, the rest
        // the blocks.
        let markdown = abstract.joined(separator: " ") + "\n\n" + overview.joined(separator: "\n")
        var doc = QuickHelpDocument(hover: markdown)
        if abstract.isEmpty {
            // No abstract: every block is Overview.
            doc = QuickHelpDocument(hover: "x\n\n" + overview.joined(separator: "\n"))
            doc.summary = nil
        }
        doc.overview = doc.discussionBlocks
        doc.discussionBlocks = []
        doc.discussion = []
        return doc
    }

    /// The root article of `module`'s catalog: a `<Module>.docc` folder
    /// (searched a few levels deep, skipping build output) whose Markdown
    /// file starts with `# ``Module```.
    public static func catalogArticle(module: String, roots: [URL]) -> String? {
        let fm = FileManager.default
        let skip: Set<String> = [".build", ".git", "node_modules", "DerivedData", ".ycode-build", ".swiftpm", "build"]
        var queue = roots.map { ($0, 0) }
        var catalogs: [URL] = []
        var visited = 0
        while !queue.isEmpty, visited < 4000 {
            let (dir, depth) = queue.removeFirst()
            visited += 1
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for n in names.sorted() where !skip.contains(n) && !n.hasPrefix(".") {
                let u = dir.appendingPathComponent(n)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue else { continue }
                if n.hasSuffix(".docc") { catalogs.append(u); continue }
                if depth < 5 { queue.append((u, depth + 1)) }
            }
        }
        // `<Module>.docc` first, then any catalog.
        catalogs = catalogs.filter { $0.lastPathComponent == module + ".docc" } + catalogs.filter { $0.lastPathComponent != module + ".docc" }
        let heading = "# ``\(module)``"
        for c in catalogs {
            guard let files = fm.enumerator(atPath: c.path) else { continue }
            for case let f as String in files where f.hasSuffix(".md") {
                guard let text = try? String(contentsOf: c.appendingPathComponent(f), encoding: .utf8) else { continue }
                if text.components(separatedBy: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
                    .trimmingCharacters(in: .whitespaces) == heading {
                    return text
                }
            }
        }
        return nil
    }
}
