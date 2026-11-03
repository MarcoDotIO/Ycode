import Foundation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Menus (round R8): `Menu` and the pop-up menu window that `Menu` and menu
// `Picker`s open. The pop-up is a window of its own, created through
// OVPlatform as a pop-up menu of the presenting window (SDL3 pop-up windows on
// X11 and Wayland; the headless back end keeps it in memory); when the window
// system refuses one, the content is shown as an overlay inside the window
// (AppHost.swift). Inside a pop-up, buttons and toggles are menu items, a
// nested `Menu` opens a submenu at its row's trailing edge, and choosing an
// item closes the whole chain. Escape closes the pop-up, the arrow keys move
// between items, Space and Return choose; a press outside closes it.
//
// Look (Ycode, 09 §4.2): a rectangle in the menu background colour with a
// hairline outline, 5 points above and below the rows; rows 26 points high
// with an 18-point slot for check marks.

// MARK: - Dismissal

private enum PopupDismissKey: EnvironmentKey { static let defaultValue: (@MainActor () -> Void)? = nil }

extension EnvironmentValues {
    /// Closes the pop-up chain the view is in (menu items call it).
    package var _dismissPopup: (@MainActor () -> Void)? {
        get { self[PopupDismissKey.self] }
        set { self[PopupDismissKey.self] = newValue }
    }
}

/// A weak reference to the view node a modifier sits on (to read its window
/// frame when a control opens a pop-up).
final class NodeRef {
    weak var node: ViewNode?
    @MainActor var windowFrame: CGRect? { node.flatMap { HitTesting.frame(of: $0, mirrorWidth: nil) } }
}

struct NodeCaptureModifier: PrimitiveModifier {
    let ref: NodeRef
    func _inserted(node: ViewNode) { ref.node = node }
    func _updated(old: NodeCaptureModifier, node: ViewNode) { ref.node = node }
}

/// Holds the pop-up a control opened.
@MainActor
final class PopupBox {
    var handle: PopupHandle?
    var isOpen: Bool { handle.map { !$0.isDismissed } ?? false }
}

/// Opens `content` as a pop-up below (or, for submenus, beside) the view of
/// `ref`.
@MainActor
func openPopup(services: WindowServices?, ref: NodeRef, box: PopupBox, submenu: Bool, minWidth: CGFloat? = nil,
               onDismiss: @escaping () -> Void = {}, content: AnyView) {
    guard let services, let popups = services.popups, let frame = ref.windowFrame else { return }
    if box.isOpen {
        box.handle?.dismiss()
        return
    }
    let origin = submenu ? CGPoint(x: frame.maxX - 2, y: frame.minY - MenuMetrics.verticalPadding)
                         : CGPoint(x: frame.minX, y: frame.maxY + 4)
    box.handle = popups.presentPopup(content: content, origin: origin, minWidth: minWidth ?? (submenu ? 0 : frame.width),
                                     onDismiss: onDismiss)
}

enum MenuMetrics {
    static let verticalPadding: CGFloat = 5
    static let rowHeight: CGFloat = 26
    static let checkSlot: CGFloat = 18
    static let horizontalPadding: CGFloat = 10
}

/// The frame of a pop-up menu around its rows.
struct MenuChrome<Content: View>: View {
    let content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = ControlPalette(scheme)
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(.vertical, MenuMetrics.verticalPadding)
        .frame(minWidth: 120, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.menuBackground)
        .overlay { Rectangle().strokeBorder(palette.outline, lineWidth: 1).allowsHitTesting(false) }
        .environment(\._inMenu, true)
        .buttonStyle(MenuItemButtonStyle())
    }
}

// MARK: - Menu items

/// The primitive style buttons get inside a pop-up.
struct MenuItemButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View { MenuItemButton(configuration: configuration) }
}

/// One row of a menu.
struct MenuRow<Label: View>: View {
    let label: Label
    let checked: Bool
    let trailing: AnyView?
    let isDestructive: Bool
    let action: @MainActor () -> Void
    /// Choosing the row closes the pop-up (false for submenu rows).
    var closes = true
    @Environment(\._dismissPopup) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false
    @State private var isFocused = false
    @State private var isPressed = false

    var body: some View {
        let palette = ControlPalette(scheme)
        let highlighted = (hovered || isFocused || isPressed) && isEnabled
        let run: @MainActor () -> Void = { [dismiss, closes, action] in
            if closes { dismiss?() }
            action()
        }
        HStack(spacing: 0) {
            ZStack {
                if checked { Image(systemName: "checkmark").imageScale(.small) }
            }
            .frame(width: MenuMetrics.checkSlot)
            label
            Spacer(minLength: 16)
            if let trailing { trailing.foregroundStyle(.secondary) }
        }
        .foregroundStyle(isDestructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.primary))
        .opacity(isEnabled ? 1 : 0.4)
        .padding(.horizontal, MenuMetrics.horizontalPadding - 4)
        .frame(maxWidth: .infinity, minHeight: MenuMetrics.rowHeight, alignment: .leading)
        .background {
            if highlighted { RoundedRectangle(cornerRadius: 4).fill(palette.menuHighlight).padding(.horizontal, 4) }
        }
        .contentShape(Rectangle())
        .onHover { h in hovered = h }
        .gesture(ControlPressGesture(onPressed: { p in isPressed = p }, onAction: { run() }))
        .controlFocus($isFocused) { k in
            guard isActivationKey(k) || (k.isDown && k.key == .rightArrow && !closes) else { return false }
            run()
            return true
        }
    }
}

struct MenuItemButton: View {
    let configuration: PrimitiveButtonStyleConfiguration
    /// The item's keyboard shortcut, shown at the trailing end (R11).
    @Environment(\._keyboardShortcut) private var shortcut
    var body: some View {
        let c = configuration
        MenuRow(label: c.label, checked: false,
                trailing: shortcut.map { AnyView(Text($0.displayText).font(.footnote)) },
                isDestructive: c.role == .destructive,
                action: { c.trigger() })
    }
}

struct MenuItemToggle: View {
    let configuration: ToggleStyleConfiguration
    var body: some View {
        let isOn = configuration.$isOn
        MenuRow(label: configuration.label, checked: isOn.wrappedValue, trailing: nil, isDestructive: false,
                action: { isOn.wrappedValue.toggle() })
    }
}

// MARK: - Menu

/// A control that shows a pop-up menu of actions.
public struct Menu<Label: View, Content: View>: View {
    let label: Label
    let content: Content
    let primaryAction: (@MainActor () -> Void)?
    @Environment(\._menuStyle) private var style
    @Environment(\._inMenu) private var inMenu
    @Environment(\._windowServices) private var services
    @Environment(\._inCommandHost) private var inCommandHost
    @State private var ref = NodeRef()
    @State private var box = PopupBox()

    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.content = content()
        self.label = label()
        primaryAction = nil
    }

    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label,
                primaryAction: @escaping @MainActor () -> Void) {
        self.content = content()
        self.label = label()
        self.primaryAction = primaryAction
    }

    public var body: some View {
        if inCommandHost {
            // R13: in the window's commands host (never laid out) the items
            // are built too, so the keyboard shortcuts of a submenu's items
            // work before the menu has been opened, as in a desktop menu bar.
            control
            content.environment(\._inMenu, true)
        } else {
            control
        }
    }

    @ViewBuilder
    private var control: some View {
        let services = services, ref = ref, box = box
        let popup = AnyView(content)
        let open: @MainActor () -> Void = {
            openPopup(services: services, ref: ref, box: box, submenu: inMenu, content: popup)
        }
        if inMenu {
            MenuRow(label: label, checked: false, trailing: AnyView(Image(systemName: "chevron.right").imageScale(.small)),
                    isDestructive: false, action: open, closes: false)
                .modifier(NodeCaptureModifier(ref: ref))
        } else {
            let action = primaryAction ?? open
            Button(action: action) {
                label
            }
            .buttonStyle(style == 1 ? AnyPrimitiveStyleBox.bordered : AnyPrimitiveStyleBox.borderless)
            .modifier(NodeCaptureModifier(ref: ref))
        }
    }
}

/// A style chosen by value (the menu styles map onto button looks).
enum AnyPrimitiveStyleBox: PrimitiveButtonStyle {
    case bordered, borderless
    func makeBody(configuration: Configuration) -> some View {
        switch self {
        case .bordered: BorderedButtonBody(configuration: configuration, kind: .bordered)
        case .borderless: BorderlessButtonStyle().makeBody(configuration: configuration)
        }
    }
}

extension Menu where Label == Text {
    public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(content: content) { Text(titleKey) }
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {
        self.init(content: content) { Text(title) }
    }
}

extension Menu where Label == _TitleAndIconLabel {
    public init(_ titleKey: LocalizedStringKey, systemImage: String, @ViewBuilder content: () -> Content) {
        self.init(content: content) { _TitleAndIconLabel(titleKey, systemImage: systemImage) }
    }
}

// MARK: - Menu styles

/// What a menu style draws.
public struct MenuStyleConfiguration {
    public struct Label: View {
        let content: AnyView
        public var body: AnyView { content }
    }

    public struct Content: View {
        let content: AnyView
        public var body: AnyView { content }
    }
}

@MainActor @preconcurrency
public protocol MenuStyle {
    /// Ycode's style identifier: 0 borderless (automatic), 1 button.
    var _ovStyleKind: Int { get }
}

public struct DefaultMenuStyle: MenuStyle {
    public init() {}
    public var _ovStyleKind: Int { 0 }
}

public struct ButtonMenuStyle: MenuStyle {
    public init() {}
    public var _ovStyleKind: Int { 1 }
}

public struct BorderlessButtonMenuStyle: MenuStyle {
    public init() {}
    public var _ovStyleKind: Int { 0 }
}

extension MenuStyle where Self == DefaultMenuStyle {
    public static var automatic: DefaultMenuStyle { DefaultMenuStyle() }
}

extension MenuStyle where Self == ButtonMenuStyle {
    public static var button: ButtonMenuStyle { ButtonMenuStyle() }
}

extension MenuStyle where Self == BorderlessButtonMenuStyle {
    public static var borderlessButton: BorderlessButtonMenuStyle { BorderlessButtonMenuStyle() }
}

private enum MenuStyleKey: EnvironmentKey { static let defaultValue = 0 }

extension EnvironmentValues {
    var _menuStyle: Int {
        get { self[MenuStyleKey.self] }
        set { self[MenuStyleKey.self] = newValue }
    }
}

extension View {
    public func menuStyle<S: MenuStyle>(_ style: S) -> some View { environment(\._menuStyle, style._ovStyleKind) }
}
