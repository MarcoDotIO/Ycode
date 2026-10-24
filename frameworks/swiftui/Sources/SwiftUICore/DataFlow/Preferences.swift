import Foundation

// Preferences flow up (03-architecture.md §7): a key's values from sibling
// subtrees are combined with the key's `reduce` in declaration order
// (measured: `first,second`). Only subtrees that produce a value take part:
// the first value found starts the reduction (the key's default value is used
// where a reader needs a value and none was produced). `onPreferenceChange`
// runs when the reduced value changes; it also runs in the first update.

/// A named value produced by views and combined up the tree.
public protocol PreferenceKey {
    associatedtype Value
    static var defaultValue: Value { get }
    static func reduce(value: inout Value, nextValue: () -> Value)
}

/// The preference values of a subtree.
package struct PreferenceValues {
    package struct Entry {
        package var value: Any
        package let reduce: (inout Any, Any) -> Void
    }

    package private(set) var entries: [ObjectIdentifier: Entry] = [:]

    package init() {}

    package subscript<K: PreferenceKey>(key: K.Type) -> K.Value? {
        entries[ObjectIdentifier(key)].map { $0.value as! K.Value }
    }

    package mutating func set<K: PreferenceKey>(_ key: K.Type, _ value: K.Value) {
        entries[ObjectIdentifier(key)] = Entry(value: value) { acc, next in
            var v = acc as! K.Value
            K.reduce(value: &v) { next as! K.Value }
            acc = v
        }
    }

    package mutating func remove<K: PreferenceKey>(_ key: K.Type) { entries[ObjectIdentifier(key)] = nil }

    /// Combines a later sibling's values into these.
    package mutating func combine(with other: PreferenceValues) {
        for (id, e) in other.entries {
            if var mine = entries[id] {
                mine.reduce(&mine.value, e.value)
                entries[id] = mine
            } else {
                entries[id] = e
            }
        }
    }
}

// MARK: - Modifiers

/// `preference(key:value:)`: the view's value for the key (it replaces
/// values from inside the view).
package struct PreferenceWritingModifier<Key: PreferenceKey>: PrimitiveModifier {
    package let value: Key.Value

    package func _preferences(_ content: PreferenceValues, secondary: PreferenceValues?, node: ViewNode) -> PreferenceValues {
        var p = content
        if let secondary { p.combine(with: secondary) }
        p.set(Key.self, value)
        return p
    }
}

/// `transformPreference(_:_:)`.
package struct PreferenceTransformModifier<Key: PreferenceKey>: PrimitiveModifier {
    package let transform: (inout Key.Value) -> Void

    package func _preferences(_ content: PreferenceValues, secondary: PreferenceValues?, node: ViewNode) -> PreferenceValues {
        var p = content
        if let secondary { p.combine(with: secondary) }
        var v = p[Key.self] ?? Key.defaultValue
        transform(&v)
        p.set(Key.self, v)
        return p
    }
}

private final class PreferenceChangeState<Value> {
    var last: Value?
    var action: (Value) -> Void
    init(action: @escaping (Value) -> Void) { self.action = action }
}

/// `onPreferenceChange(_:perform:)`.
package struct PreferenceChangeModifier<Key: PreferenceKey>: PrimitiveModifier where Key.Value: Equatable {
    package let action: (Key.Value) -> Void

    package func _inserted(node: ViewNode) { node.primitiveState = PreferenceChangeState<Key.Value>(action: action) }

    package func _updated(old: PreferenceChangeModifier, node: ViewNode) {
        (node.primitiveState as? PreferenceChangeState<Key.Value>)?.action = action
    }

    package func _preferences(_ content: PreferenceValues, secondary: PreferenceValues?, node: ViewNode) -> PreferenceValues {
        var p = content
        if let secondary { p.combine(with: secondary) }
        let value = p[Key.self] ?? Key.defaultValue
        if let state = node.primitiveState as? PreferenceChangeState<Key.Value>, state.last != value {
            state.last = value
            node.graph.queuePreferenceAction { state.action(value) }
        }
        return p
    }
}

private final class PreferenceReaderState<Value> {
    var value: Value
    init(_ v: Value) { value = v }
}

/// `overlayPreferenceValue` / `backgroundPreferenceValue`: a secondary view
/// built from the content's reduced value. When the value changes after a
/// pass, the node is invalidated and the secondary view rebuilt in the next
/// pass. The secondary view's own preferences do not flow up.
package struct PreferenceReaderModifier<Key: PreferenceKey, Secondary: View>: PrimitiveModifier {
    package let alignment: Alignment
    package let isBackground: Bool
    package let build: (Key.Value) -> Secondary

    package func _inserted(node: ViewNode) { node.primitiveState = PreferenceReaderState(Key.defaultValue) }

    package func _secondary(node: ViewNode) -> (any View)? {
        let v = (node.primitiveState as? PreferenceReaderState<Key.Value>)?.value ?? Key.defaultValue
        return node.trackContent { build(v) }
    }

    package var _rebuildsWhenDirty: Bool { true }

    package func _lower(_ content: [LayoutNode], secondary: () -> [LayoutNode], node: ViewNode) -> [LayoutNode] {
        content.map { c in
            let s = secondary()
            let layer: LayoutNode = s.count == 1 ? s[0] : .zstack(alignment: alignment, s)
            return isBackground ? c.background(layer, alignment: alignment) : c.overlay(layer, alignment: alignment)
        }
    }

    package func _preferences(_ content: PreferenceValues, secondary: PreferenceValues?, node: ViewNode) -> PreferenceValues {
        let value = content[Key.self] ?? Key.defaultValue
        if let state = node.primitiveState as? PreferenceReaderState<Key.Value>,
           !GraphComparison.valuesEqual(state.value, value) {
            state.value = value
            node.invalidate(transaction: Transaction())
        }
        return content
    }
}

extension View {
    /// Sets a preference value for this view.
    public func preference<K: PreferenceKey>(key: K.Type = K.self, value: K.Value) -> some View {
        modifier(PreferenceWritingModifier<K>(value: value))
    }

    /// Transforms the preference value for `key` produced by this view.
    public func transformPreference<K: PreferenceKey>(_ key: K.Type = K.self,
                                                      _ callback: @escaping (inout K.Value) -> Void) -> some View {
        modifier(PreferenceTransformModifier<K>(transform: callback))
    }

    /// Runs `action` when the reduced value of `key` in this view changes.
    public func onPreferenceChange<K: PreferenceKey>(_ key: K.Type = K.self,
                                                     perform action: @escaping (K.Value) -> Void) -> some View
    where K.Value: Equatable {
        modifier(PreferenceChangeModifier<K>(action: action))
    }

    /// Overlays a view built from this view's reduced value for `key`.
    public func overlayPreferenceValue<K: PreferenceKey, V: View>(_ key: K.Type, alignment: Alignment = .center,
                                                                  @ViewBuilder _ transform: @escaping (K.Value) -> V) -> some View {
        modifier(PreferenceReaderModifier<K, V>(alignment: alignment, isBackground: false, build: transform))
    }

    /// Places a view built from this view's reduced value for `key` behind it.
    public func backgroundPreferenceValue<K: PreferenceKey, V: View>(_ key: K.Type, alignment: Alignment = .center,
                                                                     @ViewBuilder _ transform: @escaping (K.Value) -> V) -> some View {
        modifier(PreferenceReaderModifier<K, V>(alignment: alignment, isBackground: true, build: transform))
    }
}
