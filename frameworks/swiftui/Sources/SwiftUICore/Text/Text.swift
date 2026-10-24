import Foundation

// `Text` (round R4): a sequence of styled segments. `Text + Text`
// concatenates segments; a modifier applied to a `Text` styles every segment
// that does not set that attribute itself (the innermost setting wins:
// `(Text("a").font(.body) + Text("b")).font(.title)` sets only "b" in the
// title font). View-level text modifiers (`.bold()`, `.fontWeight(_:)`, …
// on any view) write the same attributes into the environment, where they
// apply below segment and `Text` settings. Lowering resolves fonts against
// the environment (Dynamic Type, legibility weight) and hands the runs and
// the paragraph settings to the layout engine's text leaf.

/// Character-level attributes of a text segment. nil = not set here.
package struct TextAttributes: Hashable, Sendable {
    package var font: Font?
    package var weight: Font.Weight?
    package var width: Font.Width?
    package var design: Font.Design?
    package var isItalic: Bool?
    package var isBold: Bool?
    package var isMonospaced: Bool?
    package var isMonospacedDigit: Bool?
    package var kerning: CGFloat?
    package var tracking: CGFloat?
    package var baselineOffset: CGFloat?
    package var underline: Text.LineStyle?
    package var strikethrough: Text.LineStyle?
    package var foregroundColor: Color?

    package init() {}

    /// Fills attributes not set here from `outer`.
    package func merged(under outer: TextAttributes) -> TextAttributes {
        var r = self
        r.font = font ?? outer.font
        r.weight = weight ?? outer.weight
        r.width = width ?? outer.width
        r.design = design ?? outer.design
        r.isItalic = isItalic ?? outer.isItalic
        r.isBold = isBold ?? outer.isBold
        r.isMonospaced = isMonospaced ?? outer.isMonospaced
        r.isMonospacedDigit = isMonospacedDigit ?? outer.isMonospacedDigit
        r.kerning = kerning ?? outer.kerning
        r.tracking = tracking ?? outer.tracking
        r.baselineOffset = baselineOffset ?? outer.baselineOffset
        r.underline = underline ?? outer.underline
        r.strikethrough = strikethrough ?? outer.strikethrough
        r.foregroundColor = foregroundColor ?? outer.foregroundColor
        return r
    }

    /// The font these attributes select in `environment` (whose `font` is the
    /// default when no segment font is set).
    package func textFont(in environment: EnvironmentValues) -> TextFont {
        var f = font ?? environment.font ?? .body
        if let w = weight { f.weight = w }
        if isBold == true, (f.weight ?? .regular).value < Font.Weight.bold.value { f.weight = .bold }
        if let w = width { f.width = w }
        if let d = design { f.design = d }
        if let i = isItalic { f.isItalic = i }
        if let m = isMonospaced { f.isMonospaced = m }
        if isMonospacedDigit == true { f.isMonospacedDigit = true }
        return f.textFont(in: environment)
    }
}

/// A view that displays text.
public struct Text: Equatable, Sendable {
    package enum Content: Equatable, Sendable {
        case verbatim(String)
        case localized(LocalizedStringKey, table: String?, bundle: BundleReference?)
    }

    package struct Segment: Equatable, Sendable {
        package var content: Content
        package var attributes = TextAttributes()

        /// The text as written (localization happens when the text is laid out).
        package var string: String {
            switch content {
            case .verbatim(let s): return s
            case .localized(let k, _, _): return k.resolved
            }
        }
    }

    package var segments: [Segment]

    public init(verbatim content: String) { segments = [Segment(content: .verbatim(content))] }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ content: S) { segments = [Segment(content: .verbatim(String(content)))] }

    public init(_ key: LocalizedStringKey, tableName: String? = nil, bundle: Bundle? = nil, comment: StaticString? = nil) {
        segments = [Segment(content: .localized(key, table: tableName, bundle: bundle.map(BundleReference.init)))]
    }

    /// The concatenated text as written.
    package var string: String { segments.map(\.string).joined() }

    /// How text is truncated when it does not fit.
    public enum TruncationMode: Hashable, Sendable {
        case head, middle, tail
    }

    /// Case transformation (`textCase(_:)`).
    public enum Case: Hashable, Sendable {
        case uppercase, lowercase
    }

    /// Underline and strikethrough styles (rendering only).
    public struct LineStyle: Hashable, Sendable {
        public struct Pattern: Hashable, Sendable {
            let name: String
            public static let solid = Pattern(name: "solid")
            public static let dot = Pattern(name: "dot")
            public static let dash = Pattern(name: "dash")
            public static let dashDot = Pattern(name: "dashDot")
            public static let dashDotDot = Pattern(name: "dashDotDot")
        }

        public var pattern: Pattern
        public var color: Color?

        public init(pattern: Pattern = .solid, color: Color? = nil) {
            self.pattern = pattern
            self.color = color
        }

        public static let single = LineStyle()
    }

    public typealias Body = Never

    // MARK: Concatenation and styling

    public static func + (lhs: Text, rhs: Text) -> Text {
        var t = lhs
        t.segments += rhs.segments
        return t
    }

    /// Sets `attribute` on every segment that does not set it.
    private func styled(_ apply: (inout TextAttributes) -> Void) -> Text {
        var t = self
        for i in t.segments.indices {
            var outer = TextAttributes()
            apply(&outer)
            t.segments[i].attributes = t.segments[i].attributes.merged(under: outer)
        }
        return t
    }

    public func font(_ font: Font?) -> Text { styled { $0.font = font } }
    public func fontWeight(_ weight: Font.Weight?) -> Text { styled { $0.weight = weight } }
    public func fontWidth(_ width: Font.Width?) -> Text { styled { $0.width = width } }
    public func fontDesign(_ design: Font.Design?) -> Text { styled { $0.design = design } }
    public func bold() -> Text { bold(true) }
    public func bold(_ isActive: Bool) -> Text { styled { $0.isBold = isActive } }
    public func italic() -> Text { italic(true) }
    public func italic(_ isActive: Bool) -> Text { styled { $0.isItalic = isActive } }
    public func monospaced(_ isActive: Bool = true) -> Text { styled { $0.isMonospaced = isActive } }
    public func monospacedDigit() -> Text { styled { $0.isMonospacedDigit = true } }
    public func kerning(_ kerning: CGFloat) -> Text { styled { $0.kerning = kerning } }
    public func tracking(_ tracking: CGFloat) -> Text { styled { $0.tracking = tracking } }
    public func baselineOffset(_ offset: CGFloat) -> Text { styled { $0.baselineOffset = offset } }
    public func underline(_ isActive: Bool = true, color: Color? = nil) -> Text {
        underline(isActive, pattern: .solid, color: color)
    }
    public func underline(_ isActive: Bool = true, pattern: LineStyle.Pattern, color: Color? = nil) -> Text {
        styled { $0.underline = isActive ? LineStyle(pattern: pattern, color: color) : nil }
    }
    public func strikethrough(_ isActive: Bool = true, color: Color? = nil) -> Text {
        strikethrough(isActive, pattern: .solid, color: color)
    }
    public func strikethrough(_ isActive: Bool = true, pattern: LineStyle.Pattern, color: Color? = nil) -> Text {
        styled { $0.strikethrough = isActive ? LineStyle(pattern: pattern, color: color) : nil }
    }
    public func foregroundColor(_ color: Color?) -> Text { styled { $0.foregroundColor = color } }
    public func foregroundStyle(_ color: Color) -> Text { foregroundColor(color) }
}

/// A `Bundle` held by identity (Text stays `Equatable` and `Sendable`).
package struct BundleReference: Equatable, @unchecked Sendable {
    package let bundle: Bundle
    package init(_ b: Bundle) { bundle = b }
    package static func == (a: BundleReference, b: BundleReference) -> Bool { a.bundle === b.bundle }
}

extension Text: View {}

extension Text: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: Text?, transaction: Transaction) {}

    package func _lower(node: ViewNode) -> [LayoutNode] {
        [.text(resolve(in: node.environment))]
    }

    /// The runs and paragraph settings of this text in `environment`.
    package func resolve(in environment: EnvironmentValues) -> ResolvedText {
        let outer = environment.textAttributes
        let runs = segments.map { seg -> ResolvedText.Run in
            let a = seg.attributes.merged(under: outer)
            var s = TextLocalization.string(for: seg.content, in: environment)
            switch environment.textCase {
            case .uppercase?: s = s.uppercased(with: environment.locale)
            case .lowercase?: s = s.lowercased(with: environment.locale)
            case nil: break
            }
            return ResolvedText.Run(string: s, font: a.textFont(in: environment),
                                    tracking: a.tracking ?? 0, kerning: a.kerning ?? 0,
                                    baselineOffset: a.baselineOffset ?? 0)
        }
        return ResolvedText(runs: runs, paragraph: ResolvedText.Paragraph(environment: environment))
    }
}
