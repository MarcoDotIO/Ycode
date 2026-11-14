import Foundation

// Modifiers that attach gestures and shape hit testing (06 §7). Each keeps
// its latest value in its node's primitive state, where the gesture engine
// finds it when a press begins.

/// Attaches a gesture to the content.
package struct GestureModifier<G: Gesture>: PrimitiveModifier {
    package let gesture: G
    package let kind: GestureAttachmentKind
    package let mask: GestureMask
    package let isEnabled: Bool

    private func attachment() -> GestureAttachment {
        let g = gesture
        return GestureAttachment(kind: kind, mask: mask, isEnabled: isEnabled) { GestureFactory.make(g, context: $0) }
    }

    package func _inserted(node: ViewNode) { node.primitiveState = attachment() }

    package func _updated(old: GestureModifier, node: ViewNode) {
        guard let a = node.primitiveState as? GestureAttachment else {
            node.primitiveState = attachment()
            return
        }
        let fresh = attachment()
        a.kind = fresh.kind
        a.mask = fresh.mask
        a.isEnabled = fresh.isEnabled
        a.make = fresh.make
    }
}

/// `contentShape` / `allowsHitTesting(false)`.
package struct HitShapeModifier: PrimitiveModifier {
    package let kind: HitShapeState.Kind?

    package func _inserted(node: ViewNode) { node.primitiveState = kind.map(HitShapeState.init) }
    package func _updated(old: HitShapeModifier, node: ViewNode) { node.primitiveState = kind.map(HitShapeState.init) }
}

/// Scroll-wheel input for the content (a hook for scroll views, R9).
package final class ScrollWheelState: ScrollWheelHandling {
    var action: (CGSize, CGPoint) -> Bool
    init(_ action: @escaping (CGSize, CGPoint) -> Bool) { self.action = action }
    package func scrollWheel(delta: CGSize, location: CGPoint, frame: CGRect) -> Bool { action(delta, location) }
}

package struct ScrollWheelModifier: PrimitiveModifier {
    package let action: (CGSize, CGPoint) -> Bool

    package func _inserted(node: ViewNode) { node.primitiveState = ScrollWheelState(action) }
    package func _updated(old: ScrollWheelModifier, node: ViewNode) {
        (node.primitiveState as? ScrollWheelState)?.action = action
    }
}

/// Scroll input with its gesture and momentum phases (B6-OPENVIEWS): every
/// event goes to the action, those without motion (a phase's end) too.
package final class ScrollInputState: ScrollWheelHandling {
    var action: (ScrollWheelInput, CGPoint) -> Bool
    init(_ action: @escaping (ScrollWheelInput, CGPoint) -> Bool) { self.action = action }
    package func scrollWheel(delta: CGSize, location: CGPoint, frame: CGRect) -> Bool {
        action(ScrollWheelInput(delta: delta), location)
    }
    package func scrollWheel(_ input: ScrollWheelInput, location: CGPoint, frame: CGRect) -> Bool { action(input, location) }
}

package struct ScrollInputModifier: PrimitiveModifier {
    package let action: (ScrollWheelInput, CGPoint) -> Bool

    package func _inserted(node: ViewNode) { node.primitiveState = ScrollInputState(action) }
    package func _updated(old: ScrollInputModifier, node: ViewNode) {
        if let state = node.primitiveState as? ScrollInputState { state.action = action } else { _inserted(node: node) }
    }
}

extension View {
    /// Attaches a gesture; the content's own gestures take precedence.
    public func gesture<T: Gesture>(_ gesture: T, including mask: GestureMask = .all) -> some View {
        modifier(GestureModifier(gesture: gesture, kind: .normal, mask: mask, isEnabled: true))
    }

    public func gesture<T: Gesture>(_ gesture: T, isEnabled: Bool) -> some View {
        modifier(GestureModifier(gesture: gesture, kind: .normal, mask: .all, isEnabled: isEnabled))
    }

    public func gesture<T: Gesture>(_ gesture: T, name: String, isEnabled: Bool = true) -> some View {
        modifier(GestureModifier(gesture: gesture, kind: .normal, mask: .all, isEnabled: isEnabled))
    }

    /// Attaches a gesture that takes precedence over the content's gestures.
    public func highPriorityGesture<T: Gesture>(_ gesture: T, including mask: GestureMask = .all) -> some View {
        modifier(GestureModifier(gesture: gesture, kind: .highPriority, mask: mask, isEnabled: true))
    }

    public func highPriorityGesture<T: Gesture>(_ gesture: T, isEnabled: Bool) -> some View {
        modifier(GestureModifier(gesture: gesture, kind: .highPriority, mask: .all, isEnabled: isEnabled))
    }

    public func highPriorityGesture<T: Gesture>(_ gesture: T, name: String, isEnabled: Bool = true) -> some View {
        modifier(GestureModifier(gesture: gesture, kind: .highPriority, mask: .all, isEnabled: isEnabled))
    }

    /// Attaches a gesture recognized together with the content's gestures.
    public func simultaneousGesture<T: Gesture>(_ gesture: T, including mask: GestureMask = .all) -> some View {
        modifier(GestureModifier(gesture: gesture, kind: .simultaneous, mask: mask, isEnabled: true))
    }

    public func simultaneousGesture<T: Gesture>(_ gesture: T, isEnabled: Bool) -> some View {
        modifier(GestureModifier(gesture: gesture, kind: .simultaneous, mask: .all, isEnabled: isEnabled))
    }

    public func simultaneousGesture<T: Gesture>(_ gesture: T, name: String, isEnabled: Bool = true) -> some View {
        modifier(GestureModifier(gesture: gesture, kind: .simultaneous, mask: .all, isEnabled: isEnabled))
    }

    /// Runs `action` when the view is tapped `count` times (on touch-up).
    public func onTapGesture(count: Int = 1, perform action: @escaping () -> Void) -> some View {
        gesture(TapGesture(count: count).onEnded { action() })
    }

    /// Runs `action` with the location of the last tap.
    public func onTapGesture(count: Int = 1, coordinateSpace: CoordinateSpace = .local,
                             perform action: @escaping (CGPoint) -> Void) -> some View {
        gesture(_LocatedTapGesture(count: count, coordinateSpace: coordinateSpace).onEnded(action))
    }

    /// Makes the whole frame of the view respond to hits (not only what it
    /// draws).
    public func contentShape<S: View>(_ shape: S, eoFill: Bool = false) -> some View {
        modifier(HitShapeModifier(kind: .contentShape))
    }

    /// Whether the view and its subviews take part in hit testing.
    public func allowsHitTesting(_ enabled: Bool) -> some View {
        modifier(HitShapeModifier(kind: enabled ? nil : .disabled))
    }

    /// Scroll-wheel steps over the view (package hook for scroll views).
    package func _onScrollWheel(_ action: @escaping (CGSize, CGPoint) -> Bool) -> some View {
        modifier(ScrollWheelModifier(action: action))
    }

    /// Scroll events over the view with their phases (package hook for
    /// views that scroll themselves, B6-OPENVIEWS).
    package func _onScrollInput(_ action: @escaping (ScrollWheelInput, CGPoint) -> Bool) -> some View {
        modifier(ScrollInputModifier(action: action))
    }
}

/// A tap gesture whose value is the location of the final tap.
package struct _LocatedTapGesture: Gesture {
    package typealias Value = CGPoint
    package typealias Body = Never
    package var count: Int
    package var coordinateSpace: CoordinateSpace
}

extension _LocatedTapGesture: PrimitiveGesture {
    package func _makeRecognizer(context: GestureContext) -> GestureRecognizer {
        let local = coordinateSpace == .local
        let origin = context.frame.origin
        return mapping(TapRecognizer(count: count, context: context)) { (p: CGPoint) -> CGPoint in
            local ? p : CGPoint(x: p.x + origin.x, y: p.y + origin.y)
        }
    }
}
