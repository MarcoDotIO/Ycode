import Foundation
import YcodeDarwinABI

// thread_info (Ycode private routine 0x30; specs/simulator/app-launch.md
// §3.4). Flavors and layouts from the public mach/thread_info.h (level 1):
// THREAD_BASIC_INFO 3 (10 words), THREAD_IDENTIFIER_INFO 4 (6 words),
// THREAD_EXTENDED_INFO 5 (28 words), THREAD_SCHED_TIMESHARE_INFO 10
// (5 words). PlugInKit, CoreAudio and DialogEngine ask for them; before,
// the call failed with KERN_NOT_SUPPORTED.
//
// Ycode keeps no per-thread scheduler accounting: the CPU time is known for
// the calling thread only (its host thread's time, as thread_selfusage);
// another thread reports 0. Priorities are the default user ones (31,
// maximum 63), the policy POLICY_TIMESHARE, the run state STOPPED
// (suspended), WAITING (blocked in the kernel) or RUNNING, and the thread's
// own suspend count (`thread_suspend`).

extension DarwinKernel {
    static let threadInfoBasic: UInt32 = 3
    static let threadInfoIdentifier: UInt32 = 4
    static let threadInfoExtended: UInt32 = 5
    static let threadInfoSchedTimeshare: UInt32 = 10

    /// The words of `flavor` for `thread`; nil for an unknown flavor.
    /// `selfCPUNanoseconds`: the thread's CPU time when it is the caller.
    static func threadInfoWords(_ thread: ThreadContext, flavor: UInt32, selfCPUNanoseconds: UInt64?) -> [UInt8]? {
        let cpu = selfCPUNanoseconds ?? 0
        // TH_STATE_STOPPED (suspended, threads-and-events.md §1.6) / WAITING / RUNNING.
        let runState: Int32 = thread.gate.isClosed ? 2 : thread.blockedInKernel ? 3 : 1
        var out: [UInt8] = []
        switch flavor {
        case threadInfoBasic:
            out.appendLE(Int32(truncatingIfNeeded: cpu / 1_000_000_000))          // user_time.seconds
            out.appendLE(Int32(truncatingIfNeeded: (cpu % 1_000_000_000) / 1000)) // user_time.microseconds
            out.appendLE(Int32(0)); out.appendLE(Int32(0))                       // system_time
            out.appendLE(Int32(0))                                                // cpu_usage
            out.appendLE(Int32(1))                                                // policy: POLICY_TIMESHARE
            out.appendLE(runState)
            out.appendLE(Int32(0))                                                // flags
            out.appendLE(Int32(truncatingIfNeeded: thread.suspendCount))          // suspend_count
            out.appendLE(Int32(0))                                                // sleep_time
        case threadInfoIdentifier:
            out.appendLE(thread.threadID)
            out.appendLE(thread.pthreadAddress)
            // The libdispatch queue slot of the thread's TSD (the TSD starts
            // 224 bytes into the pthread; key __PTK_LIBDISPATCH_KEY0 = 20).
            out.appendLE(thread.pthreadAddress == 0 ? UInt64(0) : thread.pthreadAddress + 224 + 20 * 8)
        case threadInfoExtended:
            out.appendLE(cpu)                                                     // pth_user_time (ns)
            out.appendLE(UInt64(0))                                               // pth_system_time
            out.appendLE(Int32(0))                                                // pth_cpu_usage
            out.appendLE(Int32(1))                                                // pth_policy
            out.appendLE(runState)
            out.appendLE(Int32(0))                                                // pth_flags
            out.appendLE(Int32(0))                                                // pth_sleep_time
            out.appendLE(Int32(31)); out.appendLE(Int32(31)); out.appendLE(Int32(63))  // cur, base, max priority
            out += [UInt8](repeating: 0, count: 64)                               // pth_name
        case threadInfoSchedTimeshare:
            for v: Int32 in [63, 31, 31, 0, 0] { out.appendLE(v) }  // max, base, cur priority, depressed, depress priority
        default:
            return nil
        }
        return out
    }

    /// thread_info(thread, flavor, info, &count) for a thread of the
    /// caller's task: KERN_INVALID_ARGUMENT for another port or an unknown
    /// flavor, MIG_ARRAY_TOO_SMALL (-307) when `count` is too small.
    func threadInfo(_ a: [UInt64], ipc: MachIPC, memory: any GuestVirtualMemory, caller: ThreadContext) -> (UInt32, String) {
        let name = UInt32(truncatingIfNeeded: a[0]), flavor = UInt32(truncatingIfNeeded: a[1])
        guard let (port, object) = ipc.kernelObject(named: name), case .thread = object,
              let thread = threadsByPort.values.first(where: { ipc.kernelObject(named: $0.portName)?.0 === port }),
              thread.isAlive else {
            return (MachKern.invalidArgument, " [not a thread of this task]")
        }
        let selfCPU: UInt64? = thread === caller
            ? { let now = Self.hostThreadCPUNanoseconds(); return now >= caller.hostCPUBaseNanoseconds ? now - caller.hostCPUBaseNanoseconds : now }()
            : nil
        guard let words = Self.threadInfoWords(thread, flavor: flavor, selfCPUNanoseconds: selfCPU) else {
            return (MachKern.invalidArgument, " [flavor \(flavor)]")
        }
        guard let capacityBytes = try? memory.read(va: a[3], count: 4) else { return (MachKern.invalidAddress, "") }
        let needed = UInt32(words.count / 4)
        guard capacityBytes.readLE(UInt32.self, at: 0) >= needed else { return (UInt32(bitPattern: -307), " [count]") }
        guard (try? memory.write(va: a[2], bytes: words)) != nil,
              (try? memory.write(va: a[3], bytes: le32(needed))) != nil else { return (MachKern.invalidAddress, "") }
        return (MachKern.success, " [thread \(thread.threadID) flavor \(flavor)]")
    }
}
