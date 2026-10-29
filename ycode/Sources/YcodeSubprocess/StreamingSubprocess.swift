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
/// Cancelling the consumer (ending the iteration, or cancelling the task
/// that iterates) interrupts the child: SIGINT first, so a tool can end its
/// turn cleanly, then SIGTERM after `interruptGrace`, then SIGKILL.
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
            let out = Pipe(), err = Pipe()
            let inPipe = input == nil ? nil : Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = inPipe ?? FileHandle.nullDevice
            let state = RunState()
            continuation.onTermination = { reason in
                if case .cancelled = reason { state.cancel(p) }
            }
            do {
                try p.run()
            } catch {
                continuation.finish(throwing: error)
                return
            }
            state.started()
            if let inPipe, let input {
                let h = inPipe.fileHandleForWriting
                Thread.detachNewThread {
                    // A child that exits early closes its end; ignore SIGPIPE's error.
                    h.writeQuietly(input)
                    try? h.close()
                }
            }
            let errBox = DataBox()
            let errDone = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                let h = err.fileHandleForReading
                while true {
                    let d = h.availableData
                    if d.isEmpty { break }
                    errBox.append(d, keepingLast: 4096)
                }
                errDone.signal()
            }
            Thread.detachNewThread {
                let h = out.fileHandleForReading
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

    /// Escalating stop: SIGINT, then SIGTERM, then SIGKILL while it runs.
    final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var running = false
        private var done = false
        private var cancelled = false
        var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

        func started() { lock.lock(); running = !done; lock.unlock() }
        func finished() { lock.lock(); done = true; running = false; lock.unlock() }

        func cancel(_ p: Process) {
            lock.lock()
            cancelled = true
            let live = running
            lock.unlock()
            guard live else { return }
            let pid = p.processIdentifier
            p.interrupt()
            let grace = StreamingSubprocess.interruptGrace
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
                guard isRunning else { return }
                kill(pid, SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
                    if isRunning { kill(pid, SIGKILL) }
                }
            }
        }

        private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    }
}

extension FileHandle {
    /// Writes all of `data`, stopping silently when the reader has gone.
    func writeQuietly(_ data: Data) {
        let fd = fileDescriptor
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
                    return
                }
                left -= n
                p += n
            }
        }
    }
}
