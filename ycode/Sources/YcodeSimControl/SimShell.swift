// Running commands where the simulator lives (specs/ide/ycrun.md §4): the
// same shell command runs on this machine (`/bin/sh -c`) or on a simulator
// host (`ssh -o BatchMode=yes <user@host> <command>`). ssh logs in with a key
// only: BatchMode makes it fail rather than ask for a password, and ycrun
// never asks for, stores or passes one.

import Foundation
import YcodeSubprocess
#if canImport(Glibc)
import Glibc
#endif

/// One finished command.
public struct SimCommandResult: Equatable, Sendable {
    public var status: Int32
    public var output: Data
    public var errorText: String

    public init(status: Int32, output: Data = Data(), errorText: String = "") {
        self.status = status
        self.output = output
        self.errorText = errorText
    }

    public init(status: Int32, text: String, errorText: String = "") {
        self.init(status: status, output: Data(text.utf8), errorText: errorText)
    }

    public var text: String { String(decoding: output, as: UTF8.self) }
    public var ok: Bool { status == 0 }
}

/// Runs a program (tests answer for it).
public protocol SimCommandRunner: Sendable {
    func run(_ argv: [String], input: Data?, timeout: TimeInterval?) -> SimCommandResult
}

extension SimCommandRunner {
    public func run(_ argv: [String]) -> SimCommandResult { run(argv, input: nil, timeout: nil) }
}

/// posix_spawn and waitpid: standard output and standard error kept apart.
///
/// Not Foundation's `Process`: on Linux its wait missed the exit of a shell
/// that left a detached job behind (`simctl boot`'s `nohup setsid … &`): the
/// pipes reached end of file, SIGCHLD arrived, and `waitUntilExit` waited for
/// ever. Here the child is reaped with its own `waitpid`, and it starts with
/// no blocked signals and SIGINT, SIGTERM, SIGHUP and SIGPIPE at their
/// defaults (a Dispatch thread blocks them, and a child would inherit that).
public struct ProcessCommandRunner: SimCommandRunner {
    public init() {}

    public func run(_ argv: [String], input: Data?, timeout: TimeInterval?) -> SimCommandResult {
        guard !argv.isEmpty else { return SimCommandResult(status: 127, errorText: "no program") }
        var outFDs: [Int32] = [-1, -1], errFDs: [Int32] = [-1, -1], inFDs: [Int32] = [-1, -1]
        guard PosixSpawn.pipe(&outFDs), PosixSpawn.pipe(&errFDs), input == nil || PosixSpawn.pipe(&inFDs) else {
            return SimCommandResult(status: 127, errorText: "cannot make a pipe")
        }
        let childIn = input == nil ? nil : inFDs[0]
        let spawned = PosixSpawn.spawn([Self.resolve(argv[0])] + argv.dropFirst(), stdin: childIn, stdout: outFDs[1], stderr: errFDs[1])
        close(outFDs[1]); close(errFDs[1])
        if input != nil { close(inFDs[0]) }
        guard case .success(let pid) = spawned else {
            close(outFDs[0]); close(errFDs[0]); if input != nil { close(inFDs[1]) }
            if case .failure(let why) = spawned { return SimCommandResult(status: 127, errorText: "cannot run \(argv[0]): \(why)") }
            return SimCommandResult(status: 127)
        }
        if let input {
            let fd = inFDs[1]
            Thread {
                input.withUnsafeBytes { raw in
                    var off = 0
                    while off < raw.count {
                        let n = write(fd, raw.baseAddress! + off, raw.count - off)
                        if n <= 0 { if n < 0 && errno == EINTR { continue }; break }
                        off += n
                    }
                }
                close(fd)
            }.start()
        }
        let done = DispatchSemaphore(value: 0)
        if let timeout {
            Thread {
                if done.wait(timeout: .now() + timeout) == .timedOut { kill(pid, SIGTERM) }
            }.start()
        }
        let box = ErrorBox()
        let group = DispatchGroup()
        group.enter()
        let errFD = errFDs[0]
        Thread { box.data = PosixSpawn.readAll(errFD); close(errFD); group.leave() }.start()
        let data = PosixSpawn.readAll(outFDs[0])
        close(outFDs[0])
        group.wait()
        let status = PosixSpawn.wait(pid)
        done.signal()
        return SimCommandResult(status: status, output: data, errorText: String(decoding: box.data, as: UTF8.self))
    }

    final class ErrorBox: @unchecked Sendable { var data = Data() }

    /// A bare program name is looked up on PATH.
    public static func resolve(_ exe: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        guard !exe.contains("/") else { return exe }
        for dir in (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":") {
            let p = "\(dir)/\(exe)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return "/usr/bin/" + exe
    }
}

/// Where a host's commands run, and how files get there.
public struct SimShell: Sendable {
    public enum Location: Equatable, Sendable {
        case local
        case ssh(destination: String)
    }

    public var location: Location
    public var runner: any SimCommandRunner
    public var ssh: String
    public var rsync: String

    public init(location: Location, runner: any SimCommandRunner = ProcessCommandRunner(),
                ssh: String = HostTool.path("ssh"), rsync: String = HostTool.path("rsync")) {
        self.location = location
        self.runner = runner
        self.ssh = ssh
        self.rsync = rsync
    }

    /// ssh options: a key only (never a prompt), a short connect timeout,
    /// keep-alives for long boots.
    public static let sshOptions = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15"]

    /// The program and arguments that run `command` at this location.
    public func argv(_ command: String) -> [String] {
        switch location {
        case .local: return ["/bin/sh", "-c", command]
        case .ssh(let d): return [ssh] + Self.sshOptions + [d, command]
        }
    }

    @discardableResult
    public func run(_ command: String, input: Data? = nil, timeout: TimeInterval? = 120) -> SimCommandResult {
        runner.run(argv(command), input: input, timeout: timeout)
    }

    /// rsync arguments that copy a local folder's contents to `remotePath`
    /// at this location (a local copy for this machine).
    public func uploadArguments(localFolder: String, remotePath: String) -> [String] {
        let src = localFolder.hasSuffix("/") ? localFolder : localFolder + "/"
        switch location {
        case .local: return [rsync, "-a", "--delete", src, remotePath + "/"]
        case .ssh(let d):
            return [rsync, "-az", "--delete", "-e", ([ssh] + Self.sshOptions).joined(separator: " "), src, "\(d):\(remotePath)/"]
        }
    }

    public var isLocal: Bool { location == .local }

    /// The ssh destination, for messages ("this machine" when local).
    public var title: String {
        switch location {
        case .local: return "this machine"
        case .ssh(let d): return d
        }
    }
}

/// POSIX shell single quoting.
public func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// The few process calls ycrun makes itself (`ProcessCommandRunner`).
public enum PosixSpawn {
    public struct SpawnError: Error, CustomStringConvertible { public var description: String }

    /// A close-on-exec pipe.
    static func pipe(_ fds: inout [Int32]) -> Bool {
        #if os(Linux)
        guard Glibc.pipe(&fds) == 0 else { return false }
        #else
        guard Darwin.pipe(&fds) == 0 else { return false }
        #endif
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return true
    }

    /// Starts `argv` (argv[0] a path) with the given descriptors as its
    /// standard streams (nil: inherit this process's), no signal blocked, and
    /// SIGINT, SIGTERM, SIGHUP and SIGPIPE at their defaults.
    public static func spawn(_ argv: [String], stdin: Int32? = nil, stdout: Int32? = nil, stderr: Int32? = nil,
                             environment: [String: String]? = nil) -> Result<pid_t, SpawnError> {
        #if os(Linux)
        var fa = posix_spawn_file_actions_t()
        var attr = posix_spawnattr_t()
        #else
        var fa: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        #endif
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        if let stdin { posix_spawn_file_actions_adddup2(&fa, stdin, 0) }
        if let stdout { posix_spawn_file_actions_adddup2(&fa, stdout, 1) }
        if let stderr { posix_spawn_file_actions_adddup2(&fa, stderr, 2) }
        if stdin == nil && stdout != nil { posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0) }
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attr, &none)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for s in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] { sigaddset(&defaults, s) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        let env = (environment ?? ProcessInfo.processInfo.environment).map { "\($0.key)=\($0.value)" }
        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup($0) } + [nil]
        defer { for p in cArgs { free(p) }; for p in cEnv { free(p) } }
        var pid: pid_t = 0
        let r = posix_spawn(&pid, argv[0], &fa, &attr, cArgs, cEnv)
        return r == 0 ? .success(pid) : .failure(SpawnError(description: String(cString: strerror(r))))
    }

    /// Reads a descriptor to its end.
    static func readAll(_ fd: Int32) -> Data {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 { data.append(contentsOf: buf[0..<n]); continue }
            if n < 0 && errno == EINTR { continue }
            return data
        }
    }

    /// Waits for a child; its exit status (128 + the signal when a signal ended it).
    public static func wait(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR { return 255 }
        }
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }
}
