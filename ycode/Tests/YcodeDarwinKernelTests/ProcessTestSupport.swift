import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// A launched image that never runs (no VM).
final class FakeImage: LaunchedImage, @unchecked Sendable {
    var resumed = 0
    func resume() { resumed += 1 }
}

/// A `ProcessLauncher` that makes no VM: it records each request and the
/// kernel, and can be told to fail.
final class FakeLauncher: ProcessLauncher, @unchecked Sendable {
    struct Launch {
        let request: ProcessImageRequest
        let kernel: DarwinKernel
        let image: FakeImage
    }

    var launches: [Launch] = []
    /// When set, the next launch throws this errno.
    var failNext: Int32?

    func launch(_ request: ProcessImageRequest, kernel: DarwinKernel) throws -> any LaunchedImage {
        if let e = failNext {
            failNext = nil
            throw DarwinErrnoError(e)
        }
        let image = FakeImage()
        launches.append(Launch(request: request, kernel: kernel, image: image))
        return image
    }
}

/// A system with a fake launcher, a root process (pid 100), one guest
/// address space per kernel, and an executable in a temporary directory.
final class ProcEnv: @unchecked Sendable {
    static let scratch: UInt64 = 0x1_0000_0000
    static let scratchSize: UInt64 = 0x40000

    let system = DarwinSystem()
    let launcher = FakeLauncher()
    let root: String
    let exe: String
    let sink = Sink()
    var exits: [(pid: Int32, status: Int32)] = []
    private var spaces: [ObjectIdentifier: GuestAddressSpace] = [:]
    var rootKernel: DarwinKernel!

    init() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        let dir = tmp.appendingPathComponent("ycode-proc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        root = dir.path
        exe = root + "/probe"
        try Data(Self.machO()).write(to: URL(fileURLWithPath: exe))
        system.launcher = launcher
        system.processExited = { [unowned self] pid, status in self.exits.append((pid, status)) }
        let sink = sink
        let fs = DarwinFileSystem(
            prefixes: [.init(guestPath: root, hostPath: root, writable: true)],
            console: { fd, bytes in sink.console[fd, default: []] += bytes })
        rootKernel = try system.spawnInitialProcess(
            ProcessImageRequest(executablePath: exe, hostExecutablePath: exe, argv: [exe], envp: []), fileSystem: fs)
    }

    deinit {
        system.processExited = nil
        system.terminateAllProcesses()
    }

    /// A minimal arm64 iOS-simulator `MH_EXECUTE` header with one
    /// LC_BUILD_VERSION (`cputype`/`platform` overridable).
    static func machO(cpu: UInt32 = 0x0100_000C, platform: UInt32 = 7, fileType: UInt32 = 2) -> [UInt8] {
        var b: [UInt8] = []
        for v: UInt32 in [0xFEED_FACF, cpu, 0, fileType, 1, 24, 0, 0] { b.appendLE(v) }
        for v: UInt32 in [0x32, 24, platform, 0x1A_0000, 0x1A_0000, 0] { b.appendLE(v) }
        return b
    }

    /// The guest memory of `kernel` (made on first use, with a scratch region).
    func space(_ kernel: DarwinKernel) -> GuestAddressSpace {
        system.lock.withLock {
            if let s = spaces[ObjectIdentifier(kernel)] { return s }
            let s = GuestAddressSpace(backing: FakePhysicalBacking())
            _ = try! s.mapAnonymous(at: Self.scratch, size: Self.scratchSize, protection: .readWrite, hint: nil)
            spaces[ObjectIdentifier(kernel)] = s
            return s
        }
    }

    /// One trap of `kernel` (main thread unless `context`).
    @discardableResult
    func svc(_ kernel: DarwinKernel, _ x16: UInt64, _ args: [UInt64] = [], context: ThreadContext? = nil)
        -> (DarwinKernel.Outcome, TrapFrame) {
        var f = TrapFrame()
        f.kind = TrapFrame.Kind.svc.rawValue
        f.x[16] = x16
        for (i, v) in args.enumerated() { f.x[i] = v }
        let o = kernel.handleTrying(&f, context: context ?? kernel.mainThread, memory: space(kernel))
        return (o, f)
    }

    /// x0 of a BSD call, or `-errno` when carry is set.
    func bsd(_ kernel: DarwinKernel, _ n: UInt64, _ args: [UInt64] = []) -> Int64 {
        let (_, f) = svc(kernel, n, args)
        return f.carry ? -Int64(f.x[0]) : Int64(bitPattern: f.x[0])
    }

    func put(_ kernel: DarwinKernel, _ bytes: [UInt8], at va: UInt64) {
        let s = space(kernel)
        system.lock.withLock { try! s.write(va: va, bytes: bytes) }
    }

    func putString(_ kernel: DarwinKernel, _ text: String, at va: UInt64) { put(kernel, Array(text.utf8) + [0], at: va) }

    func read(_ kernel: DarwinKernel, _ va: UInt64, _ n: Int) -> [UInt8] {
        let s = space(kernel)
        return system.lock.withLock { try! s.read(va: va, count: n) }
    }

    func u32(_ kernel: DarwinKernel, _ va: UInt64) -> UInt32 { read(kernel, va, 4).readLE(UInt32.self, at: 0) }

    /// Layout of the spawn scratch area in the caller's memory.
    enum At {
        static let path = scratch + 0x0
        static let argvStrings = scratch + 0x400
        static let argv = scratch + 0x800
        static let pid = scratch + 0x900
        static let desc = scratch + 0xA00
        static let attr = scratch + 0xB00
        static let ports = scratch + 0xC00
        static let actions = scratch + 0x1000
        static let out = scratch + 0x8000
        static let events = scratch + 0x9000
    }

    /// Calls `posix_spawn` in `kernel`. Returns (errno or 0, child pid).
    @discardableResult
    func spawn(from kernel: DarwinKernel, path: String? = nil, argv: [String] = ["probe", "child"],
               flags: UInt16? = nil, pgroup: Int32 = 0, sigmask: UInt32 = 0, fileActions: [SpawnFileAction] = [],
               apptype: UInt32 = 0)
        -> (outcome: DarwinKernel.Outcome, errno: Int32, pid: Int32) {
        putString(kernel, path ?? exe, at: At.path)
        var cursor = At.argvStrings
        var pointers: [UInt8] = []
        for s in argv {
            putString(kernel, s, at: cursor)
            pointers += leBytes(cursor)
            cursor += UInt64(s.utf8.count + 1)
        }
        pointers += leBytes(0)
        put(kernel, pointers, at: At.argv)
        put(kernel, leBytes(0), at: At.pid)
        var desc = [UInt8](repeating: 0, count: 144)
        if let flags {
            var attr = [UInt8](repeating: 0, count: 248)
            attr.putLE(flags, at: 0)
            attr.putLE(sigmask, at: 8)
            attr.putLE(pgroup, at: 12)
            attr.putLE(apptype, at: 36)
            for i in 0..<4 { attr.putLE(UInt32.max, at: 112 + 4 * i) }
            put(kernel, attr, at: At.attr)
            desc.putLE(UInt64(248), at: 0)
            desc.putLE(At.attr, at: 8)
        }
        if !fileActions.isEmpty {
            var block = [UInt8](repeating: 0, count: 8 + 1040 * fileActions.count)
            block.putLE(Int32(fileActions.count), at: 0)
            block.putLE(Int32(fileActions.count), at: 4)
            for (i, a) in fileActions.enumerated() {
                let o = 8 + 1040 * i
                block.putLE(a.type, at: o)
                block.putLE(a.fd, at: o + 4)
                switch SpawnFileAction.Kind(rawValue: a.type) {
                case .open:
                    block.putLE(a.oflag, at: o + 8)
                    block.putLE(a.mode, at: o + 12)
                    block.put(Array(a.path.utf8), at: o + 14)
                case .dup2, .fileportDup2:
                    block.putLE(a.newfd, at: o + 8)
                case .chdir:
                    block.put(Array(a.path.utf8), at: o + 8)
                default:
                    break
                }
            }
            put(kernel, block, at: At.actions)
            desc.putLE(UInt64(block.count), at: 16)
            desc.putLE(At.actions, at: 24)
        }
        let hasDesc = flags != nil || !fileActions.isEmpty
        if hasDesc { put(kernel, desc, at: At.desc) }
        let (o, f) = svc(kernel, 244, [At.pid, At.path, hasDesc ? At.desc : 0, At.argv, 0])
        if o != .resume { return (o, 0, 0) }
        return (o, f.carry ? Int32(f.x[0]) : 0, f.carry ? 0 : Int32(bitPattern: u32(kernel, At.pid)))
    }

    /// The kernel the launcher was given for `pid` most recently.
    func kernel(_ pid: Int32) -> DarwinKernel? { system.kernel(forPID: pid) }

    /// `wait4(pid, &status, options)`: (result or -errno, status).
    func wait4(_ kernel: DarwinKernel, _ pid: Int32, options: Int32 = 0) -> (Int64, Int32) {
        put(kernel, [0xEE, 0xEE, 0xEE, 0xEE], at: At.out)
        let r = bsd(kernel, 7, [UInt64(UInt32(bitPattern: pid)), At.out, UInt64(options), 0])
        return (r, Int32(bitPattern: u32(kernel, At.out)))
    }

    /// One kevent64 change (48 bytes).
    static func kevent64(ident: UInt64, filter: Int16, flags: UInt16, fflags: UInt32 = 0, data: Int64 = 0) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 48)
        b.putLE(ident, at: 0)
        b.putLE(filter, at: 8)
        b.putLE(flags, at: 10)
        b.putLE(fflags, at: 12)
        b.putLE(data, at: 16)
        return b
    }

    /// `kevent64(kq, changes, …, events, nevents, flags, timeout)`; a zero
    /// timeout when `timeoutNs` is set. Returns (result or -errno, events).
    func kevent64(_ kernel: DarwinKernel, kq: Int32, changes: [[UInt8]], nevents: Int, timeoutNs: UInt64? = 0)
        -> (Int64, [(ident: UInt64, filter: Int16, flags: UInt16, fflags: UInt32, data: Int64)]) {
        let changeVA = At.events, eventVA = At.events + 0x1000, tsVA = At.events + 0x2000
        put(kernel, changes.flatMap { $0 }, at: changeVA)
        if let ns = timeoutNs { put(kernel, leBytes(ns / 1_000_000_000) + leBytes(ns % 1_000_000_000), at: tsVA) }
        let r = bsd(kernel, 369, [UInt64(UInt32(bitPattern: kq)), changeVA, UInt64(changes.count), eventVA,
                                  UInt64(nevents), 0, timeoutNs == nil ? 0 : tsVA])
        var events: [(UInt64, Int16, UInt16, UInt32, Int64)] = []
        if r > 0 {
            let b = read(kernel, eventVA, 48 * Int(r))
            for i in 0..<Int(r) {
                let o = 48 * i
                events.append((b.readLE(UInt64.self, at: o), b.readLE(Int16.self, at: o + 8), b.readLE(UInt16.self, at: o + 10),
                               b.readLE(UInt32.self, at: o + 12), b.readLE(Int64.self, at: o + 16)))
            }
        }
        return (r, events)
    }

    /// `sigaction(sig, {handler})`.
    func sigaction(_ kernel: DarwinKernel, _ sig: Int32, handler: UInt64, flags: Int32 = 0) {
        var b = leBytes(handler) + leBytes(0)
        b.appendLE(UInt32(0))
        b.appendLE(flags)
        put(kernel, b, at: At.out + 0x100)
        _ = bsd(kernel, 46, [UInt64(sig), At.out + 0x100, 0])
    }
}
