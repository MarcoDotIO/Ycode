// ycode-simd: the two speed switches of specs/simulator/fast-traps.md and
// specs/simulator/vm-shim-protocol.md §5.1. Both are on by default ("0"
// turns one off).
//
// - YCODE_HVC_DOORBELL: the shim rings the VMM with a forwarded HVC
//   (KVM_EXIT_HYPERCALL) instead of the MMIO store.
// - YCODE_FAST_TRAPS: every VM gets the system's counter offset VM-wide
//   (KVM_ARM_SET_COUNTER_OFFSET), and the commpage tells the host library to
//   answer mach time, the wall clock and the credential calls at EL0.

#if os(Linux) && arch(arm64)
import CKVM
import Foundation
import Synchronization
import YcodeDarwinABI
import YcodeDarwinKernel
import YcodeHypervisor

enum FastTraps {
    /// On unless the variable is "0" (both switches default on since
    /// 2026-10-17, fast-traps.md §8).
    private static func flag(_ name: String) -> Bool {
        getenv(name).map { String(cString: $0) != "0" } ?? true
    }

    /// `YCODE_HVC_DOORBELL` (vm-shim-protocol.md §5.1; 0 = MMIO doorbell).
    static let hvcDoorbell = flag("YCODE_HVC_DOORBELL")
    /// `YCODE_FAST_TRAPS` (fast-traps.md; 0 = every call traps).
    static let enabled = flag("YCODE_FAST_TRAPS")
    /// `YCODE_LOCAL_CALLS` (fast-traps.md §5a, with `YCODE_FAST_TRAPS`;
    /// 0 = madvise and issetugid always trap).
    static let localCalls = flag("YCODE_LOCAL_CALLS")
    /// `YCODE_SYSCTL_CACHE` (fast-traps.md §5a, with `YCODE_FAST_TRAPS`;
    /// 0 = every sysctl traps).
    static let sysctlCache = flag("YCODE_SYSCTL_CACHE")

    /// The doorbell address for a new VM's boot info: 0 (the HVC form) when
    /// the switch is on and the host installs the SMCCC filter, otherwise the
    /// MMIO doorbell. Call before any vCPU of `vm` runs.
    static func doorbellAddress(for vm: VirtualMachine, log: (String) -> Void) -> UInt64 {
        guard hvcDoorbell else { return VMLayout.doorbellGPA }
        do {
            try vm.installHVCDoorbell()
            if !announcedHVC.exchange(true, ordering: .relaxed) {
                stderrLine("ycode-simd: HVC doorbell on (SMCCC function 0xC6005943 forwarded to user space)")
            }
            return 0
        } catch {
            warnOnce("HVC doorbell unavailable, using the MMIO doorbell: \(error)", log: log)
            return VMLayout.doorbellGPA
        }
    }

    /// Writes the fast-path parts of a new image's commpage (§2, §4, §5):
    /// the flag byte, the first wall-clock snapshot and the credential
    /// block, and returns the kernel's snapshot publisher (nil when the
    /// in-place clock is off).
    static func configureCommpage(space: GuestAddressSpace, vm: VirtualMachine, directClock: Bool,
                                  counter: @escaping () -> UInt64, frequency: UInt64,
                                  clockScale: GuestTimebase.ClockScale,
                                  wallClock: () -> (seconds: Int64, nanoseconds: Int64))
        throws -> ((UInt64, Int64, Int64) -> Void)? {
        guard enabled else { return nil }
        guard let pa = space.pageTables.translate(VMLayout.commpageVA)?.pa else { return nil }
        let page = try vm.hostPointer(gpa: pa, count: Int(VMLayout.pageSize))
        var flags = CommpageBuilder.FastFlag.credentialBlock
        if localCalls { flags |= CommpageBuilder.FastFlag.localCalls }
        if sysctlCache { flags |= CommpageBuilder.FastFlag.sysctlCache }
        let creds = page + CommpageBuilder.Offset.credentials
        for (i, v) in [DarwinFileSystem.guestUID, DarwinFileSystem.guestUID,
                       DarwinFileSystem.guestGID, DarwinFileSystem.guestGID].enumerated() {
            creds.storeBytes(of: v.littleEndian, toByteOffset: 4 * i, as: UInt32.self)
        }
        var publisher: ((UInt64, Int64, Int64) -> Void)?
        if directClock {
            // §3.2: the scale before the flag that tells the library to use it.
            page.storeBytes(of: clockScale.multiplier.littleEndian, toByteOffset: CommpageBuilder.Offset.clockMultiplier,
                            as: UInt64.self)
            page.storeBytes(of: clockScale.shift.littleEndian, toByteOffset: CommpageBuilder.Offset.clockShift, as: UInt64.self)
            flags |= CommpageBuilder.FastFlag.directClock
            let block = page + CommpageBuilder.Offset.newTimeOfDay
            let publish: (UInt64, Int64, Int64) -> Void = { tick, seconds, nanoseconds in
                let t = CommpageBuilder.TimeOfDaySnapshot(tick: tick, seconds: seconds, nanoseconds: nanoseconds,
                                                          frequency: frequency)
                ckvm_publish_timeofday(block, t.tick, t.seconds, t.fraction, t.scale, t.ticksPerSecond)
            }
            let tick = counter()
            let (s, ns) = wallClock()
            publish(tick, s, ns)
            publisher = publish
        }
        page.storeBytes(of: flags, toByteOffset: CommpageBuilder.Offset.fastFlags, as: UInt8.self)
        return publisher
    }

    private static let announcedHVC = Atomic<Bool>(false)
    private static let warned = Atomic<Bool>(false)
    private static func warnOnce(_ text: String, log: (String) -> Void) {
        if !warned.exchange(true, ordering: .relaxed) { stderrLine("ycode-simd: \(text)") } else { log(text) }
    }
}
#endif
