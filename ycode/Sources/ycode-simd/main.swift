// ycode-simd: the Ycode micro-VM monitor.
//
//   ycode-simd --exec <macho> --runtime-root <dir> [--run-dir <dir>] [--trace]
//              [--timeout-ms N] [--max-exits N] [--shim <shim.bin>]
//              [--host-stubs <host_stubs.bin>] [--host-libs <dir>]
//   ycode-simd --shim <shim.bin> --el0 <el0.bin> [--trace] [--timeout-ms N] [--max-exits N]
//   ycode-simd --kvm-smoke
//
// Stage 2 (`--el0`): boots the EL1 shim in a KVM vCPU with the page tables,
// boot info, and EL0 image laid out as in specs/simulator/vm-shim-protocol.md,
// then serves the shim's doorbell exits with DarwinTrapDispatcher.
//
// Stage 3a (`--exec`): builds a Darwin process image as in
// specs/simulator/stage3-contract.md (main executable and dyld_sim mapped
// with YcodeMachO, the Ycode host page, the kernel argument block, the
// commpage), boots it at the host page's `_ycode_launch`, and serves traps
// with the YcodeDarwinKernel dispatcher.
//
// Stage 3a-ii (specs/simulator/host-libraries.md): Ycode's three host
// libraries (`--host-libs`, default `SimHostLibs/out` next to the package)
// appear in the guest as `/usr/lib/system/libsystem_{kernel,platform,pthread}.dylib`,
// and the VMM builds the main thread's pthread/TSD block before boot
// (TPIDRRO_EL0 = block + 224).
//
// `--keep-going` (with --trace) logs unimplemented traps and library
// functions but resumes the guest instead of exiting 72/73.
//
// Exit status: the guest's exit status; 70 for a fatal guest trap; 71 for an
// unexpected VM exit or the watchdog; 72 for the first unimplemented trap in
// --trace mode; 73 for the first unimplemented host-library function in
// --trace mode; 134 for abort_with_payload; 64 for bad usage; 66 for
// unreadable input; 1 for host (KVM) failures.

import YcodeDarwinABI
import YcodeHypervisor

#if os(Linux) && arch(arm64)
import Foundation
import Glibc
import YcodeDarwinKernel
import YcodeMachO

let usage = """
    usage: ycode-simd --exec <macho> --runtime-root <dir> [--run-dir <dir>] [--trace]
                      [--timeout-ms N] [--max-exits N] [--shim <shim.bin>] [--host-stubs <host_stubs.bin>]
                      [--host-libs <dir>] [--keep-going] [--libfunc-return <name>=<value>[,...]]
           ycode-simd --shim <shim.bin> --el0 <el0.bin> [--trace] [--timeout-ms N] [--max-exits N]
           ycode-simd --kvm-smoke
    """

struct Options {
    var shimPath: String?
    var el0Path: String?
    var execPath: String?
    var runtimeRoot: String?
    var runDir: String?
    var hostStubsPath: String?
    var hostLibsPath: String?
    var trace = false
    /// With --trace: log unimplemented traps and library functions, but resume.
    var keepGoing = false
    /// Debug aid: unimplemented host-library functions whose call the VMM
    /// completes itself (x0 = value, return to LR), to look past them.
    var libfuncReturns: [String: UInt64] = [:]
    var kvmSmoke = false
    var timeoutMilliseconds: UInt64?
    var maxExits: Int?
}

/// Writes all of `text` to a file descriptor, unbuffered (guest output and the
/// trap log interleave in order).
func writeFD(_ fd: Int32, _ text: String) { writeFD(fd, Array(text.utf8)) }

func writeFD(_ fd: Int32, _ bytes: [UInt8]) {
    var offset = 0
    while offset < bytes.count {
        let n = bytes.withUnsafeBytes { Glibc.write(fd, $0.baseAddress! + offset, $0.count - offset) }
        if n < 0 {
            if errno == EINTR { continue }
            return
        }
        offset += n
    }
}

func stderrLine(_ text: String) { writeFD(2, text + "\n") }

func die(_ message: String, status: Int32) -> Never {
    stderrLine("ycode-simd: \(message)")
    exit(status)
}

func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }

func parseOptions(_ arguments: [String]) -> Options {
    var options = Options()
    var iterator = arguments.dropFirst().makeIterator()
    func value(for flag: String) -> String {
        guard let value = iterator.next() else { die("\(flag) needs a value\n\(usage)", status: 64) }
        return value
    }
    while let argument = iterator.next() {
        switch argument {
        case "--shim": options.shimPath = value(for: argument)
        case "--el0": options.el0Path = value(for: argument)
        case "--exec": options.execPath = value(for: argument)
        case "--runtime-root": options.runtimeRoot = value(for: argument)
        case "--run-dir": options.runDir = value(for: argument)
        case "--host-stubs": options.hostStubsPath = value(for: argument)
        case "--host-libs": options.hostLibsPath = value(for: argument)
        case "--trace": options.trace = true
        case "--keep-going": options.keepGoing = true
        case "--libfunc-return":
            for item in value(for: argument).split(separator: ",") {
                let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { die("--libfunc-return needs name=value", status: 64) }
                let text = parts[1].hasPrefix("0x") ? String(parts[1].dropFirst(2)) : parts[1]
                guard let v = parts[1].hasPrefix("-") ? Int64(parts[1]).map({ UInt64(bitPattern: $0) })
                        : UInt64(text, radix: parts[1].hasPrefix("0x") ? 16 : 10) else {
                    die("--libfunc-return: bad value '\(parts[1])'", status: 64)
                }
                options.libfuncReturns[parts[0]] = v
            }
        case "--kvm-smoke": options.kvmSmoke = true
        case "--timeout-ms":
            guard let n = UInt64(value(for: argument)), n > 0 else { die("--timeout-ms needs a positive integer", status: 64) }
            options.timeoutMilliseconds = n
        case "--max-exits":
            guard let n = Int(value(for: argument)), n > 0 else { die("--max-exits needs a positive integer", status: 64) }
            options.maxExits = n
        case "-h", "--help":
            print(usage)
            exit(0)
        default:
            die("unknown argument '\(argument)'\n\(usage)", status: 64)
        }
    }
    return options
}

func readFile(_ path: String) -> [UInt8] {
    guard let file = fopen(path, "rb") else { die("cannot open \(path): \(String(cString: strerror(errno)))", status: 66) }
    defer { fclose(file) }
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = fread(&buffer, 1, buffer.count, file)
        if n > 0 { bytes.append(contentsOf: buffer[0..<n]) }
        if n < buffer.count {
            if ferror(file) != 0 { die("cannot read \(path)", status: 66) }
            break
        }
    }
    return bytes
}

/// Prints the vCPU state after an unexpected exit.
func dumpVCPU(_ vcpu: VCPU) {
    var parts: [String] = []
    func add(_ name: String, _ read: () throws -> UInt64) {
        if let value = try? read() { parts.append("\(name)=\(hex(value))") } else { parts.append("\(name)=?") }
    }
    add("pc") { try vcpu.get(.pc) }
    add("pstate") { try vcpu.get(.pstate) }
    add("sp_el1") { try vcpu.get(.spEL1) }
    add("elr_el1") { try vcpu.get(.elrEL1) }
    add("spsr_el1") { try vcpu.get(.spsrEL1) }
    add("esr_el1") { try vcpu.get(.esrEL1) }
    add("far_el1") { try vcpu.get(.farEL1) }
    add("vbar_el1") { try vcpu.get(.vbarEL1) }
    add("sctlr_el1") { try vcpu.get(.sctlrEL1) }
    stderrLine("ycode-simd: vCPU state: " + parts.joined(separator: " "))
    if let esr = try? vcpu.get(.esrEL1) {
        stderrLine("ycode-simd: ESR_EL1 EC=\(hex((esr >> 26) & 0x3F)) IL=\((esr >> 25) & 1) ISS=\(hex(esr & 0x1FF_FFFF))")
    }
}

// MARK: - Stage 2

/// The value the VMM puts in TPIDRRO_EL0 and passes to the self-test in x0.
let initialTPIDRRO: UInt64 = 0x0000_0001_5943_0000

func runStage2(_ options: Options) throws -> Never {
    guard let shimPath = options.shimPath, let el0Path = options.el0Path else { die("missing --shim or --el0\n\(usage)", status: 64) }
    let timeout = options.timeoutMilliseconds ?? 10_000
    let maxExits = options.maxExits ?? 100_000
    let shim = readFile(shimPath)
    let el0Image = readFile(el0Path)
    guard !shim.isEmpty, UInt64(shim.count) <= VMLayout.shimRegionSize else {
        die("shim image is empty or larger than \(VMLayout.shimRegionSize) bytes", status: 66)
    }
    guard !el0Image.isEmpty else { die("EL0 image is empty", status: 66) }

    let vm = try VirtualMachine(ramGPA: VMLayout.ramGPA, ramSize: Int(VMLayout.ramSize))

    // Stage-1 tables (§3): EL1 identity regions, then EL0 regions backed by
    // consecutive pages of the EL0 pool.
    var tables = PageTableBuilder(tableArenaGPA: VMLayout.pageTableArenaGPA, tableArenaSize: Int(VMLayout.pageTableArenaSize))
    for region in VMLayout.el1Regions { try tables.mapIdentity(region) }
    var nextPoolGPA = VMLayout.el0PoolGPA
    for region in VMLayout.selfTestRegions(imageSize: UInt64(el0Image.count)) {
        guard nextPoolGPA + region.size <= VMLayout.el0PoolGPA + VMLayout.el0PoolSize else {
            die("EL0 pool exhausted mapping \(region.name)", status: 66)
        }
        try tables.map(va: region.va, pa: nextPoolGPA, size: region.size, attributes: region.attributes)
        if options.trace {
            stderrLine("ycode-simd: map \(region.name) va \(hex(region.va))-\(hex(region.end)) -> pa \(hex(nextPoolGPA)) \(region.attributes)")
        }
        nextPoolGPA += region.size
    }
    for table in tables.tables { try vm.write(gpa: table.gpa, bytes: table.bytes) }

    // Images.
    try vm.write(gpa: VMLayout.shimGPA, bytes: shim)
    let loader = TranslatedGuestMemory(vm: vm, pageTables: tables, enforceEL0Permissions: false)
    try loader.write(va: VMLayout.selfTestImageVA, bytes: el0Image)

    // Boot info (§4).
    let bootInfo = BootInfo(
        ttbr0EL1: tables.rootGPA,
        el0EntryPC: VMLayout.selfTestImageVA,
        el0InitialSP: VMLayout.el0StackTop,
        trapFrameAddress: VMLayout.trapFrameGPA,
        doorbellAddress: VMLayout.doorbellGPA,
        tpidrroEL0: initialTPIDRRO,
        tpidrEL0: 0,
        el0Registers: [initialTPIDRRO, UInt64(VMLayout.guestPID), 0, 0, 0, 0, 0, 0],
        el1StackTop: VMLayout.el1StackTop)
    try vm.write(gpa: VMLayout.bootInfoGPA, bytes: bootInfo.encoded())
    if options.trace {
        stderrLine("ycode-simd: \(tables.tables.count) table pages, root \(hex(tables.rootGPA)); shim \(shim.count) bytes; EL0 image \(el0Image.count) bytes")
    }

    // vCPU reset state.
    let vcpu = try vm.makeVCPU()
    try vcpu.set(.pc, VMLayout.shimEntryGPA)
    try vcpu.set(.pstate, VMLayout.el1BootPSTATE)
    try vcpu.set(.x(0), VMLayout.bootInfoGPA)

    let memory = TranslatedGuestMemory(vm: vm, pageTables: tables)
    var dispatcher = DarwinTrapDispatcher(
        pid: VMLayout.guestPID,
        stdout: { text in writeFD(1, text) },
        stderr: { text in writeFD(2, text) },
        log: { line in stderrLine("[trap] " + line) })

    try Watchdog.arm(milliseconds: timeout)
    while true {
        guard vcpu.exitCount < maxExits else {
            dumpVCPU(vcpu)
            die("guest exceeded \(maxExits) VM exits", status: 71)
        }
        let exit = try vcpu.run()
        if options.trace { stderrLine("ycode-simd: exit #\(vcpu.exitCount): \(exit)") }

        switch exit {
        case let .mmio(.write, address, frameAddress, 8) where address == VMLayout.doorbellGPA:
            guard frameAddress == VMLayout.trapFrameGPA else {
                dumpVCPU(vcpu)
                die("doorbell carried frame address \(hex(frameAddress)), expected \(hex(VMLayout.trapFrameGPA))", status: 71)
            }
            var frame = try TrapFrame(decoding: vm.read(gpa: frameAddress, count: TrapFrame.byteCount))
            let outcome = dispatcher.handle(&frame, memory: memory)
            switch outcome {
            case .resume:
                try vm.write(gpa: frameAddress, bytes: frame.encoded())
            case let .exit(status):
                if options.trace { stderrLine("ycode-simd: guest exited with status \(status) after \(vcpu.exitCount) VM exits") }
                Glibc.exit(status)
            case let .fatal(message):
                // The dispatcher's message carries the decoded ESR and the frame dump.
                die("fatal guest trap:\n\(message)", status: VMLayout.fatalExitStatus)
            }
        case .watchdog:
            dumpVCPU(vcpu)
            die("watchdog: guest still running after \(timeout) ms", status: 71)
        default:
            dumpVCPU(vcpu)
            die("unexpected VM exit: \(exit)", status: 71)
        }
    }
}

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

/// Attributes guest addresses to images: the main executable, dyld_sim, the
/// host page, and shared-cache images (their __TEXT ranges, from the cache's
/// image list; the cache is never slid, but the VMM records the address
/// delta it observes in dyld_sim's mmap calls).
final class ImageMap {
    var fixed: [GuestImage] = []
    /// Ycode's host libraries are mapped by dyld_sim through `mmap` of their
    /// VFS files; they are found through the address space's file-backed
    /// regions with these guest paths.
    var space: GuestAddressSpace?
    var hostLibraryPaths: Set<String> = []
    static let hostLibrarySuffix = " [ycode]"
    let cachePath: String
    private var cache: SharedCache?
    private var cacheLoadFailed = false
    private var cacheImages: [GuestImage] = []
    /// Observed (mapped address − header address); 0 when dyld_sim maps the cache at the header addresses.
    var cacheDelta: UInt64 = 0

    init(cachePath: String) { self.cachePath = cachePath }

    func sharedCache() -> SharedCache? {
        if cache == nil && !cacheLoadFailed {
            do { cache = try SharedCache(contentsOf: URL(fileURLWithPath: cachePath)) } catch {
                cacheLoadFailed = true
                stderrLine("ycode-simd: cannot read the shared cache \(cachePath): \(error)")
            }
        }
        return cache
    }

    /// Every mapping of every cache file (main file first), as in the headers.
    func cacheMappings() -> [(file: String, mapping: SharedCache.Mapping)] {
        guard let cache = sharedCache() else { return [] }
        return cache.files.flatMap { f in f.mappings.map { (f.url.path, $0) } }
    }

    private func loadCacheImages() {
        guard cacheImages.isEmpty, let cache = sharedCache() else { return }
        var images: [GuestImage] = []
        for image in cache.images {
            guard let macho = try? cache.machO(for: image), let text = macho.segment(named: "__TEXT") else { continue }
            images.append(GuestImage(name: image.path, start: text.vmAddress, end: text.vmAddress + text.vmSize, base: image.address))
        }
        cacheImages = images.sorted { $0.start < $1.start }
    }

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
        loadCacheImages()
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
        if let cache = sharedCache(), let first = cache.mainFile.mappings.first {
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
    let trace: Bool

    init(trace: Bool) throws {
        self.trace = trace
        vm = try VirtualMachine(ramGPA: VMLayout.ramGPA, ramSize: Int(VMLayout.stage3RAMSize))
        backing = try KVMPhysicalBacking(vm: vm, poolGPA: VMLayout.anonymousPoolGPA, poolSize: VMLayout.anonymousPoolSize,
                                         fileWindowGPA: VMLayout.fileSlotGPABase,
                                         physicalAddressBits: VMLayout.physicalAddressBits)
        var tables = PageTableBuilder.stage3()
        for region in VMLayout.stage3EL1Regions { try tables.mapIdentity(region) }
        space = GuestAddressSpace(backing: backing, pageTables: tables)
        try space.flushPageTables()
    }

    func log(_ text: String) { if trace { stderrLine("ycode-simd: " + text) } }

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
    func loadMainExecutable(path: String) throws -> LoadedImage {
        let file = try GuestFile.openReadOnly(hostPath: path, guestPath: path)
        let fat = try MachOFile(contentsOf: URL(fileURLWithPath: path))
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

func runExec(_ options: Options) throws -> Never {
    guard let execArgument = options.execPath, let rootArgument = options.runtimeRoot else {
        die("--exec needs --runtime-root\n\(usage)", status: 64)
    }
    let trace = options.trace
    let timeout = options.timeoutMilliseconds ?? 120_000
    let maxExits = options.maxExits ?? 50_000_000
    let execPath = absolutePath(execArgument)
    var root = absolutePath(rootArgument)
    while root.count > 1 && root.hasSuffix("/") { root.removeLast() }
    let dyldSimPath = root + "/usr/lib/dyld_sim"
    let cachePath = root + "/System/Library/Caches/com.apple.dyld/dyld_sim_shared_cache_arm64"
    for path in [execPath, dyldSimPath] where access(path, R_OK) != 0 {
        die("cannot read \(path): \(String(cString: strerror(errno)))", status: 66)
    }
    let shim = readFile(locateSimShimFile("shim.bin", explicit: options.shimPath))
    let stubs = readFile(locateSimShimFile("host_stubs.bin", explicit: options.hostStubsPath))
    guard !shim.isEmpty, UInt64(shim.count) <= VMLayout.shimRegionSize else { die("bad shim image", status: 66) }
    guard UInt64(stubs.count) == VMLayout.hostPageSize else {
        die("host_stubs.bin is \(stubs.count) bytes, expected \(VMLayout.hostPageSize)", status: 66)
    }
    let retWord = stubs.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: Int(hostPageRetStubOffset), as: UInt32.self)) }
    guard retWord == a64Ret else { die("host_stubs.bin has no `ret` at +\(hex(hostPageRetStubOffset))", status: 66) }

    // The per-run directory: guest /tmp lives in <run dir>/tmp.
    let runDir = absolutePath(options.runDir ?? (NSTemporaryDirectory() + "/ycode-simd-\(getpid())"))
    try FileManager.default.createDirectory(atPath: runDir + "/tmp", withIntermediateDirectories: true)

    // VM, address space, process image.
    let builder = try ProcessBuilder(trace: trace)
    let vm = builder.vm, space = builder.space
    stderrLine("ycode-simd: KVM memslots available: \(vm.maxMemorySlots); RAM \(VMLayout.stage3RAMSize >> 20) MiB; anonymous pool \(VMLayout.anonymousPoolSize >> 30) GiB at \(hex(VMLayout.anonymousPoolGPA))")
    try vm.write(gpa: VMLayout.shimGPA, bytes: shim)

    let main = try builder.loadMainExecutable(path: execPath)
    let sim = try builder.loadDyldSim(path: dyldSimPath, guestPath: dyldSimPath, base: VMLayout.dyldSimBaseVA)
    guard let prepareEntry = sim.entry else { die("dyld_sim entry not found", status: 66) }
    stderrLine("ycode-simd: main \(execPath) at \(hex(main.machHeader)); dyld_sim at \(hex(sim.machHeader)) slide \(hex(sim.slide)) entry \(hex(prepareEntry))")

    // Main stack and the kernel argument block (darwin-process-start.md §1.3).
    _ = try space.mapAnonymous(at: VMLayout.userStackBase, size: VMLayout.userStackSize, protection: .readWrite, hint: nil)
    let apple = AppleStrings(executablePath: execPath)
    let arguments = KernelArgumentBlock(userStack: VMLayout.userStackTop, argv: [execPath],
                                        envp: SimulatorEnvironment.make(runtimeRoot: root),
                                        apple: apple.strings, machHeader: main.machHeader)
    try builder.poke(arguments.stackPointer, arguments.bytes)

    // The Ycode host page (§5): code RX, helpers RO, data RW.
    let hostBase = VMLayout.hostPageVA
    try space.mapPermanentAnonymous(at: hostBase + VMLayout.hostPageCodeOffset, size: VMLayout.hostPageCodeSize, protection: .readExecute)
    try space.mapPermanentAnonymous(at: hostBase + VMLayout.hostPageRODataOffset, size: VMLayout.hostPageRODataSize, protection: .read)
    try space.mapPermanentAnonymous(at: hostBase + VMLayout.hostPageRWDataOffset, size: VMLayout.hostPageRWDataSize, protection: .readWrite)
    try builder.poke(hostBase, stubs)
    let storage = DyldImageInfoStorage(base: HostPageLayout.imageInfoStorage,
                                       images: [.init(loadAddress: main.machHeader, path: execPath)])
    guard UInt64(storage.bytes.count) <= HostPageLayout.imageInfoStorageSize else { die("image info storage overflows", status: 66) }
    try builder.poke(storage.infoArrayAddress, storage.bytes)
    let infos = DyldAllImageInfos.initial(infoArray: storage.infoArrayAddress, notification: hostBase + hostPageRetStubOffset,
                                          simMH: sim.machHeader)
    try builder.poke(HostPageLayout.allImageInfos, infos.encoded())
    let launch = LaunchBlock(prepareEntry: prepareEntry, arguments: arguments, mainMH: main.machHeader,
                             simMH: sim.machHeader, simSlide: sim.slide)
    try builder.poke(HostPageLayout.launchBlock, launch.encoded())

    // Commpage (§6): RO page and RW-data page, both EL0 read-only.
    let commpage = CommpageBuilder()
    try space.mapPermanentAnonymous(at: VMLayout.readOnlyCommpageVA, size: pageSize, protection: .read)
    try space.mapPermanentAnonymous(at: VMLayout.commpageVA, size: pageSize, protection: .read)
    try builder.poke(VMLayout.readOnlyCommpageVA, commpage.roPage())
    try builder.poke(VMLayout.commpageVA, commpage.rwPage())

    if trace {
        for region in space.regions { stderrLine("ycode-simd: region \(region)") }
        stderrLine("ycode-simd: argument block at \(hex(arguments.stackPointer)) (argc \(arguments.argc)); \(vm.memorySlotCount) memslots")
    }

    // The main thread's pthread/TSD block (host-libraries.md §8.3): the VMM
    // plays the host dyld, so TSD, errno, and TLV reads work from the first
    // instruction.
    let threadBlock = MainThreadBlock(address: Stage3Layout.mainThreadPage, threadID: 1, threadPort: WellKnownPort.thread,
                                      stackTop: VMLayout.userStackTop, stackSize: VMLayout.userStackSize)
    _ = try space.mapAnonymous(at: Stage3Layout.mainThreadPage, size: Stage3Layout.mainThreadPageSize,
                               protection: .readWrite, hint: nil)
    try builder.poke(threadBlock.address, threadBlock.bytes)
    stderrLine("ycode-simd: main-thread block at \(hex(threadBlock.address)); TPIDRRO_EL0 = \(hex(threadBlock.tsdBase))")

    // Boot info and vCPU (§6 initial state, with host-libraries.md §8.3's TPIDRRO_EL0).
    let bootInfo = BootInfo(ttbr0EL1: space.pageTables.rootGPA, el0EntryPC: VMLayout.hostPageEntryVA,
                            el0InitialSP: arguments.stackPointer, tpidrroEL0: threadBlock.tsdBase, tpidrEL0: 0,
                            el0Registers: [UInt64](repeating: 0, count: 8))
    try vm.write(gpa: VMLayout.bootInfoGPA, bytes: bootInfo.encoded())
    let vcpu = try vm.makeVCPU()
    try vcpu.set(.pc, VMLayout.shimEntryGPA)
    try vcpu.set(.pstate, VMLayout.el1BootPSTATE)
    try vcpu.set(.x(0), VMLayout.bootInfoGPA)
    let (frequency, frequencySource) = vcpu.counterFrequency()
    stderrLine("ycode-simd: CNTFRQ_EL0 = \(frequency) Hz (\(frequencySource))")

    // Kernel personality and VFS (§8).
    let execDirectory = (execPath as NSString).deletingLastPathComponent
    var prefixes = [DarwinFileSystem.Prefix(guestPath: root, hostPath: root, writable: false)]
    if !execDirectory.hasPrefix(root + "/") {
        prefixes.append(DarwinFileSystem.Prefix(guestPath: execDirectory, hostPath: execDirectory, writable: false))
    }
    // Ycode's host libraries (host-libraries.md §5): three read-only
    // single-file prefixes; every other /usr/lib/system path stays ENOENT.
    var hostLibraryPaths: Set<String> = []
    let (hostLibDir, hostLibTried) = locateHostLibraryDirectory(explicit: options.hostLibsPath)
    if let hostLibDir {
        for name in hostLibraryNames {
            let file = "\(hostLibDir)/libsystem_\(name).dylib"
            let guest = hostLibraryGuestPath(name)
            if access(file, R_OK) == 0 {
                prefixes.append(DarwinFileSystem.Prefix(guestPath: guest, hostPath: file, writable: false))
                hostLibraryPaths.insert(guest)
                stderrLine("ycode-simd: host library \(guest) -> \(file)")
            } else {
                stderrLine("ycode-simd: warning: host library \(file) is missing; \(guest) will be ENOENT")
            }
        }
    } else {
        stderrLine("ycode-simd: warning: no host-library directory (tried \(hostLibTried.joined(separator: ", "))); pass --host-libs")
    }
    prefixes.append(DarwinFileSystem.Prefix(guestPath: "/tmp", hostPath: runDir + "/tmp", writable: true))
    let fileSystem = DarwinFileSystem(prefixes: prefixes, console: { fd, bytes in writeFD(fd == 2 ? 2 : 1, bytes) })

    var trapPrefix = ""
    let kernel = DarwinKernel(
        fileSystem: fileSystem,
        log: { line in if trace { stderrLine(trapPrefix + line) } },
        counter: { (try? vcpu.virtualCounter()) ?? 0 },
        counterFrequency: frequency)
    kernel.allImageInfosAddress = HostPageLayout.allImageInfos
    kernel.mainStackTop = VMLayout.userStackTop

    // Image attribution and the milestone.
    let images = ImageMap(cachePath: cachePath)
    images.fixed = [
        main.image,
        sim.image,
        GuestImage(name: "ycode host page", start: hostBase, end: hostBase + VMLayout.hostPageSize, base: hostBase),
        GuestImage(name: "ycode main-thread block", start: Stage3Layout.mainThreadPage,
                   end: Stage3Layout.mainThreadPage + Stage3Layout.mainThreadPageSize, base: threadBlock.address),
    ]
    images.space = space
    images.hostLibraryPaths = hostLibraryPaths
    var milestoneReached = false
    var tracker = CacheMappingTracker()
    var trapCount = 0
    var trapCounts: [String: Int] = [:]

    func summary() -> String {
        let expected = tracker.expected.count
        let exact = tracker.seen.filter { tracker.expected[$0.key].mapping.address == $0.value }.count
        return "\(trapCount) traps, \(vcpu.exitCount) VM exits; shared-cache mappings mapped: \(tracker.seen.count)/\(expected)"
            + " (\(exact) at the header address); milestone \(milestoneReached ? "reached" : "not reached")"
    }

    func faultReport(_ frame: TrapFrame) -> String {
        var lines = ["  ELR \(hex(frame.elr)) = \(images.describe(frame.elr))"]
        if frame.trapKind != .svc {
            lines.append("  FAR \(hex(frame.far)) = \(images.describe(frame.far)); region: \(space.region(containing: frame.far)?.description ?? "unmapped")")
        }
        lines.append("  LR  \(hex(frame.x[30])) = \(images.describe(frame.x[30]))")
        if let code = try? space.read(va: frame.elr & ~3, count: 4, checkingEL0Access: false) {
            lines.append("  instruction word at ELR: \(code.reversed().map { String(format: "%02x", $0) }.joined())")
        }
        return lines.joined(separator: "\n")
    }

    try Watchdog.arm(milliseconds: timeout)
    while true {
        guard vcpu.exitCount < maxExits else {
            dumpVCPU(vcpu)
            die("guest exceeded \(maxExits) VM exits (\(summary()))", status: 71)
        }
        let exit: VCPUExit = Watchdog.fired ? .watchdog : try vcpu.run()
        switch exit {
        case let .mmio(.write, address, frameAddress, 8) where address == VMLayout.doorbellGPA:
            guard frameAddress == VMLayout.trapFrameGPA else {
                dumpVCPU(vcpu)
                die("doorbell carried frame address \(hex(frameAddress)), expected \(hex(VMLayout.trapFrameGPA))", status: 71)
            }
            var frame = try TrapFrame(decoding: vm.read(gpa: frameAddress, count: TrapFrame.byteCount))
            trapCount += 1

            // Attribute the trap; the milestone (host-libraries.md §8.1)
            // prints once: the first trap from a cache libsystem_* image,
            // the cache libSystem.B, or one of Ycode's host libraries.
            let attribution = images.attribute(frame.elr)
            if !milestoneReached, let (image, offset) = attribution,
               image.name.hasPrefix("/usr/lib/system/libsystem_") || image.name == "/usr/lib/libSystem.B.dylib" {
                milestoneReached = true
                stderrLine("milestone: libSystem initializer reached (\(image.name) + \(hex(offset)); "
                    + "LR \(hex(frame.x[30])) = \(images.describe(frame.x[30])))")
            }
            if trace {
                let place = attribution.map { "\($0.image.name.split(separator: "/").last.map(String.init) ?? $0.image.name)+\(hex($0.offset))" } ?? hex(frame.elr)
                trapPrefix = "[\(trapCount)] \(place): "
            }

            // dyld_sim's mmap of the shared cache (§1 item 1).
            let isSVC = frame.trapKind == .svc
            let x16 = UInt32(truncatingIfNeeded: frame.x[16])
            tracker.pending = nil
            if isSVC, x16 == 197 {
                let fd = Int32(truncatingIfNeeded: frame.x[4])
                tracker.pending = .init(address: frame.x[0], size: frame.x[1], flags: frame.x[3], fd: fd,
                                        offset: frame.x[5], path: try? fileSystem.path(for: fd))
            }

            let outcome = kernel.handle(&frame, memory: space)

            if let p = tracker.pending, let path = p.path, !frame.carry, frame.x[0] == p.address,
               p.flags & 0x10 != 0, (path as NSString).lastPathComponent.hasPrefix("dyld_sim_shared_cache_") {
                if tracker.expected.isEmpty { tracker.expected = images.cacheMappings() }
                let name = (path as NSString).lastPathComponent
                if let index = tracker.expected.firstIndex(where: {
                    ($0.file as NSString).lastPathComponent == name && $0.mapping.fileOffset == p.offset && $0.mapping.size == p.size
                }) {
                    let header = tracker.expected[index].mapping.address
                    tracker.seen[index] = p.address
                    if index == 0 { images.cacheDelta = p.address &- header }
                    stderrLine("ycode-simd: shared-cache mapping \(index + 1)/\(tracker.expected.count) \(name) @\(hex(p.offset)) size \(hex(p.size)) mapped at \(hex(p.address)) (header address \(hex(header))\(p.address == header ? ", exact" : ""))")
                }
            }

            switch outcome {
            case .resume:
                try vm.write(gpa: frameAddress, bytes: frame.encoded())
            case let .exit(status):
                stderrLine("ycode-simd: guest exited with status \(status); \(summary())")
                Glibc.exit(status)
            case let .fatal(status, message):
                if DarwinKernel.isCachePatchPlaceholderFault(frame) {
                    stderrLine("ycode-simd: \(DarwinKernel.cachePatchPlaceholderMessage): ELR \(hex(frame.elr)) = "
                        + "\(images.describe(frame.elr)); LR \(hex(frame.x[30])) = \(images.describe(frame.x[30]))")
                }
                stderrLine("ycode-simd: fatal guest condition (exit \(status)):\n\(message)\n\(faultReport(frame))")
                stderrLine("ycode-simd: \(summary())")
                Glibc.exit(status)
            case let .unimplemented(description):
                trapCounts[description, default: 0] += 1
                if trace && !options.keepGoing {
                    stderrLine("ycode-simd: first unimplemented trap: \(description)\n\(frame)\n\(faultReport(frame))")
                    stderrLine("ycode-simd: \(summary())")
                    Glibc.exit(DarwinKernel.unimplementedExitStatus)
                }
                try vm.write(gpa: frameAddress, bytes: frame.encoded())
            case let .unimplementedLibraryFunction(name) where options.libfuncReturns[name] != nil:
                // Debug aid: finish the call here (x0 = value, return to the caller).
                let value = options.libfuncReturns[name]!
                stderrLine("ycode-simd: unimplemented libfunc \(name) (LR \(hex(frame.x[30])) = \(images.describe(frame.x[30]))) "
                    + "[--libfunc-return: x0 = \(hex(value))]")
                frame.x[0] = value
                frame.elr = frame.x[30]
                try vm.write(gpa: frameAddress, bytes: frame.encoded())
            case let .unimplementedLibraryFunction(name):
                trapCounts["libfunc " + name, default: 0] += 1
                stderrLine("ycode-simd: unimplemented libfunc \(name) (LR \(hex(frame.x[30])) = \(images.describe(frame.x[30])))")
                if trace && !options.keepGoing {
                    stderrLine("ycode-simd: first unimplemented host-library function: \(name)\n\(frame)\n\(faultReport(frame))")
                    stderrLine("ycode-simd: \(summary())")
                    Glibc.exit(DarwinKernel.unimplementedLibraryFunctionExitStatus)
                }
                try vm.write(gpa: frameAddress, bytes: frame.encoded())
            }
        case .watchdog:
            dumpVCPU(vcpu)
            die("watchdog: guest still running after \(timeout) ms (\(summary()))", status: 71)
        default:
            dumpVCPU(vcpu)
            die("unexpected VM exit: \(exit) (\(summary()))", status: 71)
        }
    }
}

let options = parseOptions(CommandLine.arguments)
do {
    if options.kvmSmoke {
        try KVMSmokeTest.run { print($0) }
        exit(0)
    }
    if options.execPath != nil {
        try runExec(options)
    }
    try runStage2(options)
} catch {
    die("\(error)", status: 1)
}
#else
print("ycode-simd: the micro-VM needs Linux with KVM (arm64)")
#endif
