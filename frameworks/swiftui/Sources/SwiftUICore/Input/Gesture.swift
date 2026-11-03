import Foundation

// Gesture values (06-app-and-components.md §7; names per api-inventory.md,
// "Gestures, input and drag and drop": `Gesture`, `TapGesture`,
// `SimultaneousGesture`, `ExclusiveGesture`, `AnyGesture`, `GestureMask` and
// `EventModifiers` are declared in SwiftUICore). The recognizers are in
// GestureRuntime.swift.

/// An input interaction attached to a view with `gesture(_:)`.
@MainActor @preconcurrency
public protocol Gesture<Value> {
    associatedtype Value
    associatedtype Body: Gesture
    var body: Body { get }
}

extension Never: Gesture {
    public typealias Value = Never
}

extension Gesture where Body == Never {
    public var body: Never { fatalError("\(Self.self) is a primitive gesture") }
}

// MARK: - Callbacks and mapping

/// A gesture that calls an action when its value changes.
public struct _ChangedGesture<Content: Gesture>: Gesture where Content.Value: Equatable {
    public typealias Value = Content.Value
    public typealias Body = Never
    package let content: Content
    package let action: (Content.Value) -> Void
}

/// A gesture that calls an action when it ends.
public struct _EndedGesture<Content: Gesture>: Gesture {
    public typealias Value = Content.Value
    public typealias Body = Never
    package let content: Content
    package let action: (Content.Value) -> Void
}

/// A gesture whose value is transformed.
public struct _MapGesture<Content: Gesture, Value>: Gesture {
    public typealias Body = Never
    package let content: Content
    package let transform: (Content.Value) -> Value
}

extension Gesture {
    /// Calls `action` each time the value changes while the gesture is in
    /// progress.
    public func onChanged(_ action: @escaping (Value) -> Void) -> _ChangedGesture<Self> where Value: Equatable {
        _ChangedGesture(content: self, action: action)
    }

    /// Calls `action` with the final value when the gesture ends.
    public func onEnded(_ action: @escaping (Value) -> Void) -> _EndedGesture<Self> {
        _EndedGesture(content: self, action: action)
    }

    /// Transforms the gesture's value.
    public func map<T>(_ body: @escaping (Value) -> T) -> _MapGesture<Self, T> {
        _MapGesture(content: self, transform: body)
    }

    /// Both gestures at once.
    public func simultaneously<Other: Gesture>(with other: Other) -> SimultaneousGesture<Self, Other> {
        SimultaneousGesture(self, other)
    }

    /// This gesture, or `other` if this one fails.
    public func exclusively<Other: Gesture>(before other: Other) -> ExclusiveGesture<Self, Other> {
        ExclusiveGesture(self, other)
    }
}

/// Calls an action when the (typed) value changes.
package final class ChangedRecognizer: WrappingRecognizer {
    let action: (Any) -> Void
    let equal: (Any, Any) -> Bool
    private var last: Any?

    init(base: GestureRecognizer, action: @escaping (Any) -> Void, equal: @escaping (Any, Any) -> Bool) {
        self.action = action
        self.equal = equal
        super.init(base: base)
    }

    override package func flush() {
        super.flush()
        // While in progress only: the final value goes to onEnded.
        guard phase == .possible || phase == .active, let v = currentValue else { return }
        if let last, equal(last, v) { return }
        last = v
        action(v)
    }

    override package func cancel() {
        super.cancel()
        last = nil
    }
}

/// Calls an action once with the final value.
package final class EndedRecognizer: WrappingRecognizer {
    let action: (Any) -> Void
    private var delivered = false

    init(base: GestureRecognizer, action: @escaping (Any) -> Void) {
        self.action = action
        super.init(base: base)
    }

    override package func flush() {
        super.flush()
        guard phase == .ended, !delivered, let v = value else { return }
        delivered = true
        action(v)
    }
}

// swiftlint:disable force_cast - recognizer values are the gesture's Value by construction
extension _ChangedGesture: PrimitiveGesture {
    package func _makeRecognizer(context: GestureContext) -> GestureRecognizer {
        let action = action
        return ChangedRecognizer(base: GestureFactory.make(content, context: context),
                                 action: { action($0 as! Value) },
                                 equal: { ($0 as! Value) == ($1 as! Value) })
    }
}

extension _EndedGesture: PrimitiveGesture {
    package func _makeRecognizer(context: GestureContext) -> GestureRecognizer {
        let action = action
        return EndedRecognizer(base: GestureFactory.make(content, context: context)) { action($0 as! Value) }
    }
}

extension _MapGesture: PrimitiveGesture {
    package func _makeRecognizer(context: GestureContext) -> GestureRecognizer {
        mapping(GestureFactory.make(content, context: context), transform)
    }
}
// swiftlint:enable force_cast

// MARK: - Type erasure

/// A type-erased gesture.
public struct AnyGesture<Value>: Gesture {
    public typealias Body = Never
    private let make: @MainActor (GestureContext) -> GestureRecognizer

    public init<T: Gesture>(_ gesture: T) where T.Value == Value {
        make = { GestureFactory.make(gesture, context: $0) }
    }
}

extension AnyGesture: PrimitiveGesture {
    package func _makeRecognizer(context: GestureContext) -> GestureRecognizer { make(context) }
}

// MARK: - Tap

/// Recognizes `count` taps: each a press released within 10 pt of where it
/// went down; successive taps follow within 0.35 s and 40 pt of the first
/// (our thresholds; the spec measured 120 ms double taps). While waiting for
/// a further tap it defers gestures of lower priority (06 §7: a double tap
/// fires only the double-tap action).
package final class TapRecognizer: GestureRecognizer {
    package static let movementTolerance: CGFloat = 10
    package static let multiTapInterval: TimeInterval = 0.35
    package static let multiTapDistance: CGFloat = 40

    let count: Int
    private var taps = 0
    private var isDown = false
    private var downLocation = CGPoint.zero
    private var firstLocation: CGPoint?
    private var lastUp: TimeInterval = 0

    package init(count: Int, context: GestureContext) {
        self.count = max(1, count)
        super.init(context: context)
    }

    override package var defersLowerPriority: Bool { count > 1 && taps > 0 && phase == .possible }

    override package var deadline: TimeInterval? {
        guard phase == .possible, taps > 0, !isDown else { return nil }
        return lastUp + Self.multiTapInterval
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    override package func handle(_ input: GestureInput) {
        guard phase == .possible else { return }
        switch input {
        case .tick(let t):
            if taps > 0, !isDown, t - lastUp >= Self.multiTapInterval - 1e-9 { fail() }
        case .pointer(let p):
            switch p.phase {
            case .down:
                if taps > 0 {
                    if p.time - lastUp > Self.multiTapInterval + 1e-9 { fail(); return }
                    if let f = firstLocation, Self.distance(f, p.location) > Self.multiTapDistance { fail(); return }
                }
                isDown = true
                downLocation = p.location
                if firstLocation == nil { firstLocation = p.location }
            case .moved:
                if isDown, Self.distance(downLocation, p.location) > Self.movementTolerance { fail() }
            case .up:
                guard isDown else { return }
                isDown = false
                if Self.distance(downLocation, p.location) > Self.movementTolerance { fail(); return }
                taps += 1
                lastUp = p.time
                if taps >= count {
                    value = context.local(p.location)
                    phase = .ended
                }
            case .cancelled:
                fail()
            }
        }
    }
}

/// Recognizes one or more taps (fires on touch-up, 06 §7).
public struct TapGesture: Gesture {
    public typealias Value = Void
    public typealias Body = Never
    public var count: Int
    public init(count: Int = 1) { self.count = count }
}

extension TapGesture: PrimitiveGesture {
    package func _makeRecognizer(context: GestureContext) -> GestureRecognizer {
        WrappingRecognizer(base: TapRecognizer(count: count, context: context)) { _ in () }
    }
}

// MARK: - Composition

/// Two gestures recognized at the same time.
public struct SimultaneousGesture<First: Gesture, Second: Gesture>: Gesture {
    public typealias Body = Never
    public var first: First
    public var second: Second

    public init(_ first: First, _ second: Second) {
        self.first = first
        self.second = second
    }

    /// The values of both gestures (nil for one that has not started).
    public struct Value {
        public var first: First.Value?
        public var second: Second.Value?
    }
}

extension SimultaneousGesture.Value: Equatable where First.Value: Equatable, Second.Value: Equatable {}
extension SimultaneousGesture.Value: Hashable where First.Value: Hashable, Second.Value: Hashable {}

/// Runs two recognizers side by side; its value is the pair of their
/// current values (nil for one that has not started).
package final class SimultaneousRecognizer: GestureRecognizer {
    let a: GestureRecognizer
    let b: GestureRecognizer
    let combine: (Any?, Any?) -> Any

    init(_ a: GestureRecognizer, _ b: GestureRecognizer, combine: @escaping (Any?, Any?) -> Any) {
        self.a = a
        self.b = b
        self.combine = combine
        super.init(context: a.context)
    }

    override package var deadline: TimeInterval? { [a.deadline, b.deadline].compactMap { $0 }.min() }

    override package func handle(_ input: GestureInput) {
        if !a.phase.isResolved { a.handle(input) }
        if !b.phase.isResolved { b.handle(input) }
        let pa = a.phase, pb = b.phase
        if pa.isResolved && pb.isResolved {
            phase = (pa == .ended || pb == .ended) ? .ended : .failed
        } else if pa == .active || pa == .ended || pb == .active || pb == .ended {
            phase = .active
        } else {
            phase = .possible
        }
        let va = a.currentValue, vb = b.currentValue
        if phase == .possible {
            provisionalValue = (va == nil && vb == nil) ? nil : combine(va, vb)
        } else {
            value = combine(va, vb)
        }
    }

    override package func flush() {
        a.flush()
        b.flush()
    }

    override package func cancel() {
        a.cancel()
        b.cancel()
        super.cancel()
    }
}

extension SimultaneousGesture: PrimitiveGesture {
    package func _makeRecognizer(context: GestureContext) -> GestureRecognizer {
        SimultaneousRecognizer(GestureFactory.make(first, context: context), GestureFactory.make(second, context: context)) {
            Value(first: $0 as? First.Value, second: $1 as? Second.Value)
        }
    }
}

/// The first gesture, or the second if the first fails.
public struct ExclusiveGesture<First: Gesture, Second: Gesture>: Gesture {
    public typealias Body = Never
    public var first: First
    public var second: Second

    public init(_ first: First, _ second: Second) {
        self.first = first
        self.second = second
    }

    /// Which gesture was recognized, with its value.
    public enum Value {
        case first(First.Value)
        case second(Second.Value)
    }
}

extension ExclusiveGesture.Value: Equatable where First.Value: Equatable, Second.Value: Equatable {}

/// The first recognizer, or the second once the first failed.
package final class ExclusiveRecognizer: GestureRecognizer {
    let a: GestureRecognizer
    let b: GestureRecognizer
    let wrapFirst: (Any) -> Any
    let wrapSecond: (Any) -> Any

    init(_ a: GestureRecognizer, _ b: GestureRecognizer, first: @escaping (Any) -> Any,
         second: @escaping (Any) -> Any) {
        self.a = a
        self.b = b
        wrapFirst = first
        wrapSecond = second
        super.init(context: a.context)
    }

    override package var deadline: TimeInterval? { [a.deadline, b.deadline].compactMap { $0 }.min() }
    override package var defersLowerPriority: Bool { a.defersLowerPriority || b.defersLowerPriority }

    override package func handle(_ input: GestureInput) {
        if !a.phase.isResolved { a.handle(input) }
        if !b.phase.isResolved { b.handle(input) }
        switch a.phase {
        case .active, .ended:
            phase = a.phase
            value = a.value.map(wrapFirst)
            if !b.phase.isResolved { b.cancel() }
        case .possible:
            phase = .possible
            provisionalValue = a.provisionalValue.map(wrapFirst)
        case .failed:
            phase = b.phase
            value = b.value.map(wrapSecond)
            provisionalValue = b.provisionalValue.map(wrapSecond)
        }
    }

    override package func flush() {
        if a.phase == .failed { b.flush() } else { a.flush() }
    }

    override package func cancel() {
        a.cancel()
        b.cancel()
        super.cancel()
    }
}

// swiftlint:disable:next force_cast - recognizer values are the gestures' Values by construction
private func cast<T>(_ v: Any) -> T { v as! T }

extension ExclusiveGesture: PrimitiveGesture {
    package func _makeRecognizer(context: GestureContext) -> GestureRecognizer {
        ExclusiveRecognizer(GestureFactory.make(first, context: context), GestureFactory.make(second, context: context),
                            first: { Value.first(cast($0)) }, second: { Value.second(cast($0)) })
    }
}

// MARK: - Masks and modifiers

/// Which gestures of a view and its subviews are enabled.
public struct GestureMask: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let none = GestureMask([])
    /// The gesture being attached.
    public static let gesture = GestureMask(rawValue: 1)
    /// Gestures of the view's subviews.
    public static let subviews = GestureMask(rawValue: 2)
    public static let all = GestureMask([.gesture, .subviews])
}

/// Keyboard modifiers of an event.
public struct EventModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let capsLock = EventModifiers(rawValue: 1 << 0)
    public static let shift = EventModifiers(rawValue: 1 << 1)
    public static let control = EventModifiers(rawValue: 1 << 2)
    public static let option = EventModifiers(rawValue: 1 << 3)
    public static let command = EventModifiers(rawValue: 1 << 4)
    public static let numericPad = EventModifiers(rawValue: 1 << 5)
    @available(*, deprecated, message: "Function keys are not modifiers")
    public static let function = EventModifiers(rawValue: 1 << 6)
    public static let all = EventModifiers(rawValue: 0x3F)
}
