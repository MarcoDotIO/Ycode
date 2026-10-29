// Guest memory that several address spaces map at once: the storage behind
// a Mach memory entry (`mach_make_memory_entry_64`, `mach_vm_map` with a
// memory object; xnu osfmk/vm/vm_user.c, level 1). Every guest process of a
// device runs in this host process, each in its own VM, so sharing is the
// same host pages registered in each VM that maps them.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// One host reservation from which shared memory objects take their host
/// memory (`boot-profile.md` §3.5, C19), so that a VM registers all of them
/// with one memslot, made when its backing is built, instead of one memslot
/// per object it maps (a memslot change waits for an SRCU grace period of
/// the VM, under the kernel lock). Objects get first-fit runs (16 KiB
/// multiples); a freed run is made inaccessible again (`MAP_FIXED`
/// reservation), which also drops its pages, before it can be reused.
/// On by default (`YCODE_SHARED_WINDOW=0`: off); when it is full, objects are mapped
/// on their own as before.
public final class SharedObjectArena: @unchecked Sendable {
    public static let enabled = getenv("YCODE_SHARED_WINDOW").map { String(cString: $0) != "0" } ?? true
    public static let shared: SharedObjectArena? = enabled ? SharedObjectArena(size: 128 << 30) : nil

    public let base: UnsafeMutableRawPointer
    public let size: UInt64
    private let lock = NSLockLike(name: "shared object arena")
    private let runs: RangeAllocator

    init?(size: UInt64) {
        #if canImport(Darwin)
        let flags = MAP_PRIVATE | MAP_ANON
        #else
        let flags = MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE
        #endif
        // 2 MiB-aligned base (memslot and huge-page friendly).
        let slack = 2 << 20
        guard let raw = mmap(nil, Int(size) + slack, PROT_NONE, flags, -1, 0), raw != MAP_FAILED else { return nil }
        let aligned = (UInt(bitPattern: raw) + UInt(slack) - 1) & ~(UInt(slack) - 1)
        base = UnsafeMutableRawPointer(bitPattern: aligned)!
        self.size = size
        runs = RangeAllocator(base: 0, size: size)
    }

    /// A run of `size` bytes (a 16 KiB multiple), still inaccessible; nil when full.
    func take(_ size: UInt64) -> UInt64? { lock.withLock { runs.allocate(size) } }

    // Recycling (frame-profile.md §5.2). Every host mapping change in the
    // arena (the MAP_FIXED of `take`'s caller, the PROT_NONE reservation of
    // `give`) runs the MMU notifiers of every VM of the process, because
    // every VM registers the whole arena (one memslot): each one takes its
    // MMU lock, unmaps the range from stage 2 and flushes its TLBs. With
    // hundreds of processes (VMs) that is milliseconds per change, and
    // shared Metal buffers are made and freed every frame. A freed run of an
    // anonymous object therefore stays mapped (read-write, its pages kept)
    // in a pool by size, and the next object of that size takes it and
    // zeroes it: no host mapping change at all. Isolation is unchanged: a
    // guest reaches arena pages only through its stage-1 tables, which the
    // VMM changes (and flushes) when the object is unmapped.

    /// `YCODE_ARENA_RECYCLE_MB=<n>` (default 256; 0 = off): the most bytes
    /// of freed runs kept for reuse.
    public static let recycleLimit: UInt64 = (getenv("YCODE_ARENA_RECYCLE_MB").flatMap { UInt64(String(cString: $0)) } ?? 256) << 20
    /// Runs above this size are not kept (zeroing them would cost more than the remap).
    public static let recycleMaxRun: UInt64 = 4 << 20
    private var pool: [UInt64: [UInt64]] = [:]
    private var pooledBytes: UInt64 = 0
    private var recycleHits: UInt64 = 0, recycleMisses: UInt64 = 0, recycleRefused: UInt64 = 0

    /// A pooled run of exactly `size` bytes, still mapped read-write with
    /// stale contents (the caller zeroes it), or nil.
    func takeRecycled(_ size: UInt64) -> UInt64? {
        guard Self.recycleLimit > 0, size <= Self.recycleMaxRun else { return nil }
        return lock.withLock {
            guard var list = pool[size], let at = list.popLast() else {
                recycleMisses &+= 1
                return nil
            }
            pool[size] = list.isEmpty ? nil : list
            pooledBytes -= size
            recycleHits &+= 1
            return at
        }
    }

    /// Keeps a freed run of an anonymous object (still mapped read-write)
    /// for reuse. False: the pool is full or the run too big; `give` it.
    func recycle(_ offset: UInt64, _ size: UInt64) -> Bool {
        guard Self.recycleLimit > 0, size <= Self.recycleMaxRun else { return false }
        return lock.withLock {
            guard pooledBytes + size <= Self.recycleLimit else {
                recycleRefused &+= 1
                return false
            }
            pool[size, default: []].append(offset)
            pooledBytes += size
            return true
        }
    }

    /// Diagnostics: objects that reused a pooled run, objects that found
    /// none, frees the full pool refused, and the bytes pooled now.
    public var recycleSummary: String {
        lock.withLock { "arena recycle: \(recycleHits) reused, \(recycleMisses) new, \(recycleRefused) refused, \(pooledBytes >> 20) MiB pooled" }
    }

    /// Makes the run inaccessible again (dropping its pages) and frees it.
    func give(_ offset: UInt64, _ size: UInt64) {
        #if canImport(Darwin)
        let flags = MAP_PRIVATE | MAP_ANON | MAP_FIXED
        #else
        let flags = MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE | MAP_FIXED
        #endif
        _ = mmap(base + Int(offset), Int(size), PROT_NONE, flags, -1, 0)
        lock.withLock { _ = runs.free(offset, size) }
    }
}

/// Zero-filled host memory, a 16 KiB multiple, page aligned. It lives while
/// any memory entry or any address space (through its physical backing)
/// refers to it.
public final class SharedMemoryObject: @unchecked Sendable {
    public let size: UInt64
    /// The host memory (read and written by the backings and, through KVM
    /// memslots, by the guests).
    public let host: UnsafeMutableRawPointer
    private static let counterLock = NSLockLike(name: "shared memory serials")
    nonisolated(unsafe) private static var counter: UInt64 = 0
    /// A process-unique number (tracing).
    public let serial: UInt64

    /// The object's offset in `SharedObjectArena.shared`, when its memory
    /// lies there (nil: a mapping of its own).
    public let arenaOffset: UInt64?

    /// `size` is rounded up to 16 KiB. Fails with ENOMEM.
    public init(size: UInt64) throws {
        let rounded = (max(size, 1) + VMLayout.pageSize - 1) & ~(VMLayout.pageSize - 1)
        guard rounded <= 1 << 36 else { throw DarwinErrnoError(DarwinErrnoCode.ENOMEM) }
        #if canImport(Darwin)
        let flags = MAP_PRIVATE | MAP_ANON
        #else
        let flags = MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE
        #endif
        var offset: UInt64?
        var p: UnsafeMutableRawPointer?
        if let arena = SharedObjectArena.shared, let at = arena.takeRecycled(rounded) {
            // A pooled run: mapped already; zero-filled like a new object.
            let run = arena.base + Int(at)
            memset(run, 0, Int(rounded))
            p = run
            offset = at
        } else if let arena = SharedObjectArena.shared, let at = arena.take(rounded) {
            let q = mmap(arena.base + Int(at), Int(rounded), PROT_READ | PROT_WRITE, flags | MAP_FIXED, -1, 0)
            if let q, q != MAP_FAILED {
                p = q
                offset = at
            } else {
                arena.give(at, rounded)
            }
        }
        if p == nil {
            let q = mmap(nil, Int(rounded), PROT_READ | PROT_WRITE, flags, -1, 0)
            guard let q, q != MAP_FAILED else { throw DarwinErrnoError(DarwinErrnoCode.ENOMEM) }
            p = q
        }
        arenaOffset = offset
        self.size = rounded
        self.host = p!
        isFileView = false
        serial = Self.counterLock.withLock {
            Self.counter += 1
            return Self.counter
        }
    }

    /// True for a view of a host file (`init(hostFile:…)`).
    public let isFileView: Bool

    /// SNAPSHOT hook (agent SNAP, specs/simulator/snapshot.md §2.1): the
    /// file and range a file view was made for (set by its creator).
    public struct FileSource: Sendable {
        public var guestPath: String
        public var hostPath: String
        public var offset: UInt64
        public var requestedSize: UInt64
        public init(guestPath: String, hostPath: String, offset: UInt64, requestedSize: UInt64) {
            self.guestPath = guestPath
            self.hostPath = hostPath
            self.offset = offset
            self.requestedSize = requestedSize
        }
    }
    public var snapshotFileSource: FileSource?

    /// A shared view of a host file (MAP_SHARED file mappings): bytes
    /// [offset, offset+size) of the open host file `fd` (16 KiB-aligned
    /// offset), mapped shared and writable from the host's page cache. Every
    /// view of the same file — in any VM of this host process — and the
    /// host's own `read`/`write` on the file see the same bytes, as a Darwin
    /// shared file mapping does (mmap(2), level 1).
    ///
    /// The view follows the file's size (`service-fidelity.md` §10): host
    /// pages wholly past the end of the file are private zero pages (Darwin
    /// would fault on them; zeros are the lenient answer) until the file
    /// grows over them (`SharedFileViews.sizeMayHaveChanged`), and then show
    /// the file; pages the file is truncated away from become zero pages
    /// again. A view of a file at or past its end starts with no file pages.
    ///
    /// The view keeps its own host descriptor for the file, open for reading
    /// and writing: `fd` duplicated when it is, else (`reopenReadOnly`, Linux)
    /// the same file opened again through /proc/self/fd. Nil when neither
    /// works or the host refuses the mapping; the caller then maps the file
    /// private.
    public init?(hostFile fd: Int32, offset: UInt64, size: UInt64, fileSize: UInt64, reopenReadOnly: Bool = false) {
        let page = VMLayout.pageSize
        let rounded = (max(size, 1) + page - 1) & ~(page - 1)
        guard offset & (page - 1) == 0, rounded <= 1 << 36, offset <= UInt64(Int64.max) else { return nil }
        let viewFD: Int32
        if fcntl(fd, F_GETFL) & O_ACCMODE == O_RDWR {
            viewFD = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        } else if reopenReadOnly {
            #if os(Linux)
            viewFD = open("/proc/self/fd/\(fd)", O_RDWR | O_CLOEXEC)
            #else
            viewFD = -1
            #endif
        } else {
            viewFD = -1
        }
        guard viewFD >= 0 else { return nil }
        // The reservation: a run of the shared object arena when there is
        // one (boot-profile.md §3.5), else a mapping of its own. The file
        // pages are MAP_SHARED|MAP_FIXED inside it either way, so the view
        // stays coherent with the file and follows its size (below).
        var arenaAt: UInt64?
        var reservationOrNil: UnsafeMutableRawPointer?
        if let arena = SharedObjectArena.shared, let at = arena.take(rounded) {
            let q = mmap(arena.base + Int(at), Int(rounded), PROT_READ | PROT_WRITE, MAP_PRIVATE | Self.anonymous | MAP_FIXED, -1, 0)
            if let q, q != MAP_FAILED {
                reservationOrNil = q
                arenaAt = at
            } else {
                arena.give(at, rounded)
            }
        }
        if reservationOrNil == nil {
            let q = mmap(nil, Int(rounded), PROT_READ | PROT_WRITE, MAP_PRIVATE | Self.anonymous, -1, 0)
            if let q, q != MAP_FAILED { reservationOrNil = q }
        }
        guard let reservation = reservationOrNil else {
            close(viewFD)
            return nil
        }
        let backed = SharedFileViews.backedBytes(fileSize: fileSize, offset: offset, size: rounded)
        if backed > 0 {
            guard let p = mmap(reservation, Int(backed), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, viewFD,
                               Self.hostOffset(offset)), p == reservation else {
                if let arenaAt, let arena = SharedObjectArena.shared { arena.give(arenaAt, rounded) } else { munmap(reservation, Int(rounded)) }
                close(viewFD)
                return nil
            }
        }
        arenaOffset = arenaAt
        self.size = rounded
        self.host = reservation
        isFileView = true
        serial = Self.counterLock.withLock {
            Self.counter += 1
            return Self.counter
        }
        let key = SharedFileViews.key(viewFD)
        fileView = FileViewState(fd: viewFD, offset: offset, backed: backed, key: key)
        if let key { SharedFileViews.register(self, key: key) }
    }

    #if canImport(Darwin)
    static func hostOffset(_ offset: UInt64) -> off_t { off_t(offset) }
    #else
    static func hostOffset(_ offset: UInt64) -> __off_t { __off_t(offset) }
    #endif

    /// A file view's host descriptor, file offset, how many bytes from its
    /// start are file pages (a host-page multiple), and the file's identity.
    struct FileViewState {
        var fd: Int32
        var offset: UInt64
        var backed: UInt64
        var key: SharedFileViews.Key?
    }
    /// Guarded by `SharedFileViews.lock` (after init).
    var fileView: FileViewState?

    /// Bytes from the start of the view that are file pages now (tests).
    public var fileBackedBytes: UInt64 { SharedFileViews.lock.withLock { fileView?.backed ?? 0 } }

    /// Makes the view's file pages cover `fileSize` (under `SharedFileViews.lock`).
    func followFileSize(_ fileSize: UInt64) {
        guard var v = fileView else { return }
        let want = SharedFileViews.backedBytes(fileSize: fileSize, offset: v.offset, size: size)
        if want > v.backed {
            // The file grew over pages that were zeros: they show the file now.
            let p = mmap(host + Int(v.backed), Int(want - v.backed), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, v.fd,
                         Self.hostOffset(v.offset + v.backed))
            guard p == host + Int(v.backed) else { return }
        } else if want < v.backed {
            // Truncated: the pages past the new end are zeros again (Darwin
            // would fault; a host access to them would raise SIGBUS here).
            let p = mmap(host + Int(want), Int(v.backed - want), PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | Self.anonymous | MAP_FIXED, -1, 0)
            guard p == host + Int(want) else { return }
        } else {
            return
        }
        v.backed = want
        fileView = v
    }

    deinit {
        if let v = SharedFileViews.lock.withLock({ fileView }) {
            if let key = v.key { SharedFileViews.unregister(self, key: key) }
            close(v.fd)
        }
        if let arenaOffset, let arena = SharedObjectArena.shared {
            // An anonymous object's run is kept for reuse when the pool has
            // room (no host mapping change); otherwise, and always for a
            // file view, back to an inaccessible run of the arena (every
            // VM's view of it changes with the host mapping).
            if !isFileView, arena.recycle(arenaOffset, size) { return }
            arena.give(arenaOffset, size)
        } else if Self.quarantine {
            // Diagnostics (`YCODE_DEBUG_QUARANTINE=1`): keep the range reserved
            // and inaccessible, so a stale access faults at once.
            _ = mmap(host, Int(size), PROT_NONE, MAP_PRIVATE | Self.anonymous | MAP_FIXED, -1, 0)
        } else {
            munmap(host, Int(size))
        }
    }
    private static let quarantine = getenv("YCODE_DEBUG_QUARANTINE").map { String(cString: $0) == "1" } ?? false
    #if canImport(Darwin)
    private static let anonymous = MAP_ANON
    #else
    private static let anonymous = MAP_ANONYMOUS | MAP_NORESERVE
    #endif

    /// Bytes [offset, offset+count), which must lie inside the object.
    public func read(offset: UInt64, count: Int) -> [UInt8] {
        precondition(offset <= size && UInt64(count) <= size - offset)
        return [UInt8](UnsafeRawBufferPointer(start: host + Int(offset), count: count))
    }

    /// Writes `bytes` at `offset`, which must lie inside the object.
    public func write(offset: UInt64, bytes: [UInt8]) {
        precondition(offset <= size && UInt64(bytes.count) <= size - offset)
        bytes.withUnsafeBytes { if !$0.isEmpty { (host + Int(offset)).copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
    }
}

/// The live shared file views by file (`service-fidelity.md` §10): when a
/// file's size changes through Ycode (a write past its end, ftruncate, an
/// open with O_TRUNC), every view of it follows, so a mapping made while the
/// file was short shows what is later written past the old end, as on
/// Darwin, in every process that maps it.
public enum SharedFileViews {
    struct Key: Hashable {
        var device: UInt64
        var inode: UInt64
    }
    final class Weak {
        weak var object: SharedMemoryObject?
        init(_ object: SharedMemoryObject) { self.object = object }
    }

    static let lock = NSLockLike(name: "shared file views")
    nonisolated(unsafe) private static var views: [Key: [ObjectIdentifier: Weak]] = [:]

    /// How many file views are live (tests, diagnostics).
    public static var count: Int { lock.withLock { views.values.reduce(0) { $0 + $1.count } } }

    static func key(_ fd: Int32) -> Key? {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        return Key(device: UInt64(st.st_dev), inode: UInt64(st.st_ino))
    }

    static let hostPage = UInt64(max(sysconf(Int32(_SC_PAGESIZE)), 4096))

    /// Bytes from the start of a view of `size` bytes at `offset` that lie in
    /// a file of `fileSize` bytes, rounded up to host pages (the host maps
    /// the last partial page whole; its tail reads zeros, as on Darwin).
    static func backedBytes(fileSize: UInt64, offset: UInt64, size: UInt64) -> UInt64 {
        guard fileSize > offset else { return 0 }
        let bytes = fileSize - offset
        return min((bytes + hostPage - 1) & ~(hostPage - 1), size)
    }

    static func register(_ object: SharedMemoryObject, key: Key) {
        lock.withLock { views[key, default: [:]][ObjectIdentifier(object)] = Weak(object) }
    }

    static func unregister(_ object: SharedMemoryObject, key: Key) {
        lock.withLock {
            views[key]?[ObjectIdentifier(object)] = nil
            if views[key]?.isEmpty == true { views[key] = nil }
        }
    }

    /// Called after Ycode changed the size of the open host file `fd` (or
    /// may have: a write that ends past the old end). Cheap when no view of
    /// any file is live.
    public static func sizeMayHaveChanged(hostFD fd: Int32) {
        guard lock.withLock({ !views.isEmpty }) else { return }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return }
        let key = Key(device: UInt64(st.st_dev), inode: UInt64(st.st_ino))
        let size = UInt64(max(0, Int64(st.st_size)))
        // The strong references are dropped after the lock: a last release
        // runs deinit, which takes the lock.
        var held: [SharedMemoryObject] = []
        lock.withLock {
            guard let entries = views[key] else { return }
            for entry in entries.values {
                guard let object = entry.object else { continue }
                held.append(object)
                object.followFileSize(size)
            }
        }
        held.removeAll()
    }
}

/// A tiny mutex over pthread (the module has no Foundation dependency here).
final class NSLockLike: @unchecked Sendable {
    private let mutex: UnsafeMutablePointer<pthread_mutex_t>
    init(name: String? = nil) {
        mutex = .allocate(capacity: 1)
        mutex.initialize(to: pthread_mutex_t())
        pthread_mutex_init(mutex, nil)
        if let name { DebugLockNames.register?(UnsafeMutableRawPointer(mutex), name) }
    }
    deinit {
        pthread_mutex_destroy(mutex)
        mutex.deallocate()
    }
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        return try body()
    }
}
