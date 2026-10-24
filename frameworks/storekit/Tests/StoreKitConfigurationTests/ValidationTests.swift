// Validation rules (plan.md R2: ids unique, group levels, periods, offers)
// over the value forms of configuration-file.md §2–§7.
import Foundation
import Testing
@testable import StoreKitConfiguration

@Suite("Validation (configuration-file.md §2–§7)")
struct ValidationTests {
    let catalog: StoreConfiguration

    init() throws { catalog = try StoreConfiguration(data: fixtureData("Catalog.storekit")) }

    func rules(_ c: StoreConfiguration) -> [String] { c.validate().map(\.rule) }

    @Test("Our catalog and settings files are valid without warnings")
    func valid() throws {
        #expect(catalog.validate() == [])
        let settings = try StoreConfiguration(data: fixtureData("CatalogSettings.storekit"))
        #expect(settings.validate() == [])
        #expect(catalog.isValid)
    }

    @Test("§2 identifier: 8 uppercase hex digits")
    func identifier() {
        var c = catalog
        c.identifier = "5c0de0a1"
        let issues = c.validate()
        #expect(issues == [ValidationIssue(.error, "identifier.format", "identifier",
                                           "The configuration identifier \"5c0de0a1\" is not 8 uppercase hexadecimal digits.")])
        c.identifier = nil
        #expect(rules(c) == ["identifier.missing"])
    }

    @Test("§3 product ids unique across the whole file")
    func duplicateProductID() {
        var c = catalog
        c.subscriptionGroups![1].subscriptions![0].productID = "dev.ycode.skprobe.pro"
        let issues = c.validate()
        #expect(issues.count == 1)
        #expect(issues[0].rule == "product.id.duplicate")
        #expect(issues[0].path == "subscriptionGroups[1].subscriptions[0].productID")
        #expect(issues[0].message == "The product identifier \"dev.ycode.skprobe.pro\" is already used by products[1].")
    }

    @Test("§3, §5.1 internal ids: digits, unique across products and offers")
    func internalIDs() {
        var c = catalog
        c.products![0].internalID = "10000000A"
        c.subscriptionGroups![0].subscriptions![0].introductoryOffer!.internalID = "100000002"
        #expect(rules(c) == ["internalID.format", "internalID.duplicate"])
    }

    @Test("§3 type must fit the list it is in")
    func types() {
        var c = catalog
        c.products![0].type = .recurringSubscription
        c.nonRenewingSubscriptions![0].type = .consumable
        let issues = c.validate()
        #expect(issues.map(\.rule) == ["product.type", "product.type"])
        #expect(issues[0].message == "The product type \"RecurringSubscription\" is not allowed here; expected \"Consumable\" or \"NonConsumable\".")
    }

    @Test("§3 prices are decimals with a period")
    func prices() {
        var c = catalog
        c.products![0].displayPrice = "0,99"
        c.products![1].displayPrice = nil
        c.nonRenewingSubscriptions![0].displayPrice = "-1"
        #expect(rules(c) == ["price.format", "price.missing", "price.format"])
        #expect(isDecimalPrice("0") && isDecimalPrice("29.99") && !isDecimalPrice(".5") && !isDecimalPrice("1."))
    }

    @Test("§3 localizations: a locale, once per item")
    func localizations() {
        var c = catalog
        c.products![0].localizations![1].locale = "en-US"
        c.products![1].localizations![0].locale = nil
        c.products![1].localizations![0].displayName = ""
        #expect(rules(c) == ["localization.duplicate", "localization.locale.missing"])
    }

    @Test("§4 group ids: digits, unique; subscriptions name their own group")
    func groups() {
        var c = catalog
        c.subscriptionGroups![1].id = "200000001"
        #expect(rules(c) == ["group.id.duplicate", "subscription.groupID.mismatch"])
        c = catalog
        c.subscriptionGroups![0].id = "plus"
        #expect(rules(c).filter { $0 == "group.id.format" }.count == 1)
    }

    @Test("§5 levels: ≥ 1 and without gaps")
    func levels() {
        var c = catalog
        c.subscriptionGroups![0].subscriptions![2].groupNumber = 3
        let issues = c.validate()
        #expect(issues == [ValidationIssue(.warning, "group.levels.gap", "subscriptionGroups[0].subscriptions",
                                           "The subscription levels of the group skip level 2.")])
        c.subscriptionGroups![0].subscriptions![2].groupNumber = 0
        #expect(rules(c) == ["subscription.level"])
        c.subscriptionGroups![0].subscriptions![2].groupNumber = nil
        #expect(rules(c) == ["subscription.level.missing"])
    }

    @Test("§5 periods: ISO 8601; unusual durations warn")
    func periods() {
        var c = catalog
        c.subscriptionGroups![0].subscriptions![0].recurringSubscriptionPeriod = "1 month"
        c.subscriptionGroups![0].subscriptions![1].recurringSubscriptionPeriod = "P5M"
        #expect(rules(c) == ["subscription.period", "subscription.period.unusual"])
        #expect(SubscriptionDuration(iso8601: "P1W") == SubscriptionDuration(value: 1, unit: .week))
        #expect(SubscriptionDuration(iso8601: "P3D")?.unit == .day)
        #expect(SubscriptionDuration(iso8601: "P1Y2M") == nil)
        #expect(SubscriptionDuration(iso8601: "P0M") == nil)
        #expect(SubscriptionDuration(iso8601: "PT1H") == nil)
        #expect(SubscriptionDuration(value: 1, unit: .month).times(3).iso8601 == "P3M")
    }

    @Test("§5.1 offers: payment mode, period, count, price; promotional ids; code eligibility")
    func offers() {
        var c = catalog
        var monthly = c.subscriptionGroups![0].subscriptions![0]
        monthly.introductoryOffer!.paymentMode = PaymentMode(rawValue: "cheap")
        monthly.introductoryOffer!.numberOfPeriods = 0
        monthly.adHocOffers![0].offerID = nil
        monthly.adHocOffers![0].displayPrice = nil
        monthly.codeOffers![0].eligibility = ["new", "lapsed"]
        c.subscriptionGroups![0].subscriptions![0] = monthly
        #expect(rules(c) == ["offer.paymentMode", "offer.periods", "price.missing", "offer.offerID.missing", "offer.code.eligibility"])
        c = catalog
        c.subscriptionGroups![0].subscriptions![0].adHocOffers!.append(c.subscriptionGroups![0].subscriptions![0].adHocOffers![0])
        c.subscriptionGroups![0].subscriptions![0].adHocOffers![1].internalID = "100000099"
        #expect(rules(c) == ["offer.offerID.duplicate"])
    }

    @Test("§6 settings: storefront, time rate, grace without retry")
    func settings() {
        var c = catalog
        c.settings!.storefront = "US"
        c.settings!.timeRate = 14
        c.settings!.billingGracePeriodEnabled = true
        #expect(rules(c) == ["settings.storefront", "settings.timeRate", "settings.gracePeriod"])
        c = catalog
        c.settings!.timeRate = 3
        #expect(rules(c) == ["settings.timeRate.deprecated"])
        #expect(validTimeRateValues.count == 18)
    }

    @Test("Wrong-typed known keys are reported (nulls are not)")
    func wrongTypes() throws {
        let c = try StoreConfiguration(data: fixtureData("CatalogUnknownKeys.storekit"))
        let issues = c.validate()
        #expect(issues.map(\.rule) == ["value.type"])
        #expect(issues[0].path == "products[1].displayPrice")
        #expect(issues[0].message == "The value of \"displayPrice\" has the wrong type; expected a string.")
    }
}
