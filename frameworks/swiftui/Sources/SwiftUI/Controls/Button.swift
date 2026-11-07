import Foundation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Buttons and button styles (round R8; 06 §4: the action runs on touch-up
// inside; golden-layout.md `button.*`: automatic, borderless and plain are
// the label's size; bordered, prominent and glass add 12 × 7 points around
// it, 20 × 15 at `.large`).
//
// A `Button` hands its label, role and action to the `PrimitiveButtonStyle`
// in the environment (`buttonStyle(_:)`); a `ButtonStyle` is wrapped in the
// standard press behaviour (pressed state, release inside, focus, Space and
// Return). Look: Ycode's palette (ControlSupport.swift; 09 §4.2).

// MARK: - Role

/// The purpose of a button.
public struct ButtonRole: Equatable, Sendable {
    let kind: Int
    public static let destructive = ButtonRole(kind: 1)
    public static let cancel = ButtonRole(kind: 2)
    public static let close = ButtonRole(kind: 3)
    public static let confirm = ButtonRole(kind: 4)
}

// MARK: - Configurations

/// What a `ButtonStyle` draws: the label, the role and whether the button is
/// pressed.
public struct ButtonStyleConfiguration {
    /// The button's label.
    public struct Label: View {
        let content: AnyView
        public var body: AnyView { content }
    }

    public let role: ButtonRole?
    public let label: Label
    public let isPressed: Bool
}

/// What a `PrimitiveButtonStyle` gets: the label, the role and the trigger.
public struct PrimitiveButtonStyleConfiguration {
    public struct Label: View {
        let content: AnyView
        public var body: AnyView { content }
    }

    public let role: ButtonRole?
    public let label: Label
    let action: @MainActor () -> Void

    /// Runs the button's action.
    @MainActor public func trigger() { action() }
}

// MARK: - Style protocols

/// A style that draws a button and lets the standard press behaviour drive
/// it.
@MainActor @preconcurrency
public protocol ButtonStyle {
    associatedtype Body: View
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
    typealias Configuration = ButtonStyleConfiguration
}

/// A style that draws a button and decides when it triggers.
@MainActor @preconcurrency
public protocol PrimitiveButtonStyle {
    associatedtype Body: View
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
    typealias Configuration = PrimitiveButtonStyleConfiguration
}

/// The button style in the environment.
struct AnyPrimitiveButtonStyle {
    let make: @MainActor (PrimitiveButtonStyleConfiguration) -> AnyView
}

private enum ButtonStyleKey: EnvironmentKey { static let defaultValue: AnyPrimitiveButtonStyle? = nil }
private enum ButtonBorderShapeKey: EnvironmentKey { static let defaultValue = ButtonBorderShape.automatic }

extension EnvironmentValues {
    var _buttonStyle: AnyPrimitiveButtonStyle? {
        get { self[ButtonStyleKey.self] }
        set { self[ButtonStyleKey.self] = newValue }
    }

    var _buttonBorderShape: ButtonBorderShape {
        get { self[ButtonBorderShapeKey.self] }
        set { self[ButtonBorderShapeKey.self] = newValue }
    }
}

extension View {
    /// Draws the buttons inside with `style`.
    public func buttonStyle<S: PrimitiveButtonStyle>(_ style: S) -> some View {
        environment(\._buttonStyle, AnyPrimitiveButtonStyle { AnyView(style.makeBody(configuration: $0)) })
    }

    /// Draws the buttons inside with `style` and the standard press behaviour.
    public func buttonStyle<S: ButtonStyle>(_ style: S) -> some View {
        environment(\._buttonStyle, AnyPrimitiveButtonStyle { c in
            AnyView(ButtonBehavior(configuration: c, ring: AnyShape(RoundedRectangle(cornerRadius: 6))) {
                style.makeBody(configuration: $0)
            })
        })
    }

    /// The shape of bordered buttons inside.
    public func buttonBorderShape(_ shape: ButtonBorderShape) -> some View {
        environment(\._buttonBorderShape, shape)
    }
}

// MARK: - Button

/// A control that runs an action when pressed.
public struct Button<Label: View>: View {
    let action: @MainActor () -> Void
    let label: Label
    let role: ButtonRole?
    @Environment(\._buttonStyle) private var style
    @Environment(\._inMenu) private var inMenu
    @Environment(\._keyboardShortcut) private var shortcut
    @State private var shortcutOwner = ShortcutOwner()

    public init(action: @escaping @MainActor () -> Void, @ViewBuilder label: () -> Label) {
        self.init(role: nil, action: action, label: label)
    }

    public init(role: ButtonRole?, action: @escaping @MainActor () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
        self.role = role
    }

    public var body: some View {
        let configuration = PrimitiveButtonStyleConfiguration(role: role, label: .init(content: AnyView(label)),
                                                              action: action)
        Group {
            if let style {
                style.make(configuration)
            } else if inMenu {
                MenuItemButton(configuration: configuration)
            } else {
                BorderlessButtonStyle().makeBody(configuration: configuration)
            }
        }
        .modifier(ShortcutRegistrationModifier(owner: shortcutOwner, action: action))
        .accessibilityControl(inMenu ? .menuItem : .button, traits: .isButton, actions: ["default": action],
                              isDefault: !inMenu && shortcut == .defaultAction,
                              isCancel: !inMenu && (role == .cancel || shortcut == .cancelAction))
    }
}

extension Button where Label == Text {
    public init(_ titleKey: LocalizedStringKey, action: @escaping @MainActor () -> Void) {
        self.init(action: action) { Text(titleKey) }
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, action: @escaping @MainActor () -> Void) {
        self.init(action: action) { Text(title) }
    }

    public init(_ titleKey: LocalizedStringKey, role: ButtonRole?, action: @escaping @MainActor () -> Void) {
        self.init(role: role, action: action) { Text(titleKey) }
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, role: ButtonRole?, action: @escaping @MainActor () -> Void) {
        self.init(role: role, action: action) { Text(title) }
    }
}

extension Button where Label == _TitleAndIconLabel {
    public init(_ titleKey: LocalizedStringKey, systemImage: String, action: @escaping @MainActor () -> Void) {
        self.init(action: action) { _TitleAndIconLabel(titleKey, systemImage: systemImage) }
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, systemImage: String, action: @escaping @MainActor () -> Void) {
        self.init(action: action) { _TitleAndIconLabel(title, systemImage: systemImage) }
    }

    public init(_ titleKey: LocalizedStringKey, systemImage: String, role: ButtonRole?,
                action: @escaping @MainActor () -> Void) {
        self.init(role: role, action: action) { _TitleAndIconLabel(titleKey, systemImage: systemImage) }
    }
}

// MARK: - The standard press behaviour

/// Pressed state on touch-down, the action on release inside, keyboard focus
/// with Space and Return, and the focus ring.
struct ButtonBehavior<Content: View>: View {
    let configuration: PrimitiveButtonStyleConfiguration
    let ring: AnyShape
    let content: @MainActor (ButtonStyleConfiguration) -> Content
    @State private var isPressed = false
    @State private var isFocused = false

    init(configuration: PrimitiveButtonStyleConfiguration, ring: AnyShape,
         @ViewBuilder content: @escaping @MainActor (ButtonStyleConfiguration) -> Content) {
        self.configuration = configuration
        self.ring = ring
        self.content = content
    }

    var body: some View {
        let c = ButtonStyleConfiguration(role: configuration.role,
                                         label: .init(content: configuration.label.content), isPressed: isPressed)
        let trigger = configuration.action
        content(c)
            .contentShape(Rectangle())
            .gesture(ControlPressGesture(onPressed: { p in isPressed = p }, onAction: { trigger() }))
            .controlFocus($isFocused) { k in
                guard isActivationKey(k) else { return false }
                trigger()
                return true
            }
            .focusRing(isFocused, ring)
    }
}

// MARK: - Built-in styles

/// Padding of bordered buttons per control size (golden: regular 12 × 7,
/// large 20 × 15; the other sizes are Ycode's).
func borderedPadding(_ size: ControlSize) -> (h: CGFloat, v: CGFloat) {
    switch size {
    case .mini: return (7, 2)
    case .small: return (10, 4)
    case .regular: return (12, 7)
    case .large: return (20, 15)
    case .extraLarge: return (24, 18)
    }
}

/// The automatic style: borderless outside forms and menus.
public struct DefaultButtonStyle: PrimitiveButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        DefaultButtonBody(configuration: configuration)
    }
}

struct DefaultButtonBody: View {
    let configuration: PrimitiveButtonStyleConfiguration
    @Environment(\._inMenu) private var inMenu
    var body: some View {
        if inMenu {
            MenuItemButton(configuration: configuration)
        } else {
            BorderlessButtonStyle().makeBody(configuration: configuration)
        }
    }
}

/// The label in the tint colour (red for destructive buttons); dims while
/// pressed.
public struct BorderlessButtonStyle: PrimitiveButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        ButtonBehavior(configuration: configuration, ring: AnyShape(RoundedRectangle(cornerRadius: 4))) { c in
            BorderlessLook(configuration: c)
        }
    }
}

struct BorderlessLook: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        let label = configuration.label
            .opacity(configuration.isPressed ? 0.35 : (isEnabled ? 1 : 0.4))
        if configuration.role == .destructive {
            label.foregroundStyle(Color.red)
        } else {
            label.foregroundStyle(.tint)
        }
    }
}

/// The label as it is (no tint); dims while pressed.
public struct PlainButtonStyle: PrimitiveButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        ButtonBehavior(configuration: configuration, ring: AnyShape(RoundedRectangle(cornerRadius: 4))) { c in
            PlainLook(configuration: c)
        }
    }
}

struct PlainLook: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        configuration.label.opacity(configuration.isPressed ? 0.5 : (isEnabled ? 1 : 0.4))
    }
}

/// A neutral fill behind the tinted label.
public struct BorderedButtonStyle: PrimitiveButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        BorderedButtonBody(configuration: configuration, kind: .bordered)
    }
}

/// The tint as the fill, a white label.
public struct BorderedProminentButtonStyle: PrimitiveButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        BorderedButtonBody(configuration: configuration, kind: .prominent)
    }
}

/// An approximation of glass (09 §1: materials are approximated): a
/// translucent fill with a light rim; `.glassProminent` is tinted.
public struct GlassButtonStyle: PrimitiveButtonStyle {
    let prominent: Bool
    public init() { prominent = false }
    init(prominent: Bool) { self.prominent = prominent }
    public func makeBody(configuration: Configuration) -> some View {
        BorderedButtonBody(configuration: configuration, kind: prominent ? .prominent : .glass)
    }
}

struct BorderedButtonBody: View {
    enum Kind { case bordered, prominent, glass }
    let configuration: PrimitiveButtonStyleConfiguration
    let kind: Kind
    @Environment(\._buttonBorderShape) private var borderShape
    @Environment(\.controlSize) private var controlSize
    @Environment(\._desktopChrome) private var desktop

    var body: some View {
        let shape = desktop && borderShape == .automatic && kind != .glass
            ? AnyShape(RoundedRectangle(cornerRadius: DesktopControlMetrics.buttonRadius(controlSize)))
            : borderShape.resolvedShape(controlSize: controlSize)
        ButtonBehavior(configuration: configuration, ring: shape) { c in
            BorderedLook(configuration: c, kind: kind, shape: shape)
        }
    }
}

struct BorderedLook: View {
    let configuration: ButtonStyleConfiguration
    let kind: BorderedButtonBody.Kind
    let shape: AnyShape
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.colorScheme) private var scheme
    @Environment(\._desktopChrome) private var desktop

    var body: some View {
        let pad = desktop && kind != .glass ? DesktopControlMetrics.buttonPadding(controlSize) : borderedPadding(controlSize)
        let palette = ControlPalette(scheme)
        let destructive = configuration.role == .destructive
        let padded = configuration.label
            .padding(.horizontal, pad.h)
            .padding(.vertical, pad.v)
            .frame(minHeight: desktop && kind != .glass ? DesktopControlMetrics.buttonHeight(controlSize) : nil)
        Group {
            switch kind {
            case .bordered:
                if desktop {
                    // B5-OPENVIEWS: the macOS IDE's push button, a grey
                    // bezel with the label in the text colour.
                    padded.foregroundStyle(destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(HierarchicalShapeStyle.primary))
                        .background(DesktopControlMetrics.bezel(scheme), in: shape)
                } else if destructive {
                    padded.foregroundStyle(Color.red).background(palette.fill, in: shape)
                } else {
                    padded.foregroundStyle(.tint).background(palette.fill, in: shape)
                }
            case .prominent:
                if destructive {
                    padded.foregroundStyle(Color.white).background(Color.red, in: shape)
                } else {
                    padded.foregroundStyle(Color.white).background(.tint, in: shape)
                }
            case .glass:
                padded.foregroundStyle(destructive ? Color.red : Color.primary)
                    .background(palette.subtleFill, in: shape)
                    .overlay { shape.stroke(Color.white.opacity(scheme == .dark ? 0.25 : 0.7), lineWidth: 1) }
            }
        }
        .opacity(configuration.isPressed ? 0.65 : (isEnabled ? 1 : 0.4))
    }
}

extension PrimitiveButtonStyle where Self == DefaultButtonStyle {
    public static var automatic: DefaultButtonStyle { DefaultButtonStyle() }
}

extension PrimitiveButtonStyle where Self == BorderlessButtonStyle {
    public static var borderless: BorderlessButtonStyle { BorderlessButtonStyle() }
}

extension PrimitiveButtonStyle where Self == PlainButtonStyle {
    public static var plain: PlainButtonStyle { PlainButtonStyle() }
}

extension PrimitiveButtonStyle where Self == BorderedButtonStyle {
    public static var bordered: BorderedButtonStyle { BorderedButtonStyle() }
}

extension PrimitiveButtonStyle where Self == BorderedProminentButtonStyle {
    public static var borderedProminent: BorderedProminentButtonStyle { BorderedProminentButtonStyle() }
}

extension PrimitiveButtonStyle where Self == GlassButtonStyle {
    public static var glass: GlassButtonStyle { GlassButtonStyle() }
    public static var glassProminent: GlassButtonStyle { GlassButtonStyle(prominent: true) }
}

// MARK: - Border shape

/// The shape of a bordered button.
public struct ButtonBorderShape: Equatable, Sendable, Shape {
    enum Kind: Equatable, Sendable { case automatic, capsule, roundedRectangle(CGFloat?), circle }
    let kind: Kind

    nonisolated public static let automatic = ButtonBorderShape(kind: .automatic)
    nonisolated public static let capsule = ButtonBorderShape(kind: .capsule)
    nonisolated public static let roundedRectangle = ButtonBorderShape(kind: .roundedRectangle(nil))
    nonisolated public static func roundedRectangle(radius: CGFloat) -> ButtonBorderShape {
        ButtonBorderShape(kind: .roundedRectangle(radius))
    }
    nonisolated public static let circle = ButtonBorderShape(kind: .circle)

    nonisolated public func path(in rect: CGRect) -> Path {
        switch kind {
        case .automatic, .capsule: return Capsule().path(in: rect)
        case .roundedRectangle(let r): return RoundedRectangle(cornerRadius: r ?? 8).path(in: rect)
        case .circle: return Circle().path(in: rect)
        }
    }

    /// The automatic shape is a capsule (Ycode's choice for every size).
    func resolvedShape(controlSize: ControlSize) -> AnyShape {
        switch kind {
        case .automatic, .capsule: return AnyShape(Capsule())
        case .roundedRectangle(let r): return AnyShape(RoundedRectangle(cornerRadius: r ?? (controlSize == .large ? 12 : 8)))
        case .circle: return AnyShape(Circle())
        }
    }
}

/// How a button repeats while held (accepted; buttons do not repeat yet).
public struct ButtonRepeatBehavior: Hashable, Sendable {
    let kind: Int
    public static let automatic = ButtonRepeatBehavior(kind: 0)
    public static let enabled = ButtonRepeatBehavior(kind: 1)
    public static let disabled = ButtonRepeatBehavior(kind: 2)
}

extension View {
    public func buttonRepeatBehavior(_ behavior: ButtonRepeatBehavior) -> some View { self }
}
