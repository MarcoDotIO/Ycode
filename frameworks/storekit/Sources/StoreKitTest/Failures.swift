// `SKTestFailures` and the failable API markers (testing-session.md §9).
import Foundation
@_spi(Ycode) import StoreKit
import StoreKitEngine

/// A simulated error of one API.
public protocol SKTestFailure: Sendable {
    /// The engine's form.
    var ycodeFailure: SimulatedFailure { get }
    init?(ycode: SimulatedFailure)
}

/// An API that accepts a simulated error.
public protocol FailableStoreKitAPI: Sendable {
    associatedtype Failure: SKTestFailure
    var ycodeAPI: StoreAPI { get }
}

func generic(_ e: StoreKitError) -> SimulatedFailure {
    switch e {
    case .unknown: return .generic(.unknown)
    case .userCancelled: return .generic(.userCancelled)
    case .networkError(let u): return .generic(.networkError(code: u.code.rawValue))
    case .systemError: return .generic(.systemError)
    case .notAvailableInStorefront: return .generic(.notAvailableInStorefront)
    case .notEntitled: return .generic(.notEntitled)
    case .unsupported, .invalidPresentationContext: return .generic(.unsupported)
    }
}

func storeKitError(_ g: GenericFailure) -> StoreKitError {
    switch g {
    case .unknown: return .unknown
    case .userCancelled: return .userCancelled
    case .networkError(let code): return .networkError(URLError(urlErrorCode(code)))
    case .systemError: return .systemError(YcodeStoreSystemError.unknown)
    case .notAvailableInStorefront: return .notAvailableInStorefront
    case .notEntitled: return .notEntitled
    case .unsupported: return .unsupported
    }
}

func purchaseReason(_ e: Product.PurchaseError) -> PurchaseFailureReason {
    switch e {
    case .invalidQuantity: return .invalidQuantity
    case .productUnavailable: return .productUnavailable
    case .purchaseNotAllowed: return .purchaseNotAllowed
    case .ineligibleForOffer: return .ineligibleForOffer
    case .invalidOfferIdentifier: return .invalidOfferIdentifier
    case .invalidOfferPrice: return .invalidOfferPrice
    case .invalidOfferSignature: return .invalidOfferSignature
    case .missingOfferParameters, .paymentMethodBindingConfigurationRequired: return .missingOfferParameters
    }
}

func purchaseError(_ r: PurchaseFailureReason) -> Product.PurchaseError {
    switch r {
    case .invalidQuantity: return .invalidQuantity
    case .productUnavailable: return .productUnavailable
    case .purchaseNotAllowed: return .purchaseNotAllowed
    case .ineligibleForOffer: return .ineligibleForOffer
    case .invalidOfferIdentifier: return .invalidOfferIdentifier
    case .invalidOfferPrice: return .invalidOfferPrice
    case .invalidOfferSignature: return .invalidOfferSignature
    case .missingOfferParameters: return .missingOfferParameters
    }
}

public enum SKTestFailures {
    public enum LoadProducts: SKTestFailure {
        case generic(StoreKitError)
        public var ycodeFailure: SimulatedFailure { if case .generic(let e) = self { return StoreKitTest.generic(e) }; return .generic(.unknown) }
        public init?(ycode f: SimulatedFailure) { guard case .generic(let g) = f else { return nil }; self = .generic(storeKitError(g)) }
        public static func == (a: Self, b: Self) -> Bool { a.ycodeFailure == b.ycodeFailure }
    }

    public enum Purchase: SKTestFailure {
        case generic(StoreKitError)
        case purchase(Product.PurchaseError)
        public var ycodeFailure: SimulatedFailure {
            switch self {
            case .generic(let e): return StoreKitTest.generic(e)
            case .purchase(let e): return .purchase(purchaseReason(e))
            }
        }
        public init?(ycode f: SimulatedFailure) {
            switch f {
            case .generic(let g): self = .generic(storeKitError(g))
            case .purchase(let r): self = .purchase(purchaseError(r))
            default: return nil
            }
        }
        public static func == (a: Self, b: Self) -> Bool { a.ycodeFailure == b.ycodeFailure }
    }

    public enum Verification: SKTestFailure {
        case verification(VerificationResult<Transaction>.VerificationError)
        public var ycodeFailure: SimulatedFailure {
            guard case .verification(let e) = self else { return .verification(.invalidSignature) }
            switch e {
            case .revokedCertificate: return .verification(.revokedCertificate)
            case .invalidCertificateChain: return .verification(.invalidCertificateChain)
            case .invalidDeviceVerification: return .verification(.invalidDeviceVerification)
            case .invalidEncoding: return .verification(.invalidEncoding)
            case .invalidSignature: return .verification(.invalidSignature)
            case .missingRequiredProperties: return .verification(.missingRequiredProperties)
            }
        }
        public init?(ycode f: SimulatedFailure) {
            guard case .verification(let r) = f else { return nil }
            switch r {
            case .revokedCertificate: self = .verification(.revokedCertificate)
            case .invalidCertificateChain: self = .verification(.invalidCertificateChain)
            case .invalidDeviceVerification: self = .verification(.invalidDeviceVerification)
            case .invalidEncoding: self = .verification(.invalidEncoding)
            case .invalidSignature: self = .verification(.invalidSignature)
            case .missingRequiredProperties: self = .verification(.missingRequiredProperties)
            }
        }
        public static func == (a: Self, b: Self) -> Bool { a.ycodeFailure == b.ycodeFailure }
    }

    public enum AppStoreSync: SKTestFailure {
        case generic(StoreKitError)
        public var ycodeFailure: SimulatedFailure { if case .generic(let e) = self { return StoreKitTest.generic(e) }; return .generic(.unknown) }
        public init?(ycode f: SimulatedFailure) { guard case .generic(let g) = f else { return nil }; self = .generic(storeKitError(g)) }
        public static func == (a: Self, b: Self) -> Bool { a.ycodeFailure == b.ycodeFailure }
    }

    public enum SubscriptionStatus: SKTestFailure {
        case generic(StoreKitError)
        public var ycodeFailure: SimulatedFailure { if case .generic(let e) = self { return StoreKitTest.generic(e) }; return .generic(.unknown) }
        public init?(ycode f: SimulatedFailure) { guard case .generic(let g) = f else { return nil }; self = .generic(storeKitError(g)) }
        public static func == (a: Self, b: Self) -> Bool { a.ycodeFailure == b.ycodeFailure }
    }

    public enum AppTransaction: SKTestFailure {
        case generic(StoreKitError)
        public var ycodeFailure: SimulatedFailure { if case .generic(let e) = self { return StoreKitTest.generic(e) }; return .generic(.unknown) }
        public init?(ycode f: SimulatedFailure) { guard case .generic(let g) = f else { return nil }; self = .generic(storeKitError(g)) }
        public static func == (a: Self, b: Self) -> Bool { a.ycodeFailure == b.ycodeFailure }
    }

    public enum ManageSubscriptions: SKTestFailure {
        case generic(StoreKitError)
        public var ycodeFailure: SimulatedFailure { if case .generic(let e) = self { return StoreKitTest.generic(e) }; return .generic(.unknown) }
        public init?(ycode f: SimulatedFailure) { guard case .generic(let g) = f else { return nil }; self = .generic(storeKitError(g)) }
        public static func == (a: Self, b: Self) -> Bool { a.ycodeFailure == b.ycodeFailure }
    }

    public enum OfferCodeRedeem: SKTestFailure {
        case generic(StoreKitError)
        public var ycodeFailure: SimulatedFailure { if case .generic(let e) = self { return StoreKitTest.generic(e) }; return .generic(.unknown) }
        public init?(ycode f: SimulatedFailure) { guard case .generic(let g) = f else { return nil }; self = .generic(storeKitError(g)) }
        public static func == (a: Self, b: Self) -> Bool { a.ycodeFailure == b.ycodeFailure }
    }

    public enum RefundRequest: SKTestFailure {
        case generic(StoreKitError)
        case refundRequest(Transaction.RefundRequestError)
        public var ycodeFailure: SimulatedFailure {
            switch self {
            case .generic(let e): return StoreKitTest.generic(e)
            case .refundRequest(let e): return .refundRequest(e == .duplicateRequest ? .duplicateRequest : .failed)
            }
        }
        public init?(ycode f: SimulatedFailure) {
            switch f {
            case .generic(let g): self = .generic(storeKitError(g))
            case .refundRequest(let r): self = .refundRequest(r == .duplicateRequest ? .duplicateRequest : .failed)
            default: return nil
            }
        }
        public static func == (a: Self, b: Self) -> Bool { a.ycodeFailure == b.ycodeFailure }
    }
}

public struct StoreKitLoadProductsAPI: FailableStoreKitAPI {
    public typealias Failure = SKTestFailures.LoadProducts
    public init() {}
    public var ycodeAPI: StoreAPI { .loadProducts }
}

public struct StoreKitPurchaseAPI: FailableStoreKitAPI {
    public typealias Failure = SKTestFailures.Purchase
    public init() {}
    public var ycodeAPI: StoreAPI { .purchase }
}

public struct StoreKitVerificationAPI: FailableStoreKitAPI {
    public typealias Failure = SKTestFailures.Verification
    public init() {}
    public var ycodeAPI: StoreAPI { .verification }
}

public struct StoreKitAppStoreSyncAPI: FailableStoreKitAPI {
    public typealias Failure = SKTestFailures.AppStoreSync
    public init() {}
    public var ycodeAPI: StoreAPI { .appStoreSync }
}

public struct StoreKitSubscriptionStatusAPI: FailableStoreKitAPI {
    public typealias Failure = SKTestFailures.SubscriptionStatus
    public init() {}
    public var ycodeAPI: StoreAPI { .subscriptionStatus }
}

public struct StoreKitAppTransactionAPI: FailableStoreKitAPI {
    public typealias Failure = SKTestFailures.AppTransaction
    public init() {}
    public var ycodeAPI: StoreAPI { .appTransaction }
}

public struct StoreKitManageSubscriptionsAPI: FailableStoreKitAPI {
    public typealias Failure = SKTestFailures.ManageSubscriptions
    public init() {}
    public var ycodeAPI: StoreAPI { .manageSubscriptions }
}

public struct StoreKitOfferCodeRedeemAPI: FailableStoreKitAPI {
    public typealias Failure = SKTestFailures.OfferCodeRedeem
    public init() {}
    public var ycodeAPI: StoreAPI { .offerCodeRedeem }
}

public struct StoreKitRefundRequestAPI: FailableStoreKitAPI {
    public typealias Failure = SKTestFailures.RefundRequest
    public init() {}
    public var ycodeAPI: StoreAPI { .refundRequest }
}

extension FailableStoreKitAPI where Self == StoreKitLoadProductsAPI { public static var loadProducts: Self { .init() } }
extension FailableStoreKitAPI where Self == StoreKitPurchaseAPI { public static var purchase: Self { .init() } }
extension FailableStoreKitAPI where Self == StoreKitVerificationAPI { public static var verification: Self { .init() } }
extension FailableStoreKitAPI where Self == StoreKitAppStoreSyncAPI { public static var appStoreSync: Self { .init() } }
extension FailableStoreKitAPI where Self == StoreKitSubscriptionStatusAPI { public static var subscriptionStatus: Self { .init() } }
extension FailableStoreKitAPI where Self == StoreKitAppTransactionAPI { public static var appTransaction: Self { .init() } }
extension FailableStoreKitAPI where Self == StoreKitManageSubscriptionsAPI { public static var manageSubscriptions: Self { .init() } }
extension FailableStoreKitAPI where Self == StoreKitOfferCodeRedeemAPI { public static var offerCodeRedeem: Self { .init() } }
extension FailableStoreKitAPI where Self == StoreKitRefundRequestAPI { public static var refundRequest: Self { .init() } }
