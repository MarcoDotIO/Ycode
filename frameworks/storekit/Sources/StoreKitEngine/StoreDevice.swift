// A device's local store: one `AppTestStore` per bundle identifier, sharing a
// clock, a time zone and (optionally) a directory for persistence
// (simulator-baseline.md §4–§5; design.md §4.2, §4.7).
import Foundation
import StoreKitConfiguration

/// The context a signed promotional offer is checked in.
public struct PromotionalOfferContext: Hashable, Sendable {
    public var bundleID: String
    public var productID: String
    public var appAccountToken: UUID?

    public init(bundleID: String, productID: String, appAccountToken: UUID?) {
        self.bundleID = bundleID
        self.productID = productID
        self.appAccountToken = appAccountToken
    }
}

/// Decides whether a signed promotional offer's signature is valid.
public typealias PromotionalOfferVerifier = @Sendable (SignedPromotionalOffer, PromotionalOfferContext) -> Bool

/// One device's local test store.
public final class StoreDevice: @unchecked Sendable {
    public let clock: any StoreClock
    public let timeZone: TimeZone
    /// Where per-app state is kept; nil keeps everything in memory.
    public let directory: URL?
    public let quirks: EngineQuirks

    private let lock = NSLock()
    private var stores: [String: AppTestStore] = [:]
    private var verifier: PromotionalOfferVerifier = { _, _ in false }

    /// - Parameters:
    ///   - clock: the store's notion of now (inject a `ManualClock` in tests).
    ///   - timeZone: the device time zone; real-time periods are calendar periods in it.
    ///   - directory: persistence root; each app gets `<directory>/<bundle id>/`.
    public init(
        clock: any StoreClock = SystemClock(), timeZone: TimeZone = .current, directory: URL? = nil,
        quirks: EngineQuirks = .reference
    ) {
        self.clock = clock
        self.timeZone = timeZone
        self.directory = directory
        self.quirks = quirks
    }

    /// The Gregorian calendar in the device time zone.
    public var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    /// Checks signed promotional offers. The default rejects every signature
    /// (the reference's behavior without the configuration's key, testing-session.md §5).
    public var promotionalOfferVerifier: PromotionalOfferVerifier {
        get { lock.withLock { verifier } }
        set { lock.withLock { verifier = newValue } }
    }

    /// The store of one app (created on first use; loaded from `directory` if present).
    public func store(for bundleID: String) -> AppTestStore {
        lock.withLock {
            if let s = stores[bundleID] { return s }
            let s = AppTestStore(bundleID: bundleID, device: self)
            stores[bundleID] = s
            return s
        }
    }

    /// The directory of one app's state.
    func appDirectory(_ bundleID: String) -> URL? {
        guard let directory else { return nil }
        let safe = bundleID.unicodeScalars.map { c -> String in
            let ok = CharacterSet.alphanumerics.contains(c) || c == "." || c == "-" || c == "_"
            return ok && c.isASCII ? String(c) : String(format: "%%%02X", c.value)
        }.joined()
        return directory.appendingPathComponent(safe.isEmpty || safe == "." || safe == ".." ? "_" : safe, isDirectory: true)
    }
}
