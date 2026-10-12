import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// A vCPU pool that only records what it was asked to start.
final class FakeThreadHost: ThreadHost, @unchecked Sendable {
    struct Exhausted: Error {}
    private let mutex = NSLock()
    private var startsStorage: [(state: ThreadStartState, context: ThreadContext)] = []
    /// How many threads it may start (default: unlimited).
    var limit = Int.max

    var starts: [(state: ThreadStartState, context: ThreadContext)] {
        mutex.lock()
        defer { mutex.unlock() }
        return startsStorage
    }

    func startThread(_ start: ThreadStartState, context: ThreadContext) throws -> Int {
        mutex.lock()
        defer { mutex.unlock() }
        guard startsStorage.count < limit else { throw Exhausted() }
        startsStorage.append((start, context))
        return startsStorage.count
    }
}

/// A value written by one host thread and read by another.
final class T2Box<T>: @unchecked Sendable {
    private let mutex = NSLock()
    private var stored: T?
    var value: T? {
        get { mutex.lock(); defer { mutex.unlock() }; return stored }
        set { mutex.lock(); stored = newValue; mutex.unlock() }
    }
}

/// A kernel with a registered thread library, a fake vCPU pool, and helpers
/// to run traps as any thread from any host thread.
final class T2Env: @unchecked Sendable {
    static let threadStart: UInt64 = 0x2_0000_1000
    static let wqStart: UInt64 = 0x2_0000_2000
    let env: Env
    let host = FakeThreadHost()
    var kernel: DarwinKernel { env.kernel }
    var space: GuestAddressSpace { env.space }
    var main: ThreadContext { kernel.mainThread }

    init(register: Bool = true) throws {
        env = try Env(counter: MachTimebase.now, frequency: MachTimebase.frequency)
        env.kernel.threadHost = host
        if register { registerThreads() }
    }

    deinit { kernel.shutdown() }

    /// `bsdthread_register` with tsd_offset 224 and mach_thread_self_offset 24.
    func registerThreads() {
        let rec = Env.scratch + 0xF000
        var r = [UInt8](repeating: 0, count: 56)
        r.putLE(UInt64(56), at: 0)
        r.putLE(UInt64(160), at: 8)
        r.putLE(UInt32(224), at: 24)
        r.putLE(UInt32(24), at: 32)
        put(r, at: rec)
        let (_, f) = svc(366, [Self.threadStart, Self.wqStart, 16384, rec, 56, 160])
        precondition(!f.carry && f.x[0] == 0x4000_00DF)
    }

    /// One trap as `context` (main thread by default).
    @discardableResult
    func svc(_ x16: UInt64, _ args: [UInt64] = [], context: ThreadContext? = nil) -> (DarwinKernel.Outcome, TrapFrame) {
        var f = TrapFrame()
        f.kind = TrapFrame.Kind.svc.rawValue
        f.x[16] = x16
        for (i, v) in args.enumerated() { f.x[i] = v }
        let o = kernel.handle(&f, context: context ?? main, memory: space)
        return (o, f)
    }

    /// x0 of a trap (errno when carry is set).
    func x0(_ x16: UInt64, _ args: [UInt64] = [], context: ThreadContext? = nil) -> UInt64 {
        svc(x16, args, context: context).1.x[0]
    }

    func mach(_ n: Int) -> UInt64 { UInt64(bitPattern: Int64(n)) }

    // Guest memory, under the kernel lock.
    func map(_ size: UInt64) -> UInt64 {
        kernel.lock.withLock { try! space.mapAnonymous(at: nil, size: size, protection: .readWrite, hint: nil) }
    }
    func put(_ bytes: [UInt8], at va: UInt64) { kernel.lock.withLock { try! space.write(va: va, bytes: bytes) } }
    func put32(_ v: UInt32, at va: UInt64) { var b: [UInt8] = []; b.appendLE(v); put(b, at: va) }
    func put64(_ v: UInt64, at va: UInt64) { put(leBytes(v), at: va) }
    func u32(_ va: UInt64) -> UInt32 { kernel.lock.withLock { UInt32(le(try! space.read(va: va, count: 4))) } }
    func u64(_ va: UInt64) -> UInt64 { kernel.lock.withLock { le(try! space.read(va: va, count: 8)) } }
    func read(_ va: UInt64, _ n: Int) -> [UInt8] { kernel.lock.withLock { try! space.read(va: va, count: n) } }
    func isMapped(_ va: UInt64) -> Bool { kernel.lock.withLock { space.region(containing: va) != nil } }

    /// Creates a pthread through `bsdthread_create`; returns its context and start state.
    @discardableResult
    func createThread(flags: UInt32 = 0x0100_0000) -> (ThreadContext, ThreadStartState) {
        let region = map(0x2_0000)
        let pthread = region + 0x1_0000, stack = region + 0x1_0000
        let before = host.starts.count
        let (_, f) = svc(360, [0x5000, 0x6000, stack, pthread, UInt64(flags)])
        precondition(!f.carry, "bsdthread_create failed: \(f.x[0])")
        let s = host.starts[before]
        return (s.context, s.state)
    }

    /// Runs `body` on a new host thread; the result waits up to 10 s for it.
    func spawn<T>(_ body: @escaping @Sendable () -> T) -> () -> T? {
        let done = DispatchSemaphore(value: 0)
        let box = T2Box<T>()
        let thread = Thread {
            box.value = body()
            done.signal()
        }
        thread.start()
        return { done.wait(timeout: .now() + 10) == .success ? box.value : nil }
    }

    /// True once `condition` holds (polls up to `seconds`).
    func eventually(_ seconds: Double = 5, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.002)
        }
        return condition()
    }

    func blocked(_ c: ThreadContext) -> Bool { kernel.lock.withLock { c.blockedInKernel } }
}
