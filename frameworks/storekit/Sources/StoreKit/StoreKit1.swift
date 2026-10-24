// StoreKit 1 over the same store (simulator-baseline.md §7; errors.md §4;
// formats.md §3): product requests, the payment queue, restore, the receipt.
// Callbacks arrive on `YcodeStoreKit.shared.callbackQueue` (the main queue by default).
import Foundation
import StoreKitConfiguration
import StoreKitEngine

/// `SKErrorDomain` errors (errors.md §4).
public struct SKError: CustomNSError, Hashable, Sendable {
    public enum Code: Int, Hashable, Sendable {
        case unknown = 0, clientInvalid, paymentCancelled, paymentInvalid, paymentNotAllowed, storeProductNotAvailable
        case cloudServicePermissionDenied, cloudServiceNetworkConnectionFailed, cloudServiceRevoked
        case privacyAcknowledgementRequired, unauthorizedRequestData, invalidOfferIdentifier, invalidSignature
        case missingOfferParams, invalidOfferPrice, overlayCancelled, overlayInvalidConfiguration, overlayTimeout
        case ineligibleForOffer, unsupportedPlatform, overlayPresentedInBackgroundScene
        case paymentMethodBindingConfigurationRequired
    }

    public let code: Code
    public init(_ code: Code) { self.code = code }

    public static let errorDomain = "SKErrorDomain"
    public var errorCode: Int { code.rawValue }
    public static var errorDomainName: String { errorDomain }
}

/// `SKPaymentTransactionState`.
public enum SKPaymentTransactionState: Int, Sendable {
    case purchasing = 0, purchased, failed, restored, deferred
}

/// Delegate of every request.
public protocol SKRequestDelegate: AnyObject {
    func requestDidFinish(_ request: SKRequest)
    func request(_ request: SKRequest, didFailWithError error: any Error)
}

extension SKRequestDelegate {
    public func requestDidFinish(_ request: SKRequest) {}
    public func request(_ request: SKRequest, didFailWithError error: any Error) {}
}

/// Delegate of a products request.
public protocol SKProductsRequestDelegate: SKRequestDelegate {
    func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse)
}

open class SKRequest: NSObject, @unchecked Sendable {
    open weak var delegate: (any SKRequestDelegate)?
    var isCancelled = false

    open func start() {}

    open func cancel() { isCancelled = true }
}

/// The products and the unknown identifiers of a request.
open class SKProductsResponse: NSObject, @unchecked Sendable {
    public let products: [SKProduct]
    public let invalidProductIdentifiers: [String]

    init(products: [SKProduct], invalidProductIdentifiers: [String]) {
        self.products = products
        self.invalidProductIdentifiers = invalidProductIdentifiers
    }
}

open class SKProductsRequest: SKRequest, @unchecked Sendable {
    let identifiers: Set<String>

    public init(productIdentifiers: Set<String>) { identifiers = productIdentifiers }

    open override func start() {
        let rt = YcodeStoreKit.shared
        rt.callbackQueue.async { [self] in
            guard !isCancelled else { return }
            do {
                let found = try rt.store.products(for: identifiers.sorted())
                let settings = rt.store.settings
                let catalog = rt.store.catalog
                let products = found.compactMap { p in catalog.map { SKProduct(p, catalog: $0, settings: settings) } }
                let invalid = identifiers.filter { id in !found.contains { $0.id == id } }.sorted()
                let response = SKProductsResponse(products: products, invalidProductIdentifiers: invalid)
                (delegate as? any SKProductsRequestDelegate)?.productsRequest(self, didReceive: response)
                delegate?.requestDidFinish(self)
            } catch {
                delegate?.request(self, didFailWithError: SKError(.unknown))
            }
        }
    }
}

/// `SKReceiptRefreshRequest`: writes the receipt (formats.md §3) and finishes.
open class SKReceiptRefreshRequest: SKRequest, @unchecked Sendable {
    public let receiptProperties: [String: Any]?

    public init(receiptProperties: [String: Any]? = nil) { self.receiptProperties = receiptProperties }

    open override func start() {
        let rt = YcodeStoreKit.shared
        rt.callbackQueue.async { [self] in
            guard !isCancelled else { return }
            do {
                try rt.writeReceipt()
                delegate?.requestDidFinish(self)
            } catch {
                delegate?.request(self, didFailWithError: SKError(.unknown))
            }
        }
    }
}

/// A subscription period in StoreKit 1 units (week 1, month 2, year 3; plan.md §3.1).
open class SKProductSubscriptionPeriod: NSObject, @unchecked Sendable {
    public let numberOfUnits: Int
    public let unit: SKProduct.PeriodUnit

    init(_ d: SubscriptionDuration) {
        numberOfUnits = d.value
        switch d.unit {
        case .day: unit = .day
        case .week: unit = .week
        case .month: unit = .month
        case .year: unit = .year
        }
    }
}

/// An introductory or promotional offer in StoreKit 1 terms.
open class SKProductDiscount: NSObject, @unchecked Sendable {
    /// pay-as-you-go 0, pay-up-front 1, free trial 2 (plan.md §3.1).
    public enum PaymentMode: UInt, Sendable { case payAsYouGo = 0, payUpFront = 1, freeTrial = 2 }
    public enum `Type`: UInt, Sendable { case introductory = 0, subscription = 1 }

    public let price: NSDecimalNumber
    public let priceLocale: Locale
    public let identifier: String?
    public let subscriptionPeriod: SKProductSubscriptionPeriod
    public let numberOfPeriods: Int
    public let paymentMode: PaymentMode
    public let type: `Type`

    init(_ o: CatalogOffer, priceLocale: Locale) {
        price = NSDecimalNumber(decimal: o.price)
        self.priceLocale = priceLocale
        identifier = o.type == .introductory ? nil : o.identifier
        subscriptionPeriod = SKProductSubscriptionPeriod(o.period)
        numberOfPeriods = o.periodCount
        switch o.paymentMode {
        case .payAsYouGo: paymentMode = .payAsYouGo
        case .payUpFront: paymentMode = .payUpFront
        case .freeTrial: paymentMode = .freeTrial
        }
        type = o.type == .introductory ? .introductory : .subscription
    }
}

open class SKProduct: NSObject, @unchecked Sendable {
    public enum PeriodUnit: UInt, Sendable { case day = 0, week = 1, month = 2, year = 3 }

    public let productIdentifier: String
    public let localizedTitle: String
    public let localizedDescription: String
    public let price: NSDecimalNumber
    /// `en_US@currency=USD`.
    public let priceLocale: Locale
    public let isFamilyShareable: Bool
    public let subscriptionPeriod: SKProductSubscriptionPeriod?
    public let introductoryPrice: SKProductDiscount?
    public let subscriptionGroupIdentifier: String?
    public let discounts: [SKProductDiscount]
    public let isDownloadable = false
    public let downloadContentLengths: [NSNumber] = []
    public let downloadContentVersion = ""

    init(_ p: CatalogProduct, catalog: Catalog, settings: EffectiveSettings) {
        productIdentifier = p.id
        localizedTitle = p.displayName(locale: settings.locale)
        localizedDescription = p.description(locale: settings.locale) ?? ""
        price = NSDecimalNumber(decimal: p.price)
        priceLocale = Locale(identifier: settings.priceLocale)
        isFamilyShareable = p.isFamilyShareable
        subscriptionPeriod = p.subscription.map { SKProductSubscriptionPeriod($0.period) }
        introductoryPrice = p.subscription?.introductoryOffer.map { SKProductDiscount($0, priceLocale: Locale(identifier: settings.priceLocale)) }
        subscriptionGroupIdentifier = p.subscription?.groupID
        discounts = (p.subscription?.promotionalOffers ?? []).map { SKProductDiscount($0, priceLocale: Locale(identifier: settings.priceLocale)) }
    }
}

/// A signed promotional offer for a StoreKit 1 payment.
open class SKPaymentDiscount: NSObject, @unchecked Sendable {
    public let identifier: String
    public let keyIdentifier: String
    public let nonce: UUID
    /// Base64 of the DER signature.
    public let signature: String
    public let timestamp: NSNumber

    public init(identifier: String, keyIdentifier: String, nonce: UUID, signature: String, timestamp: NSNumber) {
        self.identifier = identifier
        self.keyIdentifier = keyIdentifier
        self.nonce = nonce
        self.signature = signature
        self.timestamp = timestamp
    }
}

open class SKPayment: NSObject, @unchecked Sendable {
    var storedProductIdentifier: String
    var storedQuantity = 1
    var storedApplicationUsername: String?
    var storedPaymentDiscount: SKPaymentDiscount?
    var storedSimulatesAskToBuy = false
    var storedRequestData: Data?

    public init(product: SKProduct) { storedProductIdentifier = product.productIdentifier }

    init(productIdentifier: String) { storedProductIdentifier = productIdentifier }

    open var productIdentifier: String { storedProductIdentifier }
    open var quantity: Int { storedQuantity }
    open var applicationUsername: String? { storedApplicationUsername }
    open var paymentDiscount: SKPaymentDiscount? { storedPaymentDiscount }
    open var simulatesAskToBuyInSandbox: Bool { storedSimulatesAskToBuy }
    open var requestData: Data? { storedRequestData }

    func copyPayment() -> SKPayment {
        let p = SKPayment(productIdentifier: storedProductIdentifier)
        p.storedQuantity = storedQuantity
        p.storedApplicationUsername = storedApplicationUsername
        p.storedPaymentDiscount = storedPaymentDiscount
        p.storedSimulatesAskToBuy = storedSimulatesAskToBuy
        p.storedRequestData = storedRequestData
        return p
    }
}

open class SKMutablePayment: SKPayment, @unchecked Sendable {
    open override var productIdentifier: String { get { storedProductIdentifier } set { storedProductIdentifier = newValue } }
    open override var quantity: Int { get { storedQuantity } set { storedQuantity = newValue } }
    open override var applicationUsername: String? { get { storedApplicationUsername } set { storedApplicationUsername = newValue } }
    open override var paymentDiscount: SKPaymentDiscount? { get { storedPaymentDiscount } set { storedPaymentDiscount = newValue } }
    open override var simulatesAskToBuyInSandbox: Bool { get { storedSimulatesAskToBuy } set { storedSimulatesAskToBuy = newValue } }
    open override var requestData: Data? { get { storedRequestData } set { storedRequestData = newValue } }
}

open class SKPaymentTransaction: NSObject, @unchecked Sendable {
    public let payment: SKPayment
    public internal(set) var transactionState: SKPaymentTransactionState
    public internal(set) var transactionIdentifier: String?
    public internal(set) var transactionDate: Date?
    public internal(set) var original: SKPaymentTransaction?
    public internal(set) var error: (any Error)?
    var record: TransactionRecord?

    init(payment: SKPayment, state: SKPaymentTransactionState) {
        self.payment = payment
        transactionState = state
    }

    convenience init(record r: TransactionRecord, state: SKPaymentTransactionState, original: TransactionRecord? = nil) {
        let p = SKPayment(productIdentifier: r.productID)
        p.storedQuantity = r.quantity
        self.init(payment: p, state: state)
        record = r
        transactionIdentifier = String(r.id)
        transactionDate = r.purchase
        if let original {
            let o = SKPaymentTransaction(payment: p, state: .purchased)
            o.record = original
            o.transactionIdentifier = String(original.id)
            o.transactionDate = original.purchase
            self.original = o
        }
    }
}

/// Observer of the payment queue.
public protocol SKPaymentTransactionObserver: AnyObject {
    func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction])
    func paymentQueue(_ queue: SKPaymentQueue, removedTransactions transactions: [SKPaymentTransaction])
    func paymentQueue(_ queue: SKPaymentQueue, restoreCompletedTransactionsFailedWithError error: any Error)
    func paymentQueueRestoreCompletedTransactionsFinished(_ queue: SKPaymentQueue)
    func paymentQueueDidChangeStorefront(_ queue: SKPaymentQueue)
}

extension SKPaymentTransactionObserver {
    public func paymentQueue(_ queue: SKPaymentQueue, removedTransactions transactions: [SKPaymentTransaction]) {}
    public func paymentQueue(_ queue: SKPaymentQueue, restoreCompletedTransactionsFailedWithError error: any Error) {}
    public func paymentQueueRestoreCompletedTransactionsFinished(_ queue: SKPaymentQueue) {}
    public func paymentQueueDidChangeStorefront(_ queue: SKPaymentQueue) {}
}

open class SKStorefront: NSObject, @unchecked Sendable {
    /// Alpha-3 (`USA`).
    public let countryCode: String
    /// `143441`.
    public let identifier: String

    init(countryCode: String, identifier: String) {
        self.countryCode = countryCode
        self.identifier = identifier
    }
}

/// The StoreKit 1 payment queue.
open class SKPaymentQueue: NSObject, @unchecked Sendable {
    private final class WeakObserver {
        weak var value: (any SKPaymentTransactionObserver)?
        init(_ v: any SKPaymentTransactionObserver) { value = v }
    }

    private let lock = NSLock()
    private var observers: [WeakObserver] = []
    private var pending: [SKPaymentTransaction] = []
    private var storeToken: UUID?
    private weak var tokenStore: AppTestStore?

    nonisolated(unsafe) private static var shared = SKPaymentQueue()
    private static let sharedLock = NSLock()

    public static func `default`() -> SKPaymentQueue { sharedLock.withLock { shared } }

    /// Ycode extension: a fresh default queue (for tests that replace the runtime).
    public static func ycodeReset() {
        sharedLock.withLock { shared = SKPaymentQueue() }
    }

    public static func canMakePayments() -> Bool { true }

    /// The storefront in force.
    open var storefront: SKStorefront? {
        let s = YcodeStoreKit.shared.store.settings.storefront
        return SKStorefront(countryCode: s.countryCode, identifier: s.id)
    }

    open var transactions: [SKPaymentTransaction] { lock.withLock { pending } }

    open var transactionObservers: [any SKPaymentTransactionObserver] { lock.withLock { observers.compactMap(\.value) } }

    open func add(_ observer: any SKPaymentTransactionObserver) {
        let rt = YcodeStoreKit.shared
        lock.withLock {
            observers.removeAll { $0.value == nil || $0.value === observer }
            observers.append(WeakObserver(observer))
            if storeToken == nil || tokenStore !== rt.store {
                if let t = storeToken { tokenStore?.removeObserver(t) }
                tokenStore = rt.store
                storeToken = rt.store.addObserver { [weak self] event in self?.storeEvent(event) }
            }
        }
    }

    open func remove(_ observer: any SKPaymentTransactionObserver) {
        lock.withLock { observers.removeAll { $0.value == nil || $0.value === observer } }
    }

    private func notify(_ body: @escaping (any SKPaymentTransactionObserver) -> Void) {
        for o in transactionObservers { body(o) }
    }

    private func updated(_ ts: [SKPaymentTransaction]) {
        lock.withLock {
            for t in ts where !pending.contains(where: { $0 === t }) { pending.append(t) }
        }
        notify { $0.paymentQueue(self, updatedTransactions: ts) }
    }

    /// Renewals, approvals and refunds made by the store reach StoreKit 1 observers as new transactions.
    private func storeEvent(_ event: StoreEvent) {
        // Restores and interrupted purchases are reported by the call that made them.
        guard case .transaction(let r) = event, !r.isRevoked, r.state != .restored, !r.hasPurchaseIssue else { return }
        let rt = YcodeStoreKit.shared
        rt.callbackQueue.async { [self] in
            let state: SKPaymentTransactionState = r.state == .failed ? .failed : .purchased
            let t = SKPaymentTransaction(record: r, state: state)
            if state == .failed { t.error = SKError(.unknown) }
            updated([t])
        }
    }

    /// Adds a payment: `purchasing`, then `purchased`, `deferred` or `failed` (simulator-baseline.md §7).
    open func add(_ payment: SKPayment) {
        let rt = YcodeStoreKit.shared
        let p = payment.copyPayment()
        rt.callbackQueue.async { [self] in
            let t = SKPaymentTransaction(payment: p, state: .purchasing)
            updated([t])
            var options = PurchaseOptions(quantity: p.quantity)
            if let d = p.paymentDiscount {
                options.signedPromotionalOffer = SignedPromotionalOffer(
                    offerID: d.identifier, keyID: d.keyIdentifier, nonce: d.nonce, signature: Data(base64Encoded: d.signature) ?? Data(),
                    timestamp: d.timestamp.int64Value)
            }
            do {
                switch try rt.store.purchase(productID: p.productIdentifier, options: options) {
                case .success(let r, _):
                    t.record = r
                    t.transactionIdentifier = String(r.id)
                    t.transactionDate = r.purchase
                    t.transactionState = .purchased
                    _ = try? rt.writeReceipt()
                case .pending(let r):
                    t.record = r
                    t.transactionState = .deferred
                case .userCancelled:
                    t.transactionState = .failed
                    t.error = SKError(.paymentCancelled)
                }
            } catch {
                if let alert = (error as? StoreFailure)?.alert { Task { await rt.show(alert) } }
                t.transactionState = .failed
                t.error = SKError(.unknown)
            }
            updated([t])
        }
    }

    open func finishTransaction(_ transaction: SKPaymentTransaction) {
        let rt = YcodeStoreKit.shared
        if let r = transaction.record, transaction.transactionState != .deferred { rt.store.finish(transactionID: r.id) }
        let removed = lock.withLock { () -> Bool in
            let before = pending.count
            pending.removeAll { $0 === transaction }
            return pending.count != before
        }
        if removed { rt.callbackQueue.async { [self] in notify { $0.paymentQueue(self, removedTransactions: [transaction]) } } }
    }

    open func restoreCompletedTransactions() { restoreCompletedTransactions(withApplicationUsername: nil) }

    /// New transactions in state `restored` for each non-consumable and active subscription.
    open func restoreCompletedTransactions(withApplicationUsername username: String?) {
        let rt = YcodeStoreKit.shared
        rt.callbackQueue.async { [self] in
            let restored = rt.store.restoreCompletedTransactions()
            let all = rt.store.allTransactions()
            let ts = restored.map { r in
                SKPaymentTransaction(record: r, state: .restored, original: all.first { $0.id == r.originalID })
            }
            for t in ts { t.payment.storedApplicationUsername = username }
            _ = try? rt.writeReceipt()
            if !ts.isEmpty { updated(ts) }
            notify { $0.paymentQueueRestoreCompletedTransactionsFinished(self) }
        }
    }
}

extension YcodeStoreKit {
    /// `Bundle.appStoreReceiptURL` equivalent: where the StoreKit 1 receipt lives.
    public var appStoreReceiptURL: URL? { receiptURL }
}
