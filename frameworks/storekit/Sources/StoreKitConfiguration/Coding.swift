// JSON <-> typed model, and the file-level reader/writer.
import Foundation

/// Errors reading a configuration file.
public enum ConfigurationReadError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The bytes are not JSON.
    case syntax(JSONSyntaxError)
    /// The top-level value is not an object.
    case notAnObject

    public var description: String {
        switch self {
        case .syntax(let e): return "The file is not valid JSON (\(e))."
        case .notAnObject: return "The file's top-level value is not a JSON object."
        }
    }
}

/// Takes known keys out of an object; whatever remains is the `extra` dictionary.
/// A key whose value has the wrong type stays in the remainder.
struct ObjectReader {
    var remaining: [String: JSONValue]

    init(_ object: [String: JSONValue]) { remaining = object }

    mutating func string(_ key: String) -> String? {
        guard case .string(let s)? = remaining[key] else { return nil }
        remaining[key] = nil
        return s
    }

    mutating func int(_ key: String) -> Int? {
        guard case .number(let n)? = remaining[key], let v = n.intValue, String(v) == n.literal else { return nil }
        remaining[key] = nil
        return v
    }

    mutating func bool(_ key: String) -> Bool? {
        guard case .bool(let b)? = remaining[key] else { return nil }
        remaining[key] = nil
        return b
    }

    mutating func rawArray(_ key: String) -> [JSONValue]? {
        guard case .array(let a)? = remaining[key] else { return nil }
        remaining[key] = nil
        return a
    }

    mutating func strings(_ key: String) -> [String]? {
        guard case .array(let a)? = remaining[key] else { return nil }
        var out: [String] = []
        for e in a { guard case .string(let s) = e else { return nil }; out.append(s) }
        remaining[key] = nil
        return out
    }

    /// An array whose every element is an object, decoded with `make`.
    mutating func objects<T>(_ key: String, _ make: ([String: JSONValue]) -> T) -> [T]? {
        guard case .array(let a)? = remaining[key] else { return nil }
        var out: [T] = []
        for e in a { guard case .object(let o) = e else { return nil }; out.append(make(o)) }
        remaining[key] = nil
        return out
    }

    mutating func object<T>(_ key: String, _ make: ([String: JSONValue]) -> T) -> T? {
        guard case .object(let o)? = remaining[key] else { return nil }
        remaining[key] = nil
        return make(o)
    }
}

/// Builds an object from known properties plus `extra`. Known properties win.
struct ObjectBuilder {
    var object: [String: JSONValue]

    init(extra: [String: JSONValue]) { object = extra }

    mutating func set(_ key: String, _ value: String?) { if let value { object[key] = .string(value) } }
    mutating func set(_ key: String, _ value: Int?) { if let value { object[key] = .int(value) } }
    mutating func set(_ key: String, _ value: Bool?) { if let value { object[key] = .bool(value) } }
    mutating func set(_ key: String, _ value: [String]?) { if let value { object[key] = .array(value.map { .string($0) }) } }
    mutating func set(_ key: String, raw value: [JSONValue]?) { if let value { object[key] = .array(value) } }
    mutating func set(_ key: String, _ value: JSONValue?) { if let value { object[key] = value } }
    mutating func set<T>(_ key: String, _ values: [T]?, _ json: (T) -> JSONValue) {
        if let values { object[key] = .array(values.map(json)) }
    }

    var json: JSONValue { .object(object) }
}

// MARK: - Model <-> JSON

extension StoreConfiguration {
    /// Decodes the model from a parsed JSON object (never fails for an object;
    /// unexpected values are preserved in `extra`).
    public init(object: [String: JSONValue]) {
        var r = ObjectReader(object)
        identifier = r.string("identifier")
        version = r.object("version", Version.init(object:))
        products = r.objects("products", ConfiguredProduct.init(object:))
        nonRenewingSubscriptions = r.objects("nonRenewingSubscriptions", ConfiguredProduct.init(object:))
        subscriptionGroups = r.objects("subscriptionGroups", SubscriptionGroup.init(object:))
        settings = r.object("settings", Settings.init(object:))
        appPolicies = r.object("appPolicies", AppPolicies.init(object:))
        appName = r.string("appName")
        extra = r.remaining
    }

    /// Reads a configuration file's bytes.
    public init(data: Data) throws {
        let value: JSONValue
        do { value = try JSONParser.parse(data) } catch let e as JSONSyntaxError { throw ConfigurationReadError.syntax(e) }
        guard case .object(let o) = value else { throw ConfigurationReadError.notAnObject }
        self.init(object: o)
    }

    /// Reads a configuration file.
    public init(contentsOf url: URL) throws { try self.init(data: Data(contentsOf: url)) }

    /// The JSON form (unordered; the writer sorts).
    public var json: JSONValue {
        var b = ObjectBuilder(extra: extra)
        b.set("identifier", identifier)
        b.set("version", version?.json)
        b.set("products", products) { $0.json }
        b.set("nonRenewingSubscriptions", nonRenewingSubscriptions) { $0.json }
        b.set("subscriptionGroups", subscriptionGroups) { $0.json }
        b.set("settings", settings?.json)
        b.set("appPolicies", appPolicies?.json)
        b.set("appName", appName)
        return b.json
    }

    /// The file's bytes in the sorted pretty-printed form of configuration-file.md §1.
    public func data(writer: JSONWriter = JSONWriter()) -> Data { writer.data(json) }
}

extension Version {
    public init(object: [String: JSONValue]) {
        var r = ObjectReader(object)
        major = r.int("major")
        minor = r.int("minor")
        extra = r.remaining
    }

    public var json: JSONValue {
        var b = ObjectBuilder(extra: extra)
        b.set("major", major)
        b.set("minor", minor)
        return b.json
    }
}

extension ConfiguredProduct {
    public init(object: [String: JSONValue]) {
        var r = ObjectReader(object)
        type = r.string("type").map(ProductKind.init(rawValue:))
        productID = r.string("productID")
        referenceName = r.string("referenceName")
        internalID = r.string("internalID")
        displayPrice = r.string("displayPrice")
        familyShareable = r.bool("familyShareable")
        localizations = r.objects("localizations", Localization.init(object:))
        subscriptionGroupID = r.string("subscriptionGroupID")
        groupNumber = r.int("groupNumber")
        recurringSubscriptionPeriod = r.string("recurringSubscriptionPeriod")
        introductoryOffer = r.object("introductoryOffer", Offer.init(object:))
        adHocOffers = r.objects("adHocOffers", Offer.init(object:))
        codeOffers = r.objects("codeOffers", Offer.init(object:))
        winbackOffers = r.rawArray("winbackOffers")
        extra = r.remaining
    }

    public var json: JSONValue {
        var b = ObjectBuilder(extra: extra)
        b.set("type", type?.rawValue)
        b.set("productID", productID)
        b.set("referenceName", referenceName)
        b.set("internalID", internalID)
        b.set("displayPrice", displayPrice)
        b.set("familyShareable", familyShareable)
        b.set("localizations", localizations) { $0.json }
        b.set("subscriptionGroupID", subscriptionGroupID)
        b.set("groupNumber", groupNumber)
        b.set("recurringSubscriptionPeriod", recurringSubscriptionPeriod)
        b.set("introductoryOffer", introductoryOffer?.json)
        b.set("adHocOffers", adHocOffers) { $0.json }
        b.set("codeOffers", codeOffers) { $0.json }
        b.set("winbackOffers", raw: winbackOffers)
        return b.json
    }
}

extension Localization {
    public init(object: [String: JSONValue]) {
        var r = ObjectReader(object)
        locale = r.string("locale")
        displayName = r.string("displayName")
        description = r.string("description")
        extra = r.remaining
    }

    public var json: JSONValue {
        var b = ObjectBuilder(extra: extra)
        b.set("locale", locale)
        b.set("displayName", displayName)
        b.set("description", description)
        return b.json
    }
}

extension SubscriptionGroup {
    public init(object: [String: JSONValue]) {
        var r = ObjectReader(object)
        id = r.string("id")
        name = r.string("name")
        localizations = r.objects("localizations", Localization.init(object:))
        subscriptions = r.objects("subscriptions", ConfiguredProduct.init(object:))
        extra = r.remaining
    }

    public var json: JSONValue {
        var b = ObjectBuilder(extra: extra)
        b.set("id", id)
        b.set("name", name)
        b.set("localizations", localizations) { $0.json }
        b.set("subscriptions", subscriptions) { $0.json }
        return b.json
    }
}

extension Offer {
    public init(object: [String: JSONValue]) {
        var r = ObjectReader(object)
        internalID = r.string("internalID")
        offerID = r.string("offerID")
        referenceName = r.string("referenceName")
        paymentMode = r.string("paymentMode").map(PaymentMode.init(rawValue:))
        subscriptionPeriod = r.string("subscriptionPeriod")
        numberOfPeriods = r.int("numberOfPeriods")
        displayPrice = r.string("displayPrice")
        eligibility = r.strings("eligibility")
        isStackable = r.bool("isStackable")
        extra = r.remaining
    }

    public var json: JSONValue {
        var b = ObjectBuilder(extra: extra)
        b.set("internalID", internalID)
        b.set("offerID", offerID)
        b.set("referenceName", referenceName)
        b.set("paymentMode", paymentMode?.rawValue)
        b.set("subscriptionPeriod", subscriptionPeriod)
        b.set("numberOfPeriods", numberOfPeriods)
        b.set("displayPrice", displayPrice)
        b.set("eligibility", eligibility)
        b.set("isStackable", isStackable)
        return b.json
    }
}

extension Settings {
    public init(object: [String: JSONValue]) {
        var r = ObjectReader(object)
        storefront = r.string("_storefront")
        locale = r.string("_locale")
        timeRate = r.int("_timeRate")
        askToBuyEnabled = r.bool("_askToBuyEnabled")
        billingIssuesEnabled = r.bool("_billingIssuesEnabled")
        renewalBillingIssuesEnabled = r.bool("_renewalBillingIssuesEnabled")
        billingGracePeriodEnabled = r.bool("_billingGracePeriodEnabled")
        disableDialogs = r.bool("_disableDialogs")
        failTransactionsEnabled = r.bool("_failTransactionsEnabled")
        storeKitErrors = r.rawArray("_storeKitErrors")
        extra = r.remaining
    }

    public var json: JSONValue {
        var b = ObjectBuilder(extra: extra)
        b.set("_storefront", storefront)
        b.set("_locale", locale)
        b.set("_timeRate", timeRate)
        b.set("_askToBuyEnabled", askToBuyEnabled)
        b.set("_billingIssuesEnabled", billingIssuesEnabled)
        b.set("_renewalBillingIssuesEnabled", renewalBillingIssuesEnabled)
        b.set("_billingGracePeriodEnabled", billingGracePeriodEnabled)
        b.set("_disableDialogs", disableDialogs)
        b.set("_failTransactionsEnabled", failTransactionsEnabled)
        b.set("_storeKitErrors", raw: storeKitErrors)
        return b.json
    }
}

extension AppPolicies {
    public init(object: [String: JSONValue]) {
        var r = ObjectReader(object)
        eula = r.string("eula")
        policies = r.objects("policies", Policy.init(object:))
        extra = r.remaining
    }

    public var json: JSONValue {
        var b = ObjectBuilder(extra: extra)
        b.set("eula", eula)
        b.set("policies", policies) { $0.json }
        return b.json
    }
}

extension Policy {
    public init(object: [String: JSONValue]) {
        var r = ObjectReader(object)
        locale = r.string("locale")
        policyText = r.string("policyText")
        policyURL = r.string("policyURL")
        extra = r.remaining
    }

    public var json: JSONValue {
        var b = ObjectBuilder(extra: extra)
        b.set("locale", locale)
        b.set("policyText", policyText)
        b.set("policyURL", policyURL)
        return b.json
    }
}

// MARK: - File level

/// A configuration file as read from disk: the model plus the one layout
/// detail the model does not carry (whether the file ends with a newline), so
/// that writing back an unmodified file reproduces its bytes.
public struct ConfigurationDocument: Hashable, Sendable {
    public var configuration: StoreConfiguration
    /// Whether the text ends with a newline after the closing brace.
    public var trailingNewline: Bool

    public init(configuration: StoreConfiguration, trailingNewline: Bool = false) {
        self.configuration = configuration
        self.trailingNewline = trailingNewline
    }

    public init(data: Data) throws {
        configuration = try StoreConfiguration(data: data)
        trailingNewline = data.last == 0x0A
    }

    public init(contentsOf url: URL) throws { try self.init(data: Data(contentsOf: url)) }

    /// The file's bytes in the canonical form.
    public func data() -> Data { configuration.data(writer: JSONWriter(trailingNewline: trailingNewline)) }

    public func write(to url: URL) throws { try data().write(to: url, options: .atomic) }
}
