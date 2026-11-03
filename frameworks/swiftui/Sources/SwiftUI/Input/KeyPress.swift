import Foundation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Key presses (round R13; public API names: `KeyPress`, `KeyPress.Phases`,
// `KeyPress.Result`, `onKeyPress`).
//
// Delivery (as the public documentation describes it): a view's handlers
// receive the key presses of the window while the view or a view inside it
// has keyboard focus. Handlers are tried from the focused view outwards (the
// modifiers on the focused view itself first, innermost first, then its
// ancestors); the first that returns `.handled` ends the key's delivery, so
// the focused control, menu shortcuts and Tab do not see it, and the text a
// handled character key would have typed is not inserted.
//
// On Linux the Ctrl key reads as `.command` (OpenViews' shortcut rule, so
// that ⌘-shortcuts written for Apple platforms work); Ctrl+Super is
// `[.command, .control]`; Alt is `.option`.

/// A key press, auto-repeat or release given to `onKeyPress` handlers.
public struct KeyPress: Sendable {
    /// Which events a handler wants.
    public struct Phases: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let down = Phases(rawValue: 1)
        public static let `repeat` = Phases(rawValue: 2)
        public static let up = Phases(rawValue: 4)
        public static let all: Phases = [.down, .repeat, .up]
    }

    /// Whether a handler used the key.
    public enum Result: Sendable, Equatable {
        case handled, ignored
    }

    public let phase: Phases
    public let key: KeyEquivalent
    /// The text the key types (modifiers applied: Shift gives capitals).
    public let characters: String
    public let modifiers: EventModifiers

    package init(phase: Phases, key: KeyEquivalent, characters: String, modifiers: EventModifiers) {
        self.phase = phase
        self.key = key
        self.characters = characters
        self.modifiers = modifiers
    }

    /// The press for a platform key event (nil for keys with no
    /// equivalent).
    package init?(_ e: KeyEvent) {
        guard let k = KeyEquivalent(platformKey: e.key) else { return nil }
        let phase: Phases = !e.isDown ? .up : (e.isRepeat ? .repeat : .down)
        var m: EventModifiers = []
        if e.modifiers.contains(.shift) { m.insert(.shift) }
        if e.modifiers.contains(.option) { m.insert(.option) }
        if e.modifiers.contains(.capsLock) { m.insert(.capsLock) }
        if e.modifiers.contains(.numericPad) { m.insert(.numericPad) }
        let ctrl = e.modifiers.contains(.control), superKey = e.modifiers.contains(.command)
        if ctrl && superKey { m.formUnion([.command, .control]) } else if ctrl || superKey { m.insert(.command) }
        var chars = String(k.character)
        if case .character = e.key, e.modifiers.contains(.shift) || e.modifiers.contains(.capsLock) { chars = chars.uppercased() }
        self.init(phase: phase, key: k, characters: chars, modifiers: m)
    }
}

/// The handlers one `onKeyPress` modifier installs.
@MainActor
final class KeyPressHandlers {
    var phases: KeyPress.Phases
    var accepts: (KeyPress) -> Bool
    var action: (KeyPress) -> KeyPress.Result

    init(phases: KeyPress.Phases, accepts: @escaping (KeyPress) -> Bool, action: @escaping (KeyPress) -> KeyPress.Result) {
        self.phases = phases
        self.accepts = accepts
        self.action = action
    }

    func handle(_ p: KeyPress) -> Bool {
        guard phases.contains(p.phase), accepts(p) else { return false }
        return action(p) == .handled
    }
}

struct KeyPressModifier: PrimitiveModifier {
    let phases: KeyPress.Phases
    let accepts: (KeyPress) -> Bool
    let action: (KeyPress) -> KeyPress.Result

    func _inserted(node: ViewNode) {
        node.primitiveState = KeyPressHandlers(phases: phases, accepts: accepts, action: action)
    }

    func _updated(old: KeyPressModifier, node: ViewNode) {
        guard let h = node.primitiveState as? KeyPressHandlers else { return _inserted(node: node) }
        h.phases = phases
        h.accepts = accepts
        h.action = action
    }
}

extension KeyPressModifier: GraphInputComparable {
    nonisolated func _isGraphInputEqual(to other: Any) -> Bool { false }
}

@MainActor
enum KeyPressDispatch {
    /// Offers `event` to the handlers around the focused view; true when one
    /// handled it.
    static func deliver(_ event: KeyEvent, focused: ViewNode?) -> Bool {
        guard let focused, let press = KeyPress(event) else { return false }
        // Modifiers on the focused view itself (its modifier chain below the
        // focus registration), innermost first.
        var inner: [KeyPressHandlers] = []
        var n = focused
        var depth = 0
        while depth < 32, n.view is any ModifierAccessing, let c = n.children.first {
            if let h = c.primitiveState as? KeyPressHandlers { inner.append(h) }
            n = c
            depth += 1
        }
        for h in inner.reversed() where h.handle(press) { return true }
        var p: ViewNode? = focused
        while let x = p {
            if let h = x.primitiveState as? KeyPressHandlers, h.handle(press) { return true }
            p = x.parent
        }
        return false
    }
}

extension View {
    /// Runs `action` when `key` is pressed while this view (or a view in it)
    /// has focus.
    public func onKeyPress(_ key: KeyEquivalent, action: @escaping () -> KeyPress.Result) -> some View {
        onKeyPress(key, phases: [.down, .repeat]) { _ in action() }
    }

    public func onKeyPress(_ key: KeyEquivalent, phases: KeyPress.Phases,
                           action: @escaping (KeyPress) -> KeyPress.Result) -> some View {
        modifier(KeyPressModifier(phases: phases, accepts: { $0.key == key }, action: action))
    }

    public func onKeyPress(keys: Set<KeyEquivalent>, phases: KeyPress.Phases = [.down, .repeat],
                           action: @escaping (KeyPress) -> KeyPress.Result) -> some View {
        modifier(KeyPressModifier(phases: phases, accepts: { keys.contains($0.key) }, action: action))
    }

    public func onKeyPress(characters: CharacterSet, phases: KeyPress.Phases = [.down, .repeat],
                           action: @escaping (KeyPress) -> KeyPress.Result) -> some View {
        modifier(KeyPressModifier(phases: phases, accepts: { p in
            !p.characters.isEmpty && p.characters.unicodeScalars.allSatisfy { characters.contains($0) }
        }, action: action))
    }

    public func onKeyPress(phases: KeyPress.Phases = [.down, .repeat],
                           action: @escaping (KeyPress) -> KeyPress.Result) -> some View {
        modifier(KeyPressModifier(phases: phases, accepts: { _ in true }, action: action))
    }
}
