import Foundation

// `Binding`: read/write access to storage owned elsewhere (03 §3). Reading
// through a binding while a body is evaluated records a dependency on the
// underlying storage, so the reader re-runs when it changes. As a view input,
// two bindings are equal when they refer to the same storage (same location
// and key path); bindings made from closures never compare equal.

@propertyWrapper
@dynamicMemberLookup
public struct Binding<Value> {
    /// The transaction used for writes through this binding (empty: the
    /// current one).
    public var transaction: Transaction

    package let getValue: () -> Value
    package let setValue: (Value, Transaction) -> Void
    /// Identity of the storage (nil for closure-made bindings).
    package let identity: AnyHashable?
    /// For `constant(_:)` bindings: the value (compared by value).
    package let constantValue: Value?

    package init(identity: AnyHashable?, constant: Value? = nil, transaction: Transaction = Transaction(),
                 get: @escaping () -> Value, set: @escaping (Value, Transaction) -> Void) {
        self.identity = identity
        self.constantValue = constant
        self.transaction = transaction
        self.getValue = get
        self.setValue = set
    }

    package init(location: StateLocation<Value>) {
        self.init(identity: AnyHashable(ObjectIdentifier(location)),
                  get: { location.read() },
                  set: { v, t in location.write(v, transaction: t) })
    }

    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        self.init(identity: nil, get: get, set: { v, _ in set(v) })
    }

    public init(get: @escaping () -> Value, set: @escaping (Value, Transaction) -> Void) {
        self.init(identity: nil, get: get, set: set)
    }

    /// A binding to an immutable value; writes are ignored.
    public static func constant(_ value: Value) -> Binding<Value> {
        Binding(identity: nil, constant: value, get: { value }, set: { _, _ in })
    }

    public var wrappedValue: Value {
        get { getValue() }
        nonmutating set { setValue(newValue, transaction.isEmpty ? Transaction._current : transaction) }
    }

    public var projectedValue: Binding<Value> { self }

    public init(projectedValue: Binding<Value>) { self = projectedValue }

    /// A binding to a property of the value.
    public subscript<Subject>(dynamicMember keyPath: WritableKeyPath<Value, Subject>) -> Binding<Subject> {
        let base = self
        return Binding<Subject>(
            identity: identity.map { AnyHashable([$0, AnyHashable(keyPath)]) },
            transaction: transaction,
            get: { base.getValue()[keyPath: keyPath] },
            set: { v, t in
                var whole = base.getValue()
                whole[keyPath: keyPath] = v
                base.setValue(whole, t)
            })
    }

    /// The same binding with writes made in `transaction`.
    public func transaction(_ transaction: Transaction) -> Binding<Value> {
        var b = self
        b.transaction = transaction
        return b
    }

    /// The same binding with writes animated by `animation`.
    public func animation(_ animation: Animation? = .default) -> Binding<Value> {
        var b = self
        b.transaction.animation = animation
        return b
    }
}

extension Binding {
    /// Wraps a non-optional binding as an optional one.
    public init<V>(_ base: Binding<V>) where Value == V? {
        self.init(identity: base.identity.map { AnyHashable([$0, AnyHashable("optional")]) },
                  transaction: base.transaction,
                  get: { Optional(base.getValue()) },
                  set: { v, t in if let v { base.setValue(v, t) } })
    }

    /// Unwraps an optional binding; nil when the value is nil.
    public init?(_ base: Binding<Value?>) {
        guard let initial = base.getValue() else { return nil }
        self.init(identity: base.identity.map { AnyHashable([$0, AnyHashable("unwrapped")]) },
                  transaction: base.transaction,
                  get: { base.getValue() ?? initial },
                  set: { v, t in base.setValue(v, t) })
    }

    /// Type-erases a binding to a hashable value.
    public init<V: Hashable>(_ base: Binding<V>) where Value == AnyHashable {
        self.init(identity: base.identity.map { AnyHashable([$0, AnyHashable("anyHashable")]) },
                  transaction: base.transaction,
                  get: { AnyHashable(base.getValue()) },
                  set: { v, t in if let v = v.base as? V { base.setValue(v, t) } })
    }
}

extension Binding: @unchecked Sendable {}

extension Binding: DynamicProperty {}

extension Binding: GraphInputComparable {
    package func _isGraphInputEqual(to other: Any) -> Bool {
        guard let o = other as? Binding<Value> else { return false }
        if let a = identity, let b = o.identity { return a == b }
        if let a = constantValue, let b = o.constantValue { return GraphComparison.valuesEqual(a, b) }
        return false
    }
}

extension Binding: Identifiable where Value: Identifiable {
    public var id: Value.ID { wrappedValue.id }
}
