// `Product` and its nested types (configuration-file.md §3–§5; formats.md §1;
// testing-session.md §3–§5, §9).
import Foundation
import StoreKitConfiguration
import StoreKitEngine
import StoreKitSigning

/// An in-app product of the store.
public struct Product: Identifiable, Hashable, Sendable {
    public typealias ID = String

    public let id: String
    public let type: ProductType
    public let displayName: String
    public let description: String
    public let price: Decimal
    public let displayPrice: String
    public let isFamilyShareable: Bool
    public let subscription: SubscriptionInfo?
    /// The catalog resource (formats.md §1).
    public let jsonRepresentation: Data
    /// The price locale (`en_US@currency=USD`).
    public let priceLocale: Locale

    init(_ p: CatalogProduct, catalog: Catalog, settings: EffectiveSettings) {
        let locale = settings.locale
        let priceLocale = settings.priceLocale
        id = p.id
        type = ProductType(p.type)
        displayName = p.displayName(locale: locale)
        description = p.description(locale: locale) ?? ""
        price = p.price
        displayPrice = PriceFormatter.displayPrice(p.price, priceLocale: priceLocale)
        isFamilyShareable = p.isFamilyShareable
        jsonRepresentation = ProductJSON.data(p, catalog: catalog, locale: locale, storefront: settings.storefront)
        self.priceLocale = Locale(identifier: priceLocale)
        subscription = p.subscription.map { s in
            func offer(_ o: CatalogOffer) -> SubscriptionOffer {
                SubscriptionOffer(
                    id: o.type == .introductory ? nil : o.identifier, type: SubscriptionOffer.OfferType(o.type), price: o.price,
                    displayPrice: PriceFormatter.displayPrice(o.price, priceLocale: priceLocale), period: SubscriptionPeriod(o.period),
                    periodCount: o.periodCount, paymentMode: SubscriptionOffer.PaymentMode(o.paymentMode))
            }
            return SubscriptionInfo(
                introductoryOffer: s.introductoryOffer.map(offer), promotionalOffers: s.promotionalOffers.map(offer),
                winBackOffers: [], subscriptionGroupID: s.groupID, subscriptionPeriod: SubscriptionPeriod(s.period),
                groupLevel: s.level, groupDisplayName: catalog.group(s.groupID)?.displayName(locale: locale) ?? "")
        }
    }

    /// `Product.products(for:)`: the configured products among `identifiers`;
    /// unknown ones are left out (configuration-file.md §8 item 4).
    public static func products<C: Collection>(for identifiers: C) async throws -> [Product] where C.Element == String {
        let rt = YcodeStoreKit.shared
        let found: [CatalogProduct]
        do { found = try rt.store.products(for: Array(identifiers)) } catch { throw StoreKitError(error.kind) }
        guard let catalog = rt.store.catalog else { return [] }
        let settings = rt.store.settings
        return found.map { Product($0, catalog: catalog, settings: settings) }
    }

    /// Buys the product (testing-session.md §4–§9).
    public func purchase(options: Set<PurchaseOption> = []) async throws -> PurchaseResult {
        let rt = YcodeStoreKit.shared
        let settings = rt.store.settings
        let opts = PurchaseOption.engineOptions(options)
        if !settings.disableDialogs {
            let confirmation = PurchaseConfirmation(
                product: self, quantity: opts.quantity, buttonTitle: type == .autoRenewable ? "Subscribe" : "Purchase",
                environmentNote: StoreAlert.environmentNote)
            guard await rt.confirmPurchase(confirmation) else { return .userCancelled }
        }
        let outcome: PurchaseOutcome
        do {
            outcome = try rt.store.purchase(productID: id, options: opts)
        } catch {
            if let alert = error.alert { await rt.show(alert) }
            throw StoreKitError(error.kind)
        }
        switch outcome {
        case .success(let record, _):
            guard let result = rt.verificationResult(record) else { throw StoreKitError.unknown }
            return .success(result)
        case .pending: return .pending
        case .userCancelled: return .userCancelled
        }
    }

    /// The newest transaction of this product.
    public var latestTransaction: VerificationResult<Transaction>? { get async { await Transaction.latest(for: id) } }

    /// This product's current entitlements.
    public var currentEntitlements: Transaction.Transactions { Transaction.currentEntitlements(for: id) }

    public var currentEntitlement: VerificationResult<Transaction>? { get async { await Transaction.currentEntitlement(for: id) } }

    public static func == (a: Product, b: Product) -> Bool { a.jsonRepresentation == b.jsonRepresentation }
    public func hash(into h: inout Hasher) { h.combine(jsonRepresentation) }

    // MARK: Nested types

    /// `Product.ProductType`: raw values as the app sees them (configuration-file.md §3).
    public struct ProductType: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        init(_ t: StoreKitEngine.ProductType) { rawValue = t.rawValue }
        public static let consumable = ProductType(rawValue: "Consumable")
        public static let nonConsumable = ProductType(rawValue: "Non-Consumable")
        public static let nonRenewable = ProductType(rawValue: "Non-Renewing Subscription")
        public static let autoRenewable = ProductType(rawValue: "Auto-Renewable Subscription")
        public var localizedDescription: String { rawValue }
    }

    /// `Product.PurchaseResult`.
    public enum PurchaseResult: Sendable {
        case success(VerificationResult<Transaction>)
        case userCancelled
        case pending
    }

    /// `Product.PurchaseError` (errors.md §2).
    public enum PurchaseError: Error, Hashable, Sendable {
        case invalidQuantity, productUnavailable, purchaseNotAllowed, ineligibleForOffer, invalidOfferIdentifier
        case invalidOfferPrice, invalidOfferSignature, missingOfferParameters, paymentMethodBindingConfigurationRequired
    }

    /// A subscription or offer period.
    public struct SubscriptionPeriod: Hashable, Sendable, CustomDebugStringConvertible {
        public enum Unit: Hashable, Sendable, CustomDebugStringConvertible {
            case day, week, month, year
            public var debugDescription: String {
                switch self {
                case .day: return "day"
                case .week: return "week"
                case .month: return "month"
                case .year: return "year"
                }
            }
            public var localizedDescription: String { debugDescription }
        }

        public let unit: Unit
        public let value: Int

        init(unit: Unit, value: Int) {
            self.unit = unit
            self.value = value
        }

        init(_ d: SubscriptionDuration) {
            switch d.unit {
            case .day: unit = .day
            case .week: unit = .week
            case .month: unit = .month
            case .year: unit = .year
            }
            value = d.value
        }

        public static let weekly = SubscriptionPeriod(unit: .week, value: 1)
        public static let monthly = SubscriptionPeriod(unit: .month, value: 1)
        public static let yearly = SubscriptionPeriod(unit: .year, value: 1)
        public static let everyThreeDays = SubscriptionPeriod(unit: .day, value: 3)
        public static let everyTwoWeeks = SubscriptionPeriod(unit: .week, value: 2)
        public static let everyTwoMonths = SubscriptionPeriod(unit: .month, value: 2)
        public static let everyThreeMonths = SubscriptionPeriod(unit: .month, value: 3)
        public static let everySixMonths = SubscriptionPeriod(unit: .month, value: 6)

        public var debugDescription: String { "\(value) \(unit.debugDescription)\(value == 1 ? "" : "s")" }
    }

    /// An introductory or promotional offer of a subscription.
    public struct SubscriptionOffer: Hashable, Sendable {
        public let id: String?
        public let type: OfferType
        public let price: Decimal
        public let displayPrice: String
        public let period: SubscriptionPeriod
        public let periodCount: Int
        public let paymentMode: PaymentMode

        public struct OfferType: RawRepresentable, Hashable, Sendable {
            public let rawValue: String
            public init(rawValue: String) { self.rawValue = rawValue }
            init(_ t: StoreKitEngine.OfferType) {
                switch t {
                case .introductory: rawValue = "introductory"
                case .promotional: rawValue = "promotional"
                case .code: rawValue = "code"
                case .winBack: rawValue = "winBack"
                }
            }
            public static let introductory = OfferType(rawValue: "introductory")
            public static let promotional = OfferType(rawValue: "promotional")
            public static let winBack = OfferType(rawValue: "winBack")
            public var localizedDescription: String { rawValue }
        }

        public struct PaymentMode: RawRepresentable, Hashable, Sendable {
            public let rawValue: String
            public init(rawValue: String) { self.rawValue = rawValue }
            init(_ m: OfferPaymentMode) { rawValue = m.productJSONMode }
            public static let freeTrial = PaymentMode(rawValue: "FreeTrial")
            public static let payAsYouGo = PaymentMode(rawValue: "PayAsYouGo")
            public static let payUpFront = PaymentMode(rawValue: "PayUpFront")
            public var localizedDescription: String { rawValue }
        }

        /// The signature of a promotional offer (`promotionalOffer(offerID:signature:)`).
        public struct Signature: Hashable, Sendable {
            public let keyID: String
            public let nonce: UUID
            public let timestamp: Int
            public let signature: Data

            public init(keyID: String, nonce: UUID, timestamp: Int, signature: Data) {
                self.keyID = keyID
                self.nonce = nonce
                self.timestamp = timestamp
                self.signature = signature
            }
        }
    }
}

extension Product: CustomDebugStringConvertible {
    public var debugDescription: String { String(decoding: jsonRepresentation, as: UTF8.self) }
}
