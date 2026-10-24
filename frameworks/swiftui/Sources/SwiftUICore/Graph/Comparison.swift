import Foundation

// Input comparison (03-architecture.md §4.2 rules 1–2; 09-open-design.md
// §3.2): when a parent re-creates a child's value, the child's body runs only
// if one of its stored inputs differs. Inputs are compared field by field:
// plain values by value, class references by identity, closures never equal.
// A view type's own `==` is *not* consulted for its fields' combination (the
// measured `.equatable()` case of 03 §4.1); `EquatableView` decides when it is.

/// A stored property kind that knows how it compares as a view input
/// (property wrappers whose value lives in the graph, bindings, …).
package protocol GraphInputComparable {
    func _isGraphInputEqual(to other: Any) -> Bool
}

package enum GraphComparison {
    /// Maximum nesting followed when comparing structurally.
    static let maxDepth = 12

    /// Field-by-field comparison of two view (or modifier) values of the same
    /// type. The value's own `Equatable` conformance is not used at this
    /// level; each field is compared with `valuesEqual`.
    package static func fieldsEqual(_ a: Any, _ b: Any) -> Bool {
        guard ObjectIdentifier(type(of: a)) == ObjectIdentifier(type(of: b)) else { return false }
        if let g = a as? any GraphInputComparable { return g._isGraphInputEqual(to: b) }
        let ma = Mirror(reflecting: a), mb = Mirror(reflecting: b)
        if ma.displayStyle == .class { return identical(a, b) }
        return childrenEqual(ma, mb, depth: 0)
    }

    /// Comparison of two arbitrary values: graph-aware wrappers first, then
    /// closures (never equal), class instances (identity), `Equatable`
    /// values (`==`), and finally a structural comparison of stored fields.
    package static func valuesEqual(_ a: Any, _ b: Any) -> Bool { valuesEqual(a, b, depth: 0) }

    private static func valuesEqual(_ a: Any, _ b: Any, depth: Int) -> Bool {
        guard depth <= maxDepth else { return false }
        guard ObjectIdentifier(type(of: a)) == ObjectIdentifier(type(of: b)) else { return false }
        if let g = a as? any GraphInputComparable { return g._isGraphInputEqual(to: b) }
        let ma = Mirror(reflecting: a)
        if ma.displayStyle == .class { return identical(a, b) }
        if isFunction(a, ma) { return false }
        if let e = a as? any Equatable { return equatableEqual(e, b) }
        let mb = Mirror(reflecting: b)
        switch ma.displayStyle {
        case .optional?:
            let ca = Array(ma.children), cb = Array(mb.children)
            if ca.isEmpty || cb.isEmpty { return ca.isEmpty && cb.isEmpty }
            return valuesEqual(ca[0].value, cb[0].value, depth: depth + 1)
        case .struct?, .tuple?, .collection?:
            return childrenEqual(ma, mb, depth: depth)
        case .enum?:
            let ca = Array(ma.children), cb = Array(mb.children)
            if ca.isEmpty && cb.isEmpty { return String(describing: a) == String(describing: b) }
            return childrenEqual(ma, mb, depth: depth)
        default:
            return false
        }
    }

    private static func childrenEqual(_ ma: Mirror, _ mb: Mirror, depth: Int) -> Bool {
        let ca = Array(ma.children), cb = Array(mb.children)
        guard ca.count == cb.count else { return false }
        for (x, y) in zip(ca, cb) {
            guard x.label == y.label, valuesEqual(x.value, y.value, depth: depth + 1) else { return false }
        }
        return true
    }

    private static func identical(_ a: Any, _ b: Any) -> Bool {
        (a as AnyObject) === (b as AnyObject)
    }

    private static func isFunction(_ a: Any, _ m: Mirror) -> Bool {
        m.displayStyle == nil && m.children.isEmpty && String(describing: type(of: a)).contains("->")
    }

    private static func equatableEqual<T: Equatable>(_ a: T, _ b: Any) -> Bool {
        guard let b = b as? T else { return false }
        return a == b
    }
}
