import Foundation

// Environment values and view modifiers for text (round R4): line spacing,
// minimum scale factor, tightening, text case, line-limit ranges and
// reserved lines, and the view-level character attributes (`.bold()`,
// `.fontWeight(_:)`, … on any view). `lineLimit`, `multilineTextAlignment`,
// `truncationMode` and `font` are in Environment/EnvironmentKeys.swift.

private enum LineSpacingKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private enum MinimumScaleFactorKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
private enum AllowsTighteningKey: EnvironmentKey { static let defaultValue = false }
private enum TextCaseKey: EnvironmentKey { static let defaultValue: Text.Case? = nil }
private enum LineLimitMinimumKey: EnvironmentKey { static let defaultValue: Int? = nil }
private enum TextAttributesKey: EnvironmentKey { static let defaultValue = TextAttributes() }

extension EnvironmentValues {
    public var lineSpacing: CGFloat {
        get { self[LineSpacingKey.self] }
        set { self[LineSpacingKey.self] = newValue }
    }
    public var minimumScaleFactor: CGFloat {
        get { self[MinimumScaleFactorKey.self] }
        set { self[MinimumScaleFactorKey.self] = newValue }
    }
    public var allowsTightening: Bool {
        get { self[AllowsTighteningKey.self] }
        set { self[AllowsTighteningKey.self] = newValue }
    }
    public var textCase: Text.Case? {
        get { self[TextCaseKey.self] }
        set { self[TextCaseKey.self] = newValue }
    }
    /// Lines a text reserves even when it needs fewer (`lineLimit(_:reservesSpace:)`,
    /// the lower bound of `lineLimit(_:)` with a range).
    package var lineLimitMinimum: Int? {
        get { self[LineLimitMinimumKey.self] }
        set { self[LineLimitMinimumKey.self] = newValue }
    }
    /// Character attributes set by view-level text modifiers.
    package var textAttributes: TextAttributes {
        get { self[TextAttributesKey.self] }
        set { self[TextAttributesKey.self] = newValue }
    }
}

extension View {
    public func lineSpacing(_ lineSpacing: CGFloat) -> some View { environment(\.lineSpacing, lineSpacing) }
    public func minimumScaleFactor(_ factor: CGFloat) -> some View { environment(\.minimumScaleFactor, factor) }
    public func allowsTightening(_ flag: Bool) -> some View { environment(\.allowsTightening, flag) }
    public func textCase(_ textCase: Text.Case?) -> some View { environment(\.textCase, textCase) }

    /// At most `limit` lines; with `reservesSpace`, always as tall as `limit` lines.
    public func lineLimit(_ limit: Int, reservesSpace: Bool) -> some View {
        environment(\.lineLimit, limit).environment(\.lineLimitMinimum, reservesSpace ? limit : nil)
    }

    /// Between `limits.lowerBound` (reserved) and `limits.upperBound` lines.
    public func lineLimit(_ limits: ClosedRange<Int>) -> some View {
        environment(\.lineLimit, limits.upperBound).environment(\.lineLimitMinimum, limits.lowerBound)
    }

    public func lineLimit(_ limits: PartialRangeFrom<Int>) -> some View {
        environment(\.lineLimit, nil).environment(\.lineLimitMinimum, limits.lowerBound)
    }

    public func lineLimit(_ limits: PartialRangeThrough<Int>) -> some View {
        environment(\.lineLimit, limits.upperBound).environment(\.lineLimitMinimum, nil)
    }

    private func textAttribute(_ apply: (inout TextAttributes) -> Void) -> some View {
        var inner = TextAttributes()
        apply(&inner)
        // Inner settings win: an outer modifier only fills what is unset.
        return modifier(EnvironmentTransformModifier(label: "textAttributes", value: inner) {
            $0.textAttributes = inner.merged(under: $0.textAttributes)
        })
    }

    public func fontWeight(_ weight: Font.Weight?) -> some View { textAttribute { $0.weight = weight } }
    public func fontWidth(_ width: Font.Width?) -> some View { textAttribute { $0.width = width } }
    public func fontDesign(_ design: Font.Design?) -> some View { textAttribute { $0.design = design } }
    public func bold(_ isActive: Bool = true) -> some View { textAttribute { $0.isBold = isActive } }
    public func italic(_ isActive: Bool = true) -> some View { textAttribute { $0.isItalic = isActive } }
    public func monospaced(_ isActive: Bool = true) -> some View { textAttribute { $0.isMonospaced = isActive } }
    public func monospacedDigit() -> some View { textAttribute { $0.isMonospacedDigit = true } }
    public func kerning(_ kerning: CGFloat) -> some View { textAttribute { $0.kerning = kerning } }
    public func tracking(_ tracking: CGFloat) -> some View { textAttribute { $0.tracking = tracking } }
    public func baselineOffset(_ offset: CGFloat) -> some View { textAttribute { $0.baselineOffset = offset } }
    public func underline(_ isActive: Bool = true, pattern: Text.LineStyle.Pattern = .solid,
                          color: Color? = nil) -> some View {
        textAttribute { $0.underline = isActive ? Text.LineStyle(pattern: pattern, color: color) : nil }
    }
    public func strikethrough(_ isActive: Bool = true, pattern: Text.LineStyle.Pattern = .solid,
                              color: Color? = nil) -> some View {
        textAttribute { $0.strikethrough = isActive ? Text.LineStyle(pattern: pattern, color: color) : nil }
    }
}
