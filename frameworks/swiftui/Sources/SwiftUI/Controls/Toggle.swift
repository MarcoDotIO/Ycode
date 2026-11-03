import Foundation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Toggle and toggle styles (round R8). 06 §4: a tap on the switch flips the
// bound value; programmatic changes animate the switch. Golden `toggle`:
// label + 8 + a 61 × 28 switch, filling a proposed width;
// `toggle.labelsHidden`: 61 × 28. The checkbox style (a desktop style; the
// name follows the public API) puts an 18 × 18 box before the label.

/// A control that switches between on and off.
public struct Toggle<Label: View>: View {
    let isOn: Binding<Bool>
    let label: Label
    @Environment(\._toggleStyle) private var style
    @Environment(\._inMenu) private var inMenu

    public init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {
        self.isOn = isOn
        self.label = label()
    }

    public var body: some View {
        let c = ToggleStyleConfiguration(label: .init(content: AnyView(label)), isOn: isOn)
        let binding = isOn
        Group {
            if inMenu {
                MenuItemToggle(configuration: c)
            } else if let style {
                style.make(c)
            } else {
                SwitchToggleStyle().makeBody(configuration: c)
            }
        }
        // R10 (08 §2): a toggle is a button with the toggle trait, value 1/0.
        .accessibilityControl(inMenu ? .menuItem : .toggle, traits: [.isButton, .isToggle],
                              value: { binding.wrappedValue ? "1" : "0" },
                              actions: ["default": { binding.wrappedValue.toggle() }])
    }
}

extension Toggle where Label == Text {
    public init(_ titleKey: LocalizedStringKey, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { Text(titleKey) }
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { Text(title) }
    }
}

extension Toggle where Label == _TitleAndIconLabel {
    public init(_ titleKey: LocalizedStringKey, systemImage: String, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { _TitleAndIconLabel(titleKey, systemImage: systemImage) }
    }
}

/// What a toggle style draws.
public struct ToggleStyleConfiguration {
    public struct Label: View {
        let content: AnyView
        public var body: AnyView { content }
    }

    public let label: Label
    @Binding public var isOn: Bool
    public var isMixed: Bool = false

    init(label: Label, isOn: Binding<Bool>, isMixed: Bool = false) {
        self.label = label
        _isOn = isOn
        self.isMixed = isMixed
    }
}

@MainActor @preconcurrency
public protocol ToggleStyle {
    associatedtype Body: View
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
    typealias Configuration = ToggleStyleConfiguration
}

struct AnyToggleStyle {
    let make: @MainActor (ToggleStyleConfiguration) -> AnyView
}

private enum ToggleStyleKey: EnvironmentKey { static let defaultValue: AnyToggleStyle? = nil }

extension EnvironmentValues {
    var _toggleStyle: AnyToggleStyle? {
        get { self[ToggleStyleKey.self] }
        set { self[ToggleStyleKey.self] = newValue }
    }
}

extension View {
    public func toggleStyle<S: ToggleStyle>(_ style: S) -> some View {
        environment(\._toggleStyle, AnyToggleStyle { AnyView(style.makeBody(configuration: $0)) })
    }
}

/// The default: a switch.
public struct DefaultToggleStyle: ToggleStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        SwitchToggleStyle().makeBody(configuration: configuration)
    }
}

/// A sliding switch at the trailing edge (61 × 28).
public struct SwitchToggleStyle: ToggleStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { SwitchToggleBody(configuration: configuration) }
}

/// A check box before the label (18 × 18).
public struct CheckboxToggleStyle: ToggleStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { CheckboxToggleBody(configuration: configuration) }
}

/// A button that shows its state (prominent while on).
public struct ButtonToggleStyle: ToggleStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.$isOn
        let c = PrimitiveButtonStyleConfiguration(role: nil, label: .init(content: AnyView(configuration.label)),
                                                  action: { isOn.wrappedValue.toggle() })
        return BorderedButtonBody(configuration: c, kind: isOn.wrappedValue ? .prominent : .bordered)
    }
}

extension ToggleStyle where Self == DefaultToggleStyle {
    public static var automatic: DefaultToggleStyle { DefaultToggleStyle() }
}

extension ToggleStyle where Self == SwitchToggleStyle {
    public static var `switch`: SwitchToggleStyle { SwitchToggleStyle() }
}

extension ToggleStyle where Self == CheckboxToggleStyle {
    public static var checkbox: CheckboxToggleStyle { CheckboxToggleStyle() }
}

extension ToggleStyle where Self == ButtonToggleStyle {
    public static var button: ButtonToggleStyle { ButtonToggleStyle() }
}

// MARK: - Switch

/// Switch geometry (golden: 61 × 28); the thumb is Ycode's.
enum SwitchMetrics {
    static let size = CGSize(width: 61, height: 28)
    static let thumb = CGSize(width: 35, height: 24)
    static let pressedThumbWidth: CGFloat = 41
}

struct SwitchToggleBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\._labelsHidden) private var labelsHidden
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isPressed = false
    @State private var isFocused = false

    var body: some View {
        let isOn = configuration.$isOn
        let on = isOn.wrappedValue
        let palette = ControlPalette(scheme)
        ControlRowLayout {
            if !labelsHidden { configuration.label }
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? AnyShapeStyle(.tint) : AnyShapeStyle(palette.switchOff))
                Capsule()
                    .fill(palette.thumb)
                    .overlay { Capsule().stroke(palette.thumbBorder, lineWidth: 0.5) }
                    .shadow(color: Color.black.opacity(0.15), radius: 2, y: 1)
                    .frame(width: isPressed ? SwitchMetrics.pressedThumbWidth : SwitchMetrics.thumb.width,
                           height: SwitchMetrics.thumb.height)
                    .padding(2)
            }
            .frame(width: SwitchMetrics.size.width, height: SwitchMetrics.size.height)
            .animation(.easeInOut(duration: 0.2), value: on)
            .animation(.easeInOut(duration: 0.12), value: isPressed)
            .contentShape(Capsule())
            .gesture(ControlPressGesture(onPressed: { p in isPressed = p }, onAction: { isOn.wrappedValue.toggle() }))
            .controlFocus($isFocused) { k in
                guard isActivationKey(k) else { return false }
                isOn.wrappedValue.toggle()
                return true
            }
            .focusRing(isFocused, Capsule())
        }
        .opacity(isEnabled ? 1 : 0.45)
    }
}

// MARK: - Checkbox

struct CheckmarkShape: Shape {
    nonisolated func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.22, y: r.minY + r.height * 0.52))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.42, y: r.minY + r.height * 0.72))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.78, y: r.minY + r.height * 0.30))
        return p
    }
}

struct CheckboxToggleBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\._labelsHidden) private var labelsHidden
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isPressed = false
    @State private var isFocused = false

    var body: some View {
        let isOn = configuration.$isOn
        let on = isOn.wrappedValue
        let mixed = configuration.isMixed
        let palette = ControlPalette(scheme)
        let box = RoundedRectangle(cornerRadius: 4)
        ControlRowLayout(controlLeading: true) {
            ZStack {
                box.fill(on || mixed ? AnyShapeStyle(.tint) : AnyShapeStyle(palette.fieldBackground))
                if !(on || mixed) { box.strokeBorder(palette.outline, lineWidth: 1) }
                if mixed {
                    Capsule().fill(Color.white).frame(width: 9, height: 2)
                } else if on {
                    CheckmarkShape().stroke(Color.white, lineWidth: 2)
                }
            }
            .frame(width: 18, height: 18)
            .opacity(isPressed ? 0.7 : 1)
            .focusRing(isFocused, box)
            if !labelsHidden { configuration.label }
        }
        .contentShape(Rectangle())
        .gesture(ControlPressGesture(onPressed: { p in isPressed = p }, onAction: { isOn.wrappedValue.toggle() }))
        .controlFocus($isFocused) { k in
            guard isActivationKey(k) else { return false }
            isOn.wrappedValue.toggle()
            return true
        }
        .opacity(isEnabled ? 1 : 0.45)
    }
}
