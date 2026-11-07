import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Runs a command and streams its standard output line by line, for tools
/// that report progress as they work (JSON-lines event streams). Nothing
/// here blocks the caller: the child is read on its own threads.
///
/// Cancelling the task that iterates interrupts the child: SIGINT first, so
/// a tool can end its turn cleanly, then SIGTERM after `interruptGrace`,
/// then SIGKILL. Ending the iteration early (a `break`) does the same, but
/// only once nothing holds the stream any more: the stream ends as
/// cancelled when its last iterator and the stream value itself are gone.
/// For `for try await line in StreamingSubprocess.lines(…)` that is at the
/// `break`; a stream that something else still holds (a stored property)
/// keeps the child running until it is released.
public enum StreamingSubprocess {
    /// The command exited with a non-zero status.
    public struct ExitError: Error, Sendable, CustomStringConvertible {
        public var status: Int32
        /// The end of the command's standard error (at most 4 KB).
        public var stderrTail: String
        /// The command was stopped by `cancel`, not by itself.
        public var wasInterrupted: Bool
        public var description: String {
            let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            return "exit status \(status)" + (tail.isEmpty ? "" : ": \(tail)")
        }
    }

    /// Seconds between SIGINT and SIGTERM, and between SIGTERM and SIGKILL.
    nonisolated(unsafe) public static var interruptGrace: TimeInterval = 2

    /// Starts `executable` and returns its standard output as lines (without
    /// the line terminator). `input` is written to its standard input, which
    /// is then closed; nil gives it the null device. The stream finishes
    /// when the command exits with status 0 and throws `ExitError`
    /// otherwise. A command that cannot start throws from the stream.
    public static func lines(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
                             currentDirectory: URL? = nil, input: Data? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let p = Process()
            p.executableURL = executable
            p.arguments = arguments
            if let environment { p.environment = environment }
            if let currentDirectory { p.currentDirectoryURL = currentDirectory }
            let out: SpawnPipe, err: SpawnPipe, inPipe: SpawnPipe?
            do {
                out = try SpawnPipe(childReads: false)
                err = try SpawnPipe(childReads: false)
                inPipe = input == nil ? nil : try SpawnPipe(childReads: true)
            } catch {
                continuation.finish(throwing: error)
                return
            }
            p.standardOutput = out.childEnd
            p.standardError = err.childEnd
            p.standardInput = inPipe?.childEnd ?? FileHandle.nullDevice
            let state = RunState()
            continuation.onTermination = { reason in
                if case .cancelled = reason { state.cancel() }
            }
            do {
                try p.runWithSignalsUnblocked()
            } catch {
                [out, err, inPipe].forEach { $0?.closeChildEnd() }
                state.finished()
                continuation.finish(throwing: error)
                return
            }
            // The child has its copies; the parent's ends now see end of file
            // (or a broken pipe) when the child, and whatever it started, is gone.
            [out, err, inPipe].forEach { $0?.closeChildEnd() }
            state.started(p.processIdentifier)
            if let inPipe, let input {
                let h = inPipe.parentEnd
                Thread.detachNewThread {
                    h.writeQuietly(input)
                    try? h.close()
                }
            }
            let errBox = DataBox()
            let errDone = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                let h = err.parentEnd
                while true {
                    let d = h.availableData
                    if d.isEmpty { break }
                    errBox.append(d, keepingLast: 4096)
                }
                errDone.signal()
            }
            Thread.detachNewThread {
                let h = out.parentEnd
                var buffer = Data()
                while true {
                    let d = h.availableData
                    if d.isEmpty { break }
                    buffer.append(d)
                    while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                        var line = buffer[buffer.startIndex..<nl]
                        if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
                        continuation.yield(String(decoding: line, as: UTF8.self))
                        buffer.removeSubrange(buffer.startIndex...nl)
                    }
                }
                if !buffer.isEmpty { continuation.yield(String(decoding: buffer, as: UTF8.self)) }
                p.waitUntilExit()
                errDone.wait()
                state.finished()
                if p.terminationStatus == 0 && p.terminationReason == .exit {
                    continuation.finish()
                } else {
                    let status = p.terminationReason == .uncaughtSignal ? 128 + p.terminationStatus : p.terminationStatus
                    continuation.finish(throwing: ExitError(status: status, stderrTail: String(decoding: errBox.data, as: UTF8.self),
                                                            wasInterrupted: state.wasCancelled))
                }
            }
        }
    }

    final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
        func append(_ d: Data, keepingLast limit: Int) {
            lock.lock()
            storage.append(d)
            if storage.count > limit { storage = storage.suffix(limit) }
            lock.unlock()
        }
    }

    /// Escalating stop of the child and the processes it started (its
    /// process group): SIGINT, then SIGTERM, then SIGKILL, while it runs.
    /// A stop asked for before the child has started is carried out as soon
    /// as it starts, so a stop button pressed early still ends the tool.
    final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t = 0
        private var done = false
        private var cancelled = false
        private var stopping = false
        var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

        func started(_ pid: pid_t) {
            lock.lock()
            self.pid = pid
            let stop = beginStop()
            lock.unlock()
            if stop { escalate(pid) }
        }

        func finished() { lock.lock(); done = true; lock.unlock() }

        func cancel() {
            lock.lock()
            cancelled = true
            let stop = beginStop()
            let pid = self.pid
            lock.unlock()
            if stop { escalate(pid) }
        }

        /// Called with the lock held: true once, when there is a running child to stop.
        private func beginStop() -> Bool {
            guard cancelled, pid > 0, !done, !stopping else { return false }
            stopping = true
            return true
        }

        private func escalate(_ pid: pid_t) {
            ChildSignals.send(SIGINT, to: pid)
            let grace = StreamingSubprocess.interruptGrace
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
                guard isRunning else { return }
                ChildSignals.send(SIGTERM, to: pid)
                DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
                    if isRunning { ChildSignals.send(SIGKILL, to: pid) }
                }
            }
        }

        private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return !done }
    }
}

extension FileHandle {
    /// Writes all of `data`, stopping silently when the reader has gone. A
    /// child that exits without reading all of its input makes the write
    /// fail with EPIPE; the SIGPIPE that comes with it, which would end
    /// this whole process, is blocked on this thread and consumed.
    func writeQuietly(_ data: Data) {
        let fd = fileDescriptor
        #if canImport(Darwin)
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        #else
        var pipeSignal = sigset_t(), saved = sigset_t()
        sigemptyset(&pipeSignal)
        sigaddset(&pipeSignal, SIGPIPE)
        pthread_sigmask(SIG_BLOCK, &pipeSignal, &saved)
        var broken = false
        defer {
            if broken && sigismember(&saved, SIGPIPE) == 0 {
                var zero = timespec(tv_sec: 0, tv_nsec: 0)
                while sigtimedwait(&pipeSignal, nil, &zero) == SIGPIPE {}
            }
            pthread_sigmask(SIG_SETMASK, &saved, nil)
        }
        #endif
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var p = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                #if canImport(Glibc)
                let n = Glibc.write(fd, p, left)
                #else
                let n = Darwin.write(fd, p, left)
                #endif
                if n < 0 {
                    if errno == EINTR { continue }
                    #if !canImport(Darwin)
                    broken = errno == EPIPE
                    #endif
                    return
                }
                left -= n
                p += n
            }
        }
    }
}
