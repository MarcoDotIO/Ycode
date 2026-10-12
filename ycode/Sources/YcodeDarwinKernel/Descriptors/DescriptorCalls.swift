import Foundation
import YcodeDarwinABI

// Descriptors of stage 4b (`specs/simulator/stage4b-contract.md` §6): pipes,
// AF_UNIX sockets, dup/dup2, SCM_RIGHTS. Owner: agent F.

/// A descriptor object with kernel behavior (readiness for kevent/select).
/// Contract-pinned.
public protocol KernelDescriptorObject: DarwinDescriptorObject {
    /// EVFILT_READ state: readable now, the `data` value, and EOF.
    func readReadiness() -> (ready: Bool, data: Int64, eof: Bool)
    /// EVFILT_WRITE state.
    func writeReadiness() -> (ready: Bool, data: Int64, eof: Bool)
    /// Calls `observer` (lock held) whenever readiness may have changed,
    /// until `removeReadinessObserver(token)`.
    func addReadinessObserver(_ observer: @escaping () -> Void) -> Int
    func removeReadinessObserver(_ token: Int)
}

extension DarwinKernel {
    /// BSD calls the descriptor layer owns. nil = not mine.
    func descriptorCall(_ n: Int, _ a: [UInt64], _ call: inout String, _ fallback: inout Int32,
                        _ mem: any KernelGuestMemory) throws -> BSDResult? {
        nil
    }
}
