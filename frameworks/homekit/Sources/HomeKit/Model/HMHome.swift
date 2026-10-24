// HMHome (object-model.md §3) and its delegate.

import Foundation

/// object-model.md §3: change reports per object kind; every method is optional.
public protocol HMHomeDelegate: AnyObject {
    func homeDidUpdateName(_ home: HMHome)
    func homeDidUpdateAccessControl(forCurrentUser home: HMHome)
    func home(_ home: HMHome, didAdd accessory: HMAccessory)
    func home(_ home: HMHome, didRemove accessory: HMAccessory)
    func home(_ home: HMHome, didUpdate room: HMRoom, for accessory: HMAccessory)
    func home(_ home: HMHome, didUnblockAccessory accessory: HMAccessory)
    func home(_ home: HMHome, didEncounterError error: Error, for accessory: HMAccessory)
    func home(_ home: HMHome, didAdd user: HMUser)
    func home(_ home: HMHome, didRemove user: HMUser)
    func home(_ home: HMHome, didAdd room: HMRoom)
    func home(_ home: HMHome, didRemove room: HMRoom)
    func home(_ home: HMHome, didUpdateNameFor room: HMRoom)
    func home(_ home: HMHome, didAdd zone: HMZone)
    func home(_ home: HMHome, didRemove zone: HMZone)
    func home(_ home: HMHome, didUpdateNameFor zone: HMZone)
    func home(_ home: HMHome, didAdd room: HMRoom, to zone: HMZone)
    func home(_ home: HMHome, didRemove room: HMRoom, from zone: HMZone)
    func home(_ home: HMHome, didAdd group: HMServiceGroup)
    func home(_ home: HMHome, didRemove group: HMServiceGroup)
    func home(_ home: HMHome, didUpdateNameFor group: HMServiceGroup)
    func home(_ home: HMHome, didAdd service: HMService, to group: HMServiceGroup)
    func home(_ home: HMHome, didRemove service: HMService, from group: HMServiceGroup)
    func home(_ home: HMHome, didAdd actionSet: HMActionSet)
    func home(_ home: HMHome, didRemove actionSet: HMActionSet)
    func home(_ home: HMHome, didUpdateNameFor actionSet: HMActionSet)
    func home(_ home: HMHome, didUpdateActionsFor actionSet: HMActionSet)
    func home(_ home: HMHome, didAdd trigger: HMTrigger)
    func home(_ home: HMHome, didRemove trigger: HMTrigger)
    func home(_ home: HMHome, didUpdateNameFor trigger: HMTrigger)
    func home(_ home: HMHome, didUpdate trigger: HMTrigger)
    func home(_ home: HMHome, didUpdate homeHubState: HMHomeHubState)
    func homeDidUpdateSupportedFeatures(_ home: HMHome)
}

public extension HMHomeDelegate {
    func homeDidUpdateName(_ home: HMHome) {}
    func homeDidUpdateAccessControl(forCurrentUser home: HMHome) {}
    func home(_ home: HMHome, didAdd accessory: HMAccessory) {}
    func home(_ home: HMHome, didRemove accessory: HMAccessory) {}
    func home(_ home: HMHome, didUpdate room: HMRoom, for accessory: HMAccessory) {}
    func home(_ home: HMHome, didUnblockAccessory accessory: HMAccessory) {}
    func home(_ home: HMHome, didEncounterError error: Error, for accessory: HMAccessory) {}
    func home(_ home: HMHome, didAdd user: HMUser) {}
    func home(_ home: HMHome, didRemove user: HMUser) {}
    func home(_ home: HMHome, didAdd room: HMRoom) {}
    func home(_ home: HMHome, didRemove room: HMRoom) {}
    func home(_ home: HMHome, didUpdateNameFor room: HMRoom) {}
    func home(_ home: HMHome, didAdd zone: HMZone) {}
    func home(_ home: HMHome, didRemove zone: HMZone) {}
    func home(_ home: HMHome, didUpdateNameFor zone: HMZone) {}
    func home(_ home: HMHome, didAdd room: HMRoom, to zone: HMZone) {}
    func home(_ home: HMHome, didRemove room: HMRoom, from zone: HMZone) {}
    func home(_ home: HMHome, didAdd group: HMServiceGroup) {}
    func home(_ home: HMHome, didRemove group: HMServiceGroup) {}
    func home(_ home: HMHome, didUpdateNameFor group: HMServiceGroup) {}
    func home(_ home: HMHome, didAdd service: HMService, to group: HMServiceGroup) {}
    func home(_ home: HMHome, didRemove service: HMService, from group: HMServiceGroup) {}
    func home(_ home: HMHome, didAdd actionSet: HMActionSet) {}
    func home(_ home: HMHome, didRemove actionSet: HMActionSet) {}
    func home(_ home: HMHome, didUpdateNameFor actionSet: HMActionSet) {}
    func home(_ home: HMHome, didUpdateActionsFor actionSet: HMActionSet) {}
    func home(_ home: HMHome, didAdd trigger: HMTrigger) {}
    func home(_ home: HMHome, didRemove trigger: HMTrigger) {}
    func home(_ home: HMHome, didUpdateNameFor trigger: HMTrigger) {}
    func home(_ home: HMHome, didUpdate trigger: HMTrigger) {}
    func home(_ home: HMHome, didUpdate homeHubState: HMHomeHubState) {}
    func homeDidUpdateSupportedFeatures(_ home: HMHome) {}
}

open class HMHome: NSObject, @unchecked Sendable {
    public let uniqueIdentifier: UUID
    public private(set) var name = ""
    public internal(set) var isPrimary = false
    public private(set) var homeHubState: HMHomeHubState = .notAvailable
    public weak var delegate: HMHomeDelegate?

    public private(set) var accessories: [HMAccessory] = []
    /// Rooms, without the default room (object-model.md §3).
    public private(set) var rooms: [HMRoom] = []
    /// The default room holding unassigned accessories.
    public private(set) var roomForEntireHome: HMRoom!
    public private(set) var zones: [HMZone] = []
    public private(set) var serviceGroups: [HMServiceGroup] = []
    public private(set) var actionSets: [HMActionSet] = []
    public private(set) var triggers: [HMTrigger] = []
    public private(set) var currentUser: HMUser!
    /// Deprecated since iOS 9 (object-model.md §3); the home's users.
    @available(iOS, deprecated: 9.0)
    public var users: [HMUser] { allUsers }
    private(set) var allUsers: [HMUser] = []

    let connection: YcodeConnection
    /// Write actions and triggers the app created, by identifier, so the
    /// mirror keeps the app's own instances once they are added.
    var pendingActions: [UUID: HMAction] = [:]
    var pendingTriggers: [UUID: HMTrigger] = [:]
    private var administrators: Set<UUID> = []

    init(id: UUID, connection: YcodeConnection) {
        uniqueIdentifier = id
        self.connection = connection
    }

    open override func isEqual(_ object: Any?) -> Bool { (object as? HMHome)?.uniqueIdentifier == uniqueIdentifier }
    open override var hash: Int { uniqueIdentifier.hashValue }

    // MARK: Lookups

    func room(_ id: UUID) -> HMRoom? {
        roomForEntireHome?.uniqueIdentifier == id ? roomForEntireHome : rooms.first { $0.uniqueIdentifier == id }
    }

    func accessory(_ id: UUID) -> HMAccessory? { accessories.first { $0.uniqueIdentifier == id } }

    func service(_ id: UUID) -> HMService? {
        for a in accessories { if let s = a.services.first(where: { $0.uniqueIdentifier == id }) { return s } }
        return nil
    }

    func characteristic(_ id: UUID) -> HMCharacteristic? {
        for a in accessories {
            for s in a.services { if let c = s.characteristics.first(where: { $0.uniqueIdentifier == id }) { return c } }
        }
        return nil
    }

    /// All services of the given types across the home (object-model.md §3).
    public func servicesWithTypes(_ serviceTypes: [String]) -> [HMService]? {
        let wanted = Set(serviceTypes.map { YcodeHomeCatalog.normalizedTypeUUID($0) ?? $0 })
        let found = accessories.flatMap(\.services).filter { wanted.contains($0.serviceType) }
        return found
    }

    /// The built-in action set of a type (`HMActionSetType…`), if any.
    public func builtinActionSet(ofType actionSetType: String) -> HMActionSet? {
        actionSets.first { $0.actionSetType == actionSetType && actionSetType != HMActionSetTypeUserDefined }
    }

    /// Access control for a user of this home (object-model.md §3).
    public func homeAccessControl(for user: HMUser) -> HMHomeAccessControl {
        HMHomeAccessControl(isAdministrator: administrators.contains(user.uniqueIdentifier))
    }

    // MARK: Mutations (object-model.md §3)

    public func updateName(_ name: String, completionHandler completion: @escaping (Error?) -> Void) {
        connection.simple(.renameHome(uniqueIdentifier, name: name), completion)
    }

    public func addRoom(withName name: String, completionHandler completion: @escaping (HMRoom?, Error?) -> Void) {
        created(.addRoom(home: uniqueIdentifier, name: name), { self.room($0) }, completion)
    }

    public func removeRoom(_ room: HMRoom, completionHandler completion: @escaping (Error?) -> Void) {
        connection.simple(.removeRoom(home: uniqueIdentifier, room: room.uniqueIdentifier), completion)
    }

    public func addZone(withName name: String, completionHandler completion: @escaping (HMZone?, Error?) -> Void) {
        created(.addZone(home: uniqueIdentifier, name: name), { id in self.zones.first { $0.uniqueIdentifier == id } }, completion)
    }

    public func removeZone(_ zone: HMZone, completionHandler completion: @escaping (Error?) -> Void) {
        connection.simple(.removeZone(home: uniqueIdentifier, zone: zone.uniqueIdentifier), completion)
    }

    public func addServiceGroup(withName name: String, completionHandler completion: @escaping (HMServiceGroup?, Error?) -> Void) {
        created(.addServiceGroup(home: uniqueIdentifier, name: name),
                { id in self.serviceGroups.first { $0.uniqueIdentifier == id } }, completion)
    }

    public func removeServiceGroup(_ group: HMServiceGroup, completionHandler completion: @escaping (Error?) -> Void) {
        connection.simple(.removeServiceGroup(home: uniqueIdentifier, group: group.uniqueIdentifier), completion)
    }

    public func addActionSet(withName name: String, completionHandler completion: @escaping (HMActionSet?, Error?) -> Void) {
        created(.addActionSet(home: uniqueIdentifier, name: name),
                { id in self.actionSets.first { $0.uniqueIdentifier == id } }, completion)
    }

    public func removeActionSet(_ actionSet: HMActionSet, completionHandler completion: @escaping (Error?) -> Void) {
        connection.simple(.removeActionSet(home: uniqueIdentifier, actionSet: actionSet.uniqueIdentifier), completion)
    }

    /// Writes every action of the set; 25 if empty, 64 on partial success,
    /// 63 if every write fails, 65 while it already runs (object-model.md §8).
    public func executeActionSet(_ actionSet: HMActionSet, completionHandler completion: @escaping (Error?) -> Void) {
        connection.simple(.executeActionSet(home: uniqueIdentifier, actionSet: actionSet.uniqueIdentifier), completion)
    }

    public func addTrigger(_ trigger: HMTrigger, completionHandler completion: @escaping (Error?) -> Void) {
        guard let record = trigger.record() else { fail(completion, .invalidClass); return }
        pendingTriggers[trigger.uniqueIdentifier] = trigger
        connection.simple(.addTrigger(home: uniqueIdentifier, trigger: record)) { error in
            if error != nil { self.pendingTriggers[trigger.uniqueIdentifier] = nil }
            completion(error)
        }
    }

    public func removeTrigger(_ trigger: HMTrigger, completionHandler completion: @escaping (Error?) -> Void) {
        connection.simple(.removeTrigger(home: uniqueIdentifier, trigger: trigger.uniqueIdentifier), completion)
    }

    /// Adds an accessory found by `HMAccessoryBrowser` to the default room.
    /// (Ycode: pairing happens without a setup sheet in this round.)
    public func addAccessory(_ accessory: HMAccessory, completionHandler completion: @escaping (Error?) -> Void) {
        guard accessory.discoveredID != nil else { fail(completion, .objectAlreadyAssociatedToHome); return }
        connection.simple(.addAccessory(home: uniqueIdentifier, discovered: accessory.uniqueIdentifier), completion)
    }

    /// Removes an accessory; a bridged accessory cannot be removed on its own (34).
    public func removeAccessory(_ accessory: HMAccessory, completionHandler completion: @escaping (Error?) -> Void) {
        connection.simple(.removeAccessory(home: uniqueIdentifier, accessory: accessory.uniqueIdentifier), completion)
    }

    public func assignAccessory(_ accessory: HMAccessory, to room: HMRoom, completionHandler completion: @escaping (Error?) -> Void) {
        connection.simple(.assignAccessory(home: uniqueIdentifier, accessory: accessory.uniqueIdentifier,
                                           room: room.uniqueIdentifier), completion)
    }

    public func unblockAccessory(_ accessory: HMAccessory, completionHandler completion: @escaping (Error?) -> Void) {
        connection.simple(.unblockAccessory(home: uniqueIdentifier, accessory: accessory.uniqueIdentifier), completion)
    }

    /// Ycode has no user-management sheet yet: completes with 48.
    public func manageUsers(completionHandler completion: @escaping (Error?) -> Void) {
        fail(completion, .operationNotSupported)
    }

    /// Deprecated in favor of `HMAccessorySetupManager` (object-model.md §3);
    /// Ycode has no setup sheet in this round: completes with 48.
    @available(iOS, deprecated: 15.4)
    public func addAndSetupAccessories(completionHandler completion: @escaping (Error?) -> Void) {
        fail(completion, .operationNotSupported)
    }

    private func created<T>(_ r: YcodeHomeRequest, _ lookup: @escaping (UUID) -> T?,
                            _ completion: @escaping (T?, Error?) -> Void) {
        connection.request(r) { result in
            switch result {
            case .success(.object(let id)): completion(lookup(id), nil)
            case .success: completion(nil, HMError(.unexpectedError))
            case .failure(let e): completion(nil, e)
            }
        }
    }

    // MARK: async variants

    public func updateName(_ name: String) async throws { try await asyncCall { updateName(name, completionHandler: $0) } }
    public func addRoom(named name: String) async throws -> HMRoom { try await asyncCall { addRoom(withName: name, completionHandler: $0) } }
    public func removeRoom(_ room: HMRoom) async throws { try await asyncCall { removeRoom(room, completionHandler: $0) } }
    public func addZone(named name: String) async throws -> HMZone { try await asyncCall { addZone(withName: name, completionHandler: $0) } }
    public func removeZone(_ zone: HMZone) async throws { try await asyncCall { removeZone(zone, completionHandler: $0) } }
    public func addServiceGroup(named name: String) async throws -> HMServiceGroup {
        try await asyncCall { addServiceGroup(withName: name, completionHandler: $0) }
    }
    public func removeServiceGroup(_ group: HMServiceGroup) async throws {
        try await asyncCall { removeServiceGroup(group, completionHandler: $0) }
    }
    public func addActionSet(named name: String) async throws -> HMActionSet {
        try await asyncCall { addActionSet(withName: name, completionHandler: $0) }
    }
    public func removeActionSet(_ actionSet: HMActionSet) async throws {
        try await asyncCall { removeActionSet(actionSet, completionHandler: $0) }
    }
    public func executeActionSet(_ actionSet: HMActionSet) async throws {
        try await asyncCall { executeActionSet(actionSet, completionHandler: $0) }
    }
    public func addTrigger(_ trigger: HMTrigger) async throws { try await asyncCall { addTrigger(trigger, completionHandler: $0) } }
    public func removeTrigger(_ trigger: HMTrigger) async throws { try await asyncCall { removeTrigger(trigger, completionHandler: $0) } }
    public func addAccessory(_ accessory: HMAccessory) async throws { try await asyncCall { addAccessory(accessory, completionHandler: $0) } }
    public func removeAccessory(_ accessory: HMAccessory) async throws {
        try await asyncCall { removeAccessory(accessory, completionHandler: $0) }
    }
    public func assignAccessory(_ accessory: HMAccessory, to room: HMRoom) async throws {
        try await asyncCall { assignAccessory(accessory, to: room, completionHandler: $0) }
    }
    public func unblockAccessory(_ accessory: HMAccessory) async throws {
        try await asyncCall { unblockAccessory(accessory, completionHandler: $0) }
    }

    // MARK: Mirror

    /// Reconciles this mirror with a record, keeping object identities.
    func apply(_ r: YcodeHomeRecord) {
        name = r.name
        isPrimary = r.isPrimary
        homeHubState = HMHomeHubState(rawValue: r.hubState) ?? .notAvailable

        func reuse<T: AnyObject>(_ old: [T], _ id: (T) -> UUID) -> [UUID: T] {
            Dictionary(old.map { (id($0), $0) }, uniquingKeysWith: { a, _ in a })
        }

        if roomForEntireHome == nil { roomForEntireHome = HMRoom(id: r.defaultRoom.id, home: self) }
        roomForEntireHome.name = r.defaultRoom.name
        let oldRooms = reuse(rooms, \.uniqueIdentifier)
        rooms = r.rooms.map { rr in
            let room = oldRooms[rr.id] ?? HMRoom(id: rr.id, home: self)
            room.name = rr.name
            return room
        }

        let oldAccessories = reuse(accessories, \.uniqueIdentifier)
        accessories = r.accessories.map { ar in
            let a = oldAccessories[ar.id] ?? HMAccessory(id: ar.id)
            a.home = self
            a.apply(ar)
            return a
        }
        for a in accessories {
            a.bridgedAccessories = a.record.bridgedAccessoryIDs.isEmpty ? nil
                : a.record.bridgedAccessoryIDs.compactMap { id in accessories.first { $0.uniqueIdentifier == id } }
        }

        let oldZones = reuse(zones, \.uniqueIdentifier)
        zones = r.zones.map { zr in
            let z = oldZones[zr.id] ?? HMZone(id: zr.id, home: self)
            z.name = zr.name
            z.rooms = zr.roomIDs.compactMap { room($0) }
            return z
        }

        let oldGroups = reuse(serviceGroups, \.uniqueIdentifier)
        serviceGroups = r.serviceGroups.map { gr in
            let g = oldGroups[gr.id] ?? HMServiceGroup(id: gr.id, home: self)
            g.name = gr.name
            g.services = gr.serviceIDs.compactMap { service($0) }
            return g
        }

        var oldActions: [UUID: HMAction] = pendingActions
        for s in actionSets { for a in s.actions { oldActions[a.uniqueIdentifier] = a } }
        let oldSets = reuse(actionSets, \.uniqueIdentifier)
        actionSets = r.actionSets.map { sr in
            let s = oldSets[sr.id] ?? HMActionSet(id: sr.id, home: self)
            s.apply(sr)
            s.actionList = sr.actions.map { ar in
                let a = oldActions[ar.id] ?? HMAction.make(ar, characteristic: characteristic(ar.characteristicID))
                a.apply(ar, characteristic: characteristic(ar.characteristicID))
                a.actionSet = s
                pendingActions[ar.id] = nil
                return a
            }
            return s
        }

        var oldTriggers: [UUID: HMTrigger] = pendingTriggers
        for t in triggers { oldTriggers[t.uniqueIdentifier] = t }
        triggers = r.triggers.map { tr in
            let t = oldTriggers[tr.id] ?? HMTrigger.make(tr)
            t.home = self
            t.apply(tr, home: self)
            pendingTriggers[tr.id] = nil
            return t
        }

        let oldUsers = reuse(allUsers, \.uniqueIdentifier)
        allUsers = r.users.map { ur in
            let u = oldUsers[ur.id] ?? HMUser(id: ur.id)
            u.name = ur.name
            return u
        }
        administrators = Set(r.users.filter(\.isAdministrator).map(\.id))
        currentUser = allUsers.first { $0.uniqueIdentifier == r.currentUserID }
    }

    /// Applies a change and, for changes made elsewhere, calls the delegates.
    func update(_ r: YcodeHomeRecord, change: YcodeHomeChange, notify: Bool) {
        // Objects that disappear are captured before the mirror drops them.
        var removedAccessories: [HMAccessory] = []
        var removedRoom: HMRoom?, removedZone: HMZone?, removedGroup: HMServiceGroup?
        var removedSet: HMActionSet?, removedTrigger: HMTrigger?
        var memberRoom: HMRoom?, memberService: HMService?
        switch change {
        case .accessoryRemoved(let id, let bridged):
            removedAccessories = ([id] + bridged).compactMap { accessory($0) }
        case .roomRemoved(let id): removedRoom = room(id)
        case .zoneRemoved(let id): removedZone = zones.first { $0.uniqueIdentifier == id }
        case .serviceGroupRemoved(let id): removedGroup = serviceGroups.first { $0.uniqueIdentifier == id }
        case .actionSetRemoved(let id): removedSet = actionSets.first { $0.uniqueIdentifier == id }
        case .triggerRemoved(let id): removedTrigger = triggers.first { $0.uniqueIdentifier == id }
        case .roomRemovedFromZone(let roomID, _): memberRoom = room(roomID)
        case .serviceRemovedFromGroup(let serviceID, _): memberService = service(serviceID)
        default: break
        }
        let oldHub = homeHubState
        apply(r)
        for a in removedAccessories { a.home = nil }
        guard notify else { return }

        let d = delegate
        switch change {
        case .homeName: d?.homeDidUpdateName(self)
        case .accessoryAdded(let id): if let a = accessory(id) { d?.home(self, didAdd: a) }
        case .accessoryRemoved: for a in removedAccessories { d?.home(self, didRemove: a) }
        case .accessoryRoom(let a, let rm):
            if let a = accessory(a), let rm = room(rm) { d?.home(self, didUpdate: rm, for: a) }
        case .accessoryName(let id):
            if let a = accessory(id) { a.delegate?.accessoryDidUpdateName(a) }
        case .accessoryUnblocked(let id): if let a = accessory(id) { d?.home(self, didUnblockAccessory: a) }
        case .accessoryReachability(let id):
            if let a = accessory(id) { a.delegate?.accessoryDidUpdateReachability(a) }
        case .serviceName(let a, let s):
            if let a = accessory(a), let s = service(s) { a.delegate?.accessory(a, didUpdateNameFor: s) }
        case .associatedServiceType(let a, let s):
            if let a = accessory(a), let s = service(s) { a.delegate?.accessory(a, didUpdateAssociatedServiceTypeFor: s) }
        case .roomAdded(let id): if let x = room(id) { d?.home(self, didAdd: x) }
        case .roomRemoved: if let x = removedRoom { d?.home(self, didRemove: x) }
        case .roomName(let id): if let x = room(id) { d?.home(self, didUpdateNameFor: x) }
        case .zoneAdded(let id): if let x = zones.first(where: { $0.uniqueIdentifier == id }) { d?.home(self, didAdd: x) }
        case .zoneRemoved: if let x = removedZone { d?.home(self, didRemove: x) }
        case .zoneName(let id):
            if let x = zones.first(where: { $0.uniqueIdentifier == id }) { d?.home(self, didUpdateNameFor: x) }
        case .roomAddedToZone(let rm, let z):
            if let rm = room(rm), let z = zones.first(where: { $0.uniqueIdentifier == z }) { d?.home(self, didAdd: rm, to: z) }
        case .roomRemovedFromZone(_, let z):
            if let rm = memberRoom, let z = zones.first(where: { $0.uniqueIdentifier == z }) { d?.home(self, didRemove: rm, from: z) }
        case .serviceGroupAdded(let id):
            if let x = serviceGroups.first(where: { $0.uniqueIdentifier == id }) { d?.home(self, didAdd: x) }
        case .serviceGroupRemoved: if let x = removedGroup { d?.home(self, didRemove: x) }
        case .serviceGroupName(let id):
            if let x = serviceGroups.first(where: { $0.uniqueIdentifier == id }) { d?.home(self, didUpdateNameFor: x) }
        case .serviceAddedToGroup(let s, let g):
            if let s = service(s), let g = serviceGroups.first(where: { $0.uniqueIdentifier == g }) { d?.home(self, didAdd: s, to: g) }
        case .serviceRemovedFromGroup(_, let g):
            if let s = memberService, let g = serviceGroups.first(where: { $0.uniqueIdentifier == g }) {
                d?.home(self, didRemove: s, from: g)
            }
        case .actionSetAdded(let id):
            if let x = actionSets.first(where: { $0.uniqueIdentifier == id }) { d?.home(self, didAdd: x) }
        case .actionSetRemoved: if let x = removedSet { d?.home(self, didRemove: x) }
        case .actionSetName(let id):
            if let x = actionSets.first(where: { $0.uniqueIdentifier == id }) { d?.home(self, didUpdateNameFor: x) }
        case .actionSetActions(let id):
            if let x = actionSets.first(where: { $0.uniqueIdentifier == id }) { d?.home(self, didUpdateActionsFor: x) }
        case .triggerAdded(let id): if let x = triggers.first(where: { $0.uniqueIdentifier == id }) { d?.home(self, didAdd: x) }
        case .triggerRemoved: if let x = removedTrigger { d?.home(self, didRemove: x) }
        case .triggerName(let id):
            if let x = triggers.first(where: { $0.uniqueIdentifier == id }) { d?.home(self, didUpdateNameFor: x) }
        case .triggerUpdated(let id): if let x = triggers.first(where: { $0.uniqueIdentifier == id }) { d?.home(self, didUpdate: x) }
        case .hubState: if oldHub != homeHubState { d?.home(self, didUpdate: homeHubState) }
        case .state: break
        }
    }

    /// A value notification (object-model.md §7: delivered through the
    /// accessory's delegate).
    func receiveValue(characteristic id: UUID, value: YcodeHomeValue?) {
        guard let c = characteristic(id), let s = c.service, let a = s.accessory else { return }
        c.cachedValue = value
        a.delegate?.accessory(a, service: s, didUpdateValueFor: c)
    }
}

// MARK: - Rooms, zones, service groups, users (object-model.md §4)

open class HMRoom: NSObject, @unchecked Sendable {
    public let uniqueIdentifier: UUID
    public internal(set) var name = ""
    weak var home: HMHome?

    init(id: UUID, home: HMHome) {
        uniqueIdentifier = id
        self.home = home
    }

    /// The accessories assigned to this room.
    public var accessories: [HMAccessory] {
        home?.accessories.filter { $0.record.roomID == uniqueIdentifier } ?? []
    }

    open override func isEqual(_ object: Any?) -> Bool { (object as? HMRoom)?.uniqueIdentifier == uniqueIdentifier }
    open override var hash: Int { uniqueIdentifier.hashValue }

    /// The default room cannot be renamed (29).
    public func updateName(_ name: String, completionHandler completion: @escaping (Error?) -> Void) {
        guard let home else { fail(completion, .objectNotAssociatedToAnyHome); return }
        home.connection.simple(.renameRoom(home: home.uniqueIdentifier, room: uniqueIdentifier, name: name), completion)
    }

    public func updateName(_ name: String) async throws { try await asyncCall { updateName(name, completionHandler: $0) } }
}

open class HMZone: NSObject, @unchecked Sendable {
    public let uniqueIdentifier: UUID
    public internal(set) var name = ""
    public internal(set) var rooms: [HMRoom] = []
    weak var home: HMHome?

    init(id: UUID, home: HMHome) {
        uniqueIdentifier = id
        self.home = home
    }

    open override func isEqual(_ object: Any?) -> Bool { (object as? HMZone)?.uniqueIdentifier == uniqueIdentifier }
    open override var hash: Int { uniqueIdentifier.hashValue }

    public func updateName(_ name: String, completionHandler completion: @escaping (Error?) -> Void) {
        guard let home else { fail(completion, .objectNotAssociatedToAnyHome); return }
        home.connection.simple(.renameZone(home: home.uniqueIdentifier, zone: uniqueIdentifier, name: name), completion)
    }

    /// The default room cannot be placed in a zone (24).
    public func addRoom(_ room: HMRoom, completionHandler completion: @escaping (Error?) -> Void) {
        guard let home else { fail(completion, .objectNotAssociatedToAnyHome); return }
        home.connection.simple(.addRoomToZone(home: home.uniqueIdentifier, zone: uniqueIdentifier,
                                              room: room.uniqueIdentifier), completion)
    }

    public func removeRoom(_ room: HMRoom, completionHandler completion: @escaping (Error?) -> Void) {
        guard let home else { fail(completion, .objectNotAssociatedToAnyHome); return }
        home.connection.simple(.removeRoomFromZone(home: home.uniqueIdentifier, zone: uniqueIdentifier,
                                                   room: room.uniqueIdentifier), completion)
    }

    public func updateName(_ name: String) async throws { try await asyncCall { updateName(name, completionHandler: $0) } }
    public func addRoom(_ room: HMRoom) async throws { try await asyncCall { addRoom(room, completionHandler: $0) } }
    public func removeRoom(_ room: HMRoom) async throws { try await asyncCall { removeRoom(room, completionHandler: $0) } }
}

open class HMServiceGroup: NSObject, @unchecked Sendable {
    public let uniqueIdentifier: UUID
    public internal(set) var name = ""
    public internal(set) var services: [HMService] = []
    weak var home: HMHome?

    init(id: UUID, home: HMHome) {
        uniqueIdentifier = id
        self.home = home
    }

    open override func isEqual(_ object: Any?) -> Bool { (object as? HMServiceGroup)?.uniqueIdentifier == uniqueIdentifier }
    open override var hash: Int { uniqueIdentifier.hashValue }

    public func updateName(_ name: String, completionHandler completion: @escaping (Error?) -> Void) {
        guard let home else { fail(completion, .objectNotAssociatedToAnyHome); return }
        home.connection.simple(.renameServiceGroup(home: home.uniqueIdentifier, group: uniqueIdentifier, name: name), completion)
    }

    public func addService(_ service: HMService, completionHandler completion: @escaping (Error?) -> Void) {
        guard let home else { fail(completion, .objectNotAssociatedToAnyHome); return }
        home.connection.simple(.addServiceToGroup(home: home.uniqueIdentifier, group: uniqueIdentifier,
                                                  service: service.uniqueIdentifier), completion)
    }

    public func removeService(_ service: HMService, completionHandler completion: @escaping (Error?) -> Void) {
        guard let home else { fail(completion, .objectNotAssociatedToAnyHome); return }
        home.connection.simple(.removeServiceFromGroup(home: home.uniqueIdentifier, group: uniqueIdentifier,
                                                       service: service.uniqueIdentifier), completion)
    }

    public func updateName(_ name: String) async throws { try await asyncCall { updateName(name, completionHandler: $0) } }
    public func addService(_ service: HMService) async throws { try await asyncCall { addService(service, completionHandler: $0) } }
    public func removeService(_ service: HMService) async throws { try await asyncCall { removeService(service, completionHandler: $0) } }
}

open class HMUser: NSObject, @unchecked Sendable {
    public let uniqueIdentifier: UUID
    public internal(set) var name = ""

    init(id: UUID) { uniqueIdentifier = id }

    open override func isEqual(_ object: Any?) -> Bool { (object as? HMUser)?.uniqueIdentifier == uniqueIdentifier }
    open override var hash: Int { uniqueIdentifier.hashValue }
}

/// Abstract base of access-control objects (iOS 11.2).
open class HMAccessControl: NSObject, @unchecked Sendable {}

open class HMHomeAccessControl: HMAccessControl, @unchecked Sendable {
    public let isAdministrator: Bool
    init(isAdministrator: Bool) { self.isAdministrator = isAdministrator }
}
