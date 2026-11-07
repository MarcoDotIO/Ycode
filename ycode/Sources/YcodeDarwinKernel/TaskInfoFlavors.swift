import Foundation
import YcodeDarwinABI

// task_info's CPU-time flavors (`boot-profile.md` §16). Before, the private
// task_info trap answered only TASK_DYLD_INFO and TASK_AUDIT_TOKEN, and
// every other flavor was KERN_INVALID_ARGUMENT; SpringBoard's FrontBoard
// asks for the CPU time of the processes it watches and logged
// "elapsedCPUTimeForFrontBoard task_info failed with 0x4" each time.
//
// Layouts from xnu's public `osfmk/mach/task_info.h` (level 1): structures
// packed to 4 bytes, `time_value_t` is { integer_t seconds, microseconds },
// absolute times in mach_absolute_time units, counts in natural_t words.
// The times are the target process's host CPU (its host threads: guest code
// and the kernel work done for it, as getrusage reports); live and ended
// threads are not told apart (threads_* = total_*). Counters Ycode does not
// keep (wake-ups, page-ins, sizes) are zero.

extension DarwinKernel {
    enum TaskInfoFlavor {
        static let absoluteTime: UInt32 = 1        // TASK_ABSOLUTETIME_INFO, 8 words
        static let eventsInfo: UInt32 = 2          // TASK_EVENTS_INFO, 8 words
        static let threadTimes: UInt32 = 3         // TASK_THREAD_TIMES_INFO, 4 words
        static let basic64: UInt32 = 5             // TASK_BASIC_INFO_64, 10 words
        static let basic64v2: UInt32 = 18          // TASK_BASIC_INFO_64_2, 10 words
        static let machBasic: UInt32 = 20          // MACH_TASK_BASIC_INFO, 12 words
        static let power: UInt32 = 21              // TASK_POWER_INFO, 12 words
        static let powerV2: UInt32 = 26            // TASK_POWER_INFO_V2, 24 words (26 with task_energy)
    }

    /// The task a task_info call names: this task, or another live task by
    /// any of its flavor ports (task_info takes a task_name_t). nil: not a
    /// task port, or the task ended.
    func taskInfoTarget(_ name: UInt32) -> DarwinKernel? {
        if name == WellKnownPort.task { return self }
        guard let ipc = machIPC as? MachIPC, let (port, object) = withPorts({ ipc.kernelObject(named: name) }) else { return nil }
        switch object {
        case .task, .taskName, .taskRead, .taskInspect: break
        default: return nil
        }
        guard port.active, let task = port.task, !task.isTerminated, let k = task.kernel, !k.isTerminating else { return nil }
        return k
    }

    enum TaskInfoReply: Equatable {
        /// Not a flavor handled here.
        case unsupported
        /// The caller's count is below the flavor's (KERN_INVALID_ARGUMENT).
        case tooSmall
        /// The structure and its size in natural_t words.
        case reply([UInt8], words: UInt32)
    }

    /// The reply of a CPU-time flavor with room for `count` words, from the
    /// target's CPU times (ns) and the guest counter's frequency.
    static func taskInfoTimes(flavor: UInt32, count: UInt32, user: UInt64, system: UInt64,
                              frequency: UInt64) -> TaskInfoReply {
        func ticks(_ ns: UInt64) -> UInt64 {
            let f = frequency == 0 ? 1_000_000_000 : frequency
            return UInt64((Double(ns) * Double(f) / 1e9).rounded(.down))
        }
        func timeValue(_ ns: UInt64, into b: inout [UInt8]) {
            b.appendLE(Int32(truncatingIfNeeded: ns / 1_000_000_000))
            b.appendLE(Int32(truncatingIfNeeded: ns / 1000 % 1_000_000))
        }
        var b: [UInt8] = []
        let words: UInt32
        switch flavor {
        case TaskInfoFlavor.absoluteTime:
            words = 8
            for v in [ticks(user), ticks(system), ticks(user), ticks(system)] { b.appendLE(v) }
        case TaskInfoFlavor.eventsInfo:
            words = 8
            b = [UInt8](repeating: 0, count: 32)
        case TaskInfoFlavor.threadTimes:
            words = 4
            timeValue(user, into: &b)
            timeValue(system, into: &b)
        case TaskInfoFlavor.basic64, TaskInfoFlavor.basic64v2:
            words = 10
            b.appendLE(Int32(0))       // suspend_count
            b.appendLE(UInt64(0))      // virtual_size
            b.appendLE(UInt64(0))      // resident_size
            timeValue(user, into: &b)
            timeValue(system, into: &b)
            b.appendLE(Int32(1))       // policy: POLICY_TIMESHARE
        case TaskInfoFlavor.machBasic:
            words = 12
            for _ in 0..<3 { b.appendLE(UInt64(0)) }  // virtual, resident, resident max
            timeValue(user, into: &b)
            timeValue(system, into: &b)
            b.appendLE(Int32(1))       // policy
            b.appendLE(Int32(0))       // suspend_count
        case TaskInfoFlavor.power, TaskInfoFlavor.powerV2:
            b.appendLE(ticks(user))
            b.appendLE(ticks(system))
            for _ in 0..<4 { b.appendLE(UInt64(0)) }  // wake-ups
            if flavor == TaskInfoFlavor.power {
                words = 12
            } else {
                for _ in 0..<4 { b.appendLE(UInt64(0)) }  // gpu_energy
                b.appendLE(user &+ system)                 // task_ptime (ns)
                b.appendLE(UInt64(0))                      // task_pset_switches
                if count >= 26 {
                    b.appendLE(UInt64(0))                  // task_energy
                    words = 26
                } else {
                    words = 24
                }
            }
        default:
            return .unsupported
        }
        guard count >= words else { return .tooSmall }
        return .reply(b, words: words)
    }
}
