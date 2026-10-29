import Foundation
import Synchronization
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// BSD descriptor and lookup traps without the kernel lock
/// (`handleBSDFast`, bsd-locking.md): the locked path's answers, the
/// fallbacks, the close hook, and concurrent use of one descriptor table.
@Suite(.serialized) struct BSDFastPathTests {
    typealias At = ProcEnv.At
    static let pathVA = ProcEnv.scratch + 0x9000
    static let buf1 = ProcEnv.scratch + 0xA000
    static let buf2 = ProcEnv.scratch + 0xB000

    private func frame(_ n: UInt64, _ args: [UInt64]) -> TrapFrame {
        var f = TrapFrame()
        f.kind = TrapFrame.Kind.svc.rawValue
        f.x[16] = n
        for (i, v) in args.enumerated() { f.x[i] = v }
        return f
    }

    private func value(_ f: TrapFrame) -> Int64 { f.carry ? -Int64(f.x[0]) : Int64(bitPattern: f.x[0]) }

    /// The fast path's answer (x0 or -errno), nil when it fell back.
    private func fast(_ env: ProcEnv, _ k: DarwinKernel, _ n: UInt64, _ args: [UInt64]) -> Int64? {
        var f = frame(n, args)
        guard k.handleBSDFast(&f, context: k.mainThread, memory: env.space(k)) != nil else { return nil }
        return value(f)
    }

    /// The locked path's answer.
    private func locked(_ env: ProcEnv, _ k: DarwinKernel, _ n: UInt64, _ args: [UInt64]) -> Int64 {
        var f = frame(n, args)
        _ = k.handle(&f, context: k.mainThread, memory: env.space(k))
        return value(f)
    }

    private func setUp() throws -> (ProcEnv, DarwinKernel, String) {
        let env = try ProcEnv()
        let k = env.rootKernel!
        k.tracing = false
        let path = env.root + "/data.bin"
        try Data((0..<100).map { UInt8($0) }).write(to: URL(fileURLWithPath: path))
        env.putString(k, path, at: Self.pathVA)
        return (env, k, path)
    }

    @Test func answersMatchTheLockedPath() throws {
        let (env, k, path) = try setUp()
        let fdA = try #require(fast(env, k, 5, [Self.pathVA, 0, 0]))
        let fdB = locked(env, k, 5, [Self.pathVA, 0, 0])
        #expect(fdA >= 3 && fdB >= 3 && fdA != fdB)
        // read, pread
        #expect(fast(env, k, 3, [UInt64(fdA), Self.buf1, 10]) == 10)
        #expect(locked(env, k, 3, [UInt64(fdB), Self.buf2, 10]) == 10)
        #expect(env.read(k, Self.buf1, 10) == env.read(k, Self.buf2, 10))
        #expect(fast(env, k, 153, [UInt64(fdA), Self.buf1, 8, 50]) == 8)
        #expect(locked(env, k, 153, [UInt64(fdB), Self.buf2, 8, 50]) == 8)
        #expect(env.read(k, Self.buf1, 8) == Array(50..<58).map { UInt8($0) } && env.read(k, Self.buf2, 8) == env.read(k, Self.buf1, 8))
        // lseek: SEEK_CUR after the read, SEEK_END, a negative result
        #expect(fast(env, k, 199, [UInt64(fdA), 0, 1]) == 10)
        #expect(fast(env, k, 199, [UInt64(fdA), 0, 2]) == locked(env, k, 199, [UInt64(fdB), 0, 2]))
        #expect(fast(env, k, 199, [UInt64(fdA), UInt64(bitPattern: -500), 1]) == -22)
        #expect(locked(env, k, 199, [UInt64(fdB), UInt64(bitPattern: -500), 1]) == -22)
        // fstat64
        #expect(fast(env, k, 339, [UInt64(fdA), Self.buf1]) == 0)
        #expect(locked(env, k, 339, [UInt64(fdB), Self.buf2]) == 0)
        #expect(env.read(k, Self.buf1, 144) == env.read(k, Self.buf2, 144))
        // fcntl: F_GETFL, F_SETFD/F_GETFD across the paths, F_GETPATH, a hint, a lock command falls back
        #expect(fast(env, k, 92, [UInt64(fdA), 3, 0]) == locked(env, k, 92, [UInt64(fdB), 3, 0]))
        #expect(fast(env, k, 92, [UInt64(fdA), 2, 1]) == 0)
        #expect(locked(env, k, 92, [UInt64(fdA), 1, 0]) == 1)
        #expect(fast(env, k, 92, [UInt64(fdA), 50, Self.buf1]) == 0)
        #expect(locked(env, k, 92, [UInt64(fdB), 50, Self.buf2]) == 0)
        #expect(env.read(k, Self.buf1, path.utf8.count + 1) == Array(path.utf8) + [0])
        #expect(fast(env, k, 92, [UInt64(fdA), 48, 1]) == 0)
        #expect(fast(env, k, 92, [UInt64(fdA), 9, Self.buf1]) == nil)  // F_SETLKW: the locked path (it may wait)
        #expect(fast(env, k, 92, [99, 3, 0]) == -9 && locked(env, k, 92, [99, 3, 0]) == -9)
        // F_SETFL of a host file, F_SETNOSIGPIPE/F_GETNOSIGPIPE, F_GETPROTECTIONCLASS/LEVEL (§12)
        #expect(fast(env, k, 92, [UInt64(fdA), 4, 0x4 | 0x8]) == 0 && locked(env, k, 92, [UInt64(fdB), 4, 0x4 | 0x8]) == 0)
        #expect(fast(env, k, 92, [UInt64(fdA), 3, 0]) == locked(env, k, 92, [UInt64(fdB), 3, 0]))
        #expect(locked(env, k, 92, [UInt64(fdA), 3, 0]) & 0xC == 0xC)
        #expect(fast(env, k, 92, [UInt64(fdA), 4, 0]) == 0 && locked(env, k, 92, [UInt64(fdA), 3, 0]) & 0xC == 0)
        #expect(fast(env, k, 92, [99, 4, 0]) == -9 && locked(env, k, 92, [99, 4, 0]) == -9)
        #expect(fast(env, k, 92, [UInt64(fdA), 73, 1]) == 0 && locked(env, k, 92, [UInt64(fdA), 74, 0]) == 1)
        #expect(fast(env, k, 92, [UInt64(fdA), 74, 0]) == 1 && fast(env, k, 92, [UInt64(fdA), 73, 0]) == 0)
        #expect(fast(env, k, 92, [UInt64(fdA), 63, 0]) == locked(env, k, 92, [UInt64(fdB), 63, 0]))
        #expect(fast(env, k, 92, [UInt64(fdA), 77, 0]) == locked(env, k, 92, [UInt64(fdB), 77, 0]))
        #expect(fast(env, k, 92, [UInt64(fdA), 64, 3]) == nil)
        // access, fstatat
        #expect(fast(env, k, 33, [Self.pathVA, 4]) == 0 && locked(env, k, 33, [Self.pathVA, 4]) == 0)
        #expect(fast(env, k, 470, [UInt64(bitPattern: -2), Self.pathVA, Self.buf1, 0]) == 0)
        #expect(locked(env, k, 470, [UInt64(bitPattern: -2), Self.pathVA, Self.buf2, 0]) == 0)
        #expect(env.read(k, Self.buf1, 144) == env.read(k, Self.buf2, 144))
        env.putString(k, env.root + "/missing", at: Self.buf2 + 0x800)
        #expect(fast(env, k, 33, [Self.buf2 + 0x800, 0]) == -2 && locked(env, k, 33, [Self.buf2 + 0x800, 0]) == -2)
        #expect(fast(env, k, 5, [Self.buf2 + 0x800, 0, 0]) == -2 && locked(env, k, 5, [Self.buf2 + 0x800, 0, 0]) == -2)
        // sysctl: by name and by MIB; kern.proc falls back
        env.putString(k, "hw.ncpu", at: Self.buf2 + 0x800)
        env.put(k, leBytes(4), at: Self.buf2 + 0x900)
        env.put(k, leBytes(4), at: Self.buf2 + 0x908)
        #expect(fast(env, k, 274, [Self.buf2 + 0x800, 7, Self.buf1, Self.buf2 + 0x900, 0, 0]) == 0)
        #expect(locked(env, k, 274, [Self.buf2 + 0x800, 7, Self.buf2, Self.buf2 + 0x908, 0, 0]) == 0)
        #expect(env.read(k, Self.buf1, 4) == env.read(k, Self.buf2, 4))
        var mib: [UInt8] = []
        for v: Int32 in [6, 3, 1, 14, 1, 100] { mib.appendLE(v) }
        env.put(k, mib, at: Self.buf2 + 0xA00)
        #expect(fast(env, k, 202, [Self.buf2 + 0xA00, 2, Self.buf1, Self.buf2 + 0x900, 0, 0]) == 0)
        // kern.proc.pid reads the process table under its lock (§13): the locked path's answer.
        env.put(k, leBytes(648), at: Self.buf2 + 0x900)
        env.put(k, leBytes(648), at: Self.buf2 + 0x908)
        #expect(fast(env, k, 202, [Self.buf2 + 0xA08, 4, Self.buf1, Self.buf2 + 0x900, 0, 0])
            == locked(env, k, 202, [Self.buf2 + 0xA08, 4, Self.buf2, Self.buf2 + 0x908, 0, 0]))
        #expect(env.read(k, Self.buf2 + 0x900, 8) == env.read(k, Self.buf2 + 0x908, 8))
        #expect(fast(env, k, 327, []) == 0)
        // dup, F_DUPFD_CLOEXEC, __mac_syscall
        let dupFD = try #require(fast(env, k, 41, [UInt64(fdA)]))
        #expect(dupFD > fdB && locked(env, k, 92, [UInt64(dupFD), 1, 0]) == 0)
        let dupFD2 = try #require(fast(env, k, 92, [UInt64(fdA), 67, 100]))
        #expect(dupFD2 == 100 && locked(env, k, 92, [100, 1, 0]) == 1)
        #expect(fast(env, k, 41, [99]) == -9 && locked(env, k, 41, [99]) == -9)
        #expect(locked(env, k, 6, [UInt64(dupFD)]) == 0 && fast(env, k, 6, [100]) == 0)
        env.putString(k, "Sandbox", at: Self.buf2 + 0xD00)
        env.putString(k, "Quarantine", at: Self.buf2 + 0xD80)
        #expect(fast(env, k, 381, [Self.buf2 + 0xD00, 2, 0]) == 0 && locked(env, k, 381, [Self.buf2 + 0xD00, 2, 0]) == 0)
        #expect(fast(env, k, 381, [Self.buf2 + 0xD80, 1, 0]) == -103 && locked(env, k, 381, [Self.buf2 + 0xD80, 1, 0]) == -103)
        // The extension calls (§12): the locked path's answers.
        #expect(fast(env, k, 381, [Self.buf2 + 0xD00, 5, 0x10]) == locked(env, k, 381, [Self.buf2 + 0xD00, 5, 0x10]))
        #expect(fast(env, k, 381, [Self.buf2 + 0xD00, 7, 0]) == 0 && locked(env, k, 381, [Self.buf2 + 0xD00, 7, 0]) == 0)
        #expect(fast(env, k, 381, [Self.buf2 + 0xD00, 9, 0]) == -103 && locked(env, k, 381, [Self.buf2 + 0xD00, 9, 0]) == -103)
        env.putString(k, "com.apple.app-sandbox.read", at: Self.buf2 + 0xE00)
        env.putString(k, env.root, at: Self.buf2 + 0xE80)
        var block = leBytes(Self.buf2 + 0xE00) + leBytes(0) + leBytes(Self.buf2 + 0xE80) + leBytes(0) + leBytes(Self.buf1)
        env.put(k, block, at: Self.buf2 + 0xF00)
        #expect(fast(env, k, 381, [Self.buf2 + 0xD00, 5, Self.buf2 + 0xF00]) == 0)
        let tokenA = env.read(k, Self.buf1, 512).prefix { $0 != 0 }
        block = leBytes(Self.buf2 + 0xE00) + leBytes(0) + leBytes(Self.buf2 + 0xE80) + leBytes(0) + leBytes(Self.buf1 + 0x800)
        env.put(k, block, at: Self.buf2 + 0xF00)
        #expect(locked(env, k, 381, [Self.buf2 + 0xD00, 5, Self.buf2 + 0xF00]) == 0)
        #expect(!tokenA.isEmpty && Array(tokenA) == Array(env.read(k, Self.buf1 + 0x800, 512).prefix { $0 != 0 }))
        // openat relative to a directory descriptor; a directory's close falls back
        env.putString(k, env.root, at: Self.buf2 + 0x800)
        let dirFD = try #require(fast(env, k, 5, [Self.buf2 + 0x800, 0x100000, 0]))
        #expect(dirFD >= 3)
        env.putString(k, "data.bin", at: Self.buf2 + 0xB00)
        let relFD = try #require(fast(env, k, 463, [UInt64(dirFD), Self.buf2 + 0xB00, 0, 0]))
        #expect(relFD >= 3 && fast(env, k, 3, [UInt64(relFD), Self.buf1, 4]) == 4)
        // A directory closes on the fast path too (§14); with the switch off, on L0.
        DarwinKernel.fastDirectoryEnabled = false
        #expect(fast(env, k, 6, [UInt64(dirFD)]) == nil)
        DarwinKernel.fastDirectoryEnabled = true
        #expect(fast(env, k, 6, [UInt64(dirFD)]) == 0)
        // close, then EBADF on both paths
        #expect(fast(env, k, 6, [UInt64(fdA)]) == 0)
        #expect(fast(env, k, 6, [UInt64(fdA)]) == nil && locked(env, k, 6, [UInt64(fdA)]) == -9)
        #expect(fast(env, k, 3, [UInt64(fdA), Self.buf1, 4]) == nil)  // the locked path answers EBADF
        #expect(locked(env, k, 3, [UInt64(fdA), Self.buf1, 4]) == -9)
        #expect(fast(env, k, 6, [UInt64(relFD)]) == 0 && locked(env, k, 6, [UInt64(fdB)]) == 0)
    }

    @Test func getattrlistAndMmapMatchTheLockedPath() throws {
        let (env, k, _) = try setUp()
        // getattrlist(path, alist, buf, 512, 0): NAME, OBJTYPE, FILEID,
        // DATA_PROTECT_FLAGS, RETURNED_ATTRS; and fgetattrlist.
        var alist = [UInt8](repeating: 0, count: 24)
        alist.putLE(UInt16(5), at: 0)
        alist.putLE(UInt32(0x1 | 0x8 | 0x2000000 | 0x40000000 | 0x8000_0000), at: 4)
        env.put(k, alist, at: Self.buf2 + 0xC00)
        #expect(fast(env, k, 220, [Self.pathVA, Self.buf2 + 0xC00, Self.buf1, 512, 0]) == 0)
        #expect(locked(env, k, 220, [Self.pathVA, Self.buf2 + 0xC00, Self.buf2, 512, 0]) == 0)
        #expect(env.read(k, Self.buf1, 512) == env.read(k, Self.buf2, 512))
        let fd = try #require(fast(env, k, 5, [Self.pathVA, 0, 0]))
        #expect(fast(env, k, 228, [UInt64(fd), Self.buf2 + 0xC00, Self.buf1, 512, 0]) == 0)
        #expect(locked(env, k, 228, [UInt64(fd), Self.buf2 + 0xC00, Self.buf2, 512, 0]) == 0)
        #expect(env.read(k, Self.buf1, 512) == env.read(k, Self.buf2, 512))
        env.putString(k, env.root + "/missing", at: Self.buf2 + 0x800)
        #expect(fast(env, k, 220, [Self.buf2 + 0x800, Self.buf2 + 0xC00, Self.buf1, 512, 0]) == -2)
        // mmap of the file, private, read-only: the same bytes at both addresses.
        let page: UInt64 = 0x4000
        let va1 = try #require(fast(env, k, 197, [0, page, 1, 2, UInt64(fd), 0]))
        let va2 = locked(env, k, 197, [0, page, 1, 2, UInt64(fd), 0])
        #expect(va1 > 0 && va2 > 0 && va1 != va2)
        #expect(env.read(k, UInt64(va1), 100) == Array(0..<100).map { UInt8($0) })
        #expect(env.read(k, UInt64(va2), 100) == env.read(k, UInt64(va1), 100))
        // Anonymous, and errors: a closed descriptor (EBADF), a pipe (ENODEV).
        #expect(try #require(fast(env, k, 197, [0, page, 3, 0x1002, UInt64(bitPattern: -1), 0])) > 0)
        #expect(fast(env, k, 197, [0, page, 1, 2, 77, 0]) == -9 && locked(env, k, 197, [0, page, 1, 2, 77, 0]) == -9)
        var f = frame(42, [])
        _ = k.handle(&f, context: k.mainThread, memory: env.space(k))
        #expect(fast(env, k, 197, [0, page, 1, 2, f.x[0], 0]) == -19 && locked(env, k, 197, [0, page, 1, 2, f.x[0], 0]) == -19)
        // A POSIX shared memory object falls back.
        env.putString(k, "ycode.fast.shm", at: Self.buf2 + 0x800)
        let shm = locked(env, k, 266, [Self.buf2 + 0x800, 0x202, 0o644])
        #expect(shm >= 3 && locked(env, k, 201, [UInt64(shm), page]) == 0)
        #expect(fast(env, k, 197, [0, page, 3, 1, UInt64(shm), 0]) == nil)
        #expect(locked(env, k, 197, [0, page, 3, 1, UInt64(shm), 0]) > 0)
        _ = locked(env, k, 267, [Self.buf2 + 0x800])
    }

    /// getdirentries64 and a directory's close without L0 (bsd-locking.md
    /// §14): the locked path's records, positions and end flag, read in
    /// small pieces on two descriptors of one directory; the fast close
    /// drops the cursor; readers racing closes of their descriptor.
    @Test func directoryReadsMatchTheLockedPath() throws {
        let (env, k, _) = try setUp()
        for i in 0..<40 { try Data([UInt8(i)]).write(to: URL(fileURLWithPath: env.root + "/entry-\(i).txt")) }
        env.putString(k, env.root, at: Self.pathVA)
        let fdA = try #require(fast(env, k, 5, [Self.pathVA, 0x100000, 0]))  // O_RDONLY | O_DIRECTORY
        let fdB = locked(env, k, 5, [Self.pathVA, 0x100000, 0])
        #expect(fdA >= 3 && fdB >= 3)
        var listingA: [UInt8] = [], listingB: [UInt8] = []
        for _ in 0..<40 {
            let a = try #require(fast(env, k, 344, [UInt64(fdA), Self.buf1, 1024, Self.buf1 + 0x800]))
            let b = locked(env, k, 344, [UInt64(fdB), Self.buf2, 1024, Self.buf2 + 0x800])
            #expect(a == b)
            #expect(env.read(k, Self.buf1, 1024) == env.read(k, Self.buf2, 1024))       // records and the end flag
            #expect(env.read(k, Self.buf1 + 0x800, 8) == env.read(k, Self.buf2 + 0x800, 8))  // position
            if a <= 0 { break }
            listingA += env.read(k, Self.buf1, Int(a))
            listingB += env.read(k, Self.buf2, Int(b))
        }
        #expect(listingA == listingB && listingA.count > 40 * 24)
        // A buffer too small for one record: EINVAL on both paths.
        _ = locked(env, k, 199, [UInt64(fdB), 0, 0])
        #expect(fast(env, k, 344, [UInt64(fdA), Self.buf1, 8, 0]) == locked(env, k, 344, [UInt64(fdB), Self.buf2, 8, 0]))
        // A regular file: ENOTDIR on both.
        #expect(fast(env, k, 344, [0, Self.buf1, 1024, 0]) == locked(env, k, 344, [0, Self.buf2, 1024, 0]))
        // The fast close of a directory drops its cursor.
        #expect(k.extended.directoryCursors[Int32(fdA)] != nil)
        #expect(fast(env, k, 6, [UInt64(fdA)]) == 0)
        #expect(k.extended.directoryCursors[Int32(fdA)] == nil)
        #expect(fast(env, k, 344, [UInt64(fdA), Self.buf1, 1024, 0]) == -9)
        // Readers on fast paths while another thread opens and closes directory descriptors.
        let box = Shared(kernel: k, space: env.space(k))
        let stop = Atomic<Bool>(false)
        let wait = spawnThread { () -> Int in
            let k = box.kernel, space = box.space
            var reads = 0
            while !stop.load(ordering: .relaxed) {
                for fd: UInt64 in 3...12 {
                    var f = TrapFrame()
                    f.kind = TrapFrame.Kind.svc.rawValue
                    f.x[16] = 344
                    f.x[0] = fd
                    f.x[1] = ProcEnv.scratch + 0xC000
                    f.x[2] = 2048
                    guard k.handleBSDFast(&f, context: k.mainThread, memory: space) != nil else { return -1 }
                    reads += 1
                }
            }
            return reads
        }
        for _ in 0..<300 {
            let fd = fast(env, k, 5, [Self.pathVA, 0x100000, 0]) ?? -1
            _ = fast(env, k, 344, [UInt64(fd), Self.buf1, 1024, 0])
            #expect(fast(env, k, 6, [UInt64(fd)]) == 0)
        }
        stop.store(true, ordering: .relaxed)
        #expect((wait() ?? -9) > 0)
        _ = locked(env, k, 6, [UInt64(fdB)])
    }

    /// The small traps that left L0 (bsd-locking.md §12): gettimeofday,
    /// thread_selfid and getentropy on the BSD fast path; munmap, mprotect
    /// and mach_absolute_time as task-local traps. Same answers as the
    /// locked path.
    @Test func smallTrapsMatchTheLockedPath() throws {
        let (env, k, _) = try setUp()
        let space = env.space(k)
        func taskLocal(_ n: UInt64, _ args: [UInt64]) -> Int64? {
            var f = frame(n, args)
            return k.handleTaskLocal(&f, context: k.mainThread, memory: space) == nil ? nil : value(f)
        }
        #expect(fast(env, k, 372, []) == locked(env, k, 372, []))
        #expect(fast(env, k, 500, [Self.buf1, 300]) == -22 && locked(env, k, 500, [Self.buf1, 300]) == -22)
        env.put(k, [UInt8](repeating: 0, count: 32), at: Self.buf1)
        #expect(fast(env, k, 500, [Self.buf1, 32]) == 0)
        #expect(env.read(k, Self.buf1, 32) != [UInt8](repeating: 0, count: 32))
        env.put(k, [UInt8](repeating: 0xFF, count: 32), at: Self.buf1)
        env.put(k, [UInt8](repeating: 0xFF, count: 32), at: Self.buf2)
        #expect(fast(env, k, 116, [Self.buf1, Self.buf1 + 16, Self.buf1 + 24]) == 0)
        #expect(locked(env, k, 116, [Self.buf2, Self.buf2 + 16, Self.buf2 + 24]) == 0)
        let a = env.read(k, Self.buf1, 32), b = env.read(k, Self.buf2, 32)
        #expect(a[16..<24].allSatisfy { $0 == 0 } && b[16..<24].allSatisfy { $0 == 0 })
        #expect(abs(Int64(u64(a, 0)) - Int64(u64(b, 0))) <= 1 && u64(a, 24) <= u64(b, 24))
        #expect(fast(env, k, 116, [0x10, 0, 0]) == -14 && locked(env, k, 116, [0x10, 0, 0]) == -14)
        // iopolicysys: set on one path, read on the other; process, thread and background scopes; EINVAL.
        for (scope, iotype, policy) in [(Int32(0), Int32(9), Int32(1)), (1, 3, 4), (2, 0, 2)] {
            env.put(k, le32(UInt32(bitPattern: scope)) + le32(UInt32(bitPattern: iotype)) + le32(UInt32(bitPattern: policy)), at: Self.buf1)
            #expect(fast(env, k, 322, [0, Self.buf1]) == 0)
            env.put(k, le32(UInt32(bitPattern: scope)) + le32(UInt32(bitPattern: iotype)) + le32(0), at: Self.buf2)
            #expect(locked(env, k, 322, [1, Self.buf2]) == 0 && env.read(k, Self.buf2 + 8, 4) == le32(UInt32(bitPattern: policy)))
            env.put(k, le32(0), at: Self.buf1 + 8)
            #expect(fast(env, k, 322, [1, Self.buf1]) == 0 && env.read(k, Self.buf1 + 8, 4) == le32(UInt32(bitPattern: policy)))
        }
        env.put(k, le32(7) + le32(0) + le32(0), at: Self.buf1)
        #expect(fast(env, k, 322, [1, Self.buf1]) == -22 && locked(env, k, 322, [1, Self.buf1]) == -22)
        // mkdir, readlink, statfs64, fstatfs64, fsync: the locked path's answers.
        env.putString(k, env.root + "/newdir", at: Self.buf1 + 0x200)
        #expect(fast(env, k, 136, [Self.buf1 + 0x200, 0o755]) == 0)
        #expect(locked(env, k, 136, [Self.buf1 + 0x200, 0o755]) == -17 && fast(env, k, 136, [Self.buf1 + 0x200, 0o755]) == -17)
        try FileManager.default.createSymbolicLink(atPath: env.root + "/link", withDestinationPath: "data.bin")
        env.putString(k, env.root + "/link", at: Self.buf1 + 0x300)
        #expect(fast(env, k, 58, [Self.buf1 + 0x300, Self.buf1 + 0x400, 64]) == 8)
        #expect(locked(env, k, 58, [Self.buf1 + 0x300, Self.buf2 + 0x400, 64]) == 8)
        #expect(env.read(k, Self.buf1 + 0x400, 8) == Array("data.bin".utf8) && env.read(k, Self.buf2 + 0x400, 8) == Array("data.bin".utf8))
        #expect(fast(env, k, 58, [Self.pathVA, Self.buf1, 64]) == locked(env, k, 58, [Self.pathVA, Self.buf2, 64]))  // not a link
        #expect(fast(env, k, 345, [Self.pathVA, Self.buf1 + 0x800]) == 0 && locked(env, k, 345, [Self.pathVA, Self.buf2 + 0x800]) == 0)
        #expect(env.read(k, Self.buf1 + 0x800, 2168) == env.read(k, Self.buf2 + 0x800, 2168))
        let sfd = try #require(fast(env, k, 5, [Self.pathVA, 0, 0]))
        #expect(fast(env, k, 346, [UInt64(sfd), Self.buf1 + 0x800]) == 0 && locked(env, k, 346, [UInt64(sfd), Self.buf2 + 0x800]) == 0)
        #expect(env.read(k, Self.buf1 + 0x800, 2168) == env.read(k, Self.buf2 + 0x800, 2168))
        #expect(fast(env, k, 95, [UInt64(sfd)]) == 0 && locked(env, k, 95, [UInt64(sfd)]) == 0)
        #expect(fast(env, k, 95, [99]) == locked(env, k, 95, [99]) && fast(env, k, 187, [1]) == locked(env, k, 187, [1]))
        _ = locked(env, k, 6, [UInt64(sfd)])
        // mach_absolute_time
        let t0 = try #require(taskLocal(UInt64(bitPattern: -3), []))
        let t1 = try #require(taskLocal(UInt64(bitPattern: -4), []))
        #expect(t1 >= t0 && t0 > 0)
        // munmap and mprotect
        let page: UInt64 = 0x4000
        let m = locked(env, k, 197, [0, 4 * page, 3, 0x1002, UInt64(bitPattern: -1), 0])
        #expect(m > 0)
        let va = UInt64(m)
        #expect(taskLocal(73, [va + 1, page]) == -22 && locked(env, k, 73, [va + 1, page]) == -22)
        #expect(taskLocal(73, [va, 0]) == -22 && locked(env, k, 73, [va, 0]) == -22)
        #expect(taskLocal(74, [va, page, 1]) == 0 && locked(env, k, 74, [va + page, page, 1]) == 0)
        #expect(taskLocal(73, [va, 2 * page]) == 0 && locked(env, k, 73, [va + 2 * page, 2 * page]) == 0)
        #expect(space.region(containing: va) == nil && space.region(containing: va + 3 * page) == nil)
        func lockedMach(_ n: Int64, _ args: [UInt64]) -> UInt64 {
            var f = frame(UInt64(bitPattern: n), args)
            _ = k.handle(&f, context: k.mainThread, memory: space)
            return f.x[0]
        }
        // mach_generate_activity_id: one counter on both paths.
        #expect(taskLocal(UInt64(bitPattern: -43), [0x103, 3, Self.buf1]) == 0)
        let id1 = u64(env.read(k, Self.buf1, 8), 0)
        #expect(lockedMach(-43, [0x103, 1, Self.buf1]) == 0 && u64(env.read(k, Self.buf1, 8), 0) == id1 + 1)
        #expect(taskLocal(UInt64(bitPattern: -43), [0x103, 0, Self.buf1]) == 0 && u64(env.read(k, Self.buf1, 8), 0) == id1 + 2)
        #expect(taskLocal(UInt64(bitPattern: -43), [0x103, 1, 0x10]) == 1)
        // vm_copy (Ycode private 0x7963_0004): the bytes, a bad source, a size too large.
        env.put(k, Array(0..<64), at: Self.buf1)
        #expect(taskLocal(0x7963_0004, [0x103, Self.buf1, 64, Self.buf2]) == 0)
        #expect(env.read(k, Self.buf2, 64) == Array(0..<64))
        #expect(taskLocal(0x7963_0004, [0x103, 0x10, 64, Self.buf2]) == 1 && lockedMach(0x7963_0004, [0x103, 0x10, 64, Self.buf2]) == 1)
        #expect(taskLocal(0x7963_0004, [0x103, Self.buf1, 1 << 40, Self.buf2]) == 4)
        // mach_vm_map of anonymous memory: anywhere, aligned, fixed (free, taken), a bad address word.
        env.put(k, leBytes(0), at: Self.buf1)
        #expect(taskLocal(UInt64(bitPattern: -15), [0x103, Self.buf1, 3 * page, 0, 1, 3]) == 0)
        let anywhere = u64(env.read(k, Self.buf1, 8), 0)
        #expect(anywhere != 0 && space.region(containing: anywhere) != nil)
        env.put(k, leBytes(0), at: Self.buf1)
        #expect(taskLocal(UInt64(bitPattern: -15), [0x103, Self.buf1, page, 0xF_FFFF, 1, 3]) == 0)
        let aligned = u64(env.read(k, Self.buf1, 8), 0)
        #expect(aligned % 0x10_0000 == 0 && space.region(containing: aligned) != nil)
        env.put(k, leBytes(anywhere), at: Self.buf1)
        env.put(k, leBytes(anywhere), at: Self.buf2)
        #expect(taskLocal(UInt64(bitPattern: -15), [0x103, Self.buf1, page, 0, 0, 3]) == 3   // fixed, taken: KERN_NO_SPACE
            && lockedMach(-15, [0x103, Self.buf2, page, 0, 0, 3]) == 3)
        #expect(taskLocal(UInt64(bitPattern: -15), [0x103, Self.buf1, page, 0, 0x4000, 3]) == 0)  // VM_FLAGS_OVERWRITE
        #expect(taskLocal(UInt64(bitPattern: -15), [0x103, 0x10, page, 0, 1, 3]) == 1
            && lockedMach(-15, [0x103, 0x10, page, 0, 1, 3]) == 1)                                  // KERN_INVALID_ADDRESS
        #expect(taskLocal(UInt64(bitPattern: -15), [0x103, Self.buf1, 0, 0, 1, 3]) == 4
            && lockedMach(-15, [0x103, Self.buf1, 0, 0, 1, 3]) == 4)                                // KERN_INVALID_ARGUMENT
    }

    /// vm_purgable_control as a task-local trap: the locked path's answers,
    /// one state table.
    @Test func purgeableControlIsTaskLocal() throws {
        let (env, k, _) = try setUp()
        let space = env.space(k)
        func taskLocal(_ args: [UInt64]) -> UInt64? {
            var f = frame(UInt64(bitPattern: -11), args)
            return k.handleTaskLocal(&f, context: k.mainThread, memory: space) == nil ? nil : f.x[0]
        }
        func lockedMach(_ args: [UInt64]) -> UInt64 {
            var f = frame(UInt64(bitPattern: -11), args)
            _ = k.handle(&f, context: k.mainThread, memory: space)
            return f.x[0]
        }
        let page: UInt64 = 0x3_0000_4000
        env.put(k, [1, 0, 0, 0], at: Self.buf1)
        #expect(taskLocal([0x103, page + 0x10, 0, Self.buf1]) == 0)        // SET_STATE volatile
        #expect(env.read(k, Self.buf1, 4) == [0, 0, 0, 0])                 // old: nonvolatile
        #expect(lockedMach([0x103, page, 1, Self.buf1]) == 0)             // GET_STATE
        #expect(env.read(k, Self.buf1, 4) == [1, 0, 0, 0])
        env.put(k, [2, 0, 0, 0], at: Self.buf1)
        #expect(taskLocal([0x103, page, 0, Self.buf1]) == 4 && lockedMach([0x103, page, 0, Self.buf1]) == 4)  // EMPTY
        #expect(taskLocal([0x103, page, 1, 0x10]) == 1 && lockedMach([0x103, page, 1, 0x10]) == 1)  // bad pointer
        #expect(taskLocal([0x103, page, 2, 0]) == 0 && taskLocal([0x103, page, 9, Self.buf1]) == 4)
        #expect(k.purgeableStates == [page: 1])
    }

    /// write and pwrite of a host file without L0 (frame-profile.md §5.1):
    /// the locked path's results and file contents; O_APPEND; the console,
    /// pipes and guarded descriptors fall back.
    @Test func writesMatchTheLockedPath() throws {
        let (env, k, path) = try setUp()
        let fdA = try #require(fast(env, k, 5, [Self.pathVA, 2, 0]))  // O_RDWR
        let fdB = locked(env, k, 5, [Self.pathVA, 2, 0])
        #expect(fdA >= 3 && fdB >= 3)
        env.put(k, Array("ABCDEFGH".utf8), at: Self.buf1)
        // write at the description's offset (it moves), pwrite (it does not)
        #expect(fast(env, k, 4, [UInt64(fdA), Self.buf1, 4]) == 4)
        #expect(fast(env, k, 199, [UInt64(fdA), 0, 1]) == 4)
        #expect(locked(env, k, 199, [UInt64(fdB), 4, 0]) == 4)
        #expect(locked(env, k, 4, [UInt64(fdB), Self.buf1 + 4, 4]) == 4)
        #expect(fast(env, k, 154, [UInt64(fdA), Self.buf1, 3, 90]) == 3)
        #expect(fast(env, k, 199, [UInt64(fdA), 0, 1]) == 4)
        #expect(fast(env, k, 415, [UInt64(fdA), Self.buf1 + 5, 2, 120]) == 2)  // past the end: the file grows
        #expect(locked(env, k, 154, [UInt64(fdB), Self.buf1, 1, 10]) == 1)
        #expect(fast(env, k, 397, [UInt64(fdA), Self.buf1, 0]) == 0)
        let data = try [UInt8](Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(data.count == 122)
        #expect(Array(data[0..<8]) == Array("ABCDEFGH".utf8) && data[10] == UInt8(ascii: "A"))
        #expect(Array(data[90..<93]) == Array("ABC".utf8) && Array(data[120..<122]) == Array("FG".utf8))
        // Errors as on the locked path: a bad descriptor (falls back), a bad buffer.
        #expect(fast(env, k, 4, [99, Self.buf1, 1]) == nil && locked(env, k, 4, [99, Self.buf1, 1]) == -9)
        #expect(fast(env, k, 4, [UInt64(fdA), 0x10, 4]) == -14 && locked(env, k, 4, [UInt64(fdB), 0x10, 4]) == -14)
        let ro = try #require(fast(env, k, 5, [Self.pathVA, 0, 0]))  // read-only: EBADF via the locked path
        #expect(fast(env, k, 4, [UInt64(ro), Self.buf1, 1]) == nil && locked(env, k, 4, [UInt64(ro), Self.buf1, 1]) == -9)
        // O_APPEND: at the end whatever the offset.
        let ap = try #require(fast(env, k, 5, [Self.pathVA, 0x9, 0]))  // O_WRONLY | O_APPEND
        #expect(fast(env, k, 4, [UInt64(ap), Self.buf1 + 7, 1]) == 1)
        let grown = try [UInt8](Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(grown.count == 123 && grown[122] == UInt8(ascii: "H"))
        // The console without L0 (§12), in order with the locked path's writes; a pipe: the locked path.
        env.put(k, Array("ab".utf8), at: Self.buf1)
        let before = env.sink.text(1)
        #expect(fast(env, k, 4, [1, Self.buf1, 1]) == 1)
        #expect(locked(env, k, 4, [1, Self.buf1 + 1, 1]) == 1)
        #expect(fast(env, k, 397, [1, Self.buf1, 2]) == 2)
        #expect(env.sink.text(1) == before + "abab")
        #expect(fast(env, k, 154, [1, Self.buf1, 1, 0]) == nil)  // pwrite of the console: the locked path
        var f = frame(42, [])
        _ = k.handle(&f, context: k.mainThread, memory: env.space(k))
        #expect(fast(env, k, 4, [f.x[1], Self.buf1, 1]) == nil)
        // A guarded descriptor (GUARD_DUP | GUARD_WRITE): the locked path reports the guard.
        let g = Self.buf2 + 0x100
        env.put(k, leBytes(UInt64(77)), at: g)
        var gf = frame(441, [Self.pathVA, g, 0x12, 0x0100_0002, 0])  // guarded_open_np, O_RDWR | O_CLOEXEC
        _ = k.handle(&gf, context: k.mainThread, memory: env.space(k))
        #expect(!gf.carry)
        #expect(fast(env, k, 4, [gf.x[0], Self.buf1, 1]) == nil && locked(env, k, 4, [gf.x[0], Self.buf1, 1]) == -1)
    }

    /// proc_info DIRTYCONTROL of the caller's own process without L0
    /// (frame-profile.md §8): the locked path's answers and state; another
    /// target, another call and the switch fall back.
    @Test func dirtyControlOfItself() throws {
        let (env, k, _) = try setUp()
        let child = env.spawn(from: k).pid
        let c = try #require(env.kernel(child))
        c.tracing = false
        let cpid = UInt64(child)
        // TRACK (allow idle exit), SET dirty, GET, SET clean, CLEAR launch-in-progress.
        #expect(fast(env, c, 336, [8, cpid, 1, 0xB, 0, 0]) == 0)
        #expect(locked(env, c, 336, [8, cpid, 3, 0, 0, 0]) == 0xB)
        #expect(fast(env, c, 336, [8, cpid, 2, 1, 0, 0]) == 0)
        #expect(fast(env, c, 336, [8, cpid, 3, 0, 0, 0]) == 0xF)
        #expect(locked(env, k, 336, [8, cpid, 3, 0, 0, 0]) == 0xF)  // the parent sees it (L0 path)
        #expect(fast(env, c, 336, [8, cpid, 4, 0x8, 0, 0]) == 0)
        #expect(fast(env, c, 336, [8, cpid, 2, 0, 0, 0]) == 0)
        #expect(fast(env, c, 336, [8, cpid, 3, 0, 0, 0]) == 0x3)
        // TRACK keeps the dirty bit only.
        #expect(locked(env, c, 336, [8, cpid, 2, 1, 0, 0]) == 0)
        #expect(fast(env, c, 336, [8, cpid, 1, 0x1, 0, 0]) == 0)
        #expect(locked(env, c, 336, [8, cpid, 3, 0, 0, 0]) == 0x5)
        // Fallbacks: another process, a bad flavor, another call.
        #expect(fast(env, k, 336, [8, cpid, 3, 0, 0, 0]) == nil)
        #expect(fast(env, c, 336, [8, cpid, 9, 0, 0, 0]) == nil && locked(env, c, 336, [8, cpid, 9, 0, 0, 0]) == -22)
        #expect(fast(env, c, 336, [7, cpid, 0, 0, 0, 0]) == nil)
        DarwinKernel.dirtyControlFastEnabled = false
        defer { DarwinKernel.dirtyControlFastEnabled = true }
        #expect(fast(env, c, 336, [8, cpid, 3, 0, 0, 0]) == nil)
    }

    /// The process-table reads without L0 (bsd-locking.md §13): proc_info
    /// LISTPIDS, PIDINFO (every served flavor), PIDRUSAGE,
    /// proc_info_extended_id, csops, csops_audittoken and kern.proc.pid give
    /// the locked path's answers and bytes, for a running process, a
    /// zombie, pseudo-init and a pid that does not exist.
    @Test func processTableReadsMatchTheLockedPath() throws {
        let (env, k, _) = try setUp()
        let running = env.spawn(from: k).pid
        let zombie = env.spawn(from: k).pid
        let z = try #require(env.kernel(zombie))
        #expect(env.svc(z, 1, [5]).0 == .exit(status: 5))
        let me = k.pid
        func same(_ n: UInt64, _ args: (UInt64) -> [UInt64], bytes: Int) {
            env.put(k, [UInt8](repeating: 0xAA, count: bytes), at: Self.buf1)
            env.put(k, [UInt8](repeating: 0xAA, count: bytes), at: Self.buf2)
            let f = fast(env, k, n, args(Self.buf1))
            let l = locked(env, k, n, args(Self.buf2))
            #expect(f != nil && f == l, "trap \(n) \(args(0)): fast \(String(describing: f)) locked \(l)")
            if bytes > 0 { #expect(env.read(k, Self.buf1, bytes) == env.read(k, Self.buf2, bytes), "trap \(n) \(args(0))") }
        }
        let pids: [Int32] = [me, running, zombie, 1, 9999]
        same(336, { [1, 1, 0, 0, $0, 256] }, bytes: 256)               // LISTPIDS, all
        same(336, { [1, 6, UInt64(me), 0, $0, 256] }, bytes: 256)      // children of the root
        same(336, { [1, 9, 0, 0, $0, 256] }, bytes: 0)                 // a bad type
        for pid in pids {
            let p = UInt64(UInt32(bitPattern: pid))
            for (flavor, size) in [(3, 136), (4, 96), (11, 1024), (13, 64), (17, 56), (18, 192), (19, 8), (30, 4), (21, 4), (99, 8)] {
                for arg: UInt64 in [0, 1] {
                    same(336, { [2, p, UInt64(flavor), arg, $0, UInt64(size)] }, bytes: size)
                }
            }
            same(336, { [2, p, 3, 0, $0, 100] }, bytes: 136)               // buffer too small
            same(336, { [9, p, 0, 0, $0, 96] }, bytes: 96)                 // PIDRUSAGE
            same(336, { [9, p, 7, 0, $0, 96] }, bytes: 0)
            same(169, { [p, 0, $0, 4] }, bytes: 4)                         // csops STATUS
            same(169, { [p, 5, $0, 20] }, bytes: 20)                       // CDHASH
            same(169, { [p, 1, $0, 4] }, bytes: 0)                         // another process: EPERM
            env.put(k, [UInt8](repeating: 0, count: 32), at: Self.buf2 + 0xC00)
            same(170, { [p, 0, $0, 4, Self.buf2 + 0xC00] }, bytes: 4)      // a token of pid 0: ESRCH
            var mib: [UInt8] = []
            for v: Int32 in [1, 14, 1, pid] { mib.appendLE(v) }
            env.put(k, mib, at: Self.buf2 + 0xD00)
            env.put(k, leBytes(648), at: Self.buf2 + 0xE00)
            env.put(k, leBytes(648), at: Self.buf2 + 0xE08)
            #expect(fast(env, k, 202, [Self.buf2 + 0xD00, 4, Self.buf1, Self.buf2 + 0xE00, 0, 0])
                == locked(env, k, 202, [Self.buf2 + 0xD00, 4, Self.buf2, Self.buf2 + 0xE08, 0, 0]))
            #expect(env.read(k, Self.buf2 + 0xE00, 8) == env.read(k, Self.buf2 + 0xE08, 8))
            #expect(env.read(k, Self.buf1, 648) == env.read(k, Self.buf2, 648) || pid == 9999)
            // proc_info_extended_id: the pid version must match (flag 1).
            let version = UInt64(env.system.processRecord(pid)?.pidVersion ?? 0)
            for ext in [version, version + 1] {
                same(545, { [2, p, 13, 1, ext, 0, $0, 64] }, bytes: 64)
            }
        }
        // Calls that change state stay on L0.
        #expect(fast(env, k, 336, [7, UInt64(running), 0, 0, 0, 0]) == nil)
        #expect(fast(env, k, 545, [7, UInt64(running), 0, 0, 0, 0, 0, 0]) == nil)
        #expect(DarwinKernel.procInfoReadFast.load(ordering: .relaxed) > 0)
        DarwinKernel.procTableFastEnabled = false
        defer { DarwinKernel.procTableFastEnabled = true }
        #expect(fast(env, k, 336, [1, 1, 0, 0, Self.buf1, 256]) == nil && fast(env, k, 169, [0, 0, Self.buf1, 4]) == nil)
    }

    /// Process-table reads without L0 while other processes start, exit and
    /// are reaped under L0: every answer is a whole record or ESRCH.
    @Test func processTableReadsRaceSpawnsAndExits() throws {
        let (env, k, _) = try setUp()
        let reader = env.spawn(from: k).pid
        let r = try #require(env.kernel(reader))
        r.tracing = false
        let box = Shared(kernel: r, space: env.space(r))
        let stop = Atomic<Bool>(false)
        let wait = spawnThread { () -> Int in
            let r = box.kernel, space = box.space
            var answers = 0
            var pid: Int32 = 2
            while !stop.load(ordering: .relaxed) {
                pid = pid > 60 ? 2 : pid + 1
                var f = frame(336, [2, UInt64(pid), 13, 1, ProcEnv.At.out, 64])
                guard r.handleBSDFast(&f, context: r.mainThread, memory: space) != nil else { return -1 }
                if f.carry {
                    guard f.x[0] == 3 else { return -2 }  // ESRCH
                } else {
                    guard f.x[0] == 64 else { return -3 }
                }
                var l = frame(336, [1, 1, 0, 0, ProcEnv.At.out + 0x100, 512])
                guard r.handleBSDFast(&l, context: r.mainThread, memory: space) != nil, !l.carry, l.x[0] % 4 == 0 else { return -4 }
                answers += 1
            }
            return answers
        }
        for _ in 0..<40 {
            let child = env.spawn(from: k).pid
            if let c = env.kernel(child) { _ = env.svc(c, 1, [0]) }
            _ = env.wait4(k, child)
        }
        stop.store(true, ordering: .relaxed)
        #expect((wait() ?? -9) > 0)
    }

    /// The non-blocking file-lock fcntls without L0 (bsd-locking.md §15):
    /// a POSIX unlock on the fast path wakes another process's F_SETLKW
    /// waiting on L0; an OFD lock's first set goes to L0 (it installs the
    /// description's release handler), later ones are fast; F_GETLK answers
    /// as the locked path.
    @Test func fileLocksWithoutL0() throws {
        let (env, k, path) = try setUp()
        func lockBytes(_ type: Int16, _ start: Int64, _ len: Int64) -> [UInt8] {
            var b = [UInt8](repeating: 0, count: 24)
            b.putLE(start, at: 0)
            b.putLE(len, at: 8)
            b.putLE(type, at: 20)
            return b
        }
        let fdR = try #require(fast(env, k, 5, [Self.pathVA, 0x2, 0]))  // O_RDWR
        env.put(k, lockBytes(3, 0, 10), at: Self.buf1)
        #expect(fast(env, k, 92, [UInt64(fdR), 8, Self.buf1]) == 0)       // F_SETLK write 0…9
        let child = env.spawn(from: k).pid
        let c = try #require(env.kernel(child))
        c.tracing = false
        env.putString(c, path, at: Self.pathVA)
        let cfd = locked(env, c, 5, [Self.pathVA, 0x2, 0])
        #expect(cfd >= 3)
        // F_GETLK: the same answer on both paths (the root's lock).
        env.put(c, lockBytes(3, 0, 1), at: Self.buf1)
        env.put(c, lockBytes(3, 0, 1), at: Self.buf2)
        #expect(fast(env, c, 92, [UInt64(cfd), 7, Self.buf1]) == 0 && locked(env, c, 92, [UInt64(cfd), 7, Self.buf2]) == 0)
        #expect(env.read(c, Self.buf1, 24) == env.read(c, Self.buf2, 24) && env.read(c, Self.buf1, 24).readLE(Int16.self, at: 20) == 3)
        #expect(fast(env, c, 92, [UInt64(cfd), 8, Self.buf1]) == -35)      // EAGAIN
        // The child waits on L0 (F_SETLKW) on another host thread.
        let box = Shared(kernel: c, space: env.space(c))
        env.put(c, lockBytes(3, 0, 1), at: Self.buf2 + 0x100)
        let waiter = spawnThread { () -> Int64 in
            var f = TrapFrame()
            f.kind = TrapFrame.Kind.svc.rawValue
            f.x[16] = 92
            f.x[0] = UInt64(cfd)
            f.x[1] = 9
            f.x[2] = Self.buf2 + 0x100
            _ = box.kernel.handle(&f, context: box.kernel.mainThread, memory: box.space)
            return f.carry ? -Int64(f.x[0]) : Int64(f.x[0])
        }
        let end = Date().addingTimeInterval(5)
        while Date() < end, !c.lock.withLock({ c.mainThread.blockedInKernel }) { Thread.sleep(forTimeInterval: 0.002) }
        #expect(c.lock.withLock { c.mainThread.blockedInKernel })
        // The root unlocks on the fast path: the waiter wakes and gets the lock.
        env.put(k, lockBytes(2, 0, 10), at: Self.buf1)
        #expect(fast(env, k, 92, [UInt64(fdR), 8, Self.buf1]) == 0)
        #expect(waiter() == 0)
        env.put(k, lockBytes(3, 0, 1), at: Self.buf1)
        #expect(fast(env, k, 92, [UInt64(fdR), 8, Self.buf1]) == -35)       // the child holds it now
        // OFD: the first set of a description goes to L0, then fast.
        let fdO = try #require(fast(env, k, 5, [Self.pathVA, 0x2, 0]))
        env.put(k, lockBytes(1, 100, 10), at: Self.buf1)
        #expect(fast(env, k, 92, [UInt64(fdO), 90, Self.buf1]) == nil)
        #expect(locked(env, k, 92, [UInt64(fdO), 90, Self.buf1]) == 0)
        env.put(k, lockBytes(2, 100, 10), at: Self.buf1)
        #expect(fast(env, k, 92, [UInt64(fdO), 90, Self.buf1]) == 0)
        env.put(k, lockBytes(3, 100, 10), at: Self.buf1)
        #expect(fast(env, k, 92, [UInt64(fdO), 90, Self.buf1]) == 0)
        env.put(c, lockBytes(1, 105, 1), at: Self.buf1)
        #expect(fast(env, c, 92, [UInt64(cfd), 92, Self.buf1]) == 0 && env.read(c, Self.buf1, 24).readLE(Int16.self, at: 20) == 3)
        // Closing the OFD description releases its lock.
        #expect(locked(env, k, 6, [UInt64(fdO)]) == 0)
        env.put(c, lockBytes(1, 105, 1), at: Self.buf1)
        #expect(fast(env, c, 92, [UInt64(cfd), 92, Self.buf1]) == 0 && env.read(c, Self.buf1, 24).readLE(Int16.self, at: 20) == 2)
    }

    @Test func objectDescriptorsFallBack() throws {
        let (env, k, _) = try setUp()
        var f = frame(42, [])
        _ = k.handle(&f, context: k.mainThread, memory: env.space(k))
        let r = f.x[0], w = f.x[1]
        #expect(!f.carry)
        #expect(fast(env, k, 3, [r, Self.buf1, 4]) == nil)
        #expect(fast(env, k, 339, [r, Self.buf1]) == nil)
        #expect(fast(env, k, 6, [w]) == nil)
        #expect(fast(env, k, 199, [r, 0, 0]) == -29 && locked(env, k, 199, [r, 0, 0]) == -29)  // ESPIPE
        #expect(locked(env, k, 6, [r]) == 0 && locked(env, k, 6, [w]) == 0)
        // A traced image, an ending image: the locked path.
        k.tracing = true
        let saved = DarwinKernel.bsdFastForTests
        DarwinKernel.bsdFastForTests = false
        defer { DarwinKernel.bsdFastForTests = saved }
        #expect(fast(env, k, 327, []) == nil)
    }

    /// A close without L0 still releases the process's POSIX locks on the
    /// file and drops the descriptor's knotes (the close hook under L0).
    @Test func closeRunsTheHookWhenNeeded() throws {
        let (env, k, path) = try setUp()
        let flags: UInt64 = 0x2  // O_RDWR
        let fd1 = locked(env, k, 5, [Self.pathVA, flags, 0])
        var lock = [UInt8](repeating: 0, count: 24)
        lock.putLE(Int64(0), at: 0)
        lock.putLE(Int64(10), at: 8)
        lock.putLE(Int16(3), at: 20)  // F_WRLCK
        env.put(k, lock, at: Self.buf1)
        #expect(locked(env, k, 92, [UInt64(fd1), 8, Self.buf1]) == 0)  // F_SETLK
        let (_, _, child) = env.spawn(from: k)
        let c = try #require(env.kernel(child))
        c.tracing = false
        env.putString(c, path, at: Self.pathVA)
        let cfd = locked(env, c, 5, [Self.pathVA, flags, 0])
        env.put(c, lock, at: Self.buf1)
        #expect(locked(env, c, 92, [UInt64(cfd), 8, Self.buf1]) == -35)  // EAGAIN: the parent's lock
        // Another descriptor of the same file, closed on the fast path.
        let fd2 = try #require(fast(env, k, 5, [Self.pathVA, 0, 0]))
        let hooks = DarwinKernel.bsdFastCloseHooks.load(ordering: .relaxed)
        #expect(fast(env, k, 6, [UInt64(fd2)]) == 0)
        #expect(DarwinKernel.bsdFastCloseHooks.load(ordering: .relaxed) > hooks)
        #expect(locked(env, c, 92, [UInt64(cfd), 8, Self.buf1]) == 0)  // the parent's locks are gone

        // A descriptor with an EVFILT_READ and an EVFILT_VNODE knote.
        let kq = Int32(env.bsd(c, 362))
        #expect(kq >= 3)
        let wfd = locked(env, c, 5, [Self.pathVA, 0, 0])
        let changes = [ProcEnv.kevent64(ident: UInt64(wfd), filter: -1, flags: 1),
                       ProcEnv.kevent64(ident: UInt64(wfd), filter: -4, flags: 1, fflags: 1)]
        #expect(env.kevent64(c, kq: kq, changes: changes, nevents: 0).0 == 0)
        #expect(c.descriptorWatches.withLock { $0[UInt64(wfd)] } == 2 && c.isDescriptorWatched(Int32(wfd)))
        #expect(fast(env, c, 6, [UInt64(wfd)]) == 0)
        #expect(!c.isDescriptorWatched(Int32(wfd)))
        let delete = [ProcEnv.kevent64(ident: UInt64(wfd), filter: -1, flags: 2)]
        #expect(env.kevent64(c, kq: kq, changes: delete, nevents: 0).0 == -2)  // ENOENT: dropped
    }

    /// Fast opens, reads and closes on many threads against locked dups,
    /// dup2s and closes of the same table: every descriptor ends closed,
    /// and no thread takes a kernel lock while it holds the table's.
    @Test func concurrentUseOfOneTable() throws {
        let savedCheck = KernelThreadLocks.checkOrder
        KernelThreadLocks.checkOrder = true
        defer { KernelThreadLocks.checkOrder = savedCheck }
        let (env, k, _) = try setUp()
        let before = k.fileSystem.openDescriptors
        let box = Shared(kernel: k, space: env.space(k))
        let group = DispatchGroup()
        for t in 0..<6 {
            group.enter()
            Thread.detachNewThread {
                defer { group.leave() }
                let k = box.kernel, space = box.space
                let buf = Self.buf1 + UInt64(t) * 0x100
                for i in 0..<300 {
                    if t < 4 {
                        var f = frame(5, [Self.pathVA, 0, 0])
                        let served = k.handleBSDFast(&f, context: k.mainThread, memory: space) != nil
                        if !served || f.carry { box.failures.wrappingAdd(1, ordering: .relaxed); continue }
                        let fd = f.x[0]
                        var r = frame(3, [fd, buf, 16])
                        if k.handleBSDFast(&r, context: k.mainThread, memory: space) == nil {
                            _ = k.handle(&r, context: k.mainThread, memory: space)
                        }
                        var c = frame(6, [fd])
                        if k.handleBSDFast(&c, context: k.mainThread, memory: space) == nil {
                            _ = k.handle(&c, context: k.mainThread, memory: space)
                        }
                    } else {
                        // dup2 a fresh open over a high number and close both.
                        var o = frame(5, [Self.pathVA, 0, 0])
                        _ = k.handle(&o, context: k.mainThread, memory: space)
                        guard !o.carry else { box.failures.wrappingAdd(1, ordering: .relaxed); continue }
                        let target = UInt64(200 + t * 10 + i % 5)
                        var d = frame(90, [o.x[0], target])
                        _ = k.handle(&d, context: k.mainThread, memory: space)
                        var c1 = frame(6, [o.x[0]])
                        _ = k.handle(&c1, context: k.mainThread, memory: space)
                        var c2 = frame(6, [target])
                        if k.handleBSDFast(&c2, context: k.mainThread, memory: space) == nil {
                            _ = k.handle(&c2, context: k.mainThread, memory: space)
                        }
                    }
                }
            }
        }
        group.wait()
        #expect(box.failures.load(ordering: .relaxed) == 0)
        #expect(k.fileSystem.openDescriptors == before)
    }

    /// ulock waits and wakes under the event lock only (split system): a
    /// fast waiter woken by a locked wake and by a fast one, a fast waiter
    /// interrupted under L0, and the value check.
    @Test func ulockUnderTheEventLock() throws {
        // SchedPolicyTests switches QoS (which keeps ulock on L0) process-wide.
        schedSwitchesTestLock.lock()
        defer { schedSwitchesTestLock.unlock() }
        let savedCheck = KernelThreadLocks.checkOrder
        KernelThreadLocks.checkOrder = true
        defer { KernelThreadLocks.checkOrder = savedCheck }
        let system = DarwinSystem(ipcLocks: true)
        let fs = DarwinFileSystem(prefixes: [], console: { _, _ in })
        let k = DarwinKernel(fileSystem: fs, pid: 300, system: system)
        k.tracing = false
        let space = GuestAddressSpace(backing: FakePhysicalBacking())
        _ = try space.mapAnonymous(at: ProcEnv.scratch, size: 0x10000, protection: .readWrite, hint: nil)
        let box = Shared(kernel: k, space: space)
        let w = ProcEnv.scratch + 0x100
        let noErrno: UInt64 = 0x0100_0000
        let waiter = ThreadContext(threadID: 7, portName: 0x1307, vcpuIndex: 3, kind: .pthread)
        waiter.kernel = k
        func waitOnce() -> HostThread<(Bool, UInt64)> {
            HostThread {
                var f = self.frame(515, [1 | noErrno, w, 0, 0])
                let fast = box.kernel.handleBSDFast(&f, context: waiter, memory: box.space) != nil
                return (fast, f.x[0])
            }
        }
        func blocked() -> Bool { box.kernel.lock.withLock { waiter.blockedInKernel } }
        func eventually(_ condition: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(5)
            while Date() < end { if condition() { return true }; Thread.sleep(forTimeInterval: 0.002) }
            return condition()
        }
        // A locked wake.
        var t = waitOnce()
        #expect(eventually(blocked))
        var f = frame(516, [1 | noErrno, w, 0])
        _ = k.handle(&f, context: k.mainThread, memory: space)
        #expect(f.x[0] == 0)
        var r = t.wait()
        #expect(r?.0 == true && r?.1 == 0)
        // A fast wake.
        t = waitOnce()
        #expect(eventually(blocked))
        f = frame(516, [1 | noErrno, w, 0])
        #expect(k.handleBSDFast(&f, context: k.mainThread, memory: space) != nil && f.x[0] == 0)
        r = t.wait()
        #expect(r?.0 == true && r?.1 == 0)
        // Interrupted under L0 (a signal): EINTR, as -errno with ULF_NO_ERRNO.
        t = waitOnce()
        #expect(eventually(blocked))
        #expect(k.lock.withLock { k.lock.interrupt(waiter) })
        r = t.wait()
        #expect(r?.0 == true && r?.1 == UInt64(bitPattern: -4))
        // The value changed: no wait; nobody waits now (ENOENT).
        try space.write(va: w, bytes: [1, 0, 0, 0])
        f = frame(515, [1 | noErrno, w, 0, 0])
        #expect(k.handleBSDFast(&f, context: waiter, memory: space) != nil && f.x[0] == 0)
        f = frame(516, [1 | noErrno, w, 0])
        #expect(k.handleBSDFast(&f, context: k.mainThread, memory: space) != nil && f.x[0] == UInt64(bitPattern: -2))
        k.shutdown()
    }

    /// With thread QoS on (scheduling-policy.md §4.4, `YCODE_SCHED_CLASS_OFF_L0`),
    /// unfair-lock waits stay on the fast path and push the waiter's class
    /// onto the owner while it waits; the owner's wake removes the push.
    @Test func ulockPushOnTheFastPathWithQoS() throws {
        schedSwitchesTestLock.lock()
        defer { schedSwitchesTestLock.unlock() }
        let saved = (SchedPolicy.qosEnabled, SchedPolicy.classOffL0, KernelThreadLocks.checkOrder)
        (SchedPolicy.qosEnabled, SchedPolicy.classOffL0, KernelThreadLocks.checkOrder) = (true, true, true)
        defer { (SchedPolicy.qosEnabled, SchedPolicy.classOffL0, KernelThreadLocks.checkOrder) = saved }
        let system = DarwinSystem(ipcLocks: true)
        let fs = DarwinFileSystem(prefixes: [], console: { _, _ in })
        let k = DarwinKernel(fileSystem: fs, pid: 301, system: system)
        k.tracing = false
        let space = GuestAddressSpace(backing: FakePhysicalBacking())
        _ = try space.mapAnonymous(at: ProcEnv.scratch, size: 0x10000, protection: .readWrite, hint: nil)
        let box = Shared(kernel: k, space: space)
        let w = ProcEnv.scratch + 0x200
        let noErrno: UInt64 = 0x0100_0000
        let owner = k.mainThread
        let ownerWord = UInt64(owner.portName & ~3)
        try space.write(va: w, bytes: Array(leBytes(ownerWord).prefix(4)))
        let waiter = ThreadContext(threadID: 8, portName: 0x1407, vcpuIndex: 4, kind: .pthread)
        waiter.kernel = k
        waiter.schedClassStore.store(SchedClass.interactive, ordering: .relaxed)
        owner.schedClassStore.store(SchedClass.default, ordering: .relaxed)
        let t = HostThread { () -> (Bool, UInt64) in
            var f = self.frame(515, [2 | noErrno, w, ownerWord, 0])
            let fast = box.kernel.handleBSDFast(&f, context: waiter, memory: box.space) != nil
            return (fast, f.x[0])
        }
        let end = Date().addingTimeInterval(5)
        while Date() < end, owner.schedClass != SchedClass.interactive { Thread.sleep(forTimeInterval: 0.002) }
        #expect(owner.schedClass == SchedClass.interactive)
        var f = frame(516, [2 | noErrno, w, 0])
        #expect(k.handleBSDFast(&f, context: owner, memory: space) != nil && f.x[0] == 0)
        let r = t.wait()
        #expect(r?.0 == true && r?.1 == 0)
        #expect(owner.schedClass == SchedClass.default)
        k.shutdown()
    }

    /// A launcher with the two-step form: records whether `prepare` ran
    /// without the kernel lock and `activate` with it.
    final class TwoStepLauncher: ProcessLauncher, @unchecked Sendable {
        final class Built: PreparedImage {
            let request: ProcessImageRequest
            let kernel: DarwinKernel
            init(_ request: ProcessImageRequest, _ kernel: DarwinKernel) {
                self.request = request
                self.kernel = kernel
            }
        }
        let inner: FakeLauncher
        var preparedUnlocked: [Bool] = []
        var activatedLocked: [Bool] = []
        var discarded = 0
        init(_ inner: FakeLauncher) { self.inner = inner }
        func launch(_ request: ProcessImageRequest, kernel: DarwinKernel) throws -> any LaunchedImage {
            try inner.launch(request, kernel: kernel)
        }
        func prepare(_ request: ProcessImageRequest, kernel: DarwinKernel) throws -> (any PreparedImage)? {
            preparedUnlocked.append(!kernel.lock.isHeldByCurrentThread)
            return Built(request, kernel)
        }
        func activate(_ prepared: any PreparedImage, startSuspended: Bool) throws -> any LaunchedImage {
            let b = prepared as! Built
            activatedLocked.append(b.kernel.lock.isHeldByCurrentThread)
            var request = b.request
            request.startSuspended = startSuspended
            return try inner.launch(request, kernel: b.kernel)
        }
        func discard(_ prepared: any PreparedImage) { discarded += 1 }
    }

    /// posix_spawn and exec build the new image without the kernel lock and
    /// register it with it (bsd-locking.md §7).
    @Test func spawnAndExecBuildTheImageWithoutTheKernelLock() throws {
        let env = try ProcEnv()
        let two = TwoStepLauncher(env.launcher)
        env.system.launcher = two
        let root = env.rootKernel!
        let (_, e, child) = env.spawn(from: root)
        #expect(e == 0 && child > 0)
        #expect(two.preparedUnlocked == [true] && two.activatedLocked == [true])
        #expect(env.kernel(child) != nil && env.launcher.launches.last?.kernel === env.kernel(child))
        // A spawn whose executable is missing fails before anything is built.
        let (_, e2, _) = env.spawn(from: root, path: env.root + "/missing")
        #expect(e2 == 2 && two.preparedUnlocked.count == 1)
        // exec (POSIX_SPAWN_SETEXEC) in the child: the same two steps.
        let c = try #require(env.kernel(child))
        let (o, e3, _) = env.spawn(from: c, flags: 0x40)
        #expect(e3 == 0 && o == .imageReplaced)
        #expect(two.preparedUnlocked == [true, true] && two.activatedLocked == [true, true] && two.discarded == 0)
        // With the switch off: one step, under the lock.
        let saved = DarwinKernel.unlockedImageBuild
        DarwinKernel.unlockedImageBuild = false
        defer { DarwinKernel.unlockedImageBuild = saved }
        let (_, e4, _) = env.spawn(from: root)
        #expect(e4 == 0 && two.preparedUnlocked.count == 2)
    }

    /// The kernel and the address space, handed to test threads.
    final class Shared: @unchecked Sendable {
        let kernel: DarwinKernel
        let space: GuestAddressSpace
        let failures = Atomic<Int>(0)
        init(kernel: DarwinKernel, space: GuestAddressSpace) {
            self.kernel = kernel
            self.space = space
        }
    }

    @Test func tableLockIsCountedAsALeaf() {
        let saved = LeafLockCheck.enabled
        LeafLockCheck.enabled = true
        defer { LeafLockCheck.enabled = saved }
        let lock = DescriptorTableLock()
        #expect(LeafLockCheck.depth == 0)
        lock.withLock {
            #expect(LeafLockCheck.depth == 1)
            lock.withLock { #expect(LeafLockCheck.depth == 2) }
        }
        #expect(LeafLockCheck.depth == 0)
    }
}
