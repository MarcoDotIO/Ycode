// C-ENGINE (plan.md §4) part 1: catalog, products, purchases and lists
// (plan.md §3.1–§3.2; testing-session.md §4, §10; simulator-baseline.md §8 rows E1, E2, P1, U1, U4).
import Foundation
import Testing
import StoreKitConfiguration
@testable import StoreKitEngine

@Suite("No configuration and isolation (simulator-baseline.md §8 E1, E2)")
struct NoConfigurationTests {
    @Test("E1: no configuration → 0 products, AppTransaction noAccount, empty lists")
    func empty() throws {
        let device = StoreDevice(clock: ManualClock(referenceStart), timeZone: newYork)
        let store = device.store(for: ID.app)
        #expect(try store.products(for: ID.all).isEmpty)
        #expect(throws: StoreFailure(.systemError(.noAccount))) { try store.checkAppTransaction() }
        #expect(store.transactionHistory().isEmpty && store.currentEntitlements().isEmpty && store.unfinishedTransactions().isEmpty)
        #expect(throws: StoreFailure(.unknown)) { try store.purchase(productID: ID.coins) }
    }

    @Test("E2: another bundle sees nothing (configuration-file.md §8 item 2)")
    func isolation() throws {
        let (_, device, store) = makeStore()
        #expect(try store.products(for: ID.all).count == 7)
        #expect(try device.store(for: "dev.ycode.skprobe.b").products(for: ID.all).isEmpty)
    }
}

@Suite("Catalog (plan.md §3.1, configuration-file.md §3–§5)")
struct CatalogTests {
    @Test("P1: the 7 products with names, prices, types, family flags, groups, levels, periods, offers")
    func products() throws {
        let (_, _, store) = makeStore()
        let products = try store.products(for: ID.all)
        #expect(products.map(\.id) == ID.all)
        #expect(products.map(\.type) == [.consumable, .nonConsumable, .nonRenewable, .autoRenewable, .autoRenewable, .autoRenewable, .autoRenewable])
        #expect(products.map { $0.displayName(locale: "en_US") } == [
            "100 Probe Coins", "Probe Pro", "Probe Season Pass", "Plus Monthly", "Plus Yearly", "Plus Lite", "Extra Weekly",
        ])
        #expect(products.map(\.priceText) == ["0.99", "4.99", "2.99", "3.99", "29.99", "1.99", "0.49"])
        #expect(products.map(\.priceMilli) == [990, 4990, 2990, 3990, 29990, 1990, 490])
        #expect(products.map(\.isFamilyShareable) == [false, true, false, false, false, false, true])
        #expect(products.map(\.internalID) == ["100000001", "100000002", "100000004", "100000011", "100000012", "100000013", "100000021"])
        let monthly = products[3].subscription!
        #expect(monthly.groupID == "200000001" && monthly.level == 1 && monthly.period.iso8601 == "P1M")
        #expect(monthly.introductoryOffer?.paymentMode == .freeTrial && monthly.introductoryOffer?.period.iso8601 == "P1W")
        #expect(monthly.promotionalOffers.map(\.identifier) == ["plus.promo3"])
        #expect(monthly.promotionalOffers[0].paymentMode == .payAsYouGo && monthly.promotionalOffers[0].periodCount == 3)
        #expect(monthly.promotionalOffers[0].price == Decimal(string: "1.99"))
        #expect(products[4].subscription?.introductoryOffer == nil && products[4].subscription?.period.iso8601 == "P1Y")
        #expect(products[5].subscription?.level == 2)
        #expect(products[5].subscription?.introductoryOffer?.paymentMode == .payAsYouGo)
        #expect(products[5].subscription?.introductoryOffer?.periodCount == 2)
        let weekly = products[6].subscription!
        #expect(weekly.groupID == "200000002" && weekly.period.iso8601 == "P1W")
        #expect(weekly.introductoryOffer?.paymentMode == .payUpFront && weekly.introductoryOffer?.totalDuration.iso8601 == "P1M")
        let catalog = store.catalog!
        #expect(catalog.group(ID.plus)?.displayName(locale: "en_US") == "Ycode Plus")
        #expect(catalog.group(ID.extra)?.displayName(locale: "en_US") == "Extra")
    }

    @Test("P1: unknown ids are left out; an empty request is empty; intro eligibility true for both groups and an unknown one")
    func requests() throws {
        let (_, _, store) = makeStore()
        #expect(try store.products(for: ["dev.ycode.skprobe.bogus"]).isEmpty)
        #expect(try store.products(for: []).isEmpty)
        #expect(try store.products(for: [ID.pro, "nope", ID.coins, ID.pro]).map(\.id) == [ID.pro, ID.coins])
        #expect(store.isEligibleForIntroOffer(groupID: ID.plus))
        #expect(store.isEligibleForIntroOffer(groupID: ID.extra))
        #expect(store.isEligibleForIntroOffer(groupID: "999"))
    }

    @Test("plan.md §3.2 locale de / storefront DEU: German name, reference-name fallback without description, group Plus, EUR")
    func germanLocale() throws {
        let (_, _, store) = makeStore { $0.storefront = "DEU"; $0.locale = "de" }
        let s = store.settings
        #expect(s.storefront == Storefront(countryCode: "DEU", id: "143443", currency: "EUR"))
        #expect(s.priceLocale == "de@currency=EUR")
        let p = try store.products(for: [ID.coins, ID.pro])
        #expect(p[0].displayName(locale: "de") == "100 Testmuenzen")
        #expect(p[1].displayName(locale: "de") == "Probe Pro")
        #expect(p[1].description(locale: "de") == nil)
        #expect(store.catalog!.group(ID.plus)?.displayName(locale: "de") == "Plus")
        // Prices are never converted between storefronts.
        #expect(p[0].priceText == "0.99")
    }

    @Test("configuration-file.md §6: storefront USA → 143441 / USD, price locale en_US@currency=USD")
    func storefront() {
        let (_, _, store) = makeStore()
        #expect(store.settings.storefront == Storefront(countryCode: "USA", id: "143441", currency: "USD"))
        #expect(store.settings.priceLocale == "en_US@currency=USD")
        #expect(Storefront.named("ZZZ") == Storefront(countryCode: "ZZZ", id: "", currency: "XXX"))
    }
}

@Suite("Purchases (testing-session.md §4, §10; simulator-baseline.md §8 U1, U4)")
struct PurchaseTests {
    @Test("U1: the buy sequence: redelivery of unfinished consumables, non-consumables once, lists")
    func buySequence() throws {
        let (_, _, store) = makeStore()
        let n = try store.purchase(productID: ID.coins).record
        #expect(n.id == 0)
        store.finish(transactionID: n.id)
        let n1 = try store.purchase(productID: ID.coins).record
        #expect(n1.id == 1)
        let n2 = try store.purchase(productID: ID.pro).record
        #expect(n2.id == 2)
        let again = try store.purchase(productID: ID.pro)
        #expect(again == .success(n2, isRedelivery: true))
        let n3 = try store.purchase(productID: ID.season).record
        #expect(n3.id == 3 && n3.expiresDate == nil)
        // Unfinished coins: the same transaction again, whatever the quantity.
        let q3 = try store.purchase(productID: ID.coins, options: PurchaseOptions(quantity: 3))
        #expect(q3 == .success(n1, isRedelivery: true))
        #expect(q3.record.quantity == 1)
        store.finish(transactionID: n1.id)
        let token = UUID(uuidString: "6A1D3C2E-0F00-4B6B-9C1D-5E0D7C4C9A11")!
        let n4 = try store.purchase(productID: ID.coins, options: PurchaseOptions(appAccountToken: token)).record
        #expect(n4.id == 4 && n4.appAccountToken == token)
        #expect(store.transactionHistory().map(\.id) == [4, 3, 2])
        #expect(store.currentEntitlements().map(\.id) == [3, 2])
        #expect(store.unfinishedTransactions().map(\.id) == [4, 3, 2])
        store.finish(transactionID: 2)
        store.finish(transactionID: 3)
        #expect(store.unfinishedTransactions().map(\.id) == [4])
        #expect(store.allTransactions().map(\.id) == [0, 1, 2, 3, 4])
        #expect(store.latestTransaction(for: ID.coins)?.id == 4)
    }

    @Test("§10: transaction fields: original id, storefront, currency, milli-unit prices, environment values")
    func fields() throws {
        let (_, _, store) = makeStore()
        let coins = try store.purchase(productID: ID.coins).record
        #expect(coins.originalID == coins.id && coins.webOrderLineItemID == coins.id)
        #expect(coins.storefront == "USA" && coins.storefrontID == "143441" && coins.currency == "USD")
        #expect(coins.reason == .purchase && coins.state == .purchased && coins.quantity == 1)
        #expect(coins.purchaseDate == referenceStart.storeMilliseconds && coins.originalPurchaseDate == coins.purchaseDate)
        #expect([try store.purchase(productID: ID.coins).record.priceMilli,
                 try store.purchase(productID: ID.pro).record.priceMilli,
                 try store.purchase(productID: ID.season).record.priceMilli] == [990, 4990, 2990])
    }

    @Test("plan.md §3.2 price fields: trial 0, pay-up-front intro 990, base renewal 3990")
    func offerPrices() throws {
        let (clock, _, store) = makeStore(rate: .oneRenewalEveryTenSeconds)
        let monthly = try store.purchase(productID: ID.monthly).record
        #expect(monthly.priceMilli == 0 && monthly.offer?.type == .introductory && monthly.offer?.paymentMode == .freeTrial)
        #expect(monthly.offer?.period.iso8601 == "P1W")
        let weekly = try store.purchase(productID: ID.weekly).record
        #expect(weekly.priceMilli == 990 && weekly.offer?.paymentMode == .payUpFront && weekly.offer?.period.iso8601 == "P1M")
        clock.advance(by: 10)
        #expect(store.transactionHistory().first { $0.productID == ID.monthly && $0.reason == .renewal }?.priceMilli == 3990)
    }

    @Test("§10 item 1: ids start at 0 per app, are never reused, survive clearTransactions; another app starts at 0")
    func counter() throws {
        let (_, device, store) = makeStore()
        for _ in 0..<3 { store.finish(transactionID: try store.purchase(productID: ID.coins).record.id) }
        store.clearTransactions()
        #expect(store.allTransactions().isEmpty)
        #expect(try store.purchase(productID: ID.coins).record.id == 3)
        let other = device.store(for: "dev.ycode.other")
        other.installConfiguration(probeConfiguration())
        #expect(try other.purchase(productID: ID.coins).record.id == 0)
    }

    @Test("§4: quantity above 10 fails with the alert; quantity is stored")
    func quantity() throws {
        let (_, _, store) = makeStore()
        #expect(throws: StoreFailure(.unknown, alert: StoreAlert(
            title: "Can't Complete This Purchase", message: "You can't buy more than 10 of this item at one time."))) {
            try store.purchase(productID: ID.coins, options: PurchaseOptions(quantity: 11))
        }
        #expect(try store.purchase(productID: ID.coins, options: PurchaseOptions(quantity: 10)).record.quantity == 10)
    }

    @Test("§10 item 4: a deleted transaction disappears from every list")
    func delete() throws {
        let (_, _, store) = makeStore()
        let pro = try store.purchase(productID: ID.pro).record
        try store.deleteTransaction(pro.id)
        #expect(store.transactionHistory().isEmpty && store.currentEntitlements().isEmpty && store.allTransactions().isEmpty)
        #expect(throws: TestSessionError.self) { try store.deleteTransaction(pro.id) }
        // Buying again makes a new transaction.
        #expect(try store.purchase(productID: ID.pro).record.id == 1)
    }

    @Test("U4: a relaunch (a new device object on the same directory) keeps products and entitlements")
    func persistence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-storekit-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = ManualClock(referenceStart)
        do {
            let device = StoreDevice(clock: clock, timeZone: newYork, directory: dir)
            let store = device.store(for: ID.app)
            store.installConfiguration(probeConfiguration(), appName: "StoreProbe")
            store.updateSettings { $0.disableDialogs = false }
            store.finish(transactionID: try store.purchase(productID: ID.pro).record.id)
            store.finish(transactionID: try store.purchase(productID: ID.season).record.id)
        }
        let device = StoreDevice(clock: clock, timeZone: newYork, directory: dir)
        let store = device.store(for: ID.app)
        #expect(try store.products(for: ID.all).count == 7)
        #expect(store.installedConfiguration?.appName == "StoreProbe")
        #expect(Set(store.currentEntitlements().map(\.productID)) == [ID.season, ID.pro])
        #expect(store.unfinishedTransactions().isEmpty)
        // The store's copy is a configuration file (configuration-file.md §8 item 1).
        let copy = try StoreConfiguration(contentsOf: dir.appendingPathComponent(ID.app).appendingPathComponent("Configuration.storekit"))
        #expect(copy.appName == "StoreProbe")
        // Uninstall: configuration and transactions go; the override stays (simulator-baseline.md §4 item 3).
        store.uninstall()
        #expect(try store.products(for: ID.all).isEmpty)
        #expect(store.allTransactions().isEmpty)
        let reopened = StoreDevice(clock: clock, timeZone: newYork, directory: dir).store(for: ID.app)
        #expect(reopened.overrideSettings.disableDialogs == false)
        #expect(reopened.installedConfiguration == nil)
        reopened.installConfiguration(probeConfiguration())
        #expect(reopened.settings.disableDialogs == false)  // the override beats _disableDialogs true
        #expect(try reopened.purchase(productID: ID.coins).record.id == 0)
    }

    @Test("configuration-file.md §6: overrides win over the file until resetToDefaultState")
    func overrides() throws {
        let (_, _, store) = makeStore()
        #expect(store.settings.timeRate == .realTime && store.settings.disableDialogs)
        store.updateSettings { $0.timeRate = .oneRenewalEveryTenSeconds; $0.storefront = "DEU" }
        #expect(store.settings.timeRate == .oneRenewalEveryTenSeconds && store.settings.storefront.currency == "EUR")
        // Installing another file does not drop the override.
        store.installConfiguration(probeConfiguration())
        #expect(store.settings.timeRate == .oneRenewalEveryTenSeconds)
        store.resetToDefaultState()
        #expect(store.settings.timeRate == .realTime && store.settings.storefront.countryCode == "USA")
    }

    @Test("StoreKit 1 restore: new transactions in state restored (3) for pro and the active subscription")
    func restore() throws {
        let (_, _, store) = makeStore(rate: .oneRenewalEveryTenSeconds)
        _ = try store.purchase(productID: ID.coins)
        let pro = try store.purchase(productID: ID.pro).record
        let monthly = try store.purchase(productID: ID.monthly).record
        let restored = store.restoreCompletedTransactions()
        #expect(restored.map(\.productID) == [ID.pro, ID.monthly])
        #expect(restored.allSatisfy { $0.state == .restored && $0.reason == .renewal })
        #expect(restored[0].originalID == pro.id && restored[1].originalID == monthly.id)
        #expect(restored[1].expiresDate == monthly.expiresDate)
        #expect(Set(store.currentEntitlements().map(\.id)) == Set(restored.map(\.id)))
    }
}
