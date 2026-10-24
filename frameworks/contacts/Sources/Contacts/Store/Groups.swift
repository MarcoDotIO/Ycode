// Groups, containers, fetch requests and results (interface.md §1, §3, §4.1).

import Foundation

public class CNGroup: NSObject, NSCopying, NSMutableCopying, @unchecked Sendable {
    public let identifier: String
    var _name: String
    public var name: String { _name }

    init(identifier: String, name: String) {
        self.identifier = identifier
        self._name = name
    }

    /// An empty group with a new `<UUID>:ABGroup` identifier.
    public override convenience init() {
        self.init(identifier: newGroupIdentifier(), name: "")
    }

    public func copy(with zone: NSZone? = nil) -> Any {
        type(of: self) == CNGroup.self ? self : CNGroup(identifier: identifier, name: _name)
    }

    public func mutableCopy(with zone: NSZone? = nil) -> Any { CNMutableGroup(identifier: identifier, name: _name) }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? CNGroup else { return false }
        return o.identifier == identifier && o._name == _name
    }
    public override var hash: Int { identifier.hashValue }
    public override var description: String { "<\(type(of: self)): identifier=\(identifier), name=\(_name)>" }

    // MARK: Predicates

    public class func predicateForGroups(withIdentifiers identifiers: [String]) -> NSPredicate {
        CNStorePredicate(.groupIdentifiers(identifiers))
    }

    public class func predicateForGroupsInContainer(withIdentifier container: String) -> NSPredicate {
        CNStorePredicate(.groupsInContainer(container))
    }

    @available(*, unavailable, message: "Subgroups are not available on iOS")
    public class func predicateForSubgroupsInGroup(withIdentifier parentGroupIdentifier: String) -> NSPredicate {
        CNStorePredicate(.groupIdentifiers([]))
    }
}

public final class CNMutableGroup: CNGroup, @unchecked Sendable {
    public override var name: String {
        get { _name }
        set { _name = newValue }
    }

    public override func copy(with zone: NSZone? = nil) -> Any { CNGroup(identifier: identifier, name: _name) }
}

public final class CNContainer: NSObject, NSCopying, @unchecked Sendable {
    public let identifier: String
    public let name: String?
    public let type: CNContainerType

    init(identifier: String, name: String?, type: CNContainerType) {
        self.identifier = identifier
        self.name = name
        self.type = type
    }

    public func copy(with zone: NSZone? = nil) -> Any { self }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? CNContainer else { return false }
        return o.identifier == identifier && o.name == name && o.type == type
    }
    public override var hash: Int { identifier.hashValue }
    public override var description: String {
        "<CNContainer: identifier=\(identifier), name=\(name ?? "(nil)"), type=\(type.rawValue)>"
    }

    public class func predicateForContainers(withIdentifiers identifiers: [String]) -> NSPredicate {
        CNStorePredicate(.containerIdentifiers(identifiers))
    }

    public class func predicateForContainerOfContact(withIdentifier contactIdentifier: String) -> NSPredicate {
        CNStorePredicate(.containerOfContact(contactIdentifier))
    }

    public class func predicateForContainerOfGroup(withIdentifier groupIdentifier: String) -> NSPredicate {
        CNStorePredicate(.containerOfGroup(groupIdentifier))
    }
}

// MARK: - Fetch requests and results

public class CNFetchRequest: NSObject, @unchecked Sendable {
    override init() {}
}

public final class CNContactFetchRequest: CNFetchRequest, @unchecked Sendable {
    public var predicate: NSPredicate?
    public var keysToFetch: [CNKeyDescriptor]
    public var mutableObjects = false
    public var unifyResults = true
    public var sortOrder: CNContactSortOrder = .none

    public init(keysToFetch: [CNKeyDescriptor]) {
        self.keysToFetch = keysToFetch
    }
}

/// A fetch result with the history token current at the time of the fetch.
public final class CNFetchResult<ValueType: AnyObject>: NSObject, @unchecked Sendable {
    public let value: ValueType
    public let currentHistoryToken: Data

    init(value: ValueType, currentHistoryToken: Data) {
        self.value = value
        self.currentHistoryToken = currentHistoryToken
    }
}

/// An enumerator over a fixed array (the `value` of a CNFetchResult).
final class ArrayEnumerator: NSEnumerator {
    private var items: [Any]
    private var index = 0

    init(_ items: [Any]) {
        self.items = items
        super.init()
    }

    override func nextObject() -> Any? {
        guard index < items.count else { return nil }
        defer { index += 1 }
        return items[index]
    }
}
