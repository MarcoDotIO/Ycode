import Foundation

// Hit testing and the per-window gesture engine (round R7).
//
// Hit testing walks the view tree from the root towards the point, topmost
// subtree first (later siblings are drawn above earlier ones; an overlay
// above its content, a background below it), and stops at the first view
// that draws at the point: a primitive leaf (colour, shape, text, image —
// not a spacer or an empty view) whose layout frame contains it, or a view
// with `contentShape` covering its whole frame. `allowsHitTesting(false)`
// removes a subtree. The result is the chain of views from the root to that
// leaf; the gestures attached along it take part in the press (GestureRuntime).
// Frames are the last layout pass's (model values, including offsets and
// other render transforms as bounding boxes).

/// Per-node hit-testing state of `contentShape` / `allowsHitTesting`.
@MainActor
package final class HitShapeState {
    package enum Kind { case contentShape, disabled }
    package var kind: Kind
    package init(_ kind: Kind) { self.kind = kind }
}

/// Primitive state that wants hover updates (`onHover`, `onContinuousHover`).
@MainActor
package protocol HoverHandling: AnyObject {
    /// `location` is in the view's local coordinates; nil when the pointer left.
    func hover(location: CGPoint?, frame: CGRect)
}

/// Primitive state that takes scroll-wheel input (scroll views, R9).
@MainActor
package protocol ScrollWheelHandling: AnyObject {
    /// Returns true if the delta was used.
    func scrollWheel(delta: CGSize, location: CGPoint, frame: CGRect) -> Bool
}

/// Views whose subtree is hit only inside their own frame (scroll views
/// clip their content, R9; modal layers).
@MainActor
package protocol ClipsHitTesting {}

/// Gives access to a modified view's modifier value.
@MainActor
package protocol ModifierAccessing {
    var _anyModifier: Any { get }
}

extension ModifiedContent: ModifierAccessing {
    package var _anyModifier: Any { modifier }
}

/// A secondary layer that is drawn below its content.
@MainActor
package protocol LayerOrdering {
    var _secondaryIsBelow: Bool { get }
}

extension SecondaryLayerModifier: LayerOrdering {
    package var _secondaryIsBelow: Bool { isBackground }
}

@MainActor
package enum HitTesting {
    /// The node's frame in window coordinates (union of its layout nodes),
    /// mirrored when the window lays out right to left.
    package static func frame(of node: ViewNode, mirrorWidth: CGFloat?) -> CGRect? {
        var r: CGRect?
        for n in node.lastLowered {
            guard let f = n.placedFrame, f.minX.isFinite, f.minY.isFinite, f.width.isFinite, f.height.isFinite
            else { continue }
            r = r.map { $0.union(f) } ?? f
        }
        guard var out = r else { return nil }
        if let w = mirrorWidth { out.origin.x = w - out.origin.x - out.width }
        return out
    }

    /// The chain from `root` to the deepest node drawing at `point`.
    package static func path(from root: ViewNode, at point: CGPoint, mirrorWidth: CGFloat?) -> [ViewNode]? {
        hit(root, point, mirrorWidth)
    }

    private static func isDrawingLeaf(_ node: ViewNode) -> Bool {
        guard node.kind == .primitive, node.children.isEmpty, !node.lastLowered.isEmpty else { return false }
        if let s = node.view as? any StrokeOnlyDrawing, s._drawsOnlyStroke { return false }
        return node.lastLowered.contains { n in !(n.behavior is EmptyLeaf) && !(n.behavior is SpacerLeaf) }
    }

    private static func hit(_ node: ViewNode, _ p: CGPoint, _ mirror: CGFloat?) -> [ViewNode]? {
        guard node.isAlive, !node.isSuspended else { return nil }
        if node.view is any ClipsHitTesting {
            guard let f = frame(of: node, mirrorWidth: mirror), f.contains(p) else { return nil }
        }
        let shape = node.primitiveState as? HitShapeState
        if shape?.kind == .disabled { return nil }
        var order = Array(node.children.reversed())
        if node.children.count == 2,
           let m = (node.view as? any ModifierAccessing)?._anyModifier as? any LayerOrdering, m._secondaryIsBelow {
            order = node.children
        }
        for c in order {
            if let path = hit(c, p, mirror) { return [node] + path }
        }
        if shape?.kind == .contentShape || isDrawingLeaf(node),
           let f = frame(of: node, mirrorWidth: mirror), f.contains(p) {
            return [node]
        }
        return nil
    }
}

/// Routes a window's pointer input to gestures, hover and scroll handlers.
@MainActor
package final class GestureEngine {
    package unowned let graph: ViewGraph
    package private(set) var session: GestureSession?
    private var hovered: [(node: WeakNode, handler: any HoverHandling)] = []
    /// Presses that started sessions (tests).
    package private(set) var sessionCount = 0

    package init(graph: ViewGraph) { self.graph = graph }

    private var mirrorWidth: CGFloat? { graph.layoutResult?.mirrorWidth }

    /// The hit chain at a window point (root first).
    package func hitPath(at point: CGPoint) -> [ViewNode] {
        guard let root = graph.root else { return [] }
        return HitTesting.path(from: root, at: point, mirrorWidth: mirrorWidth) ?? []
    }

    /// The next time the session needs a tick.
    package var deadline: TimeInterval? { session?.deadline }

    package func pointer(_ s: PointerSample, isPressed: Bool) {
        switch s.phase {
        case .down:
            // R13: a multi-tap waiting for its next press ends when the press
            // lands on other views (a click on a list row, then at once on a
            // button, presses the button).
            if let current = session, !current.isFinished, current.pointersDown.isEmpty,
               current.nodes != gestureNodes(at: s.location) {
                current.cancelAll()
                session = nil
            }
            if session == nil || session!.isFinished { session = makeSession(at: s.location) }
            session?.handle(.pointer(s))
        case .moved:
            if let session, !session.pointersDown.isEmpty {
                session.handle(.pointer(s))
            } else if !isPressed {
                updateHover(at: s.location)
            }
        case .up, .cancelled:
            session?.handle(.pointer(s))
            if !isPressed { updateHover(at: s.location) }
        }
        if session?.isFinished == true { session = nil }
    }

    package func tick(_ time: TimeInterval) {
        guard let s = session else { return }
        if let d = s.deadline, d <= time + 1e-9 { s.handle(.tick(time)) }
        if s.isFinished { session = nil }
    }

    /// The pointer left the window: hovers end; a press in progress stays.
    package func pointerLeft() { updateHover(at: nil) }

    /// Cancels the press in progress.
    package func cancel() {
        session?.cancelAll()
        session = nil
    }

    /// Delivers a scroll-wheel step to the innermost handler under the point.
    @discardableResult
    package func scroll(delta: CGSize, at point: CGPoint) -> Bool {
        for node in hitPath(at: point).reversed() {
            guard let h = node.primitiveState as? any ScrollWheelHandling,
                  let f = HitTesting.frame(of: node, mirrorWidth: mirrorWidth) else { continue }
            if h.scrollWheel(delta: delta, location: CGPoint(x: point.x - f.minX, y: point.y - f.minY), frame: f) {
                return true
            }
        }
        return false
    }

    /// The views with gestures under a point.
    private func gestureNodes(at point: CGPoint) -> Set<ObjectIdentifier> {
        Set(hitPath(at: point).filter { $0.primitiveState is GestureAttachment }.map(ObjectIdentifier.init))
    }

    private func makeSession(at point: CGPoint) -> GestureSession? {
        let path = hitPath(at: point)
        var exclusive: [GestureSession.Member] = []
        var simultaneous: [GestureSession.Member] = []
        for node in path.reversed() {
            guard let att = node.primitiveState as? GestureAttachment else { continue }
            if !att.mask.contains(.subviews) {
                exclusive.removeAll()
                simultaneous.removeAll()
            }
            guard att.isEnabled, node.environment.isEnabled, att.mask.contains(.gesture),
                  let f = HitTesting.frame(of: node, mirrorWidth: mirrorWidth) else { continue }
            let r = att.make(GestureContext(frame: f))
            switch att.kind {
            case .normal:
                exclusive.append(.init(recognizer: r, simultaneous: false))
            case .highPriority:
                // Ahead of everything inside this view (the high-priority
                // gestures of inner views were attached later, so they come
                // after this one only if they are outside it — never here).
                exclusive.insert(.init(recognizer: r, simultaneous: false), at: 0)
            case .simultaneous:
                simultaneous.append(.init(recognizer: r, simultaneous: true))
            }
        }
        guard !exclusive.isEmpty || !simultaneous.isEmpty else { return nil }
        sessionCount += 1
        let session = GestureSession(members: exclusive + simultaneous)
        session.nodes = Set(path.filter { $0.primitiveState is GestureAttachment }.map(ObjectIdentifier.init))
        return session
    }

    private func updateHover(at point: CGPoint?) {
        var now: [(WeakNode, any HoverHandling, CGRect)] = []
        if let point {
            for node in hitPath(at: point) {
                if let h = node.primitiveState as? any HoverHandling, node.environment.isEnabled,
                   let f = HitTesting.frame(of: node, mirrorWidth: mirrorWidth) {
                    now.append((WeakNode(node), h, f))
                }
            }
        }
        for old in hovered where !now.contains(where: { $0.1 === old.handler }) {
            old.handler.hover(location: nil, frame: .zero)
        }
        for (_, h, f) in now {
            h.hover(location: point.map { CGPoint(x: $0.x - f.minX, y: $0.y - f.minY) }, frame: f)
        }
        hovered = now.map { ($0.0, $0.1) }
    }
}
