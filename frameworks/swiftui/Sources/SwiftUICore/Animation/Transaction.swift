import Foundation

// Transactions (05-animation.md §1, §4.1). A state change happens inside a
// transaction; the transaction travels down the updated subtree, where
// `.animation(_:value:)` and `.transaction(_:)` modifiers may rewrite it.
// Completion handlers wait for the animations the transaction starts
// (AnimationRuntime.swift).

/// A key for a custom value carried by a `Transaction`.
public protocol TransactionKey {
    associatedtype Value
    static var defaultValue: Value { get }
}

/// When an animation completion handler runs.
public struct AnimationCompletionCriteria: Hashable, Sendable {
    private enum Kind: Hashable, Sendable { case logicallyComplete, removed }
    private let kind: Kind
    /// At the animation's nominal end (05 §4).
    public static let logicallyComplete = AnimationCompletionCriteria(kind: .logicallyComplete)
    /// When the animation is removed from the view.
    public static let removed = AnimationCompletionCriteria(kind: .removed)
}

/// The context of one state change: its animation and flags.
public struct Transaction {
    private var values: [ObjectIdentifier: Any] = [:]
    package var completions: [AnimationCompletionRecord] = []

    public init() {}

    public init(animation: Animation?) {
        self.init()
        self.animation = animation
    }

    public subscript<K: TransactionKey>(key: K.Type) -> K.Value {
        get {
            guard let v = values[ObjectIdentifier(key)] else { return K.defaultValue }
            // swiftlint:disable:next force_cast - storage is keyed by the key type, so the value has its Value type
            return v as! K.Value
        }
        set { values[ObjectIdentifier(key)] = newValue }
    }

    /// True when no value has been set.
    public var isEmpty: Bool { values.isEmpty && completions.isEmpty }

    /// The animation to apply to the changes of this transaction.
    public var animation: Animation? {
        get { self[AnimationKey.self] }
        set { self[AnimationKey.self] = newValue }
    }

    /// Disables implicit (`.animation(_:value:)`) animations in the
    /// subtree; the transaction's own animation is kept (05 §4.1).
    public var disablesAnimations: Bool {
        get { self[DisablesAnimationsKey.self] }
        set { self[DisablesAnimationsKey.self] = newValue }
    }

    /// The change is part of a continuous interaction (e.g. a drag).
    public var isContinuous: Bool {
        get { self[IsContinuousKey.self] }
        set { self[IsContinuousKey.self] = newValue }
    }

    public var tracksVelocity: Bool {
        get { self[TracksVelocityKey.self] }
        set { self[TracksVelocityKey.self] = newValue }
    }

    /// Adds a handler run when the transaction's animations complete.
    public mutating func addAnimationCompletion(criteria: AnimationCompletionCriteria = .logicallyComplete,
                                                _ completion: @escaping () -> Void) {
        completions.append(AnimationCompletionRecord(criteria: criteria, action: completion))
    }

    // MARK: The current transaction

    nonisolated(unsafe) private static var stack: [Transaction] = []

    /// The transaction of the code running now (`withTransaction` scopes).
    package static var _current: Transaction {
        guard MainActorCheck.isCurrent else { return Transaction() }
        return stack.last ?? Transaction()
    }

    package static func _with<R>(_ t: Transaction, _ body: () throws -> R) rethrows -> R {
        guard MainActorCheck.isCurrent else { return try body() }
        stack.append(t)
        defer { stack.removeLast() }
        return try body()
    }
}

private enum AnimationKey: TransactionKey { static var defaultValue: Animation? { nil } }
private enum DisablesAnimationsKey: TransactionKey { static var defaultValue: Bool { false } }
private enum IsContinuousKey: TransactionKey { static var defaultValue: Bool { false } }
private enum TracksVelocityKey: TransactionKey { static var defaultValue: Bool { false } }

/// Runs `body` with `transaction` as the transaction of its state changes.
public func withTransaction<Result>(_ transaction: Transaction, _ body: () throws -> Result) rethrows -> Result {
    try Transaction._with(transaction, body)
}

/// Runs `body` with one value of the current transaction changed.
public func withTransaction<R, V>(_ keyPath: WritableKeyPath<Transaction, V>, _ value: V,
                                  _ body: () throws -> R) rethrows -> R {
    var t = Transaction._current
    t[keyPath: keyPath] = value
    return try Transaction._with(t, body)
}

/// Runs `body` in a transaction whose animation is `animation`.
public func withAnimation<Result>(_ animation: Animation? = .default, _ body: () throws -> Result) rethrows -> Result {
    var t = Transaction._current
    t.animation = animation
    return try Transaction._with(t, body)
}

/// Runs `body` in an animated transaction and calls `completion` when the
/// animation completes per `completionCriteria`.
public func withAnimation<Result>(_ animation: Animation? = .default,
                                  completionCriteria: AnimationCompletionCriteria = .logicallyComplete,
                                  _ body: () throws -> Result, completion: @escaping () -> Void) rethrows -> Result {
    var t = Transaction._current
    t.animation = animation
    t.addAnimationCompletion(criteria: completionCriteria, completion)
    return try Transaction._with(t, body)
}
