// The guest's virtual address space in stage 3: an allocator over the VA
// map, the stage-1 tables that describe it, and the physical backing that
// the hypervisor (or an in-memory fake) supplies.
// Contract: specs/simulator/stage3-contract.md §2, §3, §4.

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
    /// Returns anonymous pages to the pool. They must read as zero when
    /// allocated again.
    func release(gpa: UInt64, size: UInt64)
    func readPhysical(gpa: UInt64, count: Int) throws -> [UInt8]
    func writePhysical(gpa: UInt64, bytes: [UInt8]) throws
}

// MARK: - Regions

/// One mapping of the address space, for tracing and region queries.
public struct GuestRegion: Equatable, Hashable, Sendable, CustomStringConvertible {
    public enum Backing: Equatable, Hashable, Sendable {
        case anonymous(gpa: UInt64)
        case file(path: String, offset: UInt64, gpa: UInt64)
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
        case let .anonymous(gpa), let .file(_, _, gpa): gpa
        }
    }

    public var backingDescription: String {
        switch backing {
        case let .anonymous(gpa): "anonymous gpa \(hex(gpa))"
        case let .file(path, offset, gpa): "\(path) @\(hex(offset)) gpa \(hex(gpa))"
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
    /// The mappings, ascending by VA.
    var regions: [GuestRegion] { get }
    /// Bumps on every page-table change.
    var generation: UInt64 { get }
}

extension GuestVirtualMemory {
    /// The mapping that contains `va`, if any.
    public func region(containing va: UInt64) -> GuestRegion? {
        regions.first { $0.va <= va && va < $0.end }
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
public final class GuestAddressSpace: GuestVirtualMemory {
    private struct Chunk {
        var va: UInt64
        var size: UInt64
        var protection: VMProtection
        var gpa: UInt64
        var file: GuestFile?
        var fileOffset: UInt64
        var permanent: Bool
        var end: UInt64 { va + size }

        /// The part of this chunk in [lo, hi), which must intersect it.
        func slice(_ lo: UInt64, _ hi: UInt64) -> Chunk {
            let start = max(lo, va), stop = min(hi, end)
            var c = self
            c.va = start
            c.size = stop - start
            c.gpa = gpa + (start - va)
            c.fileOffset = fileOffset + (start - va)
            return c
        }
    }

    public let backing: any PhysicalBacking
    public private(set) var pageTables: PageTableBuilder
    public private(set) var generation: UInt64 = 0
    /// When true (the default), `read`/`write` need EL0 access to each page,
    /// as a kernel's copyin/copyout would. The VMM turns it off to fill
    /// read-only pages.
    public var requireEL0Access: Bool

    /// VA ranges that "anywhere" placement never uses.
    public let anywhereExclusions: [Range<UInt64>] = [
        VMLayout.sharedRegionBase..<VMLayout.sharedRegionEnd,
        VMLayout.commpageReservationBase..<VMLayout.commpageReservationEnd,
    ]

    /// Sorted by VA, non-overlapping.
    private var chunks: [Chunk] = []

    /// `pageTables` may already hold the EL1 identity regions (they live
    /// below `userVAFloor`, where guest mappings never go). Its dirty tables
    /// are written on the first change or by `flushPageTables()`.
    public init(backing: any PhysicalBacking, pageTables: PageTableBuilder = .stage3(), requireEL0Access: Bool = true) {
        self.backing = backing
        self.pageTables = pageTables
        self.requireEL0Access = requireEL0Access
    }

    // MARK: Queries

    public var regions: [GuestRegion] {
        chunks.map { c in
            GuestRegion(va: c.va, size: c.size, protection: c.protection,
                        backing: c.file.map { .file(path: $0.guestPath, offset: c.fileOffset, gpa: c.gpa) } ?? .anonymous(gpa: c.gpa),
                        permanent: c.permanent)
        }
    }

    /// The file mapped at `va`, if the mapping there is file-backed.
    public func file(at va: UInt64) -> GuestFile? {
        chunks.first { $0.va <= va && va < $0.end }?.file
    }

    // MARK: GuestVirtualMemory

    public func mapAnonymous(at: UInt64?, size: UInt64, protection: VMProtection, hint: UInt64?) throws -> UInt64 {
        try map(file: nil, offset: 0, at: at, size: size, protection: protection, hint: hint, permanent: false)
    }

    public func mapFile(_ file: GuestFile, offset: UInt64, at: UInt64?, size: UInt64, protection: VMProtection, hint: UInt64?) throws -> UInt64 {
        try map(file: file, offset: offset, at: at, size: size, protection: protection, hint: hint, permanent: false)
    }

    /// A VMM-owned anonymous mapping at a fixed VA (commpage, host page):
    /// allowed above `userVALimit`, never replaced, unmapped, or re-protected
    /// by guest operations.
    @discardableResult
    public func mapPermanentAnonymous(at va: UInt64, size: UInt64, protection: VMProtection) throws -> UInt64 {
        try map(file: nil, offset: 0, at: va, size: size, protection: protection, hint: nil, permanent: true)
    }

    public func unmap(va: UInt64, size: UInt64) throws {
        let (lo, hi) = try checkedRange(va: va, size: size, permanent: false)
        let affected = chunks.filter { $0.va < hi && lo < $0.end }
        guard !affected.isEmpty else { return }
        guard !affected.contains(where: \.permanent) else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        var pt = pageTables
        try unmapPages(of: affected, lo: lo, hi: hi, in: &pt)
        releaseAnonymous(affected, lo: lo, hi: hi)
        chunks = carve(chunks, lo: lo, hi: hi)
        try commit(pt)
    }

    public func protect(va: UInt64, size: UInt64, protection: VMProtection) throws {
        let (lo, hi) = try checkedRange(va: va, size: size, permanent: false)
        // Every page must be mapped (Darwin mprotect: ENOMEM otherwise).
        var cursor = lo
        let affected = chunks.filter { $0.va < hi && lo < $0.end }
        for c in affected {
            guard c.va <= cursor else { throw DarwinErrnoError(DarwinErrnoCode.ENOMEM) }
            cursor = max(cursor, c.end)
        }
        guard cursor >= hi else { throw DarwinErrnoError(DarwinErrnoCode.ENOMEM) }
        guard !affected.contains(where: \.permanent) else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        var pt = pageTables
        do {
            try pt.protect(va: lo, size: hi - lo, attributes: protection.el0PageAttributes)
        } catch {
            throw mapPageTableError(error)
        }
        var updated = carve(chunks, lo: lo, hi: hi)
        for var c in affected.map({ $0.slice(lo, hi) }) {
            c.protection = protection
            updated.append(c)
        }
        chunks = updated.sorted { $0.va < $1.va }
        try commit(pt)
    }

    // MARK: Memory access (GuestMemoryAccess)

    private func translator(requireEL0Access: Bool) -> TranslatingGuestMemory {
        let backing = self.backing
        return TranslatingGuestMemory(
            pageTables: pageTables,
            requireEL0Access: requireEL0Access,
            readPhysical: { pa, count in try backing.readPhysical(gpa: pa, count: count) },
            writePhysical: { pa, bytes in try backing.writePhysical(gpa: pa, bytes: Array(bytes)) })
    }

    public func read(va: UInt64, count: Int) throws -> [UInt8] {
        try read(va: va, count: count, checkingEL0Access: requireEL0Access)
    }

    public func write(va: UInt64, bytes: [UInt8]) throws {
        try write(va: va, bytes: bytes, checkingEL0Access: requireEL0Access)
    }

    /// Reads with an explicit permission check choice.
    public func read(va: UInt64, count: Int, checkingEL0Access: Bool) throws -> [UInt8] {
        try translator(requireEL0Access: checkingEL0Access).read(va: va, count: count)
    }

    /// Writes with an explicit permission check choice. Every page is checked
    /// before the first byte is written.
    public func write(va: UInt64, bytes: [UInt8], checkingEL0Access: Bool) throws {
        let t = translator(requireEL0Access: checkingEL0Access)
        _ = try t.physicalPieces(va: va, count: bytes.count, write: true)
        try t.write(va: va, bytes: bytes)
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
        let dirty = pageTables.drainDirtyTables()
        guard !dirty.isEmpty else { return }
        generation &+= 1
        for t in dirty { try backing.writePhysical(gpa: t.gpa, bytes: t.bytes) }
    }

    // MARK: Implementation

    private static let pageMask = VMLayout.pageSize - 1

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

    private func map(file: GuestFile?, offset: UInt64, at: UInt64?, size: UInt64, protection: VMProtection,
                     hint: UInt64?, permanent: Bool) throws -> UInt64 {
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
        let replaced = chunks.filter { $0.va < hi && lo < $0.end }
        guard !replaced.contains(where: \.permanent) else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }

        let gpa: UInt64
        do {
            if let file {
                gpa = try backing.mapFile(file, offset: offset, size: rounded)
            } else {
                gpa = try backing.allocateAnonymous(size: rounded)
            }
        } catch let e as DarwinErrnoError {
            throw e
        } catch {
            throw DarwinErrnoError(DarwinErrnoCode.ENOMEM)
        }

        var pt = pageTables
        do {
            try unmapPages(of: replaced, lo: lo, hi: hi, in: &pt)
            try pt.map(va: lo, pa: gpa, size: rounded, attributes: protection.el0PageAttributes)
        } catch {
            if file == nil { backing.release(gpa: gpa, size: rounded) }
            throw mapPageTableError(error)
        }
        releaseAnonymous(replaced, lo: lo, hi: hi)
        var updated = carve(chunks, lo: lo, hi: hi)
        updated.append(Chunk(va: lo, size: rounded, protection: protection, gpa: gpa, file: file,
                             fileOffset: offset, permanent: permanent))
        chunks = updated.sorted { $0.va < $1.va }
        try commit(pt)
        return lo
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

    private func firstFit(size: UInt64, from start: UInt64) -> UInt64? {
        let limit = VMLayout.userVALimit
        let obstacles = (chunks.map { $0.va..<$0.end } + anywhereExclusions).sorted { $0.lowerBound < $1.lowerBound }
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

    /// Clears the pages of `affected` that lie in [lo, hi).
    private func unmapPages(of affected: [Chunk], lo: UInt64, hi: UInt64, in pt: inout PageTableBuilder) throws {
        for c in affected {
            let s = c.slice(lo, hi)
            do { try pt.unmap(va: s.va, size: s.size) } catch { throw mapPageTableError(error) }
        }
    }

    private func releaseAnonymous(_ affected: [Chunk], lo: UInt64, hi: UInt64) {
        for c in affected where c.file == nil {
            let s = c.slice(lo, hi)
            backing.release(gpa: s.gpa, size: s.size)
        }
    }

    /// `list` without [lo, hi): chunks that straddle a bound are split.
    private func carve(_ list: [Chunk], lo: UInt64, hi: UInt64) -> [Chunk] {
        var out: [Chunk] = []
        for c in list {
            if c.end <= lo || c.va >= hi {
                out.append(c)
                continue
            }
            if c.va < lo { out.append(c.slice(c.va, lo)) }
            if c.end > hi { out.append(c.slice(hi, c.end)) }
        }
        return out
    }

    private func commit(_ pt: PageTableBuilder) throws {
        pageTables = pt
        try flushPageTables()
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

// MARK: - FakePhysicalBacking

public struct FakePhysicalBackingError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// An in-memory `PhysicalBacking` for tests. It backs RAM (memslot 0), the
/// anonymous pool, and file slots with sparse 16 KiB pages that read as
/// zero until written. Anonymous memory comes from a first-fit free list
/// over the pool; file slots are bump-allocated from `fileSlotGPABase` and
/// filled by reading the host file (zero past its end).
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

    private var pages: [UInt64: [UInt8]] = [:]
    /// Free anonymous ranges, sorted and coalesced.
    private var free: [Range<UInt64>]
    private var nextFileSlotGPA: UInt64
    public private(set) var fileSlots: [FileSlot] = []
    /// Every `writePhysical` call, in order (for checking table writes).
    public var writeLog: [(gpa: UInt64, count: Int)] = []

    public init(ramGPA: UInt64 = VMLayout.ramGPA, ramSize: UInt64 = VMLayout.stage3RAMSize,
                anonymousPoolGPA: UInt64 = VMLayout.anonymousPoolGPA, anonymousPoolSize: UInt64 = VMLayout.anonymousPoolSize,
                fileSlotGPABase: UInt64 = VMLayout.fileSlotGPABase) {
        self.ramGPA = ramGPA
        self.ramSize = ramSize
        self.anonymousPoolGPA = anonymousPoolGPA
        self.anonymousPoolSize = anonymousPoolSize
        self.fileSlotGPABase = fileSlotGPABase
        self.free = [anonymousPoolGPA..<(anonymousPoolGPA + anonymousPoolSize)]
        self.nextFileSlotGPA = fileSlotGPABase
    }

    /// Anonymous bytes currently allocated.
    public var anonymousBytesInUse: UInt64 {
        anonymousPoolSize - free.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    public func allocateAnonymous(size: UInt64) throws -> UInt64 {
        guard size > 0, VMLayout.isPageAligned(size) else { throw FakePhysicalBackingError("bad anonymous size \(hex(size))") }
        guard let i = free.firstIndex(where: { $0.upperBound - $0.lowerBound >= size }) else {
            throw DarwinErrnoError(DarwinErrnoCode.ENOMEM)
        }
        let gpa = free[i].lowerBound
        if free[i].upperBound - gpa == size { free.remove(at: i) } else { free[i] = (gpa + size)..<free[i].upperBound }
        return gpa
    }

    public func mapFile(_ file: GuestFile, offset: UInt64, size: UInt64) throws -> UInt64 {
        guard size > 0, VMLayout.isPageAligned(size), VMLayout.isPageAligned(offset) else {
            throw FakePhysicalBackingError("bad file mapping offset \(hex(offset)) size \(hex(size))")
        }
        let gpa = nextFileSlotGPA
        nextFileSlotGPA += size
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
        fileSlots.append(FileSlot(gpa: gpa, size: size, path: file.guestPath, offset: offset))
        return gpa
    }

    public func release(gpa: UInt64, size: UInt64) {
        guard size > 0 else { return }
        var p = gpa
        while p < gpa + size {
            pages[p] = nil
            p += VMLayout.pageSize
        }
        free.append(gpa..<(gpa + size))
        free.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<UInt64>] = []
        for r in free {
            if let last = merged.last, last.upperBound >= r.lowerBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        free = merged
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
            if let page = pages[base] { out += page[inPage..<(inPage + n)] } else { out += repeatElement(0, count: n) }
            cursor += UInt64(n)
            remaining -= n
        }
        return out
    }

    public func writePhysical(gpa: UInt64, bytes: [UInt8]) throws {
        var cursor = gpa
        var offset = 0
        while offset < bytes.count {
            guard isBacked(cursor) else { throw FakePhysicalBackingError("gpa \(hex(cursor)) is not backed") }
            let base = cursor & ~(VMLayout.pageSize - 1)
            let inPage = Int(cursor - base)
            let n = min(bytes.count - offset, Int(VMLayout.pageSize) - inPage)
            var page = pages[base] ?? [UInt8](repeating: 0, count: Int(VMLayout.pageSize))
            page.replaceSubrange(inPage..<(inPage + n), with: bytes[offset..<(offset + n)])
            pages[base] = page
            cursor += UInt64(n)
            offset += n
        }
        writeLog.append((gpa, bytes.count))
    }
}
