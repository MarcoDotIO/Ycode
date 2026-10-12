// One host mapping of each file that guests map without write access, shared
// by every VM of this host process (simulator stage 6 §5). The arena is one
// large host reservation; each file gets a 16 KiB-aligned span in it, mapped
// read-only from the file once, plus zero-filled host pages up to the 16 KiB
// granule. Every VM registers the whole arena once, as one read-only KVM
// memslot at the same GPA (`KVMPhysicalBacking`), so a guest file mapping
// served from the arena needs neither a host mmap nor a memslot, and every
// VM sees the file at the same guest-physical address.
//
// Files are told apart by (device, inode, size, mtime): a file that changes
// size or modification time gets a new span; spans are never reused (the
// arena only grows, up to its size and `maximumFiles`).

#if os(Linux) && arch(arm64)
import Glibc

public final class SharedFileArena: @unchecked Sendable {
    /// The process-wide arena (nil when the host refuses the reservation).
    public static let shared: SharedFileArena? = SharedFileArena(size: defaultSize)
    public static let defaultSize: UInt64 = 64 << 30
    /// Smaller files keep a private memslot per mapping.
    public static let minimumFileSize: UInt64 = 0
    public static let maximumFiles = 4096
    static let granule: UInt64 = 1 << 14

    /// The host reservation [base, base + size).
    public let base: UnsafeMutableRawPointer
    public let size: UInt64

    private struct Key: Hashable {
        var device: UInt64
        var inode: UInt64
        var size: Int64
        var mtimeSeconds: Int
        var mtimeNanoseconds: Int
    }

    private let lock = HostMutex()
    private var spans: [Key: (offset: UInt64, span: UInt64)] = [:]
    private var next: UInt64 = 0

    init?(size: UInt64) {
        guard let p = mmap(nil, Int(size), PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0), p != MAP_FAILED else {
            return nil
        }
        base = p
        self.size = size
    }

    /// Files mapped into the arena so far.
    public var fileCount: Int { lock.withLock { spans.count } }
    /// Bytes of the arena in use.
    public var bytesUsed: UInt64 { lock.withLock { next } }

    /// The arena offset of bytes [offset, offset+size) of the open host file
    /// `hostFD` (16 KiB-aligned offset and size), mapping the file on first
    /// use. Nil when the arena cannot serve it: not a regular file, smaller
    /// than `minimumFileSize`, a range past the file's last 16 KiB granule,
    /// or the arena full.
    public func view(hostFD: Int32, offset: UInt64, size: UInt64) -> UInt64? {
        var st = stat()
        guard fstat(hostFD, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size > 0 else { return nil }
        let fileSize = UInt64(st.st_size)
        guard fileSize >= Self.minimumFileSize else { return nil }
        let key = Key(device: UInt64(st.st_dev), inode: UInt64(st.st_ino), size: Int64(st.st_size),
                      mtimeSeconds: Int(st.st_mtim.tv_sec), mtimeNanoseconds: Int(st.st_mtim.tv_nsec))
        return lock.withLock { () -> UInt64? in
            let entry: (offset: UInt64, span: UInt64)
            if let e = spans[key] {
                entry = e
            } else {
                guard spans.count < Self.maximumFiles else { return nil }
                let span = (fileSize + Self.granule - 1) & ~(Self.granule - 1)
                // One unused granule after each file keeps spans apart.
                guard next <= self.size, span + Self.granule <= self.size - next else { return nil }
                let hostPage = UInt64(max(sysconf(Int32(_SC_PAGESIZE)), 4096))
                let fileBytes = min((fileSize + hostPage - 1) & ~(hostPage - 1), span)
                let at = base + Int(next)
                // Whatever happens below, this span is never handed out again.
                defer { next += span + Self.granule }
                guard let p = mmap(at, Int(fileBytes), PROT_READ, MAP_SHARED | MAP_FIXED, hostFD, 0), p == at else {
                    // MAP_FIXED may have dropped part of the reservation: put it back.
                    _ = mmap(at, Int(fileBytes), PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE | MAP_FIXED, -1, 0)
                    return nil
                }
                if span > fileBytes {
                    // The rest of the last granule reads as zeros.
                    let tail = mmap(at + Int(fileBytes), Int(span - fileBytes), PROT_READ,
                                    MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0)
                    guard tail == at + Int(fileBytes) else {
                        _ = mmap(at, Int(span), PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE | MAP_FIXED, -1, 0)
                        return nil
                    }
                }
                entry = (next, span)
                spans[key] = entry
            }
            guard offset <= entry.span, size <= entry.span - offset else { return nil }
            return entry.offset + offset
        }
    }
}
#endif
