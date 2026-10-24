// Test support: our catalog (plan.md §3.1), a store on a manual clock, and an
// optional OpenSSL runner for independent verification.
import Foundation
import StoreKitConfiguration
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
    static let plus = "200000001"
    static let extra = "200000002"
    static let app = "dev.ycode.skprobe"
}

func probeConfiguration(storefront: String = "USA", locale: String = "en_US", timeRate: Int = 1004) -> StoreConfiguration {
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
        settings: Settings(storefront: storefront, locale: locale, timeRate: timeRate, disableDialogs: true),
        appPolicies: AppPolicies(eula: "", policies: []))
}

/// 2026-10-19 12:00:00 UTC.
let referenceStart = Date(timeIntervalSince1970: 1_792_411_200)
let vendorID = UUID(uuidString: "6A1D3C2E-0F00-4B6B-9C1D-5E0D7C4C9A11")!
let fixedNonce = UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301")!

func makeStore(storefront: String = "USA", locale: String = "en_US") -> (ManualClock, StoreDevice, AppTestStore) {
    let clock = ManualClock(referenceStart)
    let device = StoreDevice(clock: clock, timeZone: TimeZone(identifier: "America/New_York")!)
    let store = device.store(for: ID.app)
    store.installConfiguration(probeConfiguration(storefront: storefront, locale: locale))
    return (clock, device, store)
}

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-storekit-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Runs `openssl` from PATH, if there is one. Returns nil when OpenSSL is not installed.
func openssl(_ arguments: [String]) -> (status: Int32, output: String)? {
    let path = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":")
        .map { "\($0)/openssl" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    guard let path else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = arguments
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Whether the OpenSSL on PATH is OpenSSL 3 (LibreSSL lacks some commands used here).
let hasOpenSSL3: Bool = openssl(["version"])?.output.hasPrefix("OpenSSL 3") ?? false

/// The verification failure `body` throws, if any.
func failureReason(_ body: () throws -> Void) -> VerificationFailureReason? {
    do { try body(); return nil } catch let e as VerificationFailure { return e.reason } catch { return nil }
}
