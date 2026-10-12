#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Testing
@testable import YcodeDarwinABI

private func makeSpace() -> (GuestAddressSpace, FakePhysicalBacking) {
    let backing = FakePhysicalBacking()
    return (GuestAddressSpace(backing: backing), backing)
}

private func errno(of body: () throws -> Void) -> Int32? {
    do { try body() } catch let e as DarwinErrnoError { return e.errno } catch { return -1 }
    return nil
}

/// stage3-contract.md §4: `VMProtection`, `GuestAddressSpace`, `FakePhysicalBacking`.
@Suite struct AddressSpaceTests {
    @Test func protectionValuesAndAttributes() {
        #expect(VMProtection.read.rawValue == 1 && VMProtection.write.rawValue == 2 && VMProtection.execute.rawValue == 4)
        #expect(VMProtection.read.el0PageAttributes == PageAttributes(access: .el0ReadOnly))
        #expect(VMProtection.readWrite.el0PageAttributes == PageAttributes(access: .el0ReadWrite))
        #expect(VMProtection.readExecute.el0PageAttributes == PageAttributes(access: .el0ReadOnly, el0Execute: true))
        #expect(VMProtection.all.el0PageAttributes == PageAttributes(access: .el0ReadWrite, el0Execute: true))
        #expect(VMProtection.write.el0PageAttributes == PageAttributes(access: .el0ReadWrite))
        #expect(VMProtection.none.el0PageAttributes == PageAttributes(access: .el1ReadOnly))
        // PXN is always set.
        for raw in UInt32(0)...7 { #expect(!VMProtection(rawValue: raw).el0PageAttributes.el1Execute) }
        #expect(VMProtection.readExecute.description == "r-x")
    }

    @Test func anywhereStartsAtBaseAndIsFirstFit() throws {
        let (space, _) = makeSpace()
        let a = try space.mapAnonymous(at: nil, size: 0x4000, protection: .readWrite, hint: nil)
        #expect(a == 0x3_2000_0000)
        let b = try space.mapAnonymous(at: nil, size: 0x5000, protection: .readWrite, hint: nil)
        #expect(b == 0x3_2000_4000)   // size rounded up to 0x8000
        let c = try space.mapAnonymous(at: nil, size: 0x4000, protection: .read, hint: nil)
        #expect(c == 0x3_2000_C000)
        // Free the middle; a small request fills the hole, a big one goes past.
        try space.unmap(va: b, size: 0x8000)
        #expect(try space.mapAnonymous(at: nil, size: 0xC000, protection: .readWrite, hint: nil) == 0x3_2001_0000)
        #expect(try space.mapAnonymous(at: nil, size: 0x4000, protection: .readWrite, hint: nil) == 0x3_2000_4000)
        #expect(try space.mapAnonymous(at: nil, size: 0x4000, protection: .readWrite, hint: nil) == 0x3_2000_8000)
    }

    @Test func hintIsRespectedAndClampedToBase() throws {
        let (space, _) = makeSpace()
        // A hint below the base (even inside the shared region) is raised to the base.
        #expect(try space.mapAnonymous(at: nil, size: 0x4000, protection: .readWrite, hint: 0x1_0000_0000) == 0x3_2000_0000)
        #expect(try space.mapAnonymous(at: nil, size: 0x4000, protection: .readWrite, hint: 0x2_0000_0000) == 0x3_2000_4000)
        // A hint above the base is used as given (rounded up to 16 KiB).
        #expect(try space.mapAnonymous(at: nil, size: 0x4000, protection: .readWrite, hint: 0x4_0000_0001) == 0x4_0000_4000)
        #expect(try space.mapAnonymous(at: nil, size: 0x4000, protection: .readWrite, hint: 0x4_0000_0000) == 0x4_0000_0000)
        #expect(try space.mapAnonymous(at: nil, size: 0x4000, protection: .readWrite, hint: 0x4_0000_0000) == 0x4_0000_8000)
        // A hint with no room above it falls back to the base.
        #expect(try space.mapAnonymous(at: nil, size: 0x8000, protection: .readWrite, hint: VMLayout.userVALimit - 0x4000)
                == 0x3_2000_8000)
    }

    @Test func anywhereNeverUsesSharedRegionOrCommpageReservation() throws {
        let (space, _) = makeSpace()
        for hint: UInt64? in [nil, 0, 0x1_0000_0000, VMLayout.sharedRegionBase, 0x1_C000_0000, VMLayout.sharedRegionEnd - 0x4000,
                              VMLayout.commpageReservationBase, VMLayout.commpageVA, UInt64.max] {
            let va = try space.mapAnonymous(at: nil, size: 0x4000, protection: .read, hint: hint)
            #expect(va >= VMLayout.anonymousVABase && va + 0x4000 <= VMLayout.userVALimit, "hint \(String(describing: hint))")
        }
        #expect(space.regions.allSatisfy { $0.end <= VMLayout.sharedRegionBase || $0.va >= VMLayout.sharedRegionEnd })
        #expect(space.anywhereExclusions.contains(VMLayout.sharedRegionBase..<VMLayout.sharedRegionEnd))
        // More than the whole anywhere range: ENOMEM, nothing allocated.
        let total = VMLayout.userVALimit - VMLayout.anonymousVABase
        let before = space.regions
        #expect(errno { _ = try space.mapAnonymous(at: nil, size: total, protection: .read, hint: nil) } == DarwinErrnoCode.ENOMEM)
        #expect(space.regions == before)
    }

    @Test func fixedMappingsGoIntoSharedRegionAndReplace() throws {
        let (space, backing) = makeSpace()
        let va = try space.mapAnonymous(at: 0x1_C000_0000, size: 0xC000, protection: .readWrite, hint: nil)
        #expect(va == 0x1_C000_0000)
        try space.write(va: 0x1_C000_4000, bytes: [1, 2, 3])
        let inUse = backing.anonymousBytesInUse
        #expect(inUse == 0xC000)
        // MAP_FIXED over the middle page: the old page is released and the new one is zero.
        _ = try space.mapAnonymous(at: 0x1_C000_4000, size: 0x4000, protection: .read, hint: nil)
        #expect(try space.read(va: 0x1_C000_4000, count: 3) == [0, 0, 0])
        #expect(backing.anonymousBytesInUse == 0xC000)
        let regions = space.regions
        #expect(regions.map(\.va) == [0x1_C000_0000, 0x1_C000_4000, 0x1_C000_8000])
        #expect(regions.map(\.size) == [0x4000, 0x4000, 0x4000])
        #expect(regions.map(\.protection) == [.readWrite, .read, .readWrite])
        // The split-off pieces keep their original physical pages.
        #expect(space.pageTables.translate(0x1_C000_8000)?.pa == regions[0].gpa + 0x8000)
        #expect(space.region(containing: 0x1_C000_5000)?.protection == .read)
        #expect(space.region(containing: 0x1_C000_C000) == nil)
    }

    @Test func fixedRangeRules() throws {
        let (space, _) = makeSpace()
        #expect(errno { _ = try space.mapAnonymous(at: 0x3_2000_0001, size: 0x4000, protection: .read, hint: nil) } == DarwinErrnoCode.EINVAL)
        #expect(errno { _ = try space.mapAnonymous(at: 0x3_2000_0000, size: 0, protection: .read, hint: nil) } == DarwinErrnoCode.EINVAL)
        // Page zero (where the EL1 identity regions live) and above the user limit.
        #expect(errno { _ = try space.mapAnonymous(at: 0x4000_0000, size: 0x4000, protection: .read, hint: nil) } == DarwinErrnoCode.ENOMEM)
        #expect(errno { _ = try space.mapAnonymous(at: VMLayout.commpageVA, size: 0x4000, protection: .read, hint: nil) } == DarwinErrnoCode.ENOMEM)
        #expect(space.regions.isEmpty)
        #expect(space.generation == 0)
    }

    @Test func permanentMappings() throws {
        let (space, _) = makeSpace()
        try space.mapPermanentAnonymous(at: VMLayout.commpageVA, size: 0x4000, protection: .read)
        try space.mapPermanentAnonymous(at: VMLayout.hostPageVA, size: VMLayout.hostPageSize, protection: .readWrite)
        // The VMM fills read-only pages with checks off.
        try space.write(va: VMLayout.commpageVA, bytes: [0xAB], checkingEL0Access: false)
        #expect(try space.read(va: VMLayout.commpageVA, count: 1) == [0xAB])
        #expect(throws: GuestMemoryError.accessDenied(va: VMLayout.commpageVA)) {
            try space.write(va: VMLayout.commpageVA, bytes: [1])
        }
        // The guest can neither unmap, replace, nor re-protect them.
        #expect(errno { try space.unmap(va: VMLayout.hostPageVA, size: 0x4000) } == DarwinErrnoCode.EINVAL)
        #expect(errno { _ = try space.mapAnonymous(at: VMLayout.hostPageVA, size: 0x4000, protection: .read, hint: nil) } == DarwinErrnoCode.EINVAL)
        #expect(errno { try space.protect(va: VMLayout.hostPageVA, size: 0x4000, protection: .all) } == DarwinErrnoCode.EINVAL)
        let allPermanent = space.regions.allSatisfy { $0.permanent }
        #expect(allPermanent)
        // Anywhere placement skips the host page.
        let r = try space.mapAnonymous(at: nil, size: 0x4000, protection: .read, hint: VMLayout.hostPageVA)
        #expect(r == VMLayout.anonymousVABase)
        // A permanent mapping at the base is skipped by anywhere placement.
        try space.unmap(va: r, size: 0x4000)
        try space.mapPermanentAnonymous(at: VMLayout.anonymousVABase, size: 0x8000, protection: .read)
        #expect(try space.mapAnonymous(at: nil, size: 0x4000, protection: .read, hint: nil) == VMLayout.anonymousVABase + 0x8000)
    }

    @Test func unmapAndProtectTranslate() throws {
        let (space, backing) = makeSpace()
        let va = try space.mapAnonymous(at: nil, size: 0x10000, protection: .readWrite, hint: nil)
        try space.write(va: va + 0x8000, bytes: [9, 8, 7])
        try space.protect(va: va + 0x8000, size: 0x4000, protection: .read)
        #expect(space.pageTables.translate(va + 0x8000)?.attributes == PageAttributes(access: .el0ReadOnly))
        #expect(space.pageTables.translate(va)?.attributes == PageAttributes(access: .el0ReadWrite))
        #expect(throws: GuestMemoryError.accessDenied(va: va + 0x8000)) { try space.write(va: va + 0x8000, bytes: [1]) }
        #expect(try space.read(va: va + 0x8000, count: 3) == [9, 8, 7])
        // A write that crosses into the read-only page changes nothing.
        #expect(throws: GuestMemoryError.accessDenied(va: va + 0x8000)) { try space.write(va: va + 0x7FFE, bytes: [5, 5, 5]) }
        #expect(try space.read(va: va + 0x7FFE, count: 2) == [0, 0])
        // PROT_NONE: mapped (reserved) but inaccessible.
        try space.protect(va: va, size: 0x4000, protection: .none)
        #expect(throws: GuestMemoryError.accessDenied(va: va)) { _ = try space.read(va: va, count: 1) }
        #expect(space.pageTables.translate(va) != nil)
        // mprotect over a hole is ENOMEM and changes nothing.
        #expect(errno { try space.protect(va: va + 0xC000, size: 0x8000, protection: .read) } == DarwinErrnoCode.ENOMEM)
        #expect(space.region(containing: va + 0xC000)?.protection == .readWrite)

        try space.unmap(va: va + 0x4000, size: 0x8000)
        #expect(space.pageTables.translate(va + 0x4000) == nil)
        #expect(space.pageTables.translate(va + 0x8000) == nil)
        #expect(space.pageTables.translate(va + 0xC000) != nil)
        #expect(throws: GuestMemoryError.unmapped(va: va + 0x4000)) { _ = try space.read(va: va + 0x4000, count: 1) }
        #expect(backing.anonymousBytesInUse == 0x8000)
        // Unmapping a hole succeeds.
        try space.unmap(va: va + 0x4000, size: 0x4000)
        #expect(space.regions.map(\.va) == [va, va + 0xC000])
        // A re-allocation of freed pages reads as zero.
        let again = try space.mapAnonymous(at: nil, size: 0x8000, protection: .readWrite, hint: nil)
        #expect(again == va + 0x4000)
        #expect(try space.read(va: va + 0x8000, count: 3) == [0, 0, 0])
    }

    @Test func dirtyTablesAreWrittenAndGenerationBumps() throws {
        let (space, backing) = makeSpace()
        #expect(space.generation == 0)
        _ = try space.mapAnonymous(at: nil, size: 0x4000, protection: .readWrite, hint: nil)
        #expect(space.generation == 1)
        #expect(!space.pageTables.hasDirtyTables)
        // Root, L2, L3 were written to the arena.
        let tableWrites = backing.writeLog.filter { $0.gpa >= 0x4020_0000 && $0.gpa < 0x4420_0000 }
        #expect(tableWrites.count == 3 && tableWrites.allSatisfy { $0.count == 16384 })
        // The written bytes equal the builder's tables.
        for t in space.pageTables.tables {
            #expect(try backing.readPhysical(gpa: t.gpa, count: 16384) == t.bytes)
        }
        backing.writeLog.removeAll()
        try space.protect(va: 0x3_2000_0000, size: 0x4000, protection: .read)
        #expect(space.generation == 2)
        #expect(backing.writeLog.map(\.gpa) == [space.pageTables.tables[2].gpa])
        // No-ops do not bump.
        try space.unmap(va: 0x5_0000_0000, size: 0x4000)
        try space.protect(va: 0x3_2000_0000, size: 0x4000, protection: .read)
        #expect(space.generation == 2)
        try space.unmap(va: 0x3_2000_0000, size: 0x4000)
        #expect(space.generation == 3)
        // Failed calls do not bump.
        _ = errno { _ = try space.mapAnonymous(at: 0x1, size: 0x4000, protection: .read, hint: nil) }
        #expect(space.generation == 3)
    }

    @Test func flushWritesPrebuiltEL1Tables() throws {
        let backing = FakePhysicalBacking()
        var pt = PageTableBuilder.stage3()
        for r in VMLayout.stage3EL1Regions { try pt.mapIdentity(r) }
        let space = GuestAddressSpace(backing: backing, pageTables: pt)
        try space.flushPageTables()
        #expect(space.generation == 1)
        for t in space.pageTables.tables {
            #expect(try backing.readPhysical(gpa: t.gpa, count: 16384) == t.bytes)
        }
        try space.flushPageTables()
        #expect(space.generation == 1)
        // EL1 identity pages are not EL0-accessible through the address space.
        #expect(throws: GuestMemoryError.accessDenied(va: VMLayout.bootInfoGPA)) {
            _ = try space.read(va: VMLayout.bootInfoGPA, count: 1)
        }
    }

    @Test func fileMappings() throws {
        let dir = try TempTree()
        let bytes = (0..<0x6000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) }
        try dir.writeFile("lib.bin", bytes)
        let file = try GuestFile.openReadOnly(hostPath: dir.host("lib.bin"))
        #expect(file.size == 0x6000)
        let (space, backing) = makeSpace()
        // Map from offset 0x4000 (two pages; the second is past EOF after 0x2000 bytes).
        let va = try space.mapFile(file, offset: 0x4000, at: nil, size: 0x8000, protection: .readExecute, hint: nil)
        #expect(va == 0x3_2000_0000)
        #expect(try space.read(va: va, count: 0x2000) == Array(bytes[0x4000..<0x6000]))
        #expect(try space.read(va: va + 0x2000, count: 0x10) == [UInt8](repeating: 0, count: 0x10))
        #expect(space.pageTables.translate(va)?.attributes == PageAttributes(access: .el0ReadOnly, el0Execute: true))
        #expect(backing.fileSlots.count == 1 && backing.fileSlots[0].offset == 0x4000 && backing.fileSlots[0].size == 0x8000)
        let region = try #require(space.region(containing: va))
        #expect(region.backing == .file(path: file.guestPath, offset: 0x4000, gpa: VMLayout.fileSlotGPABase))
        #expect(region.backingDescription.contains("lib.bin"))
        #expect(space.file(at: va) === file)
        // Private: a writable mapping can be written; the host file is unchanged.
        let rw = try space.mapFile(file, offset: 0, at: 0x1_C000_0000, size: 0x4000, protection: .readWrite, hint: nil)
        try space.write(va: rw, bytes: [0xEE])
        #expect(try space.read(va: rw, count: 2) == [0xEE, bytes[1]])
        #expect(try file.read(count: 1, offset: 0) == [bytes[0]])
        // Splitting a file chunk keeps offsets.
        try space.unmap(va: va, size: 0x4000)
        #expect(space.region(containing: va + 0x4000)?.backing == .file(path: file.guestPath, offset: 0x8000, gpa: VMLayout.fileSlotGPABase + 0x4000))
        // Unaligned file offsets are EINVAL.
        #expect(errno { _ = try space.mapFile(file, offset: 0x100, at: nil, size: 0x4000, protection: .read, hint: nil) } == DarwinErrnoCode.EINVAL)
    }

    @Test func readCString() throws {
        let (space, _) = makeSpace()
        let va = try space.mapAnonymous(at: nil, size: 0x8000, protection: .readWrite, hint: nil)
        try space.write(va: va + 0x3FFC, bytes: Array("hello".utf8) + [0])
        #expect(try space.readCString(va: va + 0x3FFC) == "hello")
        #expect(errno { _ = try space.readCString(va: va + 0x3FFC, maxLength: 3) } == DarwinErrnoCode.ENAMETOOLONG)
    }

    @Test func fakeBackingPool() throws {
        let b = FakePhysicalBacking()
        let a = try b.allocateAnonymous(size: 0x4000)
        let c = try b.allocateAnonymous(size: 0x8000)
        #expect(a == VMLayout.anonymousPoolGPA && c == a + 0x4000)
        try b.writePhysical(gpa: a, bytes: [1, 2])
        b.release(gpa: a, size: 0x4000)
        #expect(try b.allocateAnonymous(size: 0x4000) == a)
        #expect(try b.readPhysical(gpa: a, count: 2) == [0, 0])
        b.release(gpa: a, size: 0x4000)
        b.release(gpa: c, size: 0x8000)
        #expect(b.anonymousBytesInUse == 0)
        #expect(try b.allocateAnonymous(size: 0xC000) == a)   // coalesced
        #expect(throws: FakePhysicalBackingError.self) { _ = try b.readPhysical(gpa: 0x8000_0000, count: 1) }
        #expect(try b.readPhysical(gpa: VMLayout.ramGPA, count: 4) == [0, 0, 0, 0])
    }
}
