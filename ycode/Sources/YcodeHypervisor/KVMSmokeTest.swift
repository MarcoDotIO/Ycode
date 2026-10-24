// A self-contained check of the KVM plumbing: boots a tiny hand-encoded EL1
// guest (MMU off) that stores to an unbacked GPA, loads from it, stores the
// loaded value back, and powers off through PSCI SYSTEM_OFF. A second test
// (stage 3) checks extra memslots: the anonymous pool and private file
// mappings, read and written by a guest, plus the timer ONE_REG reads. Run
// with `ycode-simd --kvm-smoke`.

#if os(Linux) && arch(arm64)
import Glibc

/// A few A64 encodings, from the Arm ARM instruction formats.
enum A64 {
    static func movz(_ rd: UInt32, _ imm: UInt16, shift: UInt32 = 0) -> UInt32 { 0xD280_0000 | (shift / 16) << 21 | UInt32(imm) << 5 | rd }
    static func movk(_ rd: UInt32, _ imm: UInt16, shift: UInt32) -> UInt32 { 0xF280_0000 | (shift / 16) << 21 | UInt32(imm) << 5 | rd }
    /// movz/movk sequence that loads a 64-bit constant.
    static func mov64(_ rd: UInt32, _ value: UInt64) -> [UInt32] {
        var words = [movz(rd, UInt16(value & 0xFFFF))]
        for shift in stride(from: UInt32(16), to: 64, by: 16) where (value >> UInt64(shift)) & 0xFFFF != 0 {
            words.append(movk(rd, UInt16((value >> UInt64(shift)) & 0xFFFF), shift: shift))
        }
        return words
    }
    /// ldr Xt, [Xn, #offset] (offset a multiple of 8, < 32 KiB).
    static func ldr(_ rt: UInt32, _ rn: UInt32, _ offset: UInt32 = 0) -> UInt32 { 0xF940_0000 | (offset / 8) << 10 | rn << 5 | rt }
    /// str Xt, [Xn, #offset].
    static func str(_ rt: UInt32, _ rn: UInt32, _ offset: UInt32 = 0) -> UInt32 { 0xF900_0000 | (offset / 8) << 10 | rn << 5 | rt }
    static let hvc0: UInt32 = 0xD400_0002
    static let branchSelf: UInt32 = 0x1400_0000

    static func bytes(_ words: [UInt32]) -> [UInt8] {
        var out: [UInt8] = []
        for word in words { withUnsafeBytes(of: word.littleEndian) { out.append(contentsOf: $0) } }
        return out
    }
}

public enum KVMSmokeTest {
    /// Runs the test, printing one line per step through `log`. Throws on failure.
    public static func run(log: (String) -> Void) throws {
        let vm = try VirtualMachine()
        let vcpu = try vm.makeVCPU()
        let mmfr0 = try vcpu.get(.idAA64MMFR0EL1)
        log("vCPU created; ID_AA64MMFR0_EL1 = 0x\(String(mmfr0, radix: 16)) (TGran16 field \((mmfr0 >> 20) & 0xF))")

        // A64 encodings, written by hand from the Arm ARM instruction formats.
        let program: [UInt32] = [
            0xD2A1_2001, // movz x1, #0x0900, lsl #16        -> x1 = 0x0900_0000
            0xD282_4682, // movz x2, #0x1234
            0xF900_0022, // str  x2, [x1]                     -> MMIO write 8 bytes
            0xF940_0423, // ldr  x3, [x1, #8]                 -> MMIO read 8 bytes
            0xF900_0823, // str  x3, [x1, #16]                -> MMIO write of the read value
            0xD280_0100, // movz x0, #0x0008
            0xF2B0_8000, // movk x0, #0x8400, lsl #16         -> PSCI SYSTEM_OFF (0x8400_0008)
            0xD400_0002, // hvc  #0
            0x1400_0000, // b    .
        ]
        var bytes: [UInt8] = []
        for word in program { withUnsafeBytes(of: word.littleEndian) { bytes.append(contentsOf: $0) } }
        try vm.write(gpa: vm.ramGPA, bytes: bytes)

        try vcpu.set(.pc, vm.ramGPA)
        try vcpu.set(.pstate, VCPU.pstateEL1hMasked)
        try vcpu.set(.x(5), 0xFEED_FACE)
        guard try vcpu.get(.x(5)) == 0xFEED_FACE else { throw KVMError("smoke", detail: "ONE_REG round trip of x5") }
        try vcpu.set(.tpidrroEL0, 0x1234_5678_9ABC)
        guard try vcpu.get(.tpidrroEL0) == 0x1234_5678_9ABC else { throw KVMError("smoke", detail: "ONE_REG round trip of TPIDRRO_EL0") }
        log("registers set: PC=0x\(String(vm.ramGPA, radix: 16)) PSTATE=0x3c5")

        try Watchdog.arm(milliseconds: 5_000)
        defer { try? Watchdog.arm(milliseconds: 0) }

        var exit = try vcpu.run()
        log("exit 1: \(exit)")
        guard exit == .mmio(.write, address: 0x0900_0000, data: 0x1234, length: 8) else {
            throw KVMError("smoke", detail: "expected an 8-byte MMIO write of 0x1234, got \(exit)")
        }
        exit = try vcpu.run()
        log("exit 2: \(exit)")
        guard exit == .mmio(.read, address: 0x0900_0008, data: 0, length: 8) else {
            throw KVMError("smoke", detail: "expected an 8-byte MMIO read, got \(exit)")
        }
        vcpu.completeMMIORead(0xC0FF_EE00_1122_3344, length: 8)
        exit = try vcpu.run()
        log("exit 3: \(exit)")
        guard exit == .mmio(.write, address: 0x0900_0010, data: 0xC0FF_EE00_1122_3344, length: 8) else {
            throw KVMError("smoke", detail: "expected the read value written back, got \(exit)")
        }
        // Registers are read before the PSCI call, which clobbers x0-x3.
        let x2 = try vcpu.get(.x(2)), x3 = try vcpu.get(.x(3)), pc = try vcpu.get(.pc)
        log("registers: x2=0x\(String(x2, radix: 16)) x3=0x\(String(x3, radix: 16)) pc=0x\(String(pc, radix: 16))")
        guard x2 == 0x1234, x3 == 0xC0FF_EE00_1122_3344, pc == vm.ramGPA + 16 else {
            throw KVMError("smoke", detail: "register values after the MMIO exits")
        }
        exit = try vcpu.run()
        log("exit 4: \(exit)")
        guard case .systemEvent = exit else { throw KVMError("smoke", detail: "expected PSCI SYSTEM_OFF, got \(exit)") }

        let exits = vcpu.exitCount

        // Watchdog: a guest spinning in `b .` (on a fresh VM, since the first
        // vCPU is powered off) must be interrupted.
        let spinVM = try VirtualMachine(ramSize: 1 << 20)
        let spinner = try spinVM.makeVCPU()
        try spinVM.write(gpa: spinVM.ramGPA, bytes: [0x00, 0x00, 0x00, 0x14]) // b .
        try spinner.set(.pc, spinVM.ramGPA)
        try spinner.set(.pstate, VCPU.pstateEL1hMasked)
        try Watchdog.arm(milliseconds: 200)
        exit = try spinner.run()
        log("spin test: \(exit)")
        guard exit == .watchdog else { throw KVMError("smoke", detail: "watchdog did not interrupt a spinning guest") }
        log("KVM smoke test passed (\(exits) exits)")
        try runMemslots(log: log)
        try runVCPUBatch(log: log)
    }

    /// Batched vCPU creation (`VirtualMachine.creationBatch`): the first
    /// `makeVCPU` creates the next ids too; asking for one of them hands it
    /// out without an ioctl; batches stay below `vcpuIDLimit`; `close`
    /// closes unused ones.
    public static func runVCPUBatch(log: (String) -> Void) throws {
        let batch = VirtualMachine.creationBatch
        let vm = try VirtualMachine(ramSize: 1 << 20)
        vm.vcpuIDLimit = 1 + batch + 1
        _ = try vm.makeVCPU(id: 0)
        for id in 1...max(1, batch) where batch > 0 {
            let began = monotonicNanoseconds()
            let vcpu = try vm.makeVCPU(id: id)
            let micros = (monotonicNanoseconds() &- began) / 1000
            guard vcpu.id == id, micros < 2000 else {
                throw KVMError("smoke", detail: "batched vCPU \(id): id \(vcpu.id), \(micros) us (a spare should be immediate)")
            }
        }
        // The last id below the limit: a new batch that cannot go beyond it.
        let last = try vm.makeVCPU(id: batch + 1)
        guard last.id == batch + 1, vm.vcpus.count == batch + 2 else {
            throw KVMError("smoke", detail: "vCPU batch: \(vm.vcpus.count) vCPUs, expected \(batch + 2)")
        }
        // The default id is the next free one.
        vm.vcpuIDLimit = Int.max
        let next = try vm.makeVCPU()
        guard next.id == batch + 2 else { throw KVMError("smoke", detail: "vCPU batch: default id \(next.id)") }
        vm.close()
        log("vCPU batch test passed (batch \(batch))")
    }

    /// Stage-3 memslot test: an anonymous pool slot and two private file
    /// slots of a temporary file, read and written by an EL1 guest (MMU off),
    /// with every observed value reported through MMIO stores.
    public static func runMemslots(log: (String) -> Void) throws {
        let vm = try VirtualMachine(ramSize: 1 << 20)
        log("memslots: KVM_CAP_NR_MEMSLOTS = \(vm.maxMemorySlots)")
        let backing = try KVMPhysicalBacking(vm: vm)

        // A 40000-byte file of a known pattern: u64 at byte i*8 = 0x5943_0000_0000_0000 | i.
        let fileSize = 40_000
        var content = [UInt8](repeating: 0, count: fileSize)
        for i in 0..<(fileSize / 8) {
            withUnsafeBytes(of: (0x5943_0000_0000_0000 | UInt64(i)).littleEndian) { content.replaceSubrange(i * 8..<i * 8 + 8, with: $0) }
        }
        let tmpdir = getenv("TMPDIR").map { String(cString: $0) } ?? "/tmp"
        var template = Array("\(tmpdir)/ycode-memslot-XXXXXX".utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard fd >= 0 else { throw KVMError("mkstemp", errno: Glibc.errno) }
        let path = String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        defer { close(fd); unlink(path) }
        guard content.withUnsafeBytes({ Glibc.write(fd, $0.baseAddress!, $0.count) }) == fileSize else {
            throw KVMError("write temp file", errno: Glibc.errno)
        }

        // Slot A: the whole file (40000 bytes -> 48 KiB slot; the tail past EOF is zero).
        let fileA = try backing.mapFile(hostFD: fd, fileSize: UInt64(fileSize), offset: 0, size: UInt64(fileSize), name: "memslot-test")
        // Slot B: from offset 16 KiB, 32 KiB long (ends 7232 bytes past EOF).
        let fileB = try backing.mapFile(hostFD: fd, fileSize: UInt64(fileSize), offset: 16384, size: 32768, name: "memslot-test")
        // Anonymous pool: two allocations, a release, and a reuse that must read as zeros.
        let anon1 = try backing.allocateAnonymous(size: 16384)
        let anon2 = try backing.allocateAnonymous(size: 3 * 16384)
        try backing.writePhysical(gpa: anon1, bytes: A64.bytes([0xAAAA_5555, 0x1234_5678]))
        backing.release(gpa: anon1, size: 16384)
        let anon3 = try backing.allocateAnonymous(size: 16384)
        guard anon3 == anon1 else { throw KVMError("smoke", detail: "pool did not reuse the released run") }
        try backing.writePhysical(gpa: anon2 + 16384, bytes: [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])
        log("memslots: file A at 0x\(String(fileA, radix: 16)), file B at 0x\(String(fileB, radix: 16)), pool runs 0x\(String(anon3, radix: 16)) and 0x\(String(anon2, radix: 16)); \(vm.memorySlotCount) slots")

        let doorbell: UInt64 = 0x0900_0000
        var program: [UInt32] = A64.mov64(1, doorbell)
        func report(_ base: UInt64, _ offset: UInt32) {
            program += A64.mov64(4, base)
            program += [A64.ldr(2, 4, offset), A64.str(2, 1)]
        }
        report(fileA, 0)            // file word 0
        program += A64.mov64(4, fileA + 39_992)   // last word of the file
        program += [A64.ldr(2, 4), A64.str(2, 1)]
        program += A64.mov64(4, fileA + 40_000)   // just past EOF, in the host page that holds EOF
        program += [A64.ldr(2, 4), A64.str(2, 1)]
        program += A64.mov64(4, fileA + 40_960)   // past EOF, inside the slot
        program += [A64.ldr(2, 4), A64.str(2, 1)]
        report(fileB, 0)            // file word 2048
        report(fileB, 24_576)       // file B: 1 KiB past EOF (slot ends 7232 bytes past EOF)
        // Copy-on-write: store into file A, read it back.
        program += A64.mov64(4, fileA)
        program += A64.mov64(3, 0xC000_0000_0000_BEEF)
        program += [A64.str(3, 4), A64.ldr(2, 4), A64.str(2, 1)]
        report(anon3, 0)            // reused pool page: zero
        report(anon2, 16384)
        program += A64.mov64(0, 0x8400_0008) + [A64.hvc0, A64.branchSelf]
        try vm.write(gpa: vm.ramGPA, bytes: A64.bytes(program))

        let expected: [(String, UInt64)] = [
            ("file word 0", 0x5943_0000_0000_0000),
            ("last file word", 0x5943_0000_0000_0000 | 4999),
            ("past EOF, same host page as EOF", 0),
            ("past EOF, next host page", 0),
            ("file B word 0 (file word 2048)", 0x5943_0000_0000_0000 | 2048),
            ("file B past EOF", 0),
            ("copy-on-write store", 0xC000_0000_0000_BEEF),
            ("reused pool page", 0),
            ("pool page written by the VMM", 0x8877_6655_4433_2211),
        ]
        let vcpu = try vm.makeVCPU()
        try vcpu.set(.pc, vm.ramGPA)
        try vcpu.set(.pstate, VCPU.pstateEL1hMasked)
        try Watchdog.arm(milliseconds: 5_000)
        defer { try? Watchdog.arm(milliseconds: 0) }
        for (name, value) in expected {
            let exit = try vcpu.run()
            guard case let .mmio(.write, address, data, 8) = exit, address == doorbell else {
                throw KVMError("smoke", detail: "\(name): expected an MMIO report, got \(exit)")
            }
            guard data == value else {
                throw KVMError("smoke", detail: "\(name): guest read 0x\(String(data, radix: 16)), expected 0x\(String(value, radix: 16))")
            }
            log("memslots: \(name) = 0x\(String(data, radix: 16)) ok")
        }
        let last = try vcpu.run()
        guard case .systemEvent = last else { throw KVMError("smoke", detail: "expected PSCI SYSTEM_OFF, got \(last)") }

        // The file itself must be unchanged.
        var check = [UInt8](repeating: 0, count: 8)
        guard pread(fd, &check, 8, 0) == 8, check == Array(content[0..<8]) else {
            throw KVMError("smoke", detail: "the guest's store reached the host file")
        }
        // The VMM sees the guest's private copy.
        let privateWord = try backing.readPhysical(gpa: fileA, count: 8)
        guard privateWord == A64.bytes([0x0000_BEEF, 0xC000_0000]) else {
            throw KVMError("smoke", detail: "VMM read of the copied page: \(privateWord)")
        }
        log("memslots: host file unchanged; VMM sees the private copy")

        let (hz, source) = vcpu.counterFrequency()
        let c1 = try vcpu.virtualCounter()
        usleep(10_000)
        let c2 = try vcpu.virtualCounter()
        log("timer: CNTFRQ = \(hz) Hz (\(source)); virtual counter \(c1) -> \(c2) over 10 ms (\(c2 &- c1) ticks)")
        guard hz > 0, c2 > c1 else { throw KVMError("smoke", detail: "timer registers") }
        log("memslot smoke test passed")
    }
}
#endif
