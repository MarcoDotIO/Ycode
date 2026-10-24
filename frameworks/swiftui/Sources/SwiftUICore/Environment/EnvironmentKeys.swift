import Foundation

// Environment values whose defaults 08-environment-accessibility-localization.md
// §1 lists (the values an app read at the scene root of the reference
// device). Platform hosts (R7, R10) replace them with live values.

/// Size classes.
public enum UserInterfaceSizeClass: Hashable, Sendable {
    case compact
    case regular
}

/// Horizontal alignment of lines of text.
public enum TextAlignment: Hashable, CaseIterable, Sendable {
    case leading
    case center
    case trailing
}

/// Font weight adjustment for legibility (Bold Text setting).
public enum LegibilityWeight: Hashable, Sendable {
    case regular
    case bold
}

/// Size of controls.
public enum ControlSize: Hashable, CaseIterable, Sendable {
    case mini
    case small
    case regular
    case large
    case extraLarge
}

/// Reasons to redact content.
public struct RedactionReasons: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let placeholder = RedactionReasons(rawValue: 1 << 0)
    public static let privacy = RedactionReasons(rawValue: 1 << 1)
    public static let invalidated = RedactionReasons(rawValue: 1 << 2)
}

private enum IsEnabledKey: EnvironmentKey { static let defaultValue = true }
private enum LocaleKey: EnvironmentKey { static var defaultValue: Locale { Locale(identifier: "en_US") } }
private enum CalendarKey: EnvironmentKey { static var defaultValue: Calendar { Calendar(identifier: .gregorian) } }
private enum TimeZoneKey: EnvironmentKey { static var defaultValue: TimeZone { TimeZone.current } }
private enum HorizontalSizeClassKey: EnvironmentKey { static let defaultValue: UserInterfaceSizeClass? = .compact }
private enum VerticalSizeClassKey: EnvironmentKey { static let defaultValue: UserInterfaceSizeClass? = .regular }
private enum FontKey: EnvironmentKey { static let defaultValue: Font? = nil }
private enum LineLimitKey: EnvironmentKey { static let defaultValue: Int? = nil }
private enum MultilineTextAlignmentKey: EnvironmentKey { static let defaultValue = TextAlignment.leading }
private enum TruncationModeKey: EnvironmentKey { static let defaultValue = Text.TruncationMode.tail }
private enum LegibilityWeightKey: EnvironmentKey { static let defaultValue: LegibilityWeight? = .regular }
private enum ControlSizeKey: EnvironmentKey { static let defaultValue = ControlSize.regular }
private enum ImageScaleKey: EnvironmentKey { static let defaultValue = Image.Scale.medium }
private enum RedactionReasonsKey: EnvironmentKey { static let defaultValue: RedactionReasons = [] }
private enum DefaultMinListRowHeightKey: EnvironmentKey { static let defaultValue: CGFloat = 52 }
private enum DefaultMinListHeaderHeightKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }

private enum AccessibilityEnabledKey: EnvironmentKey { static let defaultValue = false }
private enum ReduceMotionKey: EnvironmentKey { static let defaultValue = false }
private enum ReduceTransparencyKey: EnvironmentKey { static let defaultValue = false }
private enum DifferentiateWithoutColorKey: EnvironmentKey { static let defaultValue = false }
private enum InvertColorsKey: EnvironmentKey { static let defaultValue = false }
private enum ShowButtonShapesKey: EnvironmentKey { static let defaultValue = false }
private enum VoiceOverEnabledKey: EnvironmentKey { static let defaultValue = false }
private enum SwitchControlEnabledKey: EnvironmentKey { static let defaultValue = false }
private enum IsLuminanceReducedKey: EnvironmentKey { static let defaultValue = false }
private enum SupportsMultipleWindowsKey: EnvironmentKey { static let defaultValue = false }
private enum IsSceneCapturedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    public var isEnabled: Bool {
        get { self[IsEnabledKey.self] }
        set { self[IsEnabledKey.self] = newValue }
    }
    public var locale: Locale {
        get { self[LocaleKey.self] }
        set { self[LocaleKey.self] = newValue }
    }
    public var calendar: Calendar {
        get { self[CalendarKey.self] }
        set { self[CalendarKey.self] = newValue }
    }
    public var timeZone: TimeZone {
        get { self[TimeZoneKey.self] }
        set { self[TimeZoneKey.self] = newValue }
    }
    public var horizontalSizeClass: UserInterfaceSizeClass? {
        get { self[HorizontalSizeClassKey.self] }
        set { self[HorizontalSizeClassKey.self] = newValue }
    }
    public var verticalSizeClass: UserInterfaceSizeClass? {
        get { self[VerticalSizeClassKey.self] }
        set { self[VerticalSizeClassKey.self] = newValue }
    }
    /// The default font of text in this environment (nil: body).
    public var font: Font? {
        get { self[FontKey.self] }
        set { self[FontKey.self] = newValue }
    }
    public var lineLimit: Int? {
        get { self[LineLimitKey.self] }
        set { self[LineLimitKey.self] = newValue }
    }
    public var multilineTextAlignment: TextAlignment {
        get { self[MultilineTextAlignmentKey.self] }
        set { self[MultilineTextAlignmentKey.self] = newValue }
    }
    public var truncationMode: Text.TruncationMode {
        get { self[TruncationModeKey.self] }
        set { self[TruncationModeKey.self] = newValue }
    }
    public var legibilityWeight: LegibilityWeight? {
        get { self[LegibilityWeightKey.self] }
        set { self[LegibilityWeightKey.self] = newValue }
    }
    public var controlSize: ControlSize {
        get { self[ControlSizeKey.self] }
        set { self[ControlSizeKey.self] = newValue }
    }
    public var imageScale: Image.Scale {
        get { self[ImageScaleKey.self] }
        set { self[ImageScaleKey.self] = newValue }
    }
    public var redactionReasons: RedactionReasons {
        get { self[RedactionReasonsKey.self] }
        set { self[RedactionReasonsKey.self] = newValue }
    }
    public var defaultMinListRowHeight: CGFloat {
        get { self[DefaultMinListRowHeightKey.self] }
        set { self[DefaultMinListRowHeightKey.self] = newValue }
    }
    public var defaultMinListHeaderHeight: CGFloat? {
        get { self[DefaultMinListHeaderHeightKey.self] }
        set { self[DefaultMinListHeaderHeightKey.self] = newValue }
    }
    public var accessibilityEnabled: Bool {
        get { self[AccessibilityEnabledKey.self] }
        set { self[AccessibilityEnabledKey.self] = newValue }
    }
    public var accessibilityReduceMotion: Bool {
        get { self[ReduceMotionKey.self] }
        set { self[ReduceMotionKey.self] = newValue }
    }
    public var accessibilityReduceTransparency: Bool {
        get { self[ReduceTransparencyKey.self] }
        set { self[ReduceTransparencyKey.self] = newValue }
    }
    public var accessibilityDifferentiateWithoutColor: Bool {
        get { self[DifferentiateWithoutColorKey.self] }
        set { self[DifferentiateWithoutColorKey.self] = newValue }
    }
    public var accessibilityInvertColors: Bool {
        get { self[InvertColorsKey.self] }
        set { self[InvertColorsKey.self] = newValue }
    }
    public var accessibilityShowButtonShapes: Bool {
        get { self[ShowButtonShapesKey.self] }
        set { self[ShowButtonShapesKey.self] = newValue }
    }
    public var accessibilityVoiceOverEnabled: Bool {
        get { self[VoiceOverEnabledKey.self] }
        set { self[VoiceOverEnabledKey.self] = newValue }
    }
    public var accessibilitySwitchControlEnabled: Bool {
        get { self[SwitchControlEnabledKey.self] }
        set { self[SwitchControlEnabledKey.self] = newValue }
    }
    public var isLuminanceReduced: Bool {
        get { self[IsLuminanceReducedKey.self] }
        set { self[IsLuminanceReducedKey.self] = newValue }
    }
    public var supportsMultipleWindows: Bool {
        get { self[SupportsMultipleWindowsKey.self] }
        set { self[SupportsMultipleWindowsKey.self] = newValue }
    }
    public var isSceneCaptured: Bool {
        get { self[IsSceneCapturedKey.self] }
        set { self[IsSceneCapturedKey.self] = newValue }
    }
}

// MARK: - Modifiers that write environment values

extension View {
    /// Sets the default font for text in this view (03 §6: inner overrides outer).
    public func font(_ font: Font?) -> some View { environment(\.font, font) }

    public func lineLimit(_ number: Int?) -> some View { environment(\.lineLimit, number) }

    public func multilineTextAlignment(_ alignment: TextAlignment) -> some View {
        environment(\.multilineTextAlignment, alignment)
    }

    public func truncationMode(_ mode: Text.TruncationMode) -> some View { environment(\.truncationMode, mode) }

    public func disabled(_ disabled: Bool) -> some View {
        transformEnvironment(\.isEnabled) { if disabled { $0 = false } }
    }

    public func controlSize(_ controlSize: ControlSize) -> some View { environment(\.controlSize, controlSize) }

    public func imageScale(_ scale: Image.Scale) -> some View { environment(\.imageScale, scale) }

    public func redacted(reason: RedactionReasons) -> some View {
        transformEnvironment(\.redactionReasons) { $0.formUnion(reason) }
    }

    public func unredacted() -> some View { environment(\.redactionReasons, []) }

    public func dynamicTypeSize(_ size: DynamicTypeSize) -> some View { environment(\.dynamicTypeSize, size) }
}
