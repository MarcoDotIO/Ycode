import Foundation
import YcodeDarwinABI

// The process layer of stage 4b (`specs/simulator/stage4b-contract.md` §4):
// posix_spawn, execve, exit, wait4/waitid, kill, process groups, proc_info.
// Owner: agent P.

extension DarwinKernel {
    /// BSD calls the process layer owns. nil = not mine.
    func processCall(_ n: Int, _ a: [UInt64], _ call: inout String, _ fallback: inout Int32,
                     _ mem: any KernelGuestMemory) throws -> BSDResult? {
        nil
    }

    /// Contract-pinned (§4.6): posts `signal` to this process (to `thread`
    /// when given, as for SIGPIPE). Lock held.
    public func postSignal(_ signal: Int32, thread: ThreadContext? = nil) {
    }
}
