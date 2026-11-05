import Foundation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Focus and keyboard text input (06-app-and-components.md §5).
//
// Observed rules we keep: programmatic focus (`focus = value`) focuses the
// field bound to that value; a tap on a text field focuses it; Return runs
// `onSubmit` and removes focus (`focus → nil`); typed keys are inserted as
// text; the safe area does not change (no software keyboard).
//
// Design (ours): focusable views (text fields, `.focusable()` views) register
// with their window's `FocusSystem` together with the `focused(_:)` bindings
// above them. After each update the system reconciles: a binding that now
// names a target that is not focused focuses it; a focused target whose
// bindings all stopped naming it loses focus. Focus changes made by the user
// write the bindings (new target's set to its value, old target's cleared).
// The reference applied programmatic focus 0.5 s later; we apply it in the
// next update.

// MARK: - FocusState

/// A focus value owned by a view identity, bound to focusable views with
/// `focused(_:)` / `focused(_:equals:)`.
@propertyWrapper
public struct FocusState<Value: Hashable>: DynamicProperty {
    package let box: StateBox<Value>
    package let resetValue: Value

    public init() where Value == Bool {
        box = StateBox(false)
        resetValue = false
    }

    public init<T: Hashable>() where Value == T? {
        box = StateBox(nil)
        resetValue = nil
    }

    public var wrappedValue: Value {
        get { box.location?.read() ?? box.initial }
        nonmutating set { box.location?.write(newValue, transaction: nil) }
    }

    public var projectedValue: Binding {
        Binding(location: box.location, initial: box.initial, resetValue: resetValue)
    }

    /// A binding to a focus state.
    @propertyWrapper
    public struct Binding {
        package let location: StateLocation<Value>?
        package let initial: Value
        package let resetValue: Value

        public var wrappedValue: Value {
            get { location?.read() ?? initial }
            nonmutating set { location?.write(newValue, transaction: nil) }
        }

        public var projectedValue: Binding { self }

        /// The current value without recording a dependency.
        package var peek: Value { location?.value ?? initial }
    }
}

extension FocusState: @unchecked Sendable {}

extension FocusState: GraphDynamicProperty {
    package func _install(in node: ViewNode, slot: Int) {
        if let loc = node.slots[slot] as? StateLocation<Value> {
            box.location = loc
        } else {
            let loc = StateLocation(box.initial)
            node.slots[slot] = loc
            box.location = loc
            // R13: the focus system applies the new value after the next
            // update; make sure there is one (a task or action may set focus
            // without any body depending on it).
            let graph = node.graph
            loc.onChange = { [weak graph] in graph?.scheduleUpdate(transaction: Transaction()) }
        }
    }
}

extension FocusState: GraphInputComparable {
    package func _isGraphInputEqual(to other: Any) -> Bool { true }
}

/// One `focused(…)` binding as the focus system sees it.
@MainActor
package struct FocusBindingRef {
    /// The binding currently names this target.
    package let matches: () -> Bool
    /// Makes the binding name this target.
    package let assign: () -> Void
    /// Clears the binding if it names this target.
    package let clear: () -> Void
}

private enum FocusBindingsKey: EnvironmentKey {
    static var defaultValue: [FocusBindingRef] { [] }
}

private enum SubmitActionsKey: EnvironmentKey {
    static var defaultValue: [() -> Void] { [] }
}

extension EnvironmentValues {
    package var _focusBindings: [FocusBindingRef] {
        get { self[FocusBindingsKey.self] }
        set { self[FocusBindingsKey.self] = newValue }
    }

    package var _submitActions: [() -> Void] {
        get { self[SubmitActionsKey.self] }
        set { self[SubmitActionsKey.self] = newValue }
    }
}

/// What can trigger `onSubmit`.
public struct SubmitTriggers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let text = SubmitTriggers(rawValue: 1)
    public static let search = SubmitTriggers(rawValue: 2)
}

extension View {
    /// Binds the focus of the focusable view inside to `binding` (true while
    /// focused).
    public func focused(_ binding: FocusState<Bool>.Binding) -> some View {
        let ref = FocusBindingRef(matches: { binding.peek }, assign: { binding.wrappedValue = true },
                                  clear: { if binding.peek { binding.wrappedValue = false } })
        return transformEnvironment(\._focusBindings) { $0.append(ref) }
    }

    /// Binds the focus of the focusable view inside to `binding` having
    /// `value`.
    public func focused<V: Hashable>(_ binding: FocusState<V>.Binding, equals value: V) -> some View {
        let ref = FocusBindingRef(matches: { binding.peek == value }, assign: { binding.wrappedValue = value },
                                  clear: { if binding.peek == value { binding.wrappedValue = binding.resetValue } })
        return transformEnvironment(\._focusBindings) { $0.append(ref) }
    }

    /// Runs `action` when a text field below submits (Return).
    public func onSubmit(of triggers: SubmitTriggers = .text, _ action: @escaping () -> Void) -> some View {
        transformEnvironment(\._submitActions) { $0.append(action) }
    }

    /// Makes the view focusable (keyboard focus, Tab order).
    public func focusable(_ isFocusable: Bool = true) -> some View {
        modifier(FocusableModifier(isFocusable: isFocusable))
    }
}

// MARK: - Focus system

/// A focusable view that takes text (a text field).
@MainActor
package protocol TextInputClient: AnyObject {
    func insertText(_ text: String)
    func setMarkedText(_ text: String, cursor: Int)
    /// Editing keys (Backspace, arrows, Return, paste …); true if used.
    func handleKey(_ event: KeyEvent) -> Bool
    /// The caret rectangle in window coordinates.
    var caretRect: CGRect { get }
    func focusChanged(_ focused: Bool)
    /// Edit menu commands (R11): whether the client can perform one now,
    /// and performing it.
    func canPerform(_ command: StandardEditCommand, clipboard: (any PlatformClipboard)?) -> Bool
    func perform(_ command: StandardEditCommand, clipboard: (any PlatformClipboard)?)
}

extension TextInputClient {
    package func canPerform(_ command: StandardEditCommand, clipboard: (any PlatformClipboard)?) -> Bool { false }
    package func perform(_ command: StandardEditCommand, clipboard: (any PlatformClipboard)?) {}
}

/// The focusable views of a window and which one has focus.
@MainActor
package final class FocusSystem {
    final class Target {
        weak var node: ViewNode?
        var bindings: [FocusBindingRef]
        weak var client: (any TextInputClient)?
        /// Keys for a focused control that is not a text field (R8).
        var keyHandler: ((KeyEvent) -> Bool)?
        var onFocusChange: ((Bool) -> Void)?
        init(node: ViewNode, bindings: [FocusBindingRef], client: (any TextInputClient)?) {
            self.node = node
            self.bindings = bindings
            self.client = client
        }
    }

    private var targets: [ObjectIdentifier: Target] = [:]
    /// Registration order (deterministic choice when several bindings match).
    private var order: [ObjectIdentifier] = []
    package private(set) var focusedID: ObjectIdentifier?
    /// Called when the focused text client changes (text input on/off).
    package var onTextClientChanged: ((any TextInputClient)?) -> Void = { _ in }

    package init() {}

    package var focusedClient: (any TextInputClient)? { focusedID.flatMap { targets[$0]?.client } }
    package var focusedKeyHandler: ((KeyEvent) -> Bool)? { focusedID.flatMap { targets[$0]?.keyHandler } }
    package var focusedNode: ViewNode? { focusedID.flatMap { targets[$0]?.node } }

    package func register(_ node: ViewNode, bindings: [FocusBindingRef], client: (any TextInputClient)?,
                          keyHandler: ((KeyEvent) -> Bool)? = nil, onFocusChange: ((Bool) -> Void)? = nil) {
        let id = ObjectIdentifier(node)
        let t: Target
        if let existing = targets[id] {
            t = existing
            t.bindings = bindings
            t.client = client
        } else {
            t = Target(node: node, bindings: bindings, client: client)
            targets[id] = t
            order.append(id)
        }
        t.keyHandler = keyHandler
        t.onFocusChange = onFocusChange
    }

    package func unregister(_ node: ViewNode) { remove(ObjectIdentifier(node)) }

    private func remove(_ id: ObjectIdentifier) {
        guard let t = targets.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        if focusedID == id {
            focusedID = nil
            for b in t.bindings { b.clear() }
            t.client?.focusChanged(false)
            t.onFocusChange?(false)
            onTextClientChanged(nil)
        }
    }

    package func isFocused(_ node: ViewNode) -> Bool { focusedID == ObjectIdentifier(node) }

    /// The focus targets in registration order.
    package var registeredTargets: [ViewNode] { order.compactMap { targets[$0]?.node } }

    /// Focuses `node` (or nothing) as a user action: writes the bindings.
    package func focus(_ node: ViewNode?) {
        let newID = node.map(ObjectIdentifier.init)
        guard newID != focusedID, newID == nil || targets[newID!] != nil else { return }
        let old = focusedID.flatMap { targets[$0] }
        let new = newID.flatMap { targets[$0] }
        setFocus(newID)
        for b in old?.bindings ?? [] { b.clear() }
        for b in new?.bindings ?? [] { b.assign() }
    }

    private func setFocus(_ id: ObjectIdentifier?) {
        let old = focusedID.flatMap { targets[$0] }
        focusedID = id
        let new = id.flatMap { targets[$0] }
        old?.client?.focusChanged(false)
        old?.onFocusChange?(false)
        new?.client?.focusChanged(true)
        new?.onFocusChange?(true)
        onTextClientChanged(new?.client)
    }

    private func wanted(_ t: Target) -> Bool { t.bindings.contains { $0.matches() } }

    /// Targets whose bindings asked for focus at the last sync.
    private var lastWanted: Set<ObjectIdentifier> = []

    /// Applies programmatic focus changes made through `FocusState`. A
    /// binding that has just asked for focus takes it from the focused view,
    /// whose bindings are cleared (two `FocusState`s set to true one after
    /// the other: the later one wins, as on the reference platform).
    package func sync() {
        for id in order where targets[id]?.node?.isAlive != true { remove(id) }
        let nowWanted = Set(order.filter { targets[$0].map(wanted) == true })
        defer { lastWanted = Set(order.filter { targets[$0].map(wanted) == true }) }
        if let id = order.first(where: { nowWanted.contains($0) && !lastWanted.contains($0) && $0 != focusedID }) {
            let old = focusedID.flatMap { targets[$0] }
            setFocus(id)
            for b in old?.bindings ?? [] { b.clear() }
            return
        }
        if let id = focusedID, let t = targets[id], !t.bindings.isEmpty, !wanted(t) {
            setFocus(nil)
        }
        if focusedID.flatMap({ targets[$0] }).map(wanted) != true,
           let id = order.first(where: { $0 != focusedID && targets[$0].map(wanted) == true }) {
            setFocus(id)
        }
    }

    /// Moves focus to the next (or previous) focusable view in tree order.
    /// Modal presentations (sheets, alerts) shown in the window, innermost
    /// last: Tab moves only inside the innermost one (R9).
    package var modalScopes: [WeakNode] = []

    package func focusNext(in root: ViewNode?, reverse: Bool = false) {
        modalScopes.removeAll { !($0.node?.isAlive ?? false) }
        guard let root = modalScopes.last?.node ?? root else { return }
        var order: [ViewNode] = []
        func walk(_ n: ViewNode) {
            // Suspended subtrees (covered navigation pages) take no focus.
            guard !n.isSuspended else { return }
            if targets[ObjectIdentifier(n)] != nil { order.append(n) }
            for c in n.children { walk(c) }
        }
        walk(root)
        guard !order.isEmpty else { return }
        if reverse { order.reverse() }
        let i = order.firstIndex { ObjectIdentifier($0) == focusedID }
        let next = i.map { order[($0 + 1) % order.count] } ?? order[0]
        focus(next)
    }

    package var registeredCount: Int { targets.count }
}

/// What a window offers the views in it (focus, shortcuts, text input,
/// clipboard); found in the environment.
@MainActor
package final class WindowServices {
    package let focus = FocusSystem()
    package let shortcuts = ShortcutRegistry()
    package var clipboard: (any PlatformClipboard)?
    /// `onOpenURL` handlers of the window's views, in registration order.
    var urlHandlers: [OpenURLHandlerState] = []
    /// Modifier keys held at the last pointer event (shift-click).
    package var pointerModifiers: KeyModifiers = []
    /// Opens pop-up windows (menus) for views of this window (R8).
    package var popups: PopupPresenting?
    /// Sheets, covers, alerts and dialogs shown in the window (R9).
    package let presentations = PresentationCenter()
    /// The window toolbar's items (R11; toolbars outside navigation
    /// containers).
    package let toolbar = WindowToolbarModel()
    /// The window's menu bar (R11), when it shows one.
    package weak var menuBar: MenuBarController?
    /// The sidebar of a split view in the window (View > Show Sidebar).
    package weak var sidebar: SidebarController?
    /// Context menus of the window's views (R11).
    package let contextMenus = ContextMenuCenter()
    /// The tooltip shown in the window (R13, `help(_:)`).
    package let tooltips = TooltipCenter()
    /// Back-end time of the last input event (R13: tooltip timers).
    package var lastEventTime: TimeInterval = 0
    /// Draws the window again from its last layout (a text surface's own
    /// state changed; no view's body did).
    package var requestDisplay: () -> Void = {}

    private var timers: [ObjectIdentifier: (deadline: TimeInterval, fire: (TimeInterval) -> Void)] = [:]

    package init(clipboard: (any PlatformClipboard)? = nil) { self.clipboard = clipboard }

    /// Schedules (or with nil cancels) `owner`'s timer: `fire` runs once at
    /// `deadline` (back-end time). Controls use it for the caret blink.
    package func setTimer(_ owner: AnyObject, at deadline: TimeInterval?, fire: @escaping (TimeInterval) -> Void) {
        let id = ObjectIdentifier(owner)
        if let deadline { timers[id] = (deadline, fire) } else { timers[id] = nil }
    }

    package var nextTimerDeadline: TimeInterval? { timers.values.map(\.deadline).min() }

    package func fireTimers(now: TimeInterval) {
        let due = timers.filter { $0.value.deadline <= now + 1e-9 }
        for (id, t) in due {
            timers[id] = nil
            t.fire(now)
        }
    }
}

/// Opens pop-up content (menus) next to a view of a window.
@MainActor
package protocol PopupPresenting: AnyObject {
    /// Shows `content` with its top-leading corner at `origin` (window
    /// points of the presenting window); `onDismiss` runs when it goes.
    /// `anchor` is the frame of the view that opened it (same points): a
    /// pop-up that does not fit below it in the window opens above it, one
    /// beside it (a submenu) moves to its other side (`PopupPlacement`).
    /// Returns a handle that dismisses it.
    func presentPopup(content: AnyView, origin: CGPoint, anchor: CGRect?, minWidth: CGFloat, chrome: PopupChrome,
                      fallbackKeys: ((KeyEvent) -> Bool)?, onDismiss: @escaping () -> Void) -> PopupHandle?
}

/// The frame a pop-up's content gets: a menu's, or none (popovers bring
/// their own).
package enum PopupChrome { case menu, plain }

extension PopupPresenting {
    func presentPopup(content: AnyView, origin: CGPoint, minWidth: CGFloat, chrome: PopupChrome,
                      fallbackKeys: ((KeyEvent) -> Bool)?, onDismiss: @escaping () -> Void) -> PopupHandle? {
        presentPopup(content: content, origin: origin, anchor: nil, minWidth: minWidth, chrome: chrome, fallbackKeys: fallbackKeys,
                     onDismiss: onDismiss)
    }

    func presentPopup(content: AnyView, origin: CGPoint, minWidth: CGFloat, onDismiss: @escaping () -> Void) -> PopupHandle? {
        presentPopup(content: content, origin: origin, minWidth: minWidth, chrome: .menu, fallbackKeys: nil, onDismiss: onDismiss)
    }

    func presentPopup(content: AnyView, origin: CGPoint, minWidth: CGFloat, chrome: PopupChrome,
                      onDismiss: @escaping () -> Void) -> PopupHandle? {
        presentPopup(content: content, origin: origin, minWidth: minWidth, chrome: chrome, fallbackKeys: nil, onDismiss: onDismiss)
    }
}

/// A shown pop-up.
@MainActor
package final class PopupHandle {
    let dismissAction: () -> Void
    package private(set) var isDismissed = false
    package init(dismiss: @escaping () -> Void) { dismissAction = dismiss }
    package func dismiss() {
        guard !isDismissed else { return }
        isDismissed = true
        dismissAction()
    }

    /// Records that the pop-up went away by other means.
    package func markDismissed() { isDismissed = true }
}

private enum WindowServicesKey: EnvironmentKey {
    static let defaultValue: WindowServices? = nil
}

extension EnvironmentValues {
    package var _windowServices: WindowServices? {
        get { self[WindowServicesKey.self] }
        set { self[WindowServicesKey.self] = newValue }
    }
}

// MARK: - focusable()

final class FocusableState {
    var registered: WindowServices?
}

struct FocusableModifier: PrimitiveModifier {
    let isFocusable: Bool

    private func sync(_ node: ViewNode) {
        let state = (node.primitiveState as? FocusableState) ?? FocusableState()
        node.primitiveState = state
        let services = node.environment._windowServices
        if isFocusable, let services {
            services.focus.register(node, bindings: node.environment._focusBindings, client: nil)
            state.registered = services
        } else {
            state.registered?.focus.unregister(node)
            state.registered = nil
        }
    }

    func _inserted(node: ViewNode) { sync(node) }
    func _updated(old: FocusableModifier, node: ViewNode) { sync(node) }
    func _removed(node: ViewNode) { (node.primitiveState as? FocusableState)?.registered?.focus.unregister(node) }
}
