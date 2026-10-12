import Testing
@testable import YcodeDarwinABI

private let el0Data = PageAttributes(access: .el0ReadWrite)
private let el0RO = PageAttributes(access: .el0ReadOnly)
private let el0Code = PageAttributes(access: .el0ReadOnly, el0Execute: true)

/// Constants of specs/simulator/stage3-contract.md §2, §3, §5.
@Suite struct Stage3LayoutTests {
    @Test func physicalMap() {
        #expect(VMLayout.ramGPA == 0x4000_0000)
        #expect(VMLayout.stage3RAMSize == 0x4000_0000)
        #expect(VMLayout.stage3PageTableArenaGPA == 0x4020_0000)
        #expect(VMLayout.stage3PageTableArenaSize == 0x400_0000)
        #expect(VMLayout.anonymousPoolGPA == 0x10_0000_0000)
        #expect(VMLayout.anonymousPoolSize == 0x4_0000_0000)
        #expect(VMLayout.fileSlotGPABase == 0x20_0000_0000)
        #expect(VMLayout.firstExtraMemslot == 1)
        // Stage-2 values are unchanged.
        #expect(VMLayout.ramSize == 0x2000_0000)
        #expect(VMLayout.pageTableArenaSize == 0x80_0000)
        let r = Dictionary(uniqueKeysWithValues: VMLayout.stage3EL1Regions.map { ($0.name, $0) })
        #expect(r["page-tables"]?.va == 0x4020_0000 && r["page-tables"]?.end == 0x4420_0000)
        #expect(r["shim"] == VMLayout.el1Regions.first { $0.name == "shim" })
        // The arena ends inside RAM; the pool and file slots are inside 40-bit PA space.
        #expect(VMLayout.stage3PageTableArenaGPA + VMLayout.stage3PageTableArenaSize <= VMLayout.ramGPA + VMLayout.stage3RAMSize)
        #expect(VMLayout.fileSlotGPABase < 1 << VMLayout.physicalAddressBits)
        #expect(VMLayout.anonymousPoolGPA + VMLayout.anonymousPoolSize <= VMLayout.fileSlotGPABase)
        #expect(PageTableBuilder.stage3().capacity == 4096)
    }

    @Test func virtualMap() {
        #expect(VMLayout.mainExecutableBaseVA == 0x1_0000_0000)
        #expect(VMLayout.userStackTop == 0x1_6FE0_0000)
        #expect(VMLayout.userStackBase == 0x1_6F60_0000)
        #expect(VMLayout.sharedRegionBase == 0x1_8000_0000 && VMLayout.sharedRegionEnd == 0x3_0000_0000)
        #expect(VMLayout.dyldSimBaseVA == 0x3_0000_0000)
        #expect(VMLayout.hostPageVA == 0x3_1000_0000 && VMLayout.hostPageSize == 0x1_0000)
        #expect(VMLayout.anonymousVABase == 0x3_2000_0000)
        #expect(VMLayout.readOnlyCommpageVA == 0xF_FFFF_4000)
        #expect(VMLayout.commpageVA == 0xF_FFFF_C000)
        #expect(VMLayout.userVALimit == 0xF_C000_0000)
    }

    @Test func hostPage() {
        #expect(VMLayout.hostPageEntryVA == 0x3_1000_0000)
        #expect(VMLayout.hostPageHelpersOffset == 0x4000 && VMLayout.hostPageHelpersSize == 544)
        #expect(VMLayout.hostPageHelpersSize == 8 + 8 * UInt64(VMLayout.helpersSlotCount))
        #expect(VMLayout.helpersTableVersion == 18)
        #expect(VMLayout.hostPageErrnoOffset == 0x8000)
        #expect(VMLayout.hostPageStartGlueOffset == 0x8008)
        #expect(VMLayout.hostPageLaunchBlockOffset == 0x8040 && VMLayout.hostPageLaunchBlockSize == 96)
        #expect(VMLayout.hostPageAllImageInfosOffset == 0x8100 && VMLayout.hostPageAllImageInfosSize == 368)
        #expect(VMLayout.hostPageImageInfoStorageOffset == 0x8300 && VMLayout.hostPageImageInfoStorageSize == 0x800)
        #expect(VMLayout.hostPageScratchOffset == 0x9000 && VMLayout.hostPageScratchSize == 0x1000)
        let regions = VMLayout.hostPageRegions
        #expect(regions.map(\.va) == [0x3_1000_0000, 0x3_1000_4000, 0x3_1000_8000])
        #expect(regions.map(\.size) == [0x4000, 0x4000, 0x8000])
        #expect(regions.map(\.attributes) == [el0Code, el0RO, el0Data])
        #expect(regions.last!.end == VMLayout.hostPageVA + VMLayout.hostPageSize)
    }
}

/// `PageTableBuilder.unmap`, `protect`, and dirty tracking (§4).
@Suite struct PageTableStage3Tests {
    @Test func freshBuilderRootIsDirty() {
        var b = PageTableBuilder()
        #expect(b.hasDirtyTables)
        let d = b.drainDirtyTables()
        #expect(d.map(\.gpa) == [0x4020_0000])
        #expect(d[0].bytes == [UInt8](repeating: 0, count: 16384))
        #expect(!b.hasDirtyTables)
        #expect(b.drainDirtyTables().isEmpty)
    }

    @Test func mapMarksNewAndChangedTables() throws {
        var b = PageTableBuilder()
        _ = b.drainDirtyTables()
        try b.map(va: 0x1_0000_0000, pa: 0x4100_0000, size: 0x4000, attributes: el0Data)
        // Root (new L2 entry), the new L2, and the new L3.
        #expect(b.drainDirtyTables().map(\.gpa) == [0x4020_0000, 0x4020_4000, 0x4020_8000])
        // A second page under the same L3 table dirties only that table.
        try b.map(va: 0x1_0000_4000, pa: 0x4100_4000, size: 0x4000, attributes: el0Data)
        let d = b.drainDirtyTables()
        #expect(d.map(\.gpa) == [0x4020_8000])
        #expect(d[0].bytes == b.tables[2].bytes)
        // A failed map leaves the dirty set unchanged.
        #expect(throws: PageTableError.alreadyMapped(va: 0x1_0000_4000)) {
            try b.map(va: 0x1_0000_4000, pa: 0x4100_4000, size: 0x4000, attributes: el0Data)
        }
        #expect(!b.hasDirtyTables)
    }

    @Test func unmapClearsEntries() throws {
        var b = PageTableBuilder()
        try b.map(va: 0x1_0000_0000, pa: 0x4100_0000, size: 0xC000, attributes: el0Data)
        _ = b.drainDirtyTables()
        #expect(try b.unmap(va: 0x1_0000_4000, size: 0x4000) == 1)
        #expect(b.translate(0x1_0000_0000)?.pa == 0x4100_0000)
        #expect(b.translate(0x1_0000_4000) == nil)
        #expect(b.translate(0x1_0000_8000)?.pa == 0x4100_8000)
        #expect(b.drainDirtyTables().map(\.gpa) == [0x4020_8000])
        // Unmapping holes and unallocated table ranges is a no-op.
        #expect(try b.unmap(va: 0x1_0000_4000, size: 0x4000) == 0)
        #expect(try b.unmap(va: 0x5_0000_0000, size: 0x1_0000_0000) == 0)
        #expect(!b.hasDirtyTables)
        // A page can be mapped again after an unmap, at a different PA.
        try b.map(va: 0x1_0000_4000, pa: 0x4200_0000, size: 0x4000, attributes: el0RO)
        #expect(b.translate(0x1_0000_4008)?.pa == 0x4200_0008)
        #expect(throws: PageTableError.unaligned(va: 0x1_0000_0001, pa: 0, size: 0x4000)) {
            try b.unmap(va: 0x1_0000_0001, size: 0x4000)
        }
        #expect(throws: PageTableError.emptyRange(va: 0x1_0000_0000)) { try b.unmap(va: 0x1_0000_0000, size: 0) }
        // Across an L3 boundary (32 MiB).
        try b.map(va: 0x1_01FF_C000, pa: 0x4300_0000, size: 0x8000, attributes: el0Data)
        #expect(try b.unmap(va: 0x1_01FF_C000, size: 0x8000) == 2)
        #expect(b.translate(0x1_01FF_C000) == nil && b.translate(0x1_0200_0000) == nil)
    }

    @Test func protectRewritesAttributes() throws {
        var b = PageTableBuilder()
        try b.map(va: 0x1_0000_0000, pa: 0x4100_0000, size: 0x8000, attributes: el0Data)
        _ = b.drainDirtyTables()
        try b.protect(va: 0x1_0000_4000, size: 0x4000, attributes: el0Code)
        #expect(b.translate(0x1_0000_0000)?.attributes == el0Data)
        #expect(b.translate(0x1_0000_4000)?.attributes == el0Code)
        #expect(b.translate(0x1_0000_4000)?.pa == 0x4100_4000)
        #expect(b.drainDirtyTables().count == 1)
        // Same attributes: nothing dirty.
        try b.protect(va: 0x1_0000_4000, size: 0x4000, attributes: el0Code)
        #expect(!b.hasDirtyTables)
        // A hole anywhere in the range: error, no change.
        #expect(throws: PageTableError.notMapped(va: 0x1_0000_8000)) {
            try b.protect(va: 0x1_0000_0000, size: 0xC000, attributes: el0RO)
        }
        #expect(b.translate(0x1_0000_0000)?.attributes == el0Data)
        #expect(!b.hasDirtyTables)
    }
}
