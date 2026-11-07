import AppKit
import YcodeIDECore

/// Editor colors and fonts. Ycode's own default theme, built from system
/// colors so it follows light and dark appearance. See
/// `specs/ide/source-editor.md` §Syntax coloring; token kinds map to the
/// theme's color roles (`SyntaxTokenKind.role`).
@MainActor
public enum Theme {
    /// The selected theme (Settings ▸ Themes).
    public static var current: EditorTheme { Preferences.shared.theme }
    /// The theme's font at Editor ▸ Font Size's size, if one is set.
    public static var font: NSFont { cellAdvance(baseFont) }
    /// The theme's font at Editor ▸ Font Size's size, as the theme names it.
    static var baseFont: NSFont {
        let f = current.font
        guard let size = Preferences.shared.sourceFontSize, CGFloat(size) != f.pointSize else { return f }
        return NSFont(descriptor: f.fontDescriptor, size: CGFloat(size)) ?? f
    }
    public static var boldFont: NSFont {
        cellAdvance(NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask), like: baseFont)
    }
    /// The source line pitch: 18 at 13 points (`editor-area.md` §C.1).
    public static var lineHeight: CGFloat { CGFloat(EditorMetrics.lineHeight(fontSize: Double(font.pointSize))) }
    /// One character's advance in the source font.
    public static var advance: CGFloat { ("0" as NSString).size(withAttributes: [.font: font]).width }

    /// The display scale the editor's cells are laid out for: the scale of
    /// the display an editor last moved to (at first the main screen's; a
    /// test may set its own).
    static var backingScale: CGFloat { backingScaleOverride ?? displayScale }
    static var backingScaleOverride: CGFloat?
    static var displayScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2

    /// An editor's window is on a display of scale `s`: when that changes
    /// the cell, every editor applies its settings again (one cell for
    /// all, so columns never mix advances).
    static func noteDisplayScale(_ s: CGFloat) {
        guard s > 0, s != displayScale else { return }
        displayScale = s
        guard backingScaleOverride == nil else { return }
        DispatchQueue.main.async { NotificationCenter.default.post(name: displayScaleDidChange, object: nil) }
    }
    public static let displayScaleDidChange = Notification.Name("YcodeEditorDisplayScaleDidChange")

    /// `f` with every glyph advancing one cell, the advance `like`'s (or
    /// its own) at the backing scale: unrounded at 2x (8.04 at 13 points,
    /// `editor-area.md` F.2), whole pixels at 1x (8.0, §C.1), so columns
    /// line up and never drift.
    static func cellAdvance(_ f: NSFont, like base: NSFont? = nil) -> NSFont {
        let scale = backingScale
        let key = "\(f.fontName) \(f.pointSize) \(base?.fontName ?? "") \(scale)"
        if let cached = advanceFonts[key] { return cached }
        let own = ("0" as NSString).size(withAttributes: [.font: base ?? f]).width
        let target = CGFloat(EditorTextGeometry.cellAdvance(fontAdvance: Double(own), backingScale: Double(scale)))
        var out = f
        if f.isFixedPitch || base?.isFixedPitch == true, abs(target - own) > 0.001 {
            let d = f.fontDescriptor.addingAttributes([.fixedAdvance: target])
            out = NSFont(descriptor: d, size: f.pointSize) ?? f
        }
        advanceFonts[key] = out
        return out
    }
    private static var advanceFonts: [String: NSFont] = [:]
    public static var consoleFont: NSFont { current.consoleFont }
    public static var textColor: NSColor {
        EditorTheme.color(current.foreground) ?? (DefaultTheme.applies ? DefaultTheme.plain : .textColor)
    }
    /// Line numbers (`editor-area.md` §C.2, F.3); the current line's
    /// number is drawn in `textColor`.
    public static var lineNumberColor: NSColor { DefaultTheme.applies ? DefaultTheme.lineNumber : .secondaryLabelColor }
    /// The editor's background: #262626 in dark for the default theme (F.3).
    public static var backgroundColor: NSColor {
        EditorTheme.color(current.background) ?? (DefaultTheme.applies ? DefaultTheme.background : .textBackgroundColor)
    }
    public static var selectionColor: NSColor { EditorTheme.color(current.selection) ?? .selectedTextBackgroundColor }
    public static var consoleTextColor: NSColor { EditorTheme.color(current.consoleText) ?? .textColor }
    public static var consoleBackgroundColor: NSColor { EditorTheme.color(current.consoleBackground) ?? .textBackgroundColor }
    /// Line numbers: a smaller face than the code (`editor-area.md` §C.2).
    public static var gutterFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: CGFloat(EditorMetrics.lineNumberFontSize(sourceSize: Double(font.pointSize))), weight: .regular)
    }

    public static func color(for kind: SourceTokenizer.Kind) -> NSColor {
        if let c = EditorTheme.color(current.tokens[kind.rawValue]) { return c }
        if kind == .identifier { return textColor }
        if DefaultTheme.applies { return DefaultTheme.color(for: kind, fallback: systemColor(for: kind)) }
        return systemColor(for: kind)
    }

    /// A role's colour where no theme value is measured or set. A theme
    /// without declaration colours draws type declarations as type names
    /// and the other declarations and references as plain text.
    static func systemColor(for kind: SourceTokenizer.Kind) -> NSColor {
        return switch kind {
        case .typeDeclaration: EditorTheme.color(current.tokens[SourceTokenizer.Kind.typeName.rawValue]) ?? .systemPurple
        case .otherDeclaration, .propertyReference: textColor
        case .keyword: .systemPink
        case .comment: .secondaryLabelColor
        case .docComment: .systemGreen
        case .string: .systemRed
        case .number: .systemBlue
        case .preprocessor: .systemOrange
        case .attribute: .systemBrown
        case .typeName: .systemPurple
        case .identifier: .textColor
        }
    }

    /// A token kind's font: its own from the theme's Fonts, else bold for
    /// keywords, else nil (the source font). Editor ▸ Font Size applies on
    /// top: a token font changes by the same amount as the source font.
    public static func font(for kind: SourceTokenizer.Kind) -> NSFont? {
        if let f = current.tokenFonts?[kind.rawValue] {
            let base = f.font
            guard let size = Preferences.shared.sourceFontSize else { return base }
            let scaled = max(Preferences.fontSizeRange.lowerBound, f.size + size - current.fontSize)
            return NSFont(descriptor: base.fontDescriptor, size: CGFloat(scaled)) ?? base
        }
        return kind == .keyword ? boldFont : nil
    }

    public static let errorColor = NSColor.systemRed
    public static let warningColor = NSColor.systemYellow
    public static let breakpointColor = NSColor.systemBlue
    /// The insertion point's line: a neutral band, #EEEEEE on white
    /// (`editor-area.md` §C.2); the default theme's measured band in dark,
    /// fainter in a split's pane without focus (F.3).
    public static var currentLineBandColor: NSColor { currentLineBandColor(focused: true) }
    public static func currentLineBandColor(focused: Bool) -> NSColor {
        DefaultTheme.applies ? DefaultTheme.band(focused: focused, neutral: neutralBand) : neutralBand
    }
    static let neutralBand = NSColor.labelColor.withAlphaComponent(0.067)
    public static var currentLineColor: NSColor { EditorTheme.color(current.currentLine) ?? NSColor.systemGreen.withAlphaComponent(0.25) }

    /// Placeholder tokens: the `<#` / `#>` delimiters collapse to nothing
    /// visible; the text is drawn on a rounded token by the text view.
    public static func stylePlaceholders(_ storage: NSTextStorage) {
        let hidden: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear]
        for r in Placeholders.ranges(in: storage.string) {
            storage.addAttributes(hidden, range: NSRange(location: r.location, length: 2))
            storage.addAttributes(hidden, range: NSRange(location: NSMaxRange(r) - 2, length: 2))
            storage.addAttributes([.foregroundColor: placeholderTextColor, .font: font],
                                  range: NSRange(location: r.location + 2, length: r.length - 4))
        }
    }

    public static let placeholderTextColor = NSColor.labelColor
    /// Predictive completion's ghost text: the text color, faded.
    public static var ghostTextColor: NSColor { textColor.withAlphaComponent(0.4) }
    public static let placeholderFill = NSColor.systemBlue.withAlphaComponent(0.18)
    public static let placeholderSelectedFill = NSColor.systemBlue.withAlphaComponent(0.45)

    /// A highlighting token's color: its theme role's.
    public static func color(forToken kind: SyntaxTokenKind) -> NSColor { color(for: kind.role) }

    /// A highlighting token's font: its role's, with Markdown's strong
    /// text bold and emphasis italic.
    public static func font(forToken kind: SyntaxTokenKind) -> NSFont? {
        switch kind {
        case .strong: return boldFont
        case .emphasis: return NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        default: return font(for: kind.role)
        }
    }

    /// Colors `range` (whole lines; nil: all) of `storage` from the
    /// document's tokens (`YcodeSyntax`); nil document: plain text.
    public static func apply(_ doc: SyntaxDocument?, to storage: NSTextStorage, range: Range<Int>? = nil) {
        let all = 0..<storage.length
        let r = range.map { max(0, $0.lowerBound)..<min(storage.length, $0.upperBound) } ?? all
        guard !r.isEmpty || r == all else { return }
        let ns = NSRange(location: r.lowerBound, length: r.count)
        storage.beginEditing()
        // Font and color replaced; the paragraph style stays. The theme is
        // resolved once per kind (reading it lists the themes folder).
        let base = font
        storage.addAttributes([.font: base, .foregroundColor: textColor], range: ns)
        if let doc, doc.units.count == storage.length, !r.isEmpty {
            var styles: [SyntaxTokenKind: [NSAttributedString.Key: Any]] = [:]
            for t in doc.tokens(in: r) where t.kind.role != .identifier {
                let tr = NSIntersectionRange(t.range, ns)
                guard tr.length > 0 else { continue }
                if styles[t.kind] == nil { styles[t.kind] = [.foregroundColor: color(forToken: t.kind), .font: font(forToken: t.kind) ?? base] }
                storage.addAttributes(styles[t.kind]!, range: tr)
            }
        }
        if range == nil { stylePlaceholders(storage) } else { stylePlaceholders(storage, in: ns) }
        fixCellWidths(storage, in: ns)
        storage.endEditing()
    }

    /// Placeholder styling limited to a region.
    static func stylePlaceholders(_ storage: NSTextStorage, in region: NSRange) {
        let hidden: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear]
        let text = (storage.string as NSString).substring(with: region)
        for p in Placeholders.ranges(in: text) {
            let r = NSRange(location: p.location + region.location, length: p.length)
            storage.addAttributes(hidden, range: NSRange(location: r.location, length: 2))
            storage.addAttributes(hidden, range: NSRange(location: NSMaxRange(r) - 2, length: 2))
            storage.addAttributes([.foregroundColor: placeholderTextColor, .font: font], range: NSRange(location: r.location + 2, length: r.length - 4))
        }
    }

    /// Applies coloring for the whole text (a fresh lexical pass; the
    /// editor keeps its own `SyntaxDocument`).
    public static func highlight(_ storage: NSTextStorage, language: SourceTokenizer.Language) {
        apply(language == .plain ? nil : SyntaxDocument(text: storage.string, language: language), to: storage)
    }
}
