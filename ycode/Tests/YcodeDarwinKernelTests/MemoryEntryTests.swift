import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// Mach memory entries (private routines n = 10, 11) and shared mappings
/// (`GuestAddressSpace.share`/`mapShared`). Semantics: xnu
/// vm_memory_entry.c and vm_map.c (`vm_map_enter_mem_object`).
@Suite struct MemoryEntryTests {
    let s = Env.scratch
    static let makeEntry: UInt64 = 0x7963_200A
    static let mapObject: UInt64 = 0x7963_200B
    static let vmAllocate = UInt64(bitPattern: -10)
    static let page = VMLayout.pageSize

    func allocate(_ env: Env, _ size: UInt64) throws -> UInt64 {
        try env.put(le64(0), at: s + 0x100)
        #expect(env.svc(Self.vmAllocate, [0x103, s + 0x100, size, 1]).1.x[0] == 0)
        return try env.u64(s + 0x100)
    }

    /// mach_make_memory_entry_64 → (kr, size, handle).
    func makeEntry(_ env: Env, offset: UInt64, size: UInt64, permission: UInt64, parent: UInt64 = 0) throws
        -> (UInt64, UInt64, UInt32) {
        try env.put(le64(size), at: s + 0x200)
        try env.put(le32(0), at: s + 0x208)
        let kr = env.svc(Self.makeEntry, [0x103, s + 0x200, offset, permission, s + 0x208, parent]).1.x[0]
        return (kr, try env.u64(s + 0x200), try env.u32(s + 0x208))
    }

    /// mach_vm_map with an object → (kr, address).
    func map(_ env: Env, object: UInt32, offset: UInt64 = 0, size: UInt64, flags: UInt64 = 1, at: UInt64 = 0,
             copy: Bool = false, cur: UInt64 = 3, max: UInt64 = 3) throws -> (UInt64, UInt64) {
        try env.put(le64(at), at: s + 0x300)
        try env.put(le64(UInt64(object)) + le64(offset) + le64(copy ? 1 : 0) + le64(cur) + le64(max) + le64(0), at: s + 0x400)
        let kr = env.svc(Self.mapObject, [0x103, s + 0x300, size, 0, flags, s + 0x400]).1.x[0]
        return (kr, try env.u64(s + 0x300))
    }

    @Test func shareExistingMemoryAndMapItTwice() throws {
        let env = try Env()
        let buffer = try allocate(env, 0x100000)
        try env.put(Array("before".utf8), at: buffer + 0x10)
        let (kr, size, handle) = try makeEntry(env, offset: buffer, size: 0x100000, permission: 3)
        #expect(kr == 0 && size == 0x100000 && handle != 0)
        // The range kept its contents and is now shared memory.
        #expect(try env.space.read(va: buffer + 0x10, count: 6) == Array("before".utf8))
        let region = try #require(env.space.region(containing: buffer))
        if case .shared = region.backing {} else { Issue.record("not shared: \(region)") }
        // A second mapping sees the same bytes, both ways.
        let (mkr, other) = try map(env, object: handle, size: 0)
        #expect(mkr == 0 && other != buffer)
        #expect(try env.space.read(va: other + 0x10, count: 6) == Array("before".utf8))
        try env.put(Array("after!".utf8), at: other + 0x10)
        #expect(try env.space.read(va: buffer + 0x10, count: 6) == Array("after!".utf8))
        // A copy does not follow later writes.
        let (ckr, copy) = try map(env, object: handle, size: Self.page, copy: true)
        #expect(ckr == 0)
        try env.put(Array("third.".utf8), at: buffer + 0x10)
        #expect(try env.space.read(va: copy + 0x10, count: 6) == Array("after!".utf8))
        // Unmapping one mapping keeps the other.
        #expect(env.svc(UInt64(bitPattern: -12), [0x103, buffer, 0x100000]).1.x[0] == 0)
        #expect(try env.space.read(va: other + 0x10, count: 6) == Array("third.".utf8))
    }

    @Test func namedCreateSubEntriesAndRules() throws {
        let env = try Env()
        // MAP_MEM_NAMED_CREATE | read-only.
        let (kr, size, ro) = try makeEntry(env, offset: 0, size: 100, permission: 0x02_0000 | 1)
        #expect(kr == 0 && size == Self.page)
        // A writable mapping of a read-only entry: KERN_INVALID_RIGHT; read-only is fine.
        #expect(try map(env, object: ro, size: 0).0 == 17)
        #expect(try map(env, object: ro, size: 0, cur: 1, max: 1).0 == 0)
        // VM_PROT_IS_MASK trims the request instead.
        #expect(try map(env, object: ro, size: 0, cur: 0x43, max: 0x43).0 == 0)
        // Past the end, not an entry, a fixed address over a mapping.
        #expect(try map(env, object: ro, size: 2 * Self.page, cur: 1, max: 1).0 == 4)
        #expect(try map(env, object: 0x103, size: 0, cur: 1, max: 1).0 == 29)
        #expect(try map(env, object: ro, size: 0, flags: 0, at: s, cur: 1, max: 1).0 == 3)
        // A sub-entry of a writable parent.
        let (_, _, rw) = try makeEntry(env, offset: 0, size: 4 * Self.page, permission: 0x02_0000 | 3)
        let (skr, ssize, sub) = try makeEntry(env, offset: Self.page, size: Self.page, permission: 3, parent: UInt64(rw))
        #expect(skr == 0 && ssize == Self.page)
        let (_, whole) = try map(env, object: rw, size: 0)
        let (_, part) = try map(env, object: sub, size: 0)
        try env.put([0xAB], at: part)
        #expect(try env.space.read(va: whole + Self.page, count: 1) == [0xAB])
        // A sub-entry asking for more than the parent allows.
        #expect(try makeEntry(env, offset: 0, size: Self.page, permission: 3, parent: UInt64(ro)).0 == 2)
        // Sharing memory that is not writable as writable: KERN_PROTECTION_FAILURE.
        let buffer = try allocate(env, Self.page)
        #expect(env.svc(UInt64(bitPattern: -14), [0x103, buffer, Self.page, 0, 1]).1.x[0] == 0)
        #expect(try makeEntry(env, offset: buffer, size: Self.page, permission: 3).0 == 2)
        // The port dies with its last send right.
        #expect(env.svc(UInt64(bitPattern: -18), [0x103, UInt64(ro)]).1.x[0] == 0)
        #expect(try map(env, object: ro, size: 0, cur: 1, max: 1).0 == 29)
    }

    /// mach_vm_remap (routine 12): share or copy a range of the caller (libobjc trampolines).
    @Test func vmRemapSharesOrCopies() throws {
        let env = try Env()
        let src = try allocate(env, Self.page)
        try env.put([7, 8, 9], at: src)
        func remap(copy: Bool, isNew: Bool = false, cur: UInt32 = 0) throws -> (UInt64, UInt64, UInt32, UInt32) {
            try env.put(le64(0), at: s + 0x300)
            try env.put(le32(cur) + le32(0), at: s + 0x500)
            try env.put(le64(0x103) + le64(src) + le64(copy ? 1 : 0) + le64(s + 0x500) + le64(s + 0x504) + le64(1)
                        + le64(isNew ? 1 : 0), at: s + 0x400)
            let kr = env.svc(0x7963_200C, [0x103, s + 0x300, Self.page, 0, 1, s + 0x400]).1.x[0]
            return (kr, try env.u64(s + 0x300), try env.u32(s + 0x500), try env.u32(s + 0x504))
        }
        let (kr, shared, cur, max) = try remap(copy: false)
        #expect(kr == 0 && shared != src && cur == 3 && max == 7)
        #expect(try env.space.read(va: shared, count: 3) == [7, 8, 9])
        try env.put([1], at: shared)
        #expect(try env.space.read(va: src, count: 1) == [1])
        let (ckr, copied, _, _) = try remap(copy: true)
        #expect(ckr == 0)
        try env.put([2], at: src)
        #expect(try env.space.read(va: copied, count: 1) == [1])
        // _new with a read-only request maps read-only.
        let (nkr, ro, ncur, _) = try remap(copy: false, isNew: true, cur: 1)
        #expect(nkr == 0 && ncur == 1 && env.space.region(containing: ro)?.protection == .read)
    }

    /// Two address spaces (two processes) see one object's bytes.
    @Test func sharedAcrossAddressSpaces() throws {
        let a = GuestAddressSpace(backing: FakePhysicalBacking())
        let b = GuestAddressSpace(backing: FakePhysicalBacking())
        let va = try a.mapAnonymous(at: nil, size: 2 * Self.page, protection: .readWrite, hint: nil)
        try a.write(va: va + Self.page, bytes: [1, 2, 3])
        let (object, offset) = try a.share(va: va + Self.page, size: Self.page)
        #expect(offset == 0 && object.size == Self.page)
        // Sharing the same range again gives the same object.
        #expect(try a.share(va: va + Self.page, size: Self.page).object === object)
        let vb = try b.mapShared(object, offset: 0, at: nil, size: Self.page, protection: .readWrite, hint: nil)
        #expect(try b.read(va: vb, count: 3) == [1, 2, 3])
        try b.write(va: vb + 1, bytes: [9])
        #expect(try a.read(va: va + Self.page, count: 3) == [1, 9, 3])
        // TBI0: a tagged address reaches the same bytes.
        #expect(try a.read(va: (va + Self.page) | 0xC000_0000_0000_0000, count: 3) == [1, 9, 3])
        // The first page stayed private anonymous memory.
        if case .anonymous = try #require(a.region(containing: va)).backing {} else { Issue.record("first page changed") }
    }

    /// POSIX shared memory (xnu posix_shm.c): one size per segment, MAP_SHARED only.
    @Test func posixSharedMemory() throws {
        let env = try Env()
        try env.putString("apple.shm.test", at: s + 0x100)
        try env.putString(String(repeating: "n", count: 32), at: s + 0x200)
        try env.putString("", at: s + 0x300)
        func shmOpen(_ name: UInt64, _ oflag: UInt64) -> (Bool, UInt64) {
            let f = env.svc(266, [name, oflag, 0o644]).1
            return (f.carry, f.x[0])
        }
        #expect(shmOpen(s + 0x100, 2) == (true, 2))  // no O_CREAT: ENOENT
        #expect(shmOpen(s + 0x200, 0x202) == (true, 63))  // ENAMETOOLONG
        #expect(shmOpen(s + 0x300, 0x202) == (true, 22))  // empty name
        #expect(shmOpen(s + 0x100, 0x203) == (true, 22))  // O_ACCMODE 3
        let (e1, rw) = shmOpen(s + 0x100, 0x202)  // O_RDWR | O_CREAT
        #expect(!e1)
        #expect(shmOpen(s + 0x100, 0xA02) == (true, 17))  // O_EXCL: EEXIST
        // mmap before the size is set: EINVAL. Then ftruncate once.
        #expect(env.svc(197, [0, Self.page, 3, 1, rw, 0]).1.x[0] == 22)
        #expect(!env.svc(201, [rw, 100]).1.carry)
        #expect(env.svc(201, [rw, 200]).1.x[0] == 22)
        #expect(shmOpen(s + 0x100, 0x402) == (true, 22))  // O_TRUNC after sizing
        // fstat: mode bits only, the page-rounded size.
        #expect(!env.svc(339, [rw, s + 0x400]).1.carry)
        let st = try env.space.read(va: s + 0x400, count: 144)
        #expect(u16(st, 4) == 0o644 && u64(st, 96) == Self.page)
        // MAP_PRIVATE: EINVAL; too large: EINVAL; MAP_SHARED: fine.
        #expect(env.svc(197, [0, Self.page, 3, 2, rw, 0]).1.x[0] == 22)
        #expect(env.svc(197, [0, 2 * Self.page, 3, 1, rw, 0]).1.x[0] == 22)
        let (_, f1) = env.svc(197, [0, Self.page, 3, 1, rw, 0])
        #expect(!f1.carry)
        // A second, read-only descriptor: PROT_WRITE is EPERM; read-only maps see the writes.
        let (e2, ro) = shmOpen(s + 0x100, 0)
        #expect(!e2)
        #expect(env.svc(197, [0, Self.page, 3, 1, ro, 0]).1.x[0] == 1)
        let (_, f2) = env.svc(197, [0, Self.page, 1, 1, ro, 0])
        try env.put([42, 43], at: f1.x[0] + 8)
        #expect(try env.space.read(va: f2.x[0] + 8, count: 2) == [42, 43])
        // read on the descriptor: ENXIO. Unlink: the name goes, the mapping stays.
        #expect(env.svc(3, [ro, s + 0x500, 4]).1.x[0] == 6)
        #expect(!env.svc(267, [s + 0x100]).1.carry)
        #expect(env.svc(267, [s + 0x100]).1.x[0] == 2)
        #expect(shmOpen(s + 0x100, 2) == (true, 2))
        #expect(try env.space.read(va: f2.x[0] + 8, count: 2) == [42, 43])
    }
}

/// mk_timer ports (xnu osfmk/kern/mk_timer.c): CoreFoundation's run-loop timers.
@Suite(.serialized) struct MachTimerTests {
    static func m(_ n: Int64) -> UInt64 { UInt64(bitPattern: n) }

    /// A non-blocking receive on `name` → (kr, size, id).
    func receive(_ t: T2Env, _ name: UInt64) -> (UInt64, UInt32, Int32) {
        let buf = Env.scratch + 0x8000
        t.put([UInt8](repeating: 0xEE, count: 0x100), at: buf)
        // MACH_RCV_MSG | MACH_RCV_TIMEOUT, timeout 0.
        let kr = t.x0(Self.m(-31), [buf, 0x102, 0, 0x100, name, 0, 0])
        let b = t.read(buf, 0x30)
        return (kr, b.readLE(UInt32.self, at: 4), b.readLE(Int32.self, at: 20))
    }

    /// task_threads (routine 13): send rights to every thread, in a new array.
    @Test func taskThreadsListsTheThreads() throws {
        let t = try T2Env()
        let out = Env.scratch + 0xA000
        #expect(t.x0(0x7963_200D, [0x103, out, out + 8]) == 0)
        let list = t.read(out, 8).readLE(UInt64.self, at: 0)
        let count = t.read(out + 8, 4).readLE(UInt32.self, at: 0)
        #expect(count == 1 && list != 0)
        let name = t.read(list, 4).readLE(UInt32.self, at: 0)
        #expect(name == t.main.portName)
        #expect(t.x0(0x7963_200D, [0x7777, out, out + 8]) == 4)
    }

    @Test func createArmExpireCancelDestroy() throws {
        let t = try T2Env()
        let timer = t.x0(Self.m(-91))
        #expect(timer != 0 && timer & 3 == 3)
        // Armed in the past: one 48-byte message at once, id 0, zero payload.
        #expect(t.x0(Self.m(-93), [timer, 1]) == 0)
        #expect(t.x0(Self.m(-93), [timer, 1]) == 0)  // still queued: no second one
        let (kr, size, id) = receive(t, timer)
        #expect(kr == 0 && size == 48 && id == 0)
        #expect(t.read(Env.scratch + 0x8000 + 24, 24) == [UInt8](repeating: 0, count: 24))
        #expect(receive(t, timer).0 == 0x1000_4003)  // MACH_RCV_TIMED_OUT: nothing else
        // Armed 20 ms ahead: arrives later.
        let soon = MachTimebase.now() + MachTimebase.frequency / 50
        #expect(t.x0(Self.m(-95), [timer, 0, soon, 0]) == 0)
        #expect(t.eventually { receive(t, timer).0 == 0 })
        // Cancel reports the armed deadline, then 0 when disarmed.
        let far = MachTimebase.now() + MachTimebase.frequency * 100
        #expect(t.x0(Self.m(-93), [timer, far]) == 0)
        #expect(t.x0(Self.m(-94), [timer, Env.scratch + 0x9000]) == 0)
        #expect(t.read(Env.scratch + 0x9000, 8).readLE(UInt64.self, at: 0) == far)
        #expect(t.x0(Self.m(-94), [timer, Env.scratch + 0x9000]) == 0)
        #expect(t.read(Env.scratch + 0x9000, 8).readLE(UInt64.self, at: 0) == 0)
        // Errors: unknown name, an ordinary port.
        #expect(t.x0(Self.m(-93), [0x7777_7703, 1]) == 15)
        let out = Env.scratch + 0x9100
        #expect(t.x0(Self.m(-16), [0x103, 1, out]) == 0)
        let plain = UInt64(t.read(out, 4).readLE(UInt32.self, at: 0))
        #expect(t.x0(Self.m(-93), [plain, 1]) == 4)
        #expect(t.x0(Self.m(-92), [plain]) == 4)
        // Destroy: the name goes away.
        #expect(t.x0(Self.m(-92), [timer]) == 0)
        #expect(t.x0(Self.m(-93), [timer, 1]) == 15)
    }
}
