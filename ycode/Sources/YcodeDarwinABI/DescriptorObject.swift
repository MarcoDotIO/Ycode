import Foundation

/// A descriptor that is not a host file: a pipe end, a socket, a kqueue
/// (stage 4b, `specs/simulator/stage4b-contract.md` §6). The file system only
/// stores it; the kernel module gives it behavior. Owner: agent F.
///
/// An object lives inside one `DarwinOpenFile` (an open file description).
/// Every descriptor that shares the description (dup, dup2, inheritance,
/// SCM_RIGHTS, fileports) holds a strong reference to that description; the
/// description calls `lastReferenceClosed()` once, when the last holder lets
/// it go.
public protocol DarwinDescriptorObject: AnyObject {
    /// The `S_IFMT` bits `fstat` reports (`S_IFIFO`, `S_IFSOCK`, …).
    var fileType: UInt16 { get }
    /// The last descriptor (in any process) that refers to this open file
    /// description was closed, and no message or fileport holds it either.
    /// Normally called with the kernel lock held (from `close`, `dup2`,
    /// exec, exit); an implementation that touches shared kernel state should
    /// take the lock itself with the re-entrant `KernelLock.withLock`, since
    /// a holder outside the kernel (a test, VM teardown) may drop the last
    /// reference without it.
    func lastReferenceClosed()
    /// A "confined" descriptor (a kqueue) is not inherited by a spawned child
    /// and cannot be sent with SCM_RIGHTS or a fileport (EINVAL;
    /// `processes.md` §1.11, §4.9, §5.5). Default: false.
    var isConfined: Bool { get }
    /// What `fstat` reports. Default: the type bits with mode 0600, owned by
    /// the guest user.
    func descriptorStat() -> DarwinStat
}

extension DarwinDescriptorObject {
    public var isConfined: Bool { false }

    public func descriptorStat() -> DarwinStat {
        DarwinStat(mode: fileType | 0o600, nlink: 1, uid: DarwinFileSystem.guestUID, gid: DarwinFileSystem.guestGID)
    }
}
