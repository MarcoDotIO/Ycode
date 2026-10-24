// C-FILE (plan.md §4): parse and re-write our configuration files, every key
// of configuration-file.md, unknown keys kept, byte-exact round trips.
//
// The fixtures are our own data (the catalog of plan.md §3.1) written in the
// text form of configuration-file.md §1 by an independent generator; no
// Apple-produced file is used.
import Foundation
import Testing
@testable import StoreKitConfiguration

func fixtureURL(_ name: String) -> URL {
    Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(name)
}

func fixtureData(_ name: String) throws -> Data { try Data(contentsOf: fixtureURL(name)) }

@Suite("configuration-file.md §1 text form and round trips")
struct RoundTripTests {
    @Test("§1: our files round-trip byte for byte", arguments: [
        "Catalog.storekit", "CatalogSettings.storekit", "CatalogUnknownKeys.storekit",
    ])
    func byteExact(name: String) throws {
        let data = try fixtureData(name)
        let doc = try ConfigurationDocument(data: data)
        #expect(doc.data() == data)
        // And through a second cycle.
        #expect(try ConfigurationDocument(data: doc.data()).data() == data)
    }

    @Test("§1, §8: key order is irrelevant to readers; the store's copy (other order, appName) reads as the same file")
    func storeCopy() throws {
        let catalog = try StoreConfiguration(data: fixtureData("Catalog.storekit"))
        var copy = try StoreConfiguration(data: fixtureData("CatalogStoreCopy.storekit"))
        #expect(copy.appName == "StoreProbe")
        copy.appName = nil
        #expect(copy == catalog)
        // Written back, the copy takes the canonical (sorted) form.
        #expect(copy.data() == (try fixtureData("Catalog.storekit")))
    }

    @Test("§1: the writer's layout: two-space indent, ' : ', sorted keys, empty containers on three lines")
    func layout() {
        let value = JSONValue.object([
            "b": .array([]), "a": .object([:]), "_c": .int(1),
            "d": .array([.string("x"), .bool(true), .null]),
            "B": .string("upper"),
        ])
        let text = JSONWriter().string(value)
        #expect(text == """
            {
              "B" : "upper",
              "_c" : 1,
              "a" : {

              },
              "b" : [

              ],
              "d" : [
                "x",
                true,
                null
              ]
            }
            """)
    }

    @Test("§1: string escapes (quote, backslash, slash, controls) and non-ASCII text written as UTF-8")
    func escapes() throws {
        let s = "q\"b\\s/n\nt\tc\u{1}é😀"
        let text = JSONWriter().string(.string(s))
        #expect(text == "\"q\\\"b\\\\s\\/n\\nt\\tc\\u0001é😀\"")
        #expect(try JSONParser.parse(text) == .string(s))
        #expect(JSONWriter(escapeSlashes: false).string(.string("a/b")) == "\"a/b\"")
        // \u escapes and surrogate pairs are read.
        #expect(try JSONParser.parse("\"\\u00e9\\ud83d\\ude00\"") == .string("é😀"))
    }

    @Test("Numbers keep their literal text")
    func numbers() throws {
        let v = try JSONParser.parse("[1.50, -2e3, 0, 10]")
        #expect(JSONWriter().string(v) == "[\n  1.50,\n  -2e3,\n  0,\n  10\n]")
    }

    @Test("Syntax errors report line and column; a non-object top level is rejected")
    func errors() {
        do {
            _ = try StoreConfiguration(data: Data("{\n  \"a\" : 1\n  \"b\" : 2\n}".utf8))
            Issue.record("no error")
        } catch let ConfigurationReadError.syntax(e) {
            #expect(e.line == 3 && e.column == 3 && e.message == "expected ',' or '}'")
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(throws: ConfigurationReadError.notAnObject) { try StoreConfiguration(data: Data("[]".utf8)) }
        #expect(throws: ConfigurationReadError.self) { try StoreConfiguration(data: Data("{} x".utf8)) }
    }

    @Test("A trailing newline is remembered per file")
    func trailingNewline() throws {
        #expect(try ConfigurationDocument(data: fixtureData("Catalog.storekit")).trailingNewline == false)
        #expect(try ConfigurationDocument(data: fixtureData("CatalogUnknownKeys.storekit")).trailingNewline == true)
    }
}

@Suite("configuration-file.md §2–§7: every key")
struct KeyTests {
    let c: StoreConfiguration

    init() throws { c = try StoreConfiguration(data: fixtureData("Catalog.storekit")) }

    @Test("§2 top level")
    func topLevel() {
        #expect(c.identifier == "5C0DE0A1")
        #expect(c.version == Version(major: 4, minor: 0))
        #expect(c.products?.count == 2)
        #expect(c.nonRenewingSubscriptions?.count == 1)
        #expect(c.subscriptionGroups?.count == 2)
        #expect(c.appName == nil)
        #expect(c.extra.isEmpty)
        #expect(!c.isSynchronized)
        #expect(c.allProducts.map(\.productID) == [
            "dev.ycode.skprobe.coins100", "dev.ycode.skprobe.pro", "dev.ycode.skprobe.season",
            "dev.ycode.skprobe.plus.monthly", "dev.ycode.skprobe.plus.yearly", "dev.ycode.skprobe.plus.lite",
            "dev.ycode.skprobe.extra.weekly",
        ])
    }

    @Test("§3 product object")
    func product() {
        let coins = c.products![0]
        #expect(coins.type == .consumable)
        #expect(coins.productID == "dev.ycode.skprobe.coins100")
        #expect(coins.referenceName == "100 Probe Coins")
        #expect(coins.internalID == "100000001")
        #expect(coins.displayPrice == "0.99")
        #expect(coins.familyShareable == false)
        #expect(coins.localizations == [
            Localization(locale: "en_US", displayName: "100 Probe Coins", description: "A pile of coins for the probe."),
            Localization(locale: "de", displayName: "100 Testmuenzen", description: "Ein Haufen Muenzen fuer die Probe."),
        ])
        #expect(c.products![1].type == .nonConsumable)
        #expect(c.products![1].familyShareable == true)
        #expect(c.nonRenewingSubscriptions![0].type == .nonRenewingSubscription)
        #expect(coins.groupNumber == nil && coins.recurringSubscriptionPeriod == nil)
    }

    @Test("§4 subscription group, §5 subscription, §5.1 offers, §5.2 code offers")
    func subscriptions() {
        let plus = c.subscriptionGroups![0]
        #expect(plus.id == "200000001")
        #expect(plus.name == "Plus")
        #expect(plus.localizations?.first?.displayName == "Ycode Plus")
        let monthly = plus.subscriptions![0]
        #expect(monthly.type == .recurringSubscription)
        #expect(monthly.subscriptionGroupID == "200000001")
        #expect(monthly.groupNumber == 1)
        #expect(monthly.recurringSubscriptionPeriod == "P1M")
        #expect(monthly.introductoryOffer == Offer(internalID: "100000031", paymentMode: .free, subscriptionPeriod: "P1W", numberOfPeriods: 1))
        #expect(monthly.adHocOffers == [Offer(
            internalID: "100000032", offerID: "plus.promo3", referenceName: "Three cheaper months", paymentMode: .payAsYouGo,
            subscriptionPeriod: "P1M", numberOfPeriods: 3, displayPrice: "1.99")])
        #expect(monthly.codeOffers == [Offer(
            internalID: "100000033", referenceName: "CODEFREE", paymentMode: .free, subscriptionPeriod: "P1M",
            numberOfPeriods: 1, eligibility: ["new", "existing", "expired"], isStackable: true)])
        #expect(monthly.winbackOffers == [])
        #expect(plus.subscriptions![2].groupNumber == 2)
        #expect(plus.subscriptions![2].introductoryOffer?.paymentMode == .payAsYouGo)
        let extra = c.subscriptionGroups![1]
        #expect(extra.name == "Extra" && extra.localizations == [])
        #expect(extra.subscriptions![0].introductoryOffer?.paymentMode == .payUpFront)
    }

    @Test("§6 settings (defaults file and the all-toggles file)")
    func settings() throws {
        #expect(c.settings == Settings(
            storefront: "USA", locale: "en_US", timeRate: 0, askToBuyEnabled: false, billingIssuesEnabled: false,
            renewalBillingIssuesEnabled: false, billingGracePeriodEnabled: false, disableDialogs: true,
            failTransactionsEnabled: false, storeKitErrors: []))
        let s = try StoreConfiguration(data: fixtureData("CatalogSettings.storekit")).settings!
        #expect(s.storefront == "DEU" && s.locale == "de" && s.timeRate == 1004)
        #expect([s.askToBuyEnabled, s.billingIssuesEnabled, s.renewalBillingIssuesEnabled, s.billingGracePeriodEnabled,
                 s.disableDialogs, s.failTransactionsEnabled].allSatisfy { $0 == true })
    }

    @Test("§7 appPolicies")
    func policies() {
        #expect(c.appPolicies == AppPolicies(eula: "", policies: [
            Policy(locale: "en_US", policyText: "", policyURL: "https://example.com/privacy"),
        ]))
    }
}

@Suite("configuration-file.md §2: unknown and synchronization keys are kept")
struct UnknownKeyTests {
    @Test("Unknown keys, wrong-typed known keys, nulls and the sync keys survive parse and write")
    func preserved() throws {
        let c = try StoreConfiguration(data: fixtureData("CatalogUnknownKeys.storekit"))
        #expect(c.isSynchronized)
        #expect(c.extra["_developerTeamID"] == .string("TEAMID0001"))
        #expect(c.extra["_lastSynchronizedDate"] == .number(JSONNumber(literal: "781234567.25")))
        #expect(c.extra["futureTopLevel"]?["nested"]?.arrayValue?.first == .number(JSONNumber(literal: "1.50")))
        #expect(c.products![0].extra["futureProductKey"] != nil)
        // A known key with an unexpected type stays verbatim in `extra`.
        #expect(c.products![1].displayPrice == nil)
        #expect(c.products![1].extra["displayPrice"] == .number(JSONNumber(literal: "4.99")))
        #expect(c.subscriptionGroups![0].subscriptions![1].extra["introductoryOffer"] == .null)
        #expect(c.settings!.extra["_compatibilityTimeRate"] == .int(0))
        #expect(c.settings!.storeKitErrors?.count == 1)
        #expect(c.subscriptionGroups![0].subscriptions![0].winbackOffers?.count == 1)
    }

    @Test("Editing a known value keeps every unknown key")
    func editKeepsUnknown() throws {
        let original = try fixtureData("CatalogUnknownKeys.storekit")
        var doc = try ConfigurationDocument(data: original)
        doc.configuration.products![0].localizations![0].displayName = "101 Probe Coins"
        let edited = doc.data()
        let text = String(decoding: edited, as: UTF8.self)
        #expect(text.contains("\"displayName\" : \"101 Probe Coins\""))
        // Exactly one line differs.
        let a = String(decoding: original, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        let b = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(a.count == b.count)
        #expect(zip(a, b).filter { $0 != $1 }.count == 1)
        var reread = try ConfigurationDocument(data: edited)
        reread.configuration.products![0].localizations![0].displayName = "100 Probe Coins"
        #expect(reread.data() == original)
    }
}

@Suite("Template (ide.md §6 item 2)")
struct TemplateTests {
    @Test("A new file: default settings, empty lists, version 4.0, a fresh identifier")
    func template() {
        let t = StoreConfiguration.template(identifier: "0A1B2C3D")
        #expect(t.validate().isEmpty)
        #expect(String(decoding: t.data(), as: UTF8.self) == """
            {
              "appPolicies" : {
                "eula" : "",
                "policies" : [

                ]
              },
              "identifier" : "0A1B2C3D",
              "nonRenewingSubscriptions" : [

              ],
              "products" : [

              ],
              "settings" : {
                "_askToBuyEnabled" : false,
                "_billingGracePeriodEnabled" : false,
                "_billingIssuesEnabled" : false,
                "_disableDialogs" : false,
                "_failTransactionsEnabled" : false,
                "_locale" : "en_US",
                "_renewalBillingIssuesEnabled" : false,
                "_storeKitErrors" : [

                ],
                "_storefront" : "USA",
                "_timeRate" : 0
              },
              "subscriptionGroups" : [

              ],
              "version" : {
                "major" : 4,
                "minor" : 0
              }
            }
            """)
    }

    @Test("Identifiers are 8 uppercase hexadecimal digits")
    func identifiers() {
        for _ in 0..<50 {
            let id = StoreConfiguration.newIdentifier()
            #expect(id.count == 8 && id.allSatisfy { $0.isHexDigit && !$0.isLowercase })
        }
    }
}
