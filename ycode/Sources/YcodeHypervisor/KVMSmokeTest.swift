// A self-contained check of the KVM plumbing: boots a tiny hand-encoded EL1
// guest (MMU off) that stores to an unbacked GPA, loads from it, stores the
// loaded value back, and powers off through PSCI SYSTEM_OFF. Run with
// `ycode-simd --kvm-smoke`.

#if os(Linux) && arch(arm64)
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
    }
}
#endif
