// ycode-simd: the Ycode micro-VM monitor (stage 2).
//
//   ycode-simd --shim <shim.bin> --el0 <el0.bin> [--trace]
//              [--timeout-ms N] [--max-exits N]
//   ycode-simd --kvm-smoke
//
// Boots the EL1 shim in a KVM vCPU with the page tables, boot info, and EL0
// image laid out as in specs/simulator/vm-shim-protocol.md, then serves the
// shim's doorbell exits with DarwinTrapDispatcher.
//
// Exit status: the guest's exit status; 70 for a fatal guest trap; 71 for an
// unexpected VM exit or the watchdog; 64 for bad usage; 66 for unreadable
// input; 1 for host (KVM) failures.

import YcodeDarwinABI
import YcodeHypervisor

#if os(Linux) && arch(arm64)
import Glibc

let usage = """
    usage: ycode-simd --shim <shim.bin> --el0 <el0.bin> [--trace] [--timeout-ms N] [--max-exits N]
           ycode-simd --kvm-smoke
    """

struct Options {
    var shimPath: String?
    var el0Path: String?
    var trace = false
    var kvmSmoke = false
    var timeoutMilliseconds: UInt64 = 10_000
    var maxExits = 100_000
}

/// Writes all of `text` to a file descriptor, unbuffered (guest output and the
/// trap log interleave in order).
func writeFD(_ fd: Int32, _ text: String) {
    let bytes = Array(text.utf8)
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
        case "--trace": options.trace = true
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

/// The value the VMM puts in TPIDRRO_EL0 and passes to the self-test in x0.
let initialTPIDRRO: UInt64 = 0x0000_0001_5943_0000

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

func runVMM(_ options: Options) throws -> Never {
    guard let shimPath = options.shimPath, let el0Path = options.el0Path else { die("missing --shim or --el0\n\(usage)", status: 64) }
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

    try Watchdog.arm(milliseconds: options.timeoutMilliseconds)
    while true {
        guard vcpu.exitCount < options.maxExits else {
            dumpVCPU(vcpu)
            die("guest exceeded \(options.maxExits) VM exits", status: 71)
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
            die("watchdog: guest still running after \(options.timeoutMilliseconds) ms", status: 71)
        default:
            dumpVCPU(vcpu)
            die("unexpected VM exit: \(exit)", status: 71)
        }
    }
}

let options = parseOptions(CommandLine.arguments)
do {
    if options.kvmSmoke {
        try KVMSmokeTest.run { print($0) }
        exit(0)
    }
    try runVMM(options)
} catch {
    die("\(error)", status: 1)
}
#else
print("ycode-simd: the micro-VM needs Linux with KVM (arm64)")
#endif
