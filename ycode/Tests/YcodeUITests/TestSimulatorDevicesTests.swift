import Foundation
import Testing

/// The test-device cleanup removes only devices this process made with the
/// `ycode-test-` prefix (`TestSimulatorDevices`). A fake simctl: no real
/// simulator is listed, shut down or deleted here.
@Suite struct TestSimulatorDevicesTests {
    final class FakeSimctl: @unchecked Sendable {
        let lock = NSLock()
        var calls: [[String]] = []
        let devices: [(String, String)]
        init(_ devices: [(String, String)]) { self.devices = devices }
        var run: TestSimulatorDevices.Runner {
            { [self] args in
                lock.withLock { calls.append(args) }
                guard args.first == "list" else { return (0, "") }
                let list = devices.map { ["name": $0.0, "udid": $0.1, "state": "Shutdown"] }
                let data = try! JSONSerialization.data(withJSONObject: ["devices": ["com.apple.CoreSimulator.SimRuntime.iOS-27-1": list]])
                return (0, String(decoding: data, as: UTF8.self))
            }
        }
        var removals: [[String]] { lock.withLock { calls.filter { $0.first == "shutdown" || $0.first == "delete" } } }
    }

    @Test func cleanupRefusesDevicesWithoutThePrefixOrNotMadeHere() {
        let mine = "AAAAAAAA-0000-0000-0000-000000000001"
        let foreignNamed = "AAAAAAAA-0000-0000-0000-000000000002"
        let otherAgent = "AAAAAAAA-0000-0000-0000-000000000003"
        let ownName = TestSimulatorDevices.newName()
        #expect(ownName.hasPrefix("ycode-test-ide-\(getpid())-"))

        // The rule itself.
        #expect(TestSimulatorDevices.mayRemove(name: ownName, udid: mine, created: [mine]))
        #expect(!TestSimulatorDevices.mayRemove(name: "iPhone 17 Pro", udid: foreignNamed, created: [foreignNamed]))
        #expect(!TestSimulatorDevices.mayRemove(name: "ycode-test-L-ladder1", udid: otherAgent, created: []))

        // remove(): a device without the prefix is refused even when its UDID
        // was recorded; a ycode-test- device this process did not make too.
        let fake = FakeSimctl([(ownName, mine), ("iPhone 17 Pro", foreignNamed), ("ycode-test-L-ladder1", otherAgent)])
        TestSimulatorDevices.record(foreignNamed)
        defer { TestSimulatorDevices.forget(foreignNamed) }
        #expect(!TestSimulatorDevices.remove(udid: foreignNamed, run: fake.run))
        #expect(!TestSimulatorDevices.remove(udid: otherAgent, run: fake.run))
        #expect(fake.removals.isEmpty)
        TestSimulatorDevices.record(mine)
        #expect(TestSimulatorDevices.remove(udid: mine, run: fake.run))
        #expect(fake.removals == [["shutdown", mine], ["delete", mine]])
        #expect(!TestSimulatorDevices.created.contains(mine))
    }

    @Test func staleSweepTakesOnlyDeadRunsOfThisSuite() {
        let dead: Int32 = 999_999, live: Int32 = 4242, own = getpid()
        let uuid = "11111111-2222-3333-4444-555555555555"
        let devices: [(name: String, udid: String)] = [
            ("ycode-test-ide-\(dead)-\(uuid)", "U-dead"),
            ("ycode-test-ide-\(live)-\(uuid)", "U-live"),          // a parallel run in another checkout
            ("ycode-test-ide-\(own)-\(uuid)", "U-own"),            // this run: removed by its own defer
            ("ycode-test-L-ladder2", "U-tools"),                   // the boot tools' devices
            ("ycode-test-\(UUID().uuidString)", "U-old-style"),    // no pid: not provably ours
            ("iPhone 17 Pro", "U-user"),
        ]
        #expect(TestSimulatorDevices.staleCandidates(devices, ownPID: own, isAlive: { $0 == live || $0 == own }) == ["U-dead"])
        #expect(TestSimulatorDevices.suitePID("ycode-test-ide-12-\(uuid)") == 12)
        #expect(TestSimulatorDevices.suitePID("ycode-test-ide-x-\(uuid)") == nil)
        #expect(TestSimulatorDevices.suitePID("ycode-test-ide-12-notauuid") == nil)

        let fake = FakeSimctl(devices.map { ($0.name, $0.udid) })
        TestSimulatorDevices.sweepStale(run: fake.run, isAlive: { $0 == live || $0 == own })
        #expect(fake.removals.allSatisfy { $0.last == "U-dead" } && fake.removals.count == 2)
    }
}
