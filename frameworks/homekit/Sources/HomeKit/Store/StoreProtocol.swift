// The home-store boundary (open-design.md §2): the client library talks to a
// store through `YcodeHomeStore` only, with Codable requests, replies and
// events, so plan.md R4's `ycode-homed` daemon can take the in-memory store's
// place behind a socket without changing the model layer.
//
// Contract for implementations:
//  * `connect` answers synchronously with the session's authorization status
//    (object-model.md §2: the status is readable right after `init`).
//  * Events for one session are delivered one at a time, in order.
//  * The events a request causes are delivered (to every session, including
//    the originator, tagged with `origin`) before that request's completion.
//  * The originator's model applies its own changes without delegate
//    callbacks; other sessions get the delegate callbacks (object-model.md §3,
//    "delegate callbacks report changes made elsewhere").

import Foundation

/// The identity of the app process behind a session.
public struct YcodeHomeClient: Codable, Hashable, Sendable {
    public var bundleIdentifier: String
    /// `NSHomeKitUsageDescription`; nil means missing.
    public var usageDescription: String?
    /// The `com.apple.developer.homekit` entitlement.
    public var hasHomeKitEntitlement: Bool
    /// When false (processes without an Info.plist), the usage-string and
    /// entitlement requirements of simulator-baseline.md §2 are not applied.
    public var enforcesRequirements: Bool

    public init(bundleIdentifier: String, usageDescription: String? = "Ycode test client",
                hasHomeKitEntitlement: Bool = true, enforcesRequirements: Bool = true) {
        self.bundleIdentifier = bundleIdentifier
        self.usageDescription = usageDescription
        self.hasHomeKitEntitlement = hasHomeKitEntitlement
        self.enforcesRequirements = enforcesRequirements
    }

    /// The current process: bundle identifier and usage string from the main
    /// bundle's Info.plist, or `YCODE_HOMEKIT_BUNDLE_IDENTIFIER` /
    /// `YCODE_HOMEKIT_USAGE_DESCRIPTION`. A process without an Info.plist is
    /// treated as meeting the requirements (there is no entitlement source
    /// on Linux; `YCODE_HOMEKIT_ENTITLED=0` turns the entitlement off).
    public static var processDefault: YcodeHomeClient {
        let env = ProcessInfo.processInfo.environment
        let info = Bundle.main.infoDictionary ?? [:]
        let hasPlist = info["CFBundleIdentifier"] != nil
        let bundle = env["YCODE_HOMEKIT_BUNDLE_IDENTIFIER"] ?? Bundle.main.bundleIdentifier
            ?? "local.\(ProcessInfo.processInfo.processName)"
        let usage = env["YCODE_HOMEKIT_USAGE_DESCRIPTION"] ?? info["NSHomeKitUsageDescription"] as? String
        return YcodeHomeClient(bundleIdentifier: bundle,
                               usageDescription: usage ?? (hasPlist ? nil : "Ycode command-line client"),
                               hasHomeKitEntitlement: env["YCODE_HOMEKIT_ENTITLED"] != "0",
                               enforcesRequirements: hasPlist)
    }
}

public struct YcodeHomeSession: Codable, Hashable, Sendable {
    public var id: UUID
    /// `HMHomeManagerAuthorizationStatus` raw value at connection time.
    public var authorizationStatus: UInt
}

/// A request from a client (one per mutation or I/O call of object-model.md).
public enum YcodeHomeRequest: Codable, Hashable, Sendable {
    // Homes (object-model.md §2)
    case addHome(name: String)
    case removeHome(UUID)
    case renameHome(UUID, name: String)
    case updatePrimaryHome(UUID)
    // Rooms, zones, service groups (§3, §4)
    case addRoom(home: UUID, name: String)
    case removeRoom(home: UUID, room: UUID)
    case renameRoom(home: UUID, room: UUID, name: String)
    case addZone(home: UUID, name: String)
    case removeZone(home: UUID, zone: UUID)
    case renameZone(home: UUID, zone: UUID, name: String)
    case addRoomToZone(home: UUID, zone: UUID, room: UUID)
    case removeRoomFromZone(home: UUID, zone: UUID, room: UUID)
    case addServiceGroup(home: UUID, name: String)
    case removeServiceGroup(home: UUID, group: UUID)
    case renameServiceGroup(home: UUID, group: UUID, name: String)
    case addServiceToGroup(home: UUID, group: UUID, service: UUID)
    case removeServiceFromGroup(home: UUID, group: UUID, service: UUID)
    // Accessories (§5, §6)
    case setBrowsing(Bool)
    case addAccessory(home: UUID, discovered: UUID)
    case removeAccessory(home: UUID, accessory: UUID)
    case assignAccessory(home: UUID, accessory: UUID, room: UUID)
    case renameAccessory(home: UUID, accessory: UUID, name: String)
    case identifyAccessory(home: UUID, accessory: UUID)
    case unblockAccessory(home: UUID, accessory: UUID)
    case renameService(home: UUID, service: UUID, name: String)
    case updateAssociatedServiceType(home: UUID, service: UUID, type: String?)
    // Characteristics (§7)
    case readCharacteristic(home: UUID, characteristic: UUID)
    case writeCharacteristic(home: UUID, characteristic: UUID, value: YcodeHomeValue)
    case enableNotification(home: UUID, characteristic: UUID, enabled: Bool)
    case updateAuthorizationData(home: UUID, characteristic: UUID, data: Data?)
    // Action sets (§8)
    case addActionSet(home: UUID, name: String)
    case removeActionSet(home: UUID, actionSet: UUID)
    case renameActionSet(home: UUID, actionSet: UUID, name: String)
    case addAction(home: UUID, actionSet: UUID, action: YcodeActionRecord)
    case removeAction(home: UUID, actionSet: UUID, action: UUID)
    case updateActionTarget(home: UUID, action: UUID, value: YcodeHomeValue)
    case executeActionSet(home: UUID, actionSet: UUID)
    // Triggers (§9)
    case addTrigger(home: UUID, trigger: YcodeTriggerRecord)
    case removeTrigger(home: UUID, trigger: UUID)
    case renameTrigger(home: UUID, trigger: UUID, name: String)
    case enableTrigger(home: UUID, trigger: UUID, enabled: Bool)
    case addActionSetToTrigger(home: UUID, trigger: UUID, actionSet: UUID)
    case removeActionSetFromTrigger(home: UUID, trigger: UUID, actionSet: UUID)
    case updateTrigger(home: UUID, trigger: YcodeTriggerRecord)
}

public enum YcodeHomeResponse: Codable, Hashable, Sendable {
    case done
    case home(YcodeHomeRecord)
    case object(UUID)
    case value(YcodeHomeValue?)
    case discovered([YcodeDiscoveredAccessoryRecord])
}

/// What changed inside a home; each case corresponds to one delegate callback
/// of `HMHomeDelegate` / `HMAccessoryDelegate` (object-model.md §3, §5).
public enum YcodeHomeChange: Codable, Hashable, Sendable {
    case homeName
    case accessoryAdded(UUID)
    case accessoryRemoved(UUID, bridged: [UUID])
    case accessoryRoom(accessory: UUID, room: UUID)
    case accessoryName(UUID)
    case accessoryUnblocked(UUID)
    case accessoryReachability(UUID)
    case serviceName(accessory: UUID, service: UUID)
    case associatedServiceType(accessory: UUID, service: UUID)
    case roomAdded(UUID)
    case roomRemoved(UUID)
    case roomName(UUID)
    case zoneAdded(UUID)
    case zoneRemoved(UUID)
    case zoneName(UUID)
    case roomAddedToZone(room: UUID, zone: UUID)
    case roomRemovedFromZone(room: UUID, zone: UUID)
    case serviceGroupAdded(UUID)
    case serviceGroupRemoved(UUID)
    case serviceGroupName(UUID)
    case serviceAddedToGroup(service: UUID, group: UUID)
    case serviceRemovedFromGroup(service: UUID, group: UUID)
    case actionSetAdded(UUID)
    case actionSetRemoved(UUID)
    case actionSetName(UUID)
    case actionSetActions(UUID)
    case triggerAdded(UUID)
    case triggerRemoved(UUID)
    case triggerName(UUID)
    case triggerUpdated(UUID)
    case hubState
    /// State without a delegate callback (execution flags, cached values).
    case state
}

/// A message from the store to one session.
public enum YcodeHomeEvent: Codable, Hashable, Sendable {
    case authorizationStatus(UInt)
    /// Initial load (or resync): every home the client may see.
    case homesLoaded([YcodeHomeRecord])
    case homeAdded(YcodeHomeRecord, origin: UUID)
    case homeRemoved(UUID, origin: UUID)
    case homeUpdated(YcodeHomeRecord, change: YcodeHomeChange, origin: UUID)
    /// A value notification for a characteristic this session subscribed to.
    case characteristicValue(home: UUID, accessory: UUID, service: UUID, characteristic: UUID, value: YcodeHomeValue?)
    case accessoryDiscovered(YcodeDiscoveredAccessoryRecord)
    case accessoryDiscoveryRemoved(UUID)
    /// The store dropped the session (missing entitlement, simulator-baseline.md §2).
    case disconnected
}

/// A home store: the in-memory `YcodeLocalHomeStore` now, `ycode-homed` later.
public protocol YcodeHomeStore: AnyObject, Sendable {
    func connect(client: YcodeHomeClient, events: @escaping @Sendable (YcodeHomeEvent) -> Void) -> YcodeHomeSession
    func disconnect(_ session: UUID)
    func perform(_ request: YcodeHomeRequest, session: UUID,
                 completion: @escaping @Sendable (Result<YcodeHomeResponse, YcodeHomeStoreError>) -> Void)
}
