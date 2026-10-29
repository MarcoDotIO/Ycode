// The guest's virtual address space in stage 3: an allocator over the VA
// map, the stage-1 tables that describe it, and the physical backing that
// the hypervisor (or an in-memory fake) supplies.
// Contract: specs/simulator/stage3-contract.md §2, §3, §4; stage 6 §5
// (performance: O(log n) mapping operations, shared read-only file views).

import Foundation

// MARK: - Protection

/// Darwin VM protection bits (`VM_PROT_*` and `PROT_*` share the values).
public struct VMProtection: OptionSet, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let read = VMProtection(rawValue: 1)
    public static let write = VMProtection(rawValue: 2)
    public static let execute = VMProtection(rawValue: 4)
    public static let none: VMProtection = []
    public static let readWrite: VMProtection = [.read, .write]
    public static let readExecute: VMProtection = [.read, .execute]
    public static let all: VMProtection = [.read, .write, .execute]

    /// The EL0 page attributes for this protection. PXN is always set. Arm
    /// has no write-only or execute-only EL0 page here, so write and execute
    /// each imply read. No access at all is AP `10` (EL1 read-only, no EL0).
    public var el0PageAttributes: PageAttributes {
        let r = contains(.read), w = contains(.write), x = contains(.execute)
        if !r && !w && !x { return PageAttributes(access: .el1ReadOnly) }
        return PageAttributes(access: w ? .el0ReadWrite : .el0ReadOnly, el0Execute: x)
    }

    public var description: String {
        (contains(.read) ? "r" : "-") + (contains(.write) ? "w" : "-") + (contains(.execute) ? "x" : "-")
    }
}

// MARK: - Physical backing

/// Guest physical memory beyond the page tables: implemented by the
/// hypervisor with KVM memslots and by `FakePhysicalBacking` for tests.
public protocol PhysicalBacking: AnyObject {
    /// `size` bytes (a 16 KiB multiple) of zeroed anonymous memory at a
    /// 16 KiB-aligned GPA.
    func allocateAnonymous(size: UInt64) throws -> UInt64
    /// A private copy-on-write view of `file` bytes [offset, offset+size)
    /// (16 KiB-aligned offset, 16 KiB-multiple size) at a 16 KiB-aligned GPA.
    /// Bytes past the end of the file must read as zero. The file is never
    /// modified.
    func mapFile(_ file: GuestFile, offset: UInt64, size: UInt64) throws -> UInt64
    /// A view of `file` bytes [offset, offset+size) (alignment as `mapFile`)
    /// that is never written, neither by the guest nor by the VMM: the
    /// backing may share it with every other read-only mapping of the same
    /// file, in any address space. Nil when the backing has no such view for
    /// this request (the caller then uses `mapFile`). Writing to the GPA
    /// range is an error.
    func mapFileReadOnly(_ file: GuestFile, offset: UInt64, size: UInt64) throws -> UInt64?
    /// Returns anonymous pages to the pool. They must read as zero when
    /// allocated again. The address space also calls it for the pages of a
    /// private file mapping (`mapFile`), which a backing may serve from its
    /// pool; GPAs the backing did not allocate from its pool are ignored.
    func release(gpa: UInt64, size: UInt64)
    func readPhysical(gpa: UInt64, count: Int) throws -> [UInt8]
    func writePhysical(gpa: UInt64, bytes: [UInt8]) throws
    /// `writePhysical` from a raw buffer (page-table writes).
    func writePhysical(gpa: UInt64, from bytes: UnsafeRawBufferPointer) throws
    /// The GPA at which all of `object` is visible in this guest physical
    /// space (registered on first use, the same GPA afterwards). The backing
    /// keeps the object alive while it is registered.
    func mapShared(_ object: SharedMemoryObject) throws -> UInt64
}

extension PhysicalBacking {
    /// Default: no shared read-only views (callers fall back to `mapFile`).
    public func mapFileReadOnly(_ file: GuestFile, offset: UInt64, size: UInt64) throws -> UInt64? { nil }
    /// Default: copies the buffer into an array and calls `writePhysical(gpa:bytes:)`.
    public func writePhysical(gpa: UInt64, from bytes: UnsafeRawBufferPointer) throws {
        try writePhysical(gpa: gpa, bytes: Array(bytes))
    }
}

// MARK: - Regions

/// One mapping of the address space, for tracing and region queries.
public struct GuestRegion: Equatable, Hashable, Sendable, CustomStringConvertible {
    public enum Backing: Equatable, Hashable, Sendable {
        case anonymous(gpa: UInt64)
        case file(path: String, offset: UInt64, gpa: UInt64)
        /// Part of a shared memory object (a Mach memory entry's memory).
        case shared(serial: UInt64, offset: UInt64, gpa: UInt64)
        /// Anonymous memory whose pages get backing when first touched
        /// (a large reservation; `GuestAddressSpace.lazyAnonymousThreshold`).
        /// It has no GPA; untouched pages read as zeros.
        case unbacked
    }

    public var va: UInt64
    public var size: UInt64
    public var protection: VMProtection
    public var backing: Backing
    /// Set by the VMM for mappings the guest may not unmap, replace, or
    /// re-protect (commpage, host page).
    public var permanent: Bool

    public var end: UInt64 { va + size }

    /// The GPA backing `va`.
    public var gpa: UInt64 {
        switch backing {
        case let .anonymous(gpa), let .file(_, _, gpa), let .shared(_, _, gpa): gpa
        case .unbacked: 0
        }
    }

    public var backingDescription: String {
        switch backing {
        case let .anonymous(gpa): "anonymous gpa \(hex(gpa))"
        case let .file(path, offset, gpa): "\(path) @\(hex(offset)) gpa \(hex(gpa))"
        case let .shared(serial, offset, gpa): "shared object #\(serial) @\(hex(offset)) gpa \(hex(gpa))"
        case .unbacked: "anonymous, backed on first touch"
        }
    }

    public var description: String {
        "\(hex16(va))-\(hex16(end)) \(protection) \(backingDescription)\(permanent ? " permanent" : "")"
    }
}

// MARK: - GuestVirtualMemory

/// The guest-visible VM operations (`mmap`, `munmap`, `mprotect`,
/// `vm_allocate`, ...). Every failure is a `DarwinErrnoError`: EINVAL for
/// bad arguments, ENOMEM for no space or a range outside the user map.
public protocol GuestVirtualMemory: GuestMemoryAccess, AnyObject {
    /// Zero-filled memory. `at: nil` means anywhere (first fit at or above
    /// `max(hint, VMLayout.anonymousVABase)`, outside the shared region);
    /// `at: va` is MAP_FIXED and replaces whatever was there.
    func mapAnonymous(at: UInt64?, size: UInt64, protection: VMProtection, hint: UInt64?) throws -> UInt64
    /// A private mapping of `file` from `offset`. Placement as `mapAnonymous`.
    func mapFile(_ file: GuestFile, offset: UInt64, at: UInt64?, size: UInt64, protection: VMProtection, hint: UInt64?) throws -> UInt64
    /// Unmaps [va, va+size). Holes are fine.
    func unmap(va: UInt64, size: UInt64) throws
    /// Changes the protection of [va, va+size), which must be fully mapped.
    func protect(va: UInt64, size: UInt64, protection: VMProtection) throws
    /// Maps `object` bytes [offset, offset+size) (16 KiB-aligned offset)
    /// shared: writes through any mapping are seen through every other one,
    /// in any address space. Placement as `mapAnonymous`.
    func mapShared(_ object: SharedMemoryObject, offset: UInt64, at: UInt64?, size: UInt64, protection: VMProtection,
                   hint: UInt64?) throws -> UInt64
    /// Makes [va, va+size) (16 KiB-aligned, every page mapped, none
    /// permanent) shared memory and returns the object and the offset of
    /// `va` in it. A range inside one shared mapping is returned as it is;
    /// otherwise its current contents move into a new object, which then
    /// backs the range (same protections).
    func share(va: UInt64, size: UInt64) throws -> (object: SharedMemoryObject, offset: UInt64)
    /// The mappings, ascending by VA.
    var regions: [GuestRegion] { get }
    /// The mapping that contains `va`, if any.
    func region(containing va: UInt64) -> GuestRegion?
    /// The mappings that intersect `range`, ascending by VA (whole, not clipped).
    func regions(overlapping range: Range<UInt64>) -> [GuestRegion]
    /// Bumps on every page-table change.
    var generation: UInt64 { get }
    /// Bumps on every page-table change that can leave a stale TLB entry
    /// (a valid descriptor removed or changed); a trap that changes it
    /// resumes with `flushTLB` (guest-cpu.md §4.2).
    var tlbGeneration: UInt64 { get }
    /// The pages whose translations the changes after `tlbGeneration` value
    /// `since` touched, when that is one known span; nil means "flush all".
    func tlbRange(since: UInt64) -> TLBRange?
    /// A guest translation fault at `va`: gives an untouched page of a lazy
    /// anonymous mapping its backing (when its protection allows any
    /// access) and returns true; false when the fault is a real one.
    func resolveTranslationFault(va: UInt64) -> Bool
    /// Runs `body` with no other change of this address space in between.
    func atomically<T>(_ body: () throws -> T) rethrows -> T
}

extension GuestVirtualMemory {
    /// Runs `body` so that no other change of this address space happens
    /// during it (a check-then-map sequence). The default runs it as is
    /// (single-threaded test memories); `GuestAddressSpace` holds its
    /// mutex (L1), which every change takes (`boot-profile.md` §3.6).
    public func atomically<T>(_ body: () throws -> T) rethrows -> T { try body() }

    /// Default: no lazy mappings, so every translation fault is a real one.
    public func resolveTranslationFault(va: UInt64) -> Bool { false }

    /// Conservative default: every change counts.
    public var tlbGeneration: UInt64 { generation }
    /// Default: nil, so the caller flushes the whole TLB.
    public func tlbRange(since: UInt64) -> TLBRange? { nil }

    /// Default: a linear search of `regions`.
    public func region(containing va: UInt64) -> GuestRegion? {
        regions.first { $0.va <= va && va < $0.end }
    }

    /// Default: a linear filter of `regions`.
    public func regions(overlapping range: Range<UInt64>) -> [GuestRegion] {
        regions.filter { $0.va < range.upperBound && range.lowerBound < $0.end }
    }
}

// MARK: - GuestAddressSpace

/// The stage-3 address space (stage3-contract.md §4). It owns the stage-1
/// tables; after every change it writes the changed tables through
/// `backing.writePhysical` and bumps `generation`.
///
/// Rules this implementation adds where §4 is silent:
/// - Addresses and file offsets must be 16 KiB-aligned (EINVAL); sizes are
///   rounded up to 16 KiB; a zero size is EINVAL. An unaligned hint is
///   rounded up.
/// - Guest mappings live in [`userVAFloor`, `userVALimit`); a fixed range
///   outside it is ENOMEM. Only `mapPermanent...` may go above the limit.
/// - "Anywhere" searches [max(hint, base), limit) and then, if the hint was
///   above the base, [base, limit). It skips the shared region and the
///   commpage reservation.
/// - A change that touches a permanent region is EINVAL and changes nothing.
///
/// Costs: the mappings are an `IntervalMap`, so finding, inserting,
/// removing, and placing a mapping is O(log n) in the number of mappings;
/// the tables (`GuestPageTables`) cost O(pages changed). A file mapping
/// without write access uses the backing's shared read-only view of the file
/// when it has one; such pages move to a private copy-on-write view before
/// they can be written (`protect` adding write, a VMM write).
public final class GuestAddressSpace: GuestVirtualMemory {
    private struct Chunk: IntervalMapElement {
        var va: UInt64
        var size: UInt64
        var protection: VMProtection
        var gpa: UInt64
        var file: GuestFile?
        /// The offset in `file` or in `shared`.
        var fileOffset: UInt64
        var shared: SharedMemoryObject?
        var permanent: Bool
        /// `gpa` is the backing's shared read-only view of `file`.
        var readOnlyShared: Bool = false
        /// Anonymous memory without backing yet (`gpa` unused, no page-table
        /// entries): pages get backing when first touched.
        var lazy: Bool = false
        var end: UInt64 { va + size }
        var start: UInt64 { va }

        /// The part of this chunk in [lo, hi), which must intersect it.
        func slice(_ lo: UInt64, _ hi: UInt64) -> Chunk {
            let start = max(lo, va), stop = min(hi, end)
            var c = self
            c.va = start
            c.size = stop - start
            c.gpa = lazy ? 0 : gpa + (start - va)
            c.fileOffset = fileOffset + (start - va)
            return c
        }

        var isAnonymous: Bool { file == nil && shared == nil }
        /// Pages the backing may have allocated from its pool: anonymous
        /// memory and private file views.
        var isReleasable: Bool { shared == nil && !readOnlyShared && !lazy }
    }

    public let backing: any PhysicalBacking
    public let pageTables: GuestPageTables
    public private(set) var generation: UInt64 = 0
    /// See `GuestVirtualMemory.tlbGeneration`. With
    /// `YCODE_TLB_FLUSH_ADDS=1` it follows `generation` (every change
    /// flushes, as before).
    public private(set) var tlbGeneration: UInt64 = 0
    /// `pageTables.invalidatingChanges` at the last table write.
    private var writtenInvalidations: UInt64 = 0
    /// The span of the last `tlbGeneration` bump (nil: unknown or too wide).
    private var lastInvalidatedSpan: Range<UInt64>?
    /// The VMM sets it before the first VM when the host's CTR_EL0.DIC is 0
    /// (there a flush also stands for the I-cache invalidation that a page
    /// reused for new code needs).
    nonisolated(unsafe) public static var flushOnAdditions = getenv("YCODE_TLB_FLUSH_ADDS").map { String(cString: $0) == "1" } ?? false
    /// When true (the default), `read`/`write` need EL0 access to each page,
    /// as a kernel's copyin/copyout would. The VMM turns it off to fill
    /// read-only pages.
    public var requireEL0Access: Bool
    /// Pages moved from a shared read-only file view to a private one (statistics).
    public private(set) var privatizedPages: UInt64 = 0

    /// VA ranges that "anywhere" placement never uses.
    public let anywhereExclusions: [Range<UInt64>] = [
        VMLayout.sharedRegionBase..<VMLayout.sharedRegionEnd,
        VMLayout.commpageReservationBase..<VMLayout.commpageReservationEnd,
    ]
    private let sortedExclusions: [Range<UInt64>]

    /// Held by every public operation (recursive).
    public let mutex = RecursiveMutex(name: "address space (L1)")
    /// Ordered by VA, disjoint.
    private let chunks = IntervalMap<Chunk>()
    private var readOnlySharedChunks = 0
    private var regionsCache: [GuestRegion]?
    /// Set by `discardAll()`: every later operation fails.
    public private(set) var isDiscarded = false

    /// `pageTables` may already hold the EL1 identity regions (they live
    /// below `userVAFloor`, where guest mappings never go). Its tables are
    /// written on the first change or by `flushPageTables()`.
    public init(backing: any PhysicalBacking, pageTables: PageTableBuilder = .stage3(), requireEL0Access: Bool = true) {
        self.backing = backing
        self.pageTables = GuestPageTables(pageTables)
        self.requireEL0Access = requireEL0Access
        sortedExclusions = anywhereExclusions.sorted { $0.lowerBound < $1.lowerBound }
    }

    // MARK: Queries

    private func region(of c: Chunk) -> GuestRegion {
        let backing: GuestRegion.Backing
        if let object = c.shared {
            backing = .shared(serial: object.serial, offset: c.fileOffset, gpa: c.gpa)
        } else if let file = c.file {
            backing = .file(path: file.guestPath, offset: c.fileOffset, gpa: c.gpa)
        } else if c.lazy {
            backing = .unbacked
        } else {
            backing = .anonymous(gpa: c.gpa)
        }
        return GuestRegion(va: c.va, size: c.size, protection: c.protection, backing: backing, permanent: c.permanent)
    }

    public var regions: [GuestRegion] { mutex.withLock { regionsLocked } }

    private var regionsLocked: [GuestRegion] {
        if let cached = regionsCache { return cached }
        let list = chunks.elements.map(region(of:))
        regionsCache = list
        return list
    }

    public func region(containing va: UInt64) -> GuestRegion? {
        mutex.withLock { chunks.element(containing: va).map(region(of:)) }
    }

    public func regions(overlapping range: Range<UInt64>) -> [GuestRegion] {
        mutex.withLock { chunks.overlapping(range.lowerBound, range.upperBound).map(region(of:)) }
    }

    /// The number of mappings.
    public var regionCount: Int { mutex.withLock { chunks.count } }

    /// The file mapped at `va`, if the mapping there is file-backed.
    public func file(at va: UInt64) -> GuestFile? {
        mutex.withLock { chunks.element(containing: va)?.file }
    }

    /// SNAPSHOT hook (agent SNAP, specs/simulator/snapshot.md §2.1): the
    /// shared memory object mapped at `va`, if the mapping there is shared.
    public func sharedObject(at va: UInt64) -> SharedMemoryObject? {
        mutex.withLock { chunks.element(containing: va)?.shared }
    }

    // MARK: GuestVirtualMemory

    public func mapAnonymous(at: UInt64?, size: UInt64, protection: VMProtection, hint: UInt64?) throws -> UInt64 {
        try map(file: nil, offset: 0, at: at, size: size, protection: protection, hint: hint, permanent: false)
    }

    public func mapFile(_ file: GuestFile, offset: UInt64, at: UInt64?, size: UInt64, protection: VMProtection, hint: UInt64?) throws -> UInt64 {
        try map(file: file, offset: offset, at: at, size: size, protection: protection, hint: hint, permanent: false)
    }

    public func mapShared(_ object: SharedMemoryObject, offset: UInt64, at: UInt64?, size: UInt64, protection: VMProtection,
                          hint: UInt64?) throws -> UInt64 {
        let rounded = (size + Self.pageMask) & ~Self.pageMask
        guard size > 0, offset & Self.pageMask == 0, offset <= object.size, rounded <= object.size - offset else {
            throw DarwinErrnoError(DarwinErrnoCode.EINVAL)
        }
        return try map(file: nil, shared: object, offset: offset, at: at, size: size, protection: protection, hint: hint,
                       permanent: false)
    }

    public func share(va: UInt64, size: UInt64) throws -> (object: SharedMemoryObject, offset: UInt64) {
        try mutex.withLock { try shareLocked(va: va, size: size) }
    }

    /// `GuestVirtualMemory.atomically`: the address-space mutex (L1,
    /// recursive) around `body`.
    public func atomically<T>(_ body: () throws -> T) rethrows -> T {
        try mutex.withLock(body)
    }

    private func shareLocked(va: UInt64, size: UInt64) throws -> (object: SharedMemoryObject, offset: UInt64) {
        try checkLive()
        let (lo, hi) = try checkedRange(va: va, size: size, permanent: false)
        let affected = chunks.overlapping(lo, hi)
        try checkCovered(affected, lo, hi)
        guard !affected.contains(where: \.permanent) else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        // Already one shared mapping: the same object.
        if affected.count == 1, let object = affected[0].shared {
            return (object, affected[0].fileOffset + (lo - affected[0].va))
        }
        let object = try SharedMemoryObject(size: hi - lo)
        let gpa: UInt64
        do { gpa = try backing.mapShared(object) } catch { throw DarwinErrnoError(DarwinErrnoCode.ENOMEM) }
        // Move the contents, then point every page at the object.
        var moved: [Chunk] = []
        for c in affected.map({ $0.slice(lo, hi) }) {
            if !c.lazy {
                let bytes = try backing.readPhysical(gpa: c.gpa, count: Int(c.size))
                object.write(offset: c.va - lo, bytes: bytes)
            }
            var n = c
            n.lazy = false
            n.gpa = gpa + (c.va - lo)
            n.file = nil
            n.shared = object
            n.fileOffset = c.va - lo
            n.readOnlyShared = false
            moved.append(n)
        }
        do {
            try pageTables.unmap(va: lo, size: hi - lo)
            for c in moved { try pageTables.map(va: c.va, pa: c.gpa, size: c.size, attributes: c.protection.el0PageAttributes) }
        } catch {
            throw mapPageTableError(error)
        }
        releaseAnonymous(affected, lo: lo, hi: hi)
        replaceChunks(lo, hi, with: moved)
        try commit()
        return (object, 0)
    }

    /// A VMM-owned anonymous mapping at a fixed VA (commpage, host page):
    /// allowed above `userVALimit`, never replaced, unmapped, or re-protected
    /// by guest operations.
    @discardableResult
    public func mapPermanentAnonymous(at va: UInt64, size: UInt64, protection: VMProtection) throws -> UInt64 {
        try map(file: nil, offset: 0, at: va, size: size, protection: protection, hint: nil, permanent: true)
    }

    public func unmap(va: UInt64, size: UInt64) throws {
        try mutex.withLock { try unmapLocked(va: va, size: size) }
    }

    private func unmapLocked(va: UInt64, size: UInt64) throws {
        try checkLive()
        let (lo, hi) = try checkedRange(va: va, size: size, permanent: false)
        let affected = chunks.overlapping(lo, hi)
        guard !affected.isEmpty else { return }
        guard !affected.contains(where: \.permanent) else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        do { try pageTables.unmap(va: lo, size: hi - lo) } catch { throw mapPageTableError(error) }
        releaseAnonymous(affected, lo: lo, hi: hi)
        replaceChunks(lo, hi, with: [])
        try commit()
    }

    public func protect(va: UInt64, size: UInt64, protection: VMProtection) throws {
        try mutex.withLock { try protectLocked(va: va, size: size, protection: protection) }
    }

    private func protectLocked(va: UInt64, size: UInt64, protection: VMProtection) throws {
        try checkLive()
        let (lo, hi) = try checkedRange(va: va, size: size, permanent: false)
        // Every page must be mapped (Darwin mprotect: ENOMEM otherwise).
        var affected = chunks.overlapping(lo, hi)
        try checkCovered(affected, lo, hi)
        guard !affected.contains(where: \.permanent) else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        if protection.contains(.write), affected.contains(where: \.readOnlyShared) {
            try privatize(lo, hi)
            affected = chunks.overlapping(lo, hi)
        }
        do {
            if affected.contains(where: \.lazy) {
                // Lazy parts have no page-table entries; their pages get the
                // new protection when they are first touched.
                for c in affected where !c.lazy {
                    let s = c.slice(lo, hi)
                    try pageTables.protect(va: s.va, size: s.size, attributes: protection.el0PageAttributes)
                }
            } else {
                try pageTables.protect(va: lo, size: hi - lo, attributes: protection.el0PageAttributes)
            }
        } catch {
            throw mapPageTableError(error)
        }
        replaceChunks(lo, hi, with: affected.map { c in
            var s = c.slice(lo, hi)
            s.protection = protection
            return s
        })
        try commit()
    }

    /// Drops every mapping and file reference at once, without changing the
    /// page tables or returning anonymous memory: for an address space whose
    /// VM is destroyed next. Afterwards every operation fails (reads and
    /// writes as unmapped, changes with ENOMEM). O(n).
    public func discardAll() {
        mutex.withLock {
            isDiscarded = true
            chunks.removeAll()
            readOnlySharedChunks = 0
            regionsCache = []
        }
    }

    // MARK: Memory access (GuestMemoryAccess)

    public func read(va: UInt64, count: Int) throws -> [UInt8] {
        try read(va: va, count: count, checkingEL0Access: requireEL0Access)
    }

    public func write(va: UInt64, bytes: [UInt8]) throws {
        try write(va: va, bytes: bytes, checkingEL0Access: requireEL0Access)
    }

    /// Splits [va, va+count) into physically contiguous pieces, one per page,
    /// checking every page first (TBI0: the top byte of `va` is ignored).
    private func physicalPieces(va: UInt64, count: Int, write: Bool, checkingEL0Access: Bool) throws -> [(pa: UInt64, count: Int)] {
        guard count >= 0, UInt64(count) <= UInt64.max - va else { throw GuestMemoryError.badRange(va: va, count: count) }
        var pieces: [(pa: UInt64, count: Int)] = []
        var cursor = va & VMLayout.addressWithoutTag
        if isDiscarded, count > 0 { throw GuestMemoryError.unmapped(va: cursor) }
        var remaining = UInt64(count)
        while remaining > 0 {
            if pageTables.translate(cursor) == nil { _ = materializeLocked(va: cursor) }
            guard let (pa, attributes) = pageTables.translate(cursor) else { throw GuestMemoryError.unmapped(va: cursor) }
            if checkingEL0Access {
                let ok = write ? attributes.access.isEL0Writable : attributes.access.isEL0Readable
                guard ok else { throw GuestMemoryError.accessDenied(va: cursor) }
            }
            let inPage = VMLayout.pageSize - (cursor & (VMLayout.pageSize - 1))
            let n = min(inPage, remaining)
            pieces.append((pa, Int(n)))
            cursor += n
            remaining -= n
        }
        return pieces
    }

    /// Reads with an explicit permission check choice.
    public func read(va: UInt64, count: Int, checkingEL0Access: Bool) throws -> [UInt8] {
        try mutex.withLock { try readLocked(va: va, count: count, checkingEL0Access: checkingEL0Access) }
    }

    private func readLocked(va: UInt64, count: Int, checkingEL0Access: Bool) throws -> [UInt8] {
        let pieces = try physicalPieces(va: va, count: count, write: false, checkingEL0Access: checkingEL0Access)
        if pieces.count == 1 { return try backing.readPhysical(gpa: pieces[0].pa, count: pieces[0].count) }
        var out: [UInt8] = []
        out.reserveCapacity(max(0, count))
        for piece in pieces { out += try backing.readPhysical(gpa: piece.pa, count: piece.count) }
        return out
    }

    /// Writes with an explicit permission check choice. Every page is checked
    /// before the first byte is written.
    public func write(va: UInt64, bytes: [UInt8], checkingEL0Access: Bool) throws {
        try mutex.withLock { try writeLocked(va: va, bytes: bytes, checkingEL0Access: checkingEL0Access) }
    }

    private func writeLocked(va: UInt64, bytes: [UInt8], checkingEL0Access: Bool) throws {
        if !checkingEL0Access, readOnlySharedChunks > 0, !bytes.isEmpty, !isDiscarded {
            // A VMM write into a shared read-only file view: those pages get
            // a private view first (with EL0 checks, such pages are never
            // EL0-writable, so the check below refuses the write anyway).
            let start = va & VMLayout.addressWithoutTag
            if UInt64(bytes.count) <= UInt64.max - start {
                let lo = start & ~Self.pageMask
                let end = start + UInt64(bytes.count)
                let hi = end > UInt64.max - Self.pageMask ? UInt64.max & ~Self.pageMask : (end + Self.pageMask) & ~Self.pageMask
                if chunks.overlapping(lo, hi).contains(where: \.readOnlyShared) {
                    try privatize(lo, hi)
                    try commit()
                }
            }
        }
        let pieces = try physicalPieces(va: va, count: bytes.count, write: true, checkingEL0Access: checkingEL0Access)
        var offset = 0
        try bytes.withUnsafeBytes { raw in
            for piece in pieces {
                try backing.writePhysical(gpa: piece.pa, from: UnsafeRawBufferPointer(rebasing: raw[offset..<(offset + piece.count)]))
                offset += piece.count
            }
        }
    }

    /// Reads a NUL-terminated string of at most `maxLength` bytes (without
    /// the NUL). Fails if no NUL is found within the limit.
    public func readCString(va: UInt64, maxLength: Int = DarwinFileSystem.maxPathLength) throws -> String {
        var out: [UInt8] = []
        var cursor = va
        while out.count < maxLength {
            let inPage = Int(VMLayout.pageSize - (cursor & (VMLayout.pageSize - 1)))
            let chunk = try read(va: cursor, count: min(inPage, maxLength - out.count))
            if let nul = chunk.firstIndex(of: 0) {
                out += chunk[..<nul]
                return String(decoding: out, as: UTF8.self)
            }
            out += chunk
            cursor += UInt64(chunk.count)
        }
        throw DarwinErrnoError(DarwinErrnoCode.ENAMETOOLONG)
    }

    /// Writes the tables changed since the last write (for example the EL1
    /// identity regions added before `init`) and bumps `generation` if any.
    public func flushPageTables() throws {
        try mutex.withLock { try flushLocked() }
    }

    private func flushLocked() throws {
        guard pageTables.hasDirtyTables else { return }
        generation &+= 1
        // Bumped before the write: a failed write still flushes.
        let invalidations = pageTables.invalidatingChanges
        let span = pageTables.takeInvalidatedSpan()
        if Self.flushOnAdditions || invalidations != writtenInvalidations {
            tlbGeneration &+= 1
            writtenInvalidations = invalidations
            lastInvalidatedSpan = Self.flushOnAdditions ? nil : span
        }
        let backing = self.backing
        try pageTables.writeDirtyTables { gpa, bytes in try backing.writePhysical(gpa: gpa, from: bytes) }
    }

    public func tlbRange(since: UInt64) -> TLBRange? {
        mutex.withLock {
            guard tlbGeneration == since &+ 1, let span = lastInvalidatedSpan else { return nil }
            return TLBRange(va: span.lowerBound, pages: (span.upperBound - span.lowerBound) >> VMLayout.pageShift)
        }
    }

    // MARK: Lazy anonymous memory

    /// Anonymous mappings of at least this size are lazy: backing comes per
    /// block when a page is first touched (`YCODE_LAZY_ANON_MB`, default
    /// 256 MiB; 0 turns it off).
    public static let lazyAnonymousThreshold: UInt64 = {
        if let v = getenv("YCODE_LAZY_ANON_MB"), let mb = UInt64(String(cString: v)) {
            return mb == 0 ? UInt64.max : mb << 20
        }
        return 256 << 20
    }()
    /// The unit in which a lazy mapping gets backing (aligned, clipped to
    /// the mapping): 256 KiB, 16 pages.
    public static let lazyBlockSize: UInt64 = 256 << 10
    /// Lazy blocks given backing so far (statistics).
    public private(set) var lazyBlocksMaterialized: UInt64 = 0

    public func resolveTranslationFault(va: UInt64) -> Bool {
        mutex.withLock {
            guard !isDiscarded else { return false }
            let page = va & VMLayout.addressWithoutTag
            guard pageTables.translate(page) == nil else { return false }
            return materializeLocked(va: page)
        }
    }

    /// Gives the block around `va` of a lazy mapping its backing, with the
    /// mapping's protection. False when `va` is not in a lazy mapping, the
    /// mapping allows no access, or no memory is left.
    private func materializeLocked(va: UInt64) -> Bool {
        guard !isDiscarded, let c = chunks.element(containing: va), c.lazy, c.protection != .none else { return false }
        let block = Self.lazyBlockSize
        let lo = max(c.va, va & ~(block - 1))
        let hi = min(c.end, (va & ~(block - 1)) + block)
        let size = hi - lo
        let gpa: UInt64
        do { gpa = try backing.allocateAnonymous(size: size) } catch {
            MapFailureLog.note("backing for a touched lazy block of 0x\(String(size, radix: 16)) bytes at 0x\(String(lo, radix: 16)): \(error)")
            return false
        }
        do {
            try pageTables.map(va: lo, pa: gpa, size: size, attributes: c.protection.el0PageAttributes)
        } catch {
            backing.release(gpa: gpa, size: size)
            MapFailureLog.note("page tables for a touched lazy block at 0x\(String(lo, radix: 16)): \(error)")
            return false
        }
        var b = c.slice(lo, hi)
        b.lazy = false
        b.gpa = gpa
        replaceChunks(lo, hi, with: [b])
        lazyBlocksMaterialized += 1
        do { try commit() } catch { return false }
        return true
    }

    // MARK: Implementation

    private static let pageMask = VMLayout.pageSize - 1

    private func checkLive() throws {
        if isDiscarded { throw DarwinErrnoError(DarwinErrnoCode.ENOMEM) }
    }

    /// Validates and rounds a range; returns [lo, hi).
    private func checkedRange(va: UInt64, size: UInt64, permanent: Bool) throws -> (UInt64, UInt64) {
        guard va & Self.pageMask == 0, size > 0 else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        guard size <= UInt64.max - Self.pageMask else { throw DarwinErrnoError(DarwinErrnoCode.ENOMEM) }
        let rounded = (size + Self.pageMask) & ~Self.pageMask
        let limit = permanent ? UInt64(1) << VMLayout.virtualAddressBits : VMLayout.userVALimit
        guard va >= VMLayout.userVAFloor, va < limit, rounded <= limit - va else {
            throw DarwinErrnoError(DarwinErrnoCode.ENOMEM)
        }
        return (va, va + rounded)
    }

    /// ENOMEM unless `affected` (ascending) covers all of [lo, hi).
    private func checkCovered(_ affected: [Chunk], _ lo: UInt64, _ hi: UInt64) throws {
        var cursor = lo
        for c in affected {
            guard c.va <= cursor else { throw DarwinErrnoError(DarwinErrnoCode.ENOMEM) }
            cursor = max(cursor, c.end)
        }
        guard cursor >= hi else { throw DarwinErrnoError(DarwinErrnoCode.ENOMEM) }
    }

    private func map(file: GuestFile?, shared: SharedMemoryObject? = nil, offset: UInt64, at: UInt64?, size: UInt64,
                     protection: VMProtection, hint: UInt64?, permanent: Bool) throws -> UInt64 {
        try mutex.withLock {
            try mapLocked(file: file, shared: shared, offset: offset, at: at, size: size, protection: protection, hint: hint,
                          permanent: permanent)
        }
    }

    private func mapLocked(file: GuestFile?, shared: SharedMemoryObject? = nil, offset: UInt64, at: UInt64?, size: UInt64,
                           protection: VMProtection, hint: UInt64?, permanent: Bool) throws -> UInt64 {
        try checkLive()
        guard size > 0 else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        guard offset & Self.pageMask == 0 else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        guard size <= UInt64.max - Self.pageMask else { throw DarwinErrnoError(DarwinErrnoCode.ENOMEM) }
        let rounded = (size + Self.pageMask) & ~Self.pageMask
        guard offset <= UInt64.max - rounded else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }

        let lo: UInt64, hi: UInt64
        if let at {
            (lo, hi) = try checkedRange(va: at, size: rounded, permanent: permanent)
        } else {
            lo = try findFree(size: rounded, hint: hint)
            hi = lo + rounded
        }
        let replaced = chunks.overlapping(lo, hi)
        guard !replaced.contains(where: \.permanent) else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        if file == nil, shared == nil, !permanent, rounded >= Self.lazyAnonymousThreshold {
            // A large anonymous mapping (a reservation such as JavaScriptCore's
            // 32 GiB cage; app-launch.md §3.2): no backing and no page-table
            // entries until a page is touched (`resolveTranslationFault`).
            if !replaced.isEmpty { do { try pageTables.unmap(va: lo, size: rounded) } catch { throw mapPageTableError(error) } }
            releaseAnonymous(replaced, lo: lo, hi: hi)
            replaceChunks(lo, hi, with: [Chunk(va: lo, size: rounded, protection: protection, gpa: 0, file: nil,
                                               fileOffset: 0, shared: nil, permanent: false, lazy: true)])
            try commit()
            return lo
        }
        do { try pageTables.checkCapacity(va: lo, size: rounded) } catch {
            MapFailureLog.note("page tables for 0x\(String(rounded, radix: 16)) bytes at 0x\(String(lo, radix: 16)): \(error)")
            throw mapPageTableError(error)
        }

        var readOnlyShared = false
        let gpa: UInt64
        do {
            if let shared {
                gpa = try backing.mapShared(shared) + offset
            } else if let file {
                if !protection.contains(.write), let view = try backing.mapFileReadOnly(file, offset: offset, size: rounded) {
                    gpa = view
                    readOnlyShared = true
                } else {
                    gpa = try backing.mapFile(file, offset: offset, size: rounded)
                }
            } else {
                gpa = try backing.allocateAnonymous(size: rounded)
            }
        } catch let e as DarwinErrnoError {
            MapFailureLog.note("backing for 0x\(String(rounded, radix: 16)) bytes (\(file?.guestPath ?? (shared != nil ? "shared" : "anonymous"))): \(e)")
            throw e
        } catch {
            MapFailureLog.note("backing for 0x\(String(rounded, radix: 16)) bytes (\(file?.guestPath ?? (shared != nil ? "shared" : "anonymous"))): \(error)")
            throw DarwinErrnoError(DarwinErrnoCode.ENOMEM)
        }

        do {
            guard gpa < 1 << VMLayout.physicalAddressBits, rounded <= (1 << VMLayout.physicalAddressBits) - gpa else {
                throw PageTableError.physicalAddressOutOfRange(pa: gpa, size: rounded)
            }
            if !replaced.isEmpty { try pageTables.unmap(va: lo, size: rounded) }
            try pageTables.map(va: lo, pa: gpa, size: rounded, attributes: protection.el0PageAttributes)
        } catch {
            if shared == nil && !readOnlyShared { backing.release(gpa: gpa, size: rounded) }
            throw mapPageTableError(error)
        }
        releaseAnonymous(replaced, lo: lo, hi: hi)
        replaceChunks(lo, hi, with: [Chunk(va: lo, size: rounded, protection: protection, gpa: gpa, file: file,
                                           fileOffset: offset, shared: shared, permanent: permanent,
                                           readOnlyShared: readOnlyShared)])
        try commit()
        return lo
    }

    /// Moves the shared read-only file pages of [lo, hi) (page-aligned) to
    /// private copy-on-write views of the same file bytes. Same protections.
    private func privatize(_ lo: UInt64, _ hi: UInt64) throws {
        for c in chunks.overlapping(lo, hi) where c.readOnlyShared {
            var s = c.slice(lo, hi)
            guard let file = s.file else { continue }
            let gpa: UInt64
            do { gpa = try backing.mapFile(file, offset: s.fileOffset, size: s.size) } catch let e as DarwinErrnoError {
                throw e
            } catch {
                throw DarwinErrnoError(DarwinErrnoCode.ENOMEM)
            }
            do {
                try pageTables.unmap(va: s.va, size: s.size)
                try pageTables.map(va: s.va, pa: gpa, size: s.size, attributes: s.protection.el0PageAttributes)
            } catch {
                throw mapPageTableError(error)
            }
            s.gpa = gpa
            s.readOnlyShared = false
            replaceChunks(s.va, s.end, with: [s])
            privatizedPages += s.size / VMLayout.pageSize
        }
    }

    /// Replaces the mappings in [lo, hi) with `inside` (which must lie in
    /// it); mappings that straddle a bound keep their outside parts.
    private func replaceChunks(_ lo: UInt64, _ hi: UInt64, with inside: [Chunk]) {
        for c in chunks.extract(lo, hi) {
            if c.readOnlyShared { readOnlySharedChunks -= 1 }
            if c.va < lo { insertChunk(c.slice(c.va, lo)) }
            if c.end > hi { insertChunk(c.slice(hi, c.end)) }
        }
        for c in inside { insertChunk(c) }
        regionsCache = nil
    }

    private func insertChunk(_ c: Chunk) {
        if c.readOnlyShared { readOnlySharedChunks += 1 }
        chunks.insert(c)
    }

    /// First fit for `size` bytes at or above `max(hint, anonymousVABase)`.
    private func findFree(size: UInt64, hint: UInt64?) throws -> UInt64 {
        let base = VMLayout.anonymousVABase
        var start = max(hint ?? base, base)
        if start > UInt64.max - Self.pageMask { start = VMLayout.userVALimit }
        start = (start + Self.pageMask) & ~Self.pageMask
        if let va = firstFit(size: size, from: start) { return va }
        if start > base, let va = firstFit(size: size, from: base) { return va }
        throw DarwinErrnoError(DarwinErrnoCode.ENOMEM)
    }

    /// The lowest va >= `start` with [va, va+size) below `userVALimit`, free
    /// of mappings, and outside every exclusion. O(log n) per exclusion.
    private func firstFit(size: UInt64, from start: UInt64) -> UInt64? {
        let limit = VMLayout.userVALimit
        var a = start
        for ex in sortedExclusions + [limit..<limit] {
            guard a < limit else { return nil }
            if ex.upperBound <= a && ex.lowerBound < limit { continue }
            let b = min(ex.lowerBound, limit)
            if b > a, let p = chunks.firstGap(from: a, size: size), p < b, size <= b - p { return p }
            a = max(a, ex.upperBound)
        }
        return nil
    }

    private func releaseAnonymous(_ affected: [Chunk], lo: UInt64, hi: UInt64) {
        for c in affected where c.isReleasable {
            let s = c.slice(lo, hi)
            backing.release(gpa: s.gpa, size: s.size)
        }
    }

    private func commit() throws {
        try flushLocked()
    }

    private func mapPageTableError(_ error: Error) -> Error {
        guard let e = error as? PageTableError else { return error }
        switch e {
        case .arenaExhausted: return DarwinErrnoError(DarwinErrnoCode.ENOMEM)
        case .notMapped: return DarwinErrnoError(DarwinErrnoCode.ENOMEM)
        case .virtualAddressOutOfRange, .physicalAddressOutOfRange: return DarwinErrnoError(DarwinErrnoCode.ENOMEM)
        case .unaligned, .emptyRange, .alreadyMapped: return DarwinErrnoError(DarwinErrnoCode.EINVAL)
        }
    }
}

/// Diagnostics: the first guest mappings that failed for a host-side
/// reason (memory backing or page tables), with the underlying error, on
/// stderr. Process-wide, at most `limit` lines.
public enum MapFailureLog {
    nonisolated(unsafe) private static var count = 0
    private static let lock = NSLock()
    /// The most failures written; later ones are counted but not shown.
    public static let limit = 40
    static func note(_ text: String) {
        lock.lock(); count += 1; let n = count; lock.unlock()
        guard n <= limit else { return }
        FileHandle.standardError.write(("ycode-simd: guest mapping failed: " + text + (n == limit ? " (further failures not shown)" : "") + "\n").data(using: .utf8)!)
    }
}

// MARK: - FakePhysicalBacking

public struct FakePhysicalBackingError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// An in-memory `PhysicalBacking` for tests. It backs RAM (memslot 0), the
/// anonymous pool, and file slots with sparse 16 KiB pages that read as
/// zero until written. Anonymous memory comes from a first-fit allocator
/// over the pool; file slots are bump-allocated from `fileSlotGPABase` and
/// filled by reading the host file (zero past its end). With
/// `sharedReadOnlyFiles`, `mapFileReadOnly` serves one read-only copy of each
/// file (by host path and size) that every later read-only request reuses,
/// and writes to it fail.
public final class FakePhysicalBacking: PhysicalBacking {
    public struct FileSlot: Equatable, Sendable {
        public var gpa: UInt64
        public var size: UInt64
        public var path: String
        public var offset: UInt64
    }

    public let ramGPA: UInt64
    public let ramSize: UInt64
    public let anonymousPoolGPA: UInt64
    public let anonymousPoolSize: UInt64
    public let fileSlotGPABase: UInt64
    public let sharedReadOnlyFiles: Bool

    private var pages: [UInt64: [UInt8]] = [:]
    private let pool: RangeAllocator
    /// Anonymous bytes currently allocated.
    public var anonymousBytesInUse: UInt64 { pool.bytesInUse }
    private var nextFileSlotGPA: UInt64
    public private(set) var fileSlots: [FileSlot] = []
    /// Read-only file views: (host path, size) -> GPA of offset 0.
    private var readOnlyViews: [String: (gpa: UInt64, span: UInt64)] = [:]
    private let readOnlyRanges = IntervalMap<PlainInterval>()
    /// `mapFileReadOnly` calls answered with a view.
    public private(set) var readOnlyViewRequests = 0
    /// Shared objects visible in this space: GPA ranges served by the object's memory.
    private var sharedSlots: [(gpa: UInt64, object: SharedMemoryObject)] = []
    /// Every `writePhysical` call, in order (for checking table writes).
    public var writeLog: [(gpa: UInt64, count: Int)] = []

    public init(ramGPA: UInt64 = VMLayout.ramGPA, ramSize: UInt64 = VMLayout.stage3RAMSize,
                anonymousPoolGPA: UInt64 = VMLayout.anonymousPoolGPA, anonymousPoolSize: UInt64 = VMLayout.anonymousPoolSize,
                fileSlotGPABase: UInt64 = VMLayout.fileSlotGPABase, sharedReadOnlyFiles: Bool = false) {
        self.ramGPA = ramGPA
        self.ramSize = ramSize
        self.anonymousPoolGPA = anonymousPoolGPA
        self.anonymousPoolSize = anonymousPoolSize
        self.fileSlotGPABase = fileSlotGPABase
        self.sharedReadOnlyFiles = sharedReadOnlyFiles
        self.nextFileSlotGPA = fileSlotGPABase
        self.pool = RangeAllocator(base: anonymousPoolGPA, size: anonymousPoolSize)
    }

    public func allocateAnonymous(size: UInt64) throws -> UInt64 {
        guard size > 0, VMLayout.isPageAligned(size) else { throw FakePhysicalBackingError("bad anonymous size \(hex(size))") }
        guard let gpa = pool.allocate(size) else { throw DarwinErrnoError(DarwinErrnoCode.ENOMEM) }
        return gpa
    }

    private func fill(gpa: UInt64, file: GuestFile, offset: UInt64, size: UInt64) throws {
        let page = VMLayout.pageSize
        var o: UInt64 = 0
        while o < size {
            let bytes = try file.read(count: Int(page), offset: offset + o)
            if bytes.contains(where: { $0 != 0 }) {
                pages[gpa + o] = bytes + [UInt8](repeating: 0, count: Int(page) - bytes.count)
            }
            if bytes.count < Int(page) { break }
            o += page
        }
    }

    public func mapFile(_ file: GuestFile, offset: UInt64, size: UInt64) throws -> UInt64 {
        guard size > 0, VMLayout.isPageAligned(size), VMLayout.isPageAligned(offset) else {
            throw FakePhysicalBackingError("bad file mapping offset \(hex(offset)) size \(hex(size))")
        }
        let gpa = nextFileSlotGPA
        nextFileSlotGPA += size
        try fill(gpa: gpa, file: file, offset: offset, size: size)
        fileSlots.append(FileSlot(gpa: gpa, size: size, path: file.guestPath, offset: offset))
        return gpa
    }

    public func mapFileReadOnly(_ file: GuestFile, offset: UInt64, size: UInt64) throws -> UInt64? {
        guard sharedReadOnlyFiles else { return nil }
        guard size > 0, VMLayout.isPageAligned(size), VMLayout.isPageAligned(offset) else {
            throw FakePhysicalBackingError("bad file mapping offset \(hex(offset)) size \(hex(size))")
        }
        let key = "\(file.hostPath)#\(file.size)"
        let view: (gpa: UInt64, span: UInt64)
        if let v = readOnlyViews[key] {
            view = v
        } else {
            let span = (file.size + VMLayout.pageSize - 1) & ~(VMLayout.pageSize - 1)
            guard span > 0 else { return nil }
            view = (nextFileSlotGPA, span)
            nextFileSlotGPA += span
            try fill(gpa: view.gpa, file: file, offset: 0, size: span)
            readOnlyViews[key] = view
            readOnlyRanges.insert(PlainInterval(start: view.gpa, end: view.gpa + span))
        }
        guard offset <= view.span, size <= view.span - offset else { return nil }
        readOnlyViewRequests += 1
        return view.gpa + offset
    }

    public func mapShared(_ object: SharedMemoryObject) throws -> UInt64 {
        if let slot = sharedSlots.first(where: { $0.object === object }) { return slot.gpa }
        let gpa = nextFileSlotGPA
        nextFileSlotGPA += object.size
        sharedSlots.append((gpa, object))
        return gpa
    }

    private func sharedSlot(_ gpa: UInt64) -> (gpa: UInt64, object: SharedMemoryObject)? {
        sharedSlots.first { gpa >= $0.gpa && gpa - $0.gpa < $0.object.size }
    }

    /// Releases of pool ranges that were not entirely allocated (a double
    /// release, or a release of memory never handed out): the real backing
    /// ignores them, but each one is a bug in the caller.
    public private(set) var releaseViolations: [String] = []

    /// Releases the allocated parts of [gpa, gpa+size); their pages read as zero.
    public func release(gpa: UInt64, size: UInt64) {
        guard size > 0 else { return }
        if gpa >= anonymousPoolGPA, gpa - anonymousPoolGPA < anonymousPoolSize, !pool.isAllocated(gpa, size) {
            releaseViolations.append("release of \(hex(gpa))+\(hex(size)), not entirely allocated")
        }
        for r in pool.free(gpa, size) {
            var p = r.lowerBound
            while p < r.upperBound {
                pages[p] = nil
                p += VMLayout.pageSize
            }
        }
    }

    private func isBacked(_ gpa: UInt64) -> Bool {
        if gpa >= ramGPA && gpa - ramGPA < ramSize { return true }
        if gpa >= anonymousPoolGPA && gpa - anonymousPoolGPA < anonymousPoolSize { return true }
        return gpa >= fileSlotGPABase && gpa < nextFileSlotGPA
    }

    public func readPhysical(gpa: UInt64, count: Int) throws -> [UInt8] {
        guard count >= 0 else { throw FakePhysicalBackingError("negative read") }
        var out: [UInt8] = []
        out.reserveCapacity(count)
        var cursor = gpa
        var remaining = count
        while remaining > 0 {
            guard isBacked(cursor) else { throw FakePhysicalBackingError("gpa \(hex(cursor)) is not backed") }
            let base = cursor & ~(VMLayout.pageSize - 1)
            let inPage = Int(cursor - base)
            let n = min(remaining, Int(VMLayout.pageSize) - inPage)
            if let slot = sharedSlot(cursor) {
                out += slot.object.read(offset: cursor - slot.gpa, count: n)
            } else if let page = pages[base] { out += page[inPage..<(inPage + n)] } else { out += repeatElement(0, count: n) }
            cursor += UInt64(n)
            remaining -= n
        }
        return out
    }

    public func writePhysical(gpa: UInt64, bytes: [UInt8]) throws {
        if !bytes.isEmpty, readOnlyRanges.intersects(gpa, gpa + UInt64(bytes.count)) {
            throw FakePhysicalBackingError("write to read-only file memory at gpa \(hex(gpa))")
        }
        var cursor = gpa
        var offset = 0
        while offset < bytes.count {
            guard isBacked(cursor) else { throw FakePhysicalBackingError("gpa \(hex(cursor)) is not backed") }
            let base = cursor & ~(VMLayout.pageSize - 1)
            let inPage = Int(cursor - base)
            let n = min(bytes.count - offset, Int(VMLayout.pageSize) - inPage)
            if let slot = sharedSlot(cursor) {
                slot.object.write(offset: cursor - slot.gpa, bytes: Array(bytes[offset..<(offset + n)]))
                cursor += UInt64(n)
                offset += n
                continue
            }
            var page = pages[base] ?? [UInt8](repeating: 0, count: Int(VMLayout.pageSize))
            page.replaceSubrange(inPage..<(inPage + n), with: bytes[offset..<(offset + n)])
            pages[base] = page
            cursor += UInt64(n)
            offset += n
        }
        writeLog.append((gpa, bytes.count))
    }
}
