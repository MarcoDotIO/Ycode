// `Transaction` (formats.md §2.2; testing-session.md §10).
import Foundation
import StoreKitConfiguration
import StoreKitEngine
import StoreKitSigning

/// A signed in-app transaction, decoded from its JWS payload.
public struct Transaction: Identifiable, Hashable, Sendable, YcodeSignedValue {
    public typealias ID = UInt64

    let jws: String
    let payload: JSONValue

    public var ycodeJWS: String { jws }

    init(jws: String, payload: JSONValue) {
        self.jws = jws
        self.payload = payload
    }

    private func string(_ k: String) -> String? { payload[k]?.stringValue }
    private func int(_ k: String) -> Int? { payload[k]?.numberValue?.intValue }
    private func date(_ k: String) -> Date? { int(k).map { Date(storeMilliseconds: StoreMilliseconds($0)) } }

    /// The payload JSON.
    public var jsonRepresentation: Data { (try? JWS.decode(jws).payloadData) ?? Data() }

    public var id: UInt64 { string("transactionId").flatMap(UInt64.init) ?? 0 }
    public var originalID: UInt64 { string("originalTransactionId").flatMap(UInt64.init) ?? 0 }
    public var webOrderLineItemID: String? { string("webOrderLineItemId") }
    public var productID: String { string("productId") ?? "" }
    public var subscriptionGroupID: String? { string("subscriptionGroupIdentifier") }
    public var appBundleID: String { string("bundleId") ?? "" }
    public var purchaseDate: Date { date("purchaseDate") ?? .distantPast }
    public var originalPurchaseDate: Date { date("originalPurchaseDate") ?? .distantPast }
    public var expirationDate: Date? { date("expiresDate") }
    public var purchasedQuantity: Int { int("quantity") ?? 1 }
    public var isUpgraded: Bool { payload["isUpgraded"]?.boolValue ?? false }
    public var offerType: OfferType? { int("offerType").map(OfferType.init(rawValue:)) }
    public var offerID: String? { string("offerIdentifier") }
    public var offerPaymentModeStringRepresentation: String? { string("offerDiscountType") }
    public var offerPeriodStringRepresentation: String? { string("offerPeriod") }
    /// The applied offer.
    public var offer: Offer? {
        guard let type = offerType else { return nil }
        return Offer(id: offerID, type: type, paymentMode: offerPaymentModeStringRepresentation.map(Offer.PaymentMode.init(rawValue:)),
                     period: offerPeriodStringRepresentation.flatMap(SubscriptionDuration.init(iso8601:)).map(Product.SubscriptionPeriod.init))
    }
    public var revocationDate: Date? { date("revocationDate") }
    public var revocationReason: RevocationReason? { int("revocationReason").map(RevocationReason.init(rawValue:)) }
    public var revocationType: RevocationType? { string("revocationType").map(RevocationType.init(rawValue:)) }
    public var revocationTypeStringRepresentation: String? { string("revocationType") }
    public var revocationPercentage: Int? { int("revocationPercentage") }
    public var productType: Product.ProductType { Product.ProductType(rawValue: string("type") ?? "") }
    public var appAccountToken: UUID? { string("appAccountToken").flatMap(UUID.init(uuidString:)) }
    public var environment: AppStore.Environment { AppStore.Environment(rawValue: string("environment") ?? "") }
    public var environmentStringRepresentation: String { string("environment") ?? "" }
    public var reason: Reason { Reason(rawValue: string("transactionReason") ?? "") }
    public var reasonStringRepresentation: String { string("transactionReason") ?? "" }
    public var storefront: Storefront {
        Storefront(countryCode: string("storefront") ?? "", id: string("storefrontId") ?? "", currencyCode: string("currency"))
    }
    public var storefrontCountryCode: String { string("storefront") ?? "" }
    /// The price paid (`price` / 1000).
    public var price: Decimal? { int("price").map { Decimal($0) / 1000 } }
    public var currencyCode: String? { string("currency") }
    public var appTransactionID: String { string("appTransactionId") ?? "" }
    public var deviceVerification: Data { string("deviceVerification").flatMap { Data(base64Encoded: $0) } ?? Data() }
    public var deviceVerificationNonce: UUID { string("deviceVerificationNonce").flatMap(UUID.init(uuidString:)) ?? UUID() }
    public var ownershipType: OwnershipType { OwnershipType(rawValue: string("inAppOwnershipType") ?? "") }
    public var signedDate: Date { date("signedDate") ?? .distantPast }

    /// `Transaction.finish()`: tells the store the content was delivered.
    public func finish() async { YcodeStoreKit.shared.store.finish(transactionID: id) }

    /// The status of the subscription this transaction belongs to.
    public var subscriptionStatus: Product.SubscriptionInfo.Status? {
        get async {
            let rt = YcodeStoreKit.shared
            guard let s = rt.store.subscriptionStatus(forTransaction: id) else { return nil }
            return Product.SubscriptionInfo.Status.make([s], runtime: rt).first
        }
    }

    public static func == (a: Transaction, b: Transaction) -> Bool { a.jws == b.jws }
    public func hash(into h: inout Hasher) { h.combine(jws) }

    // MARK: Lists (testing-session.md §10 item 4)

    /// Every transaction, newest first; finished consumables left out.
    public static var all: Transactions { list(YcodeStoreKit.shared.store.transactionHistory()) }

    /// One entry per non-consumable and active subscription.
    public static var currentEntitlements: Transactions { list(YcodeStoreKit.shared.store.currentEntitlements()) }

    /// Every unfinished transaction, renewals included.
    public static var unfinished: Transactions { list(YcodeStoreKit.shared.store.unfinishedTransactions()) }

    /// The transactions of one product.
    public static func all(for productID: String) -> Transactions {
        list(YcodeStoreKit.shared.store.transactionHistory().filter { $0.productID == productID })
    }

    /// The entitlements of one product.
    public static func currentEntitlements(for productID: String) -> Transactions {
        list(YcodeStoreKit.shared.store.currentEntitlements().filter { $0.productID == productID })
    }

    public static func currentEntitlement(for productID: String) async -> VerificationResult<Transaction>? {
        let rt = YcodeStoreKit.shared
        return rt.store.currentEntitlements().first { $0.productID == productID }.flatMap(rt.verificationResult)
    }

    /// The newest transaction of a product.
    public static func latest(for productID: String) async -> VerificationResult<Transaction>? {
        let rt = YcodeStoreKit.shared
        return rt.store.latestTransaction(for: productID).flatMap(rt.verificationResult)
    }

    /// Transactions created outside a purchase call: renewals, approvals,
    /// refunds, off-device purchases; it starts with the unfinished transactions.
    public static var updates: Transactions { Transactions(stream: YcodeStoreKit.shared.updatesStream()) }

    /// Signs and verifies one store record (for StoreKitTest).
    @_spi(Ycode) public static func ycodeVerified(_ record: TransactionRecord) async -> VerificationResult<Transaction>? {
        YcodeStoreKit.shared.verificationResult(record)
    }

    static func list(_ records: [TransactionRecord]) -> Transactions {
        let results = YcodeStoreKit.shared.verificationResults(records)
        return Transactions(stream: AsyncStream { c in
            for r in results { c.yield(r) }
            c.finish()
        })
    }

    /// An asynchronous sequence of verified transactions.
    public struct Transactions: AsyncSequence, Sendable {
        public typealias Element = VerificationResult<Transaction>
        let stream: AsyncStream<Element>

        public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(base: stream.makeAsyncIterator()) }

        public struct AsyncIterator: AsyncIteratorProtocol {
            var base: AsyncStream<Element>.AsyncIterator
            public mutating func next() async -> Element? { await base.next() }
        }
    }

    // MARK: Value types

    public struct OfferType: RawRepresentable, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let introductory = OfferType(rawValue: 1)
        public static let promotional = OfferType(rawValue: 2)
        public static let code = OfferType(rawValue: 3)
        public static let winBack = OfferType(rawValue: 4)
    }

    public struct Offer: Hashable, Sendable {
        public let id: String?
        public let type: OfferType
        public let paymentMode: PaymentMode?
        public let period: Product.SubscriptionPeriod?

        public struct PaymentMode: RawRepresentable, Hashable, Sendable {
            public let rawValue: String
            public init(rawValue: String) { self.rawValue = rawValue }
            public static let freeTrial = PaymentMode(rawValue: "FREE_TRIAL")
            public static let payAsYouGo = PaymentMode(rawValue: "PAY_AS_YOU_GO")
            public static let payUpFront = PaymentMode(rawValue: "PAY_UP_FRONT")
            public static let oneTime = PaymentMode(rawValue: "ONE_TIME")
        }
    }

    public struct Reason: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let purchase = Reason(rawValue: "PURCHASE")
        public static let renewal = Reason(rawValue: "RENEWAL")
    }

    public struct RevocationReason: RawRepresentable, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let other = RevocationReason(rawValue: 0)
        public static let developerIssue = RevocationReason(rawValue: 1)
    }

    public struct RevocationType: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let fullRefund = RevocationType(rawValue: "REFUND_FULL")
        public static let proratedRefund = RevocationType(rawValue: "REFUND_PRORATED")
        public static let familyRevocation = RevocationType(rawValue: "FAMILY_REVOKE")
    }

    public struct OwnershipType: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let purchased = OwnershipType(rawValue: "PURCHASED")
        public static let familyShared = OwnershipType(rawValue: "FAMILY_SHARED")
    }

    /// `Transaction.RefundRequestError` (errors.md §2).
    public enum RefundRequestError: Error, Hashable, Sendable {
        case duplicateRequest, failed, ineligible
    }

    /// `Transaction.RefundRequestStatus`.
    public enum RefundRequestStatus: Hashable, Sendable {
        case success, userCancelled
    }
}

extension Transaction: CustomDebugStringConvertible {
    public var debugDescription: String { JSONWriter().string(payload) }
}
