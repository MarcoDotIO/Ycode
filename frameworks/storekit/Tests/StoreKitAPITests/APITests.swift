// C-API (plan.md §4): the probe's phases through the StoreKit 2, StoreKitTest
// and StoreKit 1 APIs over the open store (simulator-baseline.md §8 rows E1–K1,
// with dates relative and a simulated clock). The probe app itself lives in
// the dirty room; these tests are our own equivalent of its phases.
import Foundation
import Testing
import StoreKit
import StoreKitTest
import StoreKitEngine
import StoreKitSigning

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
}

let start = Date(timeIntervalSince1970: 1_792_411_200)
let vendor = UUID(uuidString: "6A1D3C2E-0F00-4B6B-9C1D-5E0D7C4C9A11")!
let configurationURL = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/YcodeProbe.storekit")

/// A fresh runtime on a manual clock; StoreKit 1 callbacks on a private queue.
@discardableResult
func freshRuntime(bundleID: String = "dev.ycode.skprobe") throws -> (ManualClock, YcodeStoreKit) {
    let clock = ManualClock(start)
    let rt = try YcodeStoreKit(
        device: StoreDevice(clock: clock, timeZone: TimeZone(identifier: "America/New_York")!), bundleID: bundleID, vendorID: vendor,
        applicationVersion: "12")
    rt.callbackQueue = DispatchQueue(label: "storekit-tests")
    YcodeStoreKit.configure(rt)
    SKPaymentQueue.ycodeReset()
    return (clock, rt)
}

func session(rate: SKTestSession.TimeRate = .oneRenewalEveryTenSeconds) throws -> SKTestSession {
    let s = try SKTestSession(contentsOf: configurationURL)
    s.timeRate = rate
    s.disableDialogs = true
    return s
}

func verified(_ r: Product.PurchaseResult) throws -> Transaction {
    guard case .success(.verified(let t)) = r else { throw TestFailure("not a verified success: \(r)") }
    return t
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func collect(_ s: Transaction.Transactions) async -> [Transaction] {
    var out: [Transaction] = []
    for await r in s { out.append(r.unsafePayloadValue) }
    return out
}

/// Reads `n` updates (or gives up after a while).
func updates(_ n: Int, from stream: Transaction.Transactions) async -> [VerificationResult<Transaction>] {
    await withTaskGroup(of: [VerificationResult<Transaction>].self) { group in
        group.addTask {
            var out: [VerificationResult<Transaction>] = []
            for await r in stream {
                out.append(r)
                if out.count == n { break }
            }
            return out
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return []
        }
        let first = await group.next() ?? []
        group.cancelAll()
        return first
    }
}

@Suite("C-API: StoreKit, StoreKitTest and StoreKit 1 over the open store", .serialized)
struct APITests {
    @Test("E1: without a configuration: payments allowed, no products, AppTransaction systemError (code 1), empty lists")
    func env() async throws {
        try freshRuntime()
        #expect(AppStore.canMakePayments)
        #expect(try await Product.products(for: ID.all).isEmpty)
        do {
            _ = try await AppTransaction.shared
            Issue.record("no error")
        } catch let e as StoreKitError {
            guard case .systemError(let payload) = e else { Issue.record("\(e)"); return }
            #expect(payload as? YcodeStoreSystemError == .noAccount)
            #expect((e as NSError).code == 1)
        }
        #expect(await collect(Transaction.all).isEmpty)
        #expect(await collect(Transaction.currentEntitlements).isEmpty)
        #expect((StoreKitError.unknown as NSError).code == 2)
    }

    @Test("E2: another bundle id sees nothing after this one installed a configuration")
    func isolation() async throws {
        try freshRuntime()
        _ = try session()
        #expect(try await Product.products(for: ID.all).count == 7)
        try freshRuntime(bundleID: "dev.ycode.skprobe.b")
        #expect(try await Product.products(for: ID.all).isEmpty)
    }

    @Test("SKTestSession: a missing file is fileNotFound (4), a non-file URL invalidURL (3)")
    func sessionErrors() throws {
        try freshRuntime()
        #expect(throws: SKTestError(.fileNotFound, detail: "No file at /nonexistent/x.storekit.")) {
            try SKTestSession(contentsOf: URL(fileURLWithPath: "/nonexistent/x.storekit"))
        }
        #expect((try? SKTestSession(contentsOf: URL(string: "https://example.com/x.storekit")!)) == nil)
        #expect((SKTestError(.invalidURL) as NSError).code == 3 && SKTestError.errorDomain == "SKTestErrorDomain")
        #expect(throws: SKTestError.self) { try SKTestSession(configurationFileNamed: "NoSuchConfiguration") }
    }

    @Test("P1, P2: the 7 products, their texts, prices, subscription info and JSON")
    func products() async throws {
        try freshRuntime()
        _ = try session()
        let products = try await Product.products(for: ID.all + ["dev.ycode.skprobe.bogus"])
        #expect(products.map(\.id) == ID.all)
        #expect(products.map(\.type) == [.consumable, .nonConsumable, .nonRenewable, .autoRenewable, .autoRenewable, .autoRenewable, .autoRenewable])
        #expect(products.map(\.displayName) == [
            "100 Probe Coins", "Probe Pro", "Probe Season Pass", "Plus Monthly", "Plus Yearly", "Plus Lite", "Extra Weekly",
        ])
        #expect(products.map(\.displayPrice) == ["$0.99", "$4.99", "$2.99", "$3.99", "$29.99", "$1.99", "$0.49"])
        #expect(products.map(\.price) == ["0.99", "4.99", "2.99", "3.99", "29.99", "1.99", "0.49"].map { Decimal(string: $0)! })
        #expect(products.map(\.isFamilyShareable) == [false, true, false, false, false, false, true])
        #expect(products[0].priceLocale.identifier == "en_US@currency=USD")
        let monthly = try #require(products[3].subscription)
        #expect(monthly.subscriptionGroupID == ID.plus && monthly.groupLevel == 1 && monthly.groupDisplayName == "Ycode Plus")
        #expect(monthly.subscriptionPeriod == .monthly)
        #expect(monthly.introductoryOffer?.paymentMode == .freeTrial && monthly.introductoryOffer?.period == .weekly)
        #expect(monthly.introductoryOffer?.displayPrice == "$0.00" && monthly.introductoryOffer?.id == nil)
        #expect(monthly.promotionalOffers.map(\.id) == ["plus.promo3"])
        #expect(monthly.promotionalOffers[0].paymentMode == .payAsYouGo && monthly.promotionalOffers[0].periodCount == 3)
        #expect(products[5].subscription?.groupLevel == 2)
        #expect(products[6].subscription?.groupDisplayName == "Extra")
        #expect(products[6].subscription?.introductoryOffer?.paymentMode == .payUpFront)
        #expect(await monthly.isEligibleForIntroOffer)
        #expect(await Product.SubscriptionInfo.isEligibleForIntroOffer(for: "999"))
        let json = try JSONSerialization.jsonObject(with: products[0].jsonRepresentation) as? [String: Any]
        #expect(json?["id"] as? String == "100000001" && json?["type"] as? String == "in-apps")
        #expect(try await Product.products(for: []).isEmpty)
    }

    @Test("U1–U3: purchases, redelivery, lists, JWS form, deviceVerification, app transaction")
    func buy() async throws {
        let (_, rt) = try freshRuntime()
        _ = try session()
        let p = Dictionary(uniqueKeysWithValues: try await Product.products(for: ID.all).map { ($0.id, $0) })
        let n = try verified(try await p[ID.coins]!.purchase())
        #expect(n.id == 0 && n.productType == .consumable && n.reason == .purchase && n.price == Decimal(string: "0.99"))
        await n.finish()
        let n1 = try verified(try await p[ID.coins]!.purchase())
        let n2 = try verified(try await p[ID.pro]!.purchase())
        #expect(try verified(try await p[ID.pro]!.purchase()).id == n2.id)
        let n3 = try verified(try await p[ID.season]!.purchase())
        #expect(try verified(try await p[ID.coins]!.purchase(options: [.quantity(3)])).id == n1.id)
        await n1.finish()
        let token = UUID()
        let n4 = try verified(try await p[ID.coins]!.purchase(options: [.appAccountToken(token)]))
        #expect([n1.id, n2.id, n3.id, n4.id] == [1, 2, 3, 4] && n4.appAccountToken == token)
        #expect(await collect(Transaction.all).map(\.id) == [4, 3, 2])
        #expect(await collect(Transaction.currentEntitlements).map(\.id) == [3, 2])
        #expect(await collect(Transaction.unfinished).map(\.id) == [4, 3, 2])
        #expect(await Transaction.latest(for: ID.coins)?.unsafePayloadValue.id == 4)
        #expect(await Transaction.currentEntitlement(for: ID.pro)?.unsafePayloadValue.id == 2)
        // U2: ES256, kid, one certificate, verifies; deviceVerification per formats.md §2.2.
        let result = try #require(await Transaction.latest(for: ID.pro))
        let d = try JWSVerifier().verify(result.jwsRepresentation)
        #expect(d.header["kid"]?.stringValue == "Apple_Xcode_Key" && d.certificates.count == 1)
        #expect(d.certificates[0].subject.description == "CN=StoreKit Testing in Xcode, O=StoreKit Testing in Xcode")
        let t = result.unsafePayloadValue
        #expect(t.environment == .xcode && t.storefrontCountryCode == "USA" && t.currencyCode == "USD" && t.ownershipType == .purchased)
        #expect(t.deviceVerification.base64EncodedString()
            == DeviceVerification.value(nonce: t.deviceVerificationNonce, vendorID: AppStore.deviceVerificationID!))
        #expect(result.deviceVerificationNonce == t.deviceVerificationNonce && result.signedDate == start)
        // U3: the app transaction; no StoreKit 1 receipt after StoreKit 2 purchases.
        let app = try await AppTransaction.shared
        guard case .verified(let a) = app else { Issue.record("unverified"); return }
        #expect(a.bundleID == "dev.ycode.skprobe" && a.appVersion == "12" && a.originalAppVersion == "12")
        #expect(a.environment == .xcode && a.originalPlatform == .iOS && a.originalPurchaseDate == Date(timeIntervalSince1970: 0))
        #expect(rt.receipt == nil)
    }

    @Test("S1–S4: renewals as updates, status and renewal info, crossgrade, auto-renew, force renewal, expiry")
    func subscriptions() async throws {
        let (clock, rt) = try freshRuntime()
        let s = try session()
        let monthly = try #require(try await Product.products(for: [ID.monthly]).first)
        let first = try verified(try await monthly.purchase())
        #expect(first.expirationDate!.timeIntervalSince(first.purchaseDate) == 10)
        #expect(first.offerType == .introductory && first.offerPaymentModeStringRepresentation == "FREE_TRIAL" && first.price == 0)
        #expect(!(await monthly.subscription!.isEligibleForIntroOffer))
        await first.finish()
        let stream = Transaction.updates
        clock.advance(by: 25)
        rt.store.advance()
        let got = await updates(2, from: stream)
        #expect(got.map { $0.unsafePayloadValue.reason } == [.renewal, .renewal])
        #expect(got.map { $0.unsafePayloadValue.price } == [Decimal(string: "3.99"), Decimal(string: "3.99")])
        #expect(got.first?.unsafePayloadValue.purchaseDate == first.expirationDate)
        let status = try #require(try await monthly.subscription!.status.first)
        #expect(status.state == .subscribed)
        guard case .verified(let info) = status.renewalInfo else { Issue.record("unverified renewal info"); return }
        #expect(info.willAutoRenew && info.renewalPrice == Decimal(string: "3.99") && info.currentProductID == ID.monthly)
        #expect(info.originalTransactionID == first.id && info.environment == .xcode)
        // S2: crossgrade returns the current transaction and changes the preference.
        let yearly = try #require(try await Product.products(for: [ID.yearly]).first)
        let current = try verified(try await yearly.purchase())
        #expect(current.productID == ID.monthly)
        #expect(try await Product.SubscriptionInfo.status(for: ID.plus).first?.renewalInfo.unsafePayloadValue.autoRenewPreference == ID.yearly)
        // S3: auto-renew off → expired, reason autoRenewDisabled.
        try s.disableAutoRenewForTransaction(identifier: UInt(first.id))
        clock.advance(by: 15)
        let expired = try #require(try await Product.SubscriptionInfo.status(for: ID.plus).first)
        #expect(expired.state == .expired && expired.renewalInfo.unsafePayloadValue.expirationReason == .autoRenewDisabled)
        // S4: force renewal and expire on the weekly subscription.
        let weekly = try #require(try await Product.products(for: [ID.weekly]).first)
        _ = try verified(try await weekly.purchase())
        try s.forceRenewalOfSubscription(productIdentifier: ID.weekly)
        let forced = try #require(await Transaction.latest(for: ID.weekly)).unsafePayloadValue
        #expect(forced.reason == .renewal && forced.purchaseDate == clock.now())
        try s.expireSubscription(productIdentifier: ID.weekly)
        #expect(try await Product.SubscriptionInfo.status(for: ID.extra).first?.state == .expired)
        #expect(s.allTransactions().contains { $0.productIdentifier == ID.weekly && $0.state == .failed && $0.hasPurchaseIssue })
        #expect(throws: SKTestError.self) { try s.expireSubscription(productIdentifier: ID.pro) }
    }

    @Test("R1: refunds through the session and the headless refund request")
    func refunds() async throws {
        try freshRuntime()
        let s = try session()
        let p = Dictionary(uniqueKeysWithValues: try await Product.products(for: ID.all).map { ($0.id, $0) })
        let pro = try verified(try await p[ID.pro]!.purchase())
        let monthly = try verified(try await p[ID.monthly]!.purchase())
        try s.refundTransaction(identifier: UInt(pro.id))
        #expect(try await monthly.ycodeRequestRefund(developerIssue: true) == .success)
        let refunded = try #require(await Transaction.latest(for: ID.pro)).unsafePayloadValue
        #expect(refunded.revocationDate == start && refunded.revocationReason == .other && refunded.revocationType == .fullRefund)
        #expect(await Transaction.latest(for: ID.monthly)?.unsafePayloadValue.revocationReason == .developerIssue)
        #expect(await collect(Transaction.currentEntitlements).isEmpty)
        #expect(try await Product.SubscriptionInfo.status(for: ID.plus).first?.state == .revoked)
        do {
            try s.refundTransaction(identifier: 99)
            Issue.record("no error")
        } catch let e as SKTestError {
            #expect(e.code == .noTransactionFound)
            #expect(e.ycodeObservedError.domain == "SKServiceErrorDomain" && e.ycodeObservedError.code == 2)
            #expect((e.ycodeObservedError.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == 17)
        }
        await s.setSimulatedError(.refundRequest(.duplicateRequest), forAPI: .refundRequest)
        let coins = try verified(try await p[ID.coins]!.purchase())
        await #expect(throws: Transaction.RefundRequestError.duplicateRequest) { try await coins.ycodeRequestRefund() }
    }

    @Test("A1: Ask to Buy: pending, deferred in the session, approval delivered as an update")
    func askToBuy() async throws {
        try freshRuntime()
        let s = try session()
        s.askToBuyEnabled = true
        let pro = try #require(try await Product.products(for: [ID.pro]).first)
        guard case .pending = try await pro.purchase() else { Issue.record("not pending"); return }
        let pending = try #require(s.allTransactions().first)
        #expect(pending.state == .deferred && pending.pendingAskToBuyConfirmation)
        #expect(await collect(Transaction.all).isEmpty)
        let stream = Transaction.updates
        try s.approveAskToBuyTransaction(identifier: pending.identifier)
        let got = await updates(1, from: stream)
        #expect(got.map { $0.unsafePayloadValue.id } == [UInt64(pending.identifier)])
        #expect(s.allTransactions().first?.state == .purchased)
        s.resetToDefaultState()
        #expect(!s.askToBuyEnabled)
    }

    @Test("F1: simulated errors through SKTestSession and their effects on the API")
    func failures() async throws {
        let (_, rt) = try freshRuntime()
        let s = try session()
        await s.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .loadProducts)
        await #expect(throws: StoreKitError.self) { try await Product.products(for: ID.all) }
        #expect(await s.simulatedError(forAPI: .loadProducts) != nil)
        await s.setSimulatedError(nil, forAPI: .loadProducts)
        let p = Dictionary(uniqueKeysWithValues: try await Product.products(for: ID.all).map { ($0.id, $0) })
        for e in [Product.PurchaseError.productUnavailable, .purchaseNotAllowed, .ineligibleForOffer, .invalidQuantity] {
            await s.setSimulatedError(.purchase(e), forAPI: .purchase)
            do {
                _ = try await p[ID.coins]!.purchase()
                Issue.record("no error")
            } catch let error as StoreKitError {
                #expect(error.ycodeKind == "unknown")
            }
        }
        #expect(rt.alerts.count == 4 && rt.alerts.allSatisfy { $0.title == "Can't Complete This Purchase" })
        await s.setSimulatedError(nil, forAPI: .purchase)
        await s.setSimulatedError(.verification(.invalidSignature), forAPI: .verification)
        guard case .success(.unverified(_, .invalidSignature)) = try await p[ID.pro]!.purchase() else {
            Issue.record("expected an unverified result")
            return
        }
        await s.setSimulatedError(nil, forAPI: .verification)
        _ = try await p[ID.monthly]!.purchase()
        await s.setSimulatedError(.generic(.networkError(URLError(.timedOut))), forAPI: .subscriptionStatus)
        #expect(try await Product.SubscriptionInfo.status(for: ID.plus).isEmpty)
        await s.setSimulatedError(nil, forAPI: .subscriptionStatus)
        await s.setSimulatedError(.generic(.unknown), forAPI: .appTransaction)
        await #expect(throws: StoreKitError.self) { try await AppTransaction.shared }
        await s.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .appStoreSync)
        await #expect(throws: StoreKitError.self) { try await AppStore.sync() }
        await s.setSimulatedError(nil, forAPI: .appStoreSync)
        try await AppStore.sync()
        // §8 interrupted purchase: an error, but a failed transaction with an issue is visible; resolve fixes it.
        s.interruptedPurchasesEnabled = true
        await #expect(throws: StoreKitError.self) { try await p[ID.season]!.purchase() }
        let issue = try #require(s.allTransactions().last)
        #expect(issue.state == .failed && issue.hasPurchaseIssue)
        #expect(await collect(Transaction.currentEntitlements).contains { $0.id == UInt64(issue.identifier) })
        try s.resolveIssueForTransaction(identifier: issue.identifier)
        #expect(s.allTransactions().last?.state == .purchased)
    }

    @Test("O1: offers: intro before an unsigned promo, code offer on an active subscription, backdated purchase")
    func offers() async throws {
        try freshRuntime()
        let s = try session()
        let monthly = try #require(try await Product.products(for: [ID.monthly]).first)
        let t = try verified(try await monthly.purchase(options: [.promotionalOffer(id: "plus.promo3")]))
        #expect(t.offerType == .introductory && t.offer?.paymentMode == .freeTrial)
        _ = try await monthly.purchase(options: [.codeOffer(referenceName: "CODEFREE")])
        let info = try #require(try await Product.SubscriptionInfo.status(for: ID.plus).first).renewalInfo.unsafePayloadValue
        #expect(info.offerType == .code && info.offerID == "CODEFREE" && info.renewalPrice == 0)
        let backdated = try await s.buyProduct(identifier: ID.lite, options: [.purchaseDate(start.addingTimeInterval(-45 * 86_400))])
        #expect(backdated.purchaseDate == start.addingTimeInterval(-45 * 86_400))
        #expect(s.allTransactions().filter { $0.productIdentifier == ID.lite }.count > 1)
        #expect(s.allTransactions().first { $0.identifier == UInt(backdated.id) }?.originalTransactionIdentifier == 0)
    }

    @Test("Dialogs: with dialogs enabled the confirmation decides (Purchase / Subscribe)")
    func dialogs() async throws {
        let (_, rt) = try freshRuntime()
        let s = try session()
        s.disableDialogs = false
        let titles = Titles()
        rt.confirmPurchase = { c in titles.add(c.buttonTitle); return c.product.type != .autoRenewable }
        let p = try await Product.products(for: [ID.coins, ID.lite])
        guard case .success = try await p[0].purchase(), case .userCancelled = try await p[1].purchase() else {
            Issue.record("unexpected results")
            return
        }
        #expect(titles.values == ["Purchase", "Subscribe"])
        let storefront = await Storefront.current
        #expect(storefront?.countryCode == "USA" && storefront?.id == "143441" && storefront?.currencyCode == "USD")
    }

    @Test("K1: StoreKit 1 products, payments, restore and the receipt")
    func storeKit1() async throws {
        let (_, rt) = try freshRuntime()
        _ = try session()
        let delegate = ProductsDelegate()
        let request = SKProductsRequest(productIdentifiers: [ID.pro, ID.monthly, "dev.ycode.skprobe.bogus"])
        request.delegate = delegate
        let response = await delegate.run(request)
        #expect(response.products.map(\.productIdentifier) == [ID.monthly, ID.pro])
        #expect(response.invalidProductIdentifiers == ["dev.ycode.skprobe.bogus"])
        let monthly = response.products[0]
        #expect(monthly.priceLocale.identifier == "en_US@currency=USD" && monthly.price == NSDecimalNumber(string: "3.99"))
        #expect(monthly.subscriptionPeriod?.unit == .month && monthly.subscriptionPeriod?.numberOfUnits == 1)
        #expect(monthly.introductoryPrice?.paymentMode == .freeTrial && monthly.introductoryPrice?.subscriptionPeriod.unit == .week)
        #expect(monthly.discounts.map(\.identifier) == ["plus.promo3"] && monthly.discounts[0].paymentMode == .payAsYouGo)
        #expect(monthly.subscriptionGroupIdentifier == ID.plus)
        let observer = QueueObserver()
        let queue = SKPaymentQueue.default()
        queue.add(observer)
        queue.add(SKPayment(product: response.products[1]))
        let states = await observer.waitForStates(2)
        #expect(states == [.purchasing, .purchased])
        let bought = try #require(queue.transactions.last)
        #expect(bought.transactionIdentifier == "0")
        queue.finishTransaction(bought)
        queue.add(SKPayment(product: monthly))
        _ = await observer.waitForStates(4)
        queue.restoreCompletedTransactions()
        await observer.waitForRestore()
        #expect(observer.restored.map(\.payment.productIdentifier) == [ID.pro, ID.monthly])
        #expect(observer.restored.allSatisfy { $0.transactionState == .restored && $0.original != nil })
        // The receipt (formats.md §3).
        let receipt = try #require(rt.receipt)
        let decoded = try DecodedReceipt(data: receipt, expectedCertificate: rt.receiptIdentity.certificate)
        #expect(decoded.values(17).count >= 2)
        #expect(decoded.certificate.subject.description == "CN=StoreKit, O=StoreKit, OU=StoreKit, C=US")
        #expect(SKPaymentQueue.canMakePayments() && queue.storefront?.identifier == "143441")
        #expect((SKError(.paymentCancelled) as NSError).domain == "SKErrorDomain" && (SKError(.paymentCancelled) as NSError).code == 2)
    }
}

final class Titles: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var values: [String] { lock.withLock { items } }
}

final class ProductsDelegate: SKProductsRequestDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<SKProductsResponse, Never>?

    func run(_ request: SKProductsRequest) async -> SKProductsResponse {
        await withCheckedContinuation { c in
            continuation = c
            request.start()
        }
    }

    func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        continuation?.resume(returning: response)
        continuation = nil
    }
}

final class QueueObserver: SKPaymentTransactionObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [SKPaymentTransactionState] = []
    private(set) var restored: [SKPaymentTransaction] = []
    private var restoreFinished = false

    func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        lock.withLock {
            for t in transactions {
                seen.append(t.transactionState)
                if t.transactionState == .restored { restored.append(t) }
            }
        }
    }

    func paymentQueueRestoreCompletedTransactionsFinished(_ queue: SKPaymentQueue) { lock.withLock { restoreFinished = true } }

    func waitForStates(_ n: Int) async -> [SKPaymentTransactionState] {
        for _ in 0..<300 {
            let s = lock.withLock { seen }
            if s.count >= n { return s }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return lock.withLock { seen }
    }

    func waitForRestore() async {
        for _ in 0..<300 {
            if lock.withLock({ restoreFinished }) { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
