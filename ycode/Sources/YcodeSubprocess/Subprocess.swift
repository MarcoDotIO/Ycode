import Foundation

/// Runs a command to completion and captures its output. The caller waits,
/// so in debug builds the run is checked against the main thread
/// (`MainThreadGuard`); call it from a background task.
public enum Subprocess {
    public struct Output: Sendable {
        public var status: Int32
        public var stdout: Data
        public var stderr: Data
        public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
        public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    }

    /// Runs `executable` with `arguments`. Standard input is the null
    /// device; standard output and error are read concurrently, so a full
    /// pipe never blocks the child. Throws only when it cannot start.
    /// `environment` nil inherits this process's environment. With
    /// `timeout`, a child still running after that many seconds is
    /// terminated (then killed) and the run throws `TimedOut`, so a caller
    /// never waits for ever on a child that hangs.
    public static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                           currentDirectory: URL? = nil, captureStderr: Bool = true, timeout: TimeInterval? = nil,
                           fileID: StaticString = #fileID, line: UInt = #line) throws -> Output {
        MainThreadGuard.blockingCall("\(URL(fileURLWithPath: executable).lastPathComponent) \(arguments.prefix(3).joined(separator: " "))",
                                     fileID: fileID, line: line)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let environment { p.environment = environment }
        if let currentDirectory { p.currentDirectoryURL = currentDirectory }
        // Close-on-exec pipes: a `Pipe` can leak into a child another thread
        // starts at the same time, and the read below would then wait for
        // that child too (`SpawnPipe`).
        let out = try SpawnPipe(childReads: false), err = try SpawnPipe(childReads: false)
        p.standardOutput = out.childEnd
        p.standardError = captureStderr ? err.childEnd : FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do {
            try p.runWithSignalsUnblocked()
        } catch {
            out.closeChildEnd(); err.closeChildEnd()
            throw error
        }
        out.closeChildEnd()
        err.closeChildEnd()
        let watchdog = timeout.map { Watchdog(process: p, seconds: $0) }
        // stderr on its own thread: reading the two pipes one after the
        // other deadlocks when the child fills the second one first. A
        // thread, not a global queue: on a machine with few cores, callers
        // waiting here can fill the queue's thread pool, the reader never
        // starts, and both sides wait for ever.
        final class Box: @unchecked Sendable { var data = Data() }
        let errBox = Box()
        let group = DispatchGroup()
        if captureStderr {
            let h = err.parentEnd
            group.enter()
            Thread { errBox.data = h.readDataToEndOfFile(); group.leave() }.start()
        }
        let data = out.parentEnd.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        if let watchdog {
            watchdog.finish()
            if watchdog.fired {
                throw TimedOut(command: "\(URL(fileURLWithPath: executable).lastPathComponent) \(arguments.joined(separator: " "))", seconds: watchdog.seconds)
            }
        }
        return Output(status: p.terminationStatus, stdout: data, stderr: errBox.data)
    }

    /// A child outlived its `timeout` and was stopped.
    public struct TimedOut: LocalizedError, CustomStringConvertible {
        public var command: String
        public var seconds: TimeInterval
        public var description: String { "\(command) did not finish within \(Int(seconds)) s and was stopped." }
        public var errorDescription: String? { description }
    }

    /// Stops a child that runs past its deadline: SIGTERM, then SIGKILL two
    /// seconds later. Its own thread, so it fires while the caller waits.
    final class Watchdog: @unchecked Sendable {
        let seconds: TimeInterval
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var firedFlag = false
        var fired: Bool { lock.withLock { firedFlag } }

        init(process: Process, seconds: TimeInterval) {
            self.seconds = seconds
            let pid = process.processIdentifier
            Thread { [self] in
                guard done.wait(timeout: .now() + seconds) == .timedOut else { return }
                lock.withLock { firedFlag = true }
                kill(pid, SIGTERM)
                if done.wait(timeout: .now() + 2) == .timedOut { kill(pid, SIGKILL) }
            }.start()
        }

        func finish() { done.signal() }
    }
}
