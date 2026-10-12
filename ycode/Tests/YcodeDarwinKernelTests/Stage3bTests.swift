import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// The stage-3b BSD calls (`ExtendedBSD.swift`) and the extra sysctl names.
@Suite struct Stage3bTests {
    let s = Env.scratch

    @Test func vectoredIOAndNocancel() throws {
        let env = try Env()
        try env.putString("hello ", at: s + 0x100)
        try env.putString("world\n", at: s + 0x200)
        var iov: [UInt8] = []
        for (p, n) in [(s + 0x100, 6), (s + 0x200, 6), (s + 0x300, 0)] as [(UInt64, UInt64)] {
            iov += leBytes(p) + leBytes(n)
        }
        try env.put(iov, at: s)
        let (o, f) = env.svc(121, [1, s, 3])
        #expect(o == .resume && !f.carry && f.x[0] == 12)
        #expect(env.sink.text(1) == "hello world\n")
        let (_, g) = env.svc(412, [2, s, 2])  // writev_nocancel
        #expect(g.x[0] == 12 && env.sink.text(2) == "hello world\n")
        let (_, w) = env.svc(397, [1, s + 0x100, 6])  // write_nocancel
        #expect(w.x[0] == 6 && env.sink.text(1) == "hello world\nhello ")
        #expect(env.svc(121, [1, s, 0]).1.carry)  // iovcnt 0: EINVAL

        // readv / read_nocancel / open_nocancel / close_nocancel from a file.
        let path = try env.makeFile("data", Array("abcdefghij".utf8))
        try env.putString(path, at: s + 0x800)
        let (_, op) = env.svc(398, [s + 0x800, 0, 0])
        #expect(!op.carry)
        let fd = op.x[0]
        try env.put(leBytes(s + 0x400) + leBytes(3) + leBytes(s + 0x500) + leBytes(4), at: s)
        let (_, r) = env.svc(120, [fd, s, 2])
        #expect(r.x[0] == 7)
        #expect(try env.space.read(va: s + 0x400, count: 3) == Array("abc".utf8))
        #expect(try env.space.read(va: s + 0x500, count: 4) == Array("defg".utf8))
        let (_, r2) = env.svc(396, [fd, s + 0x600, 10])
        #expect(r2.x[0] == 3)
        #expect(!env.svc(399, [fd]).1.carry)
    }

    @Test func ulock() throws {
        let env = try Env()
        try env.put([7, 0, 0, 0], at: s)
        // Value changed: returns at once.
        let (_, a) = env.svc(515, [1, s, 6, 0])
        #expect(!a.carry && a.x[0] == 0)
        // Same value with a timeout: ETIMEDOUT.
        let (_, b) = env.svc(515, [1, s, 7, 1000])
        #expect(b.carry && b.x[0] == 60)
        let (_, b2) = env.svc(544, [2, s, 7, 5_000_000, 0])
        #expect(b2.carry && b2.x[0] == 60)
        // No timeout: a deadlock on one thread, logged loudly.
        let (_, c) = env.svc(515, [2, s, 7, 0])
        #expect(c.carry && c.x[0] == 11)
        #expect(env.sink.lines.contains { $0.hasPrefix("DEADLOCK: __ulock_wait on") })
        // ULF_NO_ERRNO: −errno with carry clear.
        let (_, d) = env.svc(515, [0x0100_0001, s, 7, 1])
        #expect(!d.carry && d.x[0] == UInt64(bitPattern: -60))
        // 64-bit compare.
        try env.put(leBytes(0x1_0000_0007), at: s + 8)
        #expect(env.svc(515, [5, s + 8, 7, 1]).1.x[0] == 0)
        #expect(env.svc(515, [5, s + 8, 0x1_0000_0007, 1]).1.x[0] == 60)
        // Wake: nobody waits.
        let (_, e) = env.svc(516, [1, s, 0])
        #expect(e.carry && e.x[0] == 2)
        let (_, e2) = env.svc(516, [0x0100_0002, s, 0])
        #expect(!e2.carry && e2.x[0] == UInt64(bitPattern: -2))
    }

    @Test func entropy() throws {
        let env = try Env()
        env.kernel.entropy = { n in [UInt8](repeating: 0x5A, count: n) }
        let (_, f) = env.svc(500, [s, 32])
        #expect(!f.carry && f.x[0] == 0)
        #expect(try env.space.read(va: s, count: 33) == [UInt8](repeating: 0x5A, count: 32) + [0])
        #expect(env.svc(500, [s, 257]).1.x[0] == 22)
        #expect(DarwinKernel.hostEntropy(16).count == 16)
    }

    @Test func signalsBookkeeping() throws {
        let env = try Env()
        try env.put([0x06, 0x01, 0x01, 0x00], at: s)  // bits 1, 2, 8 (SIGKILL), 16 (SIGSTOP)
        #expect(!env.svc(48, [1, s, 0]).1.carry)  // SIG_BLOCK
        #expect(!env.svc(48, [3, 0, s + 8]).1.carry)
        #expect(try env.u32(s + 8) == 0x6)  // SIGKILL/SIGSTOP dropped
        try env.put([0x02, 0, 0, 0], at: s)
        env.svc(329, [2, s, s + 8])  // __pthread_sigmask SIG_UNBLOCK
        #expect(try env.u32(s + 8) == 0x6)
        env.svc(48, [3, 0, s + 8])
        #expect(try env.u32(s + 8) == 0x4)
        #expect(env.svc(48, [9, s, 0]).1.x[0] == 22)

        // sigaction: struct __sigaction in, struct sigaction out.
        try env.put(leBytes(0x1_0000_4000) + leBytes(0x1_0000_5000) + [0xF0, 0, 0, 0] + [0x42, 0, 0, 0], at: s + 0x100)
        #expect(!env.svc(46, [11, s + 0x100, 0]).1.carry)
        #expect(!env.svc(46, [11, 0, s + 0x200]).1.carry)
        let o = try env.space.read(va: s + 0x200, count: 16)
        #expect(u64(o, 0) == 0x1_0000_4000 && u32(o, 8) == 0xF0 && u32(o, 12) == 0x42)
        #expect(env.svc(46, [9, s + 0x100, 0]).1.x[0] == 22)  // SIGKILL
        #expect(env.svc(46, [0, 0, 0]).1.x[0] == 22)
        // sigaltstack reports disabled.
        #expect(!env.svc(53, [0, s + 0x300]).1.carry)
        #expect(try env.u32(s + 0x310) == 4)
    }

    @Test func resourceLimits() throws {
        let env = try Env()
        #expect(!env.svc(194, [3, s]).1.carry)
        #expect(try env.u64(s) == 8 << 20)
        env.svc(194, [0x1008, s])  // RLIMIT_NOFILE | _RLIMIT_POSIX_FLAG
        #expect(try env.u64(s) == 256 && env.u64(s + 8) == 256)
        env.svc(194, [0, s])
        #expect(try env.u64(s) == DarwinKernel.RLimit.infinity)
        try env.put(leBytes(128) + leBytes(256), at: s)
        #expect(!env.svc(195, [8, s]).1.carry)
        #expect(env.kernel.fileSystem.maxDescriptors == 128)
        try env.put(leBytes(512) + leBytes(256), at: s)
        #expect(env.svc(195, [8, s]).1.x[0] == 22)
        try env.put(leBytes(512) + leBytes(1024), at: s)
        #expect(env.svc(195, [8, s]).1.x[0] == 1)  // above the hard limit
        #expect(env.svc(194, [99, s]).1.x[0] == 22)
    }

    @Test func miscellaneous() throws {
        let env = try Env()
        try env.put([UInt8](repeating: 0xFF, count: 8), at: s)
        let (_, c) = env.svc(169, [0, 0, s, 4])
        #expect(!c.carry && c.x[0] == 0)
        #expect(try env.u32(s) == 0 && env.u32(s + 4) == 0xFFFF_FFFF)
        #expect(!env.svc(170, [100, 0, s, 4, 0]).1.carry)
        #expect(env.svc(169, [42, 0, s, 4]).1.x[0] == 3)  // ESRCH
        // proc_info: ENOTSUP; kevent family: ENOSYS, but not "unimplemented".
        #expect(env.svc(336, [2, 100, 13, 0, s, 64]).1.x[0] == 45)
        for n: UInt64 in [363, 369, 374, 375] {
            let (o, f) = env.svc(n, [3, 0, 0, 0, 0, 0])
            #expect(o == .resume && f.carry && f.x[0] == 78)
        }
        #expect(env.svc(372).1.x[0] == 1)  // thread_selfid = the block's thread_id
        #expect(env.svc(39).1.x[0] == 1)
        try env.putString("<5>hello log\n", at: s + 0x40)
        #expect(env.svc(133, [0, s + 0x40, 13, 0, 0, 0]).1.x[0] == 38)
        #expect(env.svc(413, [0, s + 0x40, 13, 0, 0, 0]).1.x[0] == 38)
        #expect(env.sink.lines.contains("note: sendto message: <5>hello log"))
        #expect(env.svc(60, [0o77]).1.x[0] == 0o22 && env.svc(60, [0o22]).1.x[0] == 0o77)
        // terminate_with_payload is fatal.
        guard case let .fatal(status, _) = env.svc(520, [100, 1, 2, 0, 0, 0, 0]).0 else { Issue.record("fatal"); return }
        #expect(status == 134)
    }

    @Test func pathAtCalls() throws {
        let env = try Env()
        let dir = env.root + "/d"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data("xyz".utf8).write(to: URL(fileURLWithPath: dir + "/f"))
        try env.putString(dir, at: s)
        let (_, o) = env.svc(5, [s, 0x10_0000, 0])  // O_DIRECTORY
        #expect(!o.carry)
        let dfd = o.x[0]
        try env.putString("f", at: s + 0x100)
        let (_, st) = env.svc(470, [dfd, s + 0x100, s + 0x200, 0])
        #expect(!st.carry)
        let stat = try #require(DarwinStat(decodingStat64: try env.space.read(va: s + 0x200, count: DarwinStat.encodedSize)))
        #expect(stat.size == 3 && stat.isRegularFile)
        try env.putString(dir + "/f", at: s + 0x300)
        #expect(!env.svc(470, [UInt64(bitPattern: -2), s + 0x300, s + 0x200, 0x20]).1.carry)
        #expect(env.svc(470, [UInt64(bitPattern: -2), s + 0x100, s + 0x200, 0]).1.x[0] == 2)  // relative to "/"
        let (_, oa) = env.svc(463, [dfd, s + 0x100, 0, 0])
        #expect(!oa.carry)
        let (_, rd) = env.svc(3, [oa.x[0], s + 0x400, 8])
        #expect(rd.x[0] == 3)
        #expect(!env.svc(466, [dfd, s + 0x100, 4, 0]).1.carry)  // faccessat R_OK
        #expect(!env.svc(33, [s + 0x300, 0]).1.carry)  // access
        try env.putString("missing", at: s + 0x500)
        #expect(env.svc(466, [dfd, s + 0x500, 0, 0]).1.x[0] == 2)
        #expect(env.svc(470, [oa.x[0], s + 0x100, s + 0x200, 0]).1.x[0] == 20)  // dirfd is a file
    }

    @Test func directoryListing() throws {
        let env = try Env()
        let dir = env.root + "/list"
        try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        for name in ["b.txt", "a.txt"] { try Data("1".utf8).write(to: URL(fileURLWithPath: dir + "/" + name)) }
        try env.putString(dir, at: s)
        let fd = env.svc(5, [s, 0x10_0000, 0]).1.x[0]
        let buf = s + 0x1000, size: UInt64 = 4096, pos = s + 0x800
        let (_, f) = env.svc(344, [fd, buf, size, pos])
        #expect(!f.carry && f.x[0] > 0)
        let bytes = try env.space.read(va: buf, count: Int(size))
        var names: [String] = []
        var types: [UInt8] = []
        var o = 0
        while o < Int(f.x[0]) {
            let reclen = Int(u16(bytes, o + 16)), namlen = Int(u16(bytes, o + 18))
            #expect(reclen % 8 == 0 && u64(bytes, o) != 0)
            types.append(bytes[o + 20])
            names.append(String(decoding: bytes[(o + 21)..<(o + 21 + namlen)], as: UTF8.self))
            #expect(bytes[o + 21 + namlen] == 0)
            o += reclen
        }
        #expect(names == [".", "..", "a.txt", "b.txt", "sub"])
        #expect(types == [4, 4, 8, 8, 4])
        #expect(u32(bytes, Int(size) - 4) == 1)  // end-of-directory flag
        #expect(try env.u64(pos) == 0)
        let (_, g) = env.svc(344, [fd, buf, size, pos])
        #expect(!g.carry && g.x[0] == 0)
        #expect(try env.u64(pos) == 5)
        // A small buffer: several calls, no flag word.
        let fd2 = env.svc(5, [s, 0x10_0000, 0]).1.x[0]
        var total = 0
        for _ in 0..<10 {
            let (_, h) = env.svc(344, [fd2, buf, 40, pos])
            if h.x[0] == 0 { break }
            total += 1
        }
        #expect(total == 5)
        // Not a directory.
        let file = try env.makeFile("plain", [1])
        try env.putString(file, at: s)
        let pfd = env.svc(5, [s, 0, 0]).1.x[0]
        #expect(env.svc(344, [pfd, buf, size, pos]).1.x[0] == 20)
    }

    @Test func sysctlNames() throws {
        let env = try Env()
        func byName(_ name: String, buffer: UInt64 = 64) throws -> (TrapFrame, [UInt8]) {
            try env.putString(name, at: s)
            try env.put(leBytes(buffer), at: s + 0x100)
            let (_, f) = env.svc(274, [s, UInt64(name.utf8.count), s + 0x200, s + 0x100, 0, 0])
            let n = Int(try env.u64(s + 0x100))
            return (f, try env.space.read(va: s + 0x200, count: max(n, 1)))
        }
        #expect(try String(decoding: byName("kern.ostype").1.dropLast(), as: UTF8.self) == "Darwin")
        #expect(try String(decoding: byName("kern.osrelease").1.dropLast(), as: UTF8.self) == "26.1.0")
        #expect(try String(decoding: byName("kern.osversion").1.dropLast(), as: UTF8.self) == "24A94401")
        #expect(try u64(byName("hw.memsize", buffer: 8).1, 0) == 1 << 30)
        #expect(try u32(byName("hw.cputype", buffer: 4).1, 0) == 0x0100_000C)
        #expect(try u64(byName("hw.cachelinesize", buffer: 8).1, 0) == 64)
        #expect(try u32(byName("hw.logicalcpu", buffer: 4).1, 0) == 1)
        #expect(try byName("kern.boottime", buffer: 16).1.count == 16)
        let (f, v) = try byName("hw.optional.arm.FEAT_SME", buffer: 4)
        #expect(!f.carry && u32(v, 0) == 0)
        // hw.optional.* round-trips through name2oid.
        let table = SysctlTable.standard
        let e = try #require(table.lookup(name: "hw.optional.neon"))
        #expect(table.lookup(mib: e.mib)?.value == .integer(0, size: 4))
        #expect(table.lookup(name: "kern.nonexistent") == nil)
        #expect(table.lookup(mib: [6, 24])?.name == "hw.memsize")
    }
    @Test func machAdditions() throws {
        let env = try Env()
        func m(_ n: Int) -> UInt64 { UInt64(bitPattern: Int64(n)) }
        // mach_vm_map anywhere with a 64 KiB alignment mask.
        try env.put(leBytes(0), at: s)
        let (_, a) = env.svc(m(-15), [0x103, s, 0x4000, 0xFFFF, 1, 3])
        #expect(a.x[0] == 0)
        let va = try env.u64(s)
        #expect(va != 0 && va % 0x10000 == 0)
        #expect(env.space.region(containing: va)?.protection == .readWrite)
        #expect(env.space.region(containing: va + 0x4000) == nil)  // trimmed
        // Fixed, no overwrite, on an existing mapping: KERN_NO_SPACE.
        try env.put(leBytes(va), at: s)
        #expect(env.svc(m(-15), [0x103, s, 0x4000, 0, 0, 3]).1.x[0] == 3)
        #expect(env.svc(m(-19), [0x103, 0x203, 0, 1]).1.x[0] == 0)
        #expect(env.svc(m(-19), [0x103, 0x9999, 0, 1]).1.x[0] == 15)
        #expect(env.svc(m(-41), [0x103, 0x103, 7, 0]).1.x[0] == 0)
        #expect(env.svc(m(-42), [0x103, 0x103, 7]).1.x[0] == 0)
        #expect(env.svc(m(-46), [0x103, s]).1.x[0] == 0)
        #expect(try env.u32(s) == 100)
        let reply = env.svc(m(-50)).1.x[0]
        #expect(reply != 0 && env.kernel.ports.kind(of: UInt32(reply)) == .reply)
        #expect(env.svc(m(-76), [0x103, 0x203, s]).1.x[0] == 0)
        #expect(try env.u32(s) == 1 << 16)
        #expect(env.svc(m(-76), [0x103, reply, s]).1.x[0] == 0)
        #expect(try env.u32(s) == 1 << 17)
        try env.put(leBytes(0xFFFF_FFFF), at: s)
        #expect(env.svc(m(-77), [0x103, reply, 70, 0, 0, 21, s]).1.x[0] == 0)
        #expect(try env.u32(s) == 0)
        #expect(env.svc(m(-43), [0x103, 1, s]).1.x[0] == 0)
        #expect(try env.u64(s) == 1)
        #expect(env.svc(m(-90), [0x1234]).1.x[0] == 0)
    }
    @Test func selfSignalsAndSemwait() throws {
        let env = try Env()
        #expect(env.svc(37, [100, 0, 1]).1.x[0] == 0)  // kill(self, 0)
        #expect(env.svc(37, [55, 6, 1]).1.x[0] == 3)  // other pid: ESRCH
        #expect(env.svc(328, [0x203, 20, 0]).0 == .resume)  // SIGCHLD: ignored by default
        // SIG_IGN, then a handler: dropped.
        try env.put(leBytes(1) + leBytes(0) + [0, 0, 0, 0, 0, 0, 0, 0], at: s)
        env.svc(46, [15, s, 0])
        #expect(env.svc(37, [100, 15, 1]).0 == .resume)
        try env.put(leBytes(0x1_0000_4000), at: s)
        env.svc(46, [15, s, 0])
        #expect(env.svc(37, [100, 15, 1]).0 == .resume)
        guard case let .fatal(status, message) = env.svc(328, [0x203, 6]).0 else { Issue.record("fatal"); return }
        #expect(status == 134 && message.contains("SIGABRT"))
        // __semwait_signal: timed → ETIMEDOUT; untimed → EDEADLK.
        #expect(env.svc(423, [0, 0, 1, 1, 0, 10_000_000]).1.x[0] == 60)
        #expect(env.svc(334, [0, 0, 0, 0, 0, 0]).1.x[0] == 11)
    }
    @Test func psynchWorkqStatfs() throws {
        let env = try Env()
        #expect(env.svc(301, [s, 0, 0, 0, 0]).1.x[0] == 45)
        #expect(env.sink.lines.contains { $0.hasPrefix("DEADLOCK?: psynch_mutexwait") })
        let (_, d) = env.svc(302, [s, 0, 0, 0, 0])
        #expect(!d.carry && d.x[0] == 0)
        #expect(env.svc(304, [s]).1.x[0] == 0 && env.svc(303, [s]).1.x[0] == 0)
        #expect(env.svc(367).1.x[0] == 45 && env.svc(368, [1]).1.x[0] == 45)
        let path = try env.makeFile("fs", [1, 2])
        try env.putString(path, at: s)
        let (_, f) = env.svc(345, [s, s + 0x1000])
        #expect(!f.carry)
        let b = try env.space.read(va: s + 0x1000, count: 2168)
        #expect(u32(b, 0) == 4096 && u32(b, 64) & 1 == 1)
        #expect(String(decoding: b[72..<76], as: UTF8.self) == "apfs")
        #expect(String(decoding: b[88...].prefix { $0 != 0 }, as: UTF8.self) == env.root)
        let fd = env.svc(5, [s, 0, 0]).1.x[0]
        #expect(!env.svc(346, [fd, s + 0x2000]).1.carry)
        #expect(try env.space.read(va: s + 0x2000, count: 2168) == b)
        try env.putString("/nope", at: s)
        #expect(env.svc(345, [s, s + 0x1000]).1.x[0] == 2)
    }
}
