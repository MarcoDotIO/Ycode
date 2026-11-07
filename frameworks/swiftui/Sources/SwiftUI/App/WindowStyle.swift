import Foundation
import Observation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Window styles, window behaviours, the active state and launch behaviour
// (B5-OPENVIEWS; public API names: `WindowStyle`, `windowStyle(_:)`,
// `WindowInteractionBehavior`, `windowDismissBehavior(_:)`,
// `windowMinimizeBehavior(_:)`, `windowFullScreenBehavior(_:)`,
// `windowResizeBehavior(_:)`, `ControlActiveState`, `controlActiveState`,
// `appearsActive`, `SceneLaunchBehavior`, `defaultLaunchBehavior(_:)`).
//
// Ycode's rules on Linux (the reference is Ycode's own macOS IDE,
// `specs/ide/cross-platform-parity.md` §2, §15 OV-1):
// - `.automatic` and `.titleBar`: the window system draws the title bar and
//   frame (as before).
// - `.hiddenTitleBar`: the window has no title bar or frame from the window
//   system; the content runs to the window's top edge and OpenViews draws the
//   close, minimize and zoom buttons over it (WindowButtons.swift), centred
//   on half the title bar's height (26 for the 52-point band of a window with
//   a toolbar, the macOS IDE's window). Presses on the title-bar band that
//   land on no control move the window; the window's edges resize it.
// - `.plain`: no title bar, frame or buttons (Welcome's window: it draws its
//   own close button).
// The menu bar of such windows is on demand (MenuBarPresentation below).

/// A window style (`windowStyle(_:)`).
public protocol WindowStyle: Sendable {}

/// What a window style asks of the window.
package enum WindowStyleKind: Equatable, Sendable {
    case automatic, titleBar, hiddenTitleBar, plain
}

package protocol _WindowStyleKindProviding {
    var _kind: WindowStyleKind { get }
    var _titleBarHeight: CGFloat { get }
}

/// The platform's default: a window-system title bar.
public struct DefaultWindowStyle: WindowStyle, _WindowStyleKindProviding {
    public init() {}
    package var _kind: WindowStyleKind { .automatic }
    package var _titleBarHeight: CGFloat { WindowButtonMetrics.titleBarHeight }
}

/// A window-system title bar.
public struct TitleBarWindowStyle: WindowStyle, _WindowStyleKindProviding {
    public init() {}
    package var _kind: WindowStyleKind { .titleBar }
    package var _titleBarHeight: CGFloat { WindowButtonMetrics.titleBarHeight }
}

/// No title bar: the content fills the window and OpenViews draws the window
/// buttons over its top-left corner.
public struct HiddenTitleBarWindowStyle: WindowStyle, _WindowStyleKindProviding {
    let height: CGFloat
    public init() { height = WindowButtonMetrics.titleBarHeight }
    /// OpenViews: a title-bar band of `titleBarHeight` points (the window
    /// buttons are centred on half of it; presses on the band move the
    /// window). Not SwiftUI API.
    public init(titleBarHeight: CGFloat) { height = max(20, titleBarHeight) }
    package var _kind: WindowStyleKind { .hiddenTitleBar }
    package var _titleBarHeight: CGFloat { height }
}

/// No title bar and no window buttons.
public struct PlainWindowStyle: WindowStyle, _WindowStyleKindProviding {
    public init() {}
    package var _kind: WindowStyleKind { .plain }
    package var _titleBarHeight: CGFloat { WindowButtonMetrics.titleBarHeight }
}

extension WindowStyle where Self == DefaultWindowStyle {
    public static var automatic: DefaultWindowStyle { DefaultWindowStyle() }
}

extension WindowStyle where Self == TitleBarWindowStyle {
    public static var titleBar: TitleBarWindowStyle { TitleBarWindowStyle() }
}

extension WindowStyle where Self == HiddenTitleBarWindowStyle {
    public static var hiddenTitleBar: HiddenTitleBarWindowStyle { HiddenTitleBarWindowStyle() }
    /// OpenViews: a hidden title bar whose band is `titleBarHeight` tall.
    public static func hiddenTitleBar(titleBarHeight: CGFloat) -> HiddenTitleBarWindowStyle {
        HiddenTitleBarWindowStyle(titleBarHeight: titleBarHeight)
    }
}

extension WindowStyle where Self == PlainWindowStyle {
    public static var plain: PlainWindowStyle { PlainWindowStyle() }
}

// MARK: - Menu bar presentation (OpenViews)

/// Where a window shows the app's menu bar (OpenViews; not SwiftUI API:
/// Linux desktops have no global menu bar, `MenuBar.swift`).
///
/// - `inWindow`: a 26-point bar at the top of the window, above the toolbar
///   (round R11).
/// - `onDemand`: no bar in the window's layout, so the window keeps the
///   macOS IDE's layout. The bar slides down over the top of the window
///   (as the macOS menu bar does over a full-screen window) when the
///   pointer rests at the window's top edge, when F10 is pressed or Alt is
///   tapped, and stays while a menu is open; shortcuts work as always.
/// - `automatic`: `onDemand` for windows with a hidden title bar or the plain
///   style, `inWindow` otherwise.
///
/// `OV_MENU_BAR=inline` or `on-demand` overrides it for every window
/// (`OV_MENU_BAR=0` still removes the menu bar).
public struct MenuBarPresentation: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case automatic, inWindow, onDemand }
    let kind: Kind
    public static let automatic = MenuBarPresentation(kind: .automatic)
    public static let inWindow = MenuBarPresentation(kind: .inWindow)
    public static let onDemand = MenuBarPresentation(kind: .onDemand)
}

// MARK: - Window interaction behaviours

/// Whether a window interaction (closing, minimising, full screen,
/// resizing) is available.
public struct WindowInteractionBehavior: Equatable, Sendable {
    let kind: Int
    public static let automatic = WindowInteractionBehavior(kind: 0)
    public static let enabled = WindowInteractionBehavior(kind: 1)
    public static let disabled = WindowInteractionBehavior(kind: 2)
}

/// The window behaviours the window's views asked for.
@MainActor
@Observable
package final class WindowBehaviors {
    package var dismiss = WindowInteractionBehavior.automatic
    package var minimize = WindowInteractionBehavior.automatic
    package var fullScreen = WindowInteractionBehavior.automatic
    package var resize = WindowInteractionBehavior.automatic
    /// The buttons drawn (`windowButtonsShown(_:)`, OpenViews).
    package var shownButtons = WindowButtonSet.all
    package init() {}
}

/// Window buttons (OpenViews; `windowButtonsShown(_:)`).
public struct WindowButtonSet: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let close = WindowButtonSet(rawValue: 1)
    public static let minimize = WindowButtonSet(rawValue: 2)
    public static let zoom = WindowButtonSet(rawValue: 4)
    public static let all: WindowButtonSet = [.close, .minimize, .zoom]
}

private final class WindowButtonsShownRegistration {
    weak var services: WindowServices?
}

private struct WindowButtonsShownModifier: PrimitiveModifier {
    let set: WindowButtonSet

    private func apply(_ node: ViewNode, _ v: WindowButtonSet) {
        let reg = (node.primitiveState as? WindowButtonsShownRegistration) ?? WindowButtonsShownRegistration()
        node.primitiveState = reg
        guard let services = node.environment._windowServices ?? reg.services else { return }
        reg.services = services
        if services.windowChrome.behaviors.shownButtons != v { services.windowChrome.behaviors.shownButtons = v }
    }

    func _inserted(node: ViewNode) { apply(node, set) }
    func _updated(old: WindowButtonsShownModifier, node: ViewNode) { apply(node, set) }
    func _removed(node: ViewNode) { apply(node, .all) }
}

extension View {
    /// OpenViews: which window buttons a hidden-title-bar window draws (the
    /// macOS IDE's setup wizard shows only close). Not SwiftUI API; a hidden
    /// button keeps its place, as AppKit's do.
    public func windowButtonsShown(_ buttons: WindowButtonSet) -> some View {
        modifier(WindowButtonsShownModifier(set: buttons))
    }
}

private enum WindowBehaviorField: Sendable { case dismiss, minimize, fullScreen, resize }

private final class WindowBehaviorRegistration {
    weak var services: WindowServices?
}

private struct WindowBehaviorModifier: PrimitiveModifier {
    let field: WindowBehaviorField
    let value: WindowInteractionBehavior

    private func apply(_ node: ViewNode, _ v: WindowInteractionBehavior) {
        let reg = (node.primitiveState as? WindowBehaviorRegistration) ?? WindowBehaviorRegistration()
        node.primitiveState = reg
        guard let services = node.environment._windowServices ?? reg.services else { return }
        reg.services = services
        let b = services.windowChrome.behaviors
        switch field {
        case .dismiss: if b.dismiss != v { b.dismiss = v }
        case .minimize: if b.minimize != v { b.minimize = v }
        case .fullScreen: if b.fullScreen != v { b.fullScreen = v }
        case .resize: if b.resize != v { b.resize = v }
        }
    }

    func _inserted(node: ViewNode) { apply(node, value) }
    func _updated(old: WindowBehaviorModifier, node: ViewNode) { apply(node, value) }
    func _removed(node: ViewNode) { apply(node, .automatic) }
}

extension View {
    /// Whether the window's close button (and Close Window) is available.
    public func windowDismissBehavior(_ behavior: WindowInteractionBehavior) -> some View {
        modifier(WindowBehaviorModifier(field: .dismiss, value: behavior))
    }

    /// Whether the window's minimize button (and Minimize) is available.
    public func windowMinimizeBehavior(_ behavior: WindowInteractionBehavior) -> some View {
        modifier(WindowBehaviorModifier(field: .minimize, value: behavior))
    }

    /// Whether the zoom button can take the window to full screen.
    public func windowFullScreenBehavior(_ behavior: WindowInteractionBehavior) -> some View {
        modifier(WindowBehaviorModifier(field: .fullScreen, value: behavior))
    }

    /// Whether the window can be resized (its edges and the zoom button).
    public func windowResizeBehavior(_ behavior: WindowInteractionBehavior) -> some View {
        modifier(WindowBehaviorModifier(field: .resize, value: behavior))
    }
}

// MARK: - Active state

/// Whether the window that shows a view is the key window (SwiftUI's
/// `ControlActiveState`). On Linux the window with keyboard focus is `.key`
/// and every other window `.inactive`; before the window system has said
/// which window has focus (and on the headless back end) every window is
/// `.key`.
public enum ControlActiveState: Equatable, Sendable, CaseIterable {
    case key, active, inactive
}

private enum ControlActiveStateKey: EnvironmentKey { static let defaultValue = ControlActiveState.key }

extension EnvironmentValues {
    public var controlActiveState: ControlActiveState {
        get { self[ControlActiveStateKey.self] }
        set { self[ControlActiveStateKey.self] = newValue }
    }

    /// Whether the window that shows the view appears active (its controls
    /// in their active colours).
    public var appearsActive: Bool {
        get { controlActiveState != .inactive }
        set { controlActiveState = newValue ? .key : .inactive }
    }
}

// MARK: - Launch behaviour

/// Whether a scene's window opens when the app launches.
public struct SceneLaunchBehavior: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case automatic, presented, suppressed }
    let kind: Kind
    /// The first scene (that is not `Settings`) opens, unless another scene
    /// is `.presented`.
    public static let automatic = SceneLaunchBehavior(kind: .automatic)
    /// The scene's window opens at launch.
    public static let presented = SceneLaunchBehavior(kind: .presented)
    /// The scene's window does not open at launch (`openWindow(id:)` opens it).
    public static let suppressed = SceneLaunchBehavior(kind: .suppressed)
}

extension Scene {
    /// The style of the scene's windows.
    public func windowStyle<S: WindowStyle>(_ style: S) -> _ModifiedScene<Self> {
        let kind = (style as? any _WindowStyleKindProviding)?._kind ?? .automatic
        let height = (style as? any _WindowStyleKindProviding)?._titleBarHeight ?? WindowButtonMetrics.titleBarHeight
        return _ModifiedScene(content: self) {
            $0.windowStyle = kind
            $0.titleBarHeight = height
        }
    }

    /// OpenViews: where the scene's windows show the menu bar. Not SwiftUI API.
    public func menuBarPresentation(_ presentation: MenuBarPresentation) -> _ModifiedScene<Self> {
        _ModifiedScene(content: self) { $0.menuBarPresentation = presentation }
    }

    /// Whether the scene's window opens at launch.
    public func defaultLaunchBehavior(_ behavior: SceneLaunchBehavior) -> _ModifiedScene<Self> {
        _ModifiedScene(content: self) { $0.launchBehavior = behavior }
    }
}

// MARK: - The window's chrome state

/// What the window buttons and the hit test need (one per window).
@MainActor
@Observable
package final class WindowChromeState {
    /// The window's style (nil: not a decorated main window).
    package var style: WindowStyleKind = .automatic
    /// The title-bar band's height (points from the content's top).
    package var titleBarHeight: CGFloat = WindowButtonMetrics.titleBarHeight
    /// The pointer is over the window buttons (all three show their glyphs).
    package var buttonsHovered = false
    /// The button pressed (0 close, 1 minimize, 2 zoom).
    package var pressedButton: Int?
    /// Alt is held (zoom shows "+", maximising instead of full screen).
    package var optionHeld = false
    package let behaviors = WindowBehaviors()
    /// The menu bar is on demand (not in the window's layout).
    package var menuBarOnDemand = false
    /// The on-demand menu bar is shown.
    package var menuBarRevealed = false
    /// Where the pointer last was (window points; nil: outside).
    @ObservationIgnored package var lastPointer: CGPoint?
    /// The window's actions (the host sets them).
    @ObservationIgnored package var close: () -> Void = {}
    @ObservationIgnored package var minimize: () -> Void = {}
    @ObservationIgnored package var zoom: (_ maximize: Bool) -> Void = { _ in }
    package init() {}

    /// The style draws OpenViews' window buttons.
    package var drawsButtons: Bool { style == .hiddenTitleBar }
}
