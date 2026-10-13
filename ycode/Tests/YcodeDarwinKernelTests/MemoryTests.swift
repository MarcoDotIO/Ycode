import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

@Suite struct MemoryTests {
    static let anon: UInt64 = 0x1000
    static let priv: UInt64 = 0x2
    static let fixed: UInt64 = 0x10
    static let none = UInt64(bitPattern: -1)

    @Test func mmapAnonymousAnywhereAndFixed() throws {
        let env = try Env()
        let (_, a) = env.svc(197, [0, 0x5000, 3, Self.anon | Self.priv, Self.none, 0])
        #expect(!a.carry)
        let va = a.x[0]
        #expect(va >= 0x3_2000_0000 && va & 0x3FFF == 0)
        // Rounded to 32 KiB, zero-filled, writable.
        #expect(try env.space.read(va: va + 0x7FF8, count: 8) == [UInt8](repeating: 0, count: 8))
        try env.put([1, 2, 3], at: va)

        // MAP_FIXED inside the shared region at an exact address.
        let target: UInt64 = 0x1_C000_0000
        let (_, b) = env.svc(197, [target, 0x4000, 1, Self.anon | Self.priv | Self.fixed, Self.none, 0])
        #expect(!b.carry && b.x[0] == target)
        #expect(env.space.region(containing: target)?.protection == .read)

        // MAP_FIXED over an existing mapping replaces it (fresh zero page).
        let (_, c) = env.svc(197, [va, 0x4000, 3, Self.anon | Self.priv | Self.fixed, Self.none, 0])
        #expect(c.x[0] == va)
        #expect(try env.space.read(va: va, count: 3) == [0, 0, 0])

        // Unaligned MAP_FIXED, zero length: EINVAL.
        let (_, d) = env.svc(197, [target + 0x10, 0x4000, 1, Self.anon | Self.fixed, Self.none, 0])
        #expect(d.carry && d.x[0] == 22 && d.x[1] == 0)
        let (_, e) = env.svc(197, [0, 0, 1, Self.anon, Self.none, 0])
        #expect(e.carry && e.x[0] == 22)

        // munmap / mprotect.
        let (_, p) = env.svc(74, [target, 0x4000, 5])
        #expect(!p.carry)
        #expect(env.space.region(containing: target)?.protection == [.read, .execute])
        let (_, u) = env.svc(73, [target, 0x4000])
        #expect(!u.carry)
        #expect(env.space.region(containing: target) == nil)
        let (_, u2) = env.svc(73, [target + 1, 0x4000])
        #expect(u2.carry && u2.x[0] == 22)
        #expect(env.svc(75, [va, 0x4000, 3]).1.x[0] == 0)  // madvise

        #expect(env.sink.lines.contains {
            $0.hasPrefix("trap bsd 197 mmap(addr=0x1c0000000, len=0x4000, prot=r--, flags=PRIVATE|FIXED|ANON, fd=-1, off=0x0) -> 0x1c0000000")
        })
    }

    @Test func mmapFile() throws {
        let env = try Env()
        var content = [UInt8](repeating: 0, count: 0xA000)
        for i in content.indices { content[i] = UInt8(truncatingIfNeeded: i / 0x100) }
        let path = try env.makeFile("lib.dylib", content)
        try env.putString(path, at: Env.scratch)
        let (_, o) = env.svc(5, [Env.scratch, 0x0100_0000, 0])  // O_RDONLY | O_CLOEXEC
        #expect(!o.carry)
        let fd = o.x[0]
        #expect(fd == 3)

        // Fixed, private, read-execute, from file offset 0x4000.
        let at: UInt64 = 0x1_C000_8000
        let (_, m) = env.svc(197, [at, 0x6000, 5, Self.priv | Self.fixed, fd, 0x4000])
        #expect(!m.carry && m.x[0] == at)
        #expect(try env.space.read(va: at, count: 4, checkingEL0Access: false) == [0x40, 0x40, 0x40, 0x40])
        #expect(try env.space.read(va: at + 0x5F00, count: 1, checkingEL0Access: false) == [0x9F])
        guard case let .file(p, offset, _) = env.space.region(containing: at)?.backing else {
            Issue.record("expected a file mapping"); return
        }
        #expect(p == path && offset == 0x4000)

        // Anywhere, with an unaligned file offset: the result keeps the page offset.
        let (_, n) = env.svc(197, [0, 0x10, 1, Self.priv, fd, 0x4010])
        #expect(!n.carry && n.x[0] & 0x3FFF == 0x10)
        #expect(try env.space.read(va: n.x[0], count: 1, checkingEL0Access: false) == [0x40])

        // Mappings outlive close; a bad fd is EBADF.
        #expect(!env.svc(6, [fd]).1.carry)
        #expect(try env.space.read(va: at, count: 1, checkingEL0Access: false) == [0x40])
        let (_, bad) = env.svc(197, [0, 0x4000, 1, Self.priv, fd, 0])
        #expect(bad.carry && bad.x[0] == 9)
    }

    @Test func vmAllocateWritesAddressBack() throws {
        let env = try Env()
        let slot = Env.scratch + 0x100
        try env.put(leBytes(0), at: slot)
        var f = TrapFrame()
        env.svc(UInt64(bitPattern: -10), [0x103, slot, 0x6000, 0x0100_0001], frame: &f)  // ANYWHERE + a VM tag
        #expect(f.x[0] == 0)
        let va = try env.u64(slot)
        #expect(va >= 0x3_2000_0000 && va & 0x3FFF == 0)
        #expect(env.space.region(containing: va)?.protection == .readWrite)
        #expect(env.space.region(containing: va)?.size == 0x8000)

        // Fixed without overwrite over an existing mapping: KERN_NO_SPACE.
        try env.put(leBytes(va), at: slot)
        env.svc(UInt64(bitPattern: -10), [0x103, slot, 0x4000, 0], frame: &f)
        #expect(f.x[0] == 3)
        // Fixed at a free address.
        try env.put(leBytes(0x2_0000_0000 + 0x1_0000_0000), at: slot)
        env.svc(UInt64(bitPattern: -10), [0x103, slot, 0x4000, 0], frame: &f)
        #expect(try f.x[0] == 0 && env.u64(slot) == 0x3_0000_0000)

        // vm_protect masks VM_PROT_COPY; set_maximum is accepted.
        env.svc(UInt64(bitPattern: -14), [0x103, va, 0x4000, 0, 0x11], frame: &f)
        #expect(f.x[0] == 0)
        #expect(env.space.region(containing: va)?.protection == .read)
        env.svc(UInt64(bitPattern: -14), [0x103, va, 0x4000, 1, 0x7], frame: &f)
        #expect(f.x[0] == 0)

        // vm_deallocate.
        env.svc(UInt64(bitPattern: -12), [0x103, va, 0x8000], frame: &f)
        #expect(f.x[0] == 0 && env.space.region(containing: va) == nil)

        // A bad address pointer: KERN_INVALID_ADDRESS.
        env.svc(UInt64(bitPattern: -10), [0x103, 0x8, 0x4000, 1], frame: &f)
        #expect(f.x[0] == 1)

        // vm_copy (private).
        try env.put([9, 8, 7, 6], at: Env.scratch + 0x200)
        env.svc(0x7963_0004, [0x103, Env.scratch + 0x200, 4, Env.scratch + 0x300], frame: &f)
        #expect(try f.x[0] == 0 && env.space.read(va: Env.scratch + 0x300, count: 4) == [9, 8, 7, 6])
    }

    @Test func fileCalls() throws {
        let env = try Env()
        let path = try env.makeFile("data.bin", Array("0123456789".utf8))
        try env.putString(path, at: Env.scratch)
        let fd = env.svc(5, [Env.scratch, 0, 0]).1.x[0]

        // F_GETPATH.
        let buf = Env.scratch + 0x1000
        let (_, g) = env.svc(92, [fd, 50, buf])
        #expect(try !g.carry && env.string(buf) == path)

        // F_ADDFILESIGS_RETURN writes fs_file_start = file size.
        let sigs = Env.scratch + 0x2000
        try env.put(leBytes(0) + leBytes(0x5555) + leBytes(0x100), at: sigs)
        let (_, s) = env.svc(92, [fd, 97, sigs])
        #expect(try !s.carry && env.u64(sigs) == 10)
        #expect(try env.u64(sigs + 8) == 0x5555)

        #expect(env.svc(92, [fd, 98, 0]).1.x[0] == 0)  // F_CHECK_LV
        #expect(env.svc(92, [fd, 1, 0]).1.x[0] == 0)  // F_GETFD
        #expect(!env.svc(92, [fd, 2, 1]).1.carry)  // F_SETFD FD_CLOEXEC
        #expect(env.svc(92, [fd, 1, 0]).1.x[0] == 1)
        #expect(env.svc(92, [fd, 3, 0]).1.x[0] == 0)  // F_GETFL: O_RDONLY
        #expect(env.svc(92, [fd, 42, 0]).1.x[0] == 9)  // F_PREALLOCATE on a read-only fd: EBADF
        let (_, other) = env.svc(92, [fd, 9999, 0])
        #expect(other.carry && other.x[0] == 22)

        // read / pread.
        let (_, r) = env.svc(3, [fd, buf, 4])
        #expect(try r.x[0] == 4 && env.space.read(va: buf, count: 4) == Array("0123".utf8))
        let (_, pr) = env.svc(153, [fd, buf, 3, 7])
        #expect(try pr.x[0] == 3 && env.space.read(va: buf, count: 3) == Array("789".utf8))

        // stat64 / fstat64 / lstat64: 144 bytes with st_size at +96.
        let st = Env.scratch + 0x3000
        #expect(!env.svc(338, [Env.scratch, st]).1.carry)
        #expect(try env.u64(st + 96) == 10)
        try env.put([UInt8](repeating: 0xFF, count: 144), at: st)
        #expect(!env.svc(339, [fd, st]).1.carry)
        #expect(try env.u64(st + 96) == 10)
        #expect(try env.u64(st + 136) == 0)
        #expect(!env.svc(340, [Env.scratch, st]).1.carry)

        // Missing file / outside the allowlist: ENOENT.
        try env.putString(env.root + "/missing", at: Env.scratch + 0x400)
        let (_, missing) = env.svc(5, [Env.scratch + 0x400, 0, 0])
        #expect(missing.carry && missing.x[0] == 2)
        #expect(env.svc(347, [0, 0, 0]).1.x[0] == 2)  // getfsstat64: "/" and the root prefix

        // realpath / getcwd (private).
        let out = Env.scratch + 0x4000
        let (_, rp) = env.svc(0x7963_0002, [Env.scratch, out])
        #expect(try !rp.carry && rp.x[0] == out && env.string(out) == path)
        let (_, small) = env.svc(0x7963_0003, [out, 1])
        #expect(small.carry && small.x[0] == 34)

        // proc_regionfilename (private) for a file mapping.
        let at: UInt64 = 0x1_C000_0000
        _ = env.svc(197, [at, 0x4000, 1, Self.priv | Self.fixed, fd, 0])
        let (_, prf) = env.svc(0x7963_0005, [100, at + 8, out, 1024])
        #expect(prf.x[0] == UInt64(path.utf8.count))
        #expect(String(decoding: try env.space.read(va: out, count: path.utf8.count), as: UTF8.self) == path)
    }
}
