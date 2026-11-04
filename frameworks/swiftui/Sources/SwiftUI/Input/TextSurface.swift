import Foundation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// A text surface (L2, docs/PARITY.md §5.9 item 3): a custom-drawn view that
// takes the window's keyboard and input-method text the way `TextField` does,
// and answers the Edit menu. It is OpenViews' own API (the reference has no
// counterpart; on its platform a code editor is an AppKit text view). The
// view draws itself (for example with `Canvas`) and a client object owns the
// text; `.textSurface(client)` makes the view a focus target whose client gets
//
// - committed text and marked text (SDL's text events, IME included);
// - the keys of the window while it has focus (arrows, Backspace, shortcuts;
//   a key it does not use goes on to menu shortcuts, as for a text field);
// - the Edit menu's Undo, Redo, Cut, Copy, Paste, Delete and Select All;
//
// and a connection for what only the window knows: the clipboard, the modifier
// keys of the last pointer event, a timer on the back end's clock, the input
// method's caret rectangle, and a redraw without a layout
// (`setNeedsDisplay`). `textSurfacePointer` follows presses event by event and
// `textSurfaceScroll` takes wheel steps, for a surface that scrolls itself.
//
// Focus works as for `focusable()`: `.focused($flag)` outside the modifier
// binds it, and setting the flag from a click focuses the surface.

/// The Edit menu's actions on a text surface.
public enum TextSurfaceCommand: String, CaseIterable, Sendable {
    case undo, redo, cut, copy, paste, delete, selectAll

    init(_ c: StandardEditCommand) {
        switch c {
        case .undo: self = .undo
        case .redo: self = .redo
        case .cut: self = .cut
        case .copy: self = .copy
        case .paste: self = .paste
        case .delete: self = .delete
        case .selectAll: self = .selectAll
        }
    }
}

/// The owner of a custom-drawn view's text.
@MainActor
public protocol TextSurfaceClient: AnyObject {
    /// The surface is in a window (or left one, with nil).
    func surfaceConnected(_ connection: TextSurfaceConnection?)
    /// Committed text.
    func surfaceInsertText(_ text: String)
    /// The input method's uncommitted text; empty ends the composition.
    func surfaceSetMarkedText(_ text: String, cursor: Int)
    /// A key pressed while the surface has focus; false lets it go on (menu
    /// shortcuts, Tab between views).
    func surfaceHandleKey(_ event: KeyEvent) -> Bool
    /// The caret in window points (the input method's candidate window goes by it).
    var surfaceCaretRect: CGRect { get }
    func surfaceFocusChanged(_ focused: Bool)
    func surfaceCanPerform(_ command: TextSurfaceCommand) -> Bool
    func surfacePerform(_ command: TextSurfaceCommand)
}

/// What a window gives a text surface.
@MainActor
public final class TextSurfaceConnection {
    private let services: WindowServices
    private weak var node: ViewNode?
    private let client: () -> (any TextInputClient)?

    init(services: WindowServices, node: ViewNode, client: @escaping () -> (any TextInputClient)?) {
        self.services = services
        self.node = node
        self.client = client
    }

    /// The system clipboard's text.
    public var clipboardText: String? {
        get { services.clipboard?.text }
        set { services.clipboard?.text = newValue }
    }

    public var hasClipboardText: Bool { services.clipboard?.hasText ?? false }

    /// The modifier keys held at the last pointer event (shift-click).
    public var pointerModifiers: KeyModifiers { services.pointerModifiers }

    /// The back end's clock.
    public var now: TimeInterval { node?.graph.timeSource.now ?? 0 }

    /// Runs `fire` once after `delay` seconds, replacing `owner`'s earlier timer
    /// (nil cancels it). The window sleeps until then, so an idle editor
    /// draws nothing.
    public func setTimer(_ owner: AnyObject, after delay: TimeInterval?, fire: @escaping @MainActor () -> Void) {
        services.setTimer(owner, at: delay.map { now + $0 }) { _ in fire() }
    }

    /// Draws the window again from its last layout, without updating any
    /// view: a `Canvas` that reads the client's state when it draws shows the
    /// new state. Typing, the caret's blink and scrolling cost a frame's
    /// drawing, not a layout of the whole window.
    public func setNeedsDisplay() { services.requestDisplay() }

    /// The caret moved: tells the input method where it is now.
    public func caretMoved() {
        guard let c = client(), services.focus.focusedClient === c else { return }
        services.focus.onTextClientChanged(c)
    }
}

/// Adapts a public client to the focus system's protocol.
final class TextSurfaceAdapter: TextInputClient {
    weak var client: (any TextSurfaceClient)?
    weak var services: WindowServices?
    var connection: TextSurfaceConnection?

    func insertText(_ text: String) { client?.surfaceInsertText(text) }
    func setMarkedText(_ text: String, cursor: Int) { client?.surfaceSetMarkedText(text, cursor: cursor) }
    func handleKey(_ event: KeyEvent) -> Bool { client?.surfaceHandleKey(event) ?? false }
    var caretRect: CGRect { client?.surfaceCaretRect ?? .zero }
    func focusChanged(_ focused: Bool) { client?.surfaceFocusChanged(focused) }
    func canPerform(_ command: StandardEditCommand, clipboard: (any PlatformClipboard)?) -> Bool {
        client?.surfaceCanPerform(TextSurfaceCommand(command)) ?? false
    }
    func perform(_ command: StandardEditCommand, clipboard: (any PlatformClipboard)?) {
        client?.surfacePerform(TextSurfaceCommand(command))
    }
}

struct TextSurfaceModifier: PrimitiveModifier {
    let client: any TextSurfaceClient
    let isEnabled: Bool

    private func sync(_ node: ViewNode) {
        let adapter = (node.primitiveState as? TextSurfaceAdapter) ?? TextSurfaceAdapter()
        node.primitiveState = adapter
        guard let services = node.environment._windowServices else { return }
        let changed = adapter.client !== client
        adapter.client = client
        adapter.services = services
        if isEnabled {
            services.focus.register(node, bindings: node.environment._focusBindings, client: adapter)
        } else {
            services.focus.unregister(node)
        }
        if changed || adapter.connection == nil {
            let c = TextSurfaceConnection(services: services, node: node) { [weak adapter] in adapter }
            adapter.connection = c
            client.surfaceConnected(c)
        }
    }

    func _inserted(node: ViewNode) { sync(node) }
    func _updated(old: TextSurfaceModifier, node: ViewNode) { sync(node) }
    func _removed(node: ViewNode) {
        guard let a = node.primitiveState as? TextSurfaceAdapter else { return }
        a.services?.focus.unregister(node)
        a.client?.surfaceConnected(nil)
        a.connection = nil
    }
}

extension TextSurfaceModifier: GraphInputComparable {
    nonisolated func _isGraphInputEqual(to other: Any) -> Bool { false }
}

extension View {
    /// Makes this custom-drawn view a text input target owned by `client`.
    public func textSurface(_ client: any TextSurfaceClient, isEnabled: Bool = true) -> some View {
        modifier(TextSurfaceModifier(client: client, isEnabled: isEnabled))
    }
}

// MARK: - Pointer

/// A press on a text surface, from down to up, in the view's coordinates;
/// times are the back end's clock. Every event of a press arrives, in order,
/// even when several come between two frames (a fast double click).
public enum TextSurfacePointerEvent: Equatable, Sendable {
    case down(CGPoint, time: TimeInterval)
    case moved(CGPoint, time: TimeInterval)
    case up(CGPoint, time: TimeInterval)
    case cancelled
}

extension View {
    /// Follows presses of the primary button over this view; it takes them
    /// before the gestures of the views inside.
    public func textSurfacePointer(_ handler: @escaping @MainActor (TextSurfacePointerEvent) -> Void) -> some View {
        highPriorityGesture(ControlTrackGesture { e in
            switch e {
            case .down(let p, let t): handler(.down(p, time: t))
            case .moved(let p, let t): handler(.moved(p, time: t))
            case .up(let p, let t): handler(.up(p, time: t))
            case .cancelled: handler(.cancelled)
            }
        })
    }
}

extension View {
    /// Scroll-wheel and trackpad steps over this view (points; positive y
    /// scrolls up, positive x right, as `ScrollEvent`); return true when used.
    /// For a text surface that scrolls itself.
    public func textSurfaceScroll(_ action: @escaping @MainActor (CGSize, CGPoint) -> Bool) -> some View {
        _onScrollWheel { d, p in MainActor.assumeIsolated { action(d, p) } }
    }
}

// MARK: - Termination

/// Asked before the app ends by the user's hand (the Quit command, the close
/// button of the last window): false keeps it running, and the app asks about
/// unsaved work and ends it later with `OpenViewsAutomation.terminate()`. Not
/// asked for the platform's quit (a signal, SDL's quit event), a crash or
/// `terminate()`.
@MainActor
public enum ApplicationTermination {
    public static var shouldTerminate: (() -> Bool)?
}
