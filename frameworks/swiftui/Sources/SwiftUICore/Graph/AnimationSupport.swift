import Foundation

// Graph hooks for animation (R6): which views continue an insertion chain
// (transitions apply at the root of an insertion, Animation/Transition.swift)
// and how transaction modifiers rewrite the transaction for views a pass did
// not visit (layout geometry animates per the transaction that reaches each
// view, Graph/ViewGraph.swift).

/// A primitive view through which an insertion continues to some children.
@MainActor
package protocol InsertionChaining {
    func _passesInsertion(childKey: AnyHashable) -> Bool
}

/// A primitive view that rewrites the transaction of its children.
@MainActor
package protocol TransactionRewriting {
    /// The children's transaction when the view's value did not change.
    func _unchangedTransaction(_ transaction: Transaction, node: ViewNode) -> Transaction
}

extension ModifiedContent: InsertionChaining where Content: View, Modifier: ViewModifier {
    /// The content continues the chain; a background or overlay does not.
    package func _passesInsertion(childKey: AnyHashable) -> Bool { childKey == AnyHashable(0) }
}

extension ModifiedContent: TransactionRewriting where Content: View, Modifier: ViewModifier {
    package func _unchangedTransaction(_ transaction: Transaction, node: ViewNode) -> Transaction {
        guard let pm = modifier as? any PrimitiveModifier else { return transaction }
        func open<M: PrimitiveModifier>(_ m: M) -> Transaction { m._transaction(transaction, old: m, node: node) }
        return open(pm)
    }
}

extension AnyView: InsertionChaining {
    package func _passesInsertion(childKey: AnyHashable) -> Bool { true }
}

extension IDView: InsertionChaining {
    package func _passesInsertion(childKey: AnyHashable) -> Bool { true }
}

extension Optional: InsertionChaining where Wrapped: View {
    package func _passesInsertion(childKey: AnyHashable) -> Bool { true }
}

extension _ConditionalContent: InsertionChaining {
    package func _passesInsertion(childKey: AnyHashable) -> Bool { true }
}

extension Group: InsertionChaining where Content: View {
    package func _passesInsertion(childKey: AnyHashable) -> Bool { true }
}

extension _ViewModifier_Content: InsertionChaining {
    package func _passesInsertion(childKey: AnyHashable) -> Bool { true }
}

extension PlaceholderContentView: InsertionChaining {
    package func _passesInsertion(childKey: AnyHashable) -> Bool { true }
}
