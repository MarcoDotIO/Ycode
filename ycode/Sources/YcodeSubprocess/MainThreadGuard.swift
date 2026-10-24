import Foundation

/// Debug-build checks that blocking work (a subprocess the caller waits
/// for, a large file walk, a network round trip) does not run on the main
/// thread, where it would stall the IDE's user interface.
///
/// Every place that waits synchronously for such work calls
/// `blockingCall(_:)` first. In release builds the call compiles to
/// nothing. In debug builds, on the main thread only:
///
/// - inside `violations(during:)` the call is recorded (tests use this to
///   fail when a known-slow operation runs on the main thread);
/// - with `YCODE_MAIN_THREAD_GUARD=log` it is printed to standard error
///   with the caller's stack; with `=trap` it also stops the process.
///
/// Command-line tools (`ycode`, `ycodebuild`) do all their work on the
/// main thread on purpose; the guard is off for them unless asked for.
public enum MainThreadGuard {
    /// A blocking call made on the main thread.
    public struct Violation: Sendable, CustomStringConvertible {
        /// What blocked, e.g. "git status".
        public var operation: String
        /// The `#fileID:line` of the blocking call.
        public var location: String
        /// The main thread's stack at the call (symbolic, one frame a line).
        public var stack: [String]
        public var description: String { "\(operation) at \(location)" }
    }

    public enum Mode: String, Sendable {
        case off, log, trap
    }

    /// `YCODE_MAIN_THREAD_GUARD` (`log` or `trap`); always `off` in
    /// release builds.
    public static let mode: Mode = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["YCODE_MAIN_THREAD_GUARD"].flatMap(Mode.init(rawValue:)) ?? .off
        #else
        return .off
        #endif
    }()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorders = 0
    nonisolated(unsafe) private static var recorded: [Violation] = []

    /// Call right before waiting for blocking work. `operation` names it
    /// (it is evaluated only when the call is reported).
    @inline(__always)
    public static func blockingCall(_ operation: @autoclosure () -> String, fileID: StaticString = #fileID, line: UInt = #line) {
        #if DEBUG
        guard Thread.isMainThread else { return }
        report(operation(), location: "\(fileID):\(line)")
        #endif
    }

    #if DEBUG
    private static func report(_ operation: String, location: String) {
        lock.lock()
        let recording = recorders > 0
        lock.unlock()
        guard recording || mode != .off else { return }
        let v = Violation(operation: operation, location: location, stack: Array(Thread.callStackSymbols.dropFirst(2)))
        if recording {
            lock.lock()
            recorded.append(v)
            lock.unlock()
        }
        guard mode != .off else { return }
        let text = "Ycode main-thread guard: blocking call on the main thread: \(v)\n" + v.stack.map { "    \($0)\n" }.joined()
        FileHandle.standardError.write(Data(text.utf8))
        if mode == .trap { fatalError("blocking call on the main thread: \(v)") }
    }
    #endif

    /// Runs `body` and returns the blocking calls it made on the main
    /// thread (always empty in release builds). `body` is synchronous, so
    /// nothing else can run on the main thread meanwhile.
    public static func violations(during body: () throws -> Void) rethrows -> [Violation] {
        lock.lock()
        if recorders == 0 { recorded = [] }
        recorders += 1
        lock.unlock()
        defer {
            lock.lock()
            recorders -= 1
            lock.unlock()
        }
        let start: Int = { lock.lock(); defer { lock.unlock() }; return recorded.count }()
        try body()
        lock.lock()
        defer { lock.unlock() }
        return Array(recorded[start...])
    }
}
