import Foundation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Hover, press and focus visuals of desktop controls (Ycode beta 5,
// B5-STATES; Ycode's `specs/ui/control-states.md`). On a window-system back
// end (`_desktopChrome`) controls follow the desktop's rules:
//
// - **Pressed** is not drawn as transparency: a plain button keeps its look
//   while held (most desktop controls have no visible pressed state; those
//   that do draw it themselves, through `StatefulButtonStyle`).
// - **Focus rings** show only with Full Keyboard Access (`fullKeyboardAccess`
//   in the environment, or `OV_FULL_KEYBOARD_ACCESS=1`); without it a
//   focused field shows only its caret.
// - **Menus open on mouse-down** (pop-up and pull-down buttons), as desktop
//   menus do; buttons act on mouse-up inside.
// - **Hover** is one frame on, one frame off; `StatefulButtonStyle` reports
//   it to the look, only while the control is enabled.
//
// Elsewhere (touch back ends, headless tests without desktop chrome) the
// toolkit's earlier looks stay.

// MARK: - Rules

/// When a button-like control acts.
public enum ControlPressTrigger: Sendable, Equatable {
    /// On release inside the control (the default); releasing outside
    /// cancels.
    case mouseUp
    /// On press (pop-up and pull-down menus, sidebar rows).
    case mouseDown
}

private enum FullKeyboardAccessKey: EnvironmentKey {
    static let defaultValue = ProcessInfo.processInfo.environment["OV_FULL_KEYBOARD_ACCESS"] == "1"
}

private enum PressTriggerKey: EnvironmentKey { static let defaultValue = ControlPressTrigger.mouseUp }

extension EnvironmentValues {
    /// Whether the desktop's Full Keyboard Access is on: desktop controls
    /// draw focus rings only then.
    public var fullKeyboardAccess: Bool {
        get { self[FullKeyboardAccessKey.self] }
        set { self[FullKeyboardAccessKey.self] = newValue }
    }

    /// When the buttons inside act (`Menu` sets `.mouseDown` on its button).
    package var _controlPressTrigger: ControlPressTrigger {
        get { self[PressTriggerKey.self] }
        set { self[PressTriggerKey.self] = newValue }
    }
}

extension View {
    /// Turns Full Keyboard Access's focus rings on or off for the controls
    /// inside.
    public func fullKeyboardAccess(_ on: Bool) -> some View { environment(\.fullKeyboardAccess, on) }
}

/// The desktop rules in one place (Button.swift and Menu.swift call these).
enum DesktopControlStates {
    /// A button-like control's focus ring.
    static func showsFocusRing(focused: Bool, desktop: Bool, fullKeyboardAccess: Bool) -> Bool {
        focused && (!desktop || fullKeyboardAccess)
    }

    /// A plain button's label opacity: dimmed once when disabled; on the
    /// desktop not dimmed while held.
    static func plainOpacity(pressed: Bool, enabled: Bool, desktop: Bool) -> Double {
        guard enabled else { return 0.4 }
        return pressed && !desktop ? 0.5 : 1
    }

    /// A held segment's label (dark #E8E8E8 → #C4C4C4).
    static let pressedSegmentLabel = 0.84

    /// Whether a button-like control is a Tab stop: on the desktop only with
    /// Full Keyboard Access (without it Tab moves between fields only).
    static func isTabStop(desktop: Bool, fullKeyboardAccess: Bool) -> Bool { !desktop || fullKeyboardAccess }

    /// What a `Menu`'s button waits for: the press on the desktop when the
    /// menu has no primary action.
    static func menuTrigger(desktop: Bool, hasPrimaryAction: Bool) -> ControlPressTrigger {
        desktop && !hasPrimaryAction ? .mouseDown : .mouseUp
    }
}

// MARK: - Tab stops

extension View {
    /// Keyboard focus for a button-like control: a Tab stop where
    /// `DesktopControlStates.isTabStop` says so; elsewhere not focusable
    /// (its keyboard shortcut and accessibility press still work).
    @ViewBuilder
    func controlTabStop(_ isFocused: Binding<Bool>, desktop: Bool, fullKeyboardAccess: Bool,
                        onKey: @escaping ControlKeyHandler) -> some View {
        if DesktopControlStates.isTabStop(desktop: desktop, fullKeyboardAccess: fullKeyboardAccess) {
            controlFocus(isFocused, onKey: onKey)
        } else {
            self
        }
    }
}

// MARK: - Press on mouse-down

/// A press that acts as it starts (`ControlPressTrigger.mouseDown`); the
/// control shows pressed until the release.
struct ControlDownPressGesture: Gesture, PrimitiveGesture {
    typealias Value = Void
    typealias Body = Never
    let onPressed: @MainActor (Bool) -> Void
    let onAction: @MainActor () -> Void

    func _makeRecognizer(context: GestureContext) -> GestureRecognizer {
        PointerTrackRecognizer(context: context) { e in
            MainActor.assumeIsolated {
                switch e {
                case .down:
                    onPressed(true)
                    onAction()
                case .up, .cancelled: onPressed(false)
                case .moved: break
                }
            }
        }
    }
}

extension View {
    /// The press behaviour for `trigger`.
    @ViewBuilder
    func controlPress(_ trigger: ControlPressTrigger, onPressed: @escaping @MainActor (Bool) -> Void,
                      onAction: @escaping @MainActor () -> Void) -> some View {
        switch trigger {
        case .mouseUp: gesture(ControlPressGesture(onPressed: onPressed, onAction: onAction))
        case .mouseDown: gesture(ControlDownPressGesture(onPressed: onPressed, onAction: onAction))
        }
    }
}

// MARK: - Stateful style

/// The states a `StatefulButtonStyle` look draws.
public struct ControlStateSnapshot: Equatable, Sendable {
    /// The pointer is over the control (never while disabled).
    public var isHovered: Bool
    /// The button is held down on the control.
    public var isPressed: Bool
    public var isEnabled: Bool
    /// The control has keyboard focus and focus rings are on.
    public var showsFocus: Bool

    public init(isHovered: Bool = false, isPressed: Bool = false, isEnabled: Bool = true, showsFocus: Bool = false) {
        self.isHovered = isHovered
        self.isPressed = isPressed
        self.isEnabled = isEnabled
        self.showsFocus = showsFocus
    }
}

/// A button style whose look gets the control's hover, press and focus
/// state, for controls that draw their own states (Ycode's flat and glass
/// controls). The look does not dim when disabled: it is told.
public struct StatefulButtonStyle: PrimitiveButtonStyle {
    let trigger: ControlPressTrigger
    let tracksHover: Bool
    let look: @MainActor (PrimitiveButtonStyleConfiguration.Label, ControlStateSnapshot) -> AnyView

    /// - Parameters:
    ///   - trigger: when the button acts.
    ///   - tracksHover: whether the control has a hover state at all.
    ///   - look: the control drawn for a state.
    public init<V: View>(trigger: ControlPressTrigger = .mouseUp, tracksHover: Bool = true,
                         @ViewBuilder look: @escaping @MainActor (PrimitiveButtonStyleConfiguration.Label, ControlStateSnapshot) -> V) {
        self.trigger = trigger
        self.tracksHover = tracksHover
        self.look = { AnyView(look($0, $1)) }
    }

    public func makeBody(configuration: Configuration) -> some View {
        StatefulButtonBody(configuration: configuration, trigger: trigger, tracksHover: tracksHover, look: look)
    }
}

struct StatefulButtonBody: View {
    let configuration: PrimitiveButtonStyleConfiguration
    let trigger: ControlPressTrigger
    let tracksHover: Bool
    let look: @MainActor (PrimitiveButtonStyleConfiguration.Label, ControlStateSnapshot) -> AnyView
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\._desktopChrome) private var desktop
    @Environment(\.fullKeyboardAccess) private var fullKeyboardAccess
    @State private var isHovered = false
    @State private var isPressed = false
    @State private var isFocused = false

    var body: some View {
        let snapshot = ControlStateSnapshot(
            isHovered: tracksHover && isEnabled && isHovered, isPressed: isEnabled && isPressed, isEnabled: isEnabled,
            showsFocus: DesktopControlStates.showsFocusRing(focused: isFocused, desktop: desktop, fullKeyboardAccess: fullKeyboardAccess))
        let trigger = configuration.action
        look(configuration.label, snapshot)
            .contentShape(Rectangle())
            .onHover { h in if isHovered != h { isHovered = h } }
            .controlPress(self.trigger, onPressed: { p in isPressed = p }, onAction: { trigger() })
            .controlTabStop($isFocused, desktop: desktop, fullKeyboardAccess: fullKeyboardAccess) { k in
                guard isActivationKey(k) else { return false }
                trigger()
                return true
            }
    }
}

// MARK: - Bordered buttons

/// A bordered or prominent button while held: on the desktop a push button
/// changes tint in one frame (lighter in dark, darker in light: Ycode's
/// sheet buttons, #0078FE → #2C85FD dark, #006CE5 light; Cancel #2F2F31 →
/// #434345, #EBEBEB → #D3D3D3); elsewhere it fades to 65 %. Disabled: 40 %.
struct BorderedPressLook: ViewModifier {
    let pressed: Bool
    let enabled: Bool
    let shape: AnyShape
    let prominent: Bool
    @Environment(\._desktopChrome) private var desktop
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if desktop {
            content
                .overlay {
                    if pressed && enabled {
                        shape.fill(DesktopControlStates.pressedOverlay(dark: scheme == .dark, prominent: prominent)).allowsHitTesting(false)
                    }
                }
                .opacity(enabled ? 1 : 0.4)
        } else {
            content.opacity(pressed ? 0.65 : (enabled ? 1 : 0.4))
        }
    }
}

extension DesktopControlStates {
    /// The tint laid over a held push button.
    static func pressedOverlay(dark: Bool, prominent: Bool) -> Color {
        dark ? Color.white.opacity(prominent ? 0.14 : 0.1) : Color.black.opacity(0.1)
    }
}

// MARK: - Automation

extension OpenViewsAutomation {
    /// A mouse press, move with the button held, or release at a point of a
    /// main window, through the back end's event queue (walks show held
    /// states: a pressed button, a tab bar's lens).
    public static func mouse(_ phase: PointerPhase, at p: CGPoint, window index: Int = 0) {
        guard let h = host, mainWindows.indices.contains(index) else { return }
        let held = phase == .down || phase == .moved
        h.backend.post(.pointer(PointerEvent(window: mainWindows[index].platform.id, kind: .mouse, phase: phase, location: p,
                                             button: 1, isPressed: held, timestamp: h.backend.now)))
    }
}
