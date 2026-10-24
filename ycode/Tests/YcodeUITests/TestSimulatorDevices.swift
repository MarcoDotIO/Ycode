import Foundation
@testable import YcodeUI

/// The Mac simulator devices the tests make, and the only ones they shut
/// down or delete (specs/ide/run.md §Mac simulator).
///
/// - A test device is named `ycode-test-ide-<pid>-<uuid>` (the `ycode-test-`
///   prefix every Ycode tool uses, `ide-` for this suite, and the pid of the
///   test process that made it), and its UDID is recorded when it is made.
/// - `remove` shuts down and deletes a device only when its current name has
///   the `ycode-test-` prefix **and** this process made that UDID. Anything
///   else is refused: other agents' devices (`ycode-test-L…` of the boot
///   tools, a parallel run of this suite in another checkout) and every
///   device that is not a test device.
/// - `sweepStale` deletes devices that earlier runs of this suite left
///   behind when they were killed: named `ycode-test-ide-<pid>-…` with a pid
///   that is no longer running (and not this process).
enum TestSimulatorDevices {
    static let prefix = "ycode-test-"
    static let suitePrefix = "ycode-test-ide-"
    typealias Runner = @Sendable ([String]) -> (Int32, String)

    /// UDIDs made by this process.
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var udids: Set<String> = []
    }
    private static let registry = Registry()

    static var created: Set<String> { registry.lock.withLock { registry.udids } }
    static func record(_ udid: String) { _ = registry.lock.withLock { registry.udids.insert(udid) } }
    static func forget(_ udid: String) { _ = registry.lock.withLock { registry.udids.remove(udid) } }

    /// A new device name for this process.
    static func newName(pid: Int32 = getpid()) -> String { "\(suitePrefix)\(pid)-\(UUID().uuidString)" }

    /// Whether cleanup may shut down and delete the device.
    static func mayRemove(name: String, udid: String, created: Set<String>) -> Bool {
        name.hasPrefix(prefix) && created.contains(udid)
    }

    /// The pid in `ycode-test-ide-<pid>-<uuid>`, nil for any other name.
    static func suitePID(_ name: String) -> Int32? {
        guard name.hasPrefix(suitePrefix) else { return nil }
        let rest = name.dropFirst(suitePrefix.count)
        guard let dash = rest.firstIndex(of: "-"), let pid = Int32(rest[..<dash]), pid > 0,
              UUID(uuidString: String(rest[rest.index(after: dash)...])) != nil else { return nil }
        return pid
    }

    /// Devices an earlier, killed run of this suite left behind.
    static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    static func staleCandidates(_ devices: [(name: String, udid: String)], ownPID: Int32 = getpid(),
                                isAlive: (Int32) -> Bool = isAlive) -> [String] {
        devices.compactMap { d in
            guard let pid = suitePID(d.name), pid != ownPID, !isAlive(pid) else { return nil }
            return d.udid
        }
    }

    /// Every simulator device (name, UDID) from `simctl list -j devices`.
    static func list(_ run: Runner) -> [(name: String, udid: String)] {
        let (s, out) = run(["list", "-j", "devices"])
        guard s == 0, let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let byRuntime = obj["devices"] as? [String: [[String: Any]]] else { return [] }
        return byRuntime.values.flatMap { $0 }.compactMap { d in
            guard let name = d["name"] as? String, let udid = d["udid"] as? String else { return nil }
            return (name, udid)
        }
    }

    /// Shuts down and deletes a device this process made. Returns false (and
    /// runs neither command) for any other device.
    @discardableResult
    static func remove(udid: String, run: Runner = Simctl.xcrun) -> Bool {
        guard let device = list(run).first(where: { $0.udid == udid }) else {
            forget(udid)  // already gone
            return false
        }
        guard mayRemove(name: device.name, udid: udid, created: created) else {
            FileHandle.standardError.write(Data("TestSimulatorDevices: refusing to remove \(device.name) (\(udid)): not a device this test made\n".utf8))
            return false
        }
        _ = run(["shutdown", udid])
        _ = run(["delete", udid])
        forget(udid)
        return true
    }

    /// Deletes what killed runs of this suite left behind (see the type's note).
    static func sweepStale(run: Runner = Simctl.xcrun, isAlive: (Int32) -> Bool = isAlive) {
        for udid in staleCandidates(list(run), isAlive: isAlive) {
            _ = run(["shutdown", udid])
            _ = run(["delete", udid])
        }
    }
}
