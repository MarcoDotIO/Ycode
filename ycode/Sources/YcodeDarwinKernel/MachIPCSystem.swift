import Foundation
import YcodeDarwinABI

/// Mach state shared by every task of one `DarwinSystem` (stage 4b,
/// `specs/simulator/stage4b-contract.md` §5, `processes.md` §4.1). Owner:
/// agent M.
///
/// Ports are global objects: a port created in one task's space can be named
/// in any other space of the same system. The system owns the counters that
/// must be comparable across spaces (port serials, readiness stamps), the one
/// host port, and the one bootstrap kernel object (the root task's bootstrap
/// special port until stage 4c gives it a server). Every field is used with
/// the system's kernel lock held.
public final class MachIPCSystem: @unchecked Sendable {
    var serialCounter: UInt64 = 0
    var stampCounter: UInt64 = 0
    var spaceCounter: UInt64 = 0
    /// The host port (`host_self`); every task's host slot starts here.
    let hostPort: IPCPort
    /// The VMM's bootstrap object (`host-libraries.md` §10): sends to it fail
    /// with `MACH_SEND_INVALID_DEST`.
    let bootstrapPort: IPCPort
    /// The audit session id every guest process reports (`processes.md` §4.5:
    /// one fixed session per simulator instance).
    public var auditSessionID: UInt32 = 0

    public init() {
        hostPort = IPCPort(serial: 1)
        hostPort.kernelObject = .host
        bootstrapPort = IPCPort(serial: 2)
        bootstrapPort.kernelObject = .bootstrap
        serialCounter = 2
    }

    func nextSerial() -> UInt64 {
        serialCounter += 1
        return serialCounter
    }

    func nextStamp() -> UInt64 {
        stampCounter += 1
        return stampCounter
    }

    func nextSpaceID() -> UInt64 {
        spaceCounter += 1
        return spaceCounter
    }
}

// MARK: - Fileports (processes.md §4.9)

extension MachIPC {
    /// BSD `fileport_makeport`.
    public static let bsdFileportMakeport = 430
    /// BSD `fileport_makefd`.
    public static let bsdFileportMakefd = 431

    /// Contract-pinned (stage 4b §3.7): fileport BSD calls 430
    /// (`fileport_makeport(fd, &name)`) and 431 (`fileport_makefd(name)`),
    /// forwarded by the process layer. Returns the BSD result value, throws
    /// `DarwinErrnoError`, or returns nil for any other call number. Lock held.
    func fileportCall(_ n: Int, _ a: [UInt64], fileSystem: DarwinFileSystem,
                      memory: any KernelGuestMemory) throws -> UInt64? {
        switch n {
        case Self.bsdFileportMakeport:
            let fd = Int32(truncatingIfNeeded: a.count > 0 ? a[0] : 0)
            let out = a.count > 1 ? a[1] : 0
            // EBADF for a closed fd comes from the file system; a confined
            // description (kqueue) cannot be sent. The port holds the
            // description by keeping a strong reference to it.
            let file = try fileSystem.openFile(for: fd)
            if file.object?.isConfined ?? false { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
            let p = newPort()
            p.kernelObject = .fileport(serial: p.serial)
            p.fileportFile = file
            p.srights = 1
            let (name, ok) = copyout(.send(p))
            guard ok else {
                throw DarwinErrnoError(DarwinErrnoCode.ENOMEM)
            }
            do {
                try memory.write(va: out, bytes: le32(name))
            } catch {
                _ = portDeallocate(name)
                throw DarwinErrnoError(DarwinErrnoCode.EFAULT)
            }
            log("fileport_makeport(fd=\(fd)) -> \(hx(name))")
            return 0

        case Self.bsdFileportMakefd:
            let name = UInt32(truncatingIfNeeded: a.count > 0 ? a[0] : 0)
            guard let (p, object) = kernelObject(named: name), case .fileport = object, p.active,
                  let file = p.fileportFile else {
                throw DarwinErrnoError(DarwinErrnoCode.EINVAL)
            }
            let fd = try fileSystem.install(file, closeOnExec: true)
            log("fileport_makefd(\(hx(name))) -> fd \(fd)")
            return UInt64(UInt32(bitPattern: fd))

        default:
            return nil
        }
    }

    /// The open file description a fileport name sends to (spawn
    /// `FILEPORT_DUP2`, `processes.md` §1.7 type 4). Nil when `name` is not a
    /// send right to a live fileport. Lock held.
    public func fileportFile(named name: UInt32) -> DarwinOpenFile? {
        guard let (p, object) = kernelObject(named: name), case .fileport = object, p.active else { return nil }
        return p.fileportFile
    }
}

// MARK: - Spawn port actions (processes.md §1.8)

/// One 24-byte port action of `posix_spawn` (`processes.md` §1.8).
/// Contract-pinned name.
///
/// Layout: `port_type` @0, `mask` @4, `new_port` @8, `behavior` @12,
/// `flavor` @16, `which` @20 (all 32-bit).
public struct SpawnPortAction: Equatable, Sendable {
    /// `port_type` values.
    public enum Kind: UInt32, Sendable {
        case special = 0
        case exception = 1
        case auditSession = 2
        case importanceWatch = 3
        case registered = 4
        case ptrauthTask = 5
    }

    /// The raw `port_type`; `kind` is nil for an unknown type (EINVAL).
    public var type: UInt32
    /// Exception mask (EXCEPTION).
    public var mask: UInt32
    /// A Mach name in the **caller's** space (0 and 0xFFFFFFFF pass through).
    public var port: UInt32
    /// Exception behavior (EXCEPTION).
    public var behavior: UInt32
    /// Thread-state flavor (EXCEPTION).
    public var flavor: UInt32
    /// Special-port number (SPECIAL).
    public var which: Int32

    public var kind: Kind? { Kind(rawValue: type) }

    public init() {
        self.init(type: 0, port: 0)
    }

    public init(type: UInt32, mask: UInt32 = 0, port: UInt32, behavior: UInt32 = 0, flavor: UInt32 = 0,
                which: Int32 = 0) {
        self.type = type
        self.mask = mask
        self.port = port
        self.behavior = behavior
        self.flavor = flavor
        self.which = which
    }

    public init(kind: Kind, mask: UInt32 = 0, port: UInt32, behavior: UInt32 = 0, flavor: UInt32 = 0,
                which: Int32 = 0) {
        self.init(type: kind.rawValue, mask: mask, port: port, behavior: behavior, flavor: flavor, which: which)
    }

    /// Size of one record.
    public static let recordSize = 24

    /// Decodes one 24-byte record (`bytes.count >= 24`).
    public init(record bytes: [UInt8]) {
        precondition(bytes.count >= Self.recordSize)
        self.init(type: bytes.readLE(UInt32.self, at: 0), mask: bytes.readLE(UInt32.self, at: 4),
                  port: bytes.readLE(UInt32.self, at: 8), behavior: bytes.readLE(UInt32.self, at: 12),
                  flavor: bytes.readLE(UInt32.self, at: 16), which: bytes.readLE(Int32.self, at: 20))
    }

    /// Decodes a port-action block: `{i32 alloc @0, i32 count @4, actions @8}`.
    /// Throws EINVAL when the block is shorter than its count says.
    public static func parseBlock(_ bytes: [UInt8]) throws -> [SpawnPortAction] {
        guard bytes.count >= 8 else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        let count = bytes.readLE(Int32.self, at: 4)
        guard count >= 0, bytes.count >= 8 + Int(count) * recordSize else {
            throw DarwinErrnoError(DarwinErrnoCode.EINVAL)
        }
        return (0..<Int(count)).map { k in
            SpawnPortAction(record: Array(bytes[(8 + k * recordSize)..<(8 + (k + 1) * recordSize)]))
        }
    }

    /// The 24-byte record.
    public var record: [UInt8] {
        le32(type) + le32(mask) + le32(port) + le32(behavior) + le32(flavor) + le32(UInt32(bitPattern: which))
    }
}
