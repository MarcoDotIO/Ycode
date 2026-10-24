// Validation of a configuration (plan.md R2: ids unique, group levels,
// periods, offers). The rules and messages are Ycode's own; the spec fixes
// the value forms they check (configuration-file.md §2–§7).
import Foundation

/// One finding of `StoreConfiguration.validate()`.
public struct ValidationIssue: Hashable, Sendable, CustomStringConvertible {
    public enum Severity: String, Hashable, Sendable {
        /// The store cannot use the item as written.
        case error
        /// Loads, but probably not what the author meant.
        case warning
    }

    public let severity: Severity
    /// A stable rule identifier (`product.id.duplicate`, …).
    public let rule: String
    /// A JSON path to the offending value (`subscriptionGroups[0].subscriptions[1].groupNumber`).
    public let path: String
    public let message: String

    public init(_ severity: Severity, _ rule: String, _ path: String, _ message: String) {
        self.severity = severity
        self.rule = rule
        self.path = path
        self.message = message
    }

    public var description: String { "\(severity.rawValue): \(path): \(message) [\(rule)]" }
}

/// The raw time-rate values of `SKTestSession.TimeRate` (testing-session.md §2.1).
public let validTimeRateValues: Set<Int> = [0, 1, 2, 3, 4, 5, 6, 10, 11, 12, 13, 15, 1000, 1001, 1002, 1003, 1004, 1005]

/// Whether `text` is a non-negative decimal with an optional `.` fraction (`0.99`, `29.99`, `0`).
public func isDecimalPrice(_ text: String) -> Bool {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count <= 2, let whole = parts.first, !whole.isEmpty else { return false }
    let isDigits: (Substring) -> Bool = { $0.allSatisfy { $0.isASCII && $0.isNumber } }
    guard isDigits(whole) else { return false }
    if parts.count == 2 { return !parts[1].isEmpty && isDigits(parts[1]) }
    return true
}

func isDigits(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber } }

extension StoreConfiguration {
    /// Checks the configuration and returns every finding, errors first in file order.
    public func validate() -> [ValidationIssue] {
        var v = Validator()
        v.run(self)
        return v.issues.filter { $0.severity == .error } + v.issues.filter { $0.severity == .warning }
    }

    /// Whether `validate()` finds no error (warnings allowed).
    public var isValid: Bool { !validate().contains { $0.severity == .error } }
}

struct Validator {
    var issues: [ValidationIssue] = []
    var productIDs: [String: String] = [:]  // product id -> first path
    var internalIDs: [String: String] = [:]  // internal id -> first path

    mutating func error(_ rule: String, _ path: String, _ message: String) { issues.append(.init(.error, rule, path, message)) }
    mutating func warning(_ rule: String, _ path: String, _ message: String) { issues.append(.init(.warning, rule, path, message)) }

    /// Known keys left in `extra` had a value of the wrong type.
    mutating func checkTypes(_ extra: [String: JSONValue], _ expected: [String: String], at path: String) {
        for key in JSONWriter.sortedKeys(extra.keys) where extra[key] != .null {
            // An explicit null stands for "absent" and is kept as written.
            if let want = expected[key] {
                error("value.type", join(path, key), "The value of \"\(key)\" has the wrong type; expected \(want).")
            }
        }
    }

    func join(_ path: String, _ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }

    mutating func run(_ c: StoreConfiguration) {
        checkTypes(c.extra, [
            "identifier": "a string", "version": "an object", "products": "an array of objects",
            "nonRenewingSubscriptions": "an array of objects", "subscriptionGroups": "an array of objects",
            "settings": "an object", "appPolicies": "an object", "appName": "a string",
        ], at: "")
        if let id = c.identifier {
            if id.count != 8 || !id.allSatisfy({ $0.isHexDigit && !$0.isLowercase }) {
                error("identifier.format", "identifier", "The configuration identifier \"\(id)\" is not 8 uppercase hexadecimal digits.")
            }
        } else if c.extra["identifier"] == nil {
            warning("identifier.missing", "identifier", "The configuration has no identifier.")
        }
        if let version = c.version {
            checkTypes(version.extra, ["major": "an integer", "minor": "an integer"], at: "version")
            if version.major == nil { error("version.major", "version.major", "The format version has no major number.") }
        } else if c.extra["version"] == nil {
            warning("version.missing", "version", "The configuration has no format version.")
        }

        for (i, p) in (c.products ?? []).enumerated() {
            product(p, at: "products[\(i)]", allowed: [.consumable, .nonConsumable], subscriptionGroup: nil)
        }
        for (i, p) in (c.nonRenewingSubscriptions ?? []).enumerated() {
            product(p, at: "nonRenewingSubscriptions[\(i)]", allowed: [.nonRenewingSubscription], subscriptionGroup: nil)
        }
        var groupIDs: [String: String] = [:]
        var groupNames: [String: String] = [:]
        for (g, group) in (c.subscriptionGroups ?? []).enumerated() {
            let path = "subscriptionGroups[\(g)]"
            checkTypes(group.extra, [
                "id": "a string", "name": "a string", "localizations": "an array of objects",
                "subscriptions": "an array of objects",
            ], at: path)
            if let id = group.id {
                if !isDigits(id) {
                    error("group.id.format", join(path, "id"), "The subscription group identifier \"\(id)\" is not a string of digits.")
                } else if let first = groupIDs[id] {
                    error("group.id.duplicate", join(path, "id"), "The subscription group identifier \"\(id)\" is already used by \(first).")
                } else {
                    groupIDs[id] = path
                }
            } else {
                error("group.id.missing", join(path, "id"), "The subscription group has no identifier.")
            }
            if let name = group.name, !name.isEmpty {
                if let first = groupNames[name] {
                    warning("group.name.duplicate", join(path, "name"), "Another subscription group (\(first)) has the name \"\(name)\".")
                } else {
                    groupNames[name] = path
                }
            } else {
                warning("group.name.missing", join(path, "name"), "The subscription group has no name.")
            }
            localizations(group.localizations, at: join(path, "localizations"))
            let subs = group.subscriptions ?? []
            if subs.isEmpty { warning("group.empty", join(path, "subscriptions"), "The subscription group has no subscriptions.") }
            for (i, s) in subs.enumerated() {
                product(s, at: "\(path).subscriptions[\(i)]", allowed: [.recurringSubscription], subscriptionGroup: group)
            }
            // Levels: each subscription has a level >= 1; the levels used should be 1…n without gaps.
            let levels = Set(subs.compactMap(\.groupNumber).filter { $0 >= 1 })
            if let maxLevel = levels.max(), levels.count != maxLevel {
                let missing = (1...maxLevel).filter { !levels.contains($0) }.map(String.init).joined(separator: ", ")
                warning("group.levels.gap", join(path, "subscriptions"), "The subscription levels of the group skip level \(missing).")
            }
        }
        if let s = c.settings { settings(s) }
        if let a = c.appPolicies {
            checkTypes(a.extra, ["eula": "a string", "policies": "an array of objects"], at: "appPolicies")
            for (i, p) in (a.policies ?? []).enumerated() {
                let path = "appPolicies.policies[\(i)]"
                checkTypes(p.extra, ["locale": "a string", "policyText": "a string", "policyURL": "a string"], at: path)
                if (p.locale ?? "").isEmpty { error("policy.locale.missing", join(path, "locale"), "The policy has no locale.") }
            }
        }
    }

    mutating func localizations(_ list: [Localization]?, at path: String) {
        var seen: Set<String> = []
        for (i, l) in (list ?? []).enumerated() {
            let p = "\(path)[\(i)]"
            checkTypes(l.extra, ["locale": "a string", "displayName": "a string", "description": "a string"], at: p)
            guard let locale = l.locale, !locale.isEmpty else {
                error("localization.locale.missing", join(p, "locale"), "The localization has no locale.")
                continue
            }
            let key = locale.replacingOccurrences(of: "-", with: "_")
            if !seen.insert(key).inserted {
                error("localization.duplicate", join(p, "locale"), "There is more than one localization for the locale \"\(locale)\".")
            }
            if (l.displayName ?? "").isEmpty {
                warning("localization.displayName.missing", join(p, "displayName"), "The localization for \"\(locale)\" has no display name.")
            }
        }
    }

    mutating func internalID(_ id: String?, at path: String, what: String) {
        guard let id else {
            error("internalID.missing", path, "The \(what) has no internal identifier.")
            return
        }
        if !isDigits(id) {
            error("internalID.format", path, "The internal identifier \"\(id)\" is not a string of digits.")
        } else if let first = internalIDs[id] {
            error("internalID.duplicate", path, "The internal identifier \"\(id)\" is already used by \(first).")
        } else {
            internalIDs[id] = path
        }
    }

    mutating func price(_ text: String?, at path: String, required: Bool, what: String, present: Bool = false) {
        guard let text else {
            if required && !present { error("price.missing", path, "The \(what) has no price.") }
            return
        }
        if !isDecimalPrice(text) {
            error("price.format", path, "The price \"\(text)\" is not a decimal number with a period as the separator.")
        }
    }

    mutating func product(_ p: ConfiguredProduct, at path: String, allowed: [ProductKind], subscriptionGroup: SubscriptionGroup?) {
        checkTypes(p.extra, [
            "type": "a string", "productID": "a string", "referenceName": "a string", "internalID": "a string",
            "displayPrice": "a string", "familyShareable": "a Boolean", "localizations": "an array of objects",
            "subscriptionGroupID": "a string", "groupNumber": "an integer", "recurringSubscriptionPeriod": "a string",
            "introductoryOffer": "an object", "adHocOffers": "an array of objects", "codeOffers": "an array of objects",
            "winbackOffers": "an array",
        ], at: path)
        if let type = p.type {
            if !allowed.contains(type) {
                let list = allowed.map { "\"\($0.rawValue)\"" }.joined(separator: " or ")
                error("product.type", join(path, "type"), "The product type \"\(type.rawValue)\" is not allowed here; expected \(list).")
            }
        } else {
            error("product.type.missing", join(path, "type"), "The product has no type.")
        }
        if let id = p.productID, !id.isEmpty {
            if let first = productIDs[id] {
                error("product.id.duplicate", join(path, "productID"), "The product identifier \"\(id)\" is already used by \(first).")
            } else {
                productIDs[id] = path
            }
        } else {
            error("product.id.missing", join(path, "productID"), "The product has no product identifier.")
        }
        if (p.referenceName ?? "").isEmpty {
            warning("product.referenceName.missing", join(path, "referenceName"), "The product has no reference name.")
        }
        internalID(p.internalID, at: join(path, "internalID"), what: "product")
        price(p.displayPrice, at: join(path, "displayPrice"), required: true, what: "product", present: p.extra["displayPrice"] != nil)
        localizations(p.localizations, at: join(path, "localizations"))

        let subscriptionKeys = [
            p.subscriptionGroupID != nil, p.groupNumber != nil, p.recurringSubscriptionPeriod != nil,
            p.introductoryOffer != nil, p.adHocOffers != nil, p.codeOffers != nil, p.winbackOffers != nil,
        ]
        guard let group = subscriptionGroup else {
            if subscriptionKeys.contains(true) {
                warning("product.subscriptionKeys", path, "Only auto-renewable subscriptions use the subscription keys; they are ignored here.")
            }
            return
        }
        if let gid = p.subscriptionGroupID {
            if let id = group.id, gid != id {
                error("subscription.groupID.mismatch", join(path, "subscriptionGroupID"),
                      "The subscription names the group \"\(gid)\" but is listed in the group \"\(id)\".")
            }
        } else {
            warning("subscription.groupID.missing", join(path, "subscriptionGroupID"), "The subscription does not name its group.")
        }
        if let level = p.groupNumber {
            if level < 1 { error("subscription.level", join(path, "groupNumber"), "The subscription level \(level) is not 1 or higher.") }
        } else {
            error("subscription.level.missing", join(path, "groupNumber"), "The subscription has no level in its group.")
        }
        if let period = p.recurringSubscriptionPeriod {
            if SubscriptionDuration(iso8601: period) == nil {
                error("subscription.period", join(path, "recurringSubscriptionPeriod"),
                      "The renewal period \"\(period)\" is not an ISO 8601 duration such as P1W, P1M or P1Y.")
            } else if !SubscriptionDuration.editorSubscriptionPeriods.contains(period) {
                warning("subscription.period.unusual", join(path, "recurringSubscriptionPeriod"),
                        "The renewal period \"\(period)\" is not one of the standard durations.")
            }
        } else {
            error("subscription.period.missing", join(path, "recurringSubscriptionPeriod"), "The subscription has no renewal period.")
        }
        if let intro = p.introductoryOffer {
            offer(intro, at: join(path, "introductoryOffer"), kind: .introductory)
        }
        var offerIDs: Set<String> = []
        for (i, o) in (p.adHocOffers ?? []).enumerated() {
            let op = "\(path).adHocOffers[\(i)]"
            offer(o, at: op, kind: .promotional)
            if let id = o.offerID, !id.isEmpty, !offerIDs.insert(id).inserted {
                error("offer.offerID.duplicate", join(op, "offerID"), "The promotional offer identifier \"\(id)\" is used twice in this subscription.")
            }
        }
        var codes: Set<String> = []
        for (i, o) in (p.codeOffers ?? []).enumerated() {
            let op = "\(path).codeOffers[\(i)]"
            offer(o, at: op, kind: .code)
            if let code = o.referenceName, !code.isEmpty, !codes.insert(code).inserted {
                error("offer.code.duplicate", join(op, "referenceName"), "The offer code \"\(code)\" is used twice in this subscription.")
            }
        }
    }

    enum OfferKind { case introductory, promotional, code }

    mutating func offer(_ o: Offer, at path: String, kind: OfferKind) {
        checkTypes(o.extra, [
            "internalID": "a string", "offerID": "a string", "referenceName": "a string", "paymentMode": "a string",
            "subscriptionPeriod": "a string", "numberOfPeriods": "an integer", "displayPrice": "a string",
            "eligibility": "an array of strings", "isStackable": "a Boolean",
        ], at: path)
        internalID(o.internalID, at: join(path, "internalID"), what: "offer")
        let mode = o.paymentMode
        if let mode {
            if ![PaymentMode.free, .payAsYouGo, .payUpFront].contains(mode) {
                error("offer.paymentMode", join(path, "paymentMode"),
                      "The payment mode \"\(mode.rawValue)\" is not \"free\", \"payAsYouGo\" or \"payUpFront\".")
            }
        } else {
            error("offer.paymentMode.missing", join(path, "paymentMode"), "The offer has no payment mode.")
        }
        if let period = o.subscriptionPeriod {
            if SubscriptionDuration(iso8601: period) == nil {
                error("offer.period", join(path, "subscriptionPeriod"), "The offer period \"\(period)\" is not an ISO 8601 duration such as P1W or P1M.")
            }
        } else {
            error("offer.period.missing", join(path, "subscriptionPeriod"), "The offer has no period.")
        }
        if let n = o.numberOfPeriods {
            if n < 1 {
                error("offer.periods", join(path, "numberOfPeriods"), "The offer must last at least one period.")
            } else if mode == .payUpFront && n != 1 {
                warning("offer.periods.payUpFront", join(path, "numberOfPeriods"),
                        "A pay-up-front offer normally has one period holding the whole duration.")
            }
        } else {
            error("offer.periods.missing", join(path, "numberOfPeriods"), "The offer has no number of periods.")
        }
        price(o.displayPrice, at: join(path, "displayPrice"), required: mode == .payAsYouGo || mode == .payUpFront, what: "offer",
              present: o.extra["displayPrice"] != nil)
        switch kind {
        case .introductory:
            if o.offerID != nil {
                warning("offer.intro.offerID", join(path, "offerID"), "An introductory offer has no offer identifier; this one is ignored.")
            }
        case .promotional:
            if (o.offerID ?? "").isEmpty {
                error("offer.offerID.missing", join(path, "offerID"), "The promotional offer has no offer identifier.")
            }
        case .code:
            if (o.referenceName ?? "").isEmpty {
                error("offer.code.missing", join(path, "referenceName"), "The offer code has no code (reference name).")
            }
            if let e = o.eligibility {
                if e.isEmpty { error("offer.code.eligibility", join(path, "eligibility"), "The offer code is not available to any customer.") }
                for value in e where !["new", "existing", "expired"].contains(value) {
                    error("offer.code.eligibility", join(path, "eligibility"),
                          "The eligibility \"\(value)\" is not \"new\", \"existing\" or \"expired\".")
                }
            } else {
                error("offer.code.eligibility.missing", join(path, "eligibility"), "The offer code does not say who may redeem it.")
            }
        }
    }

    mutating func settings(_ s: Settings) {
        checkTypes(s.extra, [
            "_storefront": "a string", "_locale": "a string", "_timeRate": "an integer", "_askToBuyEnabled": "a Boolean",
            "_billingIssuesEnabled": "a Boolean", "_renewalBillingIssuesEnabled": "a Boolean",
            "_billingGracePeriodEnabled": "a Boolean", "_disableDialogs": "a Boolean",
            "_failTransactionsEnabled": "a Boolean", "_storeKitErrors": "an array",
        ], at: "settings")
        if let sf = s.storefront, sf.count != 3 || !sf.allSatisfy({ $0.isASCII && $0.isUppercase }) {
            error("settings.storefront", "settings._storefront", "The storefront \"\(sf)\" is not a three-letter country code such as USA.")
        }
        if let locale = s.locale, locale.isEmpty {
            error("settings.locale", "settings._locale", "The default locale is empty.")
        }
        if let rate = s.timeRate, !validTimeRateValues.contains(rate) {
            error("settings.timeRate", "settings._timeRate", "The time rate \(rate) is not a known time rate.")
        } else if let rate = s.timeRate, (1...6).contains(rate) {
            warning("settings.timeRate.deprecated", "settings._timeRate", "The time rate \(rate) is deprecated.")
        }
        if s.billingGracePeriodEnabled == true && s.renewalBillingIssuesEnabled != true {
            warning("settings.gracePeriod", "settings._billingGracePeriodEnabled",
                    "The billing grace period has no effect unless renewal billing issues are enabled.")
        }
    }
}

// MARK: - Template

extension StoreConfiguration {
    /// A new, empty local configuration (ide.md §6 item 2): default settings,
    /// no products, empty policies, format version 4.0 (configuration-file.md
    /// §10 q2), and a fresh identifier.
    public static func template(identifier: String = StoreConfiguration.newIdentifier()) -> StoreConfiguration {
        StoreConfiguration(
            identifier: identifier,
            version: Version(major: 4, minor: 0),
            products: [],
            nonRenewingSubscriptions: [],
            subscriptionGroups: [],
            settings: .defaults,
            appPolicies: AppPolicies(eula: "", policies: []))
    }

    /// A random identifier of 8 uppercase hexadecimal digits.
    public static func newIdentifier() -> String {
        var g = SystemRandomNumberGenerator()
        return newIdentifier(using: &g)
    }

    public static func newIdentifier<G: RandomNumberGenerator>(using generator: inout G) -> String {
        let value = UInt32.random(in: .min ... .max, using: &generator)
        let hex = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: 8 - hex.count) + hex
    }
}
