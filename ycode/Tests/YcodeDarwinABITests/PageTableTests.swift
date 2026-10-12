import Testing
@testable import YcodeDarwinABI

private let el1Data = PageAttributes(access: .el1ReadWrite)
private let el1Code = PageAttributes(access: .el1ReadWrite, el1Execute: true)
private let device = PageAttributes(access: .el1ReadWrite, device: true)
private let el0Code = PageAttributes(access: .el0ReadOnly, el0Execute: true)
private let el0Data = PageAttributes(access: .el0ReadWrite)
private let el0RO = PageAttributes(access: .el0ReadOnly)

@Suite struct DescriptorTests {
    // Leaf bits by hand: AttrIndx[4:2], AP[7:6], SH[9:8]=11 (0x300), AF bit 10
    // (0x400), PXN bit 53 (0x0020_0000_0000_0000), UXN bit 54
    // (0x0040_0000_0000_0000), type bits[1:0]=11.

    @Test func el1DataPage() {
        // AP 00, AttrIndx 0, PXN and UXN.
        #expect(PageTableBuilder.pageDescriptor(pa: 0x4010_0000, attributes: el1Data) == 0x0060_0000_4010_0703)
    }

    @Test func el1CodePage() {
        // PXN clear, UXN set.
        #expect(PageTableBuilder.pageDescriptor(pa: 0x4000_0000, attributes: el1Code) == 0x0040_0000_4000_0703)
    }

    @Test func devicePage() {
        // AttrIndx 1 → bit 2.
        #expect(PageTableBuilder.pageDescriptor(pa: 0x0900_0000, attributes: device) == 0x0060_0000_0900_0707)
    }

    @Test func el0Pages() {
        // AP 11 → 0xC0; PXN set, UXN clear.
        #expect(PageTableBuilder.pageDescriptor(pa: 0x4100_0000, attributes: el0Code) == 0x0020_0000_4100_07C3)
        // AP 01 → 0x40; both XN.
        #expect(PageTableBuilder.pageDescriptor(pa: 0x4100_4000, attributes: el0Data) == 0x0060_0000_4100_4743)
        // AP 11, both XN.
        #expect(PageTableBuilder.pageDescriptor(pa: 0x4100_8000, attributes: el0RO) == 0x0060_0000_4100_87C3)
    }

    @Test func el1ReadOnlyPage() {
        // AP 10 → 0x80.
        let ro = PageAttributes(access: .el1ReadOnly)
        #expect(PageTableBuilder.pageDescriptor(pa: 0x4000_4000, attributes: ro) == 0x0060_0000_4000_4783)
    }

    @Test func apEncodings() {
        #expect(PageAttributes.Access.el1ReadWrite.apBits == 0b00)
        #expect(PageAttributes.Access.el0ReadWrite.apBits == 0b01)
        #expect(PageAttributes.Access.el1ReadOnly.apBits == 0b10)
        #expect(PageAttributes.Access.el0ReadOnly.apBits == 0b11)
        for a in PageAttributes.Access.allCases { #expect(PageAttributes.Access(apBits: a.apBits) == a) }
    }

    @Test func tableDescriptor() {
        // Address bits [47:14] plus bits[1:0] = 11; no attribute bits.
        #expect(PageTableBuilder.tableDescriptor(nextTableGPA: 0x4020_4000) == 0x4020_4003)
        #expect(PageTableBuilder.tableDescriptor(nextTableGPA: 0xFF_FFFF_C000) == 0xFF_FFFF_C003)
    }

    @Test func attributesRoundTrip() {
        for access in PageAttributes.Access.allCases {
            for dev in [false, true] {
                for x0 in [false, true] {
                    for x1 in [false, true] {
                        let a = PageAttributes(access: access, device: dev, el0Execute: x0, el1Execute: x1)
                        let d = PageTableBuilder.pageDescriptor(pa: 0x1234_4000, attributes: a)
                        #expect(PageAttributes(leafDescriptor: d) == a)
                        #expect(d & 0x0000_FFFF_FFFF_C000 == 0x1234_4000)
                        #expect(d & 0x400 != 0)
                        #expect(d & 0x300 == 0x300)
                        #expect(d & 3 == 3)
                    }
                }
            }
        }
    }

    @Test(arguments: [
        (UInt64(0x1_0000_0000), 0, 128, 0),
        (0x1_0000_4000, 0, 128, 1),
        (0xF_FFFF_C000, 0, 2047, 2047),
        (0x0900_0000, 0, 4, 1024),
        (0x4000_0000, 0, 32, 0),
        (0x1_6FFF_C000, 0, 183, 2047),
        (0x10_0000_0000, 1, 0, 0),
        (0x7FFF_FFFF_C000, 2047, 2047, 2047),
        (0, 0, 0, 0),
    ])
    func indices(va: UInt64, l1: Int, l2: Int, l3: Int) {
        #expect(PageTableBuilder.index(of: va, level: 1) == l1)
        #expect(PageTableBuilder.index(of: va, level: 2) == l2)
        #expect(PageTableBuilder.index(of: va, level: 3) == l3)
    }
}

@Suite struct PageTableBuilderTests {
    @Test func freshBuilder() {
        let b = PageTableBuilder()
        #expect(b.rootGPA == 0x4020_0000)
        #expect(b.capacity == 512)
        #expect(b.tableCount == 1)
        #expect(b.tables.count == 1)
        #expect(b.tables[0].gpa == 0x4020_0000)
        #expect(b.tables[0].bytes == [UInt8](repeating: 0, count: 16384))
        #expect(b.translate(0x4000_0000) == nil)
    }

    @Test func tableChainAndBytes() throws {
        var b = PageTableBuilder()
        try b.map(va: 0x0900_0000, pa: 0x0900_0000, size: 0x4000, attributes: device)
        #expect(b.tableCount == 3)
        // Root[0] → L2 at slot 1; L2[4] → L3 at slot 2; L3[1024] → the page.
        #expect(b.descriptor(tableGPA: 0x4020_0000, index: 0) == 0x4020_4003)
        #expect(b.descriptor(tableGPA: 0x4020_4000, index: 4) == 0x4020_8003)
        #expect(b.descriptor(tableGPA: 0x4020_8000, index: 1024) == 0x0060_0000_0900_0707)
        let t = b.tables
        #expect(t.map(\.gpa) == [0x4020_0000, 0x4020_4000, 0x4020_8000])
        #expect(t.allSatisfy { $0.bytes.count == 16384 })
        // Little-endian bytes of root entry 0 and of L3 entry 1024.
        #expect(Array(t[0].bytes[0..<8]) == [0x03, 0x40, 0x20, 0x40, 0, 0, 0, 0])
        #expect(Array(t[2].bytes[(1024 * 8)..<(1024 * 8 + 8)]) == [0x07, 0x07, 0x00, 0x09, 0, 0, 0x60, 0])
        // Every other byte is zero.
        #expect(t[0].bytes[8...].allSatisfy { $0 == 0 })
        #expect(t[1].bytes.enumerated().allSatisfy { i, v in (32..<40).contains(i) || v == 0 })
    }

    @Test func tablesAreShared() throws {
        var b = PageTableBuilder()
        // Two pages under the same L3 table, then one in a new L2 slot.
        try b.map(va: 0x1_0000_0000, pa: 0x4100_0000, size: 0x8000, attributes: el0Data)
        #expect(b.tableCount == 3)
        try b.map(va: 0x1_0200_0000, pa: 0x4100_8000, size: 0x4000, attributes: el0Data)
        #expect(b.tableCount == 4)
        try b.map(va: 0x10_0000_0000, pa: 0x4100_C000, size: 0x4000, attributes: el0Data)
        #expect(b.tableCount == 6)
    }

    @Test func translateRoundTrips() throws {
        var b = PageTableBuilder()
        for r in VMLayout.el1Regions { try b.mapIdentity(r) }
        var pool = VMLayout.el0PoolGPA
        var placed: [(VMLayout.Region, UInt64)] = []
        for r in VMLayout.selfTestRegions(imageSize: 0x5000) {
            try b.map(va: r.va, pa: pool, size: r.size, attributes: r.attributes)
            placed.append((r, pool))
            pool += r.size
        }

        for r in VMLayout.el1Regions {
            for off: UInt64 in [0, 8, 0x3FFF, r.size - 1] {
                let t = try #require(b.translate(r.va + off))
                #expect(t.pa == r.va + off)
                #expect(t.attributes == r.attributes)
            }
        }
        for (r, pa) in placed {
            for off: UInt64 in [0, 0x123, r.size - 8] {
                let t = try #require(b.translate(r.va + off))
                #expect(t.pa == pa + off)
                #expect(t.attributes == r.attributes)
            }
        }
        #expect(b.translate(0x1_0000_0000)?.pa == 0x4100_0000)
        #expect(b.translate(0x1_0000_4000)?.pa == 0x4100_4000)
        #expect(b.translate(0x1_6FFF_FFF8)?.pa == 0x4101_7FF8)
        #expect(b.translate(0xF_FFFF_C000)?.pa == 0x4101_8000)

        // Unmapped addresses.
        for va: UInt64 in [0, 0x0900_4000, 0x4012_0000, 0x1_0000_8000, 0x1_6FFE_C000, 0xF_FFFF_8000, 1 << 47, UInt64.max] {
            #expect(b.translate(va) == nil, "\(hex(va))")
        }
    }

    @Test func rejectsUnaligned() {
        var b = PageTableBuilder()
        #expect(throws: PageTableError.unaligned(va: 0x1_0000_0001, pa: 0x4100_0000, size: 0x4000)) {
            try b.map(va: 0x1_0000_0001, pa: 0x4100_0000, size: 0x4000, attributes: el0Data)
        }
        #expect(throws: PageTableError.unaligned(va: 0x1_0000_0000, pa: 0x4100_1000, size: 0x4000)) {
            try b.map(va: 0x1_0000_0000, pa: 0x4100_1000, size: 0x4000, attributes: el0Data)
        }
        #expect(throws: PageTableError.unaligned(va: 0x1_0000_0000, pa: 0x4100_0000, size: 0x1000)) {
            try b.map(va: 0x1_0000_0000, pa: 0x4100_0000, size: 0x1000, attributes: el0Data)
        }
        #expect(throws: PageTableError.emptyRange(va: 0x1_0000_0000)) {
            try b.map(va: 0x1_0000_0000, pa: 0x4100_0000, size: 0, attributes: el0Data)
        }
        #expect(b.tableCount == 1)
    }

    @Test func rejectsOutOfRange() {
        var b = PageTableBuilder()
        #expect(throws: PageTableError.virtualAddressOutOfRange(va: 1 << 47, size: 0x4000)) {
            try b.map(va: 1 << 47, pa: 0x4100_0000, size: 0x4000, attributes: el0Data)
        }
        #expect(throws: PageTableError.virtualAddressOutOfRange(va: (1 << 47) - 0x4000, size: 0x8000)) {
            try b.map(va: (1 << 47) - 0x4000, pa: 0x4100_0000, size: 0x8000, attributes: el0Data)
        }
        #expect(throws: PageTableError.physicalAddressOutOfRange(pa: 1 << 40, size: 0x4000)) {
            try b.map(va: 0x1_0000_0000, pa: 1 << 40, size: 0x4000, attributes: el0Data)
        }
        // The very last page of the VA space is fine.
        #expect(throws: Never.self) {
            try b.map(va: (1 << 47) - 0x4000, pa: 0x4100_0000, size: 0x4000, attributes: el0Data)
        }
        #expect(b.translate((1 << 47) - 1)?.pa == 0x4100_3FFF)
    }

    @Test func rejectsOverlapAtomically() throws {
        var b = PageTableBuilder()
        try b.map(va: 0x1_0000_8000, pa: 0x4100_0000, size: 0x4000, attributes: el0Data)
        let before = b.tables.map(\.bytes)
        // The new range's third page collides; nothing from it may stay mapped.
        #expect(throws: PageTableError.alreadyMapped(va: 0x1_0000_8000)) {
            try b.map(va: 0x1_0000_0000, pa: 0x4200_0000, size: 0xC000, attributes: el0Code)
        }
        #expect(b.translate(0x1_0000_0000) == nil)
        #expect(b.translate(0x1_0000_4000) == nil)
        #expect(b.tables.map(\.bytes) == before)
        // Identical remaps are rejected too.
        #expect(throws: PageTableError.alreadyMapped(va: 0x1_0000_8000)) {
            try b.map(va: 0x1_0000_8000, pa: 0x4100_0000, size: 0x4000, attributes: el0Data)
        }
        // A failed map that would allocate tables leaves the count unchanged.
        try b.map(va: 0x20_0000_0000, pa: 0x4300_0000, size: 0x4000, attributes: el0Data)
        let count = b.tableCount
        #expect(throws: PageTableError.alreadyMapped(va: 0x20_0000_0000)) {
            try b.map(va: 0x1F_FFFF_C000, pa: 0x4400_0000, size: 0x8000, attributes: el0Data)
        }
        #expect(b.tableCount == count)
        #expect(b.translate(0x1F_FFFF_C000) == nil)
    }

    @Test func arenaExhaustion() throws {
        var tiny = PageTableBuilder(tableArenaGPA: 0x4020_0000, tableArenaSize: 0x8000)
        #expect(tiny.capacity == 2)
        #expect(throws: PageTableError.arenaExhausted(capacity: 2)) {
            try tiny.map(va: 0, pa: 0x4100_0000, size: 0x4000, attributes: el0Data)
        }
        #expect(tiny.tableCount == 1)

        var three = PageTableBuilder(tableArenaGPA: 0x4100_0000, tableArenaSize: 0xC000)
        try three.map(va: 0, pa: 0x4100_0000, size: 0x4000, attributes: el0Data)
        #expect(three.rootGPA == 0x4100_0000)
        #expect(three.tables.map(\.gpa) == [0x4100_0000, 0x4100_4000, 0x4100_8000])
        // Same L3 table: fine. New L3 table: no room.
        try three.map(va: 0x4000, pa: 0x4100_4000, size: 0x4000, attributes: el0Data)
        #expect(throws: PageTableError.arenaExhausted(capacity: 3)) {
            try three.map(va: 0x200_0000, pa: 0x4100_8000, size: 0x4000, attributes: el0Data)
        }
        #expect(three.translate(0x200_0000) == nil)
    }

    @Test func fullLayoutFitsInArena() throws {
        var b = PageTableBuilder()
        for r in VMLayout.el1Regions { try b.mapIdentity(r) }
        var pool = VMLayout.el0PoolGPA
        for r in VMLayout.selfTestRegions(imageSize: 0x8000) {
            try b.map(va: r.va, pa: pool, size: r.size, attributes: r.attributes)
            pool += r.size
        }
        // L1 + L2(0) + L3 for: doorbell, shim/data, tables ×4, image, stack, commpage.
        #expect(b.tableCount <= 16)
        #expect(b.tables.allSatisfy { $0.gpa >= 0x4020_0000 && $0.gpa + 0x4000 <= 0x40A0_0000 })
    }
}

@Suite struct TranslatingGuestMemoryTests {
    final class RAM {
        var bytes = [UInt8](repeating: 0, count: 0x10000)
        let base: UInt64 = 0x4100_0000
    }

    func make() throws -> (TranslatingGuestMemory, RAM) {
        let ram = RAM()
        var b = PageTableBuilder()
        // Two virtually contiguous pages backed by physically swapped pages.
        try b.map(va: 0x1_0000_0000, pa: 0x4100_4000, size: 0x4000, attributes: el0Data)
        try b.map(va: 0x1_0000_4000, pa: 0x4100_0000, size: 0x4000, attributes: el0Data)
        try b.map(va: 0x1_0000_8000, pa: 0x4100_8000, size: 0x4000, attributes: el0RO)
        try b.map(va: 0x4000_0000, pa: 0x4100_C000, size: 0x4000, attributes: el1Data)
        let mem = TranslatingGuestMemory(
            pageTables: b,
            readPhysical: { pa, n in Array(ram.bytes[Int(pa - ram.base)..<Int(pa - ram.base) + n]) },
            writePhysical: { pa, bytes in
                let o = Int(pa - ram.base)
                ram.bytes.replaceSubrange(o..<(o + bytes.count), with: bytes)
            })
        return (mem, ram)
    }

    @Test func crossPageReadWrite() throws {
        let (mem, ram) = try make()
        try mem.write(va: 0x1_0000_3FFE, bytes: [1, 2, 3, 4])
        #expect(Array(ram.bytes[0x7FFE..<0x8000]) == [1, 2])
        #expect(Array(ram.bytes[0..<2]) == [3, 4])
        #expect(try mem.read(va: 0x1_0000_3FFE, count: 4) == [1, 2, 3, 4])
        #expect(try mem.read(va: 0x1_0000_0000, count: 0) == [])
    }

    @Test func permissions() throws {
        let (mem, _) = try make()
        #expect(try mem.read(va: 0x1_0000_8000, count: 4) == [0, 0, 0, 0])
        #expect(throws: GuestMemoryError.accessDenied(va: 0x1_0000_8000)) {
            try mem.write(va: 0x1_0000_8000, bytes: [1])
        }
        #expect(throws: GuestMemoryError.accessDenied(va: 0x4000_0000)) {
            _ = try mem.read(va: 0x4000_0000, count: 1)
        }
        #expect(throws: GuestMemoryError.unmapped(va: 0x1_0000_C000)) {
            _ = try mem.read(va: 0x1_0000_BFFF, count: 2)
        }
        var el1 = mem
        el1.requireEL0Access = false
        #expect(try el1.read(va: 0x4000_0000, count: 1) == [0])
    }
}
