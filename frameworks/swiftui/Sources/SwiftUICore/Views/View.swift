import Foundation

// Views are values (03-architecture.md §1): a struct whose stored properties
// are its inputs and whose `body` computes another view. Primitive views have
// `Never` bodies and are interpreted by the graph runtime (Graph/), which
// keeps the long-lived identities and their state.

/// A piece of user interface: a value whose `body` describes its content.
@MainActor @preconcurrency
public protocol View {
    associatedtype Body: View
    @ViewBuilder @MainActor @preconcurrency var body: Body { get }
}

extension Never: View {
    public typealias Body = Never
    public var body: Never { fatalError("Never has no body") }
}

extension View where Body == Never {
    /// Primitive views have no body; the runtime interprets them.
    public var body: Never { fatalError("\(Self.self) is a primitive view and has no body") }
}

// MARK: - The runtime's view of primitives

/// A view the graph runtime interprets directly (stacks, text, modifiers, …).
///
/// `_makeChildren` reconciles the node's children with this (new) value;
/// `_refresh` is called when the node did not receive a new value but its
/// environment changed or a descendant was invalidated; `_lower` turns the
/// node into layout nodes for the R3 engine; `_preferences` reduces the
/// subtree's preference values (03 §7).
@MainActor
package protocol PrimitiveView: View where Body == Never {
    func _makeChildren(node: ViewNode, old: Self?, transaction: Transaction)
    func _refresh(node: ViewNode, environmentChanged: Bool, transaction: Transaction)
    func _lower(node: ViewNode) -> [LayoutNode]
    func _preferences(node: ViewNode) -> PreferenceValues
    /// The node is being removed (before its children).
    func _removed(node: ViewNode)
}

extension PrimitiveView {
    package func _refresh(node: ViewNode, environmentChanged: Bool, transaction: Transaction) {
        node.refreshChildren(transaction: transaction)
    }

    package func _lower(node: ViewNode) -> [LayoutNode] { node.lowerChildren() }

    package func _preferences(node: ViewNode) -> PreferenceValues { node.childPreferences() }

    package func _removed(node: ViewNode) {}
}

// MARK: - ViewBuilder

/// Builds one static view type from the statements of a closure (03 §1):
/// several children → `TupleView`, `if`/`else` → `_ConditionalContent`,
/// `if` alone → `Optional`, `switch` → nested conditionals.
@MainActor @resultBuilder
public struct ViewBuilder {
    public static func buildBlock() -> EmptyView { EmptyView() }

    public static func buildBlock<Content: View>(_ content: Content) -> Content { content }

    public static func buildBlock<each Content: View>(_ content: repeat each Content) -> TupleView<(repeat each Content)> {
        TupleView((repeat each content))
    }

    public static func buildIf<Content: View>(_ content: Content?) -> Content? { content }

    public static func buildEither<TrueContent: View, FalseContent: View>(first: TrueContent)
        -> _ConditionalContent<TrueContent, FalseContent> {
        _ConditionalContent(storage: .trueContent(first))
    }

    public static func buildEither<TrueContent: View, FalseContent: View>(second: FalseContent)
        -> _ConditionalContent<TrueContent, FalseContent> {
        _ConditionalContent(storage: .falseContent(second))
    }

    public static func buildLimitedAvailability<Content: View>(_ content: Content) -> AnyView { AnyView(content) }
}

// MARK: - Structural views

/// A view with no content: zero size, no spacing, left out by containers
/// (04-layout.md §2).
public struct EmptyView: View, Sendable {
    public init() {}
    public typealias Body = Never
}

extension EmptyView: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: EmptyView?, transaction: Transaction) {}
    package func _lower(node: ViewNode) -> [LayoutNode] { [] }
}

/// Several views built by one `ViewBuilder` block. Child *i* has structural
/// identity "element *i*".
public struct TupleView<T>: View {
    public var value: T
    public init(_ value: T) { self.value = value }
    public typealias Body = Never
}

extension TupleView: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: TupleView?, transaction: Transaction) {
        let views = Mirror(reflecting: value).children.map { child -> any View in
            guard let v = child.value as? any View else {
                fatalError("TupleView element \(type(of: child.value)) is not a View")
            }
            return v
        }
        node.reconcileChildren(views.enumerated().map { (AnyHashable($0.offset), $0.element) },
                               transaction: transaction)
    }
}

/// The result of `if`/`else` in a `ViewBuilder`: one of two views. Each branch
/// is a different identity (03 §2).
public struct _ConditionalContent<TrueContent: View, FalseContent: View>: View {
    package enum Storage {
        case trueContent(TrueContent)
        case falseContent(FalseContent)
    }
    package let storage: Storage
    package init(storage: Storage) { self.storage = storage }
    public typealias Body = Never
}

extension _ConditionalContent: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: _ConditionalContent?, transaction: Transaction) {
        switch storage {
        case .trueContent(let v): node.reconcileChildren([(AnyHashable(true), v)], transaction: transaction)
        case .falseContent(let v): node.reconcileChildren([(AnyHashable(false), v)], transaction: transaction)
        }
    }
}

extension Optional: View where Wrapped: View {
    public typealias Body = Never
}

extension Optional: PrimitiveView where Wrapped: View {
    package func _makeChildren(node: ViewNode, old: Optional?, transaction: Transaction) {
        switch self {
        case .some(let v): node.reconcileChildren([(AnyHashable(0), v)], transaction: transaction)
        case .none: node.reconcileChildren([], transaction: transaction)
        }
    }
}

/// A type-erased view. A change of the wrapped view's type is a change of
/// identity.
public struct AnyView: View {
    package let storage: any View

    public init<V: View>(_ view: V) {
        if let any = view as? AnyView { storage = any.storage } else { storage = view }
    }

    public init<V: View>(erasing view: V) { self.init(view) }

    public init?(_fromValue value: Any) {
        guard let v = value as? any View else { return nil }
        storage = v
    }

    public typealias Body = Never
}

extension AnyView: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: AnyView?, transaction: Transaction) {
        node.reconcileChildren([(AnyHashable(ObjectIdentifier(type(of: storage))), storage)], transaction: transaction)
    }
}

/// Groups views without affecting layout: modifiers applied to a group apply
/// to each of its views.
public struct Group<Content> {
    package let content: Content
    public typealias Body = Never
}

extension Group: View where Content: View {
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
}

extension Group: PrimitiveView where Content: View {
    package func _makeChildren(node: ViewNode, old: Group?, transaction: Transaction) {
        node.reconcileChildren([(AnyHashable(0), content)], transaction: transaction)
    }
}

/// Explicit identity: `view.id(value)` (03 §2). A new value is a new
/// identity — new state, and an appear/disappear pair.
package struct IDView<Content: View, ID: Hashable>: View {
    package let content: Content
    package let id: ID
    package typealias Body = Never
}

extension IDView: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: IDView?, transaction: Transaction) {
        node.reconcileChildren([(AnyHashable(id), content)], transaction: transaction)
    }
}

extension View {
    /// Gives the view an explicit identity.
    public func id<ID: Hashable>(_ id: ID) -> some View { IDView(content: self, id: id) }
}
