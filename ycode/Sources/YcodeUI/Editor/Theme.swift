import AppKit

/// Editor colors and fonts. Ycode's own default theme, built from system
/// colors so it follows light and dark appearance. See
/// `specs/ide/source-editor.md` §Syntax coloring.
@MainActor
public enum Theme {
    /// The selected theme (Settings ▸ Themes).
    public static var current: EditorTheme { Preferences.shared.theme }
    /// The theme's font at Editor ▸ Font Size's size, if one is set.
    public static var font: NSFont {
        let f = current.font
        guard let size = Preferences.shared.sourceFontSize, CGFloat(size) != f.pointSize else { return f }
        return NSFont(descriptor: f.fontDescriptor, size: CGFloat(size)) ?? f
    }
    public static var boldFont: NSFont { NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
    public static var consoleFont: NSFont { current.consoleFont }
    public static var textColor: NSColor { EditorTheme.color(current.foreground) ?? .textColor }
    public static var backgroundColor: NSColor { EditorTheme.color(current.background) ?? .textBackgroundColor }
    public static var selectionColor: NSColor { EditorTheme.color(current.selection) ?? .selectedTextBackgroundColor }
    public static var consoleTextColor: NSColor { EditorTheme.color(current.consoleText) ?? .textColor }
    public static var consoleBackgroundColor: NSColor { EditorTheme.color(current.consoleBackground) ?? .textBackgroundColor }
    public static var gutterFont: NSFont { NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular) }

    public static func color(for kind: SourceTokenizer.Kind) -> NSColor {
        if let c = EditorTheme.color(current.tokens[kind.rawValue]) { return c }
        if kind == .identifier { return textColor }
        return switch kind {
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
    public static let placeholderFill = NSColor.systemBlue.withAlphaComponent(0.18)
    public static let placeholderSelectedFill = NSColor.systemBlue.withAlphaComponent(0.45)

    /// Applies coloring for the whole text and returns the ranges of
    /// tokens that span lines (block comments, multi-line strings), which
    /// incremental re-highlighting must not cut through.
    @discardableResult
    public static func highlightReturningMultiline(_ storage: NSTextStorage, language: SourceTokenizer.Language) -> [NSRange] {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: textColor], range: full)
        var multi: [NSRange] = []
        let ns = storage.string as NSString
        for t in SourceTokenizer(language: language).tokens(in: storage.string) where NSMaxRange(t.range) <= storage.length {
            storage.addAttribute(.foregroundColor, value: color(for: t.kind), range: t.range)
            if let f = font(for: t.kind) { storage.addAttribute(.font, value: f, range: t.range) }
            if t.range.length > 1, ns.rangeOfCharacter(from: .newlines, options: [], range: t.range).location != NSNotFound { multi.append(t.range) }
        }
        stylePlaceholders(storage)
        storage.endEditing()
        return multi
    }

    /// Re-colors only `region` (whole lines). The caller guarantees the
    /// region does not start inside or overlap a multi-line token.
    public static func highlight(_ storage: NSTextStorage, language: SourceTokenizer.Language, region: NSRange) {
        guard NSMaxRange(region) <= storage.length else { return highlight(storage, language: language) }
        let ns = storage.string as NSString
        let text = ns.substring(with: region)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: textColor], range: region)
        for t in SourceTokenizer(language: language).tokens(in: text) where NSMaxRange(t.range) <= region.length {
            let r = NSRange(location: t.range.location + region.location, length: t.range.length)
            storage.addAttribute(.foregroundColor, value: color(for: t.kind), range: r)
            if let f = font(for: t.kind) { storage.addAttribute(.font, value: f, range: r) }
        }
        stylePlaceholders(storage, in: region)
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

    /// Applies coloring for the whole text.
    public static func highlight(_ storage: NSTextStorage, language: SourceTokenizer.Language) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: textColor], range: full)
        for t in SourceTokenizer(language: language).tokens(in: storage.string) where NSMaxRange(t.range) <= storage.length {
            storage.addAttribute(.foregroundColor, value: color(for: t.kind), range: t.range)
            if let f = font(for: t.kind) { storage.addAttribute(.font, value: f, range: t.range) }
        }
        stylePlaceholders(storage)
        storage.endEditing()
    }
}
