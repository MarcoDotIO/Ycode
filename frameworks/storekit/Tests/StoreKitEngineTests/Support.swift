// Test support: our catalog of plan.md §3.1 as a configuration, and helpers.
import Foundation
import StoreKitConfiguration
@testable import StoreKitEngine

enum ID {
    static let coins = "dev.ycode.skprobe.coins100"
    static let pro = "dev.ycode.skprobe.pro"
    static let season = "dev.ycode.skprobe.season"
    static let monthly = "dev.ycode.skprobe.plus.monthly"
    static let yearly = "dev.ycode.skprobe.plus.yearly"
    static let lite = "dev.ycode.skprobe.plus.lite"
    static let weekly = "dev.ycode.skprobe.extra.weekly"
    static let all = [coins, pro, season, monthly, yearly, lite, weekly]
    static let plus = "200000001"
    static let extra = "200000002"
    static let app = "dev.ycode.skprobe"
}

/// The catalog of plan.md §3.1 (our own data).
func probeConfiguration(settings: Settings = Settings(
    storefront: "USA", locale: "en_US", timeRate: 0, askToBuyEnabled: false, billingIssuesEnabled: false,
    renewalBillingIssuesEnabled: false, billingGracePeriodEnabled: false, disableDialogs: true,
    failTransactionsEnabled: false, storeKitErrors: [])) -> StoreConfiguration
{
    func loc(_ l: String, _ n: String, _ d: String) -> Localization { Localization(locale: l, displayName: n, description: d) }
    func sub(_ id: String, _ name: String, _ internalID: String, _ price: String, group: String, level: Int, period: String,
             family: Bool = false, intro: Offer? = nil, promos: [Offer] = [], codes: [Offer] = []) -> ConfiguredProduct {
        ConfiguredProduct(type: .recurringSubscription, productID: id, referenceName: name, internalID: internalID, displayPrice: price,
                familyShareable: family, localizations: [loc("en_US", name, "\(name) plan.")], subscriptionGroupID: group,
                groupNumber: level, recurringSubscriptionPeriod: period, introductoryOffer: intro, adHocOffers: promos,
                codeOffers: codes, winbackOffers: [])
    }
    return StoreConfiguration(
        identifier: "5C0DE0A1", version: Version(major: 4, minor: 0),
        products: [
            ConfiguredProduct(type: .consumable, productID: ID.coins, referenceName: "100 Probe Coins", internalID: "100000001",
                    displayPrice: "0.99", familyShareable: false,
                    localizations: [loc("en_US", "100 Probe Coins", "A pile of coins."), loc("de", "100 Testmuenzen", "Ein Haufen Muenzen.")]),
            ConfiguredProduct(type: .nonConsumable, productID: ID.pro, referenceName: "Probe Pro", internalID: "100000002",
                    displayPrice: "4.99", familyShareable: true, localizations: [loc("en_US", "Probe Pro", "Everything.")]),
        ],
        nonRenewingSubscriptions: [
            ConfiguredProduct(type: .nonRenewingSubscription, productID: ID.season, referenceName: "Probe Season Pass", internalID: "100000004",
                    displayPrice: "2.99", familyShareable: false, localizations: [loc("en_US", "Probe Season Pass", "One season.")]),
        ],
        subscriptionGroups: [
            SubscriptionGroup(id: ID.plus, name: "Plus", localizations: [loc("en_US", "Ycode Plus", "Plus plans.")], subscriptions: [
                sub(ID.monthly, "Plus Monthly", "100000011", "3.99", group: ID.plus, level: 1, period: "P1M",
                    intro: Offer(internalID: "100000031", paymentMode: .free, subscriptionPeriod: "P1W", numberOfPeriods: 1),
                    promos: [Offer(internalID: "100000032", offerID: "plus.promo3", referenceName: "Promo", paymentMode: .payAsYouGo,
                                   subscriptionPeriod: "P1M", numberOfPeriods: 3, displayPrice: "1.99")],
                    codes: [Offer(internalID: "100000033", referenceName: "CODEFREE", paymentMode: .free, subscriptionPeriod: "P1M",
                                  numberOfPeriods: 1, eligibility: ["new", "existing", "expired"], isStackable: true)]),
                sub(ID.yearly, "Plus Yearly", "100000012", "29.99", group: ID.plus, level: 1, period: "P1Y"),
                sub(ID.lite, "Plus Lite", "100000013", "1.99", group: ID.plus, level: 2, period: "P1M",
                    intro: Offer(internalID: "100000034", paymentMode: .payAsYouGo, subscriptionPeriod: "P1M", numberOfPeriods: 2,
                                 displayPrice: "0.99")),
            ]),
            SubscriptionGroup(id: ID.extra, name: "Extra", localizations: [], subscriptions: [
                sub(ID.weekly, "Extra Weekly", "100000021", "0.49", group: ID.extra, level: 1, period: "P1W", family: true,
                    intro: Offer(internalID: "100000035", paymentMode: .payUpFront, subscriptionPeriod: "P1M", numberOfPeriods: 1,
                                 displayPrice: "0.99")),
            ]),
        ],
        settings: settings,
        appPolicies: AppPolicies(eula: "", policies: []))
}

/// 2026-10-19 12:00:00 UTC (daylight saving time in New York).
let referenceStart = Date(timeIntervalSince1970: 1_792_411_200)

let newYork = TimeZone(identifier: "America/New_York")!

/// A device with a manual clock and an app store with the catalog installed.
func makeStore(rate: TimeRate = .realTime, start: Date = referenceStart, quirks: EngineQuirks = .reference,
               configure: (inout Settings) -> Void = { _ in }) -> (ManualClock, StoreDevice, AppTestStore)
{
    let clock = ManualClock(start)
    let device = StoreDevice(clock: clock, timeZone: newYork, quirks: quirks)
    let store = device.store(for: ID.app)
    var settings = probeConfiguration().settings!
    settings.timeRate = rate.rawValue
    configure(&settings)
    store.installConfiguration(probeConfiguration(settings: settings), appName: "StoreProbe")
    return (clock, device, store)
}

/// Collects store events.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [StoreEvent] = []

    init(_ store: AppTestStore) { store.addObserver { [weak self] e in self?.append(e) } }

    private func append(_ e: StoreEvent) { lock.withLock { items.append(e) } }

    var events: [StoreEvent] { lock.withLock { items } }

    var transactions: [TransactionRecord] {
        events.compactMap { if case .transaction(let t) = $0 { return t } else { return nil } }
    }
}

extension PurchaseOutcome {
    var record: TransactionRecord {
        guard case .success(let r, _) = self else { fatalError("not a success: \(self)") }
        return r
    }
}
