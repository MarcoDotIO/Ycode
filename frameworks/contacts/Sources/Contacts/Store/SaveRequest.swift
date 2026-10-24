// CNSaveRequest (interface.md §5): a batch of adds, updates and deletes
// executed atomically by CNContactStore.execute(_:).

import Foundation

public final class CNSaveRequest: NSObject, @unchecked Sendable {
    enum Operation {
        case addContact(CNMutableContact, String?)
        case updateContact(CNMutableContact)
        case deleteContact(CNMutableContact)
        case addGroup(CNMutableGroup, String?)
        case updateGroup(CNMutableGroup)
        case deleteGroup(CNMutableGroup)
        case addMember(CNContact, CNGroup)
        case removeMember(CNContact, CNGroup)
    }

    var operations: [Operation] = []
    /// Identifies this request in change notifications.
    let saveIdentifier = UUID().uuidString

    /// Recorded with each change; history requests can exclude it.
    public var transactionAuthor: String?
    public var shouldRefetchContacts = true

    public override init() { super.init() }

    public func add(_ contact: CNMutableContact, toContainerWithIdentifier identifier: String?) {
        operations.append(.addContact(contact, identifier))
    }

    public func update(_ contact: CNMutableContact) { operations.append(.updateContact(contact)) }

    public func delete(_ contact: CNMutableContact) { operations.append(.deleteContact(contact)) }

    public func add(_ group: CNMutableGroup, toContainerWithIdentifier identifier: String?) {
        operations.append(.addGroup(group, identifier))
    }

    public func update(_ group: CNMutableGroup) { operations.append(.updateGroup(group)) }

    public func delete(_ group: CNMutableGroup) { operations.append(.deleteGroup(group)) }

    public func addMember(_ contact: CNContact, to group: CNGroup) { operations.append(.addMember(contact, group)) }

    public func removeMember(_ contact: CNContact, from group: CNGroup) { operations.append(.removeMember(contact, group)) }

    @available(*, unavailable, message: "Subgroups are not available on iOS")
    public func addSubgroup(_ subgroup: CNGroup, to group: CNGroup) {}

    @available(*, unavailable, message: "Subgroups are not available on iOS")
    public func removeSubgroup(_ subgroup: CNGroup, from group: CNGroup) {}
}
