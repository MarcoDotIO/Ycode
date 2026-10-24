// Accessory setup types (object-model.md §11, simulator-baseline.md §6–§7,
// accessory-protocols.md §2.6). The setup sheet and payload decoding are
// plan.md R7; this round has the value types and the "no setup UI" path.

import Foundation

/// Opaque vendor data that proves ownership of an accessory.
open class HMAccessoryOwnershipToken: NSObject, @unchecked Sendable {
    let data: Data
    /// Accepts arbitrary bytes (simulator-baseline.md §7).
    public init(data: Data) { self.data = data }
}

/// A HomeKit setup payload from a setup URL.
open class HMAccessorySetupPayload: NSObject, @unchecked Sendable {
    /// The URL as given.
    public let ycodeURL: URL
    public let ycodeOwnershipToken: HMAccessoryOwnershipToken?

    /// `X-HM://` followed by exactly 13 characters (9 base-36 characters and a
    /// 4-character setup ID); anything else, including Matter `MT:` codes, is
    /// rejected (simulator-baseline.md §7, T-O6).
    public init?(url setupPayloadURL: URL?) {
        guard let url = setupPayloadURL, HMAccessorySetupPayload.isValid(url.absoluteString) else { return nil }
        ycodeURL = url
        ycodeOwnershipToken = nil
    }

    public init?(url setupPayloadURL: URL?, ownershipToken: HMAccessoryOwnershipToken?) {
        guard let url = setupPayloadURL, HMAccessorySetupPayload.isValid(url.absoluteString) else { return nil }
        ycodeURL = url
        ycodeOwnershipToken = ownershipToken
    }

    static func isValid(_ text: String) -> Bool {
        let scheme = "X-HM://"
        guard text.count == scheme.count + 13, text.uppercased().hasPrefix(scheme) else { return false }
        return text.dropFirst(scheme.count).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}

/// What to set up (copyable; a copy is equal to the original).
open class HMAccessorySetupRequest: NSObject, NSCopying, @unchecked Sendable {
    public var payload: HMAccessorySetupPayload?
    public var homeUniqueIdentifier: UUID?
    public var suggestedRoomUniqueIdentifier: UUID?
    public var suggestedAccessoryName: String?

    public override init() { super.init() }

    public func copy(with zone: NSZone? = nil) -> Any {
        let c = HMAccessorySetupRequest()
        c.payload = payload
        c.homeUniqueIdentifier = homeUniqueIdentifier
        c.suggestedRoomUniqueIdentifier = suggestedRoomUniqueIdentifier
        c.suggestedAccessoryName = suggestedAccessoryName
        return c
    }

    open override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? HMAccessorySetupRequest else { return false }
        return o.payload === payload && o.homeUniqueIdentifier == homeUniqueIdentifier
            && o.suggestedRoomUniqueIdentifier == suggestedRoomUniqueIdentifier
            && o.suggestedAccessoryName == suggestedAccessoryName
    }

    open override var hash: Int {
        var h = Hasher()
        h.combine(homeUniqueIdentifier)
        h.combine(suggestedRoomUniqueIdentifier)
        h.combine(suggestedAccessoryName)
        return h.finalize()
    }
}

open class HMAccessorySetupResult: NSObject, @unchecked Sendable {
    public let homeUniqueIdentifier: UUID
    public let accessoryUniqueIdentifiers: [UUID]
    init(homeUniqueIdentifier: UUID, accessoryUniqueIdentifiers: [UUID]) {
        self.homeUniqueIdentifier = homeUniqueIdentifier
        self.accessoryUniqueIdentifiers = accessoryUniqueIdentifiers
    }
}

/// Presents the setup flow. Ycode has no setup sheet in this round (R7), so
/// every request ends as the reference's dismissed flow does: error 23 with
/// an empty userInfo, on the main queue (simulator-baseline.md §6, HK-B12).
open class HMAccessorySetupManager: NSObject, @unchecked Sendable {
    public class var isSupported: Bool { true }

    public override init() { super.init() }

    public func performAccessorySetup(using request: HMAccessorySetupRequest,
                                      completionHandler completion: @escaping (HMAccessorySetupResult?, Error?) -> Void) {
        onMain { completion(nil, HMError.cancelledWithoutInfo) }
    }

    public func performAccessorySetup(using request: HMAccessorySetupRequest) async throws -> HMAccessorySetupResult {
        try await asyncCall { performAccessorySetup(using: request, completionHandler: $0) }
    }
}
