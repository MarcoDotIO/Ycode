// C-ENGINE part 2: the subscription scheduler and its control calls
// (testing-session.md §2.1, §3; plan.md §3.2; simulator-baseline.md §8 S1–S6).
import Foundation
import Testing
import StoreKitConfiguration
@testable import StoreKitEngine

@Suite("Time rates (testing-session.md §2.1)")
struct TimeRateTests {
    let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = newYork; return c }()
    let t0 = referenceStart.storeMilliseconds
    let week = SubscriptionDuration(value: 1, unit: .week)
    let month = SubscriptionDuration(value: 1, unit: .month)
    let year = SubscriptionDuration(value: 1, unit: .year)

    @Test("1000 series: every period (week, month, year) lasts the named time")
    func fixed() {
        let expected: [(TimeRate, Int64)] = [
            (.oneRenewalEveryFifteenMinutes, 900_000), (.oneRenewalEveryFiveMinutes, 300_000), (.oneRenewalEveryMinute, 60_000),
            (.oneRenewalEveryThirtySeconds, 30_000), (.oneRenewalEveryTenSeconds, 10_000), (.oneRenewalEveryTwoSeconds, 2_000),
        ]
        for (rate, ms) in expected {
            for d in [week, month, year] { #expect(rate.end(of: d, from: t0, calendar: cal) - t0 == ms) }
            #expect(rate.end(of: month, count: 3, from: t0, calendar: cal) - t0 == 3 * ms)
        }
    }

    @Test("10 series: one month lasts the named time; other periods scale")
    func monthly() {
        #expect(TimeRate.monthlyRenewalEveryHour.end(of: month, from: t0, calendar: cal) - t0 == 3_600_000)
        #expect(TimeRate.monthlyRenewalEveryHour.end(of: year, from: t0, calendar: cal) - t0 == 43_200_000)
        #expect(TimeRate.monthlyRenewalEveryHour.end(of: week, from: t0, calendar: cal) - t0 == 840_000)
        #expect(TimeRate.monthlyRenewalEveryThirtySeconds.end(of: month, from: t0, calendar: cal) - t0 == 30_000)
        #expect(TimeRate(rawValue: 14) == nil)
    }

    @Test("Deprecated series: one day lasts the named time (oneSecondIsOneDay: a month is 30 s)")
    func deprecated() {
        #expect(TimeRate.oneSecondIsOneDay.end(of: month, from: t0, calendar: cal) - t0 == 30_000)
        #expect(TimeRate.oneMinuteIsOneDay.end(of: week, from: t0, calendar: cal) - t0 == 420_000)
        #expect(TimeRate.oneHourIsOneDay.end(of: year, from: t0, calendar: cal) - t0 == 365 * 3_600_000)
    }

    @Test("§3 item 1 real time: calendar periods in the device time zone (DST end adds an hour)")
    func realTime() {
        let rt = TimeRate.realTime
        // One week from 2026-10-19.
        #expect(rt.end(of: week, from: t0, calendar: cal) - t0 == 604_800_000)
        // One month from 2026-10-19 and from 2026-10-05 crosses 2026-11-01: 31 days + 1 hour.
        #expect(rt.end(of: month, from: t0, calendar: cal) - t0 == 2_682_000_000)
        let oct5 = Int64(1_791_201_600_000)
        #expect(rt.end(of: month, from: oct5, calendar: cal) - oct5 == 2_682_000_000)
        // One month from 2026-09-05: 30 days.
        let sep5 = Int64(1_788_609_600_000)
        #expect(rt.end(of: month, from: sep5, calendar: cal) - sep5 == 2_592_000_000)
    }
}

@Suite("Subscriptions (testing-session.md §3; simulator-baseline.md §8 S1–S6)")
struct SubscriptionTests {
    @Test("S1 at rate 1004: free trial of 10 s, renewals every 10 s with reason RENEWAL, price 3990, contiguous dates")
    func renewals() throws {
        let (clock, _, store) = makeStore(rate: .oneRenewalEveryTenSeconds)
        let log = EventLog(store)
        clock.advance(milliseconds: 200)
        let first = try store.purchase(productID: ID.monthly).record
        #expect(first.expiresDate! - first.purchaseDate == 10_000)
        #expect(first.priceMilli == 0 && first.offer == AppliedOffer(
            type: .introductory, identifier: nil, paymentMode: .freeTrial, period: SubscriptionDuration(value: 1, unit: .week), priceMilli: 0))
        #expect(first.subscriptionGroupID == ID.plus)
        #expect(!store.isEligibleForIntroOffer(groupID: ID.plus))
        clock.advance(by: 35)
        store.advance()
        let chain = store.allTransactions().filter { $0.productID == ID.monthly }
        #expect(chain.count == 4)
        for (a, b) in zip(chain, chain.dropFirst()) {
            #expect(b.reason == .renewal && b.priceMilli == 3990 && b.offer == nil)
            #expect(b.originalID == first.id && b.originalPurchaseDate == first.purchaseDate)
            #expect(b.purchaseDate == a.expiresDate)
            #expect(b.expiresDate! - b.purchaseDate == 10_000)
        }
        // Renewals reach a running app as updates.
        #expect(log.transactions.map(\.id) == chain.dropFirst().map(\.id))
        let status = store.subscriptionStatuses(groupID: ID.plus)
        #expect(status.count == 1 && status[0].state == .subscribed && status[0].transaction.id == chain.last!.id)
        #expect(status[0].renewal.autoRenewStatus == 1 && status[0].renewal.renewalPriceMilli == 3990)
        #expect(status[0].renewal.renewalDate == chain.last!.expiresDate)
        #expect(status[0].renewal.renewalBillingPlanType == "BILLED_UPFRONT")
        #expect(status[0].renewal.recentSubscriptionStartDate == first.purchaseDate)
        #expect(store.nextEventDate() == Date(storeMilliseconds: chain.last!.expiresDate!))
        // Still not eligible after it expires.
        try store.disableAutoRenew(transactionID: first.id)
        clock.advance(by: 20)
        #expect(store.subscriptionStatuses(groupID: ID.plus)[0].state == .expired)
        #expect(!store.isEligibleForIntroOffer(groupID: ID.plus))
    }

    @Test("Real time: the monthly trial lasts 604800 s; the first paid month across the DST end 2682000 s")
    func realTimeMonthly() throws {
        let (clock, _, store) = makeStore()
        let first = try store.purchase(productID: ID.monthly).record
        #expect(first.expiresDate! - first.purchaseDate == 604_800_000)
        clock.advance(by: 604_800 + 1)
        let renewal = store.transactionHistory().first!
        #expect(renewal.reason == .renewal && renewal.purchaseDate == first.expiresDate)
        #expect(renewal.expiresDate! - renewal.purchaseDate == 2_682_000_000)
    }

    @Test("Real time from 2026-09-05: pay-as-you-go intro months of 30 days, then 31 days + 1 h, then the base price")
    func payAsYouGo() throws {
        let (clock, _, store) = makeStore(start: Date(timeIntervalSince1970: 1_788_609_600))
        let first = try store.purchase(productID: ID.lite).record
        #expect(first.priceMilli == 990 && first.offer?.paymentMode == .payAsYouGo && first.offer?.period.iso8601 == "P2M")
        #expect(first.expiresDate! - first.purchaseDate == 2_592_000_000)
        clock.set(Date(timeIntervalSince1970: 1_788_609_600 + 70 * 86_400))
        let lite = store.allTransactions().filter { $0.productID == ID.lite }
        #expect(lite.count == 3)
        #expect(lite[1].priceMilli == 990 && lite[1].offer?.type == .introductory)
        #expect(lite[1].expiresDate! - lite[1].purchaseDate == 2_682_000_000)
        #expect(lite[2].priceMilli == 1990 && lite[2].offer == nil)
    }

    @Test("S2: crossgrade and downgrade return the current transaction and change autoRenewProductId; another group is independent")
    func crossgrade() throws {
        let (clock, _, store) = makeStore(rate: .oneRenewalEveryTenSeconds)
        let monthly = try store.purchase(productID: ID.monthly).record
        let yearly = try store.purchase(productID: ID.yearly)
        #expect(yearly == .success(monthly, isRedelivery: true))
        #expect(store.subscriptionStatuses(groupID: ID.plus)[0].renewal.autoRenewProductID == ID.yearly)
        let lite = try store.purchase(productID: ID.lite)
        #expect(lite == .success(monthly, isRedelivery: true))
        #expect(store.subscriptionStatuses(groupID: ID.plus)[0].renewal.autoRenewProductID == ID.lite)
        #expect(store.subscriptionStatuses(groupID: ID.plus)[0].renewal.renewalPriceMilli == 1990)
        let weekly = try store.purchase(productID: ID.weekly).record
        #expect(weekly.originalID == weekly.id && weekly.id != monthly.id)
        #expect(store.subscriptionStatuses(groupID: ID.extra).count == 1)
        // The downgrade takes effect at the next renewal.
        clock.advance(by: 10)
        let renewal = store.latestTransaction(for: ID.lite)!
        #expect(renewal.reason == .renewal && renewal.originalID == monthly.id && renewal.priceMilli == 1990)
        #expect(renewal.purchaseDate == monthly.expiresDate)
        let status = store.subscriptionStatuses(groupID: ID.plus)[0]
        #expect(status.renewal.productID == ID.lite && status.transaction.id == renewal.id)
    }

    @Test("§3.1: an upgrade to a higher level is immediate; the old transaction is marked upgraded")
    func upgrade() throws {
        let (_, _, store) = makeStore(rate: .oneRenewalEveryTenSeconds)
        let lite = try store.purchase(productID: ID.lite).record
        let monthly = try store.purchase(productID: ID.monthly).record
        #expect(monthly.id != lite.id && monthly.originalID == lite.id && monthly.reason == .purchase)
        #expect(monthly.priceMilli == 3990 && monthly.offer == nil)
        #expect(store.transaction(lite.id)?.isUpgraded == true)
        #expect(store.currentEntitlements().map(\.id) == [monthly.id])
    }

    @Test("S3: auto-renew off → expired with intent 1; enabling renews at once from the old expiration")
    func autoRenewOff() throws {
        let (clock, _, store) = makeStore(rate: .oneRenewalEveryTenSeconds)
        let first = try store.purchase(productID: ID.monthly).record
        try store.disableAutoRenew(transactionID: first.id)
        var status = store.subscriptionStatuses(groupID: ID.plus)[0]
        #expect(status.state == .subscribed && status.renewal.autoRenewStatus == 0 && status.renewal.expirationIntent == 1)
        #expect(status.renewal.renewalBillingPlanType == nil)
        clock.advance(by: 15)
        status = store.subscriptionStatuses(groupID: ID.plus)[0]
        #expect(status.state == .expired && status.renewal.expirationIntent == 1 && status.renewal.autoRenewStatus == 0)
        #expect(store.currentEntitlements().isEmpty)
        try store.enableAutoRenew(transactionID: first.id)
        let renewal = store.latestTransaction(for: ID.monthly)!
        #expect(renewal.purchaseDate == first.expiresDate && renewal.reason == .renewal)
        status = store.subscriptionStatuses(groupID: ID.plus)[0]
        #expect(status.state == .subscribed && status.renewal.autoRenewStatus == 1 && status.renewal.expirationIntent == nil)
    }

    @Test("S4: force renewal starts a new period now; expire ends the period at the call time")
    func forceAndExpire() throws {
        let (clock, _, store) = makeStore(rate: .oneRenewalEveryTenSeconds)
        _ = try store.purchase(productID: ID.weekly)
        clock.advance(by: 3)
        try store.forceRenewal(productID: ID.weekly)
        let forced = store.latestTransaction(for: ID.weekly)!
        #expect(forced.reason == .renewal && forced.purchaseDate == clock.now().storeMilliseconds)
        #expect(forced.expiresDate! - forced.purchaseDate == 10_000)
        clock.advance(by: 2)
        try store.expireSubscription(productID: ID.weekly)
        let expired = store.transaction(forced.id)!
        #expect(expired.expiresDate == clock.now().storeMilliseconds)
        let status = store.subscriptionStatuses(groupID: ID.extra)[0]
        #expect(status.state == .expired)
        // The reference leaves one failed transaction with a purchase issue, listed by Transaction.all.
        let failed = store.transactionHistory().first!
        #expect(failed.state == .failed && failed.hasPurchaseIssue && failed.purchaseDate == forced.purchaseDate)
        // Errors (§11): an expired subscription, a non-subscription, an unknown product.
        #expect(throws: TestSessionError.self) { try store.expireSubscription(productID: ID.weekly) }
        #expect(throws: TestSessionError(.invalidProductType, "\(ID.pro) is not an auto-renewable subscription.")) {
            try store.expireSubscription(productID: ID.pro)
        }
        #expect(throws: TestSessionError(.invalidProductIdentifier, "No product nope.")) { try store.expireSubscription(productID: "nope") }
    }

    @Test("S5 at rate 1004 with billing retry: retry (state 3), then expired with intent 2 and auto-renew 0")
    func billingRetry() throws {
        let (clock, _, store) = makeStore(rate: .oneRenewalEveryTenSeconds) { $0.renewalBillingIssuesEnabled = true }
        let first = try store.purchase(productID: ID.monthly).record
        clock.advance(by: 12)
        var status = store.subscriptionStatuses(groupID: ID.plus)[0]
        #expect(status.state == .inBillingRetryPeriod && status.renewal.isInBillingRetryPeriod && status.renewal.autoRenewStatus == 1)
        #expect(store.currentEntitlements().isEmpty)
        #expect(store.allTransactions().count == 1)
        clock.advance(by: 30)
        status = store.subscriptionStatuses(groupID: ID.plus)[0]
        #expect(status.state == .expired && status.renewal.expirationIntent == 2 && status.renewal.autoRenewStatus == 0)
        #expect(!status.renewal.isInBillingRetryPeriod && status.transaction.id == first.id)
    }

    @Test("S6 at rate 1003 with billing retry and grace: state 4, grace end = failed renewal + 30 s; resolve → renewal at the grace end")
    func grace() throws {
        let (clock, _, store) = makeStore(rate: .oneRenewalEveryThirtySeconds) {
            $0.renewalBillingIssuesEnabled = true
            $0.billingGracePeriodEnabled = true
        }
        let first = try store.purchase(productID: ID.monthly).record
        let failedRenewal = first.expiresDate!
        clock.advance(by: 31)
        var status = store.subscriptionStatuses(groupID: ID.plus)[0]
        #expect(status.state == .inGracePeriod)
        #expect(status.renewal.autoRenewStatus == 1 && status.renewal.isInBillingRetryPeriod)
        #expect(status.renewal.gracePeriodExpiresDate == failedRenewal + 30_000)
        #expect(status.transaction.reason == .renewal && status.transaction.expiresDate == failedRenewal + 30_000)
        #expect(store.currentEntitlements().map(\.id) == [status.transaction.id])
        store.updateSettings { $0.billingRetryOnRenewalEnabled = false }
        try store.resolveIssue(transactionID: status.transaction.id)
        status = store.subscriptionStatuses(groupID: ID.plus)[0]
        #expect(status.state == .subscribed && !status.renewal.isInBillingRetryPeriod && status.renewal.gracePeriodExpiresDate == nil)
        clock.advance(by: 30)
        let renewal = store.latestTransaction(for: ID.monthly)!
        #expect(renewal.purchaseDate == failedRenewal + 30_000 && renewal.expiresDate! - renewal.purchaseDate == 30_000)
        #expect(store.subscriptionStatuses(groupID: ID.plus)[0].state == .subscribed)
    }

    @Test("Grace without resolution: billing retry after the grace end, then expiry")
    func graceUnresolved() throws {
        let (clock, _, store) = makeStore(rate: .oneRenewalEveryThirtySeconds) {
            $0.renewalBillingIssuesEnabled = true
            $0.billingGracePeriodEnabled = true
        }
        _ = try store.purchase(productID: ID.monthly)
        clock.advance(by: 61)
        #expect(store.subscriptionStatuses(groupID: ID.plus)[0].state == .inBillingRetryPeriod)
        clock.advance(by: 30)
        let s = store.subscriptionStatuses(groupID: ID.plus)[0]
        #expect(s.state == .expired && s.renewal.expirationIntent == 2)
    }
}
