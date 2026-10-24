// StoreProbe: Ycode's own black-box probe for StoreKit Testing in the iOS
// simulator. One launch runs one phase (launch argument "-phase NAME") and
// prints one observation per line to stderr, ending with "DONE".
// Products come from our own configuration file YcodeProbe.storekit, loaded
// with SKTestSession (launch argument "-session 1", the default) or from the
// scheme/Xcode path (when "-session 0").
// Full JWS strings are written to Documents/jws-*.txt for offline decoding.

import UIKit
import StoreKit
import StoreKitTest
import CryptoKit

let args = ProcessInfo.processInfo.arguments
func arg(_ k: String) -> String? {
    if let i = args.firstIndex(of: "-" + k), i + 1 < args.count { return args[i + 1] }
    return nil
}
let t0 = Date()
func say(_ s: String) {
    let line = String(format: "[%7.2f] ", Date().timeIntervalSince(t0)) + s + "\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
}
func one(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: " | ") }

let P = "dev.ycode.skprobe."
let coins = P + "coins100", pro = P + "pro", season = P + "season"
let monthly = P + "plus.monthly", yearly = P + "plus.yearly", lite = P + "plus.lite"
let weekly = P + "extra.weekly"
let allIDs = [coins, pro, season, monthly, yearly, lite, weekly]
let plusGroup = "200000001", extraGroup = "200000002"

var session: SKTestSession?
var products: [String: Product] = [:]
weak var rootVC: UIViewController?
var jwsCounter = 0

// MARK: helpers

func withTimeout<T>(_ secs: Double, _ op: @escaping () async throws -> T) async -> Result<T, Error>? {
    await withTaskGroup(of: Result<T, Error>?.self) { g in
        g.addTask { do { return .success(try await op()) } catch { return .failure(error) } }
        g.addTask { try? await Task.sleep(nanoseconds: UInt64(secs * 1e9)); return nil }
        let r = await g.next()!
        g.cancelAll()
        return r
    }
}

func errDesc(_ e: Error) -> String {
    let ns = e as NSError
    return "\(type(of: e)) \(e) [domain=\(ns.domain) code=\(ns.code)]"
}

func b64urlDecode(_ s: Substring) -> Data? {
    var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while t.count % 4 != 0 { t += "=" }
    return Data(base64Encoded: t)
}

func saveJWS(_ tag: String, _ jws: String) {
    jwsCounter += 1
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let name = String(format: "jws-%02d-%@.txt", jwsCounter, tag.replacingOccurrences(of: " ", with: "_"))
    try? jws.write(to: docs.appendingPathComponent(name), atomically: true, encoding: .utf8)
    let parts = jws.split(separator: ".", omittingEmptySubsequences: false)
    var hdr = "?"
    if let h = parts.first, let d = b64urlDecode(h),
       let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
        var keys: [String] = []
        for (k, v) in o.sorted(by: { $0.key < $1.key }) {
            if k == "x5c", let a = v as? [String] {
                keys.append("x5c=[\(a.map { "\($0.count)b64" }.joined(separator: ","))]")
            } else { keys.append("\(k)=\(v)") }
        }
        hdr = keys.joined(separator: " ")
    }
    let sigLen = parts.count == 3 ? (b64urlDecode(parts[2])?.count ?? -1) : -1
    say("  JWS \(tag): file=\(name) parts=\(parts.count) len=\(jws.count) header{\(hdr)} sigBytes=\(sigLen)")
    if parts.count == 3, let d = b64urlDecode(parts[1]), let s = String(data: d, encoding: .utf8) {
        say("  JWS \(tag) payload=\(s)")
        if let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let dv = o["deviceVerification"] as? String, let n = o["deviceVerificationNonce"] as? String {
            say("  JWS \(tag) deviceVerification check: \(checkDV(dv, n))")
        }
    }
}

// Which combination of the vendor identifier and the nonce hashes (SHA-384)
// to the deviceVerification value? Prints the matching candidate names.
func checkDV(_ dv: String, _ nonce: String) -> String {
    guard let want = Data(base64Encoded: dv), let idfv = UIDevice.current.identifierForVendor,
          let nu = UUID(uuidString: nonce) else { return "no idfv/nonce" }
    func raw(_ u: UUID) -> Data { withUnsafeBytes(of: u.uuid) { Data($0) } }
    let cands: [(String, Data)] = [
        ("nonceStrLower+idfvStrLower", Data((nonce.lowercased() + idfv.uuidString.lowercased()).utf8)),
        ("nonceStrLower+idfvStrUpper", Data((nonce.lowercased() + idfv.uuidString).utf8)),
        ("idfvStrUpper+nonceStrLower", Data((idfv.uuidString + nonce.lowercased()).utf8)),
        ("idfvStrLower+nonceStrLower", Data((idfv.uuidString.lowercased() + nonce.lowercased()).utf8)),
        ("nonceRaw+idfvRaw", raw(nu) + raw(idfv)),
        ("idfvRaw+nonceRaw", raw(idfv) + raw(nu)),
    ]
    let hits = cands.filter { Data(SHA384.hash(data: $0.1)) == want }.map { $0.0 }
    return "idfv=\(idfv.uuidString) bytes=\(want.count) match=\(hits.isEmpty ? "none" : hits.joined(separator: ","))"
}

func txLine(_ t: Transaction) -> String {
    var s = "id=\(t.id) orig=\(t.originalID) product=\(t.productID) type=\(t.productType.rawValue)"
    s += " purchased=\(t.purchaseDate.timeIntervalSince1970) origPurchased=\(t.originalPurchaseDate.timeIntervalSince1970)"
    if let e = t.expirationDate { s += " expires=\(e.timeIntervalSince1970) (+\(Int(e.timeIntervalSince(t.purchaseDate)))s)" }
    if let r = t.revocationDate { s += " revoked=\(r.timeIntervalSince1970) reason=\(String(describing: t.revocationReason))" }
    s += " qty=\(t.purchasedQuantity) owner=\(t.ownershipType.rawValue) upgraded=\(t.isUpgraded)"
    if let o = t.offer { s += " offer{type=\(o.type.rawValue) id=\(o.id ?? "nil") mode=\(String(describing: o.paymentMode))}" }
    s += " env=\(t.environment.rawValue) reason=\(t.reason.rawValue) storefront=\(t.storefront.countryCode)"
    if let g = t.subscriptionGroupID { s += " group=\(g)" }
    if let p = t.price { s += " price=\(p) \(t.currency?.identifier ?? "?")" }
    return s
}

func dumpTx(_ tag: String, _ r: VerificationResult<Transaction>, jws: Bool = true) {
    switch r {
    case .verified(let t): say("\(tag) VERIFIED \(txLine(t))")
    case .unverified(let t, let e): say("\(tag) UNVERIFIED(\(e)) \(txLine(t))")
    }
    if jws { saveJWS(tag, r.jwsRepresentation) }
}

func tx(_ r: VerificationResult<Transaction>) -> Transaction {
    switch r { case .verified(let t): return t; case .unverified(let t, _): return t }
}

func listTx(_ tag: String, _ seq: Transaction.Transactions) async {
    var n = 0
    for await r in seq { n += 1; dumpTx("  \(tag)[\(n)]", r, jws: false) }
    say("\(tag) count=\(n)")
}

func dumpAll(_ tag: String) async {
    say("== \(tag)")
    await listTx("all", Transaction.all)
    await listTx("currentEntitlements", Transaction.currentEntitlements)
    await listTx("unfinished", Transaction.unfinished)
    if let s = session {
        for t in s.allTransactions() {
            say("  SKTestTransaction id=\(t.identifier) orig=\(t.originalTransactionIdentifier) product=\(t.productIdentifier) state=\(t.state.rawValue) autoRenew=\(t.autoRenewingEnabled) expires=\(t.expirationDate?.timeIntervalSince1970 ?? 0) cancel=\(t.cancelDate?.timeIntervalSince1970 ?? 0) issue=\(t.hasPurchaseIssue) askToBuy=\(t.pendingAskToBuyConfirmation) priceIncrease=\(t.isPendingPriceIncreaseConsent)")
        }
    }
}

func dumpStatus(_ tag: String, group: String) async {
    do {
        let st = try await Product.SubscriptionInfo.status(for: group)
        say("\(tag) status(group \(group)) count=\(st.count)")
        for (i, s) in st.enumerated() {
            say("  [\(i)] state=\(s.state.rawValue) tx: \(txLine(tx(s.transaction)))")
            switch s.renewalInfo {
            case .verified(let ri), .unverified(let ri, _):
                say("  [\(i)] renewal: \(one(ri.debugDescription))")
            }
            saveJWS("\(tag)-renewal\(i)", s.renewalInfo.jwsRepresentation)
        }
    } catch { say("\(tag) status error \(errDesc(error))") }
}

func load(_ ids: [String] = allIDs) async {
    switch await withTimeout(30, { try await Product.products(for: ids) }) {
    case .success(let ps)?:
        for p in ps { products[p.id] = p }
        say("products(for: \(ids.count)) -> \(ps.count): \(ps.map { $0.id }.sorted())")
    case .failure(let e)?: say("products error \(errDesc(e))")
    case nil: say("products TIMEOUT")
    }
}

func buy(_ id: String, _ opts: Set<Product.PurchaseOption> = [], finish: Bool = true, tag: String = "buy") async -> Transaction? {
    guard let p = products[id] else { say("\(tag) \(id): no product"); return nil }
    let r = await withTimeout(120, { @MainActor in
        if let vc = rootVC { return try await p.purchase(confirmIn: vc, options: opts) }
        return try await p.purchase(options: opts)
    })
    switch r {
    case .success(let res)?:
        switch res {
        case .success(let v):
            dumpTx("\(tag) \(id) success", v)
            if finish { await tx(v).finish(); say("  finished \(tx(v).id)") }
            return tx(v)
        case .pending: say("\(tag) \(id) PENDING")
        case .userCancelled: say("\(tag) \(id) USERCANCELLED")
        @unknown default: say("\(tag) \(id) unknown result")
        }
    case .failure(let e)?: say("\(tag) \(id) error \(errDesc(e))")
    case nil: say("\(tag) \(id) TIMEOUT")
    }
    return nil
}

func dumpProduct(_ p: Product) {
    say("PRODUCT \(p.id) type=\(p.type.rawValue) name=\(p.displayName) desc=\(p.description) price=\(p.price) display=\(p.displayPrice) family=\(p.isFamilyShareable) currency=\(p.priceFormatStyle.currencyCode) locale=\(p.priceFormatStyle.locale.identifier)")
    if let s = p.subscription {
        say("  sub group=\(s.subscriptionGroupID) groupName=\(s.groupDisplayName) level=\(s.groupLevel) period=\(s.subscriptionPeriod.value) \(s.subscriptionPeriod.unit)")
        if let o = s.introductoryOffer { say("  intro id=\(o.id ?? "nil") type=\(o.type.rawValue) mode=\(o.paymentMode.rawValue) price=\(o.price) display=\(o.displayPrice) period=\(o.period.value) \(o.period.unit) count=\(o.periodCount)") }
        for o in s.promotionalOffers { say("  promo id=\(o.id ?? "nil") type=\(o.type.rawValue) mode=\(o.paymentMode.rawValue) price=\(o.price) display=\(o.displayPrice) period=\(o.period.value) \(o.period.unit) count=\(o.periodCount)") }
        for o in s.winBackOffers { say("  winback id=\(o.id ?? "nil") mode=\(o.paymentMode.rawValue) price=\(o.price) period=\(o.period.value) \(o.period.unit) count=\(o.periodCount)") }
    }
    say("  debug: \(one(p.debugDescription))")
    say("  json: \(String(data: p.jsonRepresentation, encoding: .utf8) ?? "?")")
}

func makeSession() {
    if arg("session") == "0" { say("no SKTestSession"); return }
    do {
        let s = try SKTestSession(configurationFileNamed: arg("config") ?? "YcodeProbe")
        s.disableDialogs = arg("dialogs") != "1"
        session = s
        say("SKTestSession ok storefront=\(s.storefront) locale=\(s.locale.identifier) timeRate=\(s.timeRate.rawValue) askToBuy=\(s.askToBuyEnabled) disableDialogs=\(s.disableDialogs) interrupted=\(s.interruptedPurchasesEnabled) billingRetry=\(s.shouldEnterBillingRetryOnRenewal) grace=\(s.billingGracePeriodIsEnabled)")
    } catch { say("SKTestSession error \(errDesc(error))") }
}

func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

func sessionCall(_ what: String, _ f: () throws -> Void) {
    do { try f(); say("session.\(what) ok") } catch { say("session.\(what) error \(errDesc(error))") }
}

// MARK: phases

func phaseEnv() async {
    say("canMakePayments=\(AppStore.canMakePayments)")
    switch await withTimeout(20, { await Storefront.current }) {
    case .success(let sf)?: say("storefront=\(sf.map { "\($0.countryCode) id=\($0.id) currency=\($0.currency?.identifier ?? "?")" } ?? "nil")")
    default: say("storefront timeout/err")
    }
    await load()
    switch await withTimeout(30, { try await AppTransaction.shared }) {
    case .success(let r)?:
        switch r {
        case .verified(let a), .unverified(let a, _): say("AppTransaction \(one(a.debugDescription))")
        }
        saveJWS("appTransaction", r.jwsRepresentation)
    case .failure(let e)?: say("AppTransaction error \(errDesc(e))")
    case nil: say("AppTransaction TIMEOUT")
    }
    await dumpAll("env")
    if let s = session { say("receiptURL=\(Bundle.main.appStoreReceiptURL?.path ?? "nil") session.timeRate=\(s.timeRate.rawValue)") }
}

func phaseProducts() async {
    await load()
    for id in allIDs { if let p = products[id] { dumpProduct(p) } }
    await load(["dev.ycode.skprobe.bogus"])
    await load([])
    for g in [plusGroup, extraGroup, "999"] {
        say("isEligibleForIntroOffer(\(g))=\(await Product.SubscriptionInfo.isEligibleForIntroOffer(for: g))")
    }
}

func phaseBuy() async {
    session?.resetToDefaultState(); session?.clearTransactions(); session?.disableDialogs = true
    await load()
    await dumpAll("before")
    _ = await buy(coins)
    _ = await buy(coins, finish: false, tag: "buy-unfinished")
    _ = await buy(pro)
    _ = await buy(pro, tag: "buy-again")
    _ = await buy(season)
    _ = await buy(coins, [.quantity(3)])
    _ = await buy(coins, [.appAccountToken(UUID(uuidString: "00000000-0000-4000-8000-0000000000AB")!), .custom(key: "k", value: "v")])
    for id in [coins, pro, season] {
        if let r = await Transaction.latest(for: id) { dumpTx("latest(\(id))", r, jws: false) } else { say("latest(\(id)) nil") }
    }
    await dumpAll("after")
    if let p = products[pro] {
        say("pro currentEntitlement=\(String(describing: await p.currentEntitlement.map { tx($0).id }))")
    }
    say("receiptURL=\(Bundle.main.appStoreReceiptURL?.path ?? "nil") exists=\(Bundle.main.appStoreReceiptURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)")
    if let u = Bundle.main.appStoreReceiptURL, let d = try? Data(contentsOf: u) {
        say("receipt bytes=\(d.count) head=\(d.prefix(8).map { String(format: "%02x", $0) }.joined())")
    }
    switch await withTimeout(30, { try await AppTransaction.shared }) {
    case .success(let r)?:
        switch r { case .verified(let a), .unverified(let a, _): say("AppTransaction \(one(a.debugDescription))") }
        saveJWS("appTransaction", r.jwsRepresentation)
    case .failure(let e)?: say("AppTransaction error \(errDesc(e))")
    case nil: say("AppTransaction TIMEOUT")
    }
    // SKTestSession.buyProduct (outside the app's purchase API)
    if let s = session {
        do { let t = try await s.buyProduct(identifier: pro); say("session.buyProduct pro -> \(txLine(t))") } catch { say("session.buyProduct error \(errDesc(error))") }
        do { let t = try await s.buyProduct(identifier: "dev.ycode.skprobe.bogus"); say("session.buyProduct bogus -> \(t.id)") } catch { say("session.buyProduct bogus error \(errDesc(error))") }
    }
    await sleep(2)
}

func phaseRelaunch() async {
    await load()
    await dumpAll("relaunch")
    await sleep(5)
}

func phaseFinishAll() async {
    for await r in Transaction.unfinished { let t = tx(r); await t.finish(); say("finished unfinished \(t.id) \(t.productID)") }
    await dumpAll("after finish")
}

func phaseSub() async {
    guard let s = session else { return }
    s.resetToDefaultState(); s.clearTransactions(); s.disableDialogs = true
    let rate = Int(arg("rate") ?? "1003") ?? 1003  // oneRenewalEveryThirtySeconds
    s.timeRate = SKTestSession.TimeRate(rawValue: rate) ?? .realTime
    say("timeRate set \(s.timeRate.rawValue)")
    await load()
    say("eligible before=\(await Product.SubscriptionInfo.isEligibleForIntroOffer(for: plusGroup))")
    _ = await buy(monthly)
    say("eligible after=\(await Product.SubscriptionInfo.isEligibleForIntroOffer(for: plusGroup))")
    await dumpStatus("afterBuy", group: plusGroup)
    let wait = Double(arg("wait") ?? "70") ?? 70
    say("waiting \(wait)s for renewals")
    await sleep(wait)
    await dumpStatus("afterWait", group: plusGroup)
    await dumpAll("afterWait")
    // crossgrade/upgrade/downgrade
    _ = await buy(yearly, tag: "crossgrade-yearly")
    await dumpStatus("afterYearly", group: plusGroup)
    _ = await buy(lite, tag: "downgrade-lite")
    await dumpStatus("afterLite", group: plusGroup)
    _ = await buy(weekly, tag: "other-group")
    await dumpStatus("extra", group: extraGroup)
    // auto-renew off
    if let cur = s.allTransactions().last(where: { $0.productIdentifier.hasPrefix(P + "plus") }) {
        sessionCall("disableAutoRenew(\(cur.identifier))") { try s.disableAutoRenewForTransaction(identifier: cur.identifier) }
        await sleep(2)
        await dumpStatus("autoRenewOff", group: plusGroup)
        sessionCall("enableAutoRenew(\(cur.identifier))") { try s.enableAutoRenewForTransaction(identifier: cur.identifier) }
        sessionCall("requestPriceIncreaseConsent(\(cur.identifier))") { try s.requestPriceIncreaseConsentForTransaction(identifier: cur.identifier) }
        await sleep(2)
        await dumpStatus("priceIncrease", group: plusGroup)
        sessionCall("consentToPriceIncrease(\(cur.identifier))") { try s.consentToPriceIncreaseForTransaction(identifier: cur.identifier) }
    }
    sessionCall("forceRenewal(weekly)") { try s.forceRenewalOfSubscription(productIdentifier: weekly) }
    await sleep(2)
    sessionCall("expire(weekly)") { try s.expireSubscription(productIdentifier: weekly) }
    await sleep(2)
    await dumpStatus("weeklyExpired", group: extraGroup)
    say("eligible extra after expire=\(await Product.SubscriptionInfo.isEligibleForIntroOffer(for: extraGroup))")
    // billing retry + grace
    s.shouldEnterBillingRetryOnRenewal = true
    s.billingGracePeriodIsEnabled = arg("grace") == "1"
    say("billingRetry on, grace=\(s.billingGracePeriodIsEnabled); waiting 40s")
    await sleep(40)
    await dumpStatus("billingRetry", group: plusGroup)
    if let cur = s.allTransactions().last(where: { $0.productIdentifier.hasPrefix(P + "plus") }) {
        s.shouldEnterBillingRetryOnRenewal = false
        sessionCall("resolveIssue(\(cur.identifier))") { try s.resolveIssueForTransaction(identifier: cur.identifier) }
        await sleep(3)
        await dumpStatus("resolved", group: plusGroup)
    }
    sessionCall("expire(monthly)") { try s.expireSubscription(productIdentifier: monthly) }
    sessionCall("expire(yearly)") { try s.expireSubscription(productIdentifier: yearly) }
    sessionCall("expire(lite)") { try s.expireSubscription(productIdentifier: lite) }
    await sleep(3)
    await dumpStatus("final", group: plusGroup)
    await dumpAll("final")
}

func phaseRefund() async {
    guard let s = session else { return }
    s.resetToDefaultState(); s.clearTransactions(); s.disableDialogs = true
    await load()
    let tp = await buy(pro)
    let tc = await buy(coins)
    let tm = await buy(monthly)
    for t in [tp, tc, tm].compactMap({ $0 }) {
        sessionCall("refund(\(t.id))") { try s.refundTransaction(identifier: UInt(t.id)) }
    }
    await sleep(3)
    await dumpAll("refunded")
    for id in [pro, monthly] { if let r = await Transaction.latest(for: id) { dumpTx("refunded-latest(\(id))", r) } }
    await dumpStatus("refunded", group: plusGroup)
    sessionCall("refund(999999)") { try s.refundTransaction(identifier: 999999) }
    sessionCall("deleteTransaction(\(tc?.id ?? 0))") { try s.deleteTransaction(identifier: UInt(tc?.id ?? 0)) }
    await sleep(1)
    await dumpAll("deleted")
    sessionCall("expire(pro non-sub)") { try s.expireSubscription(productIdentifier: pro) }
    sessionCall("expire(bogus)") { try s.expireSubscription(productIdentifier: "x") }
}

func phaseAsk() async {
    guard let s = session else { return }
    s.resetToDefaultState(); s.clearTransactions(); s.disableDialogs = true
    s.askToBuyEnabled = true
    await load()
    _ = await buy(pro, tag: "ask")
    _ = await buy(coins, tag: "ask")
    await dumpAll("pending")
    let pend = s.allTransactions().filter { $0.pendingAskToBuyConfirmation }
    if pend.count >= 1 { sessionCall("approve(\(pend[0].identifier))") { try s.approveAskToBuyTransaction(identifier: pend[0].identifier) } }
    if pend.count >= 2 { sessionCall("decline(\(pend[1].identifier))") { try s.declineAskToBuyTransaction(identifier: pend[1].identifier) } }
    await sleep(3)
    await dumpAll("answered")
    s.askToBuyEnabled = false
}

func phaseFail() async {
    guard let s = session else { return }
    s.resetToDefaultState(); s.clearTransactions(); s.disableDialogs = true
    do {
        try await s.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .loadProducts)
        say("simulated loadProducts error set")
    } catch { say("setSimulatedError error \(errDesc(error))") }
    await load()
    try? await s.setSimulatedError(nil, forAPI: .loadProducts)
    await load()
    let cases: [(String, SKTestFailures.Purchase)] = [
        ("productUnavailable", .purchase(.productUnavailable)),
        ("purchaseNotAllowed", .purchase(.purchaseNotAllowed)),
        ("ineligibleForOffer", .purchase(.ineligibleForOffer)),
        ("invalidQuantity", .purchase(.invalidQuantity)),
        ("generic.unknown", .generic(.unknown)),
        ("generic.systemError", .generic(.systemError(NSError(domain: "dev.ycode", code: 7)))),
        ("generic.notEntitled", .generic(.notEntitled)),
        ("generic.userCancelled", .generic(.userCancelled)),
    ]
    for (n, f) in cases {
        try? await s.setSimulatedError(f, forAPI: .purchase)
        say("-- purchase failure \(n)")
        _ = await buy(coins, tag: "fail-\(n)")
    }
    try? await s.setSimulatedError(nil, forAPI: .purchase)
    for (n, f) in [("invalidSignature", SKTestFailures.Verification.verification(.invalidSignature)),
                   ("revokedCertificate", .verification(.revokedCertificate)),
                   ("invalidDeviceVerification", .verification(.invalidDeviceVerification))] {
        try? await s.setSimulatedError(f, forAPI: .verification)
        say("-- verification failure \(n)")
        _ = await buy(coins, tag: "verify-\(n)")
    }
    try? await s.setSimulatedError(nil, forAPI: .verification)
    try? await s.setSimulatedError(.generic(.networkError(URLError(.timedOut))), forAPI: .subscriptionStatus)
    await dumpStatus("statusFail", group: plusGroup)
    try? await s.setSimulatedError(nil, forAPI: .subscriptionStatus)
    try? await s.setSimulatedError(.generic(.unknown), forAPI: .appTransaction)
    switch await withTimeout(20, { try await AppTransaction.shared }) {
    case .success?: say("AppTransaction ok despite failure")
    case .failure(let e)?: say("AppTransaction fail \(errDesc(e))")
    case nil: say("AppTransaction TIMEOUT")
    }
    try? await s.setSimulatedError(nil, forAPI: .appTransaction)
    try? await s.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .appStoreSync)
    switch await withTimeout(20, { try await AppStore.sync() }) {
    case .success?: say("AppStore.sync ok despite failure")
    case .failure(let e)?: say("AppStore.sync fail \(errDesc(e))")
    case nil: say("AppStore.sync TIMEOUT")
    }
    try? await s.setSimulatedError(nil, forAPI: .appStoreSync)
    switch await withTimeout(20, { try await AppStore.sync() }) {
    case .success?: say("AppStore.sync ok")
    case .failure(let e)?: say("AppStore.sync fail \(errDesc(e))")
    case nil: say("AppStore.sync TIMEOUT")
    }
    // interrupted purchase
    s.interruptedPurchasesEnabled = true
    let r = await buy(pro, tag: "interrupted")
    say("interrupted result tx=\(String(describing: r?.id))")
    await dumpAll("interrupted")
    if let t = s.allTransactions().first(where: { $0.hasPurchaseIssue }) {
        sessionCall("resolveIssue(\(t.identifier))") { try s.resolveIssueForTransaction(identifier: t.identifier) }
        await sleep(3)
        await dumpAll("interrupted resolved")
    }
    s.interruptedPurchasesEnabled = false
}

func phaseOffers() async {
    guard let s = session else { return }
    s.resetToDefaultState(); s.clearTransactions(); s.disableDialogs = true
    await load()
    _ = await buy(monthly, [Product.PurchaseOption.promotionalOffer(id: "plus.promo3")] as Set, tag: "testPromo")
    await dumpStatus("promo", group: plusGroup)
    // real promotional-offer API with a made-up signature
    if let p = products[monthly], let o = p.subscription?.promotionalOffers.first, let oid = o.id {
        _ = await buy(monthly, [.promotionalOffer(offerID: oid, keyID: "YCODETEST1", nonce: UUID(), signature: Data(repeating: 1, count: 64), timestamp: Int(Date().timeIntervalSince1970 * 1000))], tag: "signedPromo")
    }
    _ = await buy(weekly, [Product.PurchaseOption.codeOffer(referenceName: "CODEFREE")] as Set, tag: "codeOffer-weekly")
    do {
        let t = try await s.buyProduct(identifier: monthly, options: [Product.PurchaseOption.codeOffer(referenceName: "CODEFREE")])
        say("session.buyProduct codeOffer -> \(txLine(t))")
    } catch { say("session.buyProduct codeOffer error \(errDesc(error))") }
    do {
        let past = Date(timeIntervalSinceNow: -86400 * 45)
        let t = try await s.buyProduct(identifier: lite, options: [Product.PurchaseOption.purchaseDate(past)])
        say("session.buyProduct backdated(45d) -> \(txLine(t))")
    } catch { say("session.buyProduct backdated error \(errDesc(error))") }
    await dumpStatus("offers", group: plusGroup)
    await dumpAll("offers")
}

final class SK1: NSObject, SKProductsRequestDelegate, SKPaymentTransactionObserver {
    var cont: CheckedContinuation<Void, Never>?
    var req: SKProductsRequest?
    var got: [SKProduct] = []
    func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        got = response.products
        say("SK1 products=\(response.products.count) invalid=\(response.invalidProductIdentifiers)")
        for p in response.products.sorted(by: { $0.productIdentifier < $1.productIdentifier }) {
            var s = "  SKProduct \(p.productIdentifier) title=\(p.localizedTitle) price=\(p.price) locale=\(p.priceLocale.identifier) family=\(p.isFamilyShareable)"
            if let per = p.subscriptionPeriod { s += " period=\(per.numberOfUnits)u\(per.unit.rawValue) group=\(p.subscriptionGroupIdentifier ?? "nil")" }
            if let i = p.introductoryPrice { s += " intro{\(i.price) mode=\(i.paymentMode.rawValue) n=\(i.numberOfPeriods) type=\(i.type.rawValue)}" }
            for d in p.discounts { s += " discount{id=\(d.identifier ?? "nil") \(d.price) mode=\(d.paymentMode.rawValue) n=\(d.numberOfPeriods) type=\(d.type.rawValue)}" }
            say(s)
        }
    }
    func requestDidFinish(_ request: SKRequest) { say("SK1 request finished \(type(of: request))"); cont?.resume(); cont = nil }
    func request(_ request: SKRequest, didFailWithError error: Error) { say("SK1 request failed \(errDesc(error))"); cont?.resume(); cont = nil }
    func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        for t in transactions {
            say("SK1 tx state=\(t.transactionState.rawValue) product=\(t.payment.productIdentifier) id=\(t.transactionIdentifier ?? "nil") orig=\(t.original?.transactionIdentifier ?? "nil") date=\(t.transactionDate?.timeIntervalSince1970 ?? 0) err=\(t.error.map { errDesc($0) } ?? "nil")")
            if t.transactionState != .purchasing && t.transactionState != .deferred { queue.finishTransaction(t); say("SK1 finished \(t.transactionIdentifier ?? "nil")") }
        }
    }
    func paymentQueue(_ queue: SKPaymentQueue, removedTransactions transactions: [SKPaymentTransaction]) { say("SK1 removed \(transactions.count)") }
    func paymentQueueRestoreCompletedTransactionsFinished(_ queue: SKPaymentQueue) { say("SK1 restore finished") }
    func paymentQueue(_ queue: SKPaymentQueue, restoreCompletedTransactionsFailedWithError error: Error) { say("SK1 restore failed \(errDesc(error))") }
}

func phaseSK1() async {
    session?.resetToDefaultState(); session?.clearTransactions(); session?.disableDialogs = true
    let o = SK1()
    say("SK1 canMakePayments=\(SKPaymentQueue.canMakePayments()) storefront=\(SKPaymentQueue.default().storefront.map { "\($0.countryCode) \($0.identifier)" } ?? "nil")")
    SKPaymentQueue.default().add(o)
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        o.cont = c
        let r = SKProductsRequest(productIdentifiers: Set(allIDs + ["dev.ycode.skprobe.bogus"]))
        r.delegate = o; o.req = r; r.start()
    }
    for id in [coins, pro, monthly] {
        if let p = o.got.first(where: { $0.productIdentifier == id }) {
            let pay = SKMutablePayment(product: p); pay.applicationUsername = "ycode-user"
            SKPaymentQueue.default().add(pay)
            await sleep(4)
        }
    }
    say("SK1 restore")
    SKPaymentQueue.default().restoreCompletedTransactions()
    await sleep(4)
    if let u = Bundle.main.appStoreReceiptURL {
        let d = try? Data(contentsOf: u)
        say("SK1 receipt path=\(u.path) bytes=\(d?.count ?? -1) head=\(d?.prefix(4).map { String(format: "%02x", $0) }.joined() ?? "")")
        if let d { try? d.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("receipt.bin")) }
    }
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        o.cont = c
        let r = SKReceiptRefreshRequest(); r.delegate = o; r.start()
    }
    await dumpAll("SK1")
    SKPaymentQueue.default().remove(o)
}

@MainActor func phaseUI() async {
    session?.disableDialogs = false
    await load()
    let which = arg("ui") ?? "buy"
    guard let scene = rootVC?.view.window?.windowScene else { say("no scene"); return }
    switch which {
    case "buy": _ = await buy(arg("product") ?? coins, tag: "ui-buy")
    case "refund":
        if let r = await Transaction.latest(for: arg("product") ?? pro) {
            do { let st = try await tx(r).beginRefundRequest(in: scene); say("refund request status=\(st)") } catch { say("refund request error \(errDesc(error))") }
        } else { say("no transaction to refund") }
    case "manage":
        do { try await AppStore.showManageSubscriptions(in: scene); say("manage subscriptions returned") } catch { say("manage error \(errDesc(error))") }
    case "redeem":
        do { try await AppStore.presentOfferCodeRedeemSheet(in: scene); say("redeem sheet returned") } catch { say("redeem error \(errDesc(error))") }
    case "review":
        AppStore.requestReview(in: scene); say("requestReview called"); await sleep(10)
    default: break
    }
    await dumpAll("ui")
}

@MainActor func runProbe() async {
    say("StoreProbe start phase=\(arg("phase") ?? "env") bundle=\(Bundle.main.bundleIdentifier ?? "?") args=\(args.dropFirst().joined(separator: " "))")
    Task.detached {
        for await u in Transaction.updates { dumpTx("UPDATE", u, jws: false) }
    }
    Task.detached {
        for await s in Storefront.updates { say("STOREFRONT UPDATE \(s.countryCode)") }
    }
    makeSession()
    switch arg("phase") ?? "env" {
    case "env": await phaseEnv()
    case "products": await phaseProducts()
    case "buy": await phaseBuy()
    case "relaunch": await phaseRelaunch()
    case "finish": await phaseFinishAll()
    case "sub": await phaseSub()
    case "refund": await phaseRefund()
    case "ask": await phaseAsk()
    case "fail": await phaseFail()
    case "offers": await phaseOffers()
    case "sk1": await phaseSK1()
    case "ui": await phaseUI()
    case "wait": await sleep(Double(arg("wait") ?? "30") ?? 30); await dumpAll("wait")
    default: say("unknown phase")
    }
    say("DONE")
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: ws)
        let vc = UIViewController()
        vc.view.backgroundColor = .systemTeal
        let l = UILabel(frame: CGRect(x: 20, y: 120, width: 360, height: 60))
        l.text = "StoreProbe " + (arg("phase") ?? "env"); l.font = .boldSystemFont(ofSize: 28)
        vc.view.addSubview(l)
        w.rootViewController = vc
        w.makeKeyAndVisible()
        window = w
        rootVC = vc
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await runProbe()
        }
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        c.delegateClass = SceneDelegate.self
        return c
    }
}
