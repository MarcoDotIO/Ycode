import Foundation
@testable import YcodeSimControl
import YcodeIDECore

/// Answers commands by the first rule whose text the command contains, and records every call.
final class FakeRunner: SimCommandRunner, @unchecked Sendable {
    struct Rule { var contains: String; var result: SimCommandResult }
    private let lock = NSLock()
    private var rules: [Rule] = []
    private(set) var calls: [[String]] = []
    private(set) var inputs: [Data?] = []

    func on(_ contains: String, _ status: Int32 = 0, _ text: String = "", err: String = "") {
        lock.withLock { rules.append(Rule(contains: contains, result: SimCommandResult(status: status, text: text, errorText: err))) }
    }

    func on(_ contains: String, data: Data) {
        lock.withLock { rules.append(Rule(contains: contains, result: SimCommandResult(status: 0, output: data))) }
    }

    func run(_ argv: [String], input: Data?, timeout: TimeInterval?) -> SimCommandResult {
        let joined = argv.joined(separator: " ")
        return lock.withLock {
            calls.append(argv)
            inputs.append(input)
            return rules.first { joined.contains($0.contains) }?.result ?? SimCommandResult(status: 0)
        }
    }

    /// The shell commands run (the last argument of each call).
    var commands: [String] { lock.withLock { calls.map { $0.last ?? "" } } }
}

/// A test environment with captured output and its own defaults and hosts file.
final class Harness {
    let runner = FakeRunner()
    let defaults: UserDefaults
    let suite: String
    let dir: URL
    var out: [String] = []
    var err: [String] = []
    var files: [String: Data] = [:]
    var foregrounds: [[String]] = []
    var answers: [String] = []

    init() {
        suite = "ycrun-tests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(suite)
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    var store: SimHostStore { SimHostStore(ide: defaults, file: dir.appendingPathComponent("hosts.json"), environment: ["HOME": "/home/me"]) }

    func env(_ machine: SimMachine = SimMachine(os: .linux, architecture: "x86_64", kvm: .absent), interactive: Bool = false) -> YcrunEnvironment {
        YcrunEnvironment(machine: machine, store: store, runner: runner, environment: ["HOME": "/home/me", "PATH": "/usr/bin"],
                         out: { [unowned self] in self.out.append($0) }, err: { [unowned self] in self.err.append($0) },
                         outData: { [unowned self] in self.files["-"] = $0 }, writeFile: { [unowned self] in self.files[$0] = $1 },
                         ask: interactive ? { [unowned self] _ in self.answers.isEmpty ? nil : self.answers.removeFirst() } : nil,
                         sleep: { _ in }, foreground: { [unowned self] a, _ in self.foregrounds.append(a); return 0 },
                         background: { _ in {} }, ssh: "/usr/bin/ssh", rsync: "/usr/bin/rsync", macOSRunsLocally: false, executable: "/opt/ycode/bin/ycrun")
    }

    /// The IDE names a host with one iOS 27.1 runtime.
    func configureRemote(destination: String = "me@sim-host", data: String = "/data/ycode") {
        var s = RemoteSimulatorSettings(destination: destination, dataDirectory: data, runtimeRoot: "/data/ycode/runtimes/iOS-27.1-24A1/RuntimeRoot",
                                        simdPath: data + "/bin/ycode-sim")
        s.save(defaults)
        RemoteSimulatorSettings.saveRuntimeVersion("27.1", root: s.runtimeRoot, defaults)
        RemoteSimulatorSettings.saveRuntimePlatform("iOS", root: s.runtimeRoot, defaults)
    }

    static let linuxARM = SimMachine(os: .linux, architecture: "aarch64", kvm: .usable)
    static let linuxX86 = SimMachine(os: .linux, architecture: "x86_64", kvm: .absent)
    static let mac = SimMachine(os: .macOS, architecture: "arm64", kvm: .notApplicable)
}
