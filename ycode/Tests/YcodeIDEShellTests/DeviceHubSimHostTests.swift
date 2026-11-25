import Foundation
import Testing
import YcodeDisplayStream
import YcodeIDECore
@testable import YcodeIDEShell
import YcodeSimControl

/// The Linux Device Hub over ycrun's hosts (`DeviceHubSimHostBackend`):
/// the host ycrun set up in the IDE's defaults domain is listed with its
/// devices' states; Start boots as `ycrun simctl boot` does (its pid file,
/// the display server); Shut Down is ycrun's SIGTERM to that pid; this
/// machine is listed only where the placement policy runs devices here.
/// Commands go to a fake runner; nothing logs in anywhere.
@Suite(.serialized) struct DeviceHubSimHostTests {
    final class Runner: SimCommandRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var rules: [(String, SimCommandResult)] = []
        private(set) var calls: [[String]] = []
        func on(_ contains: String, _ status: Int32 = 0, _ text: String = "") {
            lock.withLock { rules.append((contains, SimCommandResult(status: status, text: text))) }
        }
        func run(_ argv: [String], input: Data?, timeout: TimeInterval?) -> SimCommandResult {
            let joined = argv.joined(separator: " ")
            return lock.withLock {
                calls.append(argv)
                return rules.first { joined.contains($0.0) }?.1 ?? SimCommandResult(status: 0)
            }
        }
        var commands: [String] { lock.withLock { calls.map { $0.last ?? "" } } }
    }

    final class Host {
        let runner = Runner()
        let suite = "ycode-hub-simhost-" + UUID().uuidString
        let defaults: UserDefaults
        let dir: URL
        var backgrounds: [[String]] = []
        init() {
            defaults = UserDefaults(suiteName: suite)!
            dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(suite)
        }
        deinit {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        }
        /// What `ycrun remote setup` writes: the IDE's host with one iOS 27.1 runtime.
        func setUpWithYcrun() throws {
            let store = SimHostStore(ide: defaults, file: dir.appendingPathComponent("hosts.json"), environment: ["HOME": "/home/me"])
            var e = SimHostEntry(name: "sim-host", destination: "me@sim-host", dataDirectory: "/data/ycode",
                                 runtimeRoot: "/data/ycode/runtimes/iOS-27.1-24A1/RuntimeRoot")
            e.runtimeVersions[e.runtimeRoot] = "27.1"
            e.runtimePlatforms[e.runtimeRoot] = "iOS"
            try store.save(e, makeDefault: true)
        }
        func backend(_ machine: SimMachine = SimMachine(os: .linux, architecture: "x86_64", kvm: .absent)) -> DeviceHubSimHostBackend {
            let store = SimHostStore(ide: defaults, file: dir.appendingPathComponent("hosts.json"), environment: ["HOME": "/home/me"])
            let env = YcrunEnvironment(machine: machine, store: store, runner: runner, environment: ["HOME": "/home/me", "PATH": "/usr/bin"],
                                       out: { _ in }, err: { _ in }, sleep: { _ in },
                                       background: { [unowned self] a in self.backgrounds.append(a); return {} },
                                       ssh: "/usr/bin/ssh", rsync: "/usr/bin/rsync", macOSRunsLocally: false, executable: "/opt/ycode/bin/ycrun")
            return DeviceHubSimHostBackend(environment: env)
        }
    }

    @Test func theHostYcrunSetUpIsListedWithItsDevicesStates() throws {
        let h = Host()
        try h.setUpWithYcrun()
        let dirs = Dictionary(try #require(h.backend().hostContexts().first).devices.map { ($0.type.id, $0.directory) }, uniquingKeysWith: { a, _ in a })
        let duoDir = try #require(dirs["iphone-duo"]), ipadDir = try #require(dirs["ipad-a16"])
        h.runner.on("st() {", 0, "\(duoDir) Booted\n\(ipadDir) Booting\n")
        let hosts = h.backend().list()
        #expect(hosts.map(\.name) == ["sim-host"])
        let devices = try #require(hosts.first?.devices)
        #expect(!devices.isEmpty)
        // Over ssh, with a key only.
        #expect(h.runner.calls.allSatisfy { $0.first == "/usr/bin/ssh" && $0.contains("BatchMode=yes") && $0.contains("me@sim-host") })
        let states = Dictionary(devices.map { ($0.deviceType, $0.state) }, uniquingKeysWith: { a, _ in a })
        #expect(states["iphone-duo"] == "running")
        #expect(states["ipad-a16"] == "booting")
        #expect(devices.allSatisfy { $0.host == "sim-host" && $0.runtime.hasSuffix("RuntimeRoot") })
    }

    @Test func aHostThatDoesNotAnswerIsOffline() throws {
        let h = Host()
        try h.setUpWithYcrun()
        h.runner.on("st() {", 255, "")
        let hosts = h.backend().list()
        #expect(hosts.first?.offline == true && hosts.first?.devices.isEmpty == true)
    }

    @Test func startBootsAsYcrunDoesAndShutDownSendsSIGTERMToItsPid() throws {
        let h = Host()
        try h.setUpWithYcrun()
        let b = h.backend()
        let duo = try #require(b.list().first?.devices.first { $0.deviceType == "iphone-duo" })
        #expect(b.boot(duo).0)
        let start = try #require(h.runner.commands.last)
        #expect(start.contains("/data/ycode/ycrun/") && start.contains(".pid") && start.contains("nohup setsid"))
        #expect(start.contains("--display-server") && start.contains("/data/ycode/display/"))
        #expect(b.shutdown(duo).0)
        let stop = try #require(h.runner.commands.last)
        #expect(stop.contains("kill -TERM") && stop.contains("/data/ycode/ycrun/") && stop.contains(".pid") && !stop.contains("kill -INT"))
        // A device a run started (no live pid file): the hub says where to stop it.
        h.runner.on("kill -TERM", 3, "")
        let (ok, message) = b.shutdown(duo)
        #expect(!ok && message == DeviceHubSimHostBackend.notOurs(duo.name))
    }

    @Test func theLiveScreenOfAHostDeviceComesThroughAnSSHForward() throws {
        let h = Host()
        try h.setUpWithYcrun()
        let b = h.backend()
        let duo = try #require(b.list().first?.devices.first { $0.deviceType == "iphone-duo" })
        let connect = try #require(b.display(duo))
        #expect(throws: (any Error).self) { _ = try connect() }   // nothing listens on the forward's socket here
        let forward = try #require(h.backgrounds.first)
        #expect(forward.first == "/usr/bin/ssh" && forward.contains("-L") && forward.contains("me@sim-host") && forward.contains("BatchMode=yes"))
        #expect(forward.contains { $0.contains(":/data/ycode/display/") && $0.hasSuffix(".sock") })
        // A second connection reuses the forward; Shut Down ends it.
        _ = try? connect()
        #expect(h.backgrounds.count == 1)
        b.endDisplay(duo)
        _ = try? connect()
        #expect(h.backgrounds.count == 2)
    }

    @Test func thisMachineIsListedOnlyWhereThePlacementPolicyRunsDevicesHere() throws {
        let h = Host()
        // x86-64 Linux: no local host, not even asked.
        _ = h.backend().list()
        #expect(!h.runner.commands.contains { $0.contains("[ -x ") })
        // arm64 Linux with KVM and a launcher in place: "this computer".
        let arm = SimMachine(os: .linux, architecture: "aarch64", kvm: .usable)
        h.runner.on("[ -x ", 0)
        let hosts = h.backend(arm).list()
        #expect(hosts.first?.name == "this computer")
        // arm64 Linux without KVM access: not here.
        let denied = SimMachine(os: .linux, architecture: "aarch64", kvm: .denied)
        #expect(!h.backend(denied).list().contains { $0.name == "this computer" })
    }

    final class FakeLink: DeviceHubBackend, @unchecked Sendable {
        var booted: [String] = []
        func list() -> [DeviceHubHost] {
            [DeviceHubHost(name: "sim-host", devices: [DeviceHubDevice(host: "sim-host", name: "Linked Phone", deviceType: "iphone-duo",
                                                                       runtime: "/r/iOS-27.1-24A1/RuntimeRoot", state: "shutdown")])]
        }
        func boot(_ d: DeviceHubDevice) -> (Bool, String) { booted.append(d.id); return (true, "ok") }
        func shutdown(_ d: DeviceHubDevice) -> (Bool, String) { (true, "ok") }
        func display(_ d: DeviceHubDevice) -> (@Sendable () throws -> DisplayTransport)? { nil }
    }

    @Test func pairedAndYcrunHostsAreListedTogetherWithoutClashingNames() throws {
        let h = Host()
        try h.setUpWithYcrun()
        let link = FakeLink()
        let all = DeviceHubAllHostsBackend(link: link, simHosts: h.backend())
        let hosts = all.list()
        #expect(hosts.map(\.name) == ["sim-host", "sim-host (ssh)"])
        let linked = try #require(hosts[0].devices.first)
        let ssh = try #require(hosts[1].devices.first { $0.deviceType == "iphone-duo" })
        #expect(linked.id != ssh.id)
        _ = all.boot(linked)
        #expect(link.booted == [linked.id])
        _ = all.boot(ssh)
        #expect(h.runner.commands.last?.contains("nohup setsid") == true)
    }
}
