// T-O3 / T-O4: authorization states and callbacks, usage string and
// entitlement requirements, the no-account mode (simulator-baseline.md §2–§5,
// checklist HK-B01–B08).

import Foundation
import Testing
@testable import HomeKit

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

@Suite("T-O3 authorization (simulator-baseline.md §3)")
@MainActor
struct AuthorizationTests {
    @Test("HK-B01/B02: status 0 at first creation, Allow → 5 on main, then the homes callback with 0 homes")
    func allow() async {
        let prompts = Counter()
        let store = newStore(consent: { _ in prompts.bump(); return true })
        let r = Recorder()
        let m = HMHomeManager(ycodeStore: store, client: client())
        m.delegate = r
        #expect(m.authorizationStatus.rawValue == 0)
        #expect(m.homes.isEmpty)
        await settle(store)
        #expect(r.log == ["auth 5", "homes 0"])
        #expect(r.offMain == 0)
        #expect(m.authorizationStatus == [.determined, .authorized])
        #expect(prompts.value == 1)

        // Later launches: 5 right after init, homes callback, no prompt.
        let r2 = Recorder()
        let m2 = HMHomeManager(ycodeStore: store, client: client())
        m2.delegate = r2
        #expect(m2.authorizationStatus.rawValue == 5)
        await settle(store)
        #expect(r2.log == ["homes 0"])
        #expect(prompts.value == 1)
    }

    @Test("HK-B03/B04: Don't Allow → 1, never a homes callback; later status 1 at init and addHome fails with 47")
    func deny() async {
        let store = newStore(consent: { _ in false })
        let r = Recorder()
        let m = HMHomeManager(ycodeStore: store, client: client())
        m.delegate = r
        await settle(store)
        #expect(r.log == ["auth 1"])
        #expect(m.authorizationStatus == [.determined])

        let r2 = Recorder()
        let m2 = HMHomeManager(ycodeStore: store, client: client())
        m2.delegate = r2
        #expect(m2.authorizationStatus.rawValue == 1)
        await settle(store)
        #expect(r2.log.isEmpty)
        await expectCode(.homeAccessNotAuthorized) { _ = try await m2.addHome(named: "Home") }
        let ns = await withCheckedContinuation { (c: CheckedContinuation<NSError?, Never>) in
            m2.addHome(withName: "Home") { _, e in c.resume(returning: e as NSError?) }
        }
        #expect(ns.map { Array($0.userInfo.keys) } == [NSLocalizedDescriptionKey], "only a localized description (errors.md §2)")
    }

    @Test("HK-B07/B08: without the entitlement, Allow gives 5 but no homes; later launches read 0 and get 47")
    func missingEntitlement() async {
        let store = newStore()
        let r = Recorder()
        let m = HMHomeManager(ycodeStore: store, client: client(entitled: false))
        m.delegate = r
        await settle(store)
        #expect(r.log == ["auth 5"])

        let r2 = Recorder()
        let m2 = HMHomeManager(ycodeStore: store, client: client(entitled: false))
        m2.delegate = r2
        #expect(m2.authorizationStatus.rawValue == 0)
        await settle(store)
        #expect(r2.log.isEmpty)
        await expectCode(.homeAccessNotAuthorized) { _ = try await m2.addHome(named: "Home") }
    }

    @Test("Resetting the recorded answer brings the prompt back (simctl privacy reset analogue)")
    func reset() async {
        let prompts = Counter()
        let store = newStore(consent: { _ in prompts.bump(); return true })
        _ = await loadedManager(store)
        store.resetAuthorization(bundleIdentifier: client().bundleIdentifier)
        let m = HMHomeManager(ycodeStore: store, client: client())
        #expect(m.authorizationStatus.rawValue == 0)
        await settle(store)
        #expect(prompts.value == 2)
        #expect(m.authorizationStatus.rawValue == 5)
    }

    @Test("Answers are per bundle identifier")
    func perBundle() async {
        let store = newStore(consent: { $0.bundleIdentifier.hasSuffix(".yes") })
        let yes = await loadedManager(store, client("local.app.yes"))
        let no = await loadedManager(store, client("local.app.no"))
        #expect(yes.authorizationStatus.rawValue == 5)
        #expect(no.authorizationStatus.rawValue == 1)
    }
}

@Suite("T-O4 no-account mode (simulator-baseline.md §5)")
@MainActor
struct NoAccountTests {
    @Test("HK-B05: authorized, homes callback, every addHome fails with 2040 before name checks, no callbacks")
    func noAccount() async {
        let store = newStore(noAccount: true)
        _ = await loadedManager(store)
        let r = Recorder()
        let m = await loadedManager(store, delegate: r)
        let other = Recorder()
        let watcher = await loadedManager(store, delegate: other)
        #expect(m.authorizationStatus.rawValue == 5)
        #expect(r.log == ["homes 0"])
        for name in ["Home", "Home", "home", "", "!!!", "Second Home"] {
            let (home, error) = await withCheckedContinuation { (c: CheckedContinuation<(HMHome?, NSError?), Never>) in
                m.addHome(withName: name) { h, e in
                    #expect(onMainQueue())
                    c.resume(returning: (h, e as NSError?))
                }
            }
            #expect(home == nil)
            #expect(error?.domain == "HMErrorDomain")
            #expect(error?.code == 2040, "name \(name)")
            #expect(error?.userInfo.count == 1)
        }
        await settle(store)
        #expect(m.homes.isEmpty)
        #expect(other.log == ["homes 0"], "no delegate callbacks follow")
        _ = watcher
    }
}

@Suite("Usage string requirement (simulator-baseline.md §2, HK-B06)")
struct UsageStringTests {
    @Test("Creating a manager without NSHomeKitUsageDescription stops the process")
    func missingUsageStringAborts() async {
        await #expect(processExitsWith: .failure) {
            let store = YcodeLocalHomeStore(configuration: .init())
            _ = HMHomeManager(ycodeStore: store, client: YcodeHomeClient(bundleIdentifier: "local.no-usage",
                                                                         usageDescription: nil))
        }
    }

    @Test("A process without an Info.plist is not held to the requirements")
    func lenientClient() {
        let c = YcodeHomeClient(bundleIdentifier: "local.tool", usageDescription: nil, hasHomeKitEntitlement: false,
                                enforcesRequirements: false)
        let m = HMHomeManager(ycodeStore: YcodeLocalHomeStore(configuration: .init()), client: c)
        #expect(m.authorizationStatus.rawValue == 0)
    }
}
