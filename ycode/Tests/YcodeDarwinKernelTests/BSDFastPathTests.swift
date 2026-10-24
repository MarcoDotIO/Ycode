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
        #expect(fast(env, k, 92, [UInt64(fdA), 8, Self.buf1]) == nil)
        #expect(fast(env, k, 92, [99, 3, 0]) == -9 && locked(env, k, 92, [99, 3, 0]) == -9)
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
        #expect(fast(env, k, 202, [Self.buf2 + 0xA08, 4, Self.buf1, Self.buf2 + 0x900, 0, 0]) == nil)
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
        #expect(fast(env, k, 381, [Self.buf2 + 0xD00, 5, 0]) == nil)
        // openat relative to a directory descriptor; a directory's close falls back
        env.putString(k, env.root, at: Self.buf2 + 0x800)
        let dirFD = try #require(fast(env, k, 5, [Self.buf2 + 0x800, 0x100000, 0]))
        #expect(dirFD >= 3)
        env.putString(k, "data.bin", at: Self.buf2 + 0xB00)
        let relFD = try #require(fast(env, k, 463, [UInt64(dirFD), Self.buf2 + 0xB00, 0, 0]))
        #expect(relFD >= 3 && fast(env, k, 3, [UInt64(relFD), Self.buf1, 4]) == 4)
        #expect(fast(env, k, 6, [UInt64(dirFD)]) == nil)
        #expect(locked(env, k, 6, [UInt64(dirFD)]) == 0)
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
        // The console and a pipe: the locked path.
        #expect(fast(env, k, 4, [1, Self.buf1, 1]) == nil)
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
        #expect(fast(env, c, 336, [2, cpid, 3, 0, ProcEnv.At.out, 136]) == nil)
        DarwinKernel.dirtyControlFastEnabled = false
        defer { DarwinKernel.dirtyControlFastEnabled = true }
        #expect(fast(env, c, 336, [8, cpid, 3, 0, 0, 0]) == nil)
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
