// The typed model of a `.storekit` configuration file (configuration-file.md §2–§7).
//
// Every object type keeps the keys it does not know in `extra`, and a known
// key whose value has an unexpected type is kept there verbatim too, so a
// parse → write cycle never loses data. Optional properties distinguish an
// absent key from an empty value; the writer emits exactly the keys present.

/// A whole configuration file (§2).
public struct StoreConfiguration: Hashable, Sendable {
    /// `identifier`: 8 uppercase hexadecimal digits.
    public var identifier: String?
    /// `version`: format version (`4.0` loads on the reference).
    public var version: Version?
    /// `products`: consumables and non-consumables (§3).
    public var products: [ConfiguredProduct]?
    /// `nonRenewingSubscriptions` (§3).
    public var nonRenewingSubscriptions: [ConfiguredProduct]?
    /// `subscriptionGroups` (§4).
    public var subscriptionGroups: [SubscriptionGroup]?
    /// `settings` (§6).
    public var settings: Settings?
    /// `appPolicies` (§7).
    public var appPolicies: AppPolicies?
    /// `appName`: added by the store to its private copy (§8).
    public var appName: String?
    /// Unknown keys, including the App Store Connect synchronization keys
    /// (`_applicationInternalID`, `_developerTeamID`, `_lastSynchronizedDate`).
    public var extra: [String: JSONValue]

    public init(
        identifier: String? = nil, version: Version? = nil, products: [ConfiguredProduct]? = nil,
        nonRenewingSubscriptions: [ConfiguredProduct]? = nil, subscriptionGroups: [SubscriptionGroup]? = nil,
        settings: Settings? = nil, appPolicies: AppPolicies? = nil, appName: String? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.identifier = identifier
        self.version = version
        self.products = products
        self.nonRenewingSubscriptions = nonRenewingSubscriptions
        self.subscriptionGroups = subscriptionGroups
        self.settings = settings
        self.appPolicies = appPolicies
        self.appName = appName
        self.extra = extra
    }

    /// The App Store Connect synchronization keys (§2); such a file is read-only in an editor.
    public static let synchronizationKeys = ["_applicationInternalID", "_developerTeamID", "_lastSynchronizedDate"]

    /// Whether the file carries any synchronization key.
    public var isSynchronized: Bool { StoreConfiguration.synchronizationKeys.contains { extra[$0] != nil } }

    /// Every product of the file in file order: `products`, then
    /// `nonRenewingSubscriptions`, then each group's `subscriptions`.
    public var allProducts: [ConfiguredProduct] {
        (products ?? []) + (nonRenewingSubscriptions ?? []) + (subscriptionGroups ?? []).flatMap { $0.subscriptions ?? [] }
    }
}

/// `version` (§2).
public struct Version: Hashable, Sendable {
    public var major: Int?
    public var minor: Int?
    public var extra: [String: JSONValue]

    public init(major: Int? = nil, minor: Int? = nil, extra: [String: JSONValue] = [:]) {
        self.major = major
        self.minor = minor
        self.extra = extra
    }
}

/// The `type` string of a product (§3, §5). Unknown strings are kept.
public struct ProductKind: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let consumable = ProductKind(rawValue: "Consumable")
    public static let nonConsumable = ProductKind(rawValue: "NonConsumable")
    public static let nonRenewingSubscription = ProductKind(rawValue: "NonRenewingSubscription")
    public static let recurringSubscription = ProductKind(rawValue: "RecurringSubscription")

    public var description: String { rawValue }
}

/// A product object (§3) or an auto-renewable subscription object (§5).
/// The subscription keys are present only on subscriptions.
public struct ConfiguredProduct: Hashable, Sendable {
    public var type: ProductKind?
    public var productID: String?
    public var referenceName: String?
    /// Digits; becomes the `id` of the product JSON (formats.md §1).
    public var internalID: String?
    /// Decimal string with `.` in the storefront's currency.
    public var displayPrice: String?
    public var familyShareable: Bool?
    public var localizations: [Localization]?
    // §5: auto-renewable subscriptions
    public var subscriptionGroupID: String?
    /// The level in the group; 1 is the highest service level.
    public var groupNumber: Int?
    /// ISO 8601 duration (`P1W`, `P1M`, `P1Y`, …).
    public var recurringSubscriptionPeriod: String?
    public var introductoryOffer: Offer?
    public var adHocOffers: [Offer]?
    public var codeOffers: [Offer]?
    /// Win-back offers; element structure not specified (configuration-file.md §10 q5), kept as JSON.
    public var winbackOffers: [JSONValue]?
    public var extra: [String: JSONValue]

    public init(
        type: ProductKind? = nil, productID: String? = nil, referenceName: String? = nil, internalID: String? = nil,
        displayPrice: String? = nil, familyShareable: Bool? = nil, localizations: [Localization]? = nil,
        subscriptionGroupID: String? = nil, groupNumber: Int? = nil, recurringSubscriptionPeriod: String? = nil,
        introductoryOffer: Offer? = nil, adHocOffers: [Offer]? = nil, codeOffers: [Offer]? = nil,
        winbackOffers: [JSONValue]? = nil, extra: [String: JSONValue] = [:]
    ) {
        self.type = type
        self.productID = productID
        self.referenceName = referenceName
        self.internalID = internalID
        self.displayPrice = displayPrice
        self.familyShareable = familyShareable
        self.localizations = localizations
        self.subscriptionGroupID = subscriptionGroupID
        self.groupNumber = groupNumber
        self.recurringSubscriptionPeriod = recurringSubscriptionPeriod
        self.introductoryOffer = introductoryOffer
        self.adHocOffers = adHocOffers
        self.codeOffers = codeOffers
        self.winbackOffers = winbackOffers
        self.extra = extra
    }
}

/// `{ "locale", "displayName", "description" }` (§3, §4).
public struct Localization: Hashable, Sendable {
    public var locale: String?
    public var displayName: String?
    public var description: String?
    public var extra: [String: JSONValue]

    public init(locale: String? = nil, displayName: String? = nil, description: String? = nil, extra: [String: JSONValue] = [:]) {
        self.locale = locale
        self.displayName = displayName
        self.description = description
        self.extra = extra
    }
}

/// A subscription group (§4).
public struct SubscriptionGroup: Hashable, Sendable {
    /// Digits; the subscription group identifier.
    public var id: String?
    public var name: String?
    public var localizations: [Localization]?
    public var subscriptions: [ConfiguredProduct]?
    public var extra: [String: JSONValue]

    public init(
        id: String? = nil, name: String? = nil, localizations: [Localization]? = nil, subscriptions: [ConfiguredProduct]? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.localizations = localizations
        self.subscriptions = subscriptions
        self.extra = extra
    }
}

/// `paymentMode` of an offer (§5.1). Unknown strings are kept.
public struct PaymentMode: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let free = PaymentMode(rawValue: "free")
    public static let payAsYouGo = PaymentMode(rawValue: "payAsYouGo")
    public static let payUpFront = PaymentMode(rawValue: "payUpFront")

    public var description: String { rawValue }
}

/// An introductory, promotional (`adHocOffers`) or code offer (§5.1, §5.2).
public struct Offer: Hashable, Sendable {
    public var internalID: String?
    /// Promotional offers only.
    public var offerID: String?
    /// Promotional and code offers; for a code offer, the code.
    public var referenceName: String?
    public var paymentMode: PaymentMode?
    /// ISO 8601 duration of one offer period.
    public var subscriptionPeriod: String?
    public var numberOfPeriods: Int?
    public var displayPrice: String?
    /// Code offers: any of `new`, `existing`, `expired`.
    public var eligibility: [String]?
    /// Code offers.
    public var isStackable: Bool?
    public var extra: [String: JSONValue]

    public init(
        internalID: String? = nil, offerID: String? = nil, referenceName: String? = nil, paymentMode: PaymentMode? = nil,
        subscriptionPeriod: String? = nil, numberOfPeriods: Int? = nil, displayPrice: String? = nil,
        eligibility: [String]? = nil, isStackable: Bool? = nil, extra: [String: JSONValue] = [:]
    ) {
        self.internalID = internalID
        self.offerID = offerID
        self.referenceName = referenceName
        self.paymentMode = paymentMode
        self.subscriptionPeriod = subscriptionPeriod
        self.numberOfPeriods = numberOfPeriods
        self.displayPrice = displayPrice
        self.eligibility = eligibility
        self.isStackable = isStackable
        self.extra = extra
    }
}

/// `settings` (§6). Every key starts with an underscore.
public struct Settings: Hashable, Sendable {
    /// `_storefront`: ISO 3166-1 alpha-3 country.
    public var storefront: String?
    /// `_locale`: locale identifier.
    public var locale: String?
    /// `_timeRate`: raw `SKTestSession.TimeRate` value; 0 is real time.
    public var timeRate: Int?
    public var askToBuyEnabled: Bool?
    /// `_billingIssuesEnabled` (session `interruptedPurchasesEnabled`).
    public var billingIssuesEnabled: Bool?
    /// `_renewalBillingIssuesEnabled` (session `shouldEnterBillingRetryOnRenewal`).
    public var renewalBillingIssuesEnabled: Bool?
    public var billingGracePeriodEnabled: Bool?
    public var disableDialogs: Bool?
    public var failTransactionsEnabled: Bool?
    /// `_storeKitErrors`; element structure not specified (§10 q6), kept as JSON.
    public var storeKitErrors: [JSONValue]?
    public var extra: [String: JSONValue]

    public init(
        storefront: String? = nil, locale: String? = nil, timeRate: Int? = nil, askToBuyEnabled: Bool? = nil,
        billingIssuesEnabled: Bool? = nil, renewalBillingIssuesEnabled: Bool? = nil,
        billingGracePeriodEnabled: Bool? = nil, disableDialogs: Bool? = nil, failTransactionsEnabled: Bool? = nil,
        storeKitErrors: [JSONValue]? = nil, extra: [String: JSONValue] = [:]
    ) {
        self.storefront = storefront
        self.locale = locale
        self.timeRate = timeRate
        self.askToBuyEnabled = askToBuyEnabled
        self.billingIssuesEnabled = billingIssuesEnabled
        self.renewalBillingIssuesEnabled = renewalBillingIssuesEnabled
        self.billingGracePeriodEnabled = billingGracePeriodEnabled
        self.disableDialogs = disableDialogs
        self.failTransactionsEnabled = failTransactionsEnabled
        self.storeKitErrors = storeKitErrors
        self.extra = extra
    }

    /// The defaults of a new file (ide.md §6 item 2): USA, `en_US`, real time,
    /// every toggle off, no simulated errors.
    public static let defaults = Settings(
        storefront: "USA", locale: "en_US", timeRate: 0, askToBuyEnabled: false, billingIssuesEnabled: false,
        renewalBillingIssuesEnabled: false, billingGracePeriodEnabled: false, disableDialogs: false,
        failTransactionsEnabled: false, storeKitErrors: [])
}

/// `appPolicies` (§7).
public struct AppPolicies: Hashable, Sendable {
    public var eula: String?
    public var policies: [Policy]?
    public var extra: [String: JSONValue]

    public init(eula: String? = nil, policies: [Policy]? = nil, extra: [String: JSONValue] = [:]) {
        self.eula = eula
        self.policies = policies
        self.extra = extra
    }
}

/// `{ "locale", "policyText", "policyURL" }` (§7).
public struct Policy: Hashable, Sendable {
    public var locale: String?
    public var policyText: String?
    public var policyURL: String?
    public var extra: [String: JSONValue]

    public init(locale: String? = nil, policyText: String? = nil, policyURL: String? = nil, extra: [String: JSONValue] = [:]) {
        self.locale = locale
        self.policyText = policyText
        self.policyURL = policyURL
        self.extra = extra
    }
}
