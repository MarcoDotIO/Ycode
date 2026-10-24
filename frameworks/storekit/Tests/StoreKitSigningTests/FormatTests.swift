// C-FORMATS (plan.md §4) part 2: payload keys and value forms (formats.md
// §1–§3), deviceVerification, the receipt, promotional-offer signatures.
import Crypto
import Foundation
import Testing
import StoreKitConfiguration
import StoreKitEngine
@testable import StoreKitSigning

func keys(_ v: JSONValue) -> [String] { JSONWriter.sortedKeys(v.objectValue?.keys ?? [:].keys) }

@Suite("Payloads (formats.md §2.2–§2.4)")
struct PayloadTests {
    let context = SigningContext(bundleID: ID.app, vendorID: vendorID, nonce: fixedNonce, signedDate: 1_792_411_201_000)

    @Test("§2.2 deviceVerification = base64(SHA-384(lower(nonce) + lower(vendor id)))")
    func deviceVerification() {
        #expect(DeviceVerification.value(nonce: fixedNonce, vendorID: vendorID) == "r2Se63VFZB4JeyQXiXbLCveA0+my/Ecg2Fddgw1dkqPVAVX7BIEpwdnH9gih6QdY")
        #expect(Data(base64Encoded: context.deviceVerification)?.count == 48)
    }

    @Test("§2.2 a consumable's payload, byte for byte (keys sorted, integer dates in ms)")
    func consumableGolden() throws {
        let (_, _, store) = makeStore()
        let r = try store.purchase(productID: ID.coins).transaction!
        #expect(JSONWriter.compact(Payloads.transaction(r, context: context)) == """
            {"appTransactionId":"0","bundleId":"dev.ycode.skprobe","currency":"USD",\
            "deviceVerification":"r2Se63VFZB4JeyQXiXbLCveA0+my/Ecg2Fddgw1dkqPVAVX7BIEpwdnH9gih6QdY",\
            "deviceVerificationNonce":"3f2504e0-4f89-41d3-9a0c-0305e82c3301","environment":"Xcode",\
            "inAppOwnershipType":"PURCHASED","originalPurchaseDate":1792411200000,"originalTransactionId":"0","price":990,\
            "productId":"dev.ycode.skprobe.coins100","purchaseDate":1792411200000,"quantity":1,"signedDate":1792411201000,\
            "storeType":"CONSUMER","storefront":"USA","storefrontId":"143441","transactionId":"0","transactionReason":"PURCHASE",\
            "type":"Consumable","webOrderLineItemId":"0"}
            """)
    }

    @Test("§2.2 prices and types of every product; subscription keys; offers; app account token in lower case")
    func values() throws {
        let (clock, _, store) = makeStore()
        let token = UUID(uuidString: "6A1D3C2E-0F00-4B6B-9C1D-5E0D7C4C9A11")!
        var payloads: [JSONValue] = []
        for id in [ID.coins, ID.pro, ID.season, ID.monthly, ID.weekly] {
            let r = try store.purchase(productID: id, options: PurchaseOptions(appAccountToken: token)).transaction!
            payloads.append(Payloads.transaction(r, context: context))
        }
        #expect(payloads.map { $0["price"]?.intValue } == [990, 4990, 2990, 0, 990])
        #expect(payloads.map { $0["type"]?.stringValue } == [
            "Consumable", "Non-Consumable", "Non-Renewing Subscription", "Auto-Renewable Subscription", "Auto-Renewable Subscription",
        ])
        #expect(payloads.allSatisfy { $0["appAccountToken"] == .string("6a1d3c2e-0f00-4b6b-9c1d-5e0d7c4c9a11") })
        let monthly = payloads[3]
        #expect(monthly["subscriptionGroupIdentifier"] == .string(ID.plus))
        #expect(monthly["expiresDate"]?.numberValue?.literal == "1792411210000")
        #expect(monthly["offerType"] == .int(1) && monthly["offerDiscountType"] == .string("FREE_TRIAL"))
        #expect(monthly["offerPeriod"] == .string("P1W") && monthly["offerIdentifier"] == nil)
        #expect(monthly["billingPlanType"] == .string("BILLED_UPFRONT"))
        #expect(payloads[4]["offerDiscountType"] == .string("PAY_UP_FRONT") && payloads[4]["offerPeriod"] == .string("P1M"))
        #expect(payloads[0]["expiresDate"] == nil && payloads[0]["subscriptionGroupIdentifier"] == nil && payloads[0]["offerType"] == nil)
        // A renewal: reason RENEWAL, base price, the original's id and date.
        clock.advance(by: 10)
        let renewal = store.latestTransaction(for: ID.monthly)!
        let p = Payloads.transaction(renewal, context: context)
        #expect(p["transactionReason"] == .string("RENEWAL") && p["price"] == .int(3990))
        #expect(p["originalTransactionId"] == .string("3") && p["originalPurchaseDate"]?.numberValue?.literal == "1792411200000")
        #expect(p["purchaseDate"]?.numberValue?.literal == "1792411210000")
    }

    @Test("§2.2 refund fields: revocationDate, reason 0, REFUND_FULL, 100000")
    func refund() throws {
        let (clock, _, store) = makeStore()
        let r = try store.purchase(productID: ID.pro).transaction!
        clock.advance(by: 1)
        try store.refundTransaction(r.id)
        let p = Payloads.transaction(store.transaction(r.id)!, context: context)
        #expect(p["revocationDate"]?.numberValue?.literal == "1792411201000")
        #expect(p["revocationReason"] == .int(0) && p["revocationType"] == .string("REFUND_FULL"))
        #expect(p["revocationPercentage"] == .int(100_000))
    }

    @Test("§2.3 renewal info after a purchase, and with an offer code pending")
    func renewalInfo() throws {
        let (_, _, store) = makeStore()
        let r = try store.purchase(productID: ID.monthly).transaction!
        var info = Payloads.renewalInfo(store.subscriptionStatuses(groupID: ID.plus)[0].renewal, context: context)
        #expect(keys(info) == [
            "appTransactionId", "autoRenewProductId", "autoRenewStatus", "currency", "deviceVerification", "deviceVerificationNonce",
            "eligibleWinBackOfferIds", "environment", "isInBillingRetryPeriod", "originalTransactionId", "productId",
            "recentSubscriptionStartDate", "renewalBillingPlanType", "renewalDate", "renewalPrice", "signedDate",
        ])
        #expect(info["autoRenewStatus"] == .int(1) && info["renewalPrice"] == .int(3990))
        #expect(info["renewalDate"]?.numberValue?.literal == String(r.expiresDate!))
        #expect(info["renewalBillingPlanType"] == .string("BILLED_UPFRONT") && info["eligibleWinBackOfferIds"] == .array([]))
        _ = try store.purchase(productID: ID.monthly, options: PurchaseOptions(codeOfferReferenceName: "CODEFREE"))
        info = Payloads.renewalInfo(store.subscriptionStatuses(groupID: ID.plus)[0].renewal, context: context)
        #expect(info["offerType"] == .int(3) && info["offerIdentifier"] == .string("CODEFREE"))
        #expect(info["offerDiscountType"] == .string("FREE_TRIAL") && info["offerPeriod"] == .string("P1M") && info["renewalPrice"] == .int(0))
        try store.disableAutoRenew(transactionID: r.id)
        info = Payloads.renewalInfo(store.subscriptionStatuses(groupID: ID.plus)[0].renewal, context: context)
        #expect(info["autoRenewStatus"] == .int(0) && info["expirationIntent"] == .int(1) && info["renewalBillingPlanType"] == nil)
    }

    @Test("§2.4 app transaction payload")
    func appTransaction() {
        let p = Payloads.appTransaction(applicationVersion: "12", context: context)
        #expect(JSONWriter.compact(p) == """
            {"appTransactionId":"0","applicationVersion":"12","bundleId":"dev.ycode.skprobe",\
            "deviceVerification":"r2Se63VFZB4JeyQXiXbLCveA0+my/Ecg2Fddgw1dkqPVAVX7BIEpwdnH9gih6QdY",\
            "deviceVerificationNonce":"3f2504e0-4f89-41d3-9a0c-0305e82c3301","originalApplicationVersion":"12",\
            "originalPlatform":"iOS","originalPurchaseDate":0,"receiptCreationDate":1792411201000,"receiptType":"Xcode",\
            "requestDate":1792411201000}
            """)
    }

    @Test("§2.2: a batch shares nonce, deviceVerification and signedDate; every JWS verifies; invalidSignature simulation")
    func batch() throws {
        let (clock, _, store) = makeStore()
        let identity = try SigningIdentity.generate(now: referenceStart)
        let signer = StoreSigner(identity: identity, bundleID: ID.app, vendorID: vendorID)
        _ = try store.purchase(productID: ID.pro)
        _ = try store.purchase(productID: ID.season)
        let jws = try signer.sign(store.transactionHistory(), at: clock.now())
        let decoded = try jws.map { try JWSVerifier(requiredPayloadKeys: ["transactionId", "signedDate"]).verify($0) }
        #expect(Set(decoded.map { $0.payload["deviceVerificationNonce"] }).count == 1)
        #expect(Set(decoded.map { $0.payload["deviceVerification"] }).count == 1)
        #expect(Set(decoded.map { $0.payload["signedDate"] }).count == 1)
        let bad = try signer.sign(store.transactionHistory(), at: clock.now(), simulated: .verification(.invalidSignature))
        for j in bad {
            #expect(failureReason { _ = try JWSVerifier().verify(j) } == .invalidSignature)
        }
        let app = try JWSVerifier().verify(try signer.signAppTransaction(applicationVersion: "12", at: clock.now()))
        #expect(app.payload["receiptType"] == .string("Xcode"))
    }
}

@Suite("Product JSON (formats.md §1)")
struct ProductJSONTests {
    @Test("A consumable in en_US, byte for byte")
    func coins() throws {
        let (_, _, store) = makeStore()
        let catalog = store.catalog!
        let coins = catalog.product(ID.coins)!
        #expect(String(decoding: ProductJSON.data(coins, catalog: catalog, locale: "en_US", storefront: Storefront.named("USA")), as: UTF8.self) == """
            {"attributes":{"description":{"standard":"A pile of coins."},"icuLocale":"en_US@currency=USD","isFamilyShareable":0,\
            "kind":"Consumable","name":"100 Probe Coins","offerName":"dev.ycode.skprobe.coins100",\
            "offers":[{"currencyCode":"USD","priceFormatted":"$0.99","priceString":"0.99"}]},"id":"100000001","type":"in-apps"}
            """)
    }

    @Test("Subscriptions: billing period, discounts (IntroOffer/AdhocOffer), family id, name and rank")
    func subscription() throws {
        let (_, _, store) = makeStore()
        let catalog = store.catalog!
        let json = ProductJSON.value(catalog.product(ID.monthly)!, catalog: catalog, locale: "en_US", storefront: Storefront.named("USA"))
        let a = json["attributes"]!
        #expect(json["id"] == .string("100000011") && a["kind"] == .string("Auto-Renewable Subscription"))
        #expect(a["subscriptionFamilyId"] == .string(ID.plus) && a["subscriptionFamilyName"] == .string("Ycode Plus"))
        #expect(a["subscriptionFamilyRank"] == .int(1))
        let offer = a["offers"]!.arrayValue![0]
        #expect(offer["type"] == .string("buy") && offer["billingPeriod"] == .string("P1M"))
        #expect(offer["recurringSubscriptionPeriod"] == .string("P1M") && offer["billingPlanType"] == .string("BILLED_UPFRONT"))
        #expect(offer["priceFormatted"] == .string("$3.99") && offer["priceString"] == .string("3.99"))
        let discounts = offer["discounts"]!.arrayValue!
        #expect(discounts.count == 2)
        #expect(discounts[0] == .object([
            "type": .string("IntroOffer"), "modeType": .string("FreeTrial"), "numOfPeriods": .int(1),
            "recurringSubscriptionPeriod": .string("P1W"), "priceFormatted": .string("$0.00"), "priceString": .string("0.00"),
            "billingPlanType": .string("BILLED_UPFRONT"),
        ]))
        #expect(discounts[1]["type"] == .string("AdhocOffer") && discounts[1]["offerId"] == .string("plus.promo3"))
        #expect(discounts[1]["modeType"] == .string("PayAsYouGo") && discounts[1]["numOfPeriods"] == .int(3))
        #expect(discounts[1]["priceString"] == .string("1.99"))
        let weekly = ProductJSON.value(catalog.product(ID.weekly)!, catalog: catalog, locale: "en_US", storefront: Storefront.named("USA"))
        #expect(weekly["attributes"]?["subscriptionFamilyName"] == .string("Extra"))
        #expect(weekly["attributes"]?["isFamilyShareable"] == .int(1))
        #expect(weekly["attributes"]?["offers"]?.arrayValue?[0]["discounts"]?.arrayValue?[0]["modeType"] == .string("PayUpFront"))
    }

    @Test("plan.md §3.2 locale de / DEU: German name and 0,99 €; no description without a de entry")
    func german() throws {
        let (_, _, store) = makeStore(storefront: "DEU", locale: "de")
        let catalog = store.catalog!
        let s = store.settings
        let coins = ProductJSON.value(catalog.product(ID.coins)!, catalog: catalog, locale: s.locale, storefront: s.storefront)
        #expect(coins["attributes"]?["name"] == .string("100 Testmuenzen"))
        #expect(coins["attributes"]?["icuLocale"] == .string("de@currency=EUR"))
        let formatted = coins["attributes"]?["offers"]?.arrayValue?[0]["priceFormatted"]?.stringValue ?? ""
        #expect(formatted.replacingOccurrences(of: "\u{00A0}", with: " ") == "0,99 €")
        let pro = ProductJSON.value(catalog.product(ID.pro)!, catalog: catalog, locale: s.locale, storefront: s.storefront)
        #expect(pro["attributes"]?["name"] == .string("Probe Pro") && pro["attributes"]?["description"] == nil)
        let monthly = ProductJSON.value(catalog.product(ID.monthly)!, catalog: catalog, locale: s.locale, storefront: s.storefront)
        #expect(monthly["attributes"]?["subscriptionFamilyName"] == .string("Plus"))
    }
}

@Suite("StoreKit 1 receipt (formats.md §3)")
struct ReceiptTests {
    func makeReceipt() throws -> (Data, SigningIdentity, [TransactionRecord]) {
        let (_, _, store) = makeStore()
        let coins = try store.purchase(productID: ID.coins).transaction!
        store.finish(transactionID: coins.id)
        _ = try store.purchase(productID: ID.pro)
        _ = try store.purchase(productID: ID.monthly)
        let identity = try SigningIdentity.deviceReceiptIdentity(directory: nil, now: referenceStart)
        let data = try Receipt.build(
            bundleID: ID.app, appVersion: "12", vendorID: vendorID, opaque: [1, 2, 3, 4, 5, 6, 7, 8], creationDate: referenceStart,
            purchases: store.allTransactions(), identity: identity)
        return (data, identity, store.allTransactions())
    }

    @Test("Attributes 0, 1, 2, 3, 4, 5, 8, 12, 17 × n, 21 with their values; finished consumables not listed")
    func attributes() throws {
        let (data, identity, _) = try makeReceipt()
        let r = try DecodedReceipt(data: data, expectedCertificate: identity.certificate)
        #expect(r.attributes.map(\.type) == [0, 1, 2, 3, 4, 5, 8, 12, 17, 17, 21])
        #expect(r.attributes.allSatisfy { $0.version == 1 })
        func string(_ t: Int) throws -> String? { try DERElement.parse(r.values(t)[0]).stringValue }
        #expect(try string(0) == "Xcode")
        #expect(try string(2) == ID.app)
        #expect(try string(3) == "12")
        #expect(try DERElement.parse(r.values(1)[0]).intValue == 0)
        #expect(r.values(4)[0] == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(r.values(5)[0].count == 20)
        #expect(r.values(5)[0] == Receipt.deviceHash(vendorID: vendorID, opaque: [1, 2, 3, 4, 5, 6, 7, 8], bundleIDValue: r.values(2)[0]))
        #expect(try string(8) == "")
        #expect(try string(12) == "2026-10-19T12:00:00Z")
        #expect(try string(21) == "4001-01-01T00:00:00Z")
        let iaps = try r.inAppPurchases()
        #expect(iaps.map { $0.map(\.type) } == [[1701, 1702, 1703, 1704], [1701, 1702, 1703, 1704, 1708, 1719]])
        let monthly = iaps[1]
        #expect(try DERElement.parse(monthly[1].value).stringValue == ID.monthly)
        #expect(try DERElement.parse(monthly[2].value).stringValue == "2")
        #expect(try DERElement.parse(monthly[4].value).stringValue == "2026-10-19T12:00:10Z")
        #expect(try DERElement.parse(monthly[5].value).intValue == 1)
    }

    @Test("Signed by the device's receipt identity: CN=StoreKit, O=StoreKit, OU=StoreKit, C=US, 2020-04-01 to 2040-03-27")
    func signer() throws {
        let (data, identity, _) = try makeReceipt()
        let c = identity.certificate
        #expect(c.subject.description == "CN=StoreKit, O=StoreKit, OU=StoreKit, C=US" && c.issuer == c.subject)
        #expect(c.notBefore == Date(timeIntervalSince1970: 1_585_699_200) && c.notAfter == Date(timeIntervalSince1970: 2_216_419_200))
        // Change one byte of the payload (the first bundle id).
        var tampered = Array(data)
        let needle = Array("dev.ycode".utf8)
        let at = try #require((0..<tampered.count - needle.count).first { Array(tampered[$0..<$0 + needle.count]) == needle })
        tampered[at] ^= 0x01
        #expect(throws: (any Error).self) { try DecodedReceipt(data: Data(tampered)) }
    }

    @Test("OpenSSL verifies the CMS signature and returns the payload", .enabled(if: hasOpenSSL3))
    func openSSLCMS() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (data, identity, _) = try makeReceipt()
        let receipt = dir.appendingPathComponent("receipt")
        let cert = dir.appendingPathComponent("cert.pem")
        let out = dir.appendingPathComponent("payload")
        try data.write(to: receipt)
        try identity.certificate.pem.write(to: cert, atomically: true, encoding: .utf8)
        let r = try #require(openssl([
            "cms", "-verify", "-inform", "DER", "-in", receipt.path, "-CAfile", cert.path, "-binary", "-out", out.path,
            "-attime", "1792411200",
        ]))
        #expect(r.status == 0, "\(r.output)")
        let payload = try Data(contentsOf: out)
        #expect(try DERElement.parse(Array(payload)).tag == 0x31)
    }
}

@Suite("Signed promotional offers (testing-session.md §5 item 2; design.md §5 item 4)")
struct PromotionalOfferTests {
    @Test("An offer signed with a known key is accepted by the store; other keys and edits are rejected")
    func signatures() throws {
        let (_, device, store) = makeStore()
        let key = P256.Signing.PrivateKey()
        device.promotionalOfferVerifier = PromotionalOfferSignature.verifier(keys: ["KEY1": key.publicKey])
        let ctx = PromotionalOfferContext(bundleID: ID.app, productID: ID.monthly, appAccountToken: nil)
        let offer = try PromotionalOfferSignature.sign(
            offerID: "plus.promo3", keyID: "KEY1", nonce: fixedNonce, timestamp: 1_792_411_200_000, context: ctx, key: key)
        #expect(String(decoding: PromotionalOfferSignature.message(offer, context: ctx), as: UTF8.self)
            == "dev.ycode.skprobe\u{2063}KEY1\u{2063}dev.ycode.skprobe.plus.monthly\u{2063}plus.promo3\u{2063}\u{2063}3f2504e0-4f89-41d3-9a0c-0305e82c3301\u{2063}1792411200000")
        // Accepted (the intro offer applies first while eligible, §5 item 3).
        #expect(try store.purchase(productID: ID.monthly, options: PurchaseOptions(signedPromotionalOffer: offer)).transaction?.offer?.type == .introductory)
        var wrongKey = offer
        wrongKey.keyID = "KEY2"
        #expect(throws: StoreFailure.self) { try store.purchase(productID: ID.yearly, options: PurchaseOptions(signedPromotionalOffer: wrongKey)) }
        let verify = PromotionalOfferSignature.verifier(keys: ["KEY1": key.publicKey])
        var edited = offer
        edited.timestamp += 1
        #expect(!verify(edited, ctx))
        #expect(verify(offer, ctx))
        #expect(!verify(offer, PromotionalOfferContext(bundleID: ID.app, productID: ID.monthly, appAccountToken: UUID())))
    }
}
