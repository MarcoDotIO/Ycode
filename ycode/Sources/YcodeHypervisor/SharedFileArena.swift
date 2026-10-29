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
import CKVM
import Foundation
import Glibc
import Synchronization

public final class SharedFileArena: @unchecked Sendable {
    /// The process-wide arena (nil when the host refuses the reservation).
    public static let shared: SharedFileArena? = SharedFileArena(size: defaultSize)
    public static let defaultSize: UInt64 = 64 << 30
    /// Smaller files keep a private memslot per mapping.
    public static let minimumFileSize: UInt64 = 0
    /// Spans are never reused, and a file under a writable prefix that
    /// changes (size or mtime) takes a new one each time, so a boot that
    /// installs an app passes 4096 files (`performance-contract.md` §6,
    /// C16 note). Past the limit, read-only mappings fall back to private
    /// mappings (correct, slower).
    /// `YCODE_ARENA_MAX_FILES=<n>` overrides it (diagnostics).
    public static let maximumFiles = getenv("YCODE_ARENA_MAX_FILES").flatMap { Int(String(cString: $0)) } ?? 32768
    /// Set once the arena first refuses a file for lack of room (logged once).
    private var reportedFull = false
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

    private let lock = HostMutex(name: "shared file window")
    private var spans: [Key: (offset: UInt64, span: UInt64)] = [:]
    private var next: UInt64 = 0

    /// `YCODE_ARENA_HUGE=1` (`performance-contract.md` §6, C18): a file of
    /// at least `hugeMinimum` bytes (the shared cache) gets a 2 MiB-aligned
    /// span, and a background thread replaces its page-cache mapping with an
    /// anonymous copy in transparent huge pages (`promote`). KVM then maps
    /// the guests' views of it with 2 MiB stage-2 blocks instead of 4 KiB
    /// pages: far fewer stage-2 faults per process, and guest TLB entries
    /// that cover a whole 16 KiB guest page.
    public static let hugeEnabled = hugeWholeFile || hugeHotChunks
    static let hugeWholeFile = getenv("YCODE_ARENA_HUGE").map { String(cString: $0) == "1" } ?? false
    /// `YCODE_ARENA_HUGE=hot` (boot-profile.md §9, SP4): instead of copying
    /// the whole file, a background thread promotes each 2 MiB chunk of a
    /// huge span once part of it is in the host page cache (`mincore`):
    /// the chunk is copied into its own 2 MiB-aligned anonymous memory
    /// (a transparent huge page when one is free) and moved over the arena
    /// chunk with `mremap`. Only the cache's hot set is copied, from the
    /// page cache, so no promotion waits for the disk for long.
    static let hugeHotChunks = getenv("YCODE_ARENA_HUGE").map { String(cString: $0) == "hot" } ?? false
    /// `YCODE_ARENA_HUGE_INTERVAL_MS` (default 1000): the promoter's pass interval.
    static let hugeInterval = getenv("YCODE_ARENA_HUGE_INTERVAL_MS").flatMap { UInt32(String(cString: $0)) }.map { max(50, $0) } ?? 1000
    /// `YCODE_ARENA_HUGE_MADVISE` (boot-profile.md §9): whether the copy
    /// asks for huge pages with `MADV_HUGEPAGE`. With the host's THP mode
    /// `always` the copy gets huge pages without it, from free 2 MiB blocks
    /// only (no direct compaction under the `madvise` defrag mode: the
    /// 74–82 s copies of §3.4 were compaction stalls); a 2 MiB piece that
    /// finds none stays in 4 KiB pages. Default: only when the mode is not
    /// `always`; `=1` always, `=0` never.
    public static let hugeMadvise: Bool = {
        if let v = getenv("YCODE_ARENA_HUGE_MADVISE") { return String(cString: v) == "1" }
        let mode = (try? String(contentsOfFile: "/sys/kernel/mm/transparent_hugepage/enabled", encoding: .utf8)) ?? ""
        return !mode.contains("[always]")
    }()
    /// `YCODE_ARENA_HUGE_THREADS=<n>` (default 8): threads that fill the copy.
    public static let hugeThreads = getenv("YCODE_ARENA_HUGE_THREADS").flatMap { Int(String(cString: $0)) }.map { max(1, min(32, $0)) } ?? 8
    public static let hugeMinimum: UInt64 = 256 << 20
    /// `YCODE_ARENA_ZERO_TAILS` (default on, `=0` off; boot-profile.md §9, SP3):
    /// the reservation is readable (untouched pages read as zeros), so the
    /// rest of a file's last 16 KiB granule needs no zero mapping of its own:
    /// one host `mmap` less per new file (each takes the host process's
    /// address-space lock for writing). Off: an inaccessible reservation and
    /// a read-only zero mapping after each file, as before.
    static let zeroTails = getenv("YCODE_ARENA_ZERO_TAILS").map { String(cString: $0) != "0" } ?? true
    static var reserveProtection: Int32 { zeroTails ? PROT_READ : PROT_NONE }
    static let huge: UInt64 = 2 << 20

    init?(size: UInt64) {
        // 2 MiB alignment of the base (huge spans need it).
        let slack = Int(Self.huge)
        guard let raw = mmap(nil, Int(size) + slack, Self.reserveProtection, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0),
              raw != MAP_FAILED else {
            return nil
        }
        let aligned = (UInt(bitPattern: raw) + UInt(slack) - 1) & ~(UInt(slack) - 1)
        base = UnsafeMutableRawPointer(bitPattern: aligned)!
        self.size = size
    }

    /// Promotions done (diagnostics): spans copied, bytes, milliseconds.
    public private(set) var promotions: [(bytes: UInt64, milliseconds: UInt64, hugeBytes: UInt64)] = []

    /// Diagnostics: `AnonHugePages` of the host mapping that starts at
    /// `address` (/proc/self/smaps), in bytes.
    static func anonHugeBytes(at address: UInt) -> UInt64 {
        guard let text = try? String(contentsOfFile: "/proc/self/smaps", encoding: .utf8) else { return 0 }
        let prefix = String(address, radix: 16) + "-"
        var inside = false
        for line in text.split(separator: "\n") {
            if let first = line.first, first.isHexDigit, line.contains("-") {
                if inside { break }
                inside = line.hasPrefix(prefix)
            } else if inside, line.hasPrefix("AnonHugePages:") {
                let kb = line.split(separator: " ", omittingEmptySubsequences: true).dropFirst().first.flatMap { UInt64($0) } ?? 0
                return kb << 10
            }
        }
        return 0
    }

    /// Copies [at, at+span) of the file (whose first `fileBytes` bytes are
    /// file data, the rest zeros) into fresh anonymous memory that asks for
    /// huge pages, makes it read-only, and moves it over the span with one
    /// mremap (atomic for every reader: the old and the new pages hold the
    /// same bytes). Runs on its own thread; `fd` is a duplicate it closes.
    private func promote(at: UnsafeMutableRawPointer, span: UInt64, fd: Int32, fileBytes: UInt64) {
        defer { close(fd) }
        let began = monotonicNanosecondsForArena()
        let slack = Int(Self.huge)
        guard let raw = mmap(nil, Int(span) + slack, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0),
              raw != MAP_FAILED else { return }
        let start = (UInt(bitPattern: raw) + UInt(slack) - 1) & ~(UInt(slack) - 1)
        let copy = UnsafeMutableRawPointer(bitPattern: start)!
        // Trim the slack around the aligned copy.
        let head = Int(start - UInt(bitPattern: raw))
        if head > 0 { munmap(raw, head) }
        let tail = slack - head
        if tail > 0 { munmap(copy + Int(span), tail) }
        if Self.hugeMadvise { _ = madvise(copy, Int(span), 14 /* MADV_HUGEPAGE */) }
        // Fill with `hugeThreads` threads taking 64 MiB pieces in turn (the
        // file is in the page cache after the guests' first use; this is a
        // memory copy).
        let chunk = UInt64(64 << 20)
        let pieces = Int((fileBytes + chunk - 1) / chunk)
        let failed = Atomic<Bool>(false)
        let nextPiece = Atomic<Int>(0)
        let copyAddress = UInt(bitPattern: copy)
        DispatchQueue.concurrentPerform(iterations: min(Self.hugeThreads, max(1, pieces))) { _ in
            while true {
                let i = nextPiece.wrappingAdd(1, ordering: .relaxed).oldValue
                guard i < pieces, !failed.load(ordering: .relaxed) else { return }
                var done = UInt64(i) * chunk
                let end = min(fileBytes, done + chunk)
                while done < end {
                    let n = pread(fd, UnsafeMutableRawPointer(bitPattern: copyAddress)! + Int(done), Int(end - done), off_t(done))
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { failed.store(true, ordering: .relaxed); return }
                    done += UInt64(n)
                }
            }
        }
        guard !failed.load(ordering: .relaxed) else { munmap(copy, Int(span)); return }
        guard mprotect(copy, Int(span), PROT_READ) == 0 else { munmap(copy, Int(span)); return }
        // MREMAP_MAYMOVE | MREMAP_FIXED: replaces the file mapping at `at`.
        let moved = ckvm_mremap_fixed(copy, Int(span), at)
        guard moved == at else { munmap(copy, Int(span)); return }
        let ms = (monotonicNanosecondsForArena() &- began) / 1_000_000
        let hugeBytes = Self.anonHugeBytes(at: UInt(bitPattern: at))
        lock.withLock { promotions.append((span, ms, hugeBytes)) }
    }

    /// Huge spans waiting for chunk promotion (hot mode). Guarded by `lock`.
    private final class HotSpan {
        let at: UInt
        let span: UInt64
        let fd: Int32
        let fileBytes: UInt64
        var promoted: [Bool]
        init(at: UInt, span: UInt64, fd: Int32, fileBytes: UInt64) {
            self.at = at; self.span = span; self.fd = fd; self.fileBytes = fileBytes
            promoted = [Bool](repeating: false, count: Int(span / SharedFileArena.huge))
        }
    }
    private var hotSpans: [HotSpan] = []
    private var promoterStarted = false
    /// Hot mode diagnostics: chunks promoted, failed, and the promoter's time.
    public let hotChunks = Atomic<UInt64>(0)
    public let hotChunkFailures = Atomic<UInt64>(0)
    public let hotNanoseconds = Atomic<UInt64>(0)

    /// The promoter (hot mode): every `hugeInterval` ms, promote the chunks
    /// of every huge span that have a page in the page cache.
    private func promoterLoop() {
        var vector: [UInt8] = []
        while true {
            usleep(Self.hugeInterval * 1000)
            let list = lock.withLock { hotSpans }
            for span in list {
                let pages = Int((span.fileBytes + 4095) / 4096)
                if vector.count < pages { vector = [UInt8](repeating: 0, count: pages) }
                let ok = vector.withUnsafeMutableBufferPointer { v in
                    mincore(UnsafeMutableRawPointer(bitPattern: span.at)!, Int(span.fileBytes + 4095) & ~4095, v.baseAddress!) == 0
                }
                guard ok else { continue }
                let pagesPerChunk = Int(Self.huge / 4096)
                for chunk in 0..<span.promoted.count where !lock.withLock({ span.promoted[chunk] }) {
                    let first = chunk * pagesPerChunk
                    guard first < pages else { break }
                    let last = min(pages, first + pagesPerChunk)
                    var resident = false
                    for i in first..<last where vector[i] & 1 != 0 { resident = true; break }
                    guard resident else { continue }
                    let began = monotonicNanosecondsForArena()
                    if promoteChunk(span, chunk) {
                        hotChunks.wrappingAdd(1, ordering: .relaxed)
                    } else {
                        hotChunkFailures.wrappingAdd(1, ordering: .relaxed)
                    }
                    lock.withLock { span.promoted[chunk] = true }
                    hotNanoseconds.wrappingAdd(monotonicNanosecondsForArena() &- began, ordering: .relaxed)
                }
            }
        }
    }

    /// Copies chunk `chunk` (2 MiB) of `span` into fresh 2 MiB-aligned
    /// anonymous memory (file bytes, zeros past the end of the file), makes
    /// it read-only and moves it over the arena chunk (one `mremap`, atomic
    /// for every reader: both hold the same bytes). False (nothing changed)
    /// on any failure.
    private func promoteChunk(_ span: HotSpan, _ chunk: Int) -> Bool {
        let size = Int(Self.huge)
        guard let raw = mmap(nil, 2 * size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0),
              raw != MAP_FAILED else { return false }
        let start = (UInt(bitPattern: raw) + UInt(size) - 1) & ~(UInt(size) - 1)
        let copy = UnsafeMutableRawPointer(bitPattern: start)!
        let head = Int(start - UInt(bitPattern: raw))
        if head > 0 { munmap(raw, head) }
        if size - head > 0 { munmap(copy + size, size - head) }
        if Self.hugeMadvise { _ = madvise(copy, size, 14 /* MADV_HUGEPAGE */) }
        let offset = UInt64(chunk) * Self.huge
        let fileEnd = min(span.fileBytes, offset + Self.huge)
        var done = offset
        while done < fileEnd {
            let n = pread(span.fd, copy + Int(done - offset), Int(fileEnd - done), off_t(done))
            if n < 0 && errno == EINTR { continue }
            if n == 0 { break }   // the end of the file: the rest stays zero
            if n < 0 { munmap(copy, size); return false }
            done += UInt64(n)
        }
        guard mprotect(copy, size, PROT_READ) == 0 else { munmap(copy, size); return false }
        let at = UnsafeMutableRawPointer(bitPattern: span.at + UInt(offset))!
        guard ckvm_mremap_fixed(copy, size, at) == at else { munmap(copy, size); return false }
        return true
    }

    /// Lock held.
    private func noteFull() {
        guard !reportedFull else { return }
        reportedFull = true
        FileHandle.standardError.write(("ycode-simd: shared file arena full (\(spans.count) files, \(next >> 20) MiB): "
            + "further read-only file mappings are private\n").data(using: .utf8)!)
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
                guard spans.count < Self.maximumFiles else { noteFull(); return nil }
                let huge = Self.hugeEnabled && fileSize >= Self.hugeMinimum
                let alignment = huge ? Self.huge : Self.granule
                let span = (fileSize + alignment - 1) & ~(alignment - 1)
                if huge { next = (next + Self.huge - 1) & ~(Self.huge - 1) }
                // One unused granule after each file keeps spans apart.
                guard next <= self.size, span + Self.granule <= self.size - next else { noteFull(); return nil }
                let hostPage = UInt64(max(sysconf(Int32(_SC_PAGESIZE)), 4096))
                let fileBytes = min((fileSize + hostPage - 1) & ~(hostPage - 1), span)
                let at = base + Int(next)
                // Whatever happens below, this span is never handed out again.
                defer { next += span + Self.granule }
                guard let p = mmap(at, Int(fileBytes), PROT_READ, MAP_SHARED | MAP_FIXED, hostFD, 0), p == at else {
                    // MAP_FIXED may have dropped part of the reservation: put it back.
                    _ = mmap(at, Int(fileBytes), Self.reserveProtection, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE | MAP_FIXED, -1, 0)
                    return nil
                }
                if span > fileBytes, !Self.zeroTails {
                    // The rest of the last granule reads as zeros.
                    let tail = mmap(at + Int(fileBytes), Int(span - fileBytes), PROT_READ,
                                    MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0)
                    guard tail == at + Int(fileBytes) else {
                        _ = mmap(at, Int(span), Self.reserveProtection, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE | MAP_FIXED, -1, 0)
                        return nil
                    }
                }
                entry = (next, span)
                spans[key] = entry
                if huge, Self.hugeHotChunks {
                    let copyFD = dup(hostFD)
                    if copyFD >= 0 {
                        hotSpans.append(HotSpan(at: UInt(bitPattern: at), span: span, fd: copyFD, fileBytes: fileBytes))
                        if !promoterStarted {
                            promoterStarted = true
                            let thread = Thread { [self] in promoterLoop() }
                            thread.name = "ycode arena promoter"
                            thread.start()
                        }
                    }
                } else if huge {
                    let copyFD = dup(hostFD)
                    if copyFD >= 0 {
                        let fileBytesForCopy = fileBytes
                        let atAddress = UInt(bitPattern: at)
                        Thread.detachNewThread { [self] in
                            self.promote(at: UnsafeMutableRawPointer(bitPattern: atAddress)!, span: span, fd: copyFD, fileBytes: fileBytesForCopy)
                        }
                    }
                }
            }
            guard offset <= entry.span, size <= entry.span - offset else { return nil }
            return entry.offset + offset
        }
    }
}

private func monotonicNanosecondsForArena() -> UInt64 {
    var now = timespec()
    clock_gettime(CLOCK_MONOTONIC, &now)
    return UInt64(now.tv_sec) * 1_000_000_000 + UInt64(now.tv_nsec)
}
#endif
