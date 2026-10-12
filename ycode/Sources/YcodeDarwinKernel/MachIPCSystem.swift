import Foundation
import YcodeDarwinABI

/// Mach state shared by every task of one `DarwinSystem` (stage 4b,
/// `specs/simulator/stage4b-contract.md` §5). Owner: agent M.
public final class MachIPCSystem: @unchecked Sendable {
    public init() {}
}

extension MachIPC {
    /// Contract-pinned (stage 4b §3.7): fileport BSD calls 430
    /// (`fileport_makeport`) and 431 (`fileport_makefd`), forwarded by the
    /// process layer. Returns the BSD result value, throws
    /// `DarwinErrnoError`, or returns nil for any other call number.
    func fileportCall(_ n: Int, _ a: [UInt64], fileSystem: DarwinFileSystem,
                      memory: any KernelGuestMemory) throws -> UInt64? {
        nil
    }
}

/// One 24-byte port action of `posix_spawn` (`processes.md` §1.8).
/// Contract-pinned name; agent M defines the fields.
public struct SpawnPortAction: Equatable, Sendable {
    public init() {}
}

extension MachIPC {
    /// Contract-pinned (stage 4b §3.7). Stub: agent M implements.
    public func inheritTaskPorts(from parent: MachIPC) {}

    /// Contract-pinned (stage 4b §3.7). Stub: agent M implements.
    public func applySpawnPortActions(_ actions: [SpawnPortAction], from caller: MachIPC) throws {}

    /// Contract-pinned (stage 4b §3.7). Stub: agent M implements.
    public func terminateTask() {}
}
