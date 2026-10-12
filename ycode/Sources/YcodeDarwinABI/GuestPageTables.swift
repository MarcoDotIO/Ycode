// The stage-1 TTBR0 tables of a `GuestAddressSpace`: the format of
// `PageTableBuilder` (vm-shim-protocol.md §3, stage3-contract.md §3: 16 KiB
// granule, three levels, the root at the arena base, further tables
// bump-allocated from the arena), kept as flat host-endian descriptor arrays
// and changed in place. Changed tables are tracked and written to guest RAM
// table by table. A range operation costs O(pages + tables touched), with no
// copy of untouched tables.

public final class GuestPageTables {
    public let tableArenaGPA: UInt64
    public let tableArenaSize: Int
    /// How many tables fit in the arena.
    public let capacity: Int
    /// Tables allocated so far (the root included); they occupy arena slots 0..<tableCount.
    public private(set) var tableCount: Int

    private static let entries = VMLayout.entriesPerTable
    private static let page = VMLayout.pageSize
    /// The VA span of one L3 table (32 MiB).
    private static let l3Span = page * UInt64(entries)
    private static let valid = AArch64.Descriptor.validTableOrPage
    private static let typeMask = AArch64.Descriptor.typeMask
    private static let oaMask = AArch64.Descriptor.outputAddressMask

    private var storage: UnsafeMutablePointer<UInt64>
    private var allocatedTables: Int
    private var dirtyFlags: [Bool]
    private var dirtyList: [Int] = []

    /// An empty root table (dirty until the first flush).
    public init(tableArenaGPA: UInt64, tableArenaSize: Int) {
        precondition(VMLayout.isPageAligned(tableArenaGPA), "table arena GPA must be 16 KiB-aligned")
        precondition(tableArenaSize >= Int(VMLayout.pageSize), "table arena must hold at least one table")
        self.tableArenaGPA = tableArenaGPA
        self.tableArenaSize = tableArenaSize
        capacity = tableArenaSize / Int(VMLayout.pageSize)
        allocatedTables = min(capacity, 16)
        storage = .allocate(capacity: allocatedTables * Self.entries)
        storage.initialize(repeating: 0, count: allocatedTables * Self.entries)
        dirtyFlags = [Bool](repeating: false, count: allocatedTables)
        tableCount = 1
        markDirty(0)
    }

    /// The tables of `builder`, every one of them dirty.
    public convenience init(_ builder: PageTableBuilder) {
        self.init(tableArenaGPA: builder.tableArenaGPA, tableArenaSize: builder.tableArenaSize)
        let tables = builder.tables
        precondition(tables.count <= capacity)
        reserve(tables.count)
        for (slot, t) in tables.enumerated() {
            precondition(t.gpa == gpa(ofSlot: slot) && t.bytes.count == Int(VMLayout.pageSize))
            t.bytes.withUnsafeBytes { raw in
                let base = table(slot)
                for i in 0..<Self.entries { base[i] = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)) }
            }
            markDirty(slot)
        }
        tableCount = max(1, tables.count)
    }

    deinit { storage.deallocate() }

    /// The L1 table's GPA (the value for `TTBR0_EL1`).
    public var rootGPA: UInt64 { tableArenaGPA }

    // MARK: Slots

    private func gpa(ofSlot slot: Int) -> UInt64 { tableArenaGPA + UInt64(slot) * Self.page }

    private func slot(ofTableAt gpa: UInt64) -> Int? {
        guard gpa >= tableArenaGPA else { return nil }
        let slot = Int((gpa - tableArenaGPA) / Self.page)
        return slot < tableCount ? slot : nil
    }

    @inline(__always) private func table(_ slot: Int) -> UnsafeMutablePointer<UInt64> { storage + slot * Self.entries }

    private func reserve(_ tables: Int) {
        guard tables > allocatedTables else { return }
        let newCount = min(capacity, max(tables, allocatedTables * 2))
        let fresh = UnsafeMutablePointer<UInt64>.allocate(capacity: newCount * Self.entries)
        fresh.moveInitialize(from: storage, count: allocatedTables * Self.entries)
        (fresh + allocatedTables * Self.entries).initialize(repeating: 0, count: (newCount - allocatedTables) * Self.entries)
        storage.deallocate()
        storage = fresh
        dirtyFlags += [Bool](repeating: false, count: newCount - allocatedTables)
        allocatedTables = newCount
    }

    private func markDirty(_ slot: Int) {
        if !dirtyFlags[slot] {
            dirtyFlags[slot] = true
            dirtyList.append(slot)
        }
    }

    private static func index(_ va: UInt64, level: Int) -> Int {
        Int((va >> (VMLayout.pageShift + UInt64(3 - level) * 11)) & 0x7FF)
    }

    /// The next-level table that entry `index` of `slot` points at, if any.
    private func next(_ slot: Int, _ index: Int) -> Int? {
        let d = table(slot)[index]
        guard d & Self.typeMask == Self.valid else { return nil }
        return self.slot(ofTableAt: d & Self.oaMask)
    }

    /// The L3 table slot for `va`, allocating the L2 and L3 tables if needed.
    private func l3(for va: UInt64) -> Int {
        let l2 = nextOrAllocate(0, Self.index(va, level: 1))
        return nextOrAllocate(l2, Self.index(va, level: 2))
    }

    private func nextOrAllocate(_ slot: Int, _ index: Int) -> Int {
        if let s = next(slot, index) { return s }
        precondition(tableCount < capacity, "GuestPageTables: arena exhausted after the capacity check")
        reserve(tableCount + 1)
        let s = tableCount
        tableCount += 1
        table(slot)[index] = PageTableBuilder.tableDescriptor(nextTableGPA: gpa(ofSlot: s))
        markDirty(slot)
        markDirty(s)
        return s
    }

    /// The L3 slot covering `va`, without allocating.
    private func existingL3(for va: UInt64) -> Int? {
        guard let l2 = next(0, Self.index(va, level: 1)) else { return nil }
        return next(l2, Self.index(va, level: 2))
    }

    // MARK: Checks

    private static func validate(va: UInt64, size: UInt64) throws {
        guard VMLayout.isPageAligned(va), VMLayout.isPageAligned(size) else {
            throw PageTableError.unaligned(va: va, pa: 0, size: size)
        }
        guard size > 0 else { throw PageTableError.emptyRange(va: va) }
        let vaLimit: UInt64 = 1 << VMLayout.virtualAddressBits
        guard va < vaLimit, size <= vaLimit - va else { throw PageTableError.virtualAddressOutOfRange(va: va, size: size) }
    }

    /// The number of tables `map(va:size:)` would allocate.
    public func tablesNeeded(va: UInt64, size: UInt64) -> Int {
        guard size > 0 else { return 0 }
        var needed = 0
        var lastNewL2 = -1
        var cursor = va & ~(Self.l3Span - 1)
        let end = va + size
        while cursor < end {
            let i1 = Self.index(cursor, level: 1)
            if let l2 = next(0, i1) {
                if next(l2, Self.index(cursor, level: 2)) == nil { needed += 1 }
            } else {
                if i1 != lastNewL2 { needed += 1; lastNewL2 = i1 }
                needed += 1
            }
            let (n, o) = cursor.addingReportingOverflow(Self.l3Span)
            if o { break }
            cursor = n
        }
        return needed
    }

    /// Throws `arenaExhausted` when mapping [va, va+size) needs more tables
    /// than the arena has left. Changes nothing.
    public func checkCapacity(va: UInt64, size: UInt64) throws {
        if tableCount + tablesNeeded(va: va, size: size) > capacity { throw PageTableError.arenaExhausted(capacity: capacity) }
    }

    // MARK: Changes

    /// Maps [va, va+size) to [pa, pa+size). Either the whole range is mapped
    /// or, on error, nothing changes. Errors as `PageTableBuilder.map`.
    public func map(va: UInt64, pa: UInt64, size: UInt64, attributes: PageAttributes) throws {
        guard VMLayout.isPageAligned(va), VMLayout.isPageAligned(pa), VMLayout.isPageAligned(size) else {
            throw PageTableError.unaligned(va: va, pa: pa, size: size)
        }
        try Self.validate(va: va, size: size)
        let paLimit: UInt64 = 1 << VMLayout.physicalAddressBits
        guard pa < paLimit, size <= paLimit - pa else { throw PageTableError.physicalAddressOutOfRange(pa: pa, size: size) }
        // Nothing in the range may be mapped yet.
        try forEachRun(va: va, size: size, allocate: false) { slot, first, count, runVA in
            guard let slot else { return }
            let t = table(slot)
            for i in first..<(first + count) where t[i] & Self.typeMask != 0 {
                throw PageTableError.alreadyMapped(va: runVA + UInt64(i - first) * Self.page)
            }
        }
        try checkCapacity(va: va, size: size)
        let bits = attributes.leafDescriptorBits | Self.valid
        forEachRun(va: va, size: size, allocate: true) { slot, first, count, runVA in
            let t = table(slot!)
            var d = ((pa + (runVA - va)) & Self.oaMask) | bits
            for i in first..<(first + count) {
                t[i] = d
                d &+= Self.page
            }
            markDirty(slot!)
        }
    }

    /// Clears the leaf entries of [va, va+size); unmapped pages are skipped,
    /// empty tables kept. Returns the number of pages unmapped.
    @discardableResult
    public func unmap(va: UInt64, size: UInt64) throws -> Int {
        try Self.validate(va: va, size: size)
        var cleared = 0
        forEachRun(va: va, size: size, allocate: false) { slot, first, count, _ in
            guard let slot else { return }
            let t = table(slot)
            var changed = false
            for i in first..<(first + count) where t[i] & Self.typeMask != 0 {
                t[i] = 0
                cleared += 1
                changed = true
            }
            if changed { markDirty(slot) }
        }
        return cleared
    }

    /// Rewrites the attributes of every page of [va, va+size), keeping each
    /// output address. Every page must be mapped; otherwise nothing changes
    /// and `notMapped` names the first hole.
    public func protect(va: UInt64, size: UInt64, attributes: PageAttributes) throws {
        try Self.validate(va: va, size: size)
        try forEachRun(va: va, size: size, allocate: false) { slot, first, count, runVA in
            guard let slot else { throw PageTableError.notMapped(va: runVA) }
            let t = table(slot)
            for i in first..<(first + count) where t[i] & Self.typeMask != Self.valid {
                throw PageTableError.notMapped(va: runVA + UInt64(i - first) * Self.page)
            }
        }
        let bits = attributes.leafDescriptorBits | Self.valid
        forEachRun(va: va, size: size, allocate: false) { slot, first, count, _ in
            let t = table(slot!)
            var changed = false
            for i in first..<(first + count) {
                let new = (t[i] & Self.oaMask) | bits
                if new != t[i] {
                    t[i] = new
                    changed = true
                }
            }
            if changed { markDirty(slot!) }
        }
    }

    /// Calls `body` for each L3 table's part of [va, va+size): the slot (nil
    /// when the table does not exist and `allocate` is false), the first
    /// entry index, the entry count, and the VA of the first entry.
    private func forEachRun(va: UInt64, size: UInt64, allocate: Bool,
                            _ body: (_ slot: Int?, _ first: Int, _ count: Int, _ va: UInt64) throws -> Void) rethrows {
        var cursor = va
        let end = va + size
        while cursor < end {
            let blockEnd = (cursor & ~(Self.l3Span - 1)) &+ Self.l3Span
            let runEnd = blockEnd == 0 || blockEnd > end ? end : blockEnd
            let first = Self.index(cursor, level: 3)
            let count = Int((runEnd - cursor) / Self.page)
            let slot = allocate ? l3(for: cursor) : existingL3(for: cursor)
            try body(slot, first, count, cursor)
            cursor = runEnd
        }
    }

    // MARK: Queries

    /// Translates a VA (offset kept). Nil if unmapped.
    public func translate(_ va: UInt64) -> (pa: UInt64, attributes: PageAttributes)? {
        guard va < 1 << VMLayout.virtualAddressBits, let slot = existingL3(for: va) else { return nil }
        let d = table(slot)[Self.index(va, level: 3)]
        guard d & Self.typeMask == Self.valid else { return nil }
        return ((d & Self.oaMask) | (va & (Self.page - 1)), PageAttributes(leafDescriptor: d))
    }

    /// The raw descriptor at `index` of the table at `tableGPA`, if that table exists.
    public func descriptor(tableGPA: UInt64, index: Int) -> UInt64? {
        guard let slot = slot(ofTableAt: tableGPA), (0..<Self.entries).contains(index) else { return nil }
        return table(slot)[index]
    }

    /// Every table, as (gpa, 16 KiB of little-endian descriptors), in arena order.
    public var tables: [(gpa: UInt64, bytes: [UInt8])] {
        (0..<tableCount).map { (gpa(ofSlot: $0), bytes(ofSlot: $0)) }
    }

    private func bytes(ofSlot slot: Int) -> [UInt8] {
        [UInt8](unsafeUninitializedCapacity: Int(Self.page)) { buffer, count in
            let t = table(slot)
            for i in 0..<Self.entries {
                withUnsafeBytes(of: t[i].littleEndian) { b in
                    for j in 0..<8 { buffer[i * 8 + j] = b[j] }
                }
            }
            count = Int(Self.page)
        }
    }

    // MARK: Dirty tracking

    /// True when some table changed since the last `writeDirtyTables`.
    public var hasDirtyTables: Bool { !dirtyList.isEmpty }

    /// Hands every changed table (gpa, 16 KiB of little-endian descriptors) to
    /// `write`, in arena order, and marks them clean. Returns how many.
    @discardableResult
    public func writeDirtyTables(_ write: (_ gpa: UInt64, _ bytes: UnsafeRawBufferPointer) throws -> Void) rethrows -> Int {
        guard !dirtyList.isEmpty else { return 0 }
        let slots = dirtyList.sorted()
        dirtyList.removeAll(keepingCapacity: true)
        for (n, s) in slots.enumerated() {
            do {
                #if _endian(big)
                let b = bytes(ofSlot: s)
                try b.withUnsafeBytes { try write(gpa(ofSlot: s), $0) }
                #else
                try write(gpa(ofSlot: s), UnsafeRawBufferPointer(start: table(s), count: Int(Self.page)))
                #endif
            } catch {
                // The tables not written stay dirty.
                dirtyList = Array(slots[n...])
                throw error
            }
            dirtyFlags[s] = false
        }
        return slots.count
    }
}
