import Foundation
import Observation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Focused values (round R11; public API: `FocusedValueKey`, `FocusedValues`,
// `focusedValue(_:_:)`, `focusedSceneValue(_:_:)`, `@FocusedValue`,
// `@FocusedBinding`, `focusedObject`, `@FocusedObject`). They let commands
// (menu items) and other views read values published by the part of the
// window that has keyboard focus, typically to enable or disable a command.
//
// Design (Ycode's): each window has a `FocusedValuesCenter` (observable). A
// `focusedValue` modifier registers its value with the center; after every
// update of the window the center recomputes the current values: it walks
// from the focused view up through its ancestors and takes, for each key,
// the innermost publication on that chain; keys with no publication on the
// chain then take a `focusedSceneValue` of the window (the last one
// registered). With nothing focused only scene values are present. Readers
// depend on the center through Observation, so a reader's body runs again
// only when the set of publications it sees changes (publisher, key, value
// generation). Pop-up windows (menus) read their owner window's center.

/// A key for a value published with `focusedValue(_:_:)`.
public protocol FocusedValueKey {
    associatedtype Value
}

/// The values published by the focused part of a window.
public struct FocusedValues {
    var storage: [ObjectIdentifier: Any] = [:]

    public init() {}

    public subscript<Key: FocusedValueKey>(key: Key.Type) -> Key.Value? {
        get { storage[ObjectIdentifier(key)] as? Key.Value }
        set { storage[ObjectIdentifier(key)] = newValue }
    }
}

extension FocusedValues: @unchecked Sendable {}

/// One `focusedValue` / `focusedSceneValue` registration.
@MainActor
final class FocusedValuePublication {
    weak var node: ViewNode?
    let isScene: Bool
    var apply: (inout FocusedValues) -> Void
    var keyID: AnyHashable
    var generation = 0
    let order: Int

    init(node: ViewNode, isScene: Bool, keyID: AnyHashable, order: Int, apply: @escaping (inout FocusedValues) -> Void) {
        self.node = node
        self.isScene = isScene
        self.keyID = keyID
        self.order = order
        self.apply = apply
    }
}

/// The focused values of one window.
@MainActor
@Observable
package final class FocusedValuesCenter {
    /// The current values (readers depend on this).
    package private(set) var values = FocusedValues()

    @ObservationIgnored private var publications: [ObjectIdentifier: FocusedValuePublication] = [:]
    @ObservationIgnored private var signature: [String] = []
    @ObservationIgnored private var counter = 0

    package init() {}

    func publish(_ owner: AnyObject, node: ViewNode, isScene: Bool, keyID: AnyHashable, changed: Bool,
                 apply: @escaping (inout FocusedValues) -> Void) {
        let id = ObjectIdentifier(owner)
        if let p = publications[id] {
            p.apply = apply
            p.keyID = keyID
            p.node = node
            if changed { p.generation += 1 }
        } else {
            counter += 1
            publications[id] = FocusedValuePublication(node: node, isScene: isScene, keyID: keyID, order: counter, apply: apply)
        }
    }

    func withdraw(_ owner: AnyObject) { publications[ObjectIdentifier(owner)] = nil }

    /// Recomputes the values for the focused node (nil: nothing focused).
    package func recompute(focused: ViewNode?) {
        publications = publications.filter { $0.value.node?.isAlive == true }
        var byNode: [ObjectIdentifier: [FocusedValuePublication]] = [:]
        for p in publications.values where !p.isScene {
            guard let n = p.node else { continue }
            byNode[ObjectIdentifier(n), default: []].append(p)
        }
        var chosen: [AnyHashable: FocusedValuePublication] = [:]
        var n = focused
        while let node = n {
            for p in (byNode[ObjectIdentifier(node)] ?? []).sorted(by: { $0.order < $1.order })
            where chosen[p.keyID] == nil {
                chosen[p.keyID] = p
            }
            n = node.parent
        }
        for p in publications.values.filter(\.isScene).sorted(by: { $0.order < $1.order })
        where p.node?.isInSuspendedSubtree == false {
            // Scene values fill keys the focus chain does not publish; a
            // later registration replaces an earlier one.
            if let c = chosen[p.keyID], !c.isScene { continue }
            chosen[p.keyID] = p
        }
        let sig = chosen.values.sorted { $0.order < $1.order }.map { "\($0.order):\($0.generation)" }
        guard sig != signature else { return }
        signature = sig
        var v = FocusedValues()
        for p in chosen.values.sorted(by: { $0.order < $1.order }) { p.apply(&v) }
        values = v
    }

    package var publicationCount: Int { publications.count }
}

private enum FocusedValuesCenterKey: EnvironmentKey {
    static let defaultValue: FocusedValuesCenter? = nil
}

extension EnvironmentValues {
    /// The window's focused values (pop-ups carry their owner's).
    package var _focusedValues: FocusedValuesCenter? {
        get { self[FocusedValuesCenterKey.self] }
        set { self[FocusedValuesCenterKey.self] = newValue }
    }
}

// MARK: - Publishing

final class FocusedValuePublisherState {
    weak var center: FocusedValuesCenter?
}

struct FocusedValueModifier<Value>: PrimitiveModifier {
    let keyPath: WritableKeyPath<FocusedValues, Value?>
    let value: Value?
    let isScene: Bool

    private func sync(_ node: ViewNode, old: FocusedValueModifier?) {
        let s = (node.primitiveState as? FocusedValuePublisherState) ?? FocusedValuePublisherState()
        node.primitiveState = s
        guard let center = node.environment._focusedValues else { return }
        if s.center !== center { s.center?.withdraw(s) }
        s.center = center
        let kp = keyPath, v = value
        var changed = true
        if let old, let a = old.value as? any Equatable, let b = value {
            changed = !equalAny(a, b)
        } else if old != nil, old?.value == nil, value == nil {
            changed = false
        }
        center.publish(s, node: node, isScene: isScene, keyID: AnyHashable(kp), changed: changed) { values in
            values[keyPath: kp] = v
        }
    }

    func _inserted(node: ViewNode) { sync(node, old: nil) }
    func _updated(old: FocusedValueModifier, node: ViewNode) { sync(node, old: old) }
    func _removed(node: ViewNode) {
        guard let s = node.primitiveState as? FocusedValuePublisherState else { return }
        s.center?.withdraw(s)
    }
}

private func equalAny<A: Equatable>(_ a: A, _ b: Any) -> Bool {
    guard let b = b as? A else { return false }
    return a == b
}

extension View {
    /// Publishes `value` for `keyPath` while this view (or a view inside it)
    /// has keyboard focus.
    public func focusedValue<Value>(_ keyPath: WritableKeyPath<FocusedValues, Value?>, _ value: Value) -> some View {
        modifier(FocusedValueModifier(keyPath: keyPath, value: value, isScene: false))
    }

    /// Publishes `value` (nil withdraws it) while this view has focus.
    public func focusedValue<Value>(_ keyPath: WritableKeyPath<FocusedValues, Value?>, _ value: Value?) -> some View {
        modifier(FocusedValueModifier(keyPath: keyPath, value: value, isScene: false))
    }

    /// Publishes `value` for `keyPath` while the window is shown, wherever the
    /// focus is in it.
    public func focusedSceneValue<Value>(_ keyPath: WritableKeyPath<FocusedValues, Value?>, _ value: Value) -> some View {
        modifier(FocusedValueModifier(keyPath: keyPath, value: value, isScene: true))
    }

    public func focusedSceneValue<Value>(_ keyPath: WritableKeyPath<FocusedValues, Value?>, _ value: Value?) -> some View {
        modifier(FocusedValueModifier(keyPath: keyPath, value: value, isScene: true))
    }

    /// Publishes an observable object (read with `@FocusedObject` or
    /// `@FocusedValue(Type.self)`).
    public func focusedObject<T: AnyObject>(_ object: T?) -> some View {
        modifier(FocusedValueModifier(keyPath: \FocusedValues.[_objectKey: ObjectIdentifier(T.self)], value: object.map { $0 as AnyObject },
                                      isScene: false))
    }

    public func focusedSceneObject<T: AnyObject>(_ object: T?) -> some View {
        modifier(FocusedValueModifier(keyPath: \FocusedValues.[_objectKey: ObjectIdentifier(T.self)], value: object.map { $0 as AnyObject },
                                      isScene: true))
    }

    /// `focusedValue(_ object:)` for `@Observable` models (read with
    /// `@FocusedValue(Type.self)`).
    public func focusedValue<T: AnyObject & Observable>(_ object: T?) -> some View { focusedObject(object) }

    public func focusedSceneValue<T: AnyObject & Observable>(_ object: T?) -> some View { focusedSceneObject(object) }
}

extension FocusedValues {
    /// Storage for published objects, one slot per type.
    subscript(_objectKey type: ObjectIdentifier) -> AnyObject? {
        get { storage[type] as? AnyObject }
        set { storage[type] = newValue }
    }
}

// MARK: - Reading

/// Reads a value published by the focused part of the window.
@propertyWrapper
public struct FocusedValue<Value>: DynamicProperty {
    let box: FocusedReadBox
    let read: (FocusedValues) -> Value?

    public init(_ keyPath: KeyPath<FocusedValues, Value?>) {
        box = FocusedReadBox()
        read = { $0[keyPath: keyPath] }
    }

    public init(_ objectType: Value.Type) where Value: AnyObject {
        box = FocusedReadBox()
        read = { $0[_objectKey: ObjectIdentifier(objectType)] as? Value }
    }

    @MainActor public var wrappedValue: Value? { read(box.values) }
}

/// Reads a binding published by the focused part of the window.
@propertyWrapper
public struct FocusedBinding<Value>: DynamicProperty {
    let box: FocusedReadBox
    let read: (FocusedValues) -> Binding<Value>?

    public init(_ keyPath: KeyPath<FocusedValues, Binding<Value>?>) {
        box = FocusedReadBox()
        read = { $0[keyPath: keyPath] }
    }

    @MainActor public var wrappedValue: Value? {
        get { read(box.values)?.wrappedValue }
        nonmutating set {
            if let v = newValue { read(box.values)?.wrappedValue = v }
        }
    }

    @MainActor public var projectedValue: Binding<Value?> {
        let b = read(box.values)
        return Binding(get: { b?.wrappedValue }, set: { if let v = $0 { b?.wrappedValue = v } })
    }
}

/// Reads an object published with `focusedObject(_:)`.
@propertyWrapper
public struct FocusedObject<ObjectType: AnyObject>: DynamicProperty {
    let box = FocusedReadBox()
    public init() {}
    @MainActor public var wrappedValue: ObjectType? { box.values[_objectKey: ObjectIdentifier(ObjectType.self)] as? ObjectType }
}

/// Where a focused-value reader finds its window's values.
final class FocusedReadBox: @unchecked Sendable {
    weak var node: ViewNode?
    @MainActor var values: FocusedValues { node?.environment._focusedValues?.values ?? FocusedValues() }
}

extension FocusedValue: GraphDynamicProperty, @unchecked Sendable {
    package func _install(in node: ViewNode, slot: Int) { box.node = node }
}

extension FocusedBinding: GraphDynamicProperty, @unchecked Sendable {
    package func _install(in node: ViewNode, slot: Int) { box.node = node }
}

extension FocusedObject: GraphDynamicProperty, @unchecked Sendable {
    package func _install(in node: ViewNode, slot: Int) { box.node = node }
}

extension FocusedValue: GraphInputComparable {
    package func _isGraphInputEqual(to other: Any) -> Bool { true }
}

extension FocusedBinding: GraphInputComparable {
    package func _isGraphInputEqual(to other: Any) -> Bool { true }
}

extension FocusedObject: GraphInputComparable {
    package func _isGraphInputEqual(to other: Any) -> Bool { true }
}
