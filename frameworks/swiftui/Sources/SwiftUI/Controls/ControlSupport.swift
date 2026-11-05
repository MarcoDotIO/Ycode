import Foundation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Shared pieces of the round R8 controls (10-plan.md R8; 06 §4; sizes from
// golden-layout.md): Ycode's default palette, the layouts the measured sizes
// imply, keyboard focus for controls, and the gestures controls use.

// MARK: - Palette

extension Color {
    /// An sRGB colour from 0xRRGGBB and an opacity.
    init(ycodeHex hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// Ycode's default control look for light and dark mode (09-open-design.md
/// §4.2). Where 07 §4 records a system colour the spec value is used
/// (fills, separators, grouped backgrounds, placeholder text); the rest are
/// Ycode's neutral choices. The accent is the environment's tint.
struct ControlPalette {
    let dark: Bool

    init(_ scheme: ColorScheme) { dark = scheme == .dark }

    /// systemFill (07 §4): bordered buttons, stepper and segmented tracks.
    var fill: Color { dark ? Color(ycodeHex: 0x787880, opacity: 0x5C / 255) : Color(ycodeHex: 0x787880, opacity: 0x33 / 255) }
    /// A lighter fill (pressed overlays, slider tracks; Ycode).
    var subtleFill: Color { dark ? Color(ycodeHex: 0x787880, opacity: 0.32) : Color(ycodeHex: 0x787880, opacity: 0.16) }
    /// separator (07 §4).
    var separator: Color { dark ? Color(ycodeHex: 0x545458, opacity: 0x80 / 255) : Color(ycodeHex: 0x3C3C43, opacity: 0x1F / 255) }
    /// A stronger outline for fields and checkboxes (Ycode).
    var outline: Color { dark ? Color(ycodeHex: 0xEBEBF5, opacity: 0.3) : Color(ycodeHex: 0x3C3C43, opacity: 0.3) }
    /// systemGroupedBackground / secondarySystemGroupedBackground (07 §4).
    var groupedBackground: Color { dark ? Color(ycodeHex: 0x000000) : Color(ycodeHex: 0xF2F2F7) }
    var groupedRow: Color { dark ? Color(ycodeHex: 0x1C1C1E) : Color(ycodeHex: 0xFFFFFF) }
    /// Text fields' and menus' background (Ycode).
    var fieldBackground: Color { dark ? Color(ycodeHex: 0x1C1C1E) : Color(ycodeHex: 0xFFFFFF) }
    var menuBackground: Color { dark ? Color(ycodeHex: 0x2C2C2E) : Color(ycodeHex: 0xFFFFFF) }
    /// placeholderText (07 §4).
    var placeholder: Color { dark ? Color(ycodeHex: 0xEBEBF5, opacity: 0x4C / 255) : Color(ycodeHex: 0x3C3C43, opacity: 0x4C / 255) }
    /// secondaryLabel (07 §4).
    var secondaryLabel: Color { dark ? Color(ycodeHex: 0xEBEBF5, opacity: 0x99 / 255) : Color(ycodeHex: 0x3C3C43, opacity: 0x99 / 255) }
    /// The off track of a switch (Ycode).
    var switchOff: Color { dark ? Color(ycodeHex: 0x39393D) : Color(ycodeHex: 0xE5E5EA) }
    /// Thumbs of switches and sliders (Ycode).
    var thumb: Color { dark ? Color(ycodeHex: 0xF2F2F7) : Color(ycodeHex: 0xFFFFFF) }
    var thumbBorder: Color { dark ? Color(ycodeHex: 0x000000, opacity: 0.25) : Color(ycodeHex: 0x000000, opacity: 0.12) }
    /// The raised segment of a segmented picker (Ycode).
    var segmentSelected: Color { dark ? Color(ycodeHex: 0x636366) : Color(ycodeHex: 0xFFFFFF) }
    /// Menu rows under the pointer (Ycode).
    var menuHighlight: Color { dark ? Color(ycodeHex: 0xFFFFFF, opacity: 0.12) : Color(ycodeHex: 0x000000, opacity: 0.07) }
    /// Scroll indicators (Ycode, R9).
    var indicator: Color { dark ? Color(ycodeHex: 0xFFFFFF, opacity: 0.45) : Color(ycodeHex: 0x000000, opacity: 0.38) }
    /// Selected list rows (Ycode, R9): the tint at 22 % / 35 %.
    var rowSelectionOpacity: Double { dark ? 0.35 : 0.22 }
    /// The plain list and sidebar backgrounds (systemBackground and Ycode's
    /// sidebar colour).
    var plainBackground: Color { dark ? Color(ycodeHex: 0x000000) : Color(ycodeHex: 0xFFFFFF) }
    var sidebarBackground: Color { dark ? Color(ycodeHex: 0x1C1C1E) : Color(ycodeHex: 0xF2F2F7) }
    /// Navigation and tool bars (Ycode): a translucent bar colour.
    var barBackground: Color { dark ? Color(ycodeHex: 0x1C1C1E, opacity: 0.94) : Color(ycodeHex: 0xF9F9F9, opacity: 0.94) }
    /// The dimming layer behind modal presentations (Ycode).
    var dimming: Color { dark ? Color(ycodeHex: 0x000000, opacity: 0.48) : Color(ycodeHex: 0x000000, opacity: 0.2) }
    /// Sheets, alerts and popovers (Ycode).
    var sheetBackground: Color { dark ? Color(ycodeHex: 0x1C1C1E) : Color(ycodeHex: 0xFFFFFF) }
    var alertBackground: Color { dark ? Color(ycodeHex: 0x2C2C2E) : Color(ycodeHex: 0xF2F2F2) }
    /// Destructive actions: `Color.red` of 07 §4.
    var destructive: Color { .red }
}

// MARK: - Environment

private enum LabelsHiddenKey: EnvironmentKey { static let defaultValue = false }
private enum InFormKey: EnvironmentKey { static let defaultValue = false }
private enum InMenuKey: EnvironmentKey { static let defaultValue = false }
private enum FormStyleKindKey: EnvironmentKey { static let defaultValue = 0 }
private enum FormColumnWidthKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }

extension EnvironmentValues {
    /// Set by `labelsHidden()`: controls show no label.
    package var _labelsHidden: Bool {
        get { self[LabelsHiddenKey.self] }
        set { self[LabelsHiddenKey.self] = newValue }
    }

    /// True inside a `Form` (rows, default control styles).
    package var _inForm: Bool {
        get { self[InFormKey.self] }
        set { self[InFormKey.self] = newValue }
    }

    /// The form style below (`FormStyle._ovStyleKind`: 0 grouped, 1 columns).
    package var _formStyleKind: Int {
        get { self[FormStyleKindKey.self] }
        set { self[FormStyleKindKey.self] = newValue }
    }

    /// Inside a `.columns` form: the width of the labels' column (labels end
    /// at it, controls start after it). Nil elsewhere.
    package var _formColumnWidth: CGFloat? {
        get { self[FormColumnWidthKey.self] }
        set { self[FormColumnWidthKey.self] = newValue }
    }

    /// True inside a menu's pop-up (buttons become menu items).
    package var _inMenu: Bool {
        get { self[InMenuKey.self] }
        set { self[InMenuKey.self] = newValue }
    }
}

extension View {
    /// Hides the labels of controls inside (they stay for accessibility).
    public func labelsHidden() -> some View { environment(\._labelsHidden, true) }
}

// MARK: - Layouts implied by the golden sizes

/// A label followed by a fixed-size control (`Toggle`, `Stepper`,
/// `DatePicker`, a menu `Picker` in a row). Golden `toggle`, `stepper`,
/// `datePicker.compact`: the ideal width is label + 8 + control; a proposed
/// width is taken (never less than the label's minimum + 8 + control, so
/// fit[0×0] of `toggle` is 69 = 8 + 61); the height is the larger of the two.
/// The label sits at the leading edge, the control at the trailing edge,
/// both centred vertically. A lone control (labels hidden) is its own size.
/// The row is a standard view for spacing (golden spacing matrix).
///
/// In a `.columns` form (`columnWidth` set) the row is the desktop's form
/// row instead: the label right-aligned in a column of that width (it wraps
/// inside it), the control 8 points after the column at its natural size; a
/// checkbox (control leading) sits after the empty column with its title.
struct ControlRowLayout: Layout {
    var spacing: CGFloat = 8
    /// The control comes first (checkboxes).
    var controlLeading = false
    /// The labels' column in a `.columns` form.
    var columnWidth: CGFloat?

    private func parts(_ s: Subviews) -> (label: LayoutSubview?, control: LayoutSubview?) {
        switch s.count {
        case 0: return (nil, nil)
        case 1: return (nil, s[s.startIndex])
        default: return controlLeading ? (s[s.startIndex + 1], s[s.startIndex]) : (s[s.startIndex], s[s.startIndex + 1])
        }
    }

    func spacing(subviews: Subviews, cache: inout ()) -> ViewSpacing { ViewSpacing() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (label, control) = parts(subviews)
        if let column = columnWidth { return columnsSize(label, control, column: column, proposal: proposal) }
        let c = control?.sizeThatFits(.unspecified) ?? .zero
        guard let label else { return c }
        if controlLeading {
            let w = proposal.width.map { max(0, $0 - c.width - spacing) }
            let l = label.sizeThatFits(ProposedViewSize(width: w, height: proposal.height))
            return CGSize(width: c.width + spacing + l.width, height: max(c.height, l.height))
        }
        let width: CGFloat
        let labelWidth: CGFloat?
        if let pw = proposal.width {
            let minimum = label.sizeThatFits(ProposedViewSize(width: 0, height: proposal.height)).width + spacing + c.width
            width = max(pw, minimum)
            labelWidth = max(0, width - spacing - c.width)
        } else {
            labelWidth = nil
            width = label.sizeThatFits(ProposedViewSize(width: nil, height: proposal.height)).width + spacing + c.width
        }
        let l = label.sizeThatFits(ProposedViewSize(width: labelWidth, height: proposal.height))
        return CGSize(width: width, height: max(c.height, l.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (label, control) = parts(subviews)
        if let column = columnWidth {
            placeColumns(label, control, column: column, in: bounds)
            return
        }
        let c = control?.sizeThatFits(.unspecified) ?? .zero
        if controlLeading {
            control?.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(c))
            let w = max(0, bounds.width - c.width - spacing)
            label?.place(at: CGPoint(x: bounds.minX + c.width + spacing, y: bounds.midY), anchor: .leading,
                         proposal: ProposedViewSize(width: w, height: bounds.height))
            return
        }
        control?.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(c))
        let w = max(0, bounds.width - c.width - spacing)
        label?.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                     proposal: ProposedViewSize(width: w, height: bounds.height))
    }

    // MARK: Columns form rows

    /// The control's size after the column: its natural size, or for a
    /// checkbox with its title, what is left of the proposed width.
    private func columnsParts(_ label: LayoutSubview?, _ control: LayoutSubview?, column: CGFloat,
                              proposal: ProposedViewSize) -> (label: CGSize, control: CGSize, title: CGSize) {
        let c = control?.sizeThatFits(.unspecified) ?? .zero
        if controlLeading {
            let room = proposal.width.map { max(0, $0 - column - spacing - c.width - spacing) }
            let t = label?.sizeThatFits(ProposedViewSize(width: room, height: nil)) ?? .zero
            return (.zero, c, t)
        }
        let l = label?.sizeThatFits(ProposedViewSize(width: column, height: nil)) ?? .zero
        return (CGSize(width: min(l.width, column), height: l.height), c, .zero)
    }

    private func columnsSize(_ label: LayoutSubview?, _ control: LayoutSubview?, column: CGFloat,
                             proposal: ProposedViewSize) -> CGSize {
        let p = columnsParts(label, control, column: column, proposal: proposal)
        let title = p.title.width > 0 ? spacing + p.title.width : 0
        let width = column + spacing + p.control.width + title
        return CGSize(width: max(width, proposal.width ?? 0), height: max(p.label.height, p.control.height, p.title.height))
    }

    private func placeColumns(_ label: LayoutSubview?, _ control: LayoutSubview?, column: CGFloat, in bounds: CGRect) {
        let p = columnsParts(label, control, column: column, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        let x = bounds.minX + column + spacing
        control?.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(p.control))
        if controlLeading {
            label?.place(at: CGPoint(x: x + p.control.width + spacing, y: bounds.midY), anchor: .leading,
                         proposal: ProposedViewSize(width: p.title.width, height: p.title.height))
        } else {
            label?.place(at: CGPoint(x: bounds.minX + column, y: bounds.midY), anchor: .trailing,
                         proposal: ProposedViewSize(width: p.label.width, height: p.label.height))
        }
    }
}

/// A label in a `.columns` form's labels' column: its lines end at the
/// column's edge. Elsewhere the alignment is left as it is.
struct ColumnLabelAlignment: ViewModifier {
    let inColumn: Bool
    @Environment(\.multilineTextAlignment) private var current

    func body(content: Content) -> some View {
        content.environment(\.multilineTextAlignment, inColumn ? .trailing : current)
    }
}

/// A control that takes any proposed width (unspecified: `idealWidth`) and
/// has a fixed height: `Slider` (0 × 31), linear `ProgressView` (0 × 4),
/// text fields (golden `textfield.*`: ideal = content). Its one subview is
/// proposed the final size.
struct FillWidthLayout: Layout {
    var height: CGFloat
    var idealWidth: CGFloat = 0

    func spacing(subviews: Subviews, cache: inout ()) -> ViewSpacing { ViewSpacing() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: max(0, proposal.width ?? idealWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for s in subviews {
            s.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }
}

// MARK: - Gestures

/// A button press: pressed while down inside (with the release slop),
/// action on release inside (06 §4: "action runs on touch-up inside").
struct ControlPressGesture: Gesture, PrimitiveGesture {
    typealias Value = Void
    typealias Body = Never
    let onPressed: @MainActor (Bool) -> Void
    let onAction: @MainActor () -> Void

    func _makeRecognizer(context: GestureContext) -> GestureRecognizer {
        PressRecognizer(context: context, onPressed: onPressed, onAction: onAction)
    }
}

/// Follows a press from down to up in local coordinates (slider thumbs,
/// text selection). `accepts` decides at touch-down whether to track.
struct ControlTrackGesture: Gesture, PrimitiveGesture {
    typealias Value = Void
    typealias Body = Never
    var accepts: @MainActor (CGPoint) -> Bool = { _ in true }
    let handler: @MainActor (PointerTrackRecognizer.Event) -> Void

    func _makeRecognizer(context: GestureContext) -> GestureRecognizer {
        PointerTrackRecognizer(context: context, accepts: accepts, handler: handler)
    }
}

// MARK: - Keyboard focus for controls

/// What a focused control does with a key press (true: used).
typealias ControlKeyHandler = @MainActor (KeyEvent) -> Bool

/// Registers the view as a focusable control in its window's focus system
/// (Tab order, `focused(_:)` bindings) and keeps `isFocused` current.
/// Disabled controls are not focusable.
struct ControlFocusModifier: PrimitiveModifier {
    let isFocused: Binding<Bool>
    let onKey: ControlKeyHandler
    /// Receives the registered node (containers that focus themselves on a
    /// click, R9).
    var ref: NodeRef?

    private final class Registration {
        var services: WindowServices?
    }

    private func sync(_ node: ViewNode) {
        let reg = (node.primitiveState as? Registration) ?? Registration()
        node.primitiveState = reg
        ref?.node = node
        let env = node.environment
        if env.isEnabled, let services = env._windowServices {
            let binding = isFocused
            services.focus.register(node, bindings: env._focusBindings, client: nil, keyHandler: onKey,
                                    onFocusChange: { f in if binding.wrappedValue != f { binding.wrappedValue = f } })
            reg.services = services
            let focused = services.focus.isFocused(node)
            if isFocused.wrappedValue != focused { isFocused.wrappedValue = focused }
        } else {
            reg.services?.focus.unregister(node)
            reg.services = nil
            if isFocused.wrappedValue { isFocused.wrappedValue = false }
        }
    }

    func _inserted(node: ViewNode) { sync(node) }
    func _updated(old: ControlFocusModifier, node: ViewNode) { sync(node) }
    func _removed(node: ViewNode) { (node.primitiveState as? Registration)?.services?.focus.unregister(node) }
}

extension View {
    func controlFocus(_ isFocused: Binding<Bool>, ref: NodeRef? = nil, onKey: @escaping ControlKeyHandler) -> some View {
        modifier(ControlFocusModifier(isFocused: isFocused, onKey: onKey, ref: ref))
    }

    /// Ycode's focus ring: a 2.5 pt tint outline 3 pt outside the control's
    /// shape (09-open-design.md §4.2).
    func focusRing<S: Shape>(_ visible: Bool, _ shape: S) -> some View {
        overlay {
            if visible {
                shape.stroke(.tint.opacity(0.55), lineWidth: 2.5).padding(-3).allowsHitTesting(false)
            }
        }
    }
}

/// Whether a key press activates a focused button-like control.
@MainActor
func isActivationKey(_ k: KeyEvent) -> Bool {
    guard k.isDown, !k.modifiers.contains(.control), !k.modifiers.contains(.command) else { return false }
    return k.key == .space || k.key == .return
}

// MARK: - Keyboard shortcuts of controls

/// An object whose identity stands for one control in the window's shortcut
/// registry.
final class ShortcutOwner {}

/// Registers the control's keyboard shortcut (from `keyboardShortcut` above
/// it) with its window.
struct ShortcutRegistrationModifier: PrimitiveModifier {
    let owner: ShortcutOwner
    let action: @MainActor () -> Void

    private final class Registration { var services: WindowServices? }

    private func sync(_ node: ViewNode) {
        let reg = (node.primitiveState as? Registration) ?? Registration()
        node.primitiveState = reg
        let env = node.environment
        if let shortcut = env._keyboardShortcut, let services = env._windowServices {
            let action = action
            services.shortcuts.register(owner, ShortcutRegistry.Entry(shortcut: shortcut, action: { action() },
                                                                       isEnabled: { [weak node] in
                                                                           guard let node, node.isAlive else { return false }
                                                                           return node.environment.isEnabled && !node.isInSuspendedSubtree
                                                                       },
                                                                       isCommand: env._inCommandHost))
            reg.services = services
        } else {
            reg.services?.shortcuts.unregister(owner)
            reg.services = nil
        }
    }

    func _inserted(node: ViewNode) { sync(node) }
    func _updated(old: ShortcutRegistrationModifier, node: ViewNode) { sync(node) }
    func _removed(node: ViewNode) { (node.primitiveState as? Registration)?.services?.shortcuts.unregister(owner) }
}

// MARK: - Type-erased configuration content

/// Content handed to a style (labels of buttons, toggles, …): renders the
/// control's own view.
struct ErasedContent: View {
    let view: AnyView
    init(_ v: some View) { view = AnyView(v) }
    init(any v: any View) { view = AnyView(_fromValue: v) ?? AnyView(EmptyView()) }
    var body: some View { view }
}
