// Payloads of the signed transaction, renewal info and app transaction
// (formats.md §2.2–§2.4), `deviceVerification`, and the batch signer.
import Crypto
import Foundation
import StoreKitConfiguration
import StoreKitEngine

/// `deviceVerification` (formats.md §2.2): base64 of SHA-384 over the
/// lower-case nonce followed by the lower-case vendor identifier, both in the
/// hyphenated 8-4-4-4-12 form.
public enum DeviceVerification {
    public static func value(nonce: UUID, vendorID: UUID) -> String {
        let text = nonce.uuidString.lowercased() + vendorID.uuidString.lowercased()
        return Data(SHA384.hash(data: Data(text.utf8))).base64EncodedString()
    }
}

/// What every payload of one signing batch shares (formats.md §2.2: JWS
/// signed in one batch share the nonce, `deviceVerification` and `signedDate`).
public struct SigningContext: Hashable, Sendable {
    public var bundleID: String
    /// `identifierForVendor` / `AppStore.deviceVerificationID`.
    public var vendorID: UUID
    public var nonce: UUID
    public var signedDate: StoreMilliseconds
    public var environment: String
    public var appTransactionID: String

    public init(
        bundleID: String, vendorID: UUID, nonce: UUID = UUID(), signedDate: StoreMilliseconds, environment: String = "Xcode",
        appTransactionID: String = "0"
    ) {
        self.bundleID = bundleID
        self.vendorID = vendorID
        self.nonce = nonce
        self.signedDate = signedDate
        self.environment = environment
        self.appTransactionID = appTransactionID
    }

    public var deviceVerification: String { DeviceVerification.value(nonce: nonce, vendorID: vendorID) }

    var common: [String: JSONValue] {
        [
            "environment": .string(environment), "appTransactionId": .string(appTransactionID),
            "signedDate": .number(JSONNumber(literal: String(signedDate))),
            "deviceVerification": .string(deviceVerification),
            "deviceVerificationNonce": .string(nonce.uuidString.lowercased()),
        ]
    }
}

func ms(_ v: StoreMilliseconds) -> JSONValue { .number(JSONNumber(literal: String(v))) }

public enum Payloads {
    /// The signed transaction payload (formats.md §2.2).
    public static func transaction(_ r: TransactionRecord, context: SigningContext) -> JSONValue {
        var o = context.common
        o["transactionId"] = .string(String(r.id))
        o["originalTransactionId"] = .string(String(r.originalID))
        o["webOrderLineItemId"] = .string(String(r.webOrderLineItemID))
        o["bundleId"] = .string(context.bundleID)
        o["productId"] = .string(r.productID)
        o["purchaseDate"] = ms(r.purchaseDate)
        o["originalPurchaseDate"] = ms(r.originalPurchaseDate)
        o["quantity"] = .int(r.quantity)
        o["type"] = .string(r.productType.rawValue)
        o["inAppOwnershipType"] = .string("PURCHASED")
        o["transactionReason"] = .string(r.reason.rawValue)
        o["storefront"] = .string(r.storefront)
        o["storefrontId"] = .string(r.storefrontID)
        o["currency"] = .string(r.currency)
        o["price"] = .int(r.priceMilli)
        o["storeType"] = .string("CONSUMER")
        if r.productType == .autoRenewable {
            if let g = r.subscriptionGroupID { o["subscriptionGroupIdentifier"] = .string(g) }
            if let e = r.expiresDate { o["expiresDate"] = ms(e) }
            o["billingPlanType"] = .string("BILLED_UPFRONT")
        }
        if let token = r.appAccountToken { o["appAccountToken"] = .string(token.uuidString.lowercased()) }
        if let offer = r.offer {
            o["offerType"] = .int(offer.type.rawValue)
            o["offerDiscountType"] = .string(offer.paymentMode.rawValue)
            o["offerPeriod"] = .string(offer.period.iso8601)
            if let id = offer.identifier { o["offerIdentifier"] = .string(id) }
        }
        if let d = r.revocationDate {
            o["revocationDate"] = ms(d)
            o["revocationReason"] = .int(r.revocationReason ?? 0)
            if let t = r.revocationType { o["revocationType"] = .string(t) }
            if let p = r.revocationPercentage { o["revocationPercentage"] = .int(p) }
        }
        if r.isUpgraded { o["isUpgraded"] = .bool(true) }
        return .object(o)
    }

    /// The signed renewal info payload (formats.md §2.3).
    public static func renewalInfo(_ s: RenewalSnapshot, context: SigningContext) -> JSONValue {
        var o = context.common
        o["originalTransactionId"] = .string(String(s.originalTransactionID))
        o["productId"] = .string(s.productID)
        o["autoRenewProductId"] = .string(s.autoRenewProductID)
        o["autoRenewStatus"] = .int(s.autoRenewStatus)
        if let d = s.renewalDate { o["renewalDate"] = ms(d) }
        if let p = s.renewalPriceMilli { o["renewalPrice"] = .int(p) }
        if let t = s.renewalBillingPlanType { o["renewalBillingPlanType"] = .string(t) }
        o["recentSubscriptionStartDate"] = ms(s.recentSubscriptionStartDate)
        o["isInBillingRetryPeriod"] = .bool(s.isInBillingRetryPeriod)
        if let g = s.gracePeriodExpiresDate { o["gracePeriodExpiresDate"] = ms(g) }
        if let i = s.expirationIntent { o["expirationIntent"] = .int(i) }
        if let offer = s.pendingOffer {
            o["offerType"] = .int(offer.type.rawValue)
            o["offerDiscountType"] = .string(offer.paymentMode.rawValue)
            o["offerPeriod"] = .string(offer.period.iso8601)
            if let id = offer.identifier { o["offerIdentifier"] = .string(id) }
        }
        o["eligibleWinBackOfferIds"] = .array(s.eligibleWinBackOfferIDs.map { .string($0) })
        o["currency"] = .string(s.currency)
        return .object(o)
    }

    /// The signed app transaction payload (formats.md §2.4).
    public static func appTransaction(applicationVersion: String, originalApplicationVersion: String? = nil, context: SigningContext)
        -> JSONValue
    {
        var o = context.common
        o["signedDate"] = nil
        o["receiptType"] = .string(context.environment)
        o["bundleId"] = .string(context.bundleID)
        o["applicationVersion"] = .string(applicationVersion)
        o["originalApplicationVersion"] = .string(originalApplicationVersion ?? applicationVersion)
        o["originalPlatform"] = .string("iOS")
        o["originalPurchaseDate"] = .int(0)
        o["receiptCreationDate"] = ms(context.signedDate)
        o["requestDate"] = ms(context.signedDate)
        o["environment"] = nil
        return .object(o)
    }
}

/// Signs store records for one app with the device identity.
public struct StoreSigner: Sendable {
    public let identity: SigningIdentity
    public let bundleID: String
    public let vendorID: UUID

    public init(identity: SigningIdentity, bundleID: String, vendorID: UUID) {
        self.identity = identity
        self.bundleID = bundleID
        self.vendorID = vendorID
    }

    public func context(at date: Date, nonce: UUID = UUID()) -> SigningContext {
        SigningContext(bundleID: bundleID, vendorID: vendorID, nonce: nonce, signedDate: date.storeMilliseconds)
    }

    /// Signs transactions as one batch (one nonce, one signed date).
    /// `simulated` is the app's `verification` simulated error; `invalidSignature` corrupts the signatures.
    public func sign(_ records: [TransactionRecord], at date: Date, nonce: UUID = UUID(), simulated: SimulatedFailure? = nil) throws -> [String] {
        let ctx = context(at: date, nonce: nonce)
        let corrupt = simulated == .verification(.invalidSignature)
        return try records.map { try JWS.sign(Payloads.transaction($0, context: ctx), identity: identity, corruptSignature: corrupt) }
    }

    public func sign(_ renewal: RenewalSnapshot, at date: Date, nonce: UUID = UUID(), simulated: SimulatedFailure? = nil) throws -> String {
        try JWS.sign(Payloads.renewalInfo(renewal, context: context(at: date, nonce: nonce)), identity: identity,
                     corruptSignature: simulated == .verification(.invalidSignature))
    }

    public func signAppTransaction(applicationVersion: String, originalApplicationVersion: String? = nil, at date: Date, nonce: UUID = UUID())
        throws -> String
    {
        try JWS.sign(Payloads.appTransaction(
            applicationVersion: applicationVersion, originalApplicationVersion: originalApplicationVersion,
            context: context(at: date, nonce: nonce)), identity: identity)
    }
}
