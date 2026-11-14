import Foundation

/// The language logos of the file glyphs (`FileGlyphs`; council round 9,
/// row 208, the owner's rule 1 of 2026-11-13, replacing round 7's
/// full-colour logos): each language keeps its official logo, drawn as
/// single-colour vector line art from devicon v2.18.0's "plain" variant,
/// or its "line" variant where it has no plain one (C, Rust) (MIT;
/// trademark notices in THIRD_PARTY_NOTICES.md).
/// `scripts/generate-language-logos.swift` converts the SVGs' path data
/// (`Resources/language-logos`) to Ycode's own outline data
/// (`LanguageLogoData.swift`), which both IDEs fill in the file type's
/// tint. The owner's decisions of 2026-11-13: Swift is the plain
/// variant's bird alone (inverted, no tile), Python its plain shapes'
/// outline only (`outlineOnly`); JSON and Markdown have Ycode's own glyphs
/// (`FileGlyphs.json`, `FileGlyphs.book`).
public enum LanguageLogos {
    /// The logo's name ("swift") for a file name, or nil without one.
    public static func logo(forFileName name: String) -> String? {
        extensions[(name as NSString).pathExtension.lowercased()]
    }

    /// File extensions and their logos.
    public static let extensions: [String: String] = {
        var m: [String: String] = [:]
        let table: [(String, [String])] = [
            ("swift", ["swift"]), ("python", ["py"]), ("cplusplus", ["cpp", "cc", "cxx", "hpp", "hh"]), ("c", ["c", "h"]),
            ("javascript", ["js", "mjs", "cjs"]), ("typescript", ["ts", "tsx"]), ("rust", ["rs"]), ("go", ["go"]),
            ("ruby", ["rb"]), ("java", ["java"]), ("kotlin", ["kt", "kts"]), ("html5", ["html", "htm"]), ("css3", ["css"]),
            ("bash", ["sh", "bash", "zsh"]),
        ]
        for (logo, exts) in table { for e in exts { m[e] = logo } }
        return m
    }()

    /// Every logo's name.
    public static var names: [String] { outlineData.keys.sorted() }

    /// The SVG a logo was converted from ("rust-line.svg").
    public static func source(_ name: String) -> String? { outlineData[name]?.source }

    /// How much the thin outlines of a "line" variant are thickened, in
    /// points at the navigator's box: their bands (about 0.2 points at
    /// that size) become the reference's 1.5-point line art. Plain
    /// variants are solid shapes.
    public static let strokeBoost: [String: Double] = ["c": 1.25, "rust": 1.35]

    /// Logos drawn as the outline of their plain shapes only, no fill, at
    /// the reference's 1.5-point stroke (the owner's decision of
    /// 2026-11-13: Python).
    public static let outlineOnly: Set<String> = ["python"]

    /// A logo's outline: its ink box in the SVG's units and its paths from
    /// the box's top left (y down).
    public struct Outline: Sendable {
        public let width: Double
        public let height: Double
        public let paths: [(elements: [GlyphElement], evenOdd: Bool)]
    }

    nonisolated(unsafe) private static var cache: [String: Outline] = [:]
    private static let lock = NSLock()

    /// A logo's outline, parsed once from the generated data.
    public static func outline(_ name: String) -> Outline? {
        lock.lock()
        defer { lock.unlock() }
        if let o = cache[name] { return o }
        guard let e = outlineData[name] else { return nil }
        let o = Outline(width: e.width, height: e.height, paths: e.paths.map { (parse($0.d), $0.evenOdd) })
        cache[name] = o
        return o
    }

    /// The generated outline text ("M1 2L3 4C…Z") as elements.
    static func parse(_ d: String) -> [GlyphElement] {
        var out: [GlyphElement] = []
        var numbers: [Double] = [], command: Character = " ", token = ""
        func flush() {
            if !token.isEmpty, let v = Double(token) { numbers.append(v) }
            token = ""
        }
        func emit() {
            flush()
            switch command {
            case "M" where numbers.count >= 2: out.append(.move(numbers[0], numbers[1]))
            case "L" where numbers.count >= 2: out.append(.line(numbers[0], numbers[1]))
            case "C" where numbers.count >= 6: out.append(.curve(numbers[0], numbers[1], numbers[2], numbers[3], numbers[4], numbers[5]))
            case "Z": out.append(.close)
            default: break
            }
            numbers = []
        }
        for ch in d {
            switch ch {
            case "M", "L", "C", "Z":
                if command != " " { emit() }
                command = ch
            case " ": flush()
            case "-":
                flush()
                token = "-"
            default: token.append(ch)
            }
        }
        if command != " " { emit() }
        return out
    }
}

/// What a project navigator row shows as its icon.
public enum NavigatorRowIcon: Equatable, Hashable, Sendable {
    /// A language's logo (`LanguageLogos`), as single-colour line art.
    case logo(String)
    /// Ycode's own JSON glyph (`FileGlyphs.json`).
    case json
    /// Ycode's own Markdown glyph, an open book (`FileGlyphs.book`).
    case markdown
    /// Ycode's own filled folder (`FileGlyphs.folder`): a group or folder.
    case folder
    /// The Ycode mark (the project's top row).
    case ycodeMark
    /// Ycode's own picture glyph (`FileGlyphs.picture`, round 10, row 243):
    /// an image file.
    case image
    /// One of Ycode's glyphs, by symbol name.
    case symbol(String)

    /// The icon of a node: a project, workspace or package row the Ycode
    /// mark, a group or folder the folder, a file with a logo its logo, a
    /// JSON or Markdown file Ycode's own glyph, everything else its symbol.
    public static func of(_ node: NavigatorNode) -> NavigatorRowIcon { of(kind: node.kind, name: node.name, path: node.path) }

    public static func of(kind: NavigatorNode.Kind, name: String, path: String?) -> NavigatorRowIcon {
        switch kind {
        case .container: return .ycodeMark
        case .group, .folder: return .folder
        case .file: return ofFile(name)
        }
    }

    /// A file's icon by its name (wherever a file is listed: the jump bar,
    /// the merge sheet, Open Quickly).
    public static func ofFile(_ name: String) -> NavigatorRowIcon {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "json" { return .json }
        if ext == "md" { return .markdown }
        if let logo = LanguageLogos.logo(forFileName: name) { return .logo(logo) }
        let symbol = WorkspaceChrome.fileSymbol(name)
        return symbol == "photo" ? .image : .symbol(symbol)
    }

    /// Whether Ycode draws the icon from its own outlines (`FileGlyphs`).
    public var isGlyph: Bool {
        switch self {
        case .logo, .json, .markdown, .folder, .image: true
        case .ycodeMark, .symbol: false
        }
    }
}
