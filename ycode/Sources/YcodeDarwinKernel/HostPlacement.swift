import Foundation
import Synchronization
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// Two additions to the host side of the scheduling policy
// (`specs/simulator/scheduling-policy.md` §4.7, `boot-profile.md` §12):
//
// - The host class after fast traps (`YCODE_FAST_TRAP_HOST_CLASS`). The
//   host class (a thread's class raised to its image's send push) is
//   applied at the end of a trap on the locked path. A thread that lives
//   on the fast paths (Mach messages, kevent and workqueue calls, the BSD
//   descriptor calls, the task-local traps) keeps the host priority of its
//   last locked trap: diagnosticd's workloop threads were not raised by the
//   senders that blocked on its queue. Applying the full class there too
//   (`=1`) made 3× the cgroup moves at 1.8 ms each (§12), so the default
//   is off; `=push` raises a thread only to its image's send push.
// - Host CPUs kept for the UI path (`YCODE_HOST_SCHED_UI_CPUS=N`): the host
//   threads of the UI-path programs (`YCODE_HOST_SCHED_UI_PROGRAMS`,
//   default SpringBoard and backboardd) run on every host CPU; every other
//   guest thread's host thread runs on all but the last N. The UI path then
//   finds idle CPUs while the other daemons of a boot saturate the rest.

extension HostSched {
    /// What a fast trap's end applies (`YCODE_FAST_TRAP_HOST_CLASS`).
    public enum FastTrapClass: Sendable { case off, push, full }

    /// `YCODE_FAST_TRAP_HOST_CLASS`: `0` or unset (default) nothing; `push`
    /// a raise to the image's send push when it is above the thread's
    /// applied class (lowering stays with the locked path); `1` the whole
    /// host class, as at the end of a locked trap.
    nonisolated(unsafe) public static var fastTrapClass: FastTrapClass = {
        switch getenv("YCODE_FAST_TRAP_HOST_CLASS").map({ String(cString: $0) }) {
        case "1": .full
        case "push": .push
        default: .off
        }
    }()

    /// The class step after a fast trap: off unless a backend (or a test
    /// hook) is on and the switch asks for it.
    @inline(__always) static func applyAfterFastTrap(threadClass: Int, push: Int) {
        guard fastTrapClass != .off, backend != .none || moveHook != nil else { return }
        switch fastTrapClass {
        case .full:
            apply(max(threadClass, push))
        case .push:
            if push > threadClass, push > appliedClass() { apply(push) }
        case .off:
            break
        }
    }

    /// The programs (executable names) of the UI path.
    public static let uiPathPrograms: Set<String> = {
        guard let v = getenv("YCODE_HOST_SCHED_UI_PROGRAMS").map({ String(cString: $0) }) else {
            return ["SpringBoard", "backboardd"]
        }
        return Set(v.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }()

    /// `YCODE_HOST_SCHED_UI_CPUS=N` (0 or unset: off): CPU masks for the
    /// other threads (all online CPUs but the last N) and for the UI path
    /// (every online CPU). Words of 64 bits for `sched_setaffinity`.
    nonisolated(unsafe) static var uiCPUMasks: (others: [UInt64], all: [UInt64])? = {
        #if os(Linux)
        guard let n = getenv("YCODE_HOST_SCHED_UI_CPUS").flatMap({ Int(String(cString: $0)) }), n > 0 else { return nil }
        return cpuMasks(reserving: n, online: Int(sysconf(Int32(_SC_NPROCESSORS_ONLN))))
        #else
        return nil
        #endif
    }()

    /// Masks that keep the last `n` of `online` CPUs for the UI path; nil
    /// when fewer than two CPUs would be left for the others.
    static func cpuMasks(reserving n: Int, online: Int) -> (others: [UInt64], all: [UInt64])? {
        guard n > 0, online - n >= 2 else { return nil }
        let words = (online + 63) / 64
        var others = [UInt64](repeating: 0, count: words), all = others
        for cpu in 0..<online {
            all[cpu / 64] |= 1 << UInt64(cpu % 64)
            if cpu < online - n { others[cpu / 64] |= 1 << UInt64(cpu % 64) }
        }
        return (others, all)
    }

    /// `YCODE_HOST_SCHED_UI_PUSHED=<class>` (with the reservation; unset:
    /// off): an image whose send push is at least this class (senders of
    /// that class blocked on a full queue of one of its ports, §4.6) also
    /// runs on the UI path's CPUs while the push lasts. 2 (df) by default
    /// when set to anything that is not a class number.
    nonisolated(unsafe) static var pushedUIMinClass: Int? = {
        guard let v = getenv("YCODE_HOST_SCHED_UI_PUSHED").map({ String(cString: $0) }), v != "0", !v.isEmpty else { return nil }
        return Int(v).map { max(1, min(SchedClass.count - 1, $0)) } ?? SchedClass.default
    }()

    /// Tests: replaces the affinity call (true: the UI path's mask).
    nonisolated(unsafe) static var placeHook: ((Bool) -> Void)?

    /// The placement the calling host thread has (0 none, 1 UI path, 2 others).
    static let placeKey: pthread_key_t = {
        var k = pthread_key_t()
        pthread_key_create(&k, nil)
        return k
    }()
    static let placements = Atomic<Int>(0)
    static let placementNanoseconds = Atomic<UInt64>(0)

    /// Gives the calling host thread the CPUs of its program's side (UI
    /// path or not), when the reservation is on. Cheap when nothing changes
    /// (one thread-specific read). A host thread runs the guest threads of
    /// several images in turn (VM reuse), so this is checked at trap ends.
    @inline(__always)
    public static func place(uiPath: Bool) {
        guard uiCPUMasks != nil || placeHook != nil else { return }
        let want = uiPath ? 1 : 2
        guard Int(bitPattern: pthread_getspecific(placeKey)) != want else { return }
        pthread_setspecific(placeKey, UnsafeRawPointer(bitPattern: want))
        placements.wrappingAdd(1, ordering: .relaxed)
        if let placeHook { placeHook(uiPath); return }
        guard let masks = uiCPUMasks else { return }
        let start = KernelClock.now()
        _ = setAffinity(0, uiPath ? masks.all : masks.others)   // 0: the calling thread
        placementNanoseconds.wrappingAdd(KernelClock.now() &- start, ordering: .relaxed)
    }

    /// The reservation's part of the end-of-run report ("" when off).
    static var placementReport: String {
        guard let masks = uiCPUMasks else { return "" }
        let others = masks.others.reduce(0) { $0 + $1.nonzeroBitCount }, all = masks.all.reduce(0) { $0 + $1.nonzeroBitCount }
        return "; UI path (\(uiPathPrograms.sorted().joined(separator: ","))"
            + (pushedUIMinClass.map { ", images pushed at class \($0)+" } ?? "") + ") on \(all) CPUs, others on \(others); "
            + "\(placements.load(ordering: .relaxed)) placements, \(placementNanoseconds.load(ordering: .relaxed) / 1_000_000) ms"
    }
}

extension DarwinKernel {
    /// The host side of the policy at the end of a trap: the host class
    /// (the thread's class raised to the image's send push) and the
    /// UI-path placement. Outside every kernel lock.
    @inline(__always)
    func applyHostPolicy(_ context: ThreadContext) {
        let push = sendPushClass
        if HostSched.backend != .none { HostSched.apply(max(context.schedClass, push)) }
        HostSched.place(uiPath: onUIPath(push: push))
    }

    /// The image runs on the UI path's CPUs: a UI-path program, or (with
    /// `YCODE_HOST_SCHED_UI_PUSHED`) pushed by blocked senders of that class.
    @inline(__always)
    func onUIPath(push: Int) -> Bool {
        if hostUIPath { return true }
        guard let min = HostSched.pushedUIMinClass else { return false }
        return push >= min
    }

    /// The same after a fast trap (IPC, BSD descriptor or task-local): the
    /// placement always, the class as `YCODE_FAST_TRAP_HOST_CLASS` says
    /// (`boot-profile.md` §12).
    @inline(__always)
    public func applyHostPolicyAfterFastTrap(_ context: ThreadContext) {
        guard HostSched.fastTrapClass != .off || HostSched.uiCPUMasks != nil || HostSched.placeHook != nil else { return }
        let push = sendPushClass
        HostSched.applyAfterFastTrap(threadClass: context.schedClass, push: push)
        HostSched.place(uiPath: onUIPath(push: push))
    }
}
