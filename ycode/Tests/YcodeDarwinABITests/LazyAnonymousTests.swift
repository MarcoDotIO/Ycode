import Testing
@testable import YcodeDarwinABI

/// Large anonymous mappings get backing when first touched
/// (specs/simulator/app-launch.md §3.2).
@Suite struct LazyAnonymousTests {
    private let big: UInt64 = 32 << 30

    @Test func reservationLargerThanThePoolMapsAndCostsNothing() throws {
        let backing = FakePhysicalBacking()
        let space = GuestAddressSpace(backing: backing)
        let before = backing.anonymousBytesInUse
        let va = try space.mapAnonymous(at: nil, size: big, protection: .readWrite, hint: nil)
        #expect(backing.anonymousBytesInUse == before)
        let r = try #require(space.region(containing: va + 0x1234_0000))
        #expect(r.backing == .unbacked && r.va == va && r.size == big)
        // A VMM write gives one block backing; reads elsewhere see zeros.
        try space.write(va: va + 0x10_0000, bytes: [1, 2, 3], checkingEL0Access: true)
        #expect(backing.anonymousBytesInUse == before + GuestAddressSpace.lazyBlockSize)
        #expect(try space.read(va: va + 0x10_0000, count: 3) == [1, 2, 3])
        #expect(try space.read(va: va + 0x20_0000, count: 2) == [0, 0])
        #expect(space.lazyBlocksMaterialized == 2)
        let touched = try #require(space.region(containing: va + 0x10_0000))
        #expect(touched.backing != .unbacked && touched.size == GuestAddressSpace.lazyBlockSize)
        #expect(space.region(containing: va)?.backing == .unbacked)
        try space.unmap(va: va, size: big)
        #expect(backing.anonymousBytesInUse == before)
        #expect(space.regions.isEmpty)
    }

    @Test func faultsResolveOnlyWhereAccessIsAllowed() throws {
        let (backing, space) = { let b = FakePhysicalBacking(); return (b, GuestAddressSpace(backing: b)) }()
        let va = try space.mapAnonymous(at: nil, size: big, protection: .none, hint: nil)
        #expect(!space.resolveTranslationFault(va: va + 0x8000))
        #expect(throws: (any Error).self) { _ = try space.read(va: va, count: 1) }
        // Commit a part (JavaScriptCore's pattern): mprotect, then touch.
        try space.protect(va: va + 0x40_0000, size: 0x10_0000, protection: .readWrite)
        #expect(space.resolveTranslationFault(va: va + 0x40_4000))
        #expect(!space.resolveTranslationFault(va: va + 0x40_4000))   // already backed
        #expect(!space.resolveTranslationFault(va: va + 0x80_0000))   // still PROT_NONE
        #expect(space.region(containing: va + 0x40_4000)?.protection == .readWrite)
        #expect(backing.anonymousBytesInUse == GuestAddressSpace.lazyBlockSize)
        // Protecting across touched and untouched parts works.
        try space.protect(va: va, size: big, protection: .read)
        #expect(space.region(containing: va + 0x40_4000)?.protection == .read)
        #expect(throws: (any Error).self) { try space.write(va: va + 0x40_4000, bytes: [1], checkingEL0Access: true) }
        // A fixed mapping over part of it replaces that part only.
        let small = try space.mapAnonymous(at: va + 0x100_0000, size: 0x4000, protection: .readWrite, hint: nil)
        #expect(small == va + 0x100_0000)
        #expect(space.region(containing: small)?.backing != .unbacked)
        #expect(space.region(containing: small + 0x4000)?.backing == .unbacked)
    }

    @Test func smallMappingsStayEager() throws {
        let backing = FakePhysicalBacking()
        let space = GuestAddressSpace(backing: backing)
        let va = try space.mapAnonymous(at: nil, size: 1 << 20, protection: .readWrite, hint: nil)
        #expect(space.region(containing: va)?.backing != .unbacked)
        #expect(backing.anonymousBytesInUse == 1 << 20)
    }
}
