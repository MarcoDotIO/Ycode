// ycode-simd: building one process image in a fresh VM (stage 3a layout,
// stage-4a vCPU slots), and the helpers it needs. Contracts:
// specs/simulator/stage3-contract.md, host-libraries.md, stage4a-contract.md.

#if os(Linux) && arch(arm64)
import Foundation
import Glibc
import YcodeDarwinABI
import YcodeDarwinKernel
import YcodeHypervisor
import YcodeMachO

// MARK: - Stage 3a: helpers

let pageSize = VMLayout.pageSize
func roundUpPage(_ v: UInt64) -> UInt64 { (v + pageSize - 1) & ~(pageSize - 1) }
func roundDownPage(_ v: UInt64) -> UInt64 { v & ~(pageSize - 1) }

/// The real path of this executable (for locating SimShim/out next to the package).
func executableDirectory() -> String? {
    var buffer = [Int8](repeating: 0, count: 4096)
    let n = readlink("/proc/self/exe", &buffer, buffer.count - 1)
    guard n > 0 else { return nil }
    let path = String(decoding: buffer[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return (path as NSString).deletingLastPathComponent
}

/// Finds `SimShim/out/<name>`: the explicit path, then the current
/// directory, then the package directory that holds this executable
/// (`<package>/.build/<config>/ycode-simd`).
func locateSimShimFile(_ name: String, explicit: String?) -> String {
    if let explicit { return explicit }
    var candidates = ["SimShim/out/\(name)"]
    if let dir = executableDirectory() {
        candidates.append("\(dir)/../../SimShim/out/\(name)")
        candidates.append("\(dir)/../../../SimShim/out/\(name)")
        candidates.append("\(dir)/../../../../SimShim/out/\(name)")
    }
    for c in candidates where access(c, R_OK) == 0 { return c }
    die("cannot find SimShim/out/\(name) (tried \(candidates.joined(separator: ", "))); pass it explicitly", status: 66)
}

/// Finds Ycode's host-library directory: the explicit path, then
/// `SimHostLibs/out` in the current directory, then next to the package that
/// holds this executable. Nil when none exists.
func locateHostLibraryDirectory(explicit: String?) -> (path: String?, tried: [String]) {
    if let explicit { return (absolutePath(explicit), [explicit]) }
    var candidates = ["SimHostLibs/out"]
    if let dir = executableDirectory() {
        candidates.append("\(dir)/../../SimHostLibs/out")
        candidates.append("\(dir)/../../../SimHostLibs/out")
        candidates.append("\(dir)/../../../../SimHostLibs/out")
    }
    var isDirectory: ObjCBool = false
    for c in candidates where FileManager.default.fileExists(atPath: c, isDirectory: &isDirectory) && isDirectory.boolValue {
        return (absolutePath(c), candidates)
    }
    return (nil, candidates)
}

/// The three host libraries (`host-libraries.md` §1), as guest paths.
let hostLibraryNames = ["kernel", "platform", "pthread"]
func hostLibraryGuestPath(_ name: String) -> String { "/usr/lib/system/libsystem_\(name).dylib" }

func absolutePath(_ path: String) -> String {
    if path.hasPrefix("/") { return (path as NSString).standardizingPath }
    let cwd = FileManager.default.currentDirectoryPath
    return ((cwd as NSString).appendingPathComponent(path) as NSString).standardizingPath
}

/// Mach-O protection bits → VMProtection (same bit values: r 1, w 2, x 4).
func vmProtection(_ p: Protection) -> VMProtection { VMProtection(rawValue: p.rawValue & 7) }

/// The `LC_UNIXTHREAD` PC of an arm64 image (`ARM_THREAD_STATE64`, flavor 6:
/// the PC is 64-bit word 32 of the register state), or nil.
func unixThreadPC(_ reader: ByteReader, headerOffset: Int) -> UInt64? {
    guard let ncmds = try? reader.u32(headerOffset + 16) else { return nil }
    var p = headerOffset + 32
    for _ in 0..<ncmds {
        guard let cmd = try? reader.u32(p), let size = try? reader.u32(p + 4), size >= 8 else { return nil }
        if cmd == 0x5, let flavor = try? reader.u32(p + 8), flavor == 6, size >= 16 + 33 * 8 {
            return try? reader.u64(p + 16 + 32 * 8)
        }
        p += Int(size)
    }
    return nil
}

/// One image the VMM knows about, for attributing addresses.
struct GuestImage {
    var name: String
    var start: UInt64
    var end: UInt64
    /// The address offsets are reported against (the mach header).
    var base: UInt64
}

/// The dyld shared cache of the runtime, parsed once per host process and
/// shared by every image's `ImageMap` (each image of a run maps the same
/// cache). Thread-safe.
final class SharedCacheIndex: @unchecked Sendable {
    let cachePath: String
    private let lock = HostMutex()
    private var cache: SharedCache?
    private var loadFailed = false
    private var images: [GuestImage]?
    private var crashInfo: [(image: String, address: UInt64, size: UInt64)]?
    private var mappingList: [(file: String, mapping: SharedCache.Mapping)]?
    private var firstMapping: SharedCache.Mapping??

    init(cachePath: String) { self.cachePath = cachePath }

    private func sharedCacheLocked() -> SharedCache? {
        if cache == nil && !loadFailed {
            do { cache = try SharedCache(contentsOf: URL(fileURLWithPath: cachePath)) } catch {
                loadFailed = true
                stderrLine("ycode-simd: cannot read the shared cache \(cachePath): \(error)")
            }
        }
        return cache
    }

    /// Every mapping of every cache file (main file first), as in the headers.
    func mappings() -> [(file: String, mapping: SharedCache.Mapping)] {
        lock.withLock {
            if let mappingList { return mappingList }
            guard let cache = sharedCacheLocked() else { return [] }
            let list = cache.files.flatMap { f in f.mappings.map { (f.url.path, $0) } }
            mappingList = list
            return list
        }
    }

    /// The main file's first mapping (for addresses outside every image).
    func mainMapping() -> SharedCache.Mapping? {
        lock.withLock {
            if let firstMapping { return firstMapping }
            let first = sharedCacheLocked()?.mainFile.mappings.first
            firstMapping = .some(first)
            return first
        }
    }

    /// Every cache image's `__crash_info` section (any `__DATA*` segment) at
    /// its header address: the CrashReporter annotations a library fills
    /// before it traps (Libc `CrashReporterClient.h`, level 1).
    func crashInfoSections() -> [(image: String, address: UInt64, size: UInt64)] {
        lock.withLock {
            if let crashInfo { return crashInfo }
            guard let cache = sharedCacheLocked() else { return [] }
            var list: [(image: String, address: UInt64, size: UInt64)] = []
            for image in cache.images {
                guard let macho = try? cache.machO(for: image) else { continue }
                for segment in macho.segments where segment.name.hasPrefix("__DATA") {
                    for section in segment.sections where section.name == "__crash_info" {
                        list.append((image.path, section.address, section.size))
                    }
                }
            }
            crashInfo = list
            return list
        }
    }

    /// The cache images' __TEXT ranges at their header addresses, sorted.
    func cacheImages() -> [GuestImage] {
        lock.withLock {
            if let images { return images }
            guard let cache = sharedCacheLocked() else { return [] }
            var list: [GuestImage] = []
            for image in cache.images {
                guard let macho = try? cache.machO(for: image), let text = macho.segment(named: "__TEXT") else { continue }
                list.append(GuestImage(name: image.path, start: text.vmAddress, end: text.vmAddress + text.vmSize, base: image.address))
            }
            list.sort { $0.start < $1.start }
            images = list
            return list
        }
    }
}

/// Attributes guest addresses to images: the main executable, dyld_sim, the
/// host page, and shared-cache images (their __TEXT ranges, from the cache's
/// image list; the cache is never slid, but the VMM records the address
/// delta it observes in dyld_sim's mmap calls). One per image (VM).
final class ImageMap {
    var fixed: [GuestImage] = []
    /// Ycode's host libraries are mapped by dyld_sim through `mmap` of their
    /// VFS files; they are found through the address space's file-backed
    /// regions with these guest paths.
    var space: GuestAddressSpace?
    var hostLibraryPaths: Set<String> = []
    static let hostLibrarySuffix = " [ycode]"
    let cache: SharedCacheIndex
    /// Observed (mapped address − header address); 0 when dyld_sim maps the cache at the header addresses.
    var cacheDelta: UInt64 = 0

    init(cache: SharedCacheIndex) { self.cache = cache }

    /// Every mapping of every cache file (main file first), as in the headers.
    func cacheMappings() -> [(file: String, mapping: SharedCache.Mapping)] { cache.mappings() }

    /// An address in one of Ycode's host libraries. The base is the
    /// containing mapping's VA minus its file offset, which is the mach
    /// header for `__TEXT` (where ELR and LR point).
    private func hostLibrary(_ address: UInt64) -> (image: GuestImage, offset: UInt64)? {
        guard !hostLibraryPaths.isEmpty, let space, let file = space.file(at: address),
              hostLibraryPaths.contains(file.guestPath),
              let region = space.region(containing: address), case let .file(_, fileOffset, _) = region.backing else {
            return nil
        }
        let base = region.va &- fileOffset
        return (GuestImage(name: file.guestPath + Self.hostLibrarySuffix, start: region.va, end: region.end, base: base),
                address &- base)
    }

    func attribute(_ address: UInt64) -> (image: GuestImage, offset: UInt64)? {
        if let image = fixed.first(where: { address >= $0.start && address < $0.end }) {
            return (image, address - image.base)
        }
        if let hit = hostLibrary(address) { return hit }
        guard address >= VMLayout.sharedRegionBase, address < VMLayout.sharedRegionEnd else { return nil }
        let cacheImages = cache.cacheImages()
        let header = address &- cacheDelta
        var low = 0, high = cacheImages.count
        while low < high {
            let mid = (low + high) / 2
            if cacheImages[mid].start <= header { low = mid + 1 } else { high = mid }
        }
        if low > 0, header < cacheImages[low - 1].end {
            let image = cacheImages[low - 1]
            return (image, header - image.base)
        }
        if let first = cache.mainMapping() {
            return (GuestImage(name: "dyld shared cache", start: first.address, end: first.address, base: first.address), header &- first.address)
        }
        return nil
    }

    func describe(_ address: UInt64) -> String {
        guard let (image, offset) = attribute(address) else { return hex(address) }
        return "\(image.name) + \(hex(offset))"
    }
}

/// Tracks dyld_sim's mmap calls of the shared-cache files.
struct CacheMappingTracker {
    struct Pending { var address: UInt64; var size: UInt64; var flags: UInt64; var fd: Int32; var offset: UInt64; var path: String? }
    var expected: [(file: String, mapping: SharedCache.Mapping)] = []
    /// Indices of `expected` seen mapped, with the address used.
    var seen: [Int: UInt64] = [:]
    var pending: Pending?
}

// MARK: - Stage 3a: the process image

/// Stage 4a: the vCPU slots (`VCPUSlots`, GPA 0x4100_0000, 4 MiB) lie inside
/// the stage-3 table arena (0x4020_0000 + 64 MiB), so the arena moves to
/// 0x4200_0000 (64 MiB, up to 0x4600_0000, inside the 1 GiB of RAM).
let stage4TableArenaGPA: UInt64 = 0x4200_0000

/// The EL1 identity regions of an --exec VM: the stage-3 ones with the table
/// arena moved, plus the vCPU slots.
let stage4EL1Regions: [VMLayout.Region] = VMLayout.stage3EL1Regions.map { r in
    guard r.name == "page-tables" else { return r }
    return VMLayout.Region(name: r.name, va: stage4TableArenaGPA, size: VMLayout.stage3PageTableArenaSize, attributes: r.attributes)
} + [VCPUSlots.region]

/// A loaded Mach-O image (main executable or dyld_sim).
struct LoadedImage {
    var image: GuestImage
    var machHeader: UInt64
    var slide: UInt64
    var entry: UInt64?
    var uuid: UUID?
}

enum LoaderError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case let .message(m) = self { return m }; return "" }
}

/// Builds the stage-3a process image in a fresh VM.
final class ProcessBuilder {
    let vm: VirtualMachine
    let backing: KVMPhysicalBacking
    let space: GuestAddressSpace
    /// Trace sink (nil = quiet).
    let traceLog: ((String) -> Void)?

    init(log: ((String) -> Void)?) throws {
        self.traceLog = log
        let vm = try VirtualMachine(ramGPA: VMLayout.ramGPA, ramSize: Int(VMLayout.stage3RAMSize))
        self.vm = vm
        do {
            backing = try KVMPhysicalBacking(vm: vm, poolGPA: VMLayout.anonymousPoolGPA, poolSize: VMLayout.anonymousPoolSize,
                                         fileWindowGPA: VMLayout.fileSlotGPABase,
                                         physicalAddressBits: VMLayout.physicalAddressBits)
        } catch {
            vm.close()
            throw error
        }
        var tables = PageTableBuilder(tableArenaGPA: stage4TableArenaGPA, tableArenaSize: Int(VMLayout.stage3PageTableArenaSize))
        for region in stage4EL1Regions { try tables.mapIdentity(region) }
        space = GuestAddressSpace(backing: backing, pageTables: tables)
        try space.flushPageTables()
    }

    func log(_ text: @autoclosure () -> String) { if let traceLog { traceLog(text()) } }

    /// Writes into guest memory regardless of page permissions (VMM loads).
    func poke(_ va: UInt64, _ bytes: [UInt8]) throws {
        try space.write(va: va, bytes: bytes, checkingEL0Access: false)
    }

    /// Maps one segment: the file part with `protection` at `va`, then the
    /// zero-fill part (anonymous, `zeroFillProtection`). The bytes of the last
    /// file page beyond `fileSize` are zeroed when the segment has zero fill.
    func mapSegment(file: GuestFile, name: String, va: UInt64, vmSize: UInt64, fileOffset: UInt64, fileSize: UInt64,
                    protection: VMProtection, zeroFillProtection: VMProtection) throws {
        let fileSpan = roundUpPage(fileSize)
        let vmSpan = roundUpPage(vmSize)
        if fileSize > 0 {
            _ = try space.mapFile(file, offset: fileOffset, at: va, size: fileSpan,
                                  protection: protection, hint: nil)
            if vmSize > fileSize, fileSpan > fileSize {
                try poke(va + fileSize, [UInt8](repeating: 0, count: Int(min(fileSpan, vmSpan) - fileSize)))
            }
        }
        if vmSpan > fileSpan {
            _ = try space.mapAnonymous(at: va + fileSpan, size: vmSpan - fileSpan, protection: zeroFillProtection, hint: nil)
        }
        log("map \(name) \(hex(va))-\(hex(va + max(vmSpan, fileSpan))) \(protection) file \(hex(fileOffset))+\(hex(fileSize))")
    }

    /// The main executable: every segment at its preferred vmaddr (no slide),
    /// with its initprot; __PAGEZERO (no access, no file data) is skipped.
    func loadMainExecutable(path: String, hostPath: String) throws -> LoadedImage {
        let file = try GuestFile.openReadOnly(hostPath: hostPath, guestPath: path)
        let fat = try MachOFile(contentsOf: URL(fileURLWithPath: hostPath))
        guard let slice = fat.slices.first(where: { $0.cpuType == MachO.cpuTypeARM64 && $0.cpuSubtype & 0x00FF_FFFF == 0 })
                ?? fat.slices.first(where: { $0.cpuType == MachO.cpuTypeARM64 }) else {
            throw LoaderError.message("\(path) has no arm64 slice")
        }
        let image = try MachOImage(fat.reader, at: slice.offset)
        guard image.fileType == .executable else { throw LoaderError.message("\(path) is not an executable (MH_EXECUTE)") }
        var header: UInt64?
        var low = UInt64.max, high: UInt64 = 0
        for segment in image.segments {
            if segment.vmSize == 0 { continue }
            if segment.fileSize == 0 && segment.initialProtection.rawValue == 0 { continue }   // __PAGEZERO
            if segment.fileOffset == 0 && segment.fileSize > 0 { header = segment.vmAddress }
            try mapSegment(file: file, name: "\((path as NSString).lastPathComponent) \(segment.name)", va: segment.vmAddress,
                           vmSize: segment.vmSize, fileOffset: UInt64(slice.offset) + segment.fileOffset,
                           fileSize: segment.fileSize, protection: vmProtection(segment.initialProtection),
                           zeroFillProtection: vmProtection(segment.initialProtection))
            low = min(low, segment.vmAddress)
            high = max(high, segment.vmAddress + roundUpPage(segment.vmSize))
        }
        guard let header else { throw LoaderError.message("\(path): no segment maps the Mach-O header") }
        let entry = image.entryOffset.map { header + $0 }
        return LoadedImage(image: GuestImage(name: path, start: low, end: high, base: header),
                           machHeader: header, slide: 0, entry: entry, uuid: image.uuid)
    }

    /// dyld_sim, as the host dyld maps it (dyld-sim-handoff.md §1.3): one
    /// zero-filled read/write reservation of `mappedSize` at `base`, then each
    /// file-backed segment over it with its initprot. Entry = LC_MAIN or the
    /// LC_UNIXTHREAD PC, plus the slide.
    func loadDyldSim(path: String, guestPath: String, base: UInt64) throws -> LoadedImage {
        let file = try GuestFile.openReadOnly(hostPath: path, guestPath: guestPath)
        let fat = try MachOFile(contentsOf: URL(fileURLWithPath: path))
        guard let slice = fat.slices.first(where: { $0.cpuType == MachO.cpuTypeARM64 && $0.cpuSubtype & 0x00FF_FFFF == 0 })
                ?? fat.slices.first(where: { $0.cpuType == MachO.cpuTypeARM64 }) else {
            throw LoaderError.message("\(path) has no arm64 slice")
        }
        let image = try MachOImage(fat.reader, at: slice.offset)
        let segments = image.segments.filter { $0.vmSize > 0 && !($0.fileSize == 0 && $0.initialProtection.rawValue == 0) }
        guard let text = image.segment(named: "__TEXT"), !segments.isEmpty else {
            throw LoaderError.message("\(path) has no __TEXT segment")
        }
        let preferred = text.vmAddress
        let low = segments.map(\.vmAddress).min()!
        let high = segments.map { $0.vmAddress + $0.vmSize }.max()!
        let mappedSize = roundUpPage(high - low)
        let slide = base &- preferred
        _ = try space.mapAnonymous(at: base + (low - preferred), size: mappedSize, protection: .readWrite, hint: nil)
        log("reserve dyld_sim \(hex(base))-\(hex(base + mappedSize)) rw- (slide \(hex(slide)))")
        for segment in segments where segment.fileSize > 0 {
            let va = segment.vmAddress &+ slide
            let fileSpan = roundUpPage(segment.fileSize)
            _ = try space.mapFile(file, offset: UInt64(slice.offset) + segment.fileOffset, at: va, size: fileSpan,
                                  protection: vmProtection(segment.initialProtection), hint: nil)
            if segment.vmSize > segment.fileSize, fileSpan > segment.fileSize {
                try poke(va + segment.fileSize, [UInt8](repeating: 0, count: Int(fileSpan - segment.fileSize)))
            }
            log("map dyld_sim \(segment.name) \(hex(va))-\(hex(va + fileSpan)) \(vmProtection(segment.initialProtection)) file \(hex(segment.fileOffset))+\(hex(segment.fileSize))")
        }
        let entryOffset: UInt64
        if let main = image.entryOffset {
            entryOffset = main
        } else if let pc = unixThreadPC(fat.reader, headerOffset: slice.offset) {
            entryOffset = pc &- preferred
        } else {
            throw LoaderError.message("dyld_sim entry not found (no LC_MAIN or LC_UNIXTHREAD)")
        }
        let header = base
        return LoadedImage(image: GuestImage(name: guestPath, start: base + (low - preferred), end: base + (low - preferred) + mappedSize, base: header),
                           machHeader: header, slide: slide, entry: header + entryOffset, uuid: image.uuid)
    }
}

// MARK: - Stage 3a: run

/// The `ret` stub's offset in the host page (host_stubs.S; dyld_all_image_infos.notification).
let hostPageRetStubOffset: UInt64 = 0x0F00
let a64Ret: UInt32 = 0xD65F_03C0

func uuidBytes(_ uuid: UUID?) -> [UInt8]? {
    guard let u = uuid?.uuid else { return nil }
    return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
}

/// Trace aid: prints kevent_qos_s records (72 bytes each) from guest memory.
func dumpKevents(_ space: GuestAddressSpace, list: UInt64, count: Int, label: String) {
    for i in 0..<min(count, 8) {
        guard let b = try? space.read(va: list + UInt64(i * 72), count: 72, checkingEL0Access: false) else { break }
        func u(_ o: Int, _ n: Int) -> UInt64 { (0..<n).reduce(0) { $0 | UInt64(b[o + $1]) << (8 * UInt64($1)) } }
        let filter = Int16(truncatingIfNeeded: u(8, 2))
        stderrLine("  \(label)[\(i)] ident \(hex(u(0, 8))) filter \(filter) flags \(hex(u(10, 2))) qos \(hex(u(12, 4))) "
            + "udata \(hex(u(16, 8))) fflags \(hex(u(24, 4))) xflags \(hex(u(28, 4))) data \(Int64(bitPattern: u(32, 8))) "
            + "ext \(hex(u(40, 8))) \(hex(u(48, 8))) \(hex(u(56, 8))) \(hex(u(64, 8)))")
    }
}

/// A string with one value per host thread (pthread TSD).
final class PerThreadString: @unchecked Sendable {
    private final class Box { var value = "" }
    private var key = pthread_key_t()

    init() {
        pthread_key_create(&key) { pointer in
            if let pointer { Unmanaged<AnyObject>.fromOpaque(pointer).release() }
        }
    }

    private var box: Box {
        if let pointer = pthread_getspecific(key) {
            return Unmanaged<Box>.fromOpaque(pointer).takeUnretainedValue()
        }
        let box = Box()
        pthread_setspecific(key, Unmanaged.passRetained(box).toOpaque())
        return box
    }

    var value: String {
        get { box.value }
        set { box.value = newValue }
    }
}

#endif
