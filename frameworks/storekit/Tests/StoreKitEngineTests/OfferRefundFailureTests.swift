// C-ENGINE part 3: offers, Ask to Buy, refunds, purchase issues and
// simulated errors (testing-session.md §5–§9, §11; simulator-baseline.md §8 R1, A1, F1, O1).
import Foundation
import Testing
import StoreKitConfiguration
@testable import StoreKitEngine

@Suite("Offers (testing-session.md §5; simulator-baseline.md §8 O1)")
struct OfferTests {
    @Test("§5 item 3: an unsigned promotional offer while intro-eligible gets the introductory offer")
    func introWins() throws {
        let (_, _, store) = makeStore(rate: .oneRenewalEveryTenSeconds)
        let r = try store.purchase(productID: ID.monthly, options: PurchaseOptions(promotionalOfferID: "plus.promo3")).record
        #expect(r.offer?.type == .introductory && r.offer?.paymentMode == .freeTrial && r.priceMilli == 0)
    }

    @Test("An unsigned promotional offer after the intro: offer type 2, pay-as-you-go 1990 for three periods, then 3990")
    func promotional() throws {
        let (clock, _, store) = makeStore(rate: .oneRenewalEveryTenSeconds)
        let first = try store.purchase(productID: ID.monthly).record
        try store.disableAutoRenew(transactionID: first.id)
        clock.advance(by: 11)
        let promo = try store.purchase(productID: ID.monthly, options: PurchaseOptions(promotionalOfferID: "plus.promo3")).record
        #expect(promo.offer == AppliedOffer(
            type: .promotional, identifier: "plus.promo3", paymentMode: .payAsYouGo, period: SubscriptionDuration(value: 3, unit: .month),
            priceMilli: 1990))
        #expect(promo.priceMilli == 1990 && promo.originalID == promo.id)
        clock.advance(by: 35)
        let chain = store.allTransactions().filter { $0.originalID == promo.id }
        #expect(chain.map(\.priceMilli) == [1990, 1990, 1990, 3990])
        #expect(chain.map { $0.offer?.type } == [.promotional, .promotional, .promotional, nil])
        // An unknown offer id fails with the alert (once the intro no longer applies).
        try store.expireSubscription(productID: ID.monthly)
        #expect(throws: StoreFailure(.unknown, alert: StoreAlert(title: "Unable to Purchase", message: "Contact the developer for more information."))) {
            try store.purchase(productID: ID.monthly, options: PurchaseOptions(promotionalOfferID: "nope"))
        }
    }

    @Test("§5 item 2: a signed promotional offer with a made-up signature fails with 'Unable to Purchase'")
    func signedPromotional() throws {
        let (_, device, store) = makeStore(rate: .oneRenewalEveryTenSeconds)
        let offer = SignedPromotionalOffer(offerID: "plus.promo3", keyID: "KEY1", nonce: UUID(), signature: Data([1, 2, 3]), timestamp: 0)
        #expect(throws: StoreFailure(.unknown, alert: StoreAlert(title: "Unable to Purchase", message: "Contact the developer for more information."))) {
            try store.purchase(productID: ID.monthly, options: PurchaseOptions(signedPromotionalOffer: offer))
        }
        // With a verifier that accepts it, the purchase goes through (intro first while eligible).
        device.promotionalOfferVerifier = { o, ctx in o.keyID == "KEY1" && ctx.productID == ID.monthly && ctx.bundleID == ID.app }
        #expect(try store.purchase(productID: ID.monthly, options: PurchaseOptions(signedPromotionalOffer: offer)).record.offer?.type == .introductory)
    }

    @Test("§5 item 4: a code offer on an active subscription is attached to the next renewal (offer type 3, renewal price 0)")
    func codeOnActive() throws {
        let (clock, _, store) = makeStore(rate: .oneRenewalEveryTenSeconds)
        let first = try store.purchase(productID: ID.monthly).record
        let again = try store.purchase(productID: ID.monthly, options: PurchaseOptions(codeOfferReferenceName: "CODEFREE"))
        #expect(again == .success(first, isRedelivery: true))
        let renewal = store.subscriptionStatuses(groupID: ID.plus)[0].renewal
        #expect(renewal.pendingOffer == AppliedOffer(
            type: .code, identifier: "CODEFREE", paymentMode: .freeTrial, period: SubscriptionDuration(value: 1, unit: .month), priceMilli: 0))
        #expect(renewal.renewalPriceMilli == 0)
        clock.advance(by: 10)
        let next = store.latestTransaction(for: ID.monthly)!
        #expect(next.offer?.type == .code && next.offer?.identifier == "CODEFREE" && next.priceMilli == 0)
        clock.advance(by: 10)
        #expect(store.latestTransaction(for: ID.monthly)!.priceMilli == 3990)
    }

    @Test("§5 item 4: a code the product's group does not have → the product's own introductory offer")
    func codeMissing() throws {
        let (_, _, store) = makeStore(rate: .oneRenewalEveryTenSeconds)
        let r = try store.purchase(productID: ID.weekly, options: PurchaseOptions(codeOfferReferenceName: "CODEFREE")).record
        #expect(r.offer?.type == .introductory && r.offer?.paymentMode == .payUpFront && r.priceMilli == 990)
        // A code the product has, for a new customer: applied to the purchase.
        let m = try store.purchase(productID: ID.monthly, options: PurchaseOptions(codeOfferReferenceName: "CODEFREE")).record
        #expect(m.offer?.type == .code && m.offer?.identifier == "CODEFREE" && m.priceMilli == 0)
        #expect(m.expiresDate! - m.purchaseDate == 10_000)
    }

    @Test("§3 item 4: a backdated purchase catches up at once; next to an active higher level it is reported upgraded")
    func backdated() throws {
        let (clock, _, store) = makeStore()
        _ = try store.purchase(productID: ID.monthly)
        let start = clock.now().addingTimeInterval(-45 * 86_400)
        let lite = try store.buyProduct(productID: ID.lite, options: PurchaseOptions(purchaseDate: start))
        #expect(lite.purchaseDate == start.storeMilliseconds)
        let all = store.allTransactions().filter { $0.productID == ID.lite }
        #expect(all.count == 2)
        #expect(all[1].reason == .renewal && all[1].purchaseDate == all[0].expiresDate)
        #expect(all[1].expiresDate! > clock.now().storeMilliseconds)
        #expect(all[1].isUpgraded)
    }

    @Test("A backdated purchase with cancelImmediately ends after its first period")
    func backdatedCancel() throws {
        let (clock, _, store) = makeStore()
        let start = clock.now().addingTimeInterval(-45 * 86_400)
        _ = try store.buyProduct(productID: ID.yearly, options: PurchaseOptions(purchaseDate: start, renewalBehavior: .renewUntilNow))
        let weekly = try store.buyProduct(productID: ID.weekly, options: PurchaseOptions(purchaseDate: start, renewalBehavior: .cancelImmediately))
        #expect(store.allTransactions().filter { $0.originalID == weekly.id }.count == 1)
        let s = store.subscriptionStatuses(groupID: ID.extra)[0]
        #expect(s.state == .expired && s.renewal.expirationIntent == 1)
        #expect(store.allTransactions().filter { $0.productID == ID.yearly }.count == 1)  // a year has not passed
    }
}

@Suite("Ask to Buy (testing-session.md §6; simulator-baseline.md §8 A1)")
struct AskToBuyTests {
    @Test("A1: purchases are pending (state 4, not listed); approve → state 1 delivered; decline → state 2")
    func askToBuy() throws {
        let (_, _, store) = makeStore { $0.askToBuyEnabled = true }
        let log = EventLog(store)
        guard case .pending(let coins) = try store.purchase(productID: ID.coins),
              case .pending(let pro) = try store.purchase(productID: ID.pro) else {
            Issue.record("not pending")
            return
        }
        #expect(coins.state == .deferred && coins.isPendingAskToBuy)
        #expect(store.transactionHistory().isEmpty && store.unfinishedTransactions().isEmpty)
        #expect(store.allTransactions().map(\.state) == [.deferred, .deferred])
        try store.approveAskToBuy(transactionID: pro.id)
        let approved = store.transaction(pro.id)!
        #expect(approved.state == .purchased && !approved.isPendingAskToBuy && approved.id == pro.id)
        #expect(store.currentEntitlements().map(\.id) == [pro.id])
        try store.declineAskToBuy(transactionID: coins.id)
        #expect(store.transaction(coins.id)?.state == .failed)
        // The reference still delivered and listed the declined consumable (open question 6).
        #expect(log.transactions.map(\.id) == [pro.id, coins.id])
        #expect(store.transactionHistory().map(\.id) == [pro.id, coins.id].sorted(by: >))
        #expect(throws: TestSessionError.self) { try store.approveAskToBuy(transactionID: coins.id) }
    }

    @Test("Without the reference quirk a declined request is neither delivered nor listed")
    func cleanDecline() throws {
        let (_, _, store) = makeStore(quirks: .none) { $0.askToBuyEnabled = true }
        let log = EventLog(store)
        let r = try store.purchase(productID: ID.coins).transaction!
        try store.declineAskToBuy(transactionID: r.id)
        #expect(log.transactions.isEmpty && store.transactionHistory().isEmpty)
    }

    @Test("An approved subscription request starts its period at the approval")
    func approvedSubscription() throws {
        let (clock, _, store) = makeStore(rate: .oneRenewalEveryTenSeconds) { $0.askToBuyEnabled = true }
        let r = try store.purchase(productID: ID.monthly).transaction!
        #expect(store.isEligibleForIntroOffer(groupID: ID.plus))
        clock.advance(by: 5)
        try store.approveAskToBuy(transactionID: r.id)
        let t = store.transaction(r.id)!
        #expect(t.purchaseDate == clock.now().storeMilliseconds && t.offer?.type == .introductory)
        #expect(store.subscriptionStatuses(groupID: ID.plus).first?.state == .subscribed)
    }
}

@Suite("Refunds (testing-session.md §7; simulator-baseline.md §8 R1)")
struct RefundTests {
    @Test("R1: revocation date and reason 0 on pro, coins and monthly; entitlements empty; monthly status 5")
    func refunds() throws {
        let (clock, _, store) = makeStore(rate: .oneRenewalEveryTenSeconds)
        let log = EventLog(store)
        let pro = try store.purchase(productID: ID.pro).record
        let coins = try store.purchase(productID: ID.coins).record
        store.finish(transactionID: coins.id)
        let monthly = try store.purchase(productID: ID.monthly).record
        clock.advance(by: 1)
        for id in [pro.id, coins.id, monthly.id] { try store.refundTransaction(id) }
        for id in [pro.id, coins.id, monthly.id] {
            let r = store.transaction(id)!
            #expect(r.revocationDate == clock.now().storeMilliseconds && r.revocationReason == 0)
            #expect(r.revocationType == "REFUND_FULL" && r.revocationPercentage == 100_000)
        }
        #expect(store.currentEntitlements().isEmpty)
        let status = store.subscriptionStatuses(groupID: ID.plus)[0]
        #expect(status.state == .revoked && status.renewal.autoRenewStatus == 0 && status.renewal.expirationIntent != nil)
        // The refunded, finished consumable is not listed; refunds reach the app as updates.
        #expect(!store.transactionHistory().contains { $0.id == coins.id })
        #expect(log.transactions.map(\.id) == [pro.id, coins.id, monthly.id])
        // No renewals after a refund.
        clock.advance(by: 30)
        #expect(store.allTransactions().count == 3)
    }

    @Test("§11: refunding an unknown id fails (documented code noTransactionFound; observed SKServiceErrorDomain 2 / SKInternalErrorDomain 17)")
    func unknownRefund() {
        let (_, _, store) = makeStore()
        #expect(throws: TestSessionError(.noTransactionFound, "No transaction 99.")) { try store.refundTransaction(99) }
        #expect(TestSessionError.observedDomain == "SKServiceErrorDomain" && TestSessionError.observedCode == 2)
        #expect(TestSessionError.observedUnderlyingDomain == "SKInternalErrorDomain" && TestSessionError.observedUnderlyingCode == 17)
        #expect(TestErrorCode.noTransactionFound.rawValue == 6 && TestErrorCode.invalidAction.rawValue == 7)
    }
}

@Suite("Failures (testing-session.md §8–§9; simulator-baseline.md §8 F1)")
struct FailureTests {
    let alertCases: [PurchaseFailureReason] = [.productUnavailable, .purchaseNotAllowed, .ineligibleForOffer, .invalidQuantity]

    @Test("F1: a load-products error → systemError(unknown); clearing it restores the products")
    func loadProducts() throws {
        let (_, _, store) = makeStore()
        store.setSimulatedError(.generic(.networkError(code: -1009)), for: .loadProducts)
        #expect(throws: StoreFailure(.systemError(.unknown), simulated: .generic(.networkError(code: -1009)))) {
            try store.products(for: ID.all)
        }
        store.setSimulatedError(nil, for: .loadProducts)
        #expect(try store.products(for: ID.all).count == 7)
    }

    @Test("F1: the four purchase errors show the alert then fail with unknown; generic ones fail at once")
    func purchaseErrors() throws {
        let (_, _, store) = makeStore()
        for reason in alertCases {
            store.setSimulatedError(.purchase(reason), for: .purchase)
            do {
                _ = try store.purchase(productID: ID.coins)
                Issue.record("no error")
            } catch {
                #expect(error.kind == .unknown && error.alert?.title == "Can't Complete This Purchase")
            }
        }
        for generic in [GenericFailure.unknown, .systemError, .notEntitled, .userCancelled] {
            store.setSimulatedError(.generic(generic), for: .purchase)
            #expect(throws: StoreFailure(.unknown, simulated: .generic(generic))) { try store.purchase(productID: ID.coins) }
        }
        #expect(store.allTransactions().isEmpty)
        // With dialogs disabled the alert still appears (the alert is part of the failure).
        #expect(store.settings.disableDialogs)
    }

    @Test("F1: status error → empty list; AppTransaction and sync errors → systemError")
    func otherAPIs() throws {
        let (_, _, store) = makeStore(rate: .oneRenewalEveryTenSeconds)
        _ = try store.purchase(productID: ID.monthly)
        store.setSimulatedError(.generic(.networkError(code: -1001)), for: .subscriptionStatus)
        #expect(store.subscriptionStatuses(groupID: ID.plus).isEmpty)
        store.setSimulatedError(nil, for: .subscriptionStatus)
        #expect(store.subscriptionStatuses(groupID: ID.plus).count == 1)
        try store.checkAppTransaction()
        store.setSimulatedError(.generic(.unknown), for: .appTransaction)
        #expect(throws: StoreFailure(.systemError(.unknown), simulated: .generic(.unknown))) { try store.checkAppTransaction() }
        try store.sync()
        store.setSimulatedError(.generic(.networkError(code: -1009)), for: .appStoreSync)
        #expect(throws: StoreFailure.self) { try store.sync() }
        store.setSimulatedError(nil, for: .appStoreSync)
        try store.sync()
        store.setSimulatedError(.refundRequest(.duplicateRequest), for: .refundRequest)
        #expect(throws: StoreFailure(.unknown, simulated: .refundRequest(.duplicateRequest))) { try store.checkSimulatedError(for: .refundRequest) }
        #expect(store.simulatedError(for: .refundRequest) == .refundRequest(.duplicateRequest))
        try store.checkSimulatedError(for: .manageSubscriptions)
    }

    @Test("§8: an interrupted purchase fails but the app sees a failed transaction with a purchase issue; resolve → state 1")
    func interrupted() throws {
        let (_, _, store) = makeStore { $0.billingIssuesEnabled = true }
        let log = EventLog(store)
        var recorded: TransactionRecord?
        do {
            _ = try store.purchase(productID: ID.pro)
            Issue.record("no error")
        } catch {
            #expect(error.kind == .unknown)
            recorded = error.record
        }
        let r = try #require(recorded)
        #expect(r.state == .failed && r.hasPurchaseIssue)
        #expect(store.transactionHistory().map(\.id) == [r.id])
        #expect(store.currentEntitlements().map(\.id) == [r.id])
        #expect(log.transactions.map(\.id) == [r.id])
        try store.resolveIssue(transactionID: r.id)
        let resolved = store.transaction(r.id)!
        #expect(resolved.state == .purchased && !resolved.hasPurchaseIssue)
        #expect(store.allTransactions().count == 1)
        #expect(throws: TestSessionError.self) { try store.resolveIssue(transactionID: r.id) }
    }

    @Test("The price-increase calls fail with the invalid-state error")
    func priceIncrease() throws {
        let (_, _, store) = makeStore(rate: .oneRenewalEveryTenSeconds)
        let r = try store.purchase(productID: ID.monthly).record
        #expect(throws: TestSessionError.self) { try store.requestPriceIncreaseConsent(transactionID: r.id) }
        #expect(throws: TestSessionError.self) { try store.consentToPriceIncrease(transactionID: r.id) }
        #expect(throws: TestSessionError.self) { try store.declinePriceIncrease(transactionID: r.id) }
    }

    @Test("Deprecated failTransactionsEnabled fails purchases without recording them")
    func failTransactions() {
        let (_, _, store) = makeStore { $0.failTransactionsEnabled = true }
        #expect(throws: StoreFailure(.unknown)) { try store.purchase(productID: ID.coins) }
        #expect(store.allTransactions().isEmpty)
    }
}
