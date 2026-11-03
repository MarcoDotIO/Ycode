import Foundation
import YcodeSubprocess
#if canImport(Glibc)
import Glibc
#endif

/// An advisory lock on a file (`flock`), held until `unlock()` or deinit.
/// Serializes work across processes, e.g. debugger sessions started by
/// test targets that run in parallel.
public final class InterprocessLock: @unchecked Sendable {
    private var fd: Int32

    /// Blocks until the lock at `path` is acquired.
    public init(path: String) {
        fd = Self.open(path)
        if fd >= 0 { _ = flock(fd, LOCK_EX) }
    }

    private init(locked fd: Int32) { self.fd = fd }

    private static func open(_ path: String) -> Int32 {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        #if canImport(Glibc)
        return Glibc.open(path, O_CREAT | O_RDWR, 0o644)
        #else
        return Darwin.open(path, O_CREAT | O_RDWR, 0o644)
        #endif
    }

    /// Acquires without blocking a thread: tries the lock and sleeps
    /// between tries (`poll` seconds). It used to wait in `flock` on a
    /// detached task, which held one of the cooperative pool's threads for
    /// as long as another holder kept the lock (minutes, behind a debugger
    /// test); a dozen waiting tests left the pool no thread for anything
    /// else in the process (streamed replies, language-server start-up).
    public static func acquire(path: String, poll: TimeInterval = 0.05) async -> InterprocessLock {
        let fd = open(path)
        guard fd >= 0 else { return InterprocessLock(locked: fd) }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            // EWOULDBLOCK: held elsewhere; anything else: no lock to take.
            guard errno == EWOULDBLOCK || errno == EINTR else { break }
            // A cancelled task's sleep returns at once: pause the thread
            // instead of spinning (the caller still gets the lock).
            if Task.isCancelled { usleep(useconds_t(poll * 1_000_000)) } else { try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000)) }
        }
        return InterprocessLock(locked: fd)
    }

    public func unlock() {
        guard fd >= 0 else { return }
        _ = flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { unlock() }

    /// Whether this machine can launch a process under the debugger right
    /// now: runs `lldb --batch -o "process launch"` on `executable` and
    /// waits up to `timeout` seconds for it to exit. False when the launch
    /// hangs, e.g. waiting for a debugging authorization that no one can
    /// answer (Developer Mode off). Cached per process and executable.
    public static func canLaunchUnderDebugger(_ executable: String, timeout: TimeInterval = 120) -> Bool {
        probeLock.lock()
        defer { probeLock.unlock() }
        if let cached = probeCache[executable] { return cached }
        MainThreadGuard.blockingCall("lldb launch probe")
        let p = Process()
        #if os(macOS)
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["lldb", "--batch", "-o", "process launch", executable]
        #else
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["lldb", "--batch", "-o", "process launch", executable]
        #endif
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { probeCache[executable] = false; return false }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning {
            p.terminate()
            Thread.sleep(forTimeInterval: 0.5)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            // The half-launched debuggee would otherwise linger.
            let k = Process()
            k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            k.arguments = ["-9", "-f", executable]
            try? k.run()
            k.waitUntilExit()
            probeCache[executable] = false
            lastProblem = "launch probe timed out after \(Int(timeout)) s; Developer Mode " + (developerModeDisabled() ? "disabled" : "enabled")
            return false
        }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let ok = text.contains("exited with status")
        probeCache[executable] = ok
        return ok
    }

    /// `DevToolsSecurity -status` reports Developer Mode disabled (macOS;
    /// false elsewhere or when the tool is missing).
    public static func developerModeDisabled() -> Bool {
        #if os(macOS)
        MainThreadGuard.blockingCall("DevToolsSecurity -status")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/DevToolsSecurity")
        p.arguments = ["-status"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("disabled")
        #else
        return false
        #endif
    }

    /// Why the last probe could not launch (for the skip message).
    nonisolated(unsafe) public private(set) static var lastProblem: String?

    nonisolated(unsafe) private static var probeCache: [String: Bool] = [:]
    private static let probeLock = NSLock()

    /// The lock every lldb-dap end-to-end test takes, shared across test
    /// processes.
    public static var debuggerTestLockPath: String {
        FileManager.default.temporaryDirectory.appendingPathComponent("ycode-lldb-dap-e2e.lock").path
    }
}
