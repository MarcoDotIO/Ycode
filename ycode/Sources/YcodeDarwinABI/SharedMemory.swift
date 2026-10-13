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

/// Zero-filled host memory, a 16 KiB multiple, page aligned. It lives while
/// any memory entry or any address space (through its physical backing)
/// refers to it.
public final class SharedMemoryObject: @unchecked Sendable {
    public let size: UInt64
    /// The host memory (read and written by the backings and, through KVM
    /// memslots, by the guests).
    public let host: UnsafeMutableRawPointer
    private static let counterLock = NSLockLike()
    nonisolated(unsafe) private static var counter: UInt64 = 0
    /// A process-unique number (tracing).
    public let serial: UInt64

    /// `size` is rounded up to 16 KiB. Fails with ENOMEM.
    public init(size: UInt64) throws {
        let rounded = (max(size, 1) + VMLayout.pageSize - 1) & ~(VMLayout.pageSize - 1)
        guard rounded <= 1 << 36 else { throw DarwinErrnoError(DarwinErrnoCode.ENOMEM) }
        #if canImport(Darwin)
        let flags = MAP_PRIVATE | MAP_ANON
        #else
        let flags = MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE
        #endif
        let p = mmap(nil, Int(rounded), PROT_READ | PROT_WRITE, flags, -1, 0)
        guard let p, p != MAP_FAILED else { throw DarwinErrnoError(DarwinErrnoCode.ENOMEM) }
        self.size = rounded
        self.host = p
        isFileView = false
        serial = Self.counterLock.withLock {
            Self.counter += 1
            return Self.counter
        }
    }

    /// True for a view of a host file (`init(hostFile:…)`).
    public let isFileView: Bool

    /// A shared view of a host file (MAP_SHARED file mappings): bytes
    /// [offset, offset+size) of the open host file `fd` (16 KiB-aligned
    /// offset), mapped shared and writable from the host's page cache. Every
    /// view of the same file — in any VM of this host process — and the
    /// host's own `read`/`write` on the file see the same bytes, as a Darwin
    /// shared file mapping does (mmap(2), level 1). Host pages wholly past
    /// the end of the file are private zero pages (Darwin would fault on
    /// them; zeros are the lenient answer). Nil when `fd` is not open for
    /// reading and writing, or the host refuses the mapping; the caller then
    /// maps the file private.
    public init?(hostFile fd: Int32, offset: UInt64, size: UInt64, fileSize: UInt64) {
        let page = VMLayout.pageSize
        let rounded = (max(size, 1) + page - 1) & ~(page - 1)
        guard offset & (page - 1) == 0, rounded <= 1 << 36, fileSize > offset else { return nil }
        guard fcntl(fd, F_GETFL) & O_ACCMODE == O_RDWR else { return nil }
        let hostPage = UInt64(max(sysconf(Int32(_SC_PAGESIZE)), 4096))
        let fileBytes = min((fileSize - offset + hostPage - 1) & ~(hostPage - 1), rounded)
        guard let reservation = mmap(nil, Int(rounded), PROT_READ | PROT_WRITE, MAP_PRIVATE | Self.anonymous, -1, 0),
              reservation != MAP_FAILED else { return nil }
        #if canImport(Darwin)
        let fileOffset = off_t(offset)
        #else
        let fileOffset = __off_t(offset)
        #endif
        guard let p = mmap(reservation, Int(fileBytes), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, fileOffset),
              p == reservation else {
            munmap(reservation, Int(rounded))
            return nil
        }
        self.size = rounded
        self.host = p
        isFileView = true
        serial = Self.counterLock.withLock {
            Self.counter += 1
            return Self.counter
        }
    }

    deinit {
        if Self.quarantine {
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
        bytes.withUnsafeBytes { if $0.count > 0 { (host + Int(offset)).copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
    }
}

/// A tiny mutex over pthread (the module has no Foundation dependency here).
final class NSLockLike: @unchecked Sendable {
    private var mutex = pthread_mutex_t()
    init() { pthread_mutex_init(&mutex, nil) }
    deinit { pthread_mutex_destroy(&mutex) }
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        pthread_mutex_lock(&mutex)
        defer { pthread_mutex_unlock(&mutex) }
        return try body()
    }
}
