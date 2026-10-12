// Swift wrappers over the CKVM bindings: a KVM virtual machine with one RAM
// slot, and arm64 vCPUs. Linux only; on other hosts the module exposes just
// `Hypervisor.isAvailable == false`.
// Contract: specs/simulator/vm-shim-protocol.md.

import CKVM

public enum Hypervisor {
    /// True when this build contains the KVM backend (Linux hosts).
    public static var isAvailable: Bool { ckvm_available() != 0 }
}

/// A failed KVM or host operation.
public struct KVMError: Error, CustomStringConvertible, Equatable, Sendable {
    public var operation: String
    /// Positive errno value, or 0 when the error is not an errno failure.
    public var errno: Int32
    public var detail: String

    public init(_ operation: String, errno: Int32 = 0, detail: String = "") {
        self.operation = operation
        self.errno = errno
        self.detail = detail
    }

    public var description: String {
        var text = "\(operation) failed"
        if errno != 0 { text += " (errno \(errno))" }
        if !detail.isEmpty { text += ": \(detail)" }
        return text
    }
}

#if os(Linux) && arch(arm64)
import Glibc

@discardableResult
func kvmCheck(_ result: Int32, _ operation: String) throws -> Int32 {
    if result < 0 { throw KVMError(operation, errno: -result, detail: String(cString: strerror(-result))) }
    return result
}

/// A KVM virtual machine that owns `/dev/kvm`, the VM fd, and one anonymous
/// RAM region registered as memslot 0.
public final class VirtualMachine {
    public let kvmFD: Int32
    public let vmFD: Int32
    public let ramGPA: UInt64
    public let ramSize: Int
    /// Host address of guest RAM.
    public let ram: UnsafeMutableRawPointer
    public private(set) var vcpus: [VCPU] = []

    public static let defaultRAMGPA: UInt64 = 0x4000_0000
    public static let defaultRAMSize = 512 << 20

    public init(ramGPA: UInt64 = VirtualMachine.defaultRAMGPA, ramSize: Int = VirtualMachine.defaultRAMSize) throws {
        let kvm = try kvmCheck(ckvm_open(), "open /dev/kvm")
        var vm: Int32 = -1
        var ramPointer: UnsafeMutableRawPointer?
        do {
            let version = try kvmCheck(ckvm_get_api_version(kvm), "KVM_GET_API_VERSION")
            guard version == 12 else { throw KVMError("KVM_GET_API_VERSION", detail: "unexpected API version \(version)") }
            vm = try kvmCheck(ckvm_create_vm(kvm, 0), "KVM_CREATE_VM")
            guard let pointer = ckvm_alloc_anonymous(ramSize) else {
                throw KVMError("mmap guest RAM", errno: Glibc.errno)
            }
            ramPointer = pointer
            try kvmCheck(ckvm_set_user_memory_region(vm, 0, 0, ramGPA, UInt64(ramSize), UInt64(UInt(bitPattern: pointer))),
                         "KVM_SET_USER_MEMORY_REGION")
        } catch {
            if let ramPointer { _ = ckvm_free_anonymous(ramPointer, ramSize) }
            if vm >= 0 { _ = ckvm_close(vm) }
            _ = ckvm_close(kvm)
            throw error
        }
        self.kvmFD = kvm
        self.vmFD = vm
        self.ramGPA = ramGPA
        self.ramSize = ramSize
        self.ram = ramPointer!
    }

    deinit {
        vcpus.forEach { $0.close() }
        _ = ckvm_close(vmFD)
        _ = ckvm_free_anonymous(ram, ramSize)
        _ = ckvm_close(kvmFD)
    }

    /// Creates and initializes a vCPU (preferred target, PSCI 0.2).
    public func makeVCPU(id: Int = 0) throws -> VCPU {
        let vcpu = try VCPU(vm: self, id: id)
        vcpus.append(vcpu)
        return vcpu
    }

    // MARK: Guest-physical access

    /// True when [gpa, gpa+count) lies inside RAM.
    public func contains(gpa: UInt64, count: Int) -> Bool {
        guard count >= 0, gpa >= ramGPA else { return false }
        let offset = gpa - ramGPA
        return offset <= UInt64(ramSize) && UInt64(count) <= UInt64(ramSize) - offset
    }

    private func pointer(gpa: UInt64, count: Int) throws -> UnsafeMutableRawPointer {
        guard contains(gpa: gpa, count: count) else {
            throw KVMError("guest physical access", detail: "GPA 0x\(String(gpa, radix: 16)) + \(count) is outside RAM")
        }
        return ram + Int(gpa - ramGPA)
    }

    public func read(gpa: UInt64, count: Int) throws -> [UInt8] {
        let source = try pointer(gpa: gpa, count: count)
        return [UInt8](UnsafeRawBufferPointer(start: source, count: count))
    }

    public func write(gpa: UInt64, bytes: [UInt8]) throws {
        let destination = try pointer(gpa: gpa, count: bytes.count)
        bytes.withUnsafeBytes { destination.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    }

    public func readU64(gpa: UInt64) throws -> UInt64 {
        let source = try pointer(gpa: gpa, count: 8)
        return UInt64(littleEndian: source.loadUnaligned(as: UInt64.self))
    }

    public func writeU64(gpa: UInt64, _ value: UInt64) throws {
        let destination = try pointer(gpa: gpa, count: 8)
        destination.storeBytes(of: value.littleEndian, as: UInt64.self)
    }

    /// Zero-fills [gpa, gpa+count).
    public func zero(gpa: UInt64, count: Int) throws {
        let destination = try pointer(gpa: gpa, count: count)
        destination.initializeMemory(as: UInt8.self, repeating: 0, count: count)
    }
}

/// Why a vCPU returned to the VMM.
public enum VCPUExit: Equatable, Sendable, CustomStringConvertible {
    public enum MMIODirection: Equatable, Sendable { case read, write }
    /// A guest access to a GPA with no memslot. For writes, `data` holds the
    /// stored value (little-endian, zero-extended). For reads, complete the
    /// access with `VCPU.completeMMIORead(_:)` before the next `run()`.
    case mmio(MMIODirection, address: UInt64, data: UInt64, length: Int)
    case hlt
    case shutdown
    /// PSCI SYSTEM_OFF / SYSTEM_RESET and similar (KVM_SYSTEM_EVENT_* type).
    case systemEvent(type: UInt32, data: [UInt64])
    case internalError(suberror: UInt32, data: [UInt64])
    case failEntry(reason: UInt64, cpu: UInt32)
    /// A data abort KVM could not decode (no valid instruction syndrome).
    case armNISV(esrISS: UInt64, faultIPA: UInt64)
    /// The run was interrupted by the watchdog timer.
    case watchdog
    case other(reason: UInt32)

    public var description: String {
        func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }
        switch self {
        case let .mmio(direction, address, data, length):
            return "mmio \(direction == .write ? "write" : "read") \(hex(address)) len \(length)" + (direction == .write ? " data \(hex(data))" : "")
        case .hlt: return "hlt"
        case .shutdown: return "shutdown"
        case let .systemEvent(type, data): return "system event type \(type) data \(data.map(hex))"
        case let .internalError(suberror, data): return "internal error suberror \(suberror) data \(data.map(hex))"
        case let .failEntry(reason, cpu): return "fail entry reason \(hex(reason)) cpu \(cpu)"
        case let .armNISV(iss, ipa): return "data abort without syndrome: ESR ISS \(hex(iss)) IPA \(hex(ipa))"
        case .watchdog: return "watchdog timeout"
        case let .other(reason): return "exit reason \(reason)"
        }
    }
}

/// A core register of the vCPU.
public enum CoreRegister: Equatable, Sendable {
    case x(Int)
    case spEL0, pc, pstate, spEL1, elrEL1, spsrEL1

    var id: UInt64 {
        switch self {
        case let .x(n):
            precondition((0...30).contains(n), "x\(n) is not a general-purpose register")
            return ckvm_reg_x(UInt32(n))
        case .spEL0: return ckvm_reg_sp_el0()
        case .pc: return ckvm_reg_pc()
        case .pstate: return ckvm_reg_pstate()
        case .spEL1: return ckvm_reg_sp_el1()
        case .elrEL1: return ckvm_reg_elr_el1()
        case .spsrEL1: return ckvm_reg_spsr_el1()
        }
    }
}

/// A system register, by its MRS/MSR encoding.
public struct SystemRegister: Equatable, Sendable {
    public var op0, op1, crn, crm, op2: UInt32
    public init(op0: UInt32, op1: UInt32, crn: UInt32, crm: UInt32, op2: UInt32) {
        (self.op0, self.op1, self.crn, self.crm, self.op2) = (op0, op1, crn, crm, op2)
    }
    var id: UInt64 { ckvm_reg_sysreg(op0, op1, crn, crm, op2) }

    public static let sctlrEL1 = SystemRegister(op0: 3, op1: 0, crn: 1, crm: 0, op2: 0)
    public static let ttbr0EL1 = SystemRegister(op0: 3, op1: 0, crn: 2, crm: 0, op2: 0)
    public static let tcrEL1 = SystemRegister(op0: 3, op1: 0, crn: 2, crm: 0, op2: 2)
    public static let esrEL1 = SystemRegister(op0: 3, op1: 0, crn: 5, crm: 2, op2: 0)
    public static let farEL1 = SystemRegister(op0: 3, op1: 0, crn: 6, crm: 0, op2: 0)
    public static let mairEL1 = SystemRegister(op0: 3, op1: 0, crn: 10, crm: 2, op2: 0)
    public static let vbarEL1 = SystemRegister(op0: 3, op1: 0, crn: 12, crm: 0, op2: 0)
    public static let tpidrEL0 = SystemRegister(op0: 3, op1: 3, crn: 13, crm: 0, op2: 2)
    public static let tpidrroEL0 = SystemRegister(op0: 3, op1: 3, crn: 13, crm: 0, op2: 3)
    public static let idAA64MMFR0EL1 = SystemRegister(op0: 3, op1: 0, crn: 0, crm: 7, op2: 0)
}

/// One arm64 vCPU with its mapped `struct kvm_run`.
public final class VCPU {
    public let fd: Int32
    public let id: Int
    private let runArea: UnsafeMutableRawPointer
    private let runSize: Int
    private var closed = false
    /// Number of KVM_RUN calls that returned to user space.
    public private(set) var exitCount = 0

    /// PSTATE for EL1h with D, A, I, F masked.
    public static let pstateEL1hMasked: UInt64 = 0x3C5

    init(vm: VirtualMachine, id: Int) throws {
        let fd = try kvmCheck(ckvm_create_vcpu(vm.vmFD, UInt(id)), "KVM_CREATE_VCPU")
        do {
            let size = Int(try kvmCheck(ckvm_get_vcpu_mmap_size(vm.kvmFD), "KVM_GET_VCPU_MMAP_SIZE"))
            try kvmCheck(ckvm_arm_vcpu_init_preferred(vm.vmFD, fd, UInt32(1) << UInt32(CKVM_ARM_VCPU_FEATURE_PSCI_0_2)),
                         "KVM_ARM_VCPU_INIT")
            guard let run = ckvm_map_run(fd, size) else { throw KVMError("mmap kvm_run", errno: Glibc.errno) }
            self.runArea = run
            self.runSize = size
        } catch {
            _ = ckvm_close(fd)
            throw error
        }
        self.fd = fd
        self.id = id
    }

    deinit { close() }

    func close() {
        guard !closed else { return }
        closed = true
        munmap(runArea, runSize)
        _ = ckvm_close(fd)
    }

    // MARK: Registers

    public func get(_ register: CoreRegister) throws -> UInt64 { try getRaw(register.id, "\(register)") }
    public func set(_ register: CoreRegister, _ value: UInt64) throws { try setRaw(register.id, value, "\(register)") }
    public func get(_ register: SystemRegister) throws -> UInt64 { try getRaw(register.id, "sysreg") }
    public func set(_ register: SystemRegister, _ value: UInt64) throws { try setRaw(register.id, value, "sysreg") }

    private func getRaw(_ id: UInt64, _ name: String) throws -> UInt64 {
        var value: UInt64 = 0
        try kvmCheck(ckvm_get_one_reg_u64(fd, id, &value), "KVM_GET_ONE_REG \(name)")
        return value
    }

    private func setRaw(_ id: UInt64, _ value: UInt64, _ name: String) throws {
        try kvmCheck(ckvm_set_one_reg_u64(fd, id, value), "KVM_SET_ONE_REG \(name)")
    }

    // MARK: Running

    /// Runs the vCPU until it exits to user space.
    public func run() throws -> VCPUExit {
        while true {
            let result = ckvm_run(fd)
            if result == -EINTR || result == -EAGAIN {
                if ckvm_watchdog_fired() != 0 { return .watchdog }
                continue
            }
            try kvmCheck(result, "KVM_RUN")
            exitCount += 1
            return decodeExit()
        }
    }

    /// Supplies the value for a pending MMIO read (little-endian, `length` bytes).
    public func completeMMIORead(_ value: UInt64, length: Int) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes in
            ckvm_run_mmio_set_data(runArea, bytes.bindMemory(to: UInt8.self).baseAddress, UInt32(min(length, 8)))
        }
    }

    private func decodeExit() -> VCPUExit {
        let reason = ckvm_run_exit_reason(runArea)
        switch Int(reason) {
        case Int(CKVM_EXIT_MMIO):
            let length = Int(ckvm_run_mmio_len(runArea))
            var bytes = [UInt8](repeating: 0, count: 8)
            ckvm_run_mmio_get_data(runArea, &bytes, 8)
            var data: UInt64 = 0
            for i in 0..<min(length, 8) { data |= UInt64(bytes[i]) << (8 * UInt64(i)) }
            let direction: VCPUExit.MMIODirection = ckvm_run_mmio_is_write(runArea) != 0 ? .write : .read
            return .mmio(direction, address: ckvm_run_mmio_phys_addr(runArea), data: direction == .write ? data : 0, length: length)
        case Int(CKVM_EXIT_HLT):
            return .hlt
        case Int(CKVM_EXIT_SHUTDOWN):
            return .shutdown
        case Int(CKVM_EXIT_SYSTEM_EVENT):
            let count = min(Int(ckvm_run_system_event_ndata(runArea)), 16)
            return .systemEvent(type: ckvm_run_system_event_type(runArea),
                                data: (0..<count).map { ckvm_run_system_event_data(runArea, UInt32($0)) })
        case Int(CKVM_EXIT_INTERNAL_ERROR):
            let count = min(Int(ckvm_run_internal_ndata(runArea)), 16)
            return .internalError(suberror: ckvm_run_internal_suberror(runArea),
                                  data: (0..<count).map { ckvm_run_internal_data(runArea, UInt32($0)) })
        case Int(CKVM_EXIT_FAIL_ENTRY):
            return .failEntry(reason: ckvm_run_fail_entry_reason(runArea), cpu: ckvm_run_fail_entry_cpu(runArea))
        case Int(CKVM_EXIT_ARM_NISV):
            return .armNISV(esrISS: ckvm_run_arm_nisv_esr_iss(runArea), faultIPA: ckvm_run_arm_nisv_fault_ipa(runArea))
        case Int(CKVM_EXIT_INTR):
            return ckvm_watchdog_fired() != 0 ? .watchdog : .other(reason: reason)
        default:
            return .other(reason: reason)
        }
    }
}

/// A one-shot timer that interrupts KVM_RUN on the arming thread.
public enum Watchdog {
    /// Arms (or, with 0, disarms) the watchdog for the calling thread.
    public static func arm(milliseconds: UInt64) throws {
        try kvmCheck(ckvm_watchdog_arm(milliseconds), "watchdog timer")
    }
    public static var fired: Bool { ckvm_watchdog_fired() != 0 }
}
#endif
