import Foundation
import YcodeDarwinABI

/// All guest processes of one simulated device (stage 4b,
/// `specs/simulator/stage4b-contract.md` §3). One `DarwinSystem` owns the
/// kernel lock every process shares, the process table, the shared Mach
/// state, and the launcher that turns a spawn request into a running VM.
///
/// Owner: agent P (process layer). Contract-pinned members are marked.
public final class DarwinSystem: @unchecked Sendable {
    /// Contract-pinned: the one kernel lock of the whole system.
    public let lock: KernelLock
    /// Contract-pinned: Mach state shared by every task (agent M).
    public let mach: MachIPCSystem
    /// Contract-pinned: builds VMs for new images (agent V).
    public weak var launcher: (any ProcessLauncher)?

    public init() {
        lock = KernelLock()
        mach = MachIPCSystem()
    }

    /// Contract-pinned: the live (not zombie) kernel of `pid`'s current image.
    public func kernel(forPID pid: Int32) -> DarwinKernel? {
        nil
    }
}
