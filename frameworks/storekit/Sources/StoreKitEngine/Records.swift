// The store's records: transactions, subscriptions, settings overrides,
// simulated failures, events and errors (design.md §4.2; testing-session.md).
import Foundation
import StoreKitConfiguration

/// `SKTestTransaction` state (StoreKit 1 numbering, testing-session.md §6–§8).
public enum TransactionState: Int, Codable, Sendable {
    case purchasing = 0
    case purchased = 1
    case failed = 2
    case restored = 3
    case deferred = 4
}

/// `transactionReason` (formats.md §2.2).
public enum TransactionReason: String, Codable, Sendable {
    case purchase = "PURCHASE"
    case renewal = "RENEWAL"
}

/// An offer applied to one transaction or pending for the next renewal.
public struct AppliedOffer: Hashable, Codable, Sendable {
    public var type: OfferType
    /// Promotional offer id or code; nil for introductory offers.
    public var identifier: String?
    public var paymentMode: OfferPaymentMode
    /// `offerPeriod`: the offer's whole duration (formats.md §2.2; README spec question 6).
    public var period: SubscriptionDuration
    /// The price of one billed period in milli-units.
    public var priceMilli: Int
}

/// One transaction of the local store (design.md §4.2's transaction table).
public struct TransactionRecord: Hashable, Codable, Sendable, Identifiable {
    /// Decimal counter value per app (testing-session.md §10); also `webOrderLineItemId`.
    public var id: UInt64
    public var originalID: UInt64
    public var productID: String
    public var productType: ProductType
    public var subscriptionGroupID: String?
    public var state: TransactionState
    public var reason: TransactionReason
    public var isFinished: Bool
    public var purchaseDate: StoreMilliseconds
    public var originalPurchaseDate: StoreMilliseconds
    public var expiresDate: StoreMilliseconds?
    public var quantity: Int
    /// Price × 1000 (formats.md §2.2).
    public var priceMilli: Int
    public var currency: String
    public var storefront: String
    public var storefrontID: String
    public var appAccountToken: UUID?
    public var offer: AppliedOffer?
    /// Waiting for Ask-to-Buy approval (state `deferred`).
    public var isPendingAskToBuy: Bool
    /// Ask to Buy declined (state `failed`).
    public var isAskToBuyDeclined: Bool
    public var revocationDate: StoreMilliseconds?
    /// 0 other, 1 developer issue.
    public var revocationReason: Int?
    /// `REFUND_FULL` after a test-session refund.
    public var revocationType: String?
    /// Thousandths of a percent (100000 = 100 %).
    public var revocationPercentage: Int?
    public var hasPurchaseIssue: Bool
    public var isUpgraded: Bool
    /// The request an Ask-to-Buy transaction will complete when approved.
    public var pendingRequest: PurchaseOptions?

    public var webOrderLineItemID: UInt64 { id }
    public var isRevoked: Bool { revocationDate != nil }
    public var purchase: Date { Date(storeMilliseconds: purchaseDate) }
    public var expiration: Date? { expiresDate.map(Date.init(storeMilliseconds:)) }
}

/// `Product.SubscriptionInfo.RenewalState` raw values (testing-session.md §3.2).
public enum RenewalState: Int, Codable, Sendable {
    case subscribed = 1
    case expired = 2
    case inBillingRetryPeriod = 3
    case inGracePeriod = 4
    case revoked = 5
}

/// An offer that still applies to coming renewals (pay-as-you-go periods left).
public struct ContinuingOffer: Hashable, Codable, Sendable {
    public var offer: AppliedOffer
    /// One billed period of the offer.
    public var billedPeriod: SubscriptionDuration
    public var remainingPeriods: Int
}

/// One auto-renewable subscription: an original transaction and its renewals.
public struct SubscriptionChain: Hashable, Codable, Sendable {
    public var originalID: UInt64
    public var groupID: String
    /// The product of the current period.
    public var productID: String
    /// The product of the next period (changes on crossgrade or downgrade).
    public var autoRenewProductID: String
    public var autoRenewEnabled: Bool
    public var expirationIntent: Int?
    public var state: RenewalState
    public var currentTransactionID: UInt64
    /// The original purchase's date.
    public var originalPurchaseDate: StoreMilliseconds
    /// The end of the current period (the grace end while in grace).
    public var expiresDate: StoreMilliseconds
    public var recentStartDate: StoreMilliseconds
    public var gracePeriodExpiresDate: StoreMilliseconds?
    public var billingRetryEndDate: StoreMilliseconds?
    /// A renewal failed and was not resolved.
    public var hasBillingIssue: Bool
    public var continuingOffer: ContinuingOffer?
    /// An offer (an offer code) attached to the next renewal; `remainingPeriods` is its period count.
    public var pendingOffer: ContinuingOffer?
    /// Replaced by a higher level of the same group.
    public var isUpgradedAway: Bool

    public var isActive: Bool { state == .subscribed || state == .inGracePeriod || state == .inBillingRetryPeriod }
    /// Whether the customer has access (subscribed or in grace).
    public var isEntitled: Bool { state == .subscribed || state == .inGracePeriod }
}

/// Renewal information (formats.md §2.3) at one moment.
public struct RenewalSnapshot: Hashable, Sendable {
    public var originalTransactionID: UInt64
    public var productID: String
    public var autoRenewProductID: String
    public var autoRenewStatus: Int
    public var renewalDate: StoreMilliseconds?
    public var renewalPriceMilli: Int?
    /// `BILLED_UPFRONT`; nil once auto-renew is off.
    public var renewalBillingPlanType: String?
    public var recentSubscriptionStartDate: StoreMilliseconds
    public var isInBillingRetryPeriod: Bool
    public var gracePeriodExpiresDate: StoreMilliseconds?
    public var expirationIntent: Int?
    public var pendingOffer: AppliedOffer?
    public var currency: String
    public var eligibleWinBackOfferIDs: [String]
}

/// One entry of `Product.SubscriptionInfo.status(for:)`.
public struct SubscriptionStatusSnapshot: Hashable, Sendable {
    public var state: RenewalState
    public var transaction: TransactionRecord
    public var renewal: RenewalSnapshot
}

// MARK: - Options

/// A promotional offer signed by the developer (`promotionalOffer(offerID:keyID:nonce:signature:timestamp:)`).
public struct SignedPromotionalOffer: Hashable, Codable, Sendable {
    public var offerID: String
    public var keyID: String
    public var nonce: UUID
    public var signature: Data
    /// Milliseconds since 1970.
    public var timestamp: Int64

    public init(offerID: String, keyID: String, nonce: UUID, signature: Data, timestamp: Int64) {
        self.offerID = offerID
        self.keyID = keyID
        self.nonce = nonce
        self.signature = signature
        self.timestamp = timestamp
    }
}

/// What happens after a backdated purchase (`purchaseDate(_:renewalBehavior:)`).
public enum BackdatedRenewalBehavior: String, Hashable, Codable, Sendable {
    /// Renew until the present (the default).
    case renewUntilNow
    /// Auto-renew off: the subscription ends after its first period.
    case cancelImmediately
}

/// Purchase options (testing-session.md §4).
public struct PurchaseOptions: Hashable, Codable, Sendable {
    public var quantity: Int
    public var appAccountToken: UUID?
    public var signedPromotionalOffer: SignedPromotionalOffer?
    /// The StoreKitTest-only unsigned promotional offer (`promotionalOffer(id:)`).
    public var promotionalOfferID: String?
    /// `codeOffer(referenceName:)`.
    public var codeOfferReferenceName: String?
    /// `purchaseDate(_:renewalBehavior:)`.
    public var purchaseDate: Date?
    public var renewalBehavior: BackdatedRenewalBehavior
    /// `custom(key:value:)`: accepted, not reflected in the transaction.
    public var custom: [String: String]

    public init(
        quantity: Int = 1, appAccountToken: UUID? = nil, signedPromotionalOffer: SignedPromotionalOffer? = nil,
        promotionalOfferID: String? = nil, codeOfferReferenceName: String? = nil, purchaseDate: Date? = nil,
        renewalBehavior: BackdatedRenewalBehavior = .renewUntilNow, custom: [String: String] = [:]
    ) {
        self.quantity = quantity
        self.appAccountToken = appAccountToken
        self.signedPromotionalOffer = signedPromotionalOffer
        self.promotionalOfferID = promotionalOfferID
        self.codeOfferReferenceName = codeOfferReferenceName
        self.purchaseDate = purchaseDate
        self.renewalBehavior = renewalBehavior
        self.custom = custom
    }
}

/// The result of a purchase that did not throw.
public enum PurchaseOutcome: Hashable, Sendable {
    /// The new transaction, or an existing one returned again (`isRedelivery`).
    case success(TransactionRecord, isRedelivery: Bool)
    /// Ask to Buy: waiting for approval; the deferred transaction.
    case pending(TransactionRecord)
    case userCancelled

    public var transaction: TransactionRecord? {
        switch self {
        case .success(let t, _), .pending(let t): return t
        case .userCancelled: return nil
        }
    }
}

// MARK: - Simulated failures (testing-session.md §9)

/// The APIs that accept a simulated error.
public enum StoreAPI: String, Codable, Sendable, CaseIterable {
    case loadProducts, purchase, verification, appStoreSync, subscriptionStatus, appTransaction
    case manageSubscriptions, offerCodeRedeem, refundRequest
}

/// A generic `StoreKitError` to simulate.
public enum GenericFailure: Hashable, Codable, Sendable {
    case unknown
    case systemError
    case networkError(code: Int)
    case notAvailableInStorefront
    case notEntitled
    case unsupported
    case userCancelled
}

/// `Product.PurchaseError` cases.
public enum PurchaseFailureReason: String, Hashable, Codable, Sendable, CaseIterable {
    case invalidQuantity, productUnavailable, purchaseNotAllowed, ineligibleForOffer
    case invalidOfferIdentifier, invalidOfferPrice, invalidOfferSignature, missingOfferParameters
}

/// `VerificationResult.VerificationError` cases.
public enum VerificationFailureReason: String, Hashable, Codable, Sendable, CaseIterable {
    case revokedCertificate, invalidCertificateChain, invalidDeviceVerification, invalidEncoding
    case invalidSignature, missingRequiredProperties
}

/// `Transaction.RefundRequestError` cases.
public enum RefundRequestFailureReason: String, Hashable, Codable, Sendable, CaseIterable {
    case duplicateRequest, failed
}

/// One simulated error (`SKTestFailures`).
public enum SimulatedFailure: Hashable, Codable, Sendable {
    case generic(GenericFailure)
    case purchase(PurchaseFailureReason)
    case verification(VerificationFailureReason)
    case refundRequest(RefundRequestFailureReason)
}

// MARK: - Settings

/// Session properties set through the API; each wins over the file until reset (configuration-file.md §6).
public struct SettingsOverrides: Hashable, Codable, Sendable {
    public var storefront: String?
    public var locale: String?
    public var timeRate: TimeRate?
    public var askToBuyEnabled: Bool?
    public var interruptedPurchasesEnabled: Bool?
    public var billingRetryOnRenewalEnabled: Bool?
    public var billingGracePeriodEnabled: Bool?
    public var disableDialogs: Bool?
    public var failTransactionsEnabled: Bool?
    /// Raw values of `StoreAPI`.
    public var simulatedErrors: [String: SimulatedFailure]

    public init() { simulatedErrors = [:] }
}

/// The settings in force: the file's, overlaid with the overrides.
public struct EffectiveSettings: Hashable, Sendable {
    public var storefront: Storefront
    public var locale: String
    public var timeRate: TimeRate
    public var askToBuyEnabled: Bool
    public var interruptedPurchasesEnabled: Bool
    public var billingRetryOnRenewalEnabled: Bool
    public var billingGracePeriodEnabled: Bool
    public var disableDialogs: Bool
    public var failTransactionsEnabled: Bool
    public var simulatedErrors: [StoreAPI: SimulatedFailure]

    /// `en_US@currency=USD`.
    public var priceLocale: String { storefront.priceLocaleIdentifier(locale: locale) }
}

/// Behaviors of the reference store that look like bugs; on by default for parity.
public struct EngineQuirks: Hashable, Sendable {
    /// A declined Ask-to-Buy transaction is still delivered and listed (testing-session.md §6, open question 6).
    public var declinedAskToBuyIsDelivered: Bool
    /// `expireSubscription` leaves an extra failed transaction with a purchase issue (testing-session.md §2).
    public var expireLeavesFailedTransaction: Bool

    public init(declinedAskToBuyIsDelivered: Bool = true, expireLeavesFailedTransaction: Bool = true) {
        self.declinedAskToBuyIsDelivered = declinedAskToBuyIsDelivered
        self.expireLeavesFailedTransaction = expireLeavesFailedTransaction
    }

    /// The reference's observed behavior.
    public static let reference = EngineQuirks()
    /// Ycode's cleaned-up behavior.
    public static let none = EngineQuirks(declinedAskToBuyIsDelivered: false, expireLeavesFailedTransaction: false)
}

// MARK: - Events

/// What the store reports to a running app (`Transaction.updates` and friends).
public enum StoreEvent: Hashable, Sendable {
    /// A transaction to deliver through `Transaction.updates`.
    case transaction(TransactionRecord)
    /// The configuration was installed or removed.
    case configurationChanged
    /// The storefront changed.
    case storefrontChanged(Storefront)
}

// MARK: - Errors

/// `StoreKitError` kinds the store produces (errors.md §1).
public enum StoreKitErrorKind: Hashable, Sendable {
    case unknown
    case userCancelled
    case networkError(code: Int)
    case systemError(SystemErrorReason)
    case notAvailableInStorefront
    case notEntitled
    case unsupported
}

/// The payload of `StoreKitError.systemError` in the local store.
public enum SystemErrorReason: String, Hashable, Sendable {
    /// No configuration installed for the app.
    case noAccount
    case unknown
}

/// A system alert the store shows (simulator-baseline.md §6); always marked "[Environment: Xcode]".
public struct StoreAlert: Hashable, Sendable {
    public var title: String
    public var message: String
    public static let environmentNote = "[Environment: Xcode]"
}

/// A failed client call: the error kind the app receives, the alert shown
/// first (if any), and the transaction the store recorded (interrupted purchases).
public struct StoreFailure: Error, Hashable, Sendable {
    public var kind: StoreKitErrorKind
    public var alert: StoreAlert?
    public var record: TransactionRecord?
    public var simulated: SimulatedFailure?

    public init(_ kind: StoreKitErrorKind, alert: StoreAlert? = nil, record: TransactionRecord? = nil, simulated: SimulatedFailure? = nil) {
        self.kind = kind
        self.alert = alert
        self.record = record
        self.simulated = simulated
    }
}

/// `SKTestError.Code` (errors.md §3).
public enum TestErrorCode: Int, Hashable, Sendable {
    case serviceUnavailable = 0
    case invalidProductIdentifier = 1
    case invalidProductType = 2
    case invalidURL = 3
    case fileNotFound = 4
    case noSubscriptionFound = 5
    case noTransactionFound = 6
    case invalidAction = 7
}

/// A failed test-session control call. `code` is the documented
/// `SKTestErrorDomain` code; the reference returned the observed form
/// (`SKServiceErrorDomain` 2 / `SKInternalErrorDomain` 17) for all of them
/// (testing-session.md §11, errors.md §3).
public struct TestSessionError: Error, Hashable, Sendable, CustomStringConvertible {
    public var code: TestErrorCode
    public var detail: String

    public init(_ code: TestErrorCode, _ detail: String) {
        self.code = code
        self.detail = detail
    }

    public static let observedDomain = "SKServiceErrorDomain"
    public static let observedCode = 2
    public static let observedUnderlyingDomain = "SKInternalErrorDomain"
    public static let observedUnderlyingCode = 17
    public static let documentedDomain = "SKTestErrorDomain"

    public var description: String { "\(code) (\(code.rawValue)): \(detail)" }
}
