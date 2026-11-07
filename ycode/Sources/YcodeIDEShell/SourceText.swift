import Foundation
import YcodeIDECore
import YcodeSyntax

/// One stretch of a source line drawn in one color role (nil: the plain
/// text color).
public struct SourceRun: Equatable, Sendable {
    public var text: String
    public var role: SyntaxTokenKind.Role?
    public init(_ text: String, role: SyntaxTokenKind.Role? = nil) {
        self.text = text
        self.role = role
    }
}

/// One line of the read-only editor (L1): its 1-based number and its
/// highlighted runs, tabs expanded.
public struct SourceLine: Identifiable, Equatable, Sendable {
    public var number: Int
    public var runs: [SourceRun]
    public var id: Int { number }
    public var text: String { runs.map(\.text).joined() }
    public init(number: Int, runs: [SourceRun]) {
        self.number = number
        self.runs = runs
    }
}

/// A file opened in the editor area: its lines highlighted by
/// `YcodeSyntax` (swift-syntax for Swift, the line lexers for the other
/// languages), or a message when it cannot be shown as text.
public struct SourceDocument: Equatable, Sendable {
    public var path: String
    public var language: SyntaxLanguage
    public var lines: [SourceLine]
    /// Why the file is not shown ("Binary file", "Cannot read …"), else nil.
    public var message: String?
    public var name: String { (path as NSString).lastPathComponent }

    /// Lines past this are shown unhighlighted (the read-only view builds a
    /// text per line; EditorKit, L2, replaces it).
    public static let highlightLimit = 20_000
    /// Files larger than this are not shown.
    public static let sizeLimit = 8 << 20
    public static let tabWidth = 4

    public init(path: String, language: SyntaxLanguage, lines: [SourceLine], message: String? = nil) {
        self.path = path
        self.language = language
        self.lines = lines
        self.message = message
    }

    /// Reads and highlights a file.
    public static func load(path: String) -> SourceDocument {
        let language = SyntaxLanguage(fileName: (path as NSString).lastPathComponent)
        guard let data = FileManager.default.contents(atPath: path) else {
            return SourceDocument(path: path, language: language, lines: [], message: "Cannot read \((path as NSString).lastPathComponent)")
        }
        if data.count > sizeLimit {
            return SourceDocument(path: path, language: language, lines: [], message: "File too large to show (\(data.count / 1024) KB)")
        }
        if data.prefix(8192).contains(0) || FindEngine.binaryExtensions.contains((path as NSString).pathExtension.lowercased()) {
            return SourceDocument(path: path, language: language, lines: [], message: "Binary file")
        }
        let text = String(decoding: data, as: UTF8.self)
        return SourceDocument(path: path, language: language, lines: highlight(text, language: language))
    }

    /// Splits `text` into lines of colored runs.
    public static func highlight(_ text: String, language: SyntaxLanguage) -> [SourceLine] {
        let units = Array(text.utf16)
        var starts = [0]
        for (i, u) in units.enumerated() where u == 0x0A { starts.append(i + 1) }
        // A final newline ends the last line; it does not start an empty one.
        if starts.count > 1, starts.last == units.count { starts.removeLast() }
        let lineCount = units.isEmpty ? 1 : starts.count
        let doc: SyntaxDocument? = lineCount <= highlightLimit ? SyntaxDocument(text: text, language: language) : nil
        var lines: [SourceLine] = []
        lines.reserveCapacity(lineCount)
        for n in 0..<lineCount {
            let start = starts[n]
            var end = n + 1 < starts.count ? starts[n + 1] : units.count
            if end > start, units[end - 1] == 0x0A { end -= 1 }
            if end > start, units[end - 1] == 0x0D { end -= 1 }
            let tokens = doc.map { d in n < d.lineCount ? d.tokens(onLine: n) : [] } ?? []
            lines.append(SourceLine(number: n + 1, runs: runs(units, start..<end, tokens: tokens)))
        }
        return lines
    }

    /// The runs of one line: token ranges in their roles, the gaps plain.
    static func runs(_ units: [UInt16], _ line: Range<Int>, tokens: [SyntaxToken]) -> [SourceRun] {
        var out: [SourceRun] = []
        var column = 0
        func add(_ r: Range<Int>, _ role: SyntaxTokenKind.Role?) {
            guard !r.isEmpty else { return }
            let s = expandTabs(String(decoding: units[r], as: UTF16.self), column: &column)
            if let last = out.last, last.role == role {
                out[out.count - 1].text += s
            } else {
                out.append(SourceRun(s, role: role))
            }
        }
        var at = line.lowerBound
        for t in tokens.sorted(by: { $0.location < $1.location }) {
            let a = max(t.location, at), b = min(t.end, line.upperBound)
            guard a < b else { continue }
            add(at..<a, nil)
            let role = t.kind.role == .identifier ? nil : t.kind.role
            add(a..<b, role)
            at = b
        }
        add(at..<line.upperBound, nil)
        return out
    }

    /// Replaces tabs with spaces to the next tab stop; `column` carries the
    /// position across runs.
    static func expandTabs(_ s: String, column: inout Int) -> String {
        guard s.contains("\t") else {
            column += s.count
            return s
        }
        var out = ""
        for ch in s {
            if ch == "\t" {
                let n = tabWidth - column % tabWidth
                out += String(repeating: " ", count: n)
                column += n
            } else {
                out.append(ch)
                column += 1
            }
        }
        return out
    }
}

/// The editor's colors: the selected theme (`Preferences.theme`, as the
/// AppKit editor uses it), with "Ycode Default"'s system colors as the
/// values `WorkspaceChrome.defaultThemeColors` gives for the appearance.
public struct SourcePalette: Equatable, Sendable {
    public var background: ThemeColor
    public var foreground: ThemeColor
    public var currentLine: ThemeColor
    /// The band in a split's pane without focus (the default theme's dark
    /// #2A2A2A, `editor-area.md` F.3; the focused band elsewhere).
    public var unfocusedCurrentLine: ThemeColor
    public var lineNumber: ThemeColor
    public var selection: ThemeColor
    public var tokens: [SyntaxTokenKind.Role: ThemeColor]

    /// The palette of `theme` (default: the selected one) in an appearance.
    public static func forAppearance(dark: Bool, theme: EditorTheme? = nil) -> SourcePalette {
        let theme = theme ?? EditorTheme.builtIns[0]
        let base = WorkspaceChrome.defaultThemeColors(dark: dark)
        let bg = ThemeColor(hex: theme.background) ?? base.background
        let fg = ThemeColor(hex: theme.foreground) ?? base.foreground
        var tokens: [SyntaxTokenKind.Role: ThemeColor] = [:]
        let declarations: Set<SyntaxTokenKind.Role> = [.typeDeclaration, .otherDeclaration, .propertyReference]
        let isDefault = theme.name == EditorTheme.builtIns[0].name && theme.tokens.isEmpty && theme.foreground == nil
        for role in SyntaxTokenKind.Role.allCases {
            // A theme of its own without declaration colours draws type
            // declarations as type names and the rest as plain text.
            let fallback = declarations.contains(role) && !isDefault ? nil : base.tokens[role.rawValue]
            if let c = ThemeColor(hex: theme.tokens[role.rawValue]) ?? fallback { tokens[role] = c }
        }
        if tokens[.typeDeclaration] == nil { tokens[.typeDeclaration] = tokens[.typeName] }
        let own = theme.background != nil
        let band = ThemeColor(hex: theme.currentLine) ?? base.currentLine
        let unfocused = dark && isDefault && theme.currentLine == nil ? ThemeColor(hex: "#2A2A2A")! : band
        return SourcePalette(background: bg, foreground: fg, currentLine: band, unfocusedCurrentLine: unfocused,
                             lineNumber: own ? mix(fg, bg, 0.45) : base.lineNumber,
                             selection: ThemeColor(hex: theme.selection) ?? base.selection, tokens: tokens)
    }

    public func color(_ role: SyntaxTokenKind.Role?) -> ThemeColor {
        role.flatMap { tokens[$0] } ?? foreground
    }

    /// `a` blended towards `b` by `t` (0: `a`).
    static func mix(_ a: ThemeColor, _ b: ThemeColor, _ t: Double) -> ThemeColor {
        func m(_ x: UInt8, _ y: UInt8) -> UInt8 { UInt8((Double(x) * (1 - t) + Double(y) * t).rounded()) }
        return ThemeColor(red: m(a.red, b.red), green: m(a.green, b.green), blue: m(a.blue, b.blue))
    }
}
