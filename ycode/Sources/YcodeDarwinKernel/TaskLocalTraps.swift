import Foundation
import Synchronization
import YcodeDarwinABI

// Task-local traps (`specs/simulator/boot-profile.md` §3.6, C20): a few
// frequent traps that touch only the calling process's own address space
// and the host file system run without the global kernel lock.
//
// Why: every trap waited about 0.5 ms for the kernel lock in a boot (the
// lock is about 45 % busy, and its holds have long tails), and a process
// start makes about 3,800 traps before its libSystem initializer runs,
// almost all of them `stat64` (one per library path the loader probes on
// disk), `vm_allocate` and `vm_deallocate` (a scratch buffer per library):
// about 2 s of lock waits per process start, on the boot's critical path.
//
// Which traps, and what they touch:
//
// | Trap | State used |
// |---|---|
// | BSD 338 `stat64`, 340 `lstat64` | the path string and the result buffer in guest memory; `DarwinFileSystem` path resolution and the host `stat`, which already run without the kernel lock (stage 6 §5.1) |
// | Mach −10 `vm_allocate` with `VM_FLAGS_ANYWHERE` | the address space (one change, under its own mutex L1) and guest memory (the address in/out word) |
// | Mach −12 `vm_deallocate` | the address space (one change) |
// | Mach −14 `vm_protect` (current protection) | the address space (one change; making a shared read-only file view writable moves it to a private view, under L1) |
// | BSD 75 `madvise` (C21, `YCODE_TASK_LOCAL_MADVISE`) | the arguments; for `MADV_ZERO` guest memory writes (single L1 sections). Every other advice is a hint Ycode keeps no state for |
// | BSD 73 `munmap`, 74 `mprotect` (`bsd-locking.md` §12) | the address space (one change), as `vm_deallocate` and `vm_protect` |
// | Mach −3 `mach_absolute_time`, −4 `mach_continuous_time` | the guest counter |
// | Mach −43 `mach_generate_activity_id` | the image's activity-id counter (an atomic) |
// | Ycode's `vm_copy` (0x7963_0004) | one read and one write of guest memory |
// | Mach −15 `mach_vm_map` (anonymous memory) | the address space, as `vm_allocate` (a fixed placement checks and maps as one change) |
//
// Every address-space change takes the space's mutex (L1); every kernel
// path that reads the address space and then changes it on the result
// (`vm_allocate`/`mach_vm_map` at a fixed address without overwrite)
// holds L1 across both steps (`GuestVirtualMemory.atomically`). The guest
// memory reads and writes are single L1 sections, as before. Nothing here
// reads or writes state the kernel lock guards (descriptor tables, ports,
// threads, wait queues), and nothing blocks. Lock order is unchanged
// (L0 → L1 → leaves); these traps take no L0.
//
// The traps fall back to the locked path when tracing (the trace text is
// built under the lock), when the image is ending, or when the thread is
// not yet bound to this image.

extension DarwinKernel {
    /// On by default; `YCODE_TASK_LOCAL_TRAPS=0` turns the task-local traps off.
    nonisolated(unsafe) public static var taskLocalTrapsEnabled = getenv("YCODE_TASK_LOCAL_TRAPS").map { String(cString: $0) != "0" } ?? true

    /// On by default; `YCODE_TASK_LOCAL_MADVISE=0` sends `madvise` back to
    /// the locked path (boot-profile.md §6.4, C21).
    nonisolated(unsafe) public static var taskLocalMadviseEnabled = getenv("YCODE_TASK_LOCAL_MADVISE").map { String(cString: $0) != "0" } ?? true

    /// On by default; `YCODE_TASK_LOCAL_MORE=0` sends `munmap`, `mprotect`,
    /// `mach_absolute_time` and `mach_continuous_time` back to the locked
    /// path (`bsd-locking.md` §12).
    nonisolated(unsafe) public static var taskLocalMoreEnabled = getenv("YCODE_TASK_LOCAL_MORE").map { String(cString: $0) != "0" } ?? true

    /// True when the trap was issued by a helper stub of the host page
    /// (`dyld-sim-handoff.md` §7.3: the loader's `stat`): such a `stat`
    /// sees no cache-only image files (app-launch.md §3.5), so the loader
    /// never takes one for a file that overrides the cache.
    @inline(__always) static func isLoaderHelper(pc: UInt64) -> Bool {
        pc >= VMLayout.hostPageVA && pc < VMLayout.hostPageVA + VMLayout.hostPageCodeSize
    }

    /// True for a trap number (`x16` as Int32) that `handleTaskLocal` may serve.
    public static func isTaskLocalTrap(_ number: Int32) -> Bool {
        switch number {
        case 338, 340, -10, -12, -14, -11: return true
        case 75: return taskLocalMadviseEnabled
        case 73, 74, -3, -4, -15, -43, Int32(bitPattern: Private.vmCopy): return taskLocalMoreEnabled
        default: return false
        }
    }

    /// Handles a task-local trap without the kernel lock, or returns nil
    /// when the caller must take the locked path. Call from the trapping
    /// thread's vCPU host thread, without the kernel lock.
    public func handleTaskLocal(_ frame: inout TrapFrame, context: ThreadContext, memory: any KernelGuestMemory) -> Outcome? {
        guard Self.taskLocalTrapsEnabled, !tracing, frame.trapKind == .svc, frame.x.count >= TrapFrame.registerCount,
              context.kernel === self, !isTerminating else { return nil }
        let number = Int32(truncatingIfNeeded: frame.x[16])
        let a = frame.x.prefixArray(8)
        let generation = memory.tlbGeneration
        defer { if memory.tlbGeneration != generation { frame.requestTLBInvalidation(memory.tlbRange(since: generation)) } }
        switch number {
        case 338, 340:
            do {
                let path = try readPath(a[0], memory)
                let st = try fileSystem.stat(path, followSymlinks: number == 338,
                                             cacheImages: !Self.isLoaderHelper(pc: frame.elr))
                try memory.write(va: a[1], bytes: st.encodedStat64())
                frame.x[0] = 0
                frame.x[1] = 0
                frame.carry = false
            } catch {
                frame.x[0] = UInt64(UInt32(bitPattern: errno(of: error, default: Errno.EINVAL)))
                frame.x[1] = 0
                frame.carry = true
            }
            return .resume

        case -10:
            // vm_allocate(target, *addr, size, flags): anywhere only (a fixed
            // address checks and maps under the lock).
            guard a[3] & Self.vmFlagsAnywhere != 0 else { return nil }
            frame.x[0] = vmAllocateAnywhere(a, memory)
            return .resume

        case -12:
            // vm_deallocate(target, addr, size)
            if a[2] != 0 {
                let start = a[1] & ~Self.pageMask
                let size = roundUp(a[2] + (a[1] - start), to: Self.pageSize)
                do { try memory.unmap(va: start, size: size) } catch {
                    frame.x[0] = KernReturn.invalidArgument
                    return .resume
                }
            }
            frame.x[0] = KernReturn.success
            return .resume

        case -14:
            // vm_protect(target, addr, size, set_maximum, prot): the current
            // protection only (the maximum is not tracked; the locked path
            // answers that case).
            guard a[3] & 0xFFFF_FFFF == 0 else { return nil }
            if a[2] != 0 {
                let start = a[1] & ~Self.pageMask
                let size = roundUp(a[2] + (a[1] - start), to: Self.pageSize)
                let bits = a[4] & ~Self.vmProtCopy & 7
                do {
                    try memory.protect(va: start, size: size,
                                       protection: VMProtection(rawValue: VMProtection.RawValue(truncatingIfNeeded: bits)))
                } catch {
                    frame.x[0] = KernReturn.invalidAddress
                    return .resume
                }
            }
            frame.x[0] = KernReturn.success
            return .resume

        case Int32(bitPattern: Private.vmCopy):
            // Ycode's vm_copy(target, src, size, dst): one read and one write
            // of the caller's memory (handlePrivate), each an L1 section.
            guard a[2] <= UInt64(Int32.max) else {
                frame.x[0] = KernReturn.invalidArgument
                frame.carry = false
                return .resume
            }
            if let bytes = try? memory.read(va: a[1], count: Int(a[2])), (try? memory.write(va: a[3], bytes: bytes)) != nil {
                frame.x[0] = KernReturn.success
            } else {
                frame.x[0] = KernReturn.invalidAddress
            }
            frame.carry = false
            return .resume

        case -15:
            // mach_vm_map of anonymous memory (handleMach): address-space changes only.
            frame.x[0] = vmMapAnonymous(a, memory).0
            return .resume

        case -43:
            // mach_generate_activity_id: one atomic add (handleMach).
            frame.x[0] = generateActivityID(a, memory) != nil ? KernReturn.success : KernReturn.invalidAddress
            return .resume

        case -3, -4:
            // mach_absolute_time, mach_continuous_time (handleMach): the counter.
            frame.x[0] = counter()
            return .resume

        case 73, 74:
            // munmap, mprotect: the locked path's answers (DarwinKernel
            // `BSD.munmap`, `BSD.mprotect`): one address-space change.
            var failure: Int32 = 0
            do {
                if number == 73 {
                    if a[0] & Self.pageMask != 0 || a[1] == 0 { throw Failure(errno: Errno.EINVAL) }
                    try memory.unmap(va: a[0], size: roundUp(a[1], to: Self.pageSize))
                } else {
                    let start = a[0] & ~Self.pageMask
                    let size = roundUp(a[1] + (a[0] - start), to: Self.pageSize)
                    if size > 0 {
                        try memory.protect(va: start, size: size,
                                           protection: VMProtection(rawValue: VMProtection.RawValue(truncatingIfNeeded: a[2] & 7)))
                    }
                }
            } catch {
                failure = errno(of: error, default: Errno.EINVAL)
            }
            frame.x[0] = failure == 0 ? 0 : UInt64(UInt32(bitPattern: failure))
            frame.x[1] = 0
            frame.carry = failure != 0
            return .resume

        case -11:
            // vm_purgable_control: the image's purgeable-state table has
            // its own leaf lock (bsd-locking.md §6).
            frame.x[0] = purgeableControl(a, memory)
            return .resume

        case 75:
            // madvise(addr, len, advice), also posix_madvise: the locked
            // path's answers (DarwinKernel `BSD.madvise`). Advice 0…11 is
            // accepted; only MADV_ZERO (11) changes memory (the range reads
            // as zeros); anything else is EINVAL.
            guard Self.taskLocalMadviseEnabled else { return nil }
            let advice = Int32(truncatingIfNeeded: a[2])
            var failure: Int32 = 0
            if !(0...11).contains(advice) {
                failure = Errno.EINVAL
            } else if advice == 11, a[1] > 0 {
                let end = a[0].addingReportingOverflow(a[1])
                if end.overflow {
                    failure = Errno.EINVAL
                } else {
                    let zeros = [UInt8](repeating: 0, count: Int(min(a[1], 1 << 20)))
                    var at = a[0]
                    while at < end.partialValue {
                        let n = Int(min(UInt64(zeros.count), end.partialValue - at))
                        do { try memory.write(va: at, bytes: n == zeros.count ? zeros : Array(zeros[0..<n])) } catch {
                            failure = Errno.ENOMEM
                            break
                        }
                        at += UInt64(n)
                    }
                }
            }
            frame.x[0] = failure == 0 ? 0 : UInt64(UInt32(bitPattern: failure))
            frame.x[1] = 0
            frame.carry = failure != 0
            return .resume

        default:
            return nil
        }
    }

    /// `vm_purgable_control(target, addr, control, state*)` (xnu
    /// osfmk/mach/vm_purgable.h): control 0 SET_STATE (in: new state, out:
    /// old), 1 GET_STATE, 2 PURGE_ALL. Ycode memory is never purged, so a
    /// volatile region keeps its contents and reports VOLATILE, never EMPTY
    /// (2). The state change is one section of the table's leaf lock; the
    /// guest memory is read before and written after it. The kern_return_t.
    func purgeableControl(_ a: [UInt64], _ mem: any KernelGuestMemory) -> UInt64 {
        let control = Int32(truncatingIfNeeded: a[2])
        let page = a[1] & ~Self.pageMask
        switch control {
        case 0, 1:
            guard let raw = try? mem.read(va: a[3], count: 4) else { return KernReturn.invalidAddress }
            let state = raw.readLE(Int32.self, at: 0) & 0x3
            if control == 0, state == 2 { return KernReturn.invalidArgument }  // EMPTY may not be set
            let old: Int32 = purgeableStore.withLock { table in
                let old = table[page] ?? 0
                if control == 0 { table[page] = state == 0 ? nil : state }
                return old
            }
            var out: [UInt8] = []
            out.appendLE(old)
            guard (try? mem.write(va: a[3], bytes: out)) != nil else { return KernReturn.invalidAddress }
            return KernReturn.success
        case 2:
            return KernReturn.success
        default:
            return KernReturn.invalidArgument
        }
    }

    /// `vm_allocate` with `VM_FLAGS_ANYWHERE` (the locked path's answer):
    /// the kern_return_t.
    func vmAllocateAnywhere(_ a: [UInt64], _ mem: any KernelGuestMemory) -> UInt64 {
        guard let requested = try? readU64(a[1], mem) else { return KernReturn.invalidAddress }
        if a[2] == 0 {
            guard (try? writeU64(a[1], 0, mem)) != nil else { return KernReturn.invalidAddress }
            return KernReturn.success
        }
        let size = roundUp(a[2], to: Self.pageSize)
        guard let va = try? mem.mapAnonymous(at: nil, size: size, protection: [.read, .write],
                                             hint: requested == 0 ? nil : requested & ~Self.pageMask) else {
            return KernReturn.noSpace
        }
        guard (try? writeU64(a[1], va, mem)) != nil else { return KernReturn.invalidAddress }
        return KernReturn.success
    }
}
