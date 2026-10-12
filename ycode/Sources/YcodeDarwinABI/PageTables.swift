/// Permissions and memory type of a stage-1 leaf mapping.
/// See `specs/simulator/vm-shim-protocol.md` §3.
public struct PageAttributes: Equatable, Hashable, Sendable, CustomStringConvertible {
    /// The data access permission, AP[2:1] in the leaf descriptor.
    public enum Access: Equatable, Hashable, Sendable, CaseIterable {
        /// AP `00`: EL1 read/write, no EL0 access.
        case el1ReadWrite
        /// AP `10`: EL1 read-only, no EL0 access.
        case el1ReadOnly
        /// AP `01`: EL1 and EL0 read/write.
        case el0ReadWrite
        /// AP `11`: EL1 and EL0 read-only.
        case el0ReadOnly

        /// The AP[2:1] field value.
        public var apBits: UInt64 {
            switch self {
            case .el1ReadWrite: 0b00
            case .el0ReadWrite: 0b01
            case .el1ReadOnly: 0b10
            case .el0ReadOnly: 0b11
            }
        }

        public init(apBits: UInt64) {
            switch apBits & 3 {
            case 0b00: self = .el1ReadWrite
            case 0b01: self = .el0ReadWrite
            case 0b10: self = .el1ReadOnly
            default: self = .el0ReadOnly
            }
        }

        public var isEL0Readable: Bool { self == .el0ReadWrite || self == .el0ReadOnly }
        public var isEL0Writable: Bool { self == .el0ReadWrite }
    }

    public var access: Access
    /// MAIR Attr1 (Device-nGnRnE) when true, Attr0 (Normal write-back) otherwise.
    public var device: Bool
    /// False sets UXN.
    public var el0Execute: Bool
    /// False sets PXN.
    public var el1Execute: Bool

    public init(access: Access, device: Bool = false, el0Execute: Bool = false, el1Execute: Bool = false) {
        self.access = access
        self.device = device
        self.el0Execute = el0Execute
        self.el1Execute = el1Execute
    }

    /// The attribute bits of a valid leaf descriptor: AttrIndx, AP, SH = inner
    /// shareable, AF, PXN, and UXN (the output address and type bits excluded).
    public var leafDescriptorBits: UInt64 {
        typealias D = AArch64.Descriptor
        var bits = D.attrIndx(device ? AArch64.MAIR.deviceIndex : AArch64.MAIR.normalIndex)
            | D.ap(access.apBits)
            | D.sh(AArch64.TCR.shareabilityInner)
            | D.af
        if !el1Execute { bits |= D.pxn }
        if !el0Execute { bits |= D.uxn }
        return bits
    }

    /// Decodes the attributes of a leaf descriptor.
    public init(leafDescriptor d: UInt64) {
        access = Access(apBits: (d >> 6) & 3)
        device = (d >> 2) & 7 == AArch64.MAIR.deviceIndex
        el0Execute = d & AArch64.Descriptor.uxn == 0
        el1Execute = d & AArch64.Descriptor.pxn == 0
    }

    public var description: String {
        let a = switch access {
        case .el1ReadWrite: "el1-rw"
        case .el1ReadOnly: "el1-ro"
        case .el0ReadWrite: "el0-rw"
        case .el0ReadOnly: "el0-ro"
        }
        var parts = [a]
        if device { parts.append("device") }
        if el1Execute { parts.append("el1-x") }
        if el0Execute { parts.append("el0-x") }
        return parts.joined(separator: ",")
    }
}

public enum PageTableError: Error, Equatable, Sendable, CustomStringConvertible {
    /// `va`, `pa`, or `size` is not a multiple of 16 KiB.
    case unaligned(va: UInt64, pa: UInt64, size: UInt64)
    /// `size` is zero.
    case emptyRange(va: UInt64)
    /// The virtual range goes past the 47-bit TTBR0 range.
    case virtualAddressOutOfRange(va: UInt64, size: UInt64)
    /// The physical range goes past the 40-bit output address range.
    case physicalAddressOutOfRange(pa: UInt64, size: UInt64)
    /// A page of the range is already mapped.
    case alreadyMapped(va: UInt64)
    /// The table arena has no room for another table.
    case arenaExhausted(capacity: Int)

    public var description: String {
        switch self {
        case let .unaligned(va, pa, size):
            "mapping va \(hex(va)) pa \(hex(pa)) size \(hex(size)) is not 16 KiB-aligned"
        case let .emptyRange(va): "mapping at va \(hex(va)) has size 0"
        case let .virtualAddressOutOfRange(va, size): "va range \(hex(va))+\(hex(size)) is outside the 47-bit address space"
        case let .physicalAddressOutOfRange(pa, size): "pa range \(hex(pa))+\(hex(size)) is outside the 40-bit address space"
        case let .alreadyMapped(va): "va \(hex(va)) is already mapped"
        case let .arenaExhausted(capacity): "the page table arena is full (\(capacity) tables)"
        }
    }
}

/// Builds the stage-1 TTBR0 tables of §3: 16 KiB granule, T0SZ = 17, a
/// three-level walk (L1 = VA[46:36], L2 = VA[35:25], L3 = VA[24:14]) that
/// ends in 16 KiB page descriptors. Tables are bump-allocated from an arena
/// of guest RAM; the first one is the L1 (root) table.
public struct PageTableBuilder: Sendable {
    public let tableArenaGPA: UInt64
    public let tableArenaSize: Int

    /// `tablePages[i]` is the table at `tableArenaGPA + i × 16 KiB`.
    private var tablePages: [[UInt64]]

    /// The arena must be 16 KiB-aligned and hold at least one table.
    public init(tableArenaGPA: UInt64, tableArenaSize: Int) {
        precondition(VMLayout.isPageAligned(tableArenaGPA), "table arena GPA must be 16 KiB-aligned")
        precondition(tableArenaSize >= Int(VMLayout.pageSize), "table arena must hold at least one table")
        self.tableArenaGPA = tableArenaGPA
        self.tableArenaSize = tableArenaSize
        tablePages = [Self.emptyTable]
    }

    /// The arena of §2 (`0x4020_0000`, 8 MiB).
    public init() {
        self.init(tableArenaGPA: VMLayout.pageTableArenaGPA, tableArenaSize: Int(VMLayout.pageTableArenaSize))
    }

    private static let emptyTable = [UInt64](repeating: 0, count: VMLayout.entriesPerTable)

    /// The L1 table's GPA (the value for `TTBR0_EL1`).
    public var rootGPA: UInt64 { tableArenaGPA }

    /// How many tables fit in the arena.
    public var capacity: Int { tableArenaSize / Int(VMLayout.pageSize) }

    /// How many tables have been allocated (including the root).
    public var tableCount: Int { tablePages.count }

    // MARK: Descriptor and index helpers

    /// The table index used at `level` (1, 2, or 3) for `va`.
    public static func index(of va: UInt64, level: Int) -> Int {
        precondition((1...3).contains(level), "the walk has levels 1 to 3")
        let shift = VMLayout.pageShift + UInt64(3 - level) * 11
        return Int((va >> shift) & 0x7FF)
    }

    /// A level-1 or level-2 descriptor pointing at the next-level table.
    public static func tableDescriptor(nextTableGPA: UInt64) -> UInt64 {
        (nextTableGPA & AArch64.Descriptor.outputAddressMask) | AArch64.Descriptor.validTableOrPage
    }

    /// A level-3 page descriptor mapping the 16 KiB page at `pa`.
    public static func pageDescriptor(pa: UInt64, attributes: PageAttributes) -> UInt64 {
        (pa & AArch64.Descriptor.outputAddressMask) | attributes.leafDescriptorBits | AArch64.Descriptor.validTableOrPage
    }

    // MARK: Mapping

    /// Maps [va, va+size) to [pa, pa+size), 16 KiB-aligned, with the given
    /// attributes. Either the whole range is mapped or, on error, nothing
    /// changes.
    public mutating func map(va: UInt64, pa: UInt64, size: UInt64, attributes: PageAttributes) throws {
        let page = VMLayout.pageSize
        guard VMLayout.isPageAligned(va), VMLayout.isPageAligned(pa), VMLayout.isPageAligned(size) else {
            throw PageTableError.unaligned(va: va, pa: pa, size: size)
        }
        guard size > 0 else { throw PageTableError.emptyRange(va: va) }
        let vaLimit: UInt64 = 1 << VMLayout.virtualAddressBits
        guard va < vaLimit, size <= vaLimit - va else {
            throw PageTableError.virtualAddressOutOfRange(va: va, size: size)
        }
        let paLimit: UInt64 = 1 << VMLayout.physicalAddressBits
        guard pa < paLimit, size <= paLimit - pa else {
            throw PageTableError.physicalAddressOutOfRange(pa: pa, size: size)
        }

        var work = self
        var offset: UInt64 = 0
        while offset < size {
            try work.mapPage(va: va + offset, pa: pa + offset, attributes: attributes)
            offset += page
        }
        self = work
    }

    /// Identity-maps (VA = PA) a layout region.
    public mutating func mapIdentity(_ region: VMLayout.Region) throws {
        try map(va: region.va, pa: region.va, size: region.size, attributes: region.attributes)
    }

    private mutating func mapPage(va: UInt64, pa: UInt64, attributes: PageAttributes) throws {
        let l2 = try nextTable(in: 0, index: Self.index(of: va, level: 1))
        let l3 = try nextTable(in: l2, index: Self.index(of: va, level: 2))
        let i3 = Self.index(of: va, level: 3)
        guard tablePages[l3][i3] & AArch64.Descriptor.typeMask == 0 else {
            throw PageTableError.alreadyMapped(va: va)
        }
        tablePages[l3][i3] = Self.pageDescriptor(pa: pa, attributes: attributes)
    }

    /// The arena slot of the table that entry `index` of table `table` points
    /// at, allocating it if the entry is empty.
    private mutating func nextTable(in table: Int, index: Int) throws -> Int {
        let d = tablePages[table][index]
        if d & AArch64.Descriptor.typeMask == AArch64.Descriptor.validTableOrPage {
            return slot(ofTableAt: d & AArch64.Descriptor.outputAddressMask)!
        }
        guard tablePages.count < capacity else { throw PageTableError.arenaExhausted(capacity: capacity) }
        let newSlot = tablePages.count
        tablePages.append(Self.emptyTable)
        tablePages[table][index] = Self.tableDescriptor(nextTableGPA: gpa(ofSlot: newSlot))
        return newSlot
    }

    private func gpa(ofSlot slot: Int) -> UInt64 { tableArenaGPA + UInt64(slot) * VMLayout.pageSize }

    private func slot(ofTableAt gpa: UInt64) -> Int? {
        guard gpa >= tableArenaGPA else { return nil }
        let slot = Int((gpa - tableArenaGPA) / VMLayout.pageSize)
        return slot < tablePages.count ? slot : nil
    }

    // MARK: Output

    /// Every table page to copy into guest RAM: (gpa, 16 KiB of little-endian
    /// descriptors), in allocation order, starting with the root.
    public var tables: [(gpa: UInt64, bytes: [UInt8])] {
        tablePages.enumerated().map { slot, entries in
            var bytes: [UInt8] = []
            bytes.reserveCapacity(Int(VMLayout.pageSize))
            for e in entries { appendLE(e, to: &bytes) }
            return (gpa(ofSlot: slot), bytes)
        }
    }

    /// The raw descriptor at `index` of the table at `tableGPA`, if that table exists.
    public func descriptor(tableGPA: UInt64, index: Int) -> UInt64? {
        guard let slot = slot(ofTableAt: tableGPA), (0..<VMLayout.entriesPerTable).contains(index) else { return nil }
        return tablePages[slot][index]
    }

    /// Translates a VA through the built tables (for VMM-side copies). The
    /// result keeps the offset within the page. nil if unmapped.
    public func translate(_ va: UInt64) -> (pa: UInt64, attributes: PageAttributes)? {
        guard va < 1 << VMLayout.virtualAddressBits else { return nil }
        var table = 0
        for level in 1...2 {
            let d = tablePages[table][Self.index(of: va, level: level)]
            guard d & AArch64.Descriptor.typeMask == AArch64.Descriptor.validTableOrPage,
                  let next = slot(ofTableAt: d & AArch64.Descriptor.outputAddressMask) else { return nil }
            table = next
        }
        let d = tablePages[table][Self.index(of: va, level: 3)]
        guard d & AArch64.Descriptor.typeMask == AArch64.Descriptor.validTableOrPage else { return nil }
        let pa = (d & AArch64.Descriptor.outputAddressMask) | (va & (VMLayout.pageSize - 1))
        return (pa, PageAttributes(leafDescriptor: d))
    }
}
