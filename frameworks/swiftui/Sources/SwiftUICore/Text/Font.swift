import Foundation

// `Font` (round R4): text styles with the Dynamic Type point sizes of
// 07-text-images-color.md §1.1, system fonts of a fixed size, custom
// families, weights, widths, designs, italic, leading and digit/case
// variants; resolution against the environment (`Font.Context`,
// `Font.Resolved`). Which typeface renders a resolved font is decided by the
// text measurer's font provider (TextMeasurer.swift): OpenViews never uses
// Apple's system fonts.

/// A font.
public struct Font: Hashable, Sendable {
    /// The text styles (07 §1.1).
    public enum TextStyle: String, Hashable, CaseIterable, Sendable {
        case largeTitle, title, title2, title3, headline, subheadline, body, callout, footnote, caption, caption2
    }

    /// A font weight. `value` is the weight on SwiftUI's scale (regular 0,
    /// bold 0.4).
    public struct Weight: Hashable, Sendable {
        public let value: Double
        package init(value: Double) { self.value = value }
        public static let ultraLight = Weight(value: -0.8)
        public static let thin = Weight(value: -0.6)
        public static let light = Weight(value: -0.4)
        public static let regular = Weight(value: 0)
        public static let medium = Weight(value: 0.23)
        public static let semibold = Weight(value: 0.3)
        public static let bold = Weight(value: 0.4)
        public static let heavy = Weight(value: 0.56)
        public static let black = Weight(value: 0.62)

        /// The named weights, lightest first, with their OpenType weight class.
        package static let ladder: [(Weight, Int)] = [
            (.ultraLight, 100), (.thin, 200), (.light, 300), (.regular, 400), (.medium, 500),
            (.semibold, 600), (.bold, 700), (.heavy, 800), (.black, 900),
        ]

        /// OpenType weight class (100…900), interpolated between named weights.
        package var weightClass: Int {
            let l = Weight.ladder
            if value <= l.first!.0.value { return l.first!.1 }
            if value >= l.last!.0.value { return l.last!.1 }
            for i in 1..<l.count where value <= l[i].0.value {
                let (a, b) = (l[i - 1], l[i])
                let t = (value - a.0.value) / (b.0.value - a.0.value)
                return Int((Double(a.1) + t * Double(b.1 - a.1)).rounded())
            }
            return 400
        }

        /// `steps` named weights heavier (negative: lighter).
        package func stepped(by steps: Int) -> Weight {
            let l = Weight.ladder
            let i = l.lastIndex { $0.0.value <= value } ?? 0
            return l[min(max(i + steps, 0), l.count - 1)].0
        }
    }

    /// A font width. Values are ours (the spec names the widths only):
    /// compressed −0.3, condensed −0.2, standard 0, expanded 0.2.
    public struct Width: Hashable, Sendable {
        public var value: CGFloat
        public init(_ value: CGFloat) { self.value = value }
        public static let compressed = Width(-0.3)
        public static let condensed = Width(-0.2)
        public static let standard = Width(0)
        public static let expanded = Width(0.2)

        /// OpenType width class (1…9, 5 normal).
        package var widthClass: Int {
            switch value {
            case ..<(-0.25): return 2
            case ..<(-0.1): return 3
            case ..<0.1: return 5
            default: return 7
            }
        }
    }

    public enum Design: Hashable, Sendable {
        case `default`, serif, rounded, monospaced
    }

    /// Line spacing variants.
    public enum Leading: Hashable, Sendable {
        case standard, tight, loose
    }

    package enum Base: Hashable, Sendable {
        case style(TextStyle)
        case system(size: CGFloat)
        /// A family by name; `relativeTo` nil = fixed size.
        case custom(String, size: CGFloat, relativeTo: TextStyle?)
    }

    package var base: Base
    package var weight: Weight?
    package var width: Width?
    package var design: Design?
    package var isItalic = false
    package var leading: Leading = .standard
    package var isMonospaced = false
    package var isMonospacedDigit = false
    package var smallCapsOptions: SmallCaps = []
    package var pointSizeOverride: CGFloat?
    package var scaleFactor: CGFloat = 1

    package struct SmallCaps: OptionSet, Hashable, Sendable {
        package let rawValue: Int
        package init(rawValue: Int) { self.rawValue = rawValue }
        package static let lowercase = SmallCaps(rawValue: 1)
        package static let uppercase = SmallCaps(rawValue: 2)
    }

    package init(base: Base) { self.base = base }

    public static let largeTitle = Font(base: .style(.largeTitle))
    public static let title = Font(base: .style(.title))
    public static let title2 = Font(base: .style(.title2))
    public static let title3 = Font(base: .style(.title3))
    public static let headline = Font(base: .style(.headline))
    public static let subheadline = Font(base: .style(.subheadline))
    public static let body = Font(base: .style(.body))
    public static let callout = Font(base: .style(.callout))
    public static let footnote = Font(base: .style(.footnote))
    public static let caption = Font(base: .style(.caption))
    public static let caption2 = Font(base: .style(.caption2))
    /// The default font of text (body).
    public static let `default` = Font.body

    public static func system(_ style: TextStyle, design: Design? = nil, weight: Weight? = nil) -> Font {
        var f = Font(base: .style(style))
        f.design = design
        f.weight = weight
        return f
    }

    public static func system(size: CGFloat, weight: Weight? = nil, design: Design? = nil) -> Font {
        var f = Font(base: .system(size: size))
        f.design = design
        f.weight = weight
        return f
    }

    /// A custom family that scales with the body style.
    public static func custom(_ name: String, size: CGFloat) -> Font {
        Font(base: .custom(name, size: size, relativeTo: .body))
    }

    public static func custom(_ name: String, size: CGFloat, relativeTo textStyle: TextStyle) -> Font {
        Font(base: .custom(name, size: size, relativeTo: textStyle))
    }

    public static func custom(_ name: String, fixedSize: CGFloat) -> Font {
        Font(base: .custom(name, size: fixedSize, relativeTo: nil))
    }

    public func weight(_ weight: Weight) -> Font { var f = self; f.weight = weight; return f }
    public func width(_ width: Width) -> Font { var f = self; f.width = width; return f }
    public func bold() -> Font { weight(.bold) }
    public func bold(_ isActive: Bool) -> Font { isActive ? bold() : self }
    public func italic() -> Font { var f = self; f.isItalic = true; return f }
    public func italic(_ isActive: Bool) -> Font { var f = self; f.isItalic = isActive; return f }
    public func monospaced() -> Font { var f = self; f.isMonospaced = true; return f }
    public func monospaced(_ isActive: Bool) -> Font { var f = self; f.isMonospaced = isActive; return f }
    public func monospacedDigit() -> Font { var f = self; f.isMonospacedDigit = true; return f }
    public func smallCaps() -> Font { var f = self; f.smallCapsOptions = [.lowercase, .uppercase]; return f }
    public func smallCaps(_ isActive: Bool) -> Font { isActive ? smallCaps() : self }
    public func lowercaseSmallCaps() -> Font { var f = self; f.smallCapsOptions.insert(.lowercase); return f }
    public func lowercaseSmallCaps(_ isActive: Bool) -> Font { isActive ? lowercaseSmallCaps() : self }
    public func uppercaseSmallCaps() -> Font { var f = self; f.smallCapsOptions.insert(.uppercase); return f }
    public func uppercaseSmallCaps(_ isActive: Bool) -> Font { isActive ? uppercaseSmallCaps() : self }
    public func leading(_ leading: Leading) -> Font { var f = self; f.leading = leading; return f }
    /// The same font at a fixed point size.
    public func pointSize(_ size: CGFloat) -> Font { var f = self; f.pointSizeOverride = size; return f }
    /// The same font scaled by `factor`.
    public func scaled(by factor: CGFloat) -> Font { var f = self; f.scaleFactor *= factor; return f }

    // MARK: Resolution

    /// What resolution reads from the environment.
    public struct Context: Hashable, Sendable, CustomDebugStringConvertible {
        package var dynamicTypeSize: DynamicTypeSize
        package var legibilityWeight: LegibilityWeight?

        package init(dynamicTypeSize: DynamicTypeSize = .large, legibilityWeight: LegibilityWeight? = .regular) {
            self.dynamicTypeSize = dynamicTypeSize
            self.legibilityWeight = legibilityWeight
        }

        public var debugDescription: String {
            "Font.Context(dynamicTypeSize: \(dynamicTypeSize), legibilityWeight: \(String(describing: legibilityWeight)))"
        }
    }

    /// A font resolved for a context.
    public struct Resolved: Hashable, Sendable {
        public let pointSize: CGFloat
        public let weight: Weight
        public let width: CGFloat
        public let isItalic: Bool
        public let isMonospaced: Bool
        public let isLowercaseSmallCaps: Bool
        public let isUppercaseSmallCaps: Bool
        public let leading: Leading
        package let textFont: TextFont

        public var isBold: Bool { weight.value >= Weight.bold.value }
        public var isSmallCaps: Bool { isLowercaseSmallCaps || isUppercaseSmallCaps }
    }

    public func resolve(in context: Context) -> Resolved {
        let f = resolvedTextFont(context)
        return Resolved(pointSize: f.size, weight: f.weight, width: f.width.value, isItalic: f.isItalic,
                        isMonospaced: f.design == .monospaced, isLowercaseSmallCaps: smallCapsOptions.contains(.lowercase),
                        isUppercaseSmallCaps: smallCapsOptions.contains(.uppercase), leading: leading, textFont: f)
    }

    package func resolvedTextFont(_ context: Context) -> TextFont {
        var size: CGFloat
        var weight = self.weight ?? .regular
        var family: String?
        var style: TextStyle?
        switch base {
        case .style(let s):
            size = DynamicTypeTable.pointSize(.init(s), context.dynamicTypeSize)
            if self.weight == nil && s == .headline { weight = .semibold } // 07 §1.1
            style = s
        case .system(let s):
            size = s
        case .custom(let name, let s, let relative):
            family = name
            size = s
            if let r = relative {
                size = s * DynamicTypeTable.pointSize(.init(r), context.dynamicTypeSize)
                    / DynamicTypeTable.pointSize(.init(r), .large)
            }
        }
        if let p = pointSizeOverride { size = p }
        size *= scaleFactor
        if context.legibilityWeight == .bold { weight = weight.stepped(by: 2) }
        return TextFont(size: size, weight: weight, width: width ?? .standard,
                        design: isMonospaced ? .monospaced : (design ?? .default), isItalic: isItalic,
                        family: family, leading: leading, isMonospacedDigit: isMonospacedDigit,
                        smallCaps: smallCapsOptions, textStyle: style)
    }

    package func textFont(in environment: EnvironmentValues) -> TextFont {
        resolvedTextFont(environment.fontResolutionContext)
    }
}

extension EnvironmentValues {
    /// The values font resolution reads.
    public var fontResolutionContext: Font.Context {
        Font.Context(dynamicTypeSize: dynamicTypeSize, legibilityWeight: legibilityWeight)
    }
}

/// Dynamic Type point sizes per text style and size category
/// (07-text-images-color.md §1.1, UIKit's 13 styles; SwiftUI's `title` is
/// `title1`, `caption` is `caption1`, and the two extra-large titles are not
/// SwiftUI styles on iOS).
package enum DynamicTypeTable {
    package enum Style: CaseIterable, Hashable, Sendable {
        case largeTitle, title1, title2, title3, headline, subheadline, body, callout, footnote, caption1, caption2
        case extraLargeTitle, extraLargeTitle2

        package init(_ s: Font.TextStyle) {
            switch s {
            case .largeTitle: self = .largeTitle
            case .title: self = .title1
            case .title2: self = .title2
            case .title3: self = .title3
            case .headline: self = .headline
            case .subheadline: self = .subheadline
            case .body: self = .body
            case .callout: self = .callout
            case .footnote: self = .footnote
            case .caption: self = .caption1
            case .caption2: self = .caption2
            }
        }
    }

    /// Columns: xSmall … xxxLarge, accessibility1 … accessibility5.
    package static let sizes: [Style: [CGFloat]] = [
        .largeTitle: [31, 32, 33, 34, 36, 38, 40, 44, 48, 52, 56, 60],
        .title1: [25, 26, 27, 28, 30, 32, 34, 38, 43, 48, 53, 58],
        .title2: [19, 20, 21, 22, 24, 26, 28, 34, 39, 44, 50, 56],
        .title3: [17, 18, 19, 20, 22, 24, 26, 31, 37, 43, 49, 55],
        .headline: [14, 15, 16, 17, 19, 21, 23, 28, 33, 40, 47, 53],
        .subheadline: [12, 13, 14, 15, 17, 19, 21, 25, 30, 36, 42, 49],
        .body: [14, 15, 16, 17, 19, 21, 23, 28, 33, 40, 47, 53],
        .callout: [13, 14, 15, 16, 18, 20, 22, 26, 32, 38, 44, 51],
        .footnote: [12, 12, 12, 13, 15, 17, 19, 23, 27, 33, 38, 44],
        .caption1: [11, 11, 11, 12, 14, 16, 18, 22, 26, 32, 37, 43],
        .caption2: [11, 11, 11, 11, 13, 15, 17, 20, 24, 29, 34, 40],
        .extraLargeTitle: [33, 34, 35, 36, 38, 40, 42, 44, 46, 48, 50, 52],
        .extraLargeTitle2: [25, 26, 27, 28, 30, 32, 34, 36, 38, 40, 42, 44],
    ]

    package static func pointSize(_ style: Style, _ size: DynamicTypeSize) -> CGFloat {
        sizes[style]![DynamicTypeSize.allCases.firstIndex(of: size)!]
    }

    /// Default weight of a style: headline semibold, the extra-large titles
    /// bold, the others regular (07 §1.1).
    package static func weight(_ style: Style) -> Font.Weight {
        switch style {
        case .headline: return .semibold
        case .extraLargeTitle, .extraLargeTitle2: return .bold
        default: return .regular
        }
    }
}
