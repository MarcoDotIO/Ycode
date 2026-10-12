import Foundation

/// A descriptor that is not a host file: a pipe end, a socket, a kqueue
/// (stage 4b, `specs/simulator/stage4b-contract.md` §6). The file system only
/// stores it; the kernel module gives it behavior. Owner: agent F.
public protocol DarwinDescriptorObject: AnyObject {
    /// The `S_IFMT` bits `fstat` reports (`S_IFIFO`, `S_IFSOCK`, …).
    var fileType: UInt16 { get }
    /// The last descriptor (in any process) that refers to this open file
    /// description was closed. Called with the kernel lock held.
    func lastReferenceClosed()
}
