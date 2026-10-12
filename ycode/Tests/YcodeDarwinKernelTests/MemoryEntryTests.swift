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
