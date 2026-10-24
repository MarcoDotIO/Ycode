// Value records: the state a home store owns (open-design.md §2 "Store").
// They are the storage form of the in-memory store and the wire form a future
// `ycode-homed` (plan.md R4) sends to clients; the model objects of
// object-model.md are client-side mirrors keyed by `id` (= uniqueIdentifier).

import Foundation

public struct YcodeCharacteristicRecord: Codable, Hashable, Sendable {
    public var id: UUID
    /// HAP instance ID within the accessory.
    public var iid: Int
    /// Full uppercase type UUID.
    public var type: String
    /// `HMCharacteristicProperty…` strings.
    public var properties: [String]
    public var metadata: YcodeCharacteristicMetadata?
    /// Last known value (nil until read or notified).
    public var value: YcodeHomeValue?

    public init(id: UUID = UUID(), iid: Int, type: String, properties: [String],
                metadata: YcodeCharacteristicMetadata?, value: YcodeHomeValue?) {
        self.id = id
        self.iid = iid
        self.type = type
        self.properties = properties
        self.metadata = metadata
        self.value = value
    }
}

public struct YcodeServiceRecord: Codable, Hashable, Sendable {
    public var id: UUID
    public var iid: Int
    public var type: String
    public var name: String
    public var associatedType: String?
    public var isPrimary: Bool
    public var isUserInteractive: Bool
    public var linkedServiceIDs: [UUID]
    public var characteristics: [YcodeCharacteristicRecord]
}

public struct YcodeAccessoryRecord: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var categoryType: String
    public var manufacturer: String?
    public var model: String?
    public var firmwareVersion: String?
    public var roomID: UUID
    public var services: [YcodeServiceRecord]
    public var isReachable: Bool
    public var isBlocked: Bool
    public var isBridged: Bool
    /// On a bridge: the accessories it hosts.
    public var bridgedAccessoryIDs: [UUID]
    public var supportsIdentify: Bool
    /// The endpoint (accessory server) this accessory is reached through.
    public var endpointID: String
    /// HAP accessory instance ID on that endpoint (1 = primary).
    public var aid: Int
    public var matterNodeID: UInt64?
}

public struct YcodeRoomRecord: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
}

public struct YcodeZoneRecord: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var roomIDs: [UUID]
}

public struct YcodeServiceGroupRecord: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var serviceIDs: [UUID]
}

public struct YcodeActionRecord: Codable, Hashable, Sendable {
    public var id: UUID
    public var characteristicID: UUID
    public var targetValue: YcodeHomeValue
}

public struct YcodeActionSetRecord: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// `HMActionSetType…` string.
    public var type: String
    /// In insertion order (execution order).
    public var actions: [YcodeActionRecord]
    public var lastExecutionDate: Date?
    public var isExecuting: Bool
}

public struct YcodeRegionRecord: Codable, Hashable, Sendable {
    public var identifier: String
    public var latitude: Double
    public var longitude: Double
    public var radius: Double
    public var notifyOnEntry: Bool
    public var notifyOnExit: Bool
}

public struct YcodeEventRecord: Codable, Hashable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        case characteristic(characteristicID: UUID, triggerValue: YcodeHomeValue?)
        case thresholdRange(characteristicID: UUID, minimum: Double?, maximum: Double?)
        case location(YcodeRegionRecord?)
        case presence(type: Int, userType: Int)
        case calendar(DateComponents)
        case significantTime(event: String, offset: DateComponents?)
        case duration(TimeInterval)
    }

    public var id: UUID
    public var kind: Kind
}

public struct YcodeTriggerRecord: Codable, Hashable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        case timer(fireDate: Date, recurrence: DateComponents?)
        case event(events: [YcodeEventRecord], endEvents: [YcodeEventRecord],
                   recurrences: [DateComponents]?, executeOnce: Bool)
    }

    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var actionSetIDs: [UUID]
    public var kind: Kind
    /// `HMEventTriggerActivationState` raw value (event triggers).
    public var activationState: Int
}

public struct YcodeUserRecord: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var isAdministrator: Bool
}

public struct YcodeHomeRecord: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var isPrimary: Bool
    /// `roomForEntireHome` (not part of `rooms`).
    public var defaultRoom: YcodeRoomRecord
    public var rooms: [YcodeRoomRecord]
    public var zones: [YcodeZoneRecord]
    public var serviceGroups: [YcodeServiceGroupRecord]
    public var accessories: [YcodeAccessoryRecord]
    public var actionSets: [YcodeActionSetRecord]
    public var triggers: [YcodeTriggerRecord]
    public var users: [YcodeUserRecord]
    public var currentUserID: UUID
    /// `HMHomeHubState` raw value.
    public var hubState: Int

    func accessoryIndex(_ id: UUID) -> Int? { accessories.firstIndex { $0.id == id } }

    /// (accessory index, service index, characteristic index) of a characteristic.
    func characteristicPath(_ id: UUID) -> (Int, Int, Int)? {
        for (a, acc) in accessories.enumerated() {
            for (s, svc) in acc.services.enumerated() {
                if let c = svc.characteristics.firstIndex(where: { $0.id == id }) { return (a, s, c) }
            }
        }
        return nil
    }

    func servicePath(_ id: UUID) -> (Int, Int)? {
        for (a, acc) in accessories.enumerated() {
            if let s = acc.services.firstIndex(where: { $0.id == id }) { return (a, s) }
        }
        return nil
    }
}

/// An accessory that is published but not paired (what `HMAccessoryBrowser` lists).
public struct YcodeDiscoveredAccessoryRecord: Codable, Hashable, Sendable {
    public var id: UUID
    public var endpointID: String
    public var name: String
    public var categoryType: String
}
