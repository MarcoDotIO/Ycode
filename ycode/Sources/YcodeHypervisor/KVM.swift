// Swift wrappers over the CKVM bindings: a KVM virtual machine with one RAM
// slot, and arm64 vCPUs. Linux only; on other hosts the module exposes just
// `Hypervisor.isAvailable == false`.
// Contract: specs/simulator/vm-shim-protocol.md.

import CKVM
import YcodeDarwinABI

public enum Hypervisor {
    /// True when this build contains the KVM backend (arm64 Linux hosts).
    public static var isAvailable: Bool { ckvm_available() != 0 }
}

#if os(Linux) && arch(arm64)
extension Hypervisor {
    /// The host's virtual counter (`CNTVCT_EL0`, read at EL0). A guest's
    /// `CNTVCT_EL0` differs from it by a constant (`VCPU.counterOffset()`).
    public static func hostCounter() -> UInt64 { ckvm_host_cntvct() }
    /// ID_AA64MMFR2_EL1 as Linux exposes it to user space (0 when hidden).
    public static func hostIDAA64MMFR2() -> UInt64 { ckvm_host_id_aa64mmfr2() }
}
#endif

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
import Synchronization

/// Diagnostics (`YCODE_DEBUG_QUARANTINE=1`): host memory the VMM gives back
/// (guest RAM, pool, file slots, vCPU run areas) stays reserved as
/// inaccessible pages instead of being unmapped, so a stale access faults
/// at once instead of landing in whatever the host maps there next.
let quarantineHostMemory = getenv("YCODE_DEBUG_QUARANTINE").map { String(cString: $0) == "1" } ?? false

/// Diagnostics: hardware write watchpoints (see `ckvm_hwwatch_arm`).
public enum HardwareWatchpoint {
    public static func arm(_ slot: Int, _ address: UInt64) -> Int32 { ckvm_hwwatch_arm_slot(Int32(slot), address) }
    public static func disarm(_ slot: Int) { ckvm_hwwatch_disarm_slot(Int32(slot)) }
    /// Starts the lost-write checker threads (`ckvm_memcheck_start`).
    public static func startMemoryCheck(threads: Int) { _ = ckvm_memcheck_start(Int32(threads)) }
    /// Gives the map reader/writer check (`YCODE_DEBUG_RW_GUARD`) its call chains.
    public static func installFrameCapture() { DebugAccessGuard.captureFrames = ckvm_capture_frames }
}

/// Unmaps [address, address+size) (or quarantines it, see above).
func releaseHostMemory(_ address: UnsafeMutableRawPointer, _ size: Int) {
    if quarantineHostMemory {
        _ = mmap(address, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE | MAP_FIXED, -1, 0)
    } else {
        munmap(address, size)
    }
}

@discardableResult
func kvmCheck(_ result: Int32, _ operation: String) throws -> Int32 {
    if result < 0 { throw KVMError(operation, errno: -result, detail: String(cString: strerror(-result))) }
    return result
}

/// One KVM memslot: a guest-physical range backed by host memory the VM owns.
public struct MemorySlot: Sendable, CustomStringConvertible {
    /// `shared`: the host memory of a `SharedMemoryObject`, owned by the
    /// object (never unmapped by the VM). `readOnlyFiles`: the process-wide
    /// `SharedFileArena` (never unmapped by the VM; registered read-only).
    public enum Kind: Sendable, Equatable { case ram, anonymousPool, file, shared, readOnlyFiles }
    public var slot: UInt32
    public var gpa: UInt64
    public var size: UInt64
    /// Host address of the backing memory, as an integer (Sendable).
    public var hostAddress: UInt
    public var kind: Kind
    /// For tracing: the file path or the purpose.
    public var name: String
    /// Registered with KVM_MEM_READONLY: guest writes exit as MMIO, and the
    /// VMM refuses to write it.
    public var readOnly: Bool = false

    public var end: UInt64 { gpa + size }
    public func contains(gpa a: UInt64, count: Int) -> Bool {
        guard count >= 0, a >= gpa else { return false }
        let offset = a - gpa
        return offset <= size && UInt64(count) <= size - offset
    }
    public var description: String {
        "slot \(slot) gpa 0x\(String(gpa, radix: 16))-0x\(String(end, radix: 16)) \(kind) \(name)"
    }
}

/// A KVM virtual machine that owns `/dev/kvm`, the VM fd, one anonymous
/// RAM region registered as memslot 0, and any further memslots added with
/// `addMemorySlot`. Guest-physical reads and writes reach every slot.
public final class VirtualMachine: @unchecked Sendable {
    public let kvmFD: Int32
    public let vmFD: Int32
    public let ramGPA: UInt64
    public let ramSize: Int
    /// Host address of guest RAM.
    public let ram: UnsafeMutableRawPointer
    /// Every vCPU created so far (index = vCPU id). Read under `lock`.
    public var vcpus: [VCPU] { lock.withLock { vcpuList } }
    private var vcpuList: [VCPU] = []
    /// vCPUs created ahead by a batch (`makeVCPU`), by id, until asked for.
    private var spareVCPUs: [Int: VCPU] = [:]
    /// Ids whose KVM_CREATE_VCPU is in flight (a `makeVCPU` for one of them
    /// waits for it).
    private var creatingIDs: Set<Int> = []
    /// The ids a batch may use: 0 ..< `vcpuIDLimit` (the owner's capacity;
    /// set before the first `makeVCPU`).
    public var vcpuIDLimit: Int {
        get { lock.withLock { idLimit } }
        set { lock.withLock { idLimit = newValue } }
    }
    private var idLimit = Int.max

    /// `YCODE_VCPU_BATCH=<n>` (default 3; 0 = off): a `makeVCPU` that has
    /// to create its vCPU creates the next `n` ids too, back to back.
    ///
    /// Why (measured on the Thor, Linux 6.8 arm64): once a VM has run with
    /// more than one vCPU, the KVM_CREATE_VCPU that follows a vCPU's first
    /// KVM_RUN waits for an RCU grace period, 25-60 ms (35 ms mean; Ycode
    /// boots averaged 30 ms per new vCPU). Creations with no first run in
    /// between, and every creation before the VM's second vCPU runs, take
    /// microseconds. A batch pays one grace period for `n + 1` vCPUs, and
    /// the batch made with vCPU 0 at image build pays none.
    public static let creationBatch = getenv("YCODE_VCPU_BATCH").flatMap { Int(String(cString: $0)) }.map { max(0, $0) } ?? 3

    /// `YCODE_VCPU_PRECREATE=<n>` (thread-latency.md §3.1; default 4, the
    /// earlier batch; 16 measured no faster to the home screen): the
    /// batch made with vCPU 0 (at image build, before any vCPU of the VM
    /// ran) has `n` vCPUs instead of `creationBatch + 1`.
    ///
    /// Why: Linux arm64 KVM keeps a VM-wide MPIDR-to-vCPU table, built at
    /// a vCPU's first KVM_RUN once the VM has more than one vCPU, and every
    /// KVM_CREATE_VCPU discards it and waits for an RCU grace period
    /// (`synchronize_rcu`) before freeing it. While no vCPU has run there is
    /// no table and a creation costs microseconds; afterwards each creation
    /// batch costs one grace period (25-60 ms on a loaded host), and a
    /// burst of thread starts queues behind them. Creating the vCPUs a
    /// process will need before it runs avoids every grace period.
    public static let precreateCount = getenv("YCODE_VCPU_PRECREATE").flatMap { Int(String(cString: $0)) }
        .map { max(1, min($0, 64)) } ?? (creationBatch + 1)

    /// `YCODE_VCPU_BATCH_GROW=1` (thread-latency.md §3.1): a later batch
    /// creates as many vCPUs as the VM has (doubling it), at least
    /// `creationBatch + 1`, so a process that grows to n threads pays
    /// about log2(n / precreateCount) grace periods instead of one per
    /// `creationBatch + 1` threads.
    public static let batchGrow = getenv("YCODE_VCPU_BATCH_GROW").map { String(cString: $0) == "1" } ?? false
    /// `KVM_CAP_NR_MEMSLOTS`: the number of memslots the VM may register.
    public let maxMemorySlots: Int
    /// `KVM_CAP_READONLY_MEM`: memslots may be registered read-only.
    public let supportsReadOnlyMemory: Bool
    /// `KVM_CAP_MAX_VCPUS` (the hard limit) and `KVM_CAP_NR_VCPUS` (the
    /// recommended limit), from the VM fd (falling back to /dev/kvm).
    public let maxVCPUs: Int
    public let recommendedVCPUs: Int
    /// Every registered slot (slot 0 first), sorted by GPA. Many host threads
    /// (one per vCPU) read it while a trap may add a slot, so it is guarded by
    /// `lock` and readers get a snapshot.
    public var memorySlots: [MemorySlot] { lock.withLock { slotList } }
    private var slotList: [MemorySlot] = []
    private var nextSlotNumber: UInt32 = 1
    /// Guards `slotList`, `nextSlotNumber`, `vcpuList` and
    /// `creationsInFlight`.
    private let lock = HostMutex(name: "VM")
    /// vCPU creations and memslot additions whose ioctls run without `lock`
    /// (`makeVCPU`, `addMemorySlot`); `close` waits for them before it
    /// closes the VM fd.
    private var creationsInFlight = 0
    /// Serializes memslot additions (`addMemorySlot`).
    private let slotChangeLock = HostMutex(name: "VM memslot changes")
    private let creationsDone = HostCondition()
    /// Set by `close()`; read without the lock on the RAM fast path.
    private let closedFlag = Atomic<Bool>(false)
    /// True once `close()` released the VM.
    public var isClosed: Bool { closedFlag.load(ordering: .acquiring) }

    /// KVM_CAP_READONLY_MEM and KVM_MEM_READONLY (linux/kvm.h).
    static let capReadOnlyMemory = 81
    static let memoryFlagReadOnly: UInt32 = 1 << 1

    /// Diagnostics: KVM_CREATE_VM calls and their time (the kernel registers
    /// the VM's MMU notifier on the host process's address space there).
    public static let createVMCount = Atomic<UInt64>(0)
    public static let createVMNanoseconds = Atomic<UInt64>(0)
    /// Diagnostics: VM closes and the time of the VM fd's close (the
    /// kernel tears the VM down there when it holds the last reference).
    public static let closeCount = Atomic<UInt64>(0)
    public static let closeNanoseconds = Atomic<UInt64>(0)

    public static let defaultRAMGPA: UInt64 = 0x4000_0000
    public static let defaultRAMSize = 512 << 20

    public init(ramGPA: UInt64 = VirtualMachine.defaultRAMGPA, ramSize: Int = VirtualMachine.defaultRAMSize) throws {
        let kvm = try kvmCheck(ckvm_open(), "open /dev/kvm")
        var vm: Int32 = -1
        var ramPointer: UnsafeMutableRawPointer?
        var slotLimit = 0
        var readOnlyMemory = false
        var vcpuLimits = (max: 0, recommended: 0)
        do {
            let version = try kvmCheck(ckvm_get_api_version(kvm), "KVM_GET_API_VERSION")
            guard version == 12 else { throw KVMError("KVM_GET_API_VERSION", detail: "unexpected API version \(version)") }
            let createBegan = monotonicNanoseconds()
            vm = try kvmCheck(ckvm_create_vm(kvm, 0), "KVM_CREATE_VM")
            Self.createVMNanoseconds.wrappingAdd(monotonicNanoseconds() &- createBegan, ordering: .relaxed)
            Self.createVMCount.wrappingAdd(1, ordering: .relaxed)
            // The VM-level check reports the per-VM limit; fall back to the system one.
            slotLimit = Int(ckvm_check_extension(vm, Int(CKVM_CAP_NR_MEMSLOTS)))
            if slotLimit <= 0 { slotLimit = Int(ckvm_check_extension(kvm, Int(CKVM_CAP_NR_MEMSLOTS))) }
            readOnlyMemory = ckvm_check_extension(vm, Self.capReadOnlyMemory) > 0
                || ckvm_check_extension(kvm, Self.capReadOnlyMemory) > 0
            guard slotLimit > 0 else { throw KVMError("KVM_CAP_NR_MEMSLOTS", detail: "the kernel reports no memslots") }
            func capability(_ cap: Int) -> Int {
                let v = Int(ckvm_check_extension(vm, cap))
                return v > 0 ? v : max(0, Int(ckvm_check_extension(kvm, cap)))
            }
            // KVM_CAP_NR_VCPUS absent means 4; KVM_CAP_MAX_VCPUS absent means NR_VCPUS (KVM API docs).
            let recommended = capability(Int(CKVM_CAP_NR_VCPUS))
            vcpuLimits.recommended = recommended > 0 ? recommended : 4
            let hard = capability(Int(CKVM_CAP_MAX_VCPUS))
            vcpuLimits.max = hard > 0 ? hard : vcpuLimits.recommended
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
        self.maxMemorySlots = slotLimit
        self.supportsReadOnlyMemory = readOnlyMemory
        self.maxVCPUs = vcpuLimits.max
        self.recommendedVCPUs = vcpuLimits.recommended
        self.slotList = [MemorySlot(slot: 0, gpa: ramGPA, size: UInt64(ramSize),
                                       hostAddress: UInt(bitPattern: ramPointer!), kind: .ram, name: "RAM")]
    }

    deinit { close() }

    /// Destroys the VM now (stage 4b teardown): closes every vCPU, the VM
    /// and /dev/kvm fds, and unmaps every memslot's host memory (guest RAM,
    /// the anonymous pool reservation, file mappings). No vCPU may be
    /// running. Afterwards every guest-physical access fails (no memslot)
    /// and `makeVCPU`/`addMemorySlot` throw. Idempotent.
    ///
    /// The VM is marked closed and its slots dropped under the VM's lock;
    /// the slow part (KVM tears down the stage-2 tables and waits for an
    /// SRCU grace period: milliseconds to tens of milliseconds for a VM
    /// that ran) happens after, without the lock. Callers should not hold
    /// the kernel lock across `close()` either (stage 6 §5).
    public func close() {
        let detached: (vcpus: [VCPU], slots: [MemorySlot])? = lock.withLock {
            guard !closedFlag.exchange(true, ordering: .acquiringAndReleasing) else { return nil }
            // A creation in flight uses the VM fd: let it finish (its vCPU
            // is in the list then, and is closed below).
            while creationsInFlight > 0 { creationsDone.wait(lock) }
            let taken = (vcpuList + spareVCPUs.values, slotList)
            spareVCPUs.removeAll()
            vcpuList.removeAll()
            slotList.removeAll()
            return taken
        }
        guard let detached else { return }
        let closeBegan = monotonicNanoseconds()
        detached.vcpus.forEach { $0.close() }
        _ = ckvm_close(vmFD)
        for slot in detached.slots where slot.kind != .shared && slot.kind != .readOnlyFiles {
            releaseHostMemory(UnsafeMutableRawPointer(bitPattern: slot.hostAddress)!, Int(slot.size))
        }
        _ = ckvm_close(kvmFD)
        Self.closeNanoseconds.wrappingAdd(monotonicNanoseconds() &- closeBegan, ordering: .relaxed)
        Self.closeCount.wrappingAdd(1, ordering: .relaxed)
    }

    /// `KVM_CAP_COUNTER_OFFSET`: `setCounterOffset` is available.
    public var supportsCounterOffset: Bool {
        ckvm_check_extension(vmFD, Int(CKVM_CAP_COUNTER_OFFSET)) > 0
            || ckvm_check_extension(kvmFD, Int(CKVM_CAP_COUNTER_OFFSET)) > 0
    }

    /// Sets the VM-wide counter offset (`KVM_ARM_SET_COUNTER_OFFSET`): every
    /// vCPU of this VM, present and future, reads `CNTVCT_EL0` as
    /// `Hypervisor.hostCounter() &- offset`, and creating a vCPU no longer
    /// resets it (fast-traps.md §3.1). Call before any vCPU runs.
    public func setCounterOffset(_ offset: UInt64) throws {
        // A reused VM (`resetForReuse`) keeps the offset it was given; KVM
        // refuses a change once a vCPU has run.
        if lock.withLock({ counterOffsetSet == offset }) { return }
        try kvmCheck(ckvm_set_counter_offset(vmFD, offset), "KVM_ARM_SET_COUNTER_OFFSET")
        lock.withLock { counterOffsetSet = offset }
    }
    /// The VM-wide counter offset set so far (nil: none).
    private var counterOffsetSet: UInt64?
    /// The HVC doorbell filter is installed (a reused VM keeps it).
    private var hvcDoorbellInstalled = false

    /// The forwarded-HVC doorbell's SMCCC function ID (vm-shim-protocol.md §5.1).
    public static let hvcDoorbellFunction: UInt32 = 0xC600_5943

    /// Installs the SMCCC filter that forwards the HVC doorbell to user space
    /// (vm-shim-protocol.md §5.1). Call before any vCPU runs; throws when
    /// the host kernel has no SMCCC filter.
    public func installHVCDoorbell() throws {
        if lock.withLock({ hvcDoorbellInstalled }) { return }
        try kvmCheck(ckvm_set_smccc_filter(vmFD, Self.hvcDoorbellFunction, 1, UInt8(CKVM_SMCCC_FILTER_FWD_TO_USER)),
                     "KVM_SET_DEVICE_ATTR(KVM_ARM_VM_SMCCC_FILTER)")
        lock.withLock { hvcDoorbellInstalled = true }
    }

    // MARK: Reuse (boot-profile.md §9, SP1)

    /// How many times this VM was reset for another image.
    public private(set) var reuseCount = 0

    /// Makes this VM ready for another image (`YCODE_VM_REUSE`): every vCPU
    /// is reset to its initial state (`KVM_ARM_VCPU_INIT` again, which KVM
    /// allows after a vCPU ran) and becomes a spare under its id, and guest
    /// RAM is returned to the host (it reads as zeros). The memslots, the
    /// counter offset and the HVC doorbell stay. No vCPU may be running (the
    /// image's pool threads were joined), and no other thread may use the VM.
    /// False (nothing usable: close the VM) when a vCPU cannot be reset.
    public func resetForReuse() -> Bool {
        let vcpus: [VCPU]? = lock.withLock {
            guard !isClosed, creationsInFlight == 0, creatingIDs.isEmpty else { return nil }
            let all = vcpuList + Array(spareVCPUs.values)
            vcpuList.removeAll()
            spareVCPUs.removeAll()
            return all
        }
        guard let vcpus else { return false }
        var ok = true
        for vcpu in vcpus where ok { ok = vcpu.reset(vmFD: vmFD) }
        lock.withLock {
            // On failure the vCPUs stay listed (closed with the VM).
            if ok { for vcpu in vcpus { spareVCPUs[vcpu.id] = vcpu } } else { vcpuList += vcpus }
            if ok { reuseCount += 1 }
        }
        guard ok else { return false }
        _ = ckvm_discard_anonymous(ram, ramSize)
        return true
    }

    /// Creates and initializes a vCPU (preferred target, PSCI 0.2). `id`
    /// defaults to the next free vCPU id. Safe to call from any host thread,
    /// also while other vCPUs of the VM run.
    ///
    /// The ioctls (KVM_CREATE_VCPU, KVM_ARM_VCPU_INIT, the kvm_run mapping)
    /// run without `lock`. In a busy host process they can wait for an RCU
    /// grace period (tens of ms), and `lock` also guards the memslot list
    /// that every guest-physical access outside RAM reads. `close` waits for
    /// a creation in flight.
    ///
    /// A vCPU made ahead by a batch (`creationBatch`) is handed out at once;
    /// one whose batch is still in flight is waited for.
    public func makeVCPU(id: Int? = nil) throws -> VCPU {
        enum Plan { case spare(VCPU), create([Int]) }
        let plan: Plan = try lock.withLock {
            guard !isClosed else { throw KVMError("KVM_CREATE_VCPU", errno: EBADF, detail: "the VM is closed") }
            let known = Set(vcpuList.map(\.id)).union(spareVCPUs.keys)
            let vcpuID = id ?? ((known.union(creatingIDs).max() ?? -1) + 1)
            while creatingIDs.contains(vcpuID) { creationsDone.wait(lock) }
            guard !isClosed else { throw KVMError("KVM_CREATE_VCPU", errno: EBADF, detail: "the VM is closed") }
            if let spare = spareVCPUs.removeValue(forKey: vcpuID) {
                vcpuList.append(spare)
                return .spare(spare)
            }
            // This id, then up to `creationBatch` free ids after it.
            var ids = [vcpuID]
            var next = vcpuID + 1
            let taken = known.union(creatingIDs)
            let existing = vcpuList.count + spareVCPUs.count + creatingIDs.count
            let batch = existing == 0 ? Self.precreateCount
                : Self.batchGrow ? max(Self.creationBatch + 1, existing) : Self.creationBatch + 1
            while ids.count < batch, next < idLimit {
                if !taken.contains(next) { ids.append(next) }
                next += 1
            }
            creatingIDs.formUnion(ids)
            creationsInFlight += 1
            return .create(ids)
        }
        guard case let .create(ids) = plan else {
            if case let .spare(vcpu) = plan { return vcpu }
            fatalError("unreachable")
        }
        let created = Result { try VCPU(vm: self, id: ids[0]) }
        // The batch: no grace period between these creations (none of them
        // has run). A failure only ends the batch.
        var spares: [VCPU] = []
        if case .success = created {
            for spareID in ids.dropFirst() {
                guard let spare = try? VCPU(vm: self, id: spareID) else { break }
                spares.append(spare)
            }
        }
        lock.withLock {
            if case let .success(vcpu) = created { vcpuList.append(vcpu) }
            for spare in spares { spareVCPUs[spare.id] = spare }
            creatingIDs.subtract(ids)
            creationsInFlight -= 1
            creationsDone.broadcast()
        }
        return try created.get()
    }

    /// Creates vCPUs 0 ..< `count` as spares (thread-latency.md §3.1), on
    /// a VM that has no vCPU yet, without its lock held during the ioctls;
    /// `makeVCPU` hands them out. Off the kernel lock: the prebuilt VMs.
    /// Does nothing when the VM already has vCPUs. Failures end the batch.
    public func makeSpareVCPUs(count: Int) {
        let ids: [Int]? = lock.withLock {
            guard !isClosed, vcpuList.isEmpty, spareVCPUs.isEmpty, creatingIDs.isEmpty else { return nil }
            let ids = Array(0..<max(0, min(count, idLimit)))
            creatingIDs.formUnion(ids)
            creationsInFlight += 1
            return ids
        }
        guard let ids else { return }
        var spares: [VCPU] = []
        for id in ids {
            guard let vcpu = try? VCPU(vm: self, id: id) else { break }
            spares.append(vcpu)
        }
        lock.withLock {
            for spare in spares { spareVCPUs[spare.id] = spare }
            creatingIDs.subtract(ids)
            creationsInFlight -= 1
            creationsDone.broadcast()
        }
    }

    // MARK: Memslots

    /// Registers `size` bytes of host memory at `host` as a new memslot at
    /// `gpa`. The VM takes ownership of the host mapping (it is unmapped when
    /// the VM is destroyed). `gpa`, `size`, and `host` must be aligned to the
    /// host page size, and the range must not overlap another slot. Throws a
    /// fatal error when the VM has no memslot left. `readOnly` registers it
    /// with KVM_MEM_READONLY (needs `supportsReadOnlyMemory`).
    @discardableResult
    public func addMemorySlot(gpa: UInt64, size: UInt64, host: UnsafeMutableRawPointer,
                              kind: MemorySlot.Kind, name: String, readOnly: Bool = false) throws -> MemorySlot {
        // Additions are serialized by `slotChangeLock`; the ioctl (an SRCU
        // grace period: milliseconds) runs without `lock`, which every
        // guest-physical access outside RAM takes to find its slot. The slot
        // is listed once KVM has it.
        try slotChangeLock.withLock {
            let (number, index) = try lock.withLock { () throws -> (UInt32, Int) in
                let reserved = try reserveMemorySlot(gpa: gpa, size: size, name: name, readOnly: readOnly)
                creationsInFlight += 1
                return reserved
            }
            defer {
                lock.withLock {
                    creationsInFlight -= 1
                    if creationsInFlight == 0 { creationsDone.broadcast() }
                }
            }
            try kvmCheck(ckvm_set_user_memory_region(vmFD, number, readOnly ? Self.memoryFlagReadOnly : 0, gpa, size,
                                                     UInt64(UInt(bitPattern: host))),
                         "KVM_SET_USER_MEMORY_REGION slot \(number) (\(name))")
            let slot = MemorySlot(slot: number, gpa: gpa, size: size, hostAddress: UInt(bitPattern: host), kind: kind, name: name,
                                  readOnly: readOnly)
            lock.withLock { slotList.insert(slot, at: index) }
            return slot
        }
    }

    /// Checks a new slot and takes its number; returns (number, list index).
    /// `lock` held; additions serialized by `slotChangeLock`.
    private func reserveMemorySlot(gpa: UInt64, size: UInt64, name: String, readOnly: Bool) throws -> (UInt32, Int) {
        guard !isClosed else { throw KVMError("KVM_SET_USER_MEMORY_REGION", errno: EBADF, detail: "the VM is closed") }
        guard Int(nextSlotNumber) < maxMemorySlots else {
            throw KVMError("KVM_SET_USER_MEMORY_REGION", detail: "memslots exhausted (KVM_CAP_NR_MEMSLOTS = \(maxMemorySlots)) mapping \(name)")
        }
        guard size > 0 else { throw KVMError("KVM_SET_USER_MEMORY_REGION", detail: "empty slot for \(name)") }
        if readOnly && !supportsReadOnlyMemory {
            throw KVMError("KVM_SET_USER_MEMORY_REGION", detail: "read-only memslots are not supported (\(name))")
        }
        // The slots are sorted by GPA: only the neighbours can overlap.
        let index = slotIndex(after: gpa)
        for i in [index - 1, index] where i >= 0 && i < slotList.count {
            let other = slotList[i]
            if gpa < other.end && other.gpa < gpa + size {
                throw KVMError("KVM_SET_USER_MEMORY_REGION", detail: "GPA range of \(name) overlaps \(other)")
            }
        }
        let number = nextSlotNumber
        nextSlotNumber += 1
        return (number, index)
    }

    /// The number of memslots registered so far, slot 0 included.
    public var memorySlotCount: Int { lock.withLock { slotList.count } }

    // MARK: Guest-physical access

    /// The index of the first slot whose start is > gpa (binary search). Call under `lock`.
    private func slotIndex(after gpa: UInt64) -> Int {
        var low = 0, high = slotList.count
        while low < high {
            let mid = (low + high) / 2
            if slotList[mid].gpa <= gpa { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The memslot that holds `gpa` (binary search for the last slot whose
    /// start is <= gpa). RAM (slot 0) is answered without taking the lock.
    public func memorySlot(containing gpa: UInt64) -> MemorySlot? {
        if isClosed { return nil }
        if gpa >= ramGPA, gpa - ramGPA < UInt64(ramSize) {
            return MemorySlot(slot: 0, gpa: ramGPA, size: UInt64(ramSize), hostAddress: UInt(bitPattern: ram), kind: .ram, name: "RAM")
        }
        return lock.withLock {
            let low = slotIndex(after: gpa)
            guard low > 0, gpa < slotList[low - 1].end else { return nil }
            return slotList[low - 1]
        }
    }

    /// The host address of [gpa, gpa+count) for writing: it must lie inside
    /// one memslot that is not read-only.
    public func writableHostPointer(gpa: UInt64, count: Int) throws -> UnsafeMutableRawPointer {
        guard let slot = memorySlot(containing: gpa), slot.contains(gpa: gpa, count: count) else {
            throw KVMError("guest physical access", detail: "GPA 0x\(String(gpa, radix: 16)) + \(count) is outside every memslot")
        }
        guard !slot.readOnly else {
            throw KVMError("guest physical write", errno: EFAULT, detail: "GPA 0x\(String(gpa, radix: 16)) is in read-only \(slot)")
        }
        return UnsafeMutableRawPointer(bitPattern: slot.hostAddress)! + Int(gpa - slot.gpa)
    }

    /// True when [gpa, gpa+count) lies inside one memslot.
    public func contains(gpa: UInt64, count: Int) -> Bool {
        memorySlot(containing: gpa)?.contains(gpa: gpa, count: count) ?? false
    }

    /// Host address of [gpa, gpa+count), which must lie inside one memslot.
    public func hostPointer(gpa: UInt64, count: Int) throws -> UnsafeMutableRawPointer {
        guard let slot = memorySlot(containing: gpa), slot.contains(gpa: gpa, count: count) else {
            throw KVMError("guest physical access", detail: "GPA 0x\(String(gpa, radix: 16)) + \(count) is outside every memslot")
        }
        return UnsafeMutableRawPointer(bitPattern: slot.hostAddress)! + Int(gpa - slot.gpa)
    }

    /// Cleans and invalidates [gpa, gpa+count) to the point of coherency, so
    /// a vCPU that reads it with its MMU off (non-cacheable) sees what the VMM
    /// wrote through its cacheable host mapping.
    public func cleanDataCache(gpa: UInt64, count: Int) throws {
        let pointer = try hostPointer(gpa: gpa, count: count)
        ckvm_clean_dcache_range(pointer, count)
    }

    private func pointer(gpa: UInt64, count: Int) throws -> UnsafeMutableRawPointer {
        try hostPointer(gpa: gpa, count: count)
    }

    public func read(gpa: UInt64, count: Int) throws -> [UInt8] {
        let source = try pointer(gpa: gpa, count: count)
        return [UInt8](UnsafeRawBufferPointer(start: source, count: count))
    }

    public func write(gpa: UInt64, bytes: [UInt8]) throws {
        let destination = try writableHostPointer(gpa: gpa, count: bytes.count)
        bytes.withUnsafeBytes { if !$0.isEmpty { destination.copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
    }

    public func readU64(gpa: UInt64) throws -> UInt64 {
        let source = try pointer(gpa: gpa, count: 8)
        return UInt64(littleEndian: source.loadUnaligned(as: UInt64.self))
    }

    public func writeU64(gpa: UInt64, _ value: UInt64) throws {
        let destination = try writableHostPointer(gpa: gpa, count: 8)
        destination.storeBytes(of: value.littleEndian, as: UInt64.self)
    }

    /// Zero-fills [gpa, gpa+count).
    public func zero(gpa: UInt64, count: Int) throws {
        let destination = try writableHostPointer(gpa: gpa, count: count)
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
    /// KVM_EXIT_HYPERCALL: an SMCCC call the VM's SMCCC filter forwards to
    /// user space (`function` = the function ID; `flags` bit 0 = SMC). The
    /// guest PC is already after the HVC/SMC (vm-shim-protocol.md §5.1).
    case hypercall(function: UInt64, flags: UInt64)
    /// `runOnce()` only: KVM_RUN returned -EINTR (a kick signal or
    /// `immediate_exit`).
    case interrupted
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
        case let .hypercall(function, flags): return "hypercall function \(hex(function)) flags \(hex(flags))"
        case .interrupted: return "interrupted"
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
    public static let cntfrqEL0 = SystemRegister(op0: 3, op1: 3, crn: 14, crm: 0, op2: 0)
    public static let cntkctlEL1 = SystemRegister(op0: 3, op1: 0, crn: 14, crm: 1, op2: 0)
    public static let idAA64MMFR2EL1 = SystemRegister(op0: 3, op1: 0, crn: 0, crm: 7, op2: 2)
}

/// One arm64 vCPU with its mapped `struct kvm_run`.
public final class VCPU: @unchecked Sendable {
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
        let began = monotonicNanoseconds()
        let fd = try kvmCheck(ckvm_create_vcpu(vm.vmFD, UInt(id)), "KVM_CREATE_VCPU")
        let created = monotonicNanoseconds()
        VCPUPool.deferredCreateVCPUNanoseconds.wrappingAdd(created &- began, ordering: .relaxed)
        if VCPUPool.profiling { VCPUPool.creationPhases[1].add(created &- began) }
        defer {
            let end = monotonicNanoseconds()
            VCPUPool.deferredInitNanoseconds.wrappingAdd(end &- created, ordering: .relaxed)
            if VCPUPool.profiling { VCPUPool.creationPhases[2].add(end &- created) }
        }
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

    /// Resets the vCPU to its initial state (`KVM_ARM_VCPU_INIT` with the
    /// features it was made with) for a reused VM. No thread may run it.
    func reset(vmFD: Int32) -> Bool {
        guard !closed else { return false }
        ckvm_run_set_immediate_exit(runArea, 0)
        guard ckvm_arm_vcpu_init_preferred(vmFD, fd, UInt32(1) << UInt32(CKVM_ARM_VCPU_FEATURE_PSCI_0_2)) == 0 else { return false }
        // Diagnostics count from here for the next image.
        exitCount = 0
        if VCPUPool.profiling {
            let names = ["exits", "wfe_exit_stat", "wfi_exit_stat"]
            statisticsBaseline = Dictionary(uniqueKeysWithValues: zip(names, rawStatistics(names)))
        }
        return true
    }
    /// KVM statistics at the last reset (subtracted by `kvmStatistics`).
    private var statisticsBaseline: [String: UInt64] = [:]

    /// Diagnostics: this vCPU's KVM binary statistics by name
    /// (KVM_GET_STATS_FD; 0 for a name the kernel does not have).
    public func kvmStatistics(_ names: [String]) -> [UInt64] {
        let raw = rawStatistics(names)
        return zip(names, raw).map { $1 &- (statisticsBaseline[$0] ?? 0) }
    }

    private func rawStatistics(_ names: [String]) -> [UInt64] {
        var out = [UInt64](repeating: 0, count: names.count)
        let copies = names.map { strdup($0) }
        defer { copies.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = copies.map { UnsafePointer($0) }
        _ = ckvm_vcpu_stats(fd, &pointers, Int32(names.count), &out)
        return out
    }

    func close() {
        guard !closed else { return }
        closed = true
        releaseHostMemory(runArea, runSize)
        _ = ckvm_close(fd)
    }

    // MARK: Registers

    public func get(_ register: CoreRegister) throws -> UInt64 { try getRaw(register.id, "\(register)") }
    public func set(_ register: CoreRegister, _ value: UInt64) throws { try setRaw(register.id, value, "\(register)") }
    public func get(_ register: SystemRegister) throws -> UInt64 { try getRaw(register.id, "sysreg") }
    public func set(_ register: SystemRegister, _ value: UInt64) throws { try setRaw(register.id, value, "sysreg") }

    /// Sets the guest's virtual counter (`KVM_REG_ARM_TIMER_CNT`): KVM
    /// adjusts the counter offset (VM-wide on current kernels), so every
    /// vCPU of the VM then reads `value` now. Used to give all VMs of one
    /// simulated system the same `mach_absolute_time` base.
    public func setVirtualCounter(_ value: UInt64) throws {
        try setRaw(ckvm_reg_timer_cnt(), value, "KVM_REG_ARM_TIMER_CNT")
    }

    private func getRaw(_ id: UInt64, _ name: String) throws -> UInt64 {
        var value: UInt64 = 0
        try kvmCheck(ckvm_get_one_reg_u64(fd, id, &value), "KVM_GET_ONE_REG \(name)")
        return value
    }

    private func setRaw(_ id: UInt64, _ value: UInt64, _ name: String) throws {
        try kvmCheck(ckvm_set_one_reg_u64(fd, id, value), "KVM_SET_ONE_REG \(name)")
    }

    // MARK: Generic timer

    /// The guest's virtual counter (`CNTVCT_EL0`), through ONE_REG
    /// (`KVM_REG_ARM_TIMER_CNT`).
    public func virtualCounter() throws -> UInt64 { try getRaw(ckvm_reg_timer_cnt(), "KVM_REG_ARM_TIMER_CNT") }

    /// host counter − guest counter, sampled now: the guest's `CNTVCT_EL0`
    /// equals `Hypervisor.hostCounter() &- offset` from any host thread,
    /// without an ioctl on a vCPU that may be running.
    public func counterOffset() throws -> UInt64 {
        let before = ckvm_host_cntvct()
        let guest = try virtualCounter()
        let after = ckvm_host_cntvct()
        return (before &+ (after &- before) / 2) &- guest
    }

    /// `CNTFRQ_EL0` as the guest sees it. Read through ONE_REG when KVM
    /// exposes it; otherwise the host's value, which the guest shares (KVM
    /// does not virtualize the counter frequency).
    public func counterFrequency() -> (hz: UInt64, source: String) {
        if let value = try? getRaw(SystemRegister.cntfrqEL0.id, "CNTFRQ_EL0"), value != 0 {
            return (value, "ONE_REG")
        }
        return (ckvm_host_cntfrq(), "host CNTFRQ_EL0")
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

    /// Runs the vCPU until it exits to user space or a signal interrupts the
    /// run (`.interrupted`). Pooled vCPUs use this: a kick (signal plus
    /// `immediate_exit`) must bring the host thread back.
    public func runOnce() throws -> VCPUExit {
        while true {
            let result = ckvm_run(fd)
            if result == -EINTR { return .interrupted }
            if result == -EAGAIN { continue }
            try kvmCheck(result, "KVM_RUN")
            exitCount += 1
            return decodeExit()
        }
    }

    /// Sets or clears `kvm_run.immediate_exit`: while set, KVM_RUN returns
    /// -EINTR without entering the guest. Any host thread may set it.
    public func setImmediateExit(_ on: Bool) { ckvm_run_set_immediate_exit(runArea, on ? 1 : 0) }

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
            let word = UInt64(littleEndian: ckvm_run_mmio_data_u64(runArea))
            let data = length >= 8 ? word : word & ((UInt64(1) << (8 * UInt64(max(length, 0)))) - 1)
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
        case Int(CKVM_EXIT_HYPERCALL):
            return .hypercall(function: ckvm_run_hypercall_nr(runArea), flags: ckvm_run_hypercall_flags(runArea))
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
