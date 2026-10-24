// The accessory abstraction: what a home store needs from an accessory
// server. It is shaped after HAP-IP (accessory-protocols.md §2: an attribute
// database of accessories `aid` → services → characteristics `iid`, reads,
// writes, event subscriptions, HAP status codes), so R5's HAP controller can
// provide endpoints for real or simulated servers, and R3's in-memory
// `YcodeTestAccessory` provides them for tests.

import Foundation

/// `aid.iid` of one characteristic on an endpoint.
public struct YcodeCharacteristicAddress: Hashable, Codable, Sendable, CustomStringConvertible {
    public var aid: Int
    public var iid: Int
    public init(aid: Int, iid: Int) { self.aid = aid; self.iid = iid }
    public var description: String { "\(aid).\(iid)" }
}

/// HAP characteristic permissions (accessory-protocols.md §2.3, last bullet).
public enum YcodeHAPPermission: String, Codable, Hashable, Sendable, CaseIterable {
    case pairedRead = "pr"
    case pairedWrite = "pw"
    case events = "ev"
    case additionalAuthorization = "aa"
    case timedWrite = "tw"
    case hidden = "hd"
    case writeResponse = "wr"

    /// The `HMCharacteristicProperty…` string a permission maps to, if any.
    public var property: String? {
        switch self {
        case .pairedRead: return HMCharacteristicPropertyReadable
        case .pairedWrite: return HMCharacteristicPropertyWritable
        case .events: return HMCharacteristicPropertySupportsEventNotification
        case .additionalAuthorization: return HMCharacteristicPropertyRequiresAuthorizationData
        case .hidden: return HMCharacteristicPropertyHidden
        case .timedWrite, .writeResponse: return nil
        }
    }

    /// Property strings in the catalog's order for a permission list.
    public static func properties(_ perms: [YcodeHAPPermission]) -> [String] {
        let order: [YcodeHAPPermission] = [.pairedRead, .pairedWrite, .events, .hidden, .additionalAuthorization]
        return order.filter(perms.contains).compactMap(\.property)
    }
}

/// The attribute database of an endpoint (the content of HAP's `/accessories`).
public struct YcodeAccessoryDatabase: Codable, Hashable, Sendable {
    public struct Characteristic: Codable, Hashable, Sendable {
        public var iid: Int
        /// Full uppercase type UUID.
        public var type: String
        public var permissions: [YcodeHAPPermission]
        public var metadata: YcodeCharacteristicMetadata
        public var value: YcodeHomeValue?

        public init(iid: Int, type: String, permissions: [YcodeHAPPermission],
                    metadata: YcodeCharacteristicMetadata, value: YcodeHomeValue?) {
            self.iid = iid
            self.type = YcodeHomeCatalog.normalizedTypeUUID(type) ?? type
            self.permissions = permissions
            self.metadata = metadata
            self.value = value
        }
    }

    public struct Service: Codable, Hashable, Sendable {
        public var iid: Int
        public var type: String
        public var isPrimary: Bool
        public var isHidden: Bool
        public var linkedIIDs: [Int]
        public var characteristics: [Characteristic]

        public init(iid: Int, type: String, isPrimary: Bool = false, isHidden: Bool = false,
                    linkedIIDs: [Int] = [], characteristics: [Characteristic]) {
            self.iid = iid
            self.type = YcodeHomeCatalog.normalizedTypeUUID(type) ?? type
            self.isPrimary = isPrimary
            self.isHidden = isHidden
            self.linkedIIDs = linkedIIDs
            self.characteristics = characteristics
        }
    }

    public struct Accessory: Codable, Hashable, Sendable {
        public var aid: Int
        public var services: [Service]
        public init(aid: Int, services: [Service]) { self.aid = aid; self.services = services }
    }

    public var accessories: [Accessory]
    public init(accessories: [Accessory]) { self.accessories = accessories }
}

/// Receives unsolicited messages from an endpoint (HAP `EVENT/1.0` messages,
/// connection loss and recovery). Implemented by the home store.
public protocol YcodeAccessoryEndpointDelegate: AnyObject, Sendable {
    func endpoint(_ endpointID: String, didUpdateValues values: [YcodeCharacteristicAddress: YcodeHomeValue])
    func endpoint(_ endpointID: String, didChangeReachability reachable: Bool)
}

/// One accessory server. Completions may run on any thread.
public protocol YcodeAccessoryEndpoint: AnyObject, Sendable {
    /// Stable identity (HAP device ID, `XX:XX:XX:XX:XX:XX`).
    var endpointID: String { get }
    /// Advertised name (HAP `md`/the primary accessory's Name).
    var name: String { get }
    /// HAP category number (`ci`, accessory-protocols.md §2.5).
    var categoryNumber: Int { get }
    var isReachable: Bool { get }
    /// Set by the store that pairs with the endpoint. Held weakly.
    var delegate: YcodeAccessoryEndpointDelegate? { get set }

    func fetchDatabase(completion: @escaping @Sendable (Result<YcodeAccessoryDatabase, YcodeAccessoryFailure>) -> Void)
    func read(_ address: YcodeCharacteristicAddress,
              completion: @escaping @Sendable (Result<YcodeHomeValue?, YcodeAccessoryFailure>) -> Void)
    func write(_ address: YcodeCharacteristicAddress, value: YcodeHomeValue, authorizationData: Data?,
               completion: @escaping @Sendable (Result<Void, YcodeAccessoryFailure>) -> Void)
    func setEventsEnabled(_ enabled: Bool, for address: YcodeCharacteristicAddress,
                          completion: @escaping @Sendable (Result<Void, YcodeAccessoryFailure>) -> Void)
    func identify(completion: @escaping @Sendable (Result<Void, YcodeAccessoryFailure>) -> Void)
}
