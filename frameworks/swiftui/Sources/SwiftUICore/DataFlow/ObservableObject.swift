import Foundation

// `ObservableObject` models (03 §3): dependency granularity is the whole
// object — any change published through `objectWillChange` re-runs every view
// that observes the object (`@ObservedObject`, `@StateObject`,
// `@EnvironmentObject`), whether or not its body read anything from it.
//
// On Apple hosts the protocol and `@Published` come from Combine (re-exported,
// as the reference SDK makes them visible through `import SwiftUI`). Linux has
// no Combine, so this module provides the same names with the subset of
// behaviour the view graph needs: `objectWillChange` with `send()` and
// `sink(receiveValue:)`, `@Published` (which sends `objectWillChange` before
// each change), `AnyCancellable`.

#if canImport(Combine)
@_exported import Combine

/// Subscribes to an object's will-change notifications.
package func subscribeToObjectWillChange<O: ObservableObject>(_ object: O, _ handler: @escaping () -> Void) -> AnyCancellable {
    object.objectWillChange.sink { _ in handler() }
}
#else

/// Something that can be subscribed to.
public protocol Publisher<Output, Failure> {
    associatedtype Output
    associatedtype Failure: Error
    func _subscribe(_ receive: @escaping (Output) -> Void) -> AnyCancellable
}

extension Publisher where Failure == Never {
    /// Calls `receiveValue` with every value published until the returned
    /// token is cancelled or released.
    public func sink(receiveValue: @escaping (Output) -> Void) -> AnyCancellable { _subscribe(receiveValue) }
}

/// A subscription token: cancels on `cancel()` or when released.
public final class AnyCancellable: Hashable, @unchecked Sendable {
    private var onCancel: (() -> Void)?

    public init(_ cancel: @escaping () -> Void) { onCancel = cancel }

    public func cancel() {
        let c = onCancel
        onCancel = nil
        c?()
    }

    deinit { onCancel?() }

    public func store(in set: inout Set<AnyCancellable>) { set.insert(self) }

    public static func == (a: AnyCancellable, b: AnyCancellable) -> Bool { a === b }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// Subscriber list shared by the publishers below.
package final class SubscriberList<Output>: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    private var subscribers: [Int: (Output) -> Void] = [:]

    package init() {}

    package func add(_ s: @escaping (Output) -> Void) -> AnyCancellable {
        lock.lock()
        let id = next
        next += 1
        subscribers[id] = s
        lock.unlock()
        return AnyCancellable { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.subscribers[id] = nil
            self.lock.unlock()
        }
    }

    package func send(_ value: Output) {
        lock.lock()
        let list = subscribers.sorted { $0.key < $1.key }.map(\.value)
        lock.unlock()
        for s in list { s(value) }
    }
}

/// The default `objectWillChange` publisher.
public final class ObservableObjectPublisher: Publisher, @unchecked Sendable {
    public typealias Output = Void
    public typealias Failure = Never

    private let list = SubscriberList<Void>()

    public init() {}

    public func send() { list.send(()) }

    public func _subscribe(_ receive: @escaping (Output) -> Void) -> AnyCancellable { list.add(receive) }
}

/// A class whose changes views observe as a whole.
public protocol ObservableObject: AnyObject {
    associatedtype ObjectWillChangePublisher: Publisher = ObservableObjectPublisher
        where ObjectWillChangePublisher.Failure == Never
    var objectWillChange: ObjectWillChangePublisher { get }
}

/// Per-object default publishers (objects cannot get stored properties from
/// a protocol extension).
private final class PublisherTable: @unchecked Sendable {
    private let lock = NSLock()
    private var table: [ObjectIdentifier: (object: Weak, publisher: ObservableObjectPublisher)] = [:]
    final class Weak { weak var object: AnyObject?; init(_ o: AnyObject) { object = o } }

    func publisher(for object: AnyObject) -> ObservableObjectPublisher {
        lock.lock()
        defer { lock.unlock() }
        let id = ObjectIdentifier(object)
        if let e = table[id], e.object.object === object { return e.publisher }
        if table.count > 256 { table = table.filter { $0.value.object.object != nil } }
        let p = ObservableObjectPublisher()
        table[id] = (Weak(object), p)
        return p
    }
}

private let publisherTable = PublisherTable()

extension ObservableObject where ObjectWillChangePublisher == ObservableObjectPublisher {
    public var objectWillChange: ObservableObjectPublisher { publisherTable.publisher(for: self) }
}

/// A property of an `ObservableObject` that announces its changes.
@propertyWrapper
public struct Published<Value> {
    package final class Storage: @unchecked Sendable {
        var value: Value
        let subscribers = SubscriberList<Value>()
        init(_ value: Value) { self.value = value }
    }

    private let storage: Storage

    public init(wrappedValue: Value) { storage = Storage(wrappedValue) }
    public init(initialValue: Value) { storage = Storage(initialValue) }

    @available(*, unavailable, message: "@Published is only available on properties of classes")
    public var wrappedValue: Value {
        get { fatalError() }
        set { fatalError() }
    }

    /// Publishes the property's new values.
    public struct Publisher: SwiftUICore.Publisher {
        public typealias Output = Value
        public typealias Failure = Never
        fileprivate let storage: Storage
        public func _subscribe(_ receive: @escaping (Value) -> Void) -> AnyCancellable {
            receive(storage.value)
            return storage.subscribers.add(receive)
        }
    }

    public var projectedValue: Publisher {
        get { Publisher(storage: storage) }
        set {}
    }

    public static subscript<EnclosingSelf: AnyObject>(
        _enclosingInstance object: EnclosingSelf,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Published<Value>>
    ) -> Value {
        get { object[keyPath: storageKeyPath].storage.value }
        set {
            if let o = object as? any ObservableObject { sendObjectWillChange(o) }
            let s = object[keyPath: storageKeyPath].storage
            s.value = newValue
            s.subscribers.send(newValue)
        }
    }
}

private func sendObjectWillChange<O: ObservableObject>(_ o: O) {
    (o.objectWillChange as? ObservableObjectPublisher)?.send()
}

extension Published: @unchecked Sendable {}

package func subscribeToObjectWillChange<O: ObservableObject>(_ object: O, _ handler: @escaping () -> Void) -> AnyCancellable {
    object.objectWillChange.sink { _ in handler() }
}
#endif

// MARK: - Property wrappers that observe objects

/// The graph-side record of a node's subscription to one object.
package final class ObjectSubscription {
    package var objectID: ObjectIdentifier?
    package var cancellable: AnyCancellable?
    package var object: AnyObject?

    package init() {}

    @MainActor package func observe<O: ObservableObject>(_ object: O, node: ViewNode) {
        guard objectID != ObjectIdentifier(object) else { return }
        objectID = ObjectIdentifier(object)
        self.object = object
        let ref = WeakNode(node)
        cancellable = subscribeToObjectWillChange(object) { ref.invalidate() }
    }
}

/// An object owned elsewhere that this view observes.
@propertyWrapper
public struct ObservedObject<ObjectType: ObservableObject>: DynamicProperty {
    /// Bindings to the object's properties (`$model.name`).
    @dynamicMemberLookup
    public struct Wrapper {
        package let root: ObjectType
        public subscript<Subject>(dynamicMember keyPath: ReferenceWritableKeyPath<ObjectType, Subject>) -> Binding<Subject> {
            objectBinding(root, keyPath)
        }
    }

    public var wrappedValue: ObjectType

    public init(wrappedValue: ObjectType) { self.wrappedValue = wrappedValue }
    public init(initialValue: ObjectType) { self.wrappedValue = initialValue }

    public var projectedValue: Wrapper { Wrapper(root: wrappedValue) }
}

extension ObservedObject: GraphDynamicProperty {
    package func _install(in node: ViewNode, slot: Int) {
        let sub = (node.slots[slot] as? ObjectSubscription) ?? ObjectSubscription()
        node.slots[slot] = sub
        sub.observe(wrappedValue, node: node)
    }
}

extension ObservedObject: GraphInputComparable {
    package func _isGraphInputEqual(to other: Any) -> Bool {
        guard let o = other as? ObservedObject<ObjectType> else { return false }
        return o.wrappedValue === wrappedValue
    }
}

package func objectBinding<Root: AnyObject, Subject>(_ root: Root, _ keyPath: ReferenceWritableKeyPath<Root, Subject>) -> Binding<Subject> {
    Binding(identity: AnyHashable([AnyHashable(ObjectIdentifier(root)), AnyHashable(keyPath)]),
            get: { root[keyPath: keyPath] },
            set: { v, t in withTransaction(t) { root[keyPath: keyPath] = v } })
}

package final class StateObjectBox<ObjectType: AnyObject>: @unchecked Sendable {
    package let thunk: () -> ObjectType
    package var object: ObjectType?
    package init(_ thunk: @escaping () -> ObjectType) { self.thunk = thunk }
}

private final class StateObjectSlot<ObjectType: ObservableObject> {
    let object: ObjectType
    let subscription = ObjectSubscription()
    init(_ object: ObjectType) { self.object = object }
}

/// An observable object owned by the view identity: created once, from the
/// first value's initialiser expression, and kept for the identity's
/// lifetime.
@propertyWrapper
public struct StateObject<ObjectType: ObservableObject>: DynamicProperty {
    package let box: StateObjectBox<ObjectType>

    public init(wrappedValue thunk: @autoclosure @escaping () -> ObjectType) {
        box = StateObjectBox(thunk)
    }

    public var wrappedValue: ObjectType {
        if let o = box.object { return o }
        let o = box.thunk()
        box.object = o
        return o
    }

    public var projectedValue: ObservedObject<ObjectType>.Wrapper { ObservedObject.Wrapper(root: wrappedValue) }
}

extension StateObject: GraphDynamicProperty {
    package func _install(in node: ViewNode, slot: Int) {
        let s: StateObjectSlot<ObjectType>
        if let existing = node.slots[slot] as? StateObjectSlot<ObjectType> {
            s = existing
        } else {
            s = StateObjectSlot(box.object ?? box.thunk())
            node.slots[slot] = s
        }
        box.object = s.object
        s.subscription.observe(s.object, node: node)
    }
}

extension StateObject: GraphInputComparable {
    package func _isGraphInputEqual(to other: Any) -> Bool { true }
}

private enum EnvironmentObjectKey<T: AnyObject>: EnvironmentKey {
    static var defaultValue: T? { nil }
}

extension EnvironmentValues {
    package subscript<T: ObservableObject>(environmentObject type: T.Type) -> T? {
        get { self[EnvironmentObjectKey<T>.self] }
        set { self[EnvironmentObjectKey<T>.self] = newValue }
    }
}

package final class EnvironmentObjectBox<ObjectType: AnyObject>: @unchecked Sendable {
    package var object: ObjectType?
    package init() {}
}

/// An observable object supplied by an ancestor with `environmentObject(_:)`.
@propertyWrapper
public struct EnvironmentObject<ObjectType: ObservableObject>: DynamicProperty {
    @dynamicMemberLookup
    public struct Wrapper {
        package let root: ObjectType
        public subscript<Subject>(dynamicMember keyPath: ReferenceWritableKeyPath<ObjectType, Subject>) -> Binding<Subject> {
            objectBinding(root, keyPath)
        }
    }

    package let box = EnvironmentObjectBox<ObjectType>()

    public init() {}

    public var wrappedValue: ObjectType {
        guard let o = box.object else {
            fatalError("No ObservableObject of type \(ObjectType.self) found. A View.environmentObject(_:) for \(ObjectType.self) may be missing as an ancestor of this view.")
        }
        return o
    }

    public var projectedValue: Wrapper { Wrapper(root: wrappedValue) }
}

extension EnvironmentObject: GraphDynamicProperty {
    package func _install(in node: ViewNode, slot: Int) {
        let object = node.environment[environmentObject: ObjectType.self]
        box.object = object
        // Which object the environment holds is itself a dependency.
        node.addEnvironmentDependency(key: AnyHashable(ObjectIdentifier(EnvironmentObjectKey<ObjectType>.self)),
                                      value: object.map { ObjectIdentifier($0) } as Any,
                                      read: { $0[environmentObject: ObjectType.self].map { ObjectIdentifier($0) } as Any })
        guard let object else { return }
        let sub = (node.slots[slot] as? ObjectSubscription) ?? ObjectSubscription()
        node.slots[slot] = sub
        sub.observe(object, node: node)
    }
}

extension EnvironmentObject: GraphInputComparable {
    package func _isGraphInputEqual(to other: Any) -> Bool { true }
}

extension View {
    /// Supplies an `ObservableObject` to the subtree's `@EnvironmentObject`s.
    public func environmentObject<T: ObservableObject>(_ object: T) -> some View {
        modifier(EnvironmentTransformModifier(label: "environmentObject \(T.self)", value: AnyHashable(ObjectIdentifier(object))) {
            $0[environmentObject: T.self] = object
        })
    }
}
