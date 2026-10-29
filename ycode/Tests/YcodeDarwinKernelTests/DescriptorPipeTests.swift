import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

// Stage 4b descriptors (`specs/simulator/stage4b-contract.md` §6): pipes,
// dup/dup2/fcntl, blocking and waking, and the trap-level glue.

/// One process image for descriptor tests: a kernel over a fake physical
/// backing, a read-only prefix and a writable `/tmp`-like prefix at a
/// temporary directory, and a scratch region. Several share one
/// `DarwinSystem` when `system` is given.
final class DEnv: @unchecked Sendable {
    static let scratch: UInt64 = 0x1_0000_0000
    static let scratchSize: UInt64 = 0x40000

    let kernel: DarwinKernel
    let space: GuestAddressSpace
    let sink: Sink
    let root: String

    /// A new image. With `parent`, it joins the parent's system and gets a
    /// child copy of its file system (as spawn does).
    init(parent: DEnv? = nil, pid: Int32 = 100) throws {
        let sink = Sink()
        self.sink = sink
        let fs: DarwinFileSystem
        if let parent {
            root = parent.root
            fs = parent.kernel.fileSystem.makeChildCopy()
        } else {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            root = tmp.appendingPathComponent("ycode-desc-\(UUID().uuidString)").path
            try FileManager.default.createDirectory(atPath: root + "/w", withIntermediateDirectories: true)
            fs = DarwinFileSystem(prefixes: [.init(guestPath: root, hostPath: root, writable: false),
                                             .init(guestPath: root + "/w", hostPath: root + "/w", writable: true)],
                                  console: { fd, bytes in sink.append(fd, bytes) })
        }
        kernel = DarwinKernel(fileSystem: fs, pid: pid, system: parent?.kernel.system,
                              log: { sink.append($0) }, counter: { 0x1234 }, counterFrequency: 24_000_000,
                              wallClock: { (1_700_000_000, 0) })
        space = GuestAddressSpace(backing: FakePhysicalBacking())
        _ = try space.mapAnonymous(at: Self.scratch, size: Self.scratchSize, protection: .readWrite, hint: nil)
    }

    /// The writable directory (guest path).
    var writable: String { root + "/w" }

    struct Result {
        var x0: UInt64
        var x1: UInt64
        var carry: Bool
        var outcome: DarwinKernel.Outcome
        /// The value, or nil on failure.
        var value: UInt64? { carry ? nil : x0 }
        /// The errno, or nil on success.
        var errno: Int32? { carry ? Int32(truncatingIfNeeded: x0) : nil }
        var fd: Int32 { Int32(truncatingIfNeeded: x0) }
    }

    @discardableResult
    func call(_ n: UInt64, _ args: [UInt64] = [], context: ThreadContext? = nil) -> Result {
        var f = TrapFrame()
        f.kind = TrapFrame.Kind.svc.rawValue
        f.x[16] = n
        for (i, v) in args.enumerated() { f.x[i] = v }
        let o = kernel.handle(&f, context: context ?? kernel.mainThread, memory: space)
        return Result(x0: f.x[0], x1: f.x[1], carry: f.carry, outcome: o)
    }

    func put(_ bytes: [UInt8], at va: UInt64) { try! space.write(va: va, bytes: bytes) }
    func putString(_ s: String, at va: UInt64) { put(Array(s.utf8) + [0], at: va) }
    func get(_ va: UInt64, _ count: Int) -> [UInt8] { try! space.read(va: va, count: count) }
    func u32(_ va: UInt64) -> UInt32 { UInt32(truncatingIfNeeded: le(get(va, 4))) }
    func i32(_ va: UInt64) -> Int32 { Int32(bitPattern: u32(va)) }

    /// write(fd, text) through the trap.
    @discardableResult
    func write(_ fd: Int32, _ text: String, at va: UInt64 = DEnv.scratch + 0x1000) -> Result {
        put(Array(text.utf8), at: va)
        return call(4, [UInt64(fd), va, UInt64(text.utf8.count)])
    }

    /// read(fd, count) through the trap; the text read (nil on failure).
    func read(_ fd: Int32, _ count: Int = 256, at va: UInt64 = DEnv.scratch + 0x2000) -> (Result, String?) {
        let r = call(3, [UInt64(fd), va, UInt64(count)])
        guard let n = r.value else { return (r, nil) }
        return (r, String(decoding: get(va, Int(n)), as: UTF8.self))
    }

    /// pipe() → (read fd, write fd).
    func pipe() -> (Int32, Int32) {
        let r = call(42)
        precondition(!r.carry, "pipe failed")
        return (Int32(truncatingIfNeeded: r.x0), Int32(truncatingIfNeeded: r.x1))
    }

    /// sigaction(sig, SIG_IGN).
    func ignore(_ signal: Int32) {
        let va = Self.scratch + 0x3F000
        var b = [UInt8](repeating: 0, count: 24)
        b[0] = 1
        put(b, at: va)
        precondition(!call(46, [UInt64(signal), va, 0]).carry)
    }
}

/// Runs `body` on a new host thread; `wait` returns its result (or nil
/// after the timeout).
final class HostThread<T>: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let mutex = NSLock()
    private var stored: T?

    init(_ body: @escaping @Sendable () -> T) {
        let t = Thread { [self] in
            let v = body()
            mutex.lock()
            stored = v
            mutex.unlock()
            done.signal()
        }
        t.start()
    }

    var result: T? {
        mutex.lock()
        defer { mutex.unlock() }
        return stored
    }

    func wait(seconds: Double = 5) -> T? {
        _ = done.wait(timeout: .now() + seconds)
        return result
    }
}

@Suite(.serialized) struct DescriptorPipeTests {
    @Test func pipeRoundTripEOFAndStat() throws {
        let e = try DEnv()
        let (r, w) = e.pipe()
        #expect(r == 3 && w == 4)
        #expect(e.write(w, "hello").value == 5)
        // fstat: S_IFIFO | 0660, the buffered count.
        let st = DEnv.scratch + 0x4000
        #expect(e.call(339, [UInt64(r), st]).value == 0)
        let stat = try #require(DarwinStat(decodingStat64: e.get(st, 144)))
        #expect(stat.mode == DarwinStat.S_IFIFO | 0o660 && stat.size == 5 && stat.blksize == 16384)
        // F_GETFL: the access modes.
        #expect(e.call(92, [UInt64(r), 3, 0]).value == 0)
        #expect(e.call(92, [UInt64(w), 3, 0]).value == 1)
        #expect(e.read(r, 3).1 == "hel")
        #expect(e.read(r).1 == "lo")
        // Wrong direction: EBADF.
        #expect(e.read(w).0.errno == 9)
        #expect(e.write(r, "x").errno == 9)
        // No seeking.
        #expect(e.call(199, [UInt64(r), 0, 1]).errno == 29)
        #expect(e.call(153, [UInt64(r), DEnv.scratch, 1, 0]).errno == 29)
        // Writer gone: end of file.
        #expect(e.call(6, [UInt64(w)]).value == 0)
        let (eof, text) = e.read(r)
        #expect(eof.value == 0 && text == "")
    }

    @Test func epipeRaisesSigpipeUnlessIgnored() throws {
        let e = try DEnv()
        let (r, w) = e.pipe()
        e.call(6, [UInt64(r)])
        e.ignore(13)
        #expect(e.write(w, "x").errno == 32)
        #expect(!e.kernel.isTerminating)
        // F_SETNOSIGPIPE suppresses it on the description.
        let e2 = try DEnv()
        let (r2, w2) = e2.pipe()
        e2.call(6, [UInt64(r2)])
        #expect(e2.call(92, [UInt64(w2), 73, 1]).value == 0)
        #expect(e2.call(92, [UInt64(w2), 74, 0]).value == 1)
        #expect(e2.write(w2, "x").errno == 32)
        #expect(!e2.kernel.isTerminating)
        // Default action: the process is killed by SIGPIPE.
        let e3 = try DEnv()
        let (r3, w3) = e3.pipe()
        e3.call(6, [UInt64(r3)])
        _ = e3.write(w3, "x")
        #expect(e3.kernel.isTerminating)
    }

    @Test func nonBlockingAndCapacity() throws {
        let e = try DEnv()
        let (r, w) = e.pipe()
        // F_SETFL O_NONBLOCK on both ends.
        #expect(e.call(92, [UInt64(r), 4, 4]).value == 0)
        #expect(e.call(92, [UInt64(r), 3, 0]).value == 4)  // O_RDONLY | O_NONBLOCK
        #expect(e.read(r).0.errno == 35)
        // FIONBIO on the write end.
        e.put([1, 0, 0, 0], at: DEnv.scratch + 0x100)
        #expect(e.call(54, [UInt64(w), 0x8004_667E, DEnv.scratch + 0x100]).value == 0)
        let chunk = [UInt8](repeating: 0x61, count: 0x10000)
        e.put(chunk, at: DEnv.scratch + 0x10000)
        #expect(e.call(4, [UInt64(w), DEnv.scratch + 0x10000, 40000]).value == 40000)
        #expect(e.call(4, [UInt64(w), DEnv.scratch + 0x10000, 40000]).value == UInt64(65536 - 40000))
        #expect(e.call(4, [UInt64(w), DEnv.scratch + 0x10000, 1]).errno == 35)
        // FIONREAD.
        #expect(e.call(54, [UInt64(r), 0x4004_667F, DEnv.scratch + 0x100]).value == 0)
        #expect(e.u32(DEnv.scratch + 0x100) == 65536)
    }

    @Test func dupFamily() throws {
        let e = try DEnv()
        let (r, w) = e.pipe()
        let d = e.call(41, [UInt64(w)]).fd
        #expect(d == 5)
        #expect(e.call(90, [UInt64(w), 20]).value == 20)
        let c = e.call(92, [UInt64(w), 67, 30])  // F_DUPFD_CLOEXEC
        #expect(c.value == 30)
        #expect(e.call(92, [30, 1, 0]).value == 1)  // F_GETFD
        #expect(e.call(92, [20, 1, 0]).value == 0)
        #expect(e.call(92, [UInt64(w), 0, 10]).value == 10)  // F_DUPFD
        #expect(e.call(92, [UInt64(w), 0, 300]).errno == 22)
        #expect(e.call(41, [77]).errno == 9)
        #expect(e.call(90, [77, 3]).errno == 9)
        // FIOCLEX on any descriptor.
        #expect(e.call(54, [20, 0x2000_6601, 0]).value == 0)
        #expect(e.call(92, [20, 1, 0]).value == 1)
        // Every write end must close before EOF.
        for fd in [w, d, 20, 30] { e.call(6, [UInt64(fd)]) }
        e.call(92, [UInt64(r), 4, 4])
        #expect(e.read(r).0.errno == 35)
        e.call(6, [10])
        #expect(e.read(r).0.value == 0)
    }

    @Test func vectoredIOOnAPipe() throws {
        let e = try DEnv()
        let (r, w) = e.pipe()
        let base = DEnv.scratch
        e.put(Array("abc".utf8), at: base + 0x1000)
        e.put(Array("defg".utf8), at: base + 0x1100)
        var iov: [UInt8] = []
        iov += leBytes(base + 0x1000) + leBytes(3) + leBytes(base + 0x1100) + leBytes(4)
        e.put(iov, at: base + 0x800)
        #expect(e.call(121, [UInt64(w), base + 0x800, 2]).value == 7)
        var out: [UInt8] = []
        out += leBytes(base + 0x2000) + leBytes(2) + leBytes(base + 0x2100) + leBytes(10)
        e.put(out, at: base + 0x900)
        #expect(e.call(120, [UInt64(r), base + 0x900, 2]).value == 7)
        #expect(e.get(base + 0x2000, 2) == Array("ab".utf8))
        #expect(e.get(base + 0x2100, 5) == Array("cdefg".utf8))
    }

    @Test func blockedReaderIsWokenFromAnotherHostThread() throws {
        let e = try DEnv()
        let (r, w) = e.pipe()
        let reader = HostThread { e.read(r, 16, at: DEnv.scratch + 0x5000) }
        Thread.sleep(forTimeInterval: 0.15)
        #expect(reader.result == nil)  // still blocked
        #expect(e.write(w, "wake").value == 4)
        let got = try #require(reader.wait())
        #expect(got.1 == "wake")
    }

    @Test func blockedReaderGetsEOFWhenTheLastWriterCloses() throws {
        let e = try DEnv()
        let (r, w) = e.pipe()
        let reader = HostThread { e.read(r, 16, at: DEnv.scratch + 0x5000) }
        Thread.sleep(forTimeInterval: 0.1)
        e.call(6, [UInt64(w)])
        let got = try #require(reader.wait())
        #expect(got.0.value == 0)
    }

    @Test func blockedWriterResumesWhenTheReaderDrains() throws {
        let e = try DEnv()
        let (r, w) = e.pipe()
        e.put([UInt8](repeating: 0x62, count: 0x18000), at: DEnv.scratch + 0x10000)
        let writer = HostThread { e.call(4, [UInt64(w), DEnv.scratch + 0x10000, 70000]) }
        Thread.sleep(forTimeInterval: 0.1)
        #expect(writer.result == nil)
        var total = 0
        while total < 70000 {
            let (res, _) = e.read(r, 30000, at: DEnv.scratch + 0x30000)
            total += Int(res.value ?? 0)
        }
        #expect(writer.wait()?.value == 70000)
    }

    @Test func sendtoOnANonSocketKeepsStage4aBehavior() throws {
        let e = try DEnv()
        e.putString("<5>hello log\n", at: DEnv.scratch + 0x40)
        #expect(e.call(133, [0, DEnv.scratch + 0x40, 13, 0, 0, 0]).errno == 38)
        #expect(e.sink.lines.contains("note: sendto message: <5>hello log"))
        #expect(e.call(133, [55, DEnv.scratch + 0x40, 13, 0, 0, 0]).errno == 9)
    }

    @Test func pathCalls() throws {
        let e = try DEnv()
        let path = DEnv.scratch + 0x100
        e.putString(e.writable, at: path)
        #expect(e.call(12, [path]).value == 0)
        #expect(e.kernel.fileSystem.cwd == e.writable)
        e.putString("f", at: path)
        let fd = e.call(5, [path, 0x0201, 0o644]).fd  // O_WRONLY | O_CREAT, cwd-relative
        #expect(fd >= 3)
        #expect(e.call(10, [path]).value == 0)
        #expect(e.call(10, [path]).errno == 2)
        e.putString(e.root, at: path)
        let dfd = e.call(5, [path, 0x10_0000, 0]).fd
        #expect(e.call(13, [UInt64(dfd)]).value == 0)
        #expect(e.kernel.fileSystem.cwd == e.root)
    }
}
