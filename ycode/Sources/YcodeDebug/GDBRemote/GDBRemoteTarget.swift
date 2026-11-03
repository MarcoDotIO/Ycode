import Foundation

// What the gdb-remote stub needs from the system it debugs
// (`specs/simulator/debug-stub.md` §2). `GDBRemoteServer` speaks the
// protocol; a host (Ycode's simulator, a test double) implements these.

/// How one thread continues (`vCont` actions, `c`, `s`).
public enum GDBRemoteResume: Equatable, Sendable {
    /// Stays stopped.
    case stop
    /// Runs; `signal` is the signal to deliver (nil: none, the stop's
    /// signal is dropped).
    case `continue`(signal: Int?)
    /// Executes one instruction, then stops with reason `trace`.
    case step(signal: Int?)
}

/// Why one thread is stopped.
public enum GDBRemoteStopReason: Equatable, Sendable {
    /// Stopped because another thread stopped (all-stop), or never ran.
    case none
    /// An interrupt or an attach (SIGSTOP), or a signal.
    case signal
    /// It executed a breakpoint the debugger inserted.
    case breakpoint
    /// A single step finished.
    case trace
    /// A fault or a trap instruction of the program itself.
    case exception(String)
    /// A hardware watchpoint: `address` lies in the watched range (the
    /// one the client set), `index` is its register, `hit` the address the
    /// hardware reported (it may lie before the range for a wide access).
    case watchpoint(address: UInt64, index: Int, hit: UInt64)
}

/// What a hardware watchpoint watches (`Z2` write, `Z3` read, `Z4` access).
public enum GDBRemoteWatchKind: Int, Equatable, Sendable {
    case write = 2, read = 3, access = 4
}

public struct GDBRemoteThreadStop: Equatable, Sendable {
    public var signal: Int
    public var reason: GDBRemoteStopReason
    public init(signal: Int, reason: GDBRemoteStopReason) {
        self.signal = signal
        self.reason = reason
    }

    /// A thread that is stopped only because the process is.
    public static let quiet = GDBRemoteThreadStop(signal: 0, reason: .none)
}

/// What ends a resumed run.
public enum GDBRemoteEvent: Equatable, Sendable {
    /// Every thread stopped; `thread` is the one that caused it.
    case stopped(thread: UInt64)
    /// The process exited with this status.
    case exited(status: Int)
    /// The process was ended by this signal.
    case terminated(signal: Int)
}

/// A mapped (or unmapped) range of the target's memory (`qMemoryRegionInfo`).
public struct GDBRemoteMemoryRegion: Equatable, Sendable {
    public var start: UInt64
    public var size: UInt64
    /// "r", "w", "x" letters; nil: unmapped.
    public var permissions: String?
    public var name: String?
    public init(start: UInt64, size: UInt64, permissions: String?, name: String? = nil) {
        self.start = start
        self.size = size
        self.permissions = permissions
        self.name = name
    }
}

public struct GDBRemoteError: Error, Equatable, Sendable, CustomStringConvertible {
    public var code: UInt8
    public var message: String
    public init(_ code: UInt8, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { message }
}

/// The process the stub is attached to. Every call except `interrupt`
/// is made while the process is stopped, from the stub's connection
/// thread; `waitForEvent` is called on another thread after `resume`.
public protocol GDBRemoteProcess: AnyObject, Sendable {
    var pid: Int { get }
    /// `qProcessInfo` pairs besides `pid` (parent-pid, uids, cputype, ...).
    var processInfo: [(String, String)] { get }
    /// `qShlibInfoAddr`: the address of the dynamic loader's image list.
    var sharedLibraryInfoAddress: UInt64? { get }
    /// v0–v31, fpsr and fpcr can be read.
    var hasFloatingPointRegisters: Bool { get }
    /// The debugger's software breakpoints in this process.
    var breakpoints: GDBRemoteBreakpoints { get }

    /// Live threads, the first being the main thread.
    func threadIDs() -> [UInt64]
    func threadName(_ tid: UInt64) -> String?
    /// The address of the thread's libdispatch queue slot (`qaddr`; LLDB
    /// reads the queue's name from there).
    func dispatchQueueAddress(_ tid: UInt64) -> UInt64?
    func stopInfo(_ tid: UInt64) -> GDBRemoteThreadStop
    func registers(_ tid: UInt64) -> GDBRemoteThreadRegisters?
    func setRegisters(_ tid: UInt64, _ registers: GDBRemoteThreadRegisters) -> Bool
    /// The bytes readable from `address` on, up to `count` (fewer at the
    /// first unreadable page); breakpoints show as their instructions.
    func readMemory(_ address: UInt64, count: Int) -> [UInt8]
    /// Writes; read-only code is written too (a private copy of the page).
    func writeMemory(_ address: UInt64, bytes: [UInt8]) -> Bool
    func memoryRegion(at address: UInt64) -> GDBRemoteMemoryRegion?
    /// `jGetSharedCacheInfo`: the shared cache's base address and UUID
    /// (nil: no shared cache known).
    var sharedCacheInfo: (base: UInt64, uuid: [UInt8])? { get }
    /// `_M`: new memory for the debugger's own code and data (expression
    /// evaluation); `permissions` is letters of "rwx". nil: none.
    func allocateMemory(size: UInt64, permissions: String) -> UInt64?
    /// `_m`: frees memory `allocateMemory` returned.
    func deallocateMemory(_ address: UInt64) -> Bool

    /// The images dyld lists as loaded, in its order, with their paths
    /// (`jGetLoadedDynamicLibrariesInfos`). nil: the packet is not offered.
    func loadedImages() -> [(address: UInt64, path: String)]?
    /// libdyld's process state (`jGetDyldProcessState`); nil: not offered.
    var dyldState: GDBRemoteDyldState? { get }
    /// `qWatchpointSupportInfo`: how many hardware watchpoints can be set.
    var watchpointSlots: Int { get }
    /// `Z2`–`Z4`: watches `size` bytes from `address`.
    func insertWatchpoint(address: UInt64, size: Int, kind: GDBRemoteWatchKind) -> Result<Void, GDBRemoteError>
    /// `z2`–`z4`. Removing one that is not set succeeds.
    func removeWatchpoint(address: UInt64, size: Int, kind: GDBRemoteWatchKind) -> Result<Void, GDBRemoteError>

    /// Resumes threads by `actions`, the others by `others`. Returns at
    /// once; the run ends with `waitForEvent`.
    func resume(_ actions: [UInt64: GDBRemoteResume], others: GDBRemoteResume) -> Result<Void, GDBRemoteError>
    /// Asks a running process to stop (all threads); `waitForEvent` then
    /// returns.
    func interrupt()
    /// Blocks until the resumed process stopped again or ended.
    func waitForEvent() -> GDBRemoteEvent
    /// Lets the process run on without the debugger (breakpoints already removed).
    func detach()
    /// Ends the process.
    func kill()
}

extension GDBRemoteProcess {
    public var sharedCacheInfo: (base: UInt64, uuid: [UInt8])? { nil }
    public func allocateMemory(size: UInt64, permissions: String) -> UInt64? { nil }
    public func deallocateMemory(_ address: UInt64) -> Bool { false }
    public func loadedImages() -> [(address: UInt64, path: String)]? { nil }
    public var dyldState: GDBRemoteDyldState? { nil }
    public var watchpointSlots: Int { 0 }
    public func insertWatchpoint(address: UInt64, size: Int, kind: GDBRemoteWatchKind) -> Result<Void, GDBRemoteError> {
        .failure(GDBRemoteError(0x16, "no hardware watchpoints"))
    }
    public func removeWatchpoint(address: UInt64, size: Int, kind: GDBRemoteWatchKind) -> Result<Void, GDBRemoteError> { .success(()) }
}

/// The system the stub runs in: which processes it can attach to.
public protocol GDBRemoteHost: AnyObject, Sendable {
    /// `qHostInfo` pairs.
    var hostInfo: [(String, String)] { get }
    /// The process a new connection is attached to (nil: none; the client
    /// attaches with `vAttach`).
    func initialProcess() -> GDBRemoteProcess?
    func attach(pid: Int) -> Result<GDBRemoteProcess, GDBRemoteError>
    /// By executable name; `wait`: the next process of that name to start
    /// (after any running one when `includeExisting`).
    func attach(name: String, wait: Bool, includeExisting: Bool) -> Result<GDBRemoteProcess, GDBRemoteError>
    /// (pid, executable name) of the processes it can attach to.
    func processes() -> [(pid: Int, name: String)]
}

/// The debugger's software breakpoints of one process: a `brk` instruction
/// at each address, with the bytes it replaced (`debug-stub.md` §5). Reads
/// see the original bytes; writes over a breakpoint change the saved bytes
/// and keep the breakpoint. Thread-safe.
public final class GDBRemoteBreakpoints: @unchecked Sendable {
    /// `brk #0xf000`, the encoding LLDB uses for arm64 software breakpoints.
    public static let instruction: UInt32 = 0xD43E_0000
    public static let instructionBytes: [UInt8] = [0x00, 0x00, 0x3E, 0xD4]

    private let lock = NSLock()
    @inline(__always) private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private var saved: [UInt64: [UInt8]] = [:]
    private let read: (UInt64, Int) -> [UInt8]
    private let write: (UInt64, [UInt8]) -> Bool

    /// `read` and `write` access the process's memory without the table.
    public init(read: @escaping (UInt64, Int) -> [UInt8], write: @escaping (UInt64, [UInt8]) -> Bool) {
        self.read = read
        self.write = write
    }

    public var addresses: [UInt64] { locked { saved.keys.sorted() } }
    public func contains(_ address: UInt64) -> Bool { locked { saved[address] != nil } }

    /// Inserts a breakpoint at a 4-byte-aligned address (`Z0`). Inserting
    /// one that exists succeeds.
    public func insert(_ address: UInt64) -> Result<Void, GDBRemoteError> {
        guard address & 3 == 0 else { return .failure(GDBRemoteError(0x16, "breakpoint address not 4-byte aligned")) }
        return locked {
            if saved[address] != nil { return .success(()) }
            let original = read(address, 4)
            guard original.count == 4 else { return .failure(GDBRemoteError(0x0E, "cannot read memory at the breakpoint")) }
            guard write(address, Self.instructionBytes) else { return .failure(GDBRemoteError(0x0E, "cannot write the breakpoint")) }
            saved[address] = original
            return .success(())
        }
    }

    /// Removes a breakpoint (`z0`), restoring the bytes. Removing one that
    /// does not exist succeeds.
    public func remove(_ address: UInt64) -> Result<Void, GDBRemoteError> {
        locked {
            guard let original = saved[address] else { return .success(()) }
            guard write(address, original) else { return .failure(GDBRemoteError(0x0E, "cannot restore the bytes under the breakpoint")) }
            saved[address] = nil
            return .success(())
        }
    }

    /// Removes every breakpoint (detach).
    public func removeAll() {
        for a in addresses { _ = remove(a) }
    }

    /// Forgets every breakpoint without touching memory (the process ended).
    public func forgetAll() { locked { saved.removeAll() } }

    /// `bytes`, read from `address`, with each breakpoint's original bytes.
    public func shadow(_ address: UInt64, _ bytes: [UInt8]) -> [UInt8] {
        locked {
            guard !saved.isEmpty, !bytes.isEmpty else { return bytes }
            var out = bytes
            let end = address &+ UInt64(bytes.count)
            for (bp, original) in saved where bp &+ 4 > address && bp < end {
                for i in 0..<4 {
                    let a = bp &+ UInt64(i)
                    if a >= address && a < end { out[Int(a - address)] = original[i] }
                }
            }
            return out
        }
    }

    /// Writes `bytes` at `address`: bytes under a breakpoint become its saved
    /// bytes, and the breakpoint stays.
    public func writeThrough(_ address: UInt64, _ bytes: [UInt8]) -> Bool {
        locked {
            var out = bytes
            let end = address &+ UInt64(bytes.count)
            for (bp, original) in saved where bp &+ 4 > address && bp < end {
                var o = original
                for i in 0..<4 {
                    let a = bp &+ UInt64(i)
                    if a >= address && a < end {
                        o[i] = bytes[Int(a - address)]
                        out[Int(a - address)] = Self.instructionBytes[i]
                    }
                }
                saved[bp] = o
            }
            return write(address, out)
        }
    }
}
