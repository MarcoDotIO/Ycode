// Guest-physical backing for the stage-3 address space, over KVM memslots.
// Contract: specs/simulator/stage3-contract.md §3 and §4; stage 6 §5.
//
// - Anonymous guest pages come from one large memslot (the anonymous pool),
//   backed by a host MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE mapping, so
//   host memory is committed only for pages the guest touches. Pages are
//   carved out at 16 KiB granularity, first fit (an `IntervalMap` of the
//   allocated runs: O(log n) per allocation and release).
// - A freed pool run of at most `discardLimit` bytes keeps its host pages
//   (madvise is slow while the VM runs) and is zero-filled when it is
//   allocated again; at most `staleLimit` bytes wait like this.
// - A file mapping the guest may write of at most `copyLimit` bytes is a
//   copy of the file bytes in pool memory (released like anonymous memory).
//   A larger one gets its own memslot, backed by a host MAP_PRIVATE mapping
//   of the file: guest writes are copy-on-write and the file is never
//   modified. GPAs for these slots come from a bump allocator below the
//   read-only file window.
// - A file mapping without write access is served from the process-wide
//   `SharedFileArena` when it can be: the arena is registered once per VM
//   as one read-only memslot at `readOnlyFileWindowGPA`, so such a mapping
//   costs neither a host mmap nor a memslot, and its GPA is the same in
//   every VM.
// - Memslots stay registered after the guest unmaps their pages.

#if os(Linux) && arch(arm64)
import CKVM
import Glibc
import Synchronization
import YcodeDarwinABI

/// Diagnostics (`VCPUPool.profiling`): how often and how long the backing
/// called the host for guest memory, process-wide (count, ns, bytes). Each
/// kind runs inside a guest trap, under the kernel lock.
public final class BackingCounter: @unchecked Sendable {
    public let name: String
    public let count = Atomic<UInt64>(0)
    public let nanoseconds = Atomic<UInt64>(0)
    public let bytes = Atomic<UInt64>(0)
    init(_ name: String) { self.name = name }

    @inline(__always) func add(since start: UInt64, bytes n: UInt64 = 0) {
        count.wrappingAdd(1, ordering: .relaxed)
        nanoseconds.wrappingAdd(monotonicNanoseconds() &- start, ordering: .relaxed)
        bytes.wrappingAdd(n, ordering: .relaxed)
    }

    var text: String {
        "\(name) \(count.load(ordering: .relaxed)) (\(nanoseconds.load(ordering: .relaxed) / 1_000_000) ms, "
            + "\(bytes.load(ordering: .relaxed) >> 20) MiB)"
    }
}

/// Work a trap handler leaves for its vCPU thread to do after the trap,
/// when the kernel lock is no longer held (`performance-contract.md` §6,
/// C17): today, returning anonymous pool memory to the host
/// (`MADV_DONTNEED`), which blocks in the host kernel (the process's
/// mmap lock, KVM's MMU notifier) for 0.3 ms on average and up to tens of
/// milliseconds. Per host thread; only the vCPU threads of one VM queue
/// work for that VM's memory (`isCurrentVM`), so the VM is open while the
/// work runs (a VM closes only after its vCPU threads were joined).
public enum PostTrapWork {
    private final class State {
        var vm: ObjectIdentifier?
        var work: [() -> Void] = []
    }
    nonisolated(unsafe) private static var key: pthread_key_t = {
        var k = pthread_key_t()
        pthread_key_create(&k) { p in if let p { Unmanaged<AnyObject>.fromOpaque(p).release() } }
        return k
    }()

    private static var state: State {
        if let p = pthread_getspecific(key) { return Unmanaged<State>.fromOpaque(p).takeUnretainedValue() }
        let s = State()
        pthread_setspecific(key, Unmanaged.passRetained(s).toOpaque())
        return s
    }

    /// The calling vCPU thread runs `vm`'s vCPU (set once by its thread).
    public static func setCurrentVM(_ vm: VirtualMachine) { state.vm = ObjectIdentifier(vm) }

    /// True when the calling thread is a vCPU thread of `vm`.
    public static func isCurrentVM(_ vm: VirtualMachine) -> Bool {
        guard let p = pthread_getspecific(key) else { return false }
        return Unmanaged<State>.fromOpaque(p).takeUnretainedValue().vm == ObjectIdentifier(vm)
    }

    /// Queues `body` to run on this thread after the trap.
    static func defer_(_ body: @escaping () -> Void) { state.work.append(body) }

    /// Runs the queued work (the vCPU run loop, after each handler call,
    /// with no lock held).
    public static func drain() {
        guard let p = pthread_getspecific(key) else { return }
        let s = Unmanaged<State>.fromOpaque(p).takeUnretainedValue()
        while !s.work.isEmpty {
            let list = s.work
            s.work.removeAll()
            for body in list { body() }
        }
    }
}

public enum BackingStats {
    public static let deferredDiscards = BackingCounter("discards after the trap")
    public static let fileMemslots = BackingCounter("file memslots")
    public static let fileWindowMaps = BackingCounter("file window maps")
    public static let fileCopies = BackingCounter("file copies")
    public static let sharedMemslots = BackingCounter("shared-object memslots")
    public static let discards = BackingCounter("discards")
    public static let zeroFills = BackingCounter("zero fills")

    /// One line for reports.
    public static var report: String {
        "host memory calls in traps: " + [fileMemslots, fileWindowMaps, fileCopies, sharedMemslots, discards, zeroFills,
                                         deferredDiscards]
            .map(\.text).joined(separator: "; ")
    }
}

public final class KVMPhysicalBacking {
    public let vm: VirtualMachine
    /// The anonymous pool: [poolGPA, poolGPA + poolSize).
    public let poolGPA: UInt64
    public let poolSize: UInt64
    /// The first GPA handed out to file-backed memslots.
    public let fileWindowGPA: UInt64
    /// The end of the guest-physical address space (exclusive).
    public let physicalLimit: UInt64
    /// The read-only file window (the arena's memslot), if registered.
    public let readOnlyFileWindowGPA: UInt64?
    private let arena: SharedFileArena?

    /// 16 KiB, the guest granule. Every GPA and size this type hands out is a multiple of it.
    public static let granule: UInt64 = 1 << 14
    /// Contract §3 defaults.
    public static let defaultPoolGPA: UInt64 = 0x10_0000_0000
    public static let defaultPoolSize: UInt64 = 16 << 30
    public static let defaultFileWindowGPA: UInt64 = 0x20_0000_0000
    /// Where the shared read-only file arena appears in every VM.
    public static let defaultReadOnlyFileWindowGPA: UInt64 = 0x80_0000_0000

    /// Allocated runs of the pool.
    private let pool: RangeAllocator
    /// Free runs of the pool whose host pages may still hold old data.
    private let stale: RangeAllocator
    public static let discardLimit: UInt64 = 256 << 10
    public static let staleLimit: UInt64 = 4 << 20
    /// Above this many stale bytes in a new run, the run is discarded instead of zero-filled.
    public static let zeroFillLimit: UInt64 = 64 << 10
    /// Writable file mappings up to this size are copied into pool memory.
    public static let copyLimit: UInt64 = 1 << 20
    /// Number of file mappings copied into pool memory (for tracing).
    public private(set) var copiedFileMappingCount = 0
    private var nextFileGPA: UInt64
    /// The end of the bump-allocated file window.
    private let fileWindowLimit: UInt64
    private let poolHost: UnsafeMutableRawPointer
    /// Bytes of the pool currently allocated (for tracing).
    public var anonymousBytesInUse: UInt64 { pool.bytesInUse }
    /// Number of file mappings made with their own memslot (for tracing).
    public private(set) var fileMappingCount = 0
    /// Number of file mappings served from the read-only arena (for tracing).
    public private(set) var readOnlyViewCount = 0
    /// The private file window (`performance-contract.md` §6, C16): one host
    /// reservation, registered as one memslot when the backing is made, into
    /// which writable file mappings larger than `copyLimit` are mapped
    /// (MAP_FIXED, private) instead of each getting a memslot of its own.
    /// A guest mmap then costs a host mmap but no KVM memslot change (which
    /// waits for an SRCU grace period). Nil when off or refused.
    private let privateWindowHost: UnsafeMutableRawPointer?
    public let privateWindowGPA: UInt64
    public let privateWindowSize: UInt64
    private var privateWindowNext: UInt64 = 0
    /// On by default; `YCODE_PRIVATE_FILE_WINDOW=0` turns the window off (one memslot per
    /// mapping, as before).
    public static let privateWindowEnabled = getenv("YCODE_PRIVATE_FILE_WINDOW").map { String(cString: $0) != "0" } ?? true
    public static let defaultPrivateWindowSize: UInt64 = 64 << 30
    /// On by default (`YCODE_DEFERRED_DISCARD=0`: off): pool memory a trap releases is returned
    /// to the host after the trap (`PostTrapWork`), not under the kernel
    /// lock; until then the run stays allocated, so no one can get it back
    /// before its pages are dropped.
    public static let deferredDiscardEnabled = getenv("YCODE_DEFERRED_DISCARD").map { String(cString: $0) != "0" } ?? true
    /// Runs dropped after a trap, ready to go back to the pool (guarded by
    /// `readyLock`, a leaf lock; the pool itself is changed under the
    /// kernel lock only).
    private let readyLock = HostMutex(name: "pool runs ready")
    private var readyRuns: [(gpa: UInt64, size: UInt64)] = []
    private var hasReadyRuns = false

    /// SNAPSHOT hook (snapshot.md §6.3, lazy restore): set once a restore
    /// mapped page-file overlays (private file mappings) into the pool. A
    /// discard then replaces the range with fresh anonymous memory, because
    /// `MADV_DONTNEED` on a private file mapping brings the file's bytes
    /// back instead of zeros.
    public var hasOverlays = false

    /// Returns pool host pages to the host (they read as zeros afterwards).
    @inline(__always) private func discardHost(_ host: UnsafeMutableRawPointer, _ size: Int) -> Int32 {
        hasOverlays ? ckvm_reset_anonymous(host, size) : ckvm_discard_anonymous(host, size)
    }

    /// Drops [gpa, gpa+size) (allocated in `pool`, unmapped by the guest)
    /// after the trap, then makes it free again. Kernel lock held.
    private func discardAfterTrap(_ gpa: UInt64, _ size: UInt64) {
        let host = poolHost + Int(gpa - poolGPA)
        PostTrapWork.defer_ { [self] in
            let began = VCPUPool.profiling ? monotonicNanoseconds() : 0
            _ = discardHost(host, Int(size))
            if VCPUPool.profiling { BackingStats.deferredDiscards.add(since: began, bytes: size) }
            readyLock.withLock {
                readyRuns.append((gpa, size))
                hasReadyRuns = true
            }
        }
    }

    /// Returns the runs dropped after earlier traps to the pool. Kernel lock held.
    private func takeReadyRuns() {
        let runs: [(gpa: UInt64, size: UInt64)] = readyLock.withLock {
            guard hasReadyRuns else { return [] }
            hasReadyRuns = false
            let r = readyRuns
            readyRuns.removeAll()
            return r
        }
        for r in runs { pool.free(r.gpa, r.size) }
    }

    /// The shared object arena's GPA in this VM, when registered (C19).
    public static let sharedArenaGPA: UInt64 = 0xC0_0000_0000
    private var sharedArenaRegistered = false

    /// Shared memory objects registered in this VM (kept alive while the
    /// VM may touch them; their slots are never unmapped by the VM).
    private var sharedSlots: [ObjectIdentifier: (object: SharedMemoryObject, gpa: UInt64)] = [:]

    /// `sharedReadOnlyFiles`: serve read-only file mappings from
    /// `SharedFileArena.shared` when KVM supports read-only memslots.
    public init(vm: VirtualMachine,
                poolGPA: UInt64 = KVMPhysicalBacking.defaultPoolGPA,
                poolSize: UInt64 = KVMPhysicalBacking.defaultPoolSize,
                fileWindowGPA: UInt64 = KVMPhysicalBacking.defaultFileWindowGPA,
                physicalAddressBits: UInt64 = 40,
                sharedReadOnlyFiles: Bool = true,
                readOnlyFileWindowGPA: UInt64 = KVMPhysicalBacking.defaultReadOnlyFileWindowGPA) throws {
        precondition(poolGPA % Self.granule == 0 && poolSize % Self.granule == 0 && fileWindowGPA % Self.granule == 0)
        guard let host = ckvm_alloc_anonymous(Int(poolSize)) else {
            throw KVMError("mmap anonymous pool (\(poolSize >> 20) MiB, MAP_NORESERVE)", errno: Glibc.errno)
        }
        do {
            try vm.addMemorySlot(gpa: poolGPA, size: poolSize, host: host, kind: .anonymousPool, name: "anonymous pool")
        } catch {
            _ = ckvm_free_anonymous(host, Int(poolSize))
            throw error
        }
        let limit = UInt64(1) << physicalAddressBits
        // The private file window at the start of the file GPA range (below
        // the read-only arena); per-mapping file slots follow it.
        var privateHost: UnsafeMutableRawPointer?
        var privateSize: UInt64 = 0
        let privateGPA = fileWindowGPA
        if Self.privateWindowEnabled, privateGPA < readOnlyFileWindowGPA,
           Self.defaultPrivateWindowSize <= readOnlyFileWindowGPA - privateGPA,
           let reservation = mmap(nil, Int(Self.defaultPrivateWindowSize), PROT_NONE,
                                  MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0), reservation != MAP_FAILED {
            if (try? vm.addMemorySlot(gpa: privateGPA, size: Self.defaultPrivateWindowSize, host: reservation, kind: .file,
                                      name: "private file window")) != nil {
                privateHost = reservation
                privateSize = Self.defaultPrivateWindowSize
            } else {
                munmap(reservation, Int(Self.defaultPrivateWindowSize))
            }
        }
        var window: UInt64?
        var arena: SharedFileArena?
        if sharedReadOnlyFiles, !Self.debugNoArena, vm.supportsReadOnlyMemory, let a = SharedFileArena.shared,
           readOnlyFileWindowGPA % Self.granule == 0, readOnlyFileWindowGPA > fileWindowGPA,
           readOnlyFileWindowGPA < limit, a.size <= limit - readOnlyFileWindowGPA,
           (try? vm.addMemorySlot(gpa: readOnlyFileWindowGPA, size: a.size, host: a.base, kind: .readOnlyFiles,
                                  name: "read-only file arena", readOnly: true)) != nil {
            window = readOnlyFileWindowGPA
            arena = a
        }
        self.vm = vm
        self.poolGPA = poolGPA
        self.poolSize = poolSize
        self.fileWindowGPA = fileWindowGPA
        self.physicalLimit = limit
        self.poolHost = host
        self.pool = RangeAllocator(base: poolGPA, size: poolSize)
        self.stale = RangeAllocator(base: poolGPA, size: poolSize, hardwareWatch: DebugHardwareWatch.arm != nil)
        // Above the read-only file window (and only with it, which bounds
        // the per-mapping file slots below it).
        if let objects = SharedObjectArena.shared, window != nil, let ro = SharedFileArena.shared,
           Self.sharedArenaGPA >= readOnlyFileWindowGPA + ro.size,
           objects.size <= limit - Self.sharedArenaGPA,
           (try? vm.addMemorySlot(gpa: Self.sharedArenaGPA, size: objects.size, host: objects.base, kind: .shared,
                                  name: "shared object arena")) != nil {
            sharedArenaRegistered = true
        }
        self.privateWindowHost = privateHost
        self.privateWindowGPA = privateGPA
        self.privateWindowSize = privateSize
        self.nextFileGPA = fileWindowGPA + privateSize
        self.readOnlyFileWindowGPA = window
        self.arena = arena
        self.fileWindowLimit = window ?? limit
    }

    /// Diagnostics: `YCODE_DEBUG_NO_FILE_ARENA=1` (no shared read-only file
    /// window), `YCODE_DEBUG_NO_STALE=1` (released pool pages are dropped at
    /// once, never zero-filled on reuse), `YCODE_DEBUG_NO_FILE_COPY=1`
    /// (small file mappings get their own memslot instead of a pool copy).
    static let debugNoArena = getenv("YCODE_DEBUG_NO_FILE_ARENA").map { String(cString: $0) == "1" } ?? false
    static let debugNoStale = getenv("YCODE_DEBUG_NO_STALE").map { String(cString: $0) == "1" } ?? false
    static let debugNoFileCopy = getenv("YCODE_DEBUG_NO_FILE_COPY").map { String(cString: $0) == "1" } ?? false

    static func roundUp(_ value: UInt64, _ alignment: UInt64) -> UInt64 { (value + alignment - 1) & ~(alignment - 1) }

    // MARK: Anonymous pages

    /// Allocates `size` bytes (rounded up to 16 KiB) of zeroed, physically
    /// contiguous guest memory from the pool (first fit). Returns its GPA.
    public func allocateAnonymous(size: UInt64) throws -> UInt64 {
        let size = Self.roundUp(max(size, 1), Self.granule)
        guard !vm.isClosed else { throw KVMError("anonymous pool", errno: EBADF, detail: "the VM is closed") }
        if Self.deferredDiscardEnabled { takeReadyRuns() }
        guard let start = pool.allocate(size) else {
            throw KVMError("anonymous pool", errno: ENOMEM,
                           detail: "no free run of \(size) bytes (\(anonymousBytesInUse >> 20) MiB of \(poolSize >> 20) MiB in use)")
        }
        if stale.bytesInUse > 0 {
            let old = stale.free(start, size)
            let oldBytes = old.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
            let began = VCPUPool.profiling ? monotonicNanoseconds() : 0
            if oldBytes > Self.zeroFillLimit {
                // Cheaper to drop the whole run at once.
                _ = discardHost(poolHost + Int(start - poolGPA), Int(size))
                if VCPUPool.profiling {
                    BackingStats.discards.add(since: began, bytes: size)
                }
            } else {
                for r in old {
                    (poolHost + Int(r.lowerBound - poolGPA)).initializeMemory(as: UInt8.self, repeating: 0,
                                                                              count: Int(r.upperBound - r.lowerBound))
                }
                if VCPUPool.profiling { BackingStats.zeroFills.add(since: began) }
            }
        }
        return start
    }

    /// Returns pool pages to the free list. Their host pages are dropped, so
    /// they read as zeros when reused. GPAs outside the pool (file slots) are
    /// ignored: those memslots stay registered.
    public func release(gpa: UInt64, size: UInt64) {
        let size = Self.roundUp(size, Self.granule)
        guard size > 0, gpa >= poolGPA, gpa + size <= poolGPA + poolSize, gpa % Self.granule == 0 else { return }
        // After the VM's teardown the pool's host memory is gone (and its
        // addresses may belong to another mapping): never touch it.
        guard !vm.isClosed else { return }
        // Ignore a range that is not entirely allocated (double free): keep the allocator consistent.
        guard pool.isAllocated(gpa, size) else { return }
        let deferred = Self.deferredDiscardEnabled && PostTrapWork.isCurrentVM(vm)
        if deferred, size > Self.discardLimit || Self.debugNoStale {
            // Stays allocated until it is dropped after the trap.
            discardAfterTrap(gpa, size)
            return
        }
        pool.free(gpa, size)
        let began = VCPUPool.profiling ? monotonicNanoseconds() : 0
        if size <= Self.discardLimit && !Self.debugNoStale {
            stale.mark(gpa, size)
            if stale.bytesInUse > Self.staleLimit {
                if deferred {
                    // Allocated again (they were free and stale) until dropped.
                    for r in stale.takeAll() {
                        pool.mark(r.lowerBound, r.upperBound - r.lowerBound)
                        discardAfterTrap(r.lowerBound, r.upperBound - r.lowerBound)
                    }
                    return
                }
                var bytes: UInt64 = 0
                for r in stale.takeAll() {
                    _ = discardHost(poolHost + Int(r.lowerBound - poolGPA), Int(r.upperBound - r.lowerBound))
                    bytes += r.upperBound - r.lowerBound
                }
                if VCPUPool.profiling {
                    BackingStats.discards.add(since: began, bytes: bytes)
                }
            }
        } else {
            _ = discardHost(poolHost + Int(gpa - poolGPA), Int(size))
            if VCPUPool.profiling {
                BackingStats.discards.add(since: began, bytes: size)
            }
        }
    }

    // MARK: File mappings

    /// Maps `size` bytes (rounded up to 16 KiB) of the host file `hostFD`,
    /// starting at `offset`, into a new memslot. Bytes past the end of the
    /// file read as zeros. Returns the slot's GPA.
    public func mapFile(hostFD: Int32, fileSize: UInt64, offset: UInt64, size: UInt64, name: String) throws -> UInt64 {
        let hostPage = UInt64(ckvm_host_page_size())
        guard offset % hostPage == 0 else {
            throw KVMError("file memslot", errno: EINVAL, detail: "offset 0x\(String(offset, radix: 16)) of \(name) is not host-page aligned")
        }
        let total = Self.roundUp(max(size, 1), Self.granule)
        let gpa = Self.roundUp(nextFileGPA, Self.granule)
        guard gpa <= fileWindowLimit, total <= fileWindowLimit - gpa else {
            throw KVMError("file memslot", errno: ENOMEM, detail: "guest physical space exhausted mapping \(name)")
        }
        let available = offset < fileSize ? fileSize - offset : 0
        let fileBytes = Int(min(min(size, available), total))
        let began = VCPUPool.profiling ? monotonicNanoseconds() : 0
        if total <= Self.copyLimit && !Self.debugNoFileCopy {
            // A copy in pool memory: no memslot (and released with the mapping).
            defer {
                if VCPUPool.profiling {
                    BackingStats.fileCopies.add(since: began, bytes: total)
                }
            }
            let gpa = try allocateAnonymous(size: total)
            let destination = poolHost + Int(gpa - poolGPA)
            var done = 0
            while done < fileBytes {
                let n = pread(hostFD, destination + done, fileBytes - done, off_t(offset) + off_t(done))
                if n < 0 && Glibc.errno == EINTR { continue }
                if n < 0 {
                    let saved = Glibc.errno
                    // Pages already written must not be handed out again unzeroed.
                    (destination).initializeMemory(as: UInt8.self, repeating: 0, count: done)
                    release(gpa: gpa, size: total)
                    throw KVMError("read \(name) at offset 0x\(String(offset, radix: 16))", errno: saved)
                }
                if n == 0 { break }  // the file shrank: the rest stays zero
                done += n
            }
            copiedFileMappingCount += 1
            return gpa
        }
        if let windowHost = privateWindowHost, total <= privateWindowSize - privateWindowNext {
            // The private file window: a host mapping, no memslot change.
            let at = windowHost + Int(privateWindowNext)
            guard ckvm_map_file_private_at(at, hostFD, offset, fileBytes, Int(total)) != nil else {
                let saved = Glibc.errno
                var target = [CChar](repeating: 0, count: 512)
                let n = readlink("/proc/self/fd/\(hostFD)", &target, 511)
                let what = n > 0 ? String(cString: target) : "?"
                throw KVMError("mmap \(name) at offset 0x\(String(offset, radix: 16)) (private file window; fd \(hostFD) -> \(what); "
                               + "fileBytes \(fileBytes) total \(total); arena files \(SharedFileArena.shared?.fileCount ?? -1) "
                               + "bytes \((SharedFileArena.shared?.bytesUsed ?? 0) >> 20) MiB)", errno: saved)
            }
            let gpa = privateWindowGPA + privateWindowNext
            privateWindowNext += total
            fileMappingCount += 1
            if VCPUPool.profiling {
                BackingStats.fileWindowMaps.add(since: began, bytes: total)
            }
            return gpa
        }
        guard let host = ckvm_map_file_private(hostFD, offset, fileBytes, Int(total)) else {
            throw KVMError("mmap \(name) at offset 0x\(String(offset, radix: 16))", errno: Glibc.errno)
        }
        do {
            try vm.addMemorySlot(gpa: gpa, size: total, host: host, kind: .file,
                                 name: "\(name)@0x\(String(offset, radix: 16))")
        } catch {
            _ = ckvm_free_anonymous(host, Int(total))
            throw error
        }
        nextFileGPA = gpa + total
        fileMappingCount += 1
        if VCPUPool.profiling {
            BackingStats.fileMemslots.add(since: began, bytes: total)
        }
        return gpa
    }

    /// The GPA of `file` bytes [offset, offset+size) in the shared read-only
    /// file window, or nil when the window cannot serve them (see
    /// `SharedFileArena.view`).
    public func mapFileReadOnly(hostFD: Int32, offset: UInt64, size: UInt64) -> UInt64? {
        guard let arena, let window = readOnlyFileWindowGPA,
              let at = arena.view(hostFD: hostFD, offset: offset, size: Self.roundUp(max(size, 1), Self.granule)) else {
            return nil
        }
        readOnlyViewCount += 1
        return window + at
    }

    // MARK: Shared memory

    /// Registers `object` as a memslot (once per VM) in the file window and
    /// returns its GPA.
    public func mapShared(_ object: SharedMemoryObject) throws -> UInt64 {
        if let slot = sharedSlots[ObjectIdentifier(object)] { return slot.gpa }
        if sharedArenaRegistered, let offset = object.arenaOffset {
            // In the arena this VM registered at start: no memslot change.
            let gpa = Self.sharedArenaGPA + offset
            sharedSlots[ObjectIdentifier(object)] = (object, gpa)
            return gpa
        }
        let began = VCPUPool.profiling ? monotonicNanoseconds() : 0
        defer { if VCPUPool.profiling { BackingStats.sharedMemslots.add(since: began) } }
        let gpa = Self.roundUp(nextFileGPA, Self.granule)
        guard gpa <= fileWindowLimit, object.size <= fileWindowLimit - gpa else {
            throw KVMError("shared memslot", errno: ENOMEM, detail: "guest physical space exhausted")
        }
        try vm.addMemorySlot(gpa: gpa, size: object.size, host: object.host, kind: .shared,
                             name: "shared object #\(object.serial)")
        nextFileGPA = gpa + object.size
        sharedSlots[ObjectIdentifier(object)] = (object, gpa)
        return gpa
    }

    // MARK: Physical access

    /// Reads `count` bytes at `gpa`. The range may span consecutive memslots.
    public func readPhysical(gpa: UInt64, count: Int) throws -> [UInt8] {
        if let slot = vm.memorySlot(containing: gpa), slot.contains(gpa: gpa, count: count) {
            // The common case: one slot.
            return [UInt8](UnsafeRawBufferPointer(start: UnsafeRawPointer(bitPattern: slot.hostAddress)! + Int(gpa - slot.gpa),
                                                  count: count))
        }
        var result: [UInt8] = []
        result.reserveCapacity(count)
        var address = gpa, remaining = count
        while remaining > 0 {
            guard let slot = vm.memorySlot(containing: address) else {
                throw KVMError("guest physical read", errno: EFAULT, detail: "GPA 0x\(String(address, radix: 16)) is outside every memslot")
            }
            let chunk = Int(min(UInt64(remaining), slot.end - address))
            result.append(contentsOf: try vm.read(gpa: address, count: chunk))
            address += UInt64(chunk)
            remaining -= chunk
        }
        return result
    }

    /// Writes `bytes` at `gpa`. The range may span consecutive memslots;
    /// read-only slots are refused.
    public func writePhysical(gpa: UInt64, bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { try writePhysical(gpa: gpa, from: $0) }
    }

    /// `writePhysical` from a raw buffer.
    public func writePhysical(gpa: UInt64, from bytes: UnsafeRawBufferPointer) throws {
        var address = gpa, offset = 0
        while offset < bytes.count {
            guard let slot = vm.memorySlot(containing: address) else {
                throw KVMError("guest physical write", errno: EFAULT, detail: "GPA 0x\(String(address, radix: 16)) is outside every memslot")
            }
            let chunk = Int(min(UInt64(bytes.count - offset), slot.end - address))
            let destination = try vm.writableHostPointer(gpa: address, count: chunk)
            destination.copyMemory(from: bytes.baseAddress! + offset, byteCount: chunk)
            address += UInt64(chunk)
            offset += chunk
        }
    }
}

/// The contract's `PhysicalBacking` (stage3-contract.md §4) over KVM memslots.
extension KVMPhysicalBacking: PhysicalBacking {
    public func mapFile(_ file: GuestFile, offset: UInt64, size: UInt64) throws -> UInt64 {
        try mapFile(hostFD: file.hostFD, fileSize: file.size, offset: offset, size: size, name: file.guestPath)
    }

    public func mapFileReadOnly(_ file: GuestFile, offset: UInt64, size: UInt64) throws -> UInt64? {
        mapFileReadOnly(hostFD: file.hostFD, offset: offset, size: size)
    }
}
#endif
