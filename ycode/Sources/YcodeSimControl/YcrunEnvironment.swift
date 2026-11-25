// What a ycrun command runs with (specs/ide/ycrun.md §4): the machine, the
// hosts, the program runner, the terminal. Tests give fakes for each.

import Foundation
import YcodeBuild
import YcodeIDECore
import YcodeSubprocess

/// Exit statuses (Ycode decision; specs/ide/ycrun.md §7.4).
public enum YcrunExit {
    public static let ok: Int32 = 0
    public static let failure: Int32 = 1
    /// A usage error (sysexits EX_USAGE).
    public static let usage: Int32 = 64
    /// A verb or option Ycode's simulator does not support yet (sysexits EX_UNAVAILABLE).
    public static let unsupported: Int32 = 69
}

/// A command's failure: its message and exit status.
public struct YcrunError: Error, Equatable, CustomStringConvertible {
    public var description: String
    public var status: Int32
    public init(_ d: String, status: Int32 = YcrunExit.failure) {
        description = d
        self.status = status
    }

    public static func usage(_ d: String) -> YcrunError { YcrunError(d, status: YcrunExit.usage) }

    /// "<what> is not supported by Ycode's simulator yet", with the reason or the alternative.
    public static func unsupported(_ what: String, _ why: String = "") -> YcrunError {
        YcrunError("\(what) is not supported by Ycode's simulator yet" + (why.isEmpty ? "." : ": " + why), status: YcrunExit.unsupported)
    }
}

public struct YcrunEnvironment: @unchecked Sendable {
    public var machine: SimMachine
    public var store: SimHostStore
    public var runner: any SimCommandRunner
    public var environment: [String: String]
    /// Standard output and standard error.
    public var out: (String) -> Void
    public var err: (String) -> Void
    /// Raw bytes to standard output (`io screenshot -`).
    public var outData: (Data) -> Void
    public var writeFile: (String, Data) throws -> Void
    /// A prompt for the setup wizard; nil when the input is not a terminal.
    public var ask: ((String) -> String?)?
    public var sleep: (TimeInterval) -> Void
    /// Runs a program in the foreground with this terminal (the viewer), returning its status.
    public var foreground: ([String], [String: String]) -> Int32
    /// Starts a helper (the display forward) and returns a function that ends it.
    public var background: ([String]) -> (() -> Void)?
    public var ssh: String
    public var rsync: String
    public var macOSRunsLocally: Bool
    /// The tool's own path (`--find`, `--install-link`, the viewer next to it).
    public var executable: String

    public init(machine: SimMachine = .current(), store: SimHostStore = .standard(), runner: any SimCommandRunner = ProcessCommandRunner(),
                environment: [String: String] = ProcessInfo.processInfo.environment,
                out: @escaping (String) -> Void = { print($0) },
                err: @escaping (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
                outData: @escaping (Data) -> Void = { FileHandle.standardOutput.write($0) },
                writeFile: @escaping (String, Data) throws -> Void = { try $1.write(to: URL(fileURLWithPath: $0)) },
                ask: ((String) -> String?)? = nil, sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                foreground: @escaping ([String], [String: String]) -> Int32 = YcrunEnvironment.runForeground,
                background: @escaping ([String]) -> (() -> Void)? = YcrunEnvironment.startBackground,
                ssh: String = HostToolPaths.ssh, rsync: String = HostToolPaths.rsync,
                macOSRunsLocally: Bool = SimPlacementPolicy.macOSRunsLocally,
                executable: String = CommandLine.arguments.first ?? "ycrun") {
        self.machine = machine
        self.store = store
        self.runner = runner
        self.environment = environment
        self.out = out
        self.err = err
        self.outData = outData
        self.writeFile = writeFile
        self.ask = ask
        self.sleep = sleep
        self.foreground = foreground
        self.background = background
        self.ssh = ssh
        self.rsync = rsync
        self.macOSRunsLocally = macOSRunsLocally
        self.executable = executable
    }

    // MARK: Placement and hosts

    public func decide(_ request: SimPlacementRequest) throws -> SimPlacementDecision {
        do {
            return try SimPlacementPolicy.decide(machine: machine, request: request, macOSRunsLocally: macOSRunsLocally)
        } catch let e as SimPlacementError {
            throw YcrunError.usage(e.description)
        }
    }

    public func shell(for entry: SimHostEntry) -> SimShell {
        SimShell(location: entry.isLocal ? .local : .ssh(destination: entry.destination), runner: runner, ssh: ssh, rsync: rsync)
    }

    /// The host a placement names, ready for commands.
    public func context(_ placement: SimPlacement) throws -> SimHostContext {
        switch placement {
        case .local:
            var e = store.localHost()
            let sh = shell(for: e)
            if e.runtimeRoot.isEmpty, let found = discoverRuntimes(e, shell: sh).first {
                e.runtimeRoot = found.root
                e.runtimeVersions[found.root] = found.version
                e.runtimePlatforms[found.root] = found.platform
            }
            return SimHostContext(entry: e, settings: e.remoteSettings, shell: sh)
        case .remote(let name):
            guard let e = store.remoteHost(named: name) else {
                if let name { throw YcrunError("No simulator host named \(name). `ycrun remote list` shows the hosts; `ycrun remote setup` adds one.") }
                throw YcrunError("No simulator host is set up, and devices cannot run on this machine. Set one up with `ycrun remote setup`.")
            }
            return SimHostContext(entry: e, settings: store.settings(for: e), shell: shell(for: e))
        }
    }

    /// The runtimes in a host's runtime folder (`<data>/runtimes`, Ycode's
    /// copies with their marker) and the given roots, newest iOS first.
    public func discoverRuntimes(_ e: SimHostEntry, shell sh: SimShell, extraRoots: [String] = []) -> [SimRuntime] {
        let folder = RuntimeFolders.host(dataDirectory: e.dataDirectory)
        let r = sh.run(RuntimeHostChecker.Command.listRuntimes(folder: folder, extraRoots: extraRoots), timeout: 60)
        guard r.ok else { return [] }
        let records = RuntimeHostChecker.parseListing(r.text, host: e.destination, folder: folder).records
        let rts = records.compactMap { rec -> SimRuntime? in
            guard let root = rec.runtimeRoot else { return nil }
            return SimRuntime(platform: rec.platform.rawValue, version: rec.version, build: rec.build, root: root)
        }
        return rts.sorted { a, b in
            if (a.platform == "iOS") != (b.platform == "iOS") { return a.platform == "iOS" }
            return DestinationCatalog.compareVersions(a.version ?? "0", b.version ?? "0") == .orderedDescending
        }
    }

    // MARK: Processes

    public static func runForeground(_ argv: [String], _ env: [String: String]) -> Int32 {
        var e = ProcessInfo.processInfo.environment
        for (k, v) in env { e[k] = v }
        switch PosixSpawn.spawn([ProcessCommandRunner.resolve(argv[0])] + argv.dropFirst(), environment: e) {
        case .success(let pid): return PosixSpawn.wait(pid)
        case .failure(let why):
            FileHandle.standardError.write(Data("ycrun: cannot run \(argv[0]): \(why)\n".utf8))
            return 127
        }
    }

    /// Starts a program (output dropped) and returns a function that ends
    /// it: SIGTERM to its exact pid, then waits for it.
    public static func startBackground(_ argv: [String]) -> (() -> Void)? {
        let null = open("/dev/null", O_RDWR)
        defer { if null >= 0 { close(null) } }
        guard case .success(let pid) = PosixSpawn.spawn([ProcessCommandRunner.resolve(argv[0])] + argv.dropFirst(),
                                                        stdin: null, stdout: null, stderr: null) else { return nil }
        return { kill(pid, SIGTERM); _ = PosixSpawn.wait(pid) }
    }
}

/// ssh and rsync: the host's (the Flatpak's wrappers inside the package).
public enum HostToolPaths {
    public static var ssh: String { HostTool.path("ssh") }
    public static var rsync: String { HostTool.path("rsync") }
}
