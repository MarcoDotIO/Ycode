#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Testing
@testable import YcodeDarwinABI

// Simulator stage 6 §5 (performance): the interval map, the in-place page
// tables, and the address space built on them keep the semantics of the
// straightforward versions (checked against models), scale with the number
// of mappings, and share read-only file views.

private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: UInt64) -> UInt64 { next() % n }
}

private func monotonicNanoseconds() -> UInt64 {
    var t = timespec()
    clock_gettime(CLOCK_MONOTONIC, &t)
    return UInt64(t.tv_sec) * 1_000_000_000 + UInt64(t.tv_nsec)
}

@Suite struct AddressSpacePerfTests {
    // MARK: IntervalMap against a sorted-array model

    @Test func intervalMapMatchesModel() {
        var rng = SplitMix(state: 1)
        let map = IntervalMap<PlainInterval>()
        var model: [PlainInterval] = []
        for step in 0..<4000 {
            let lo = rng.below(4096) * 16, len = (rng.below(64) + 1) * 16
            let hi = lo + len
            switch rng.below(3) {
            case 0, 1:
                // Insert [lo, hi) after carving it out (as the address space does).
                let removed = map.extract(lo, hi)
                let expected = model.filter { $0.start < hi && lo < $0.end }
                #expect(removed == expected, "step \(step)")
                model.removeAll { $0.start < hi && lo < $0.end }
                for r in removed {
                    if r.start < lo { map.insert(PlainInterval(start: r.start, end: lo)); model.append(PlainInterval(start: r.start, end: lo)) }
                    if r.end > hi { map.insert(PlainInterval(start: hi, end: r.end)); model.append(PlainInterval(start: hi, end: r.end)) }
                }
                map.insert(PlainInterval(start: lo, end: hi))
                model.append(PlainInterval(start: lo, end: hi))
                model.sort { $0.start < $1.start }
            default:
                let removed = map.extract(lo, hi)
                #expect(removed == model.filter { $0.start < hi && lo < $0.end }, "step \(step)")
                model.removeAll { $0.start < hi && lo < $0.end }
            }
            #expect(map.count == model.count)
            // Queries.
            let x = rng.below(4096 * 16 + 2048)
            #expect(map.floor(x) == model.last { $0.start <= x })
            #expect(map.ceiling(x) == model.first { $0.start >= x })
            #expect(map.element(containing: x) == model.first { $0.start <= x && x < $0.end })
            let qhi = x + rng.below(2048) + 1
            #expect(map.overlapping(x, qhi) == model.filter { $0.start < qhi && x < $0.end })
            #expect(map.intersects(x, qhi) == model.contains { $0.start < qhi && x < $0.end })
            #expect(map.covers(x, qhi) == Self.modelCovers(model, x, qhi))
            let size = (rng.below(32) + 1) * 16
            #expect(map.firstGap(from: x, size: size) == Self.modelFirstGap(model, x, size), "step \(step) x \(x) size \(size)")
        }
        #expect(map.elements == model)
    }

    private static func modelFirstGap(_ model: [PlainInterval], _ from: UInt64, _ size: UInt64) -> UInt64 {
        var p = from
        for r in model where r.end > p {
            if r.start >= p + size { return p }
            p = max(p, r.end)
        }
        return p
    }

    private static func modelCovers(_ model: [PlainInterval], _ lo: UInt64, _ hi: UInt64) -> Bool {
        var cursor = lo
        for r in model where r.end > cursor && r.start < hi {
            if r.start > cursor { return false }
            cursor = r.end
        }
        return cursor >= hi
    }

    @Test func rangeAllocatorIsFirstFit() {
        let a = RangeAllocator(base: 0x10000, size: 0x10000)
        #expect(a.allocate(0x4000) == 0x10000)
        #expect(a.allocate(0x8000) == 0x14000)
        #expect(a.allocate(0x8000) == nil)
        #expect(a.free(0x10000, 0x4000) == [0x10000..<0x14000])
        #expect(a.allocate(0x2000) == 0x10000)
        #expect(a.allocate(0x2000) == 0x12000)
        #expect(a.bytesInUse == 0xC000)
        #expect(a.isAllocated(0x10000, 0xC000) && !a.isAllocated(0x10000, 0xD000))
        #expect(a.free(0x13000, 0x2000) == [0x13000..<0x14000, 0x14000..<0x15000])
        #expect(a.bytesInUse == 0xA000)
        a.mark(0x1C000, 0x4000)
        #expect(a.takeAll().count == 4 && a.bytesInUse == 0)
    }

    // MARK: GuestPageTables against PageTableBuilder

    @Test func pageTablesMatchTheBuilder() throws {
        var rng = SplitMix(state: 7)
        var builder = PageTableBuilder(tableArenaGPA: 0x4020_0000, tableArenaSize: 16 << 20)
        let tables = GuestPageTables(tableArenaGPA: 0x4020_0000, tableArenaSize: 16 << 20)
        let page = VMLayout.pageSize
        var mapped: [UInt64: Bool] = [:]
        let attrs: [PageAttributes] = [VMProtection.readWrite.el0PageAttributes, VMProtection.read.el0PageAttributes,
                                       VMProtection.readExecute.el0PageAttributes]
        for _ in 0..<600 {
            // Ranges that cross 32 MiB table boundaries and 64 GiB L2 boundaries.
            let region: UInt64 = [0x1_0000_0000, 0x1_FFE0_0000, 0xF_FFF0_0000, 0x3_2000_0000][Int(rng.below(4))]
            let va = region + rng.below(4096) * page
            let size = (rng.below(3000) + 1) * page
            let a = attrs[Int(rng.below(3))]
            switch rng.below(3) {
            case 0:
                let pa = 0x10_0000_0000 + rng.below(1 << 20) * page
                let b = Result { try builder.map(va: va, pa: pa, size: size, attributes: a) }
                let t = Result { try tables.map(va: va, pa: pa, size: size, attributes: a) }
                #expect(String(describing: b) == String(describing: t))
                if case .success = b { for p in stride(from: va, to: va + size, by: Int(page)) { mapped[p] = true } }
            case 1:
                let b = try builder.unmap(va: va, size: size)
                let t = try tables.unmap(va: va, size: size)
                #expect(b == t)
                for p in stride(from: va, to: va + size, by: Int(page)) { mapped[p] = nil }
            default:
                let b = Result { try builder.protect(va: va, size: size, attributes: a) }
                let t = Result { try tables.protect(va: va, size: size, attributes: a) }
                #expect(String(describing: b) == String(describing: t))
            }
        }
        #expect(builder.tableCount == tables.tableCount)
        let bt = builder.tables, tt = tables.tables
        #expect(bt.count == tt.count)
        for (x, y) in zip(bt, tt) { #expect(x.gpa == y.gpa && x.bytes == y.bytes) }
        for p in mapped.keys.prefix(200) {
            #expect(builder.translate(p + 0x123)! == tables.translate(p + 0x123)!)
        }
        // Dirty tracking: every table written once, in arena order.
        var written: [UInt64] = []
        tables.writeDirtyTables { gpa, bytes in
            #expect(bytes.count == 16384)
            written.append(gpa)
        }
        #expect(written == tt.map(\.gpa) && !tables.hasDirtyTables)
    }

    @Test func pageTableCapacityIsCheckedBeforeAnyChange() throws {
        // Root + one L2 + one L3 fit; a range needing a second L3 does not.
        let tables = GuestPageTables(tableArenaGPA: 0x4020_0000, tableArenaSize: 3 * 16384)
        try tables.map(va: 0x1_0000_0000, pa: 0x10_0000_0000, size: 0x4000, attributes: VMProtection.read.el0PageAttributes)
        #expect(throws: PageTableError.arenaExhausted(capacity: 3)) {
            try tables.map(va: 0x1_01FF_C000, pa: 0x10_0000_0000, size: 0x8000, attributes: VMProtection.read.el0PageAttributes)
        }
        #expect(tables.translate(0x1_01FF_C000) == nil && tables.tableCount == 3)
    }

    // MARK: Address space against the original placement rule

    /// The original first fit: every mapping and exclusion as an obstacle.
    private static func modelFirstFit(_ regions: [GuestRegion], exclusions: [Range<UInt64>], size: UInt64, from start: UInt64) -> UInt64? {
        let limit = VMLayout.userVALimit
        let obstacles = (regions.map { $0.va..<$0.end } + exclusions).sorted { $0.lowerBound < $1.lowerBound }
        var candidate = start
        for o in obstacles {
            guard candidate < limit, size <= limit - candidate else { return nil }
            if o.upperBound <= candidate { continue }
            if o.lowerBound >= candidate + size { return candidate }
            candidate = max(candidate, o.upperBound)
        }
        guard candidate < limit, size <= limit - candidate else { return nil }
        return candidate
    }

    @Test func placementMatchesTheOriginalFirstFit() throws {
        var rng = SplitMix(state: 3)
        let space = GuestAddressSpace(backing: FakePhysicalBacking())
        let page = VMLayout.pageSize
        for step in 0..<1500 {
            let size = (rng.below(64) + 1) * page
            switch rng.below(5) {
            case 0, 1:
                let hint: UInt64? = rng.below(2) == 0 ? nil : VMLayout.anonymousVABase + rng.below(1 << 16) * page
                let base = VMLayout.anonymousVABase
                let start = max(hint ?? base, base)
                let expected = Self.modelFirstFit(space.regions, exclusions: space.anywhereExclusions, size: size, from: start)
                    ?? Self.modelFirstFit(space.regions, exclusions: space.anywhereExclusions, size: size, from: base)
                let va = try space.mapAnonymous(at: nil, size: size, protection: .readWrite, hint: hint)
                #expect(va == expected, "step \(step)")
            case 2:
                // Fixed mappings, also inside the shared region.
                let va = (rng.below(2) == 0 ? VMLayout.sharedRegionBase : VMLayout.anonymousVABase) + rng.below(1 << 14) * page
                _ = try space.mapAnonymous(at: va, size: size, protection: .read, hint: nil)
            case 3:
                let va = VMLayout.anonymousVABase + rng.below(1 << 14) * page
                try space.unmap(va: va, size: size)
            default:
                if let r = space.regions.randomElement(using: &rng) {
                    try space.protect(va: r.va, size: r.size, protection: [.read, .execute])
                }
            }
        }
        // Region queries agree with the full list.
        let all = space.regions
        for r in all.prefix(300) {
            #expect(space.region(containing: r.va + r.size / 2) == r)
            #expect(space.regions(overlapping: r.va..<(r.end + page)) == all.filter { $0.va < r.end + page && r.va < $0.end })
        }
    }

    /// Operations stay cheap as the number of mappings grows (they were
    /// linear in it): the time per operation with 16× the mappings is far
    /// below 16× the time.
    @Test func operationsScaleWithTheNumberOfMappings() throws {
        func timePerOp(background: Int) throws -> Double {
            let space = GuestAddressSpace(backing: FakePhysicalBacking())
            let page = VMLayout.pageSize
            for i in 0..<background {
                let va = try space.mapAnonymous(at: nil, size: page, protection: .readWrite, hint: nil)
                if i & 1 == 1 { try space.protect(va: va, size: page, protection: .read) }
            }
            let rounds = 400
            let t0 = monotonicNanoseconds()
            for _ in 0..<rounds {
                let va = try space.mapAnonymous(at: nil, size: 2 * page, protection: .readWrite, hint: nil)
                try space.protect(va: va, size: page, protection: .read)
                _ = space.region(containing: va)
                try space.unmap(va: va, size: 2 * page)
            }
            return Double(monotonicNanoseconds() - t0) / Double(rounds)
        }
        _ = try timePerOp(background: 100)  // warm up
        let small = try timePerOp(background: 500)
        let large = try timePerOp(background: 8000)
        #expect(large < small * 6, "per-op \(small) ns with 500 mappings, \(large) ns with 8000")
    }

    // MARK: Shared read-only file views

    @Test func readOnlyFileMappingsShareOneViewAndPrivatizeOnWrite() throws {
        let dir = try TempTree()
        let bytes = (0..<0x10000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) }
        try dir.writeFile("lib.bin", bytes)
        let file = try GuestFile.openReadOnly(hostPath: dir.host("lib.bin"))
        let backing = FakePhysicalBacking(sharedReadOnlyFiles: true)
        let space = GuestAddressSpace(backing: backing)
        let a = try space.mapFile(file, offset: 0, at: nil, size: 0x10000, protection: .readExecute, hint: nil)
        let b = try space.mapFile(file, offset: 0x4000, at: nil, size: 0x8000, protection: .read, hint: nil)
        #expect(backing.readOnlyViewRequests == 2 && backing.fileSlots.isEmpty)
        guard case let .file(_, _, gpaA) = space.region(containing: a)!.backing,
              case let .file(_, offB, gpaB) = space.region(containing: b)!.backing else {
            Issue.record("expected file regions"); return
        }
        #expect(gpaB == gpaA + 0x4000 && offB == 0x4000)
        #expect(try space.read(va: b, count: 4) == Array(bytes[0x4000..<0x4004]))
        // A writable mapping never uses the shared view.
        let w = try space.mapFile(file, offset: 0, at: nil, size: 0x4000, protection: .readWrite, hint: nil)
        #expect(backing.fileSlots.count == 1)
        try space.write(va: w, bytes: [0xEE])
        // EL0-checked writes to a read-only mapping are refused, as before.
        #expect(throws: GuestMemoryError.accessDenied(va: a)) { try space.write(va: a, bytes: [1]) }
        // A VMM write moves only the written page of `a` to a private view.
        try space.write(va: a + 0x4010, bytes: [0xAB, 0xCD], checkingEL0Access: false)
        #expect(space.privatizedPages == 1 && backing.fileSlots.count == 2)
        #expect(try space.read(va: a + 0x4010, count: 2) == [0xAB, 0xCD])
        #expect(try space.read(va: b + 0x10, count: 2) == [bytes[0x4010], bytes[0x4011]])   // the shared view is unchanged
        #expect(space.regions(overlapping: a..<(a + 0x10000)).count == 3)
        #expect(space.regions(overlapping: a..<(a + 0x10000)).allSatisfy { if case .file = $0.backing { true } else { false } })
        // mprotect adding write privatizes the range first.
        try space.protect(va: b, size: 0x8000, protection: .readWrite)
        try space.write(va: b, bytes: [0x77])
        #expect(try space.read(va: b, count: 2) == [0x77, bytes[0x4001]])
        #expect(try space.read(va: a + 0x4000, count: 1) == [bytes[0x4000]])
        #expect(space.privatizedPages == 3)
        // Unmapping everything returns what the private views took from the pool (none here: the fake bump-allocates them).
        try space.unmap(va: a, size: 0x10000)
        try space.unmap(va: b, size: 0x8000)
        #expect(space.region(containing: a) == nil && space.region(containing: b) == nil)
    }

    @Test func discardAllDropsEverything() throws {
        let space = GuestAddressSpace(backing: FakePhysicalBacking())
        let va = try space.mapAnonymous(at: nil, size: 0x8000, protection: .readWrite, hint: nil)
        space.discardAll()
        #expect(space.regions.isEmpty && space.region(containing: va) == nil && space.isDiscarded)
        #expect(throws: GuestMemoryError.unmapped(va: va)) { _ = try space.read(va: va, count: 1) }
        #expect(throws: DarwinErrnoError.self) { _ = try space.mapAnonymous(at: nil, size: 0x4000, protection: .read, hint: nil) }
        #expect(throws: DarwinErrnoError.self) { try space.unmap(va: va, size: 0x4000) }
    }
}

/// Random map/unmap/protect/share/remap sequences on one address space:
/// every pool range the space releases must be allocated (no double or
/// stray release), and the pool holds exactly the space's anonymous pages.
@Suite struct AddressSpaceReleaseFuzzTests {
    @Test func releasesMatchAllocations() throws {
        for seed in UInt64(1)...6 {
            var rng = SplitMix(state: seed)
            let backing = FakePhysicalBacking()
            let space = GuestAddressSpace(backing: backing)
            let page = VMLayout.pageSize
            let base: UInt64 = 0x2_0000_0000
            for step in 0..<3000 {
                let va = base + rng.below(256) * page
                let size = (rng.below(16) + 1) * page
                switch rng.below(6) {
                case 0, 1: _ = try? space.mapAnonymous(at: va, size: size, protection: .readWrite, hint: nil)
                case 2: try? space.unmap(va: va, size: size)
                case 3: try? space.protect(va: va, size: size, protection: rng.below(2) == 0 ? .read : .readWrite)
                case 4:
                    // vm_remap without copy: share the source, map the object elsewhere.
                    if let (object, offset) = try? space.share(va: va, size: size) {
                        let to = base + rng.below(256) * page
                        _ = try? space.mapShared(object, offset: offset, at: to, size: size, protection: .readWrite, hint: nil)
                    }
                default: _ = try? space.mapAnonymous(at: nil, size: size, protection: .readWrite, hint: base)
                }
                #expect(backing.releaseViolations.isEmpty, "seed \(seed) step \(step): \(backing.releaseViolations)")
                if !backing.releaseViolations.isEmpty { return }
            }
            for r in space.regions where !r.permanent { try space.unmap(va: r.va, size: r.size) }
            #expect(backing.anonymousBytesInUse == 0, "seed \(seed): \(backing.anonymousBytesInUse) bytes leaked")
        }
    }
}
