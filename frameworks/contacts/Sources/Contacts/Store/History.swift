// Change history (interface.md §6.2): tokens, requests, events and the visitor.

import Foundation

public final class CNChangeHistoryFetchRequest: CNFetchRequest, @unchecked Sendable {
    public var startingToken: Data?
    public var additionalContactKeyDescriptors: [CNKeyDescriptor]?
    public var shouldUnifyResults = true
    public var mutableObjects = false
    public var includeGroupChanges = false
    public var excludedTransactionAuthors: [String]?

    public override init() { super.init() }
}

/// Receives history events; only the drop-everything event is required.
public protocol CNChangeHistoryEventVisitor: AnyObject {
    func visit(_ event: CNChangeHistoryDropEverythingEvent)
    func visit(_ event: CNChangeHistoryAddContactEvent)
    func visit(_ event: CNChangeHistoryUpdateContactEvent)
    func visit(_ event: CNChangeHistoryDeleteContactEvent)
    func visit(_ event: CNChangeHistoryAddGroupEvent)
    func visit(_ event: CNChangeHistoryUpdateGroupEvent)
    func visit(_ event: CNChangeHistoryDeleteGroupEvent)
    func visit(_ event: CNChangeHistoryAddMemberToGroupEvent)
    func visit(_ event: CNChangeHistoryRemoveMemberFromGroupEvent)
    func visit(_ event: CNChangeHistoryAddSubgroupToGroupEvent)
    func visit(_ event: CNChangeHistoryRemoveSubgroupFromGroupEvent)
}

extension CNChangeHistoryEventVisitor {
    public func visit(_ event: CNChangeHistoryAddContactEvent) {}
    public func visit(_ event: CNChangeHistoryUpdateContactEvent) {}
    public func visit(_ event: CNChangeHistoryDeleteContactEvent) {}
    public func visit(_ event: CNChangeHistoryAddGroupEvent) {}
    public func visit(_ event: CNChangeHistoryUpdateGroupEvent) {}
    public func visit(_ event: CNChangeHistoryDeleteGroupEvent) {}
    public func visit(_ event: CNChangeHistoryAddMemberToGroupEvent) {}
    public func visit(_ event: CNChangeHistoryRemoveMemberFromGroupEvent) {}
    public func visit(_ event: CNChangeHistoryAddSubgroupToGroupEvent) {}
    public func visit(_ event: CNChangeHistoryRemoveSubgroupFromGroupEvent) {}
}

public class CNChangeHistoryEvent: NSObject, NSCopying, @unchecked Sendable {
    override init() {}
    public func accept(_ visitor: CNChangeHistoryEventVisitor) {}
    public func copy(with zone: NSZone? = nil) -> Any { self }
}

public final class CNChangeHistoryDropEverythingEvent: CNChangeHistoryEvent, @unchecked Sendable {
    public override func accept(_ visitor: CNChangeHistoryEventVisitor) { visitor.visit(self) }
}

public final class CNChangeHistoryAddContactEvent: CNChangeHistoryEvent, @unchecked Sendable {
    public let contact: CNContact
    public let containerIdentifier: String?
    init(contact: CNContact, containerIdentifier: String?) {
        self.contact = contact
        self.containerIdentifier = containerIdentifier
    }
    public override func accept(_ visitor: CNChangeHistoryEventVisitor) { visitor.visit(self) }
}

public final class CNChangeHistoryUpdateContactEvent: CNChangeHistoryEvent, @unchecked Sendable {
    public let contact: CNContact
    init(contact: CNContact) { self.contact = contact }
    public override func accept(_ visitor: CNChangeHistoryEventVisitor) { visitor.visit(self) }
}

public final class CNChangeHistoryDeleteContactEvent: CNChangeHistoryEvent, @unchecked Sendable {
    public let contactIdentifier: String
    init(contactIdentifier: String) { self.contactIdentifier = contactIdentifier }
    public override func accept(_ visitor: CNChangeHistoryEventVisitor) { visitor.visit(self) }
}

public final class CNChangeHistoryAddGroupEvent: CNChangeHistoryEvent, @unchecked Sendable {
    public let group: CNGroup
    public let containerIdentifier: String?
    init(group: CNGroup, containerIdentifier: String?) {
        self.group = group
        self.containerIdentifier = containerIdentifier
    }
    public override func accept(_ visitor: CNChangeHistoryEventVisitor) { visitor.visit(self) }
}

public final class CNChangeHistoryUpdateGroupEvent: CNChangeHistoryEvent, @unchecked Sendable {
    public let group: CNGroup
    init(group: CNGroup) { self.group = group }
    public override func accept(_ visitor: CNChangeHistoryEventVisitor) { visitor.visit(self) }
}

public final class CNChangeHistoryDeleteGroupEvent: CNChangeHistoryEvent, @unchecked Sendable {
    public let groupIdentifier: String
    init(groupIdentifier: String) { self.groupIdentifier = groupIdentifier }
    public override func accept(_ visitor: CNChangeHistoryEventVisitor) { visitor.visit(self) }
}

public final class CNChangeHistoryAddMemberToGroupEvent: CNChangeHistoryEvent, @unchecked Sendable {
    public let member: CNContact
    public let group: CNGroup
    init(member: CNContact, group: CNGroup) {
        self.member = member
        self.group = group
    }
    public override func accept(_ visitor: CNChangeHistoryEventVisitor) { visitor.visit(self) }
}

public final class CNChangeHistoryRemoveMemberFromGroupEvent: CNChangeHistoryEvent, @unchecked Sendable {
    public let member: CNContact
    public let group: CNGroup
    init(member: CNContact, group: CNGroup) {
        self.member = member
        self.group = group
    }
    public override func accept(_ visitor: CNChangeHistoryEventVisitor) { visitor.visit(self) }
}

/// Subgroups do not exist on iOS; these events are never produced.
public final class CNChangeHistoryAddSubgroupToGroupEvent: CNChangeHistoryEvent, @unchecked Sendable {
    public let subgroup: CNGroup
    public let group: CNGroup
    init(subgroup: CNGroup, group: CNGroup) {
        self.subgroup = subgroup
        self.group = group
    }
    public override func accept(_ visitor: CNChangeHistoryEventVisitor) { visitor.visit(self) }
}

public final class CNChangeHistoryRemoveSubgroupFromGroupEvent: CNChangeHistoryEvent, @unchecked Sendable {
    public let subgroup: CNGroup
    public let group: CNGroup
    init(subgroup: CNGroup, group: CNGroup) {
        self.subgroup = subgroup
        self.group = group
    }
    public override func accept(_ visitor: CNChangeHistoryEventVisitor) { visitor.visit(self) }
}

/// Ycode's history token: "YCNH1:<database id>:<journal sequence>" in UTF-8.
/// Apps treat tokens as opaque data.
enum HistoryToken {
    static func make(databaseID: String, seq: Int64) -> Data {
        Data("YCNH1:\(databaseID):\(seq)".utf8)
    }

    static func parse(_ data: Data, databaseID: String) -> Int64? {
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "YCNH1", parts[1] == databaseID, let n = Int64(parts[2]) else { return nil }
        return n
    }
}
