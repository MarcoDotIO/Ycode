// Ycode extension: the process's connection to the open local store
// (design.md §4 items 4–6). The StoreKit API talks to the `AppTestStore` of
// one bundle identifier on one `StoreDevice`, signs what it returns with the
// device identity, and verifies it like a client would.
import Foundation
import StoreKitConfiguration
import StoreKitEngine
import StoreKitSigning

/// The open StoreKit runtime of this process.
///
/// `YcodeStoreKit.shared` is built from the environment on first use:
///
/// | Variable | Meaning |
/// |---|---|
/// | `YCODE_STOREKIT_DIRECTORY` | persistence root (the device's store); unset keeps everything in memory |
/// | `YCODE_STOREKIT_BUNDLE_ID` | the app's bundle identifier (else the main bundle's, else the process name) |
/// | `YCODE_STOREKIT_APP_VERSION` | `CFBundleVersion` for the app transaction and receipt (else the main bundle's, else `1`) |
///
/// Tests and hosts install their own with `YcodeStoreKit.configure(_:)`.
public final class YcodeStoreKit: @unchecked Sendable {
    public let device: StoreDevice
    public let bundleID: String
    /// `identifierForVendor` / `AppStore.deviceVerificationID`.
    public let vendorID: UUID
    public let applicationVersion: String
    /// The device's JWS identity (formats.md §2.1).
    public let jwsIdentity: SigningIdentity
    /// The device's StoreKit 1 receipt identity (formats.md §3).
    public let receiptIdentity: SigningIdentity
    /// Where the StoreKit 1 receipt is written (`<app data>/StoreKit/receipt`); nil keeps it in memory only.
    public let receiptURL: URL?
    /// Queue for StoreKit 1 delegate and observer callbacks.
    public var callbackQueue: DispatchQueue = .main

    /// Shows a purchase confirmation (when dialogs are enabled); `false` cancels.
    /// Ycode's own sheet; the default confirms at once (no UI on a headless host).
    public var confirmPurchase: @Sendable (PurchaseConfirmation) async -> Bool = { _ in true }
    /// Shows a store alert ("Can't Complete This Purchase", "Unable to Purchase").
    public var presentAlert: @Sendable (StoreAlert) async -> Void = { _ in }

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<VerificationResult<Transaction>>.Continuation] = [:]
    private var observerToken: UUID?
    private var ticker: Task<Void, Never>?
    private var receiptData: Data?
    private var alertLog: [StoreAlert] = []

    /// - Parameters:
    ///   - directory: persistence root for the device (`StoreDevice.directory`) and its signing identities.
    public init(
        device: StoreDevice, bundleID: String, vendorID: UUID = UUID(), applicationVersion: String = "1",
        receiptURL: URL? = nil
    ) throws {
        self.device = device
        self.bundleID = bundleID
        self.vendorID = vendorID
        self.applicationVersion = applicationVersion
        self.receiptURL = receiptURL
        let identities = device.directory?.appendingPathComponent("_signing", isDirectory: true)
        let now = device.clock.now()
        jwsIdentity = try SigningIdentity.deviceJWSIdentity(directory: identities, now: now)
        receiptIdentity = try SigningIdentity.deviceReceiptIdentity(directory: identities, now: now)
    }

    private static let sharedLock = NSLock()
    nonisolated(unsafe) private static var current: YcodeStoreKit?

    /// The runtime the StoreKit API uses.
    public static var shared: YcodeStoreKit {
        sharedLock.withLock {
            if let current { return current }
            let made = makeFromEnvironment()
            current = made
            return made
        }
    }

    /// Replaces the runtime the StoreKit API uses.
    public static func configure(_ runtime: YcodeStoreKit) {
        sharedLock.withLock {
            current?.stop()
            current = runtime
        }
    }

    static func makeFromEnvironment() -> YcodeStoreKit {
        let env = ProcessInfo.processInfo.environment
        let dir = env["YCODE_STOREKIT_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let bundleID = env["YCODE_STOREKIT_BUNDLE_ID"] ?? Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let version = env["YCODE_STOREKIT_APP_VERSION"]
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
        var vendor = UUID()
        if let dir {
            let url = dir.appendingPathComponent("_vendor").appendingPathComponent(bundleID)
            if let text = try? String(contentsOf: url, encoding: .utf8), let v = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                vendor = v
            } else {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? vendor.uuidString.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        let device = StoreDevice(directory: dir)
        let receipt = dir?.appendingPathComponent(bundleID).appendingPathComponent("StoreKit/receipt")
        // Generating a key cannot fail in practice; fall back to an in-memory device if the directory is unusable.
        if let made = try? YcodeStoreKit(device: device, bundleID: bundleID, vendorID: vendor, applicationVersion: version, receiptURL: receipt) {
            return made
        }
        return try! YcodeStoreKit(device: StoreDevice(), bundleID: bundleID, vendorID: vendor, applicationVersion: version)
    }

    /// The app's local store.
    public var store: AppTestStore { device.store(for: bundleID) }

    var signer: StoreSigner { StoreSigner(identity: jwsIdentity, bundleID: bundleID, vendorID: vendorID) }

    var now: Date { device.clock.now() }

    /// Alerts shown so far (newest last).
    public var alerts: [StoreAlert] { lock.withLock { alertLog } }

    func show(_ alert: StoreAlert) async {
        lock.withLock { alertLog.append(alert) }
        await presentAlert(alert)
    }

    // MARK: Signing and verification

    func verifier() -> JWSVerifier { JWSVerifier(requiredPayloadKeys: []) }

    func verificationResults(_ records: [TransactionRecord]) -> [VerificationResult<Transaction>] {
        let simulated = store.simulatedError(for: .verification)
        guard let signed = try? signer.sign(records, at: now, simulated: simulated) else { return [] }
        return signed.map { verify($0, simulated: simulated, make: Transaction.init(jws:payload:)) }
    }

    func verificationResult(_ record: TransactionRecord) -> VerificationResult<Transaction>? { verificationResults([record]).first }

    func verify<T>(_ jws: String, simulated: SimulatedFailure?, make: (String, JSONValue) -> T) -> VerificationResult<T> {
        do {
            let d = try verifier().verify(jws)
            let value = make(jws, d.payload)
            // Simulated chain, encoding and property errors mark the result
            // unverified; revokedCertificate and invalidDeviceVerification left
            // it verified on the reference (testing-session.md §9, open question 7).
            if case .verification(let reason)? = simulated,
               [.invalidCertificateChain, .invalidEncoding, .missingRequiredProperties].contains(reason),
               let e = VerificationResult<T>.VerificationError(reason) {
                return .unverified(value, e)
            }
            return .verified(value)
        } catch {
            let payload = (try? JWS.decode(jws).payload) ?? .object([:])
            return .unverified(make(jws, payload), VerificationResult<T>.VerificationError(error.reason) ?? .invalidSignature)
        }
    }

    // MARK: Updates

    /// A new stream of transaction updates: the unfinished transactions first
    /// (the launch replay, testing-session.md §10 item 5), then live events.
    func updatesStream() -> AsyncStream<VerificationResult<Transaction>> {
        let (stream, continuation) = AsyncStream<VerificationResult<Transaction>>.makeStream()
        let id = UUID()
        let replay = verificationResults(store.unfinishedTransactions().reversed())
        for r in replay { continuation.yield(r) }
        lock.withLock {
            continuations[id] = continuation
            if observerToken == nil {
                observerToken = store.addObserver { [weak self] event in self?.deliver(event) }
            }
            startTickerLocked()
        }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.continuations[id] = nil }
        }
        return stream
    }

    private func deliver(_ event: StoreEvent) {
        guard case .transaction(let record) = event, let result = verificationResult(record) else { return }
        let targets = lock.withLock { Array(continuations.values) }
        for c in targets { c.yield(result) }
    }

    /// With the wall clock, wakes the store when the next renewal is due.
    private func startTickerLocked() {
        guard ticker == nil, device.clock is SystemClock else { return }
        let store = self.store
        ticker = Task.detached { [weak self] in
            while !Task.isCancelled, self != nil {
                let wait = store.nextEventDate().map { max(0.05, min(1.0, $0.timeIntervalSinceNow)) } ?? 1.0
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                store.advance()
            }
        }
    }

    func stop() {
        lock.withLock {
            ticker?.cancel()
            ticker = nil
            if let t = observerToken { store.removeObserver(t) }
            observerToken = nil
            for c in continuations.values { c.finish() }
            continuations = [:]
        }
    }

    // MARK: StoreKit 1 receipt

    /// The current StoreKit 1 receipt bytes, if one was written.
    public var receipt: Data? {
        lock.withLock {
            if let receiptData { return receiptData }
            if let receiptURL { return try? Data(contentsOf: receiptURL) }
            return nil
        }
    }

    /// Writes the receipt (after StoreKit 1 activity or a refresh request).
    @discardableResult
    func writeReceipt() throws -> Data {
        var opaque = [UInt8](repeating: 0, count: 8)
        for i in opaque.indices { opaque[i] = UInt8.random(in: 0...255) }
        let data = try Receipt.build(
            bundleID: bundleID, appVersion: applicationVersion, vendorID: vendorID, opaque: opaque, creationDate: now,
            purchases: store.allTransactions(), identity: receiptIdentity)
        try lock.withLock {
            receiptData = data
            if let receiptURL {
                try FileManager.default.createDirectory(at: receiptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: receiptURL, options: .atomic)
            }
        }
        return data
    }
}

/// What a purchase confirmation sheet shows (simulator-baseline.md §6).
public struct PurchaseConfirmation: Sendable {
    public let product: Product
    public let quantity: Int
    /// "Purchase" for in-app purchases, "Subscribe" for auto-renewable subscriptions.
    public let buttonTitle: String
    /// "[Environment: Xcode]".
    public let environmentNote: String
}

/// The `systemError` payload of the local store.
public enum YcodeStoreSystemError: Error, Hashable, Sendable {
    /// No configuration is installed for the app (`AppTransaction.shared` before any session).
    case noAccount
    case unknown
}
