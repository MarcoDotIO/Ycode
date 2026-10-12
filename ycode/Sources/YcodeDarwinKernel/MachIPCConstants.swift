// Mach IPC constants as user space sees them (specs/simulator/mach-ipc.md).
// Every value here is an interoperability fact restated in the spec.

/// `kern_return_t` values used by the IPC routines (`mach-ipc.md` §1.7, §5.2).
public enum MachKern {
    public static let success: UInt32 = 0
    public static let invalidAddress: UInt32 = 1
    public static let noSpace: UInt32 = 3
    public static let invalidArgument: UInt32 = 4
    public static let failure: UInt32 = 5
    public static let noAccess: UInt32 = 8
    public static let alreadyInSet: UInt32 = 11
    public static let notInSet: UInt32 = 12
    public static let nameExists: UInt32 = 13
    public static let aborted: UInt32 = 14
    public static let invalidName: UInt32 = 15
    public static let invalidTask: UInt32 = 16
    public static let invalidRight: UInt32 = 17
    public static let invalidValue: UInt32 = 18
    public static let invalidCapability: UInt32 = 20
    public static let rightExists: UInt32 = 21
    public static let operationTimedOut: UInt32 = 49
    public static let denied: UInt32 = 53
    /// What a trap returns when an out-pointer cannot be written or an
    /// in-pointer cannot be read: the copyin/copyout error (EFAULT).
    public static let copyFault: UInt32 = 14

    public static let migTypeError = UInt32(bitPattern: -300)
    public static let migReplyMismatch = UInt32(bitPattern: -301)
    public static let migBadID = UInt32(bitPattern: -303)
    public static let migBadArguments = UInt32(bitPattern: -304)
    public static let migNoReply = UInt32(bitPattern: -305)
    public static let migArrayTooLarge = UInt32(bitPattern: -307)
    public static let migServerDied = UInt32(bitPattern: -308)
}

/// `mach_msg_return_t` values (`mach-ipc.md` §2.12).
public enum MachMsgReturn {
    public static let success: UInt32 = 0
    public static let sendInvalidData: UInt32 = 0x1000_0002
    public static let sendInvalidDest: UInt32 = 0x1000_0003
    public static let sendTimedOut: UInt32 = 0x1000_0004
    public static let sendInvalidVoucher: UInt32 = 0x1000_0005
    public static let sendInterrupted: UInt32 = 0x1000_0007
    public static let sendMsgTooSmall: UInt32 = 0x1000_0008
    public static let sendInvalidReply: UInt32 = 0x1000_0009
    public static let sendInvalidRight: UInt32 = 0x1000_000A
    public static let sendInvalidMemory: UInt32 = 0x1000_000C
    public static let sendNoBuffer: UInt32 = 0x1000_000D
    public static let sendTooLarge: UInt32 = 0x1000_000E
    public static let sendInvalidType: UInt32 = 0x1000_000F
    public static let sendInvalidHeader: UInt32 = 0x1000_0010
    public static let sendInvalidOptions: UInt32 = 0x1000_0013
    public static let sendAuxTooSmall: UInt32 = 0x1000_0018
    public static let sendAuxTooLarge: UInt32 = 0x1000_0019

    public static let rcvInvalidName: UInt32 = 0x1000_4002
    public static let rcvTimedOut: UInt32 = 0x1000_4003
    public static let rcvTooLarge: UInt32 = 0x1000_4004
    public static let rcvInterrupted: UInt32 = 0x1000_4005
    public static let rcvPortChanged: UInt32 = 0x1000_4006
    public static let rcvInvalidNotify: UInt32 = 0x1000_4007
    public static let rcvInvalidData: UInt32 = 0x1000_4008
    public static let rcvHeaderError: UInt32 = 0x1000_400B
    public static let rcvBodyError: UInt32 = 0x1000_400C
    public static let rcvInvalidArguments: UInt32 = 0x1000_4013

    /// Resource bits ORed into a result.
    public static let ipcSpace: UInt32 = 0x2000
    public static let vmSpace: UInt32 = 0x1000
    public static let ipcKernel: UInt32 = 0x0800
    public static let vmKernel: UInt32 = 0x0400

    static let names: [UInt32: String] = [
        0x1000_0002: "MACH_SEND_INVALID_DATA", 0x1000_0003: "MACH_SEND_INVALID_DEST",
        0x1000_0004: "MACH_SEND_TIMED_OUT", 0x1000_0005: "MACH_SEND_INVALID_VOUCHER",
        0x1000_0007: "MACH_SEND_INTERRUPTED", 0x1000_0008: "MACH_SEND_MSG_TOO_SMALL",
        0x1000_0009: "MACH_SEND_INVALID_REPLY", 0x1000_000A: "MACH_SEND_INVALID_RIGHT",
        0x1000_000C: "MACH_SEND_INVALID_MEMORY", 0x1000_000D: "MACH_SEND_NO_BUFFER",
        0x1000_000E: "MACH_SEND_TOO_LARGE", 0x1000_000F: "MACH_SEND_INVALID_TYPE",
        0x1000_0010: "MACH_SEND_INVALID_HEADER", 0x1000_0013: "MACH_SEND_INVALID_OPTIONS",
        0x1000_0018: "MACH_SEND_AUX_TOO_SMALL", 0x1000_0019: "MACH_SEND_AUX_TOO_LARGE",
        0x1000_4002: "MACH_RCV_INVALID_NAME", 0x1000_4003: "MACH_RCV_TIMED_OUT",
        0x1000_4004: "MACH_RCV_TOO_LARGE", 0x1000_4005: "MACH_RCV_INTERRUPTED",
        0x1000_4006: "MACH_RCV_PORT_CHANGED", 0x1000_4007: "MACH_RCV_INVALID_NOTIFY",
        0x1000_4008: "MACH_RCV_INVALID_DATA", 0x1000_400B: "MACH_RCV_HEADER_ERROR",
        0x1000_400C: "MACH_RCV_BODY_ERROR", 0x1000_4013: "MACH_RCV_INVALID_ARGUMENTS",
    ]
    static let kernNames: [UInt32: String] = [
        0: "KERN_SUCCESS", 1: "KERN_INVALID_ADDRESS", 3: "KERN_NO_SPACE", 4: "KERN_INVALID_ARGUMENT",
        5: "KERN_FAILURE", 8: "KERN_NO_ACCESS", 11: "KERN_ALREADY_IN_SET", 12: "KERN_NOT_IN_SET", 13: "KERN_NAME_EXISTS",
        14: "EFAULT/KERN_ABORTED", 15: "KERN_INVALID_NAME", 16: "KERN_INVALID_TASK", 17: "KERN_INVALID_RIGHT",
        18: "KERN_INVALID_VALUE", 20: "KERN_INVALID_CAPABILITY", 21: "KERN_RIGHT_EXISTS",
        49: "KERN_OPERATION_TIMED_OUT", 53: "KERN_DENIED",
        UInt32(bitPattern: -303): "MIG_BAD_ID", UInt32(bitPattern: -307): "MIG_ARRAY_TOO_LARGE",
    ]

    /// A readable name for a `kern_return_t` or `mach_msg_return_t`.
    public static func name(_ value: UInt32) -> String {
        if let n = kernNames[value] { return n }
        let resource = value & 0x3E00
        if let n = names[value & ~0x3E00] {
            return resource == 0 ? n : "\(n)|\(hx(resource))"
        }
        return hx(value)
    }
}

/// `mach_port_right_t` (`mach-ipc.md` §1.1).
public enum MachPortRight {
    public static let send: UInt32 = 0
    public static let receive: UInt32 = 1
    public static let sendOnce: UInt32 = 2
    public static let portSet: UInt32 = 3
    public static let deadName: UInt32 = 4
    public static let labelh: UInt32 = 5
    public static let number: UInt32 = 6
}

/// `mach_port_type_t` bits (`mach-ipc.md` §1.1).
public enum MachPortType {
    public static let send: UInt32 = 0x0001_0000
    public static let receive: UInt32 = 0x0002_0000
    public static let sendOnce: UInt32 = 0x0004_0000
    public static let portSet: UInt32 = 0x0008_0000
    public static let deadName: UInt32 = 0x0010_0000
    public static let dnRequest: UInt32 = 0x8000_0000
    public static let spRequest: UInt32 = 0x4000_0000
    public static let spRequestDelayed: UInt32 = 0x2000_0000
    public static let sendRights: UInt32 = 0x0005_0000
    public static let portRights: UInt32 = 0x0007_0000
    public static let allRights: UInt32 = 0x001F_0000

    /// `MACH_PORT_TYPE(right)`.
    public static func of(right: UInt32) -> UInt32 { 1 << (right + 16) }
}

/// Port names (`mach-ipc.md` §1.1, §1.4).
public enum MachPortName {
    public static let null: UInt32 = 0
    public static let dead: UInt32 = 0xFFFF_FFFF
    public static func isValid(_ name: UInt32) -> Bool { name != null && name != dead }
    /// `MACH_PORT_UREFS_MAX`.
    public static let urefsMax: UInt32 = 0xFFFF
}

/// Message dispositions and received types (`mach-ipc.md` §2.4).
public enum MachMsgType {
    public static let moveReceive: UInt32 = 16
    public static let moveSend: UInt32 = 17
    public static let moveSendOnce: UInt32 = 18
    public static let copySend: UInt32 = 19
    public static let makeSend: UInt32 = 20
    public static let makeSendOnce: UInt32 = 21
    /// Received types.
    public static let portReceive: UInt32 = 16
    public static let portSend: UInt32 = 17
    public static let portSendOnce: UInt32 = 18

    /// The type a disposition is carried (and received) as.
    public static func received(_ disposition: UInt32) -> UInt32 {
        switch disposition {
        case moveReceive: portReceive
        case moveSend, copySend, makeSend: portSend
        case moveSendOnce, makeSendOnce: portSendOnce
        default: 0
        }
    }

    public static func isPortDisposition(_ d: UInt32) -> Bool { (16...21).contains(d) }
}

/// `msgh_bits` fields (`mach-ipc.md` §2.2).
public enum MachMsgBits {
    public static let remoteMask: UInt32 = 0x0000_001F
    public static let localMask: UInt32 = 0x0000_1F00
    public static let voucherMask: UInt32 = 0x001F_0000
    public static let complex: UInt32 = 0x8000_0000
    /// `MACH_MSGH_BITS_USER`: what the kernel keeps on send.
    public static let user: UInt32 = 0x801F_1F1F

    public static func remote(_ bits: UInt32) -> UInt32 { bits & remoteMask }
    public static func local(_ bits: UInt32) -> UInt32 { (bits & localMask) >> 8 }
    public static func voucher(_ bits: UInt32) -> UInt32 { (bits & voucherMask) >> 16 }
    public static func make(remote: UInt32, local: UInt32 = 0, voucher: UInt32 = 0, other: UInt32 = 0) -> UInt32 {
        remote | (local << 8) | (voucher << 16) | other
    }
}

/// Descriptor kinds (`mach-ipc.md` §2.3).
public enum MachMsgDescriptor {
    public static let port: UInt8 = 0
    public static let ool: UInt8 = 1
    public static let oolPorts: UInt8 = 2
    public static let oolVolatile: UInt8 = 3
    public static let guardedPort: UInt8 = 4

    public static let physicalCopy: UInt8 = 0
    public static let virtualCopy: UInt8 = 1

    public static let guardImmovableReceive: UInt16 = 0x1
    public static let guardUnguardedOnSend: UInt16 = 0x2
    public static let guardMask: UInt16 = 0x3

    /// The wire size of a descriptor of `type` in a 64-bit task.
    public static func size(of type: UInt8) -> Int { type == port ? 12 : 16 }
}

/// `mach_msg` options (`mach-ipc.md` §2.7).
public enum MachMsgOption {
    public static let sendMsg: UInt64 = 0x1
    public static let rcvMsg: UInt64 = 0x2
    public static let rcvLarge: UInt64 = 0x4
    public static let rcvLargeIdentity: UInt64 = 0x8
    public static let sendTimeout: UInt64 = 0x10
    public static let sendOverride: UInt64 = 0x20
    public static let sendInterrupt: UInt64 = 0x40
    public static let sendNotify: UInt64 = 0x80
    public static let rcvTimeout: UInt64 = 0x100
    public static let strictReply: UInt64 = 0x200
    public static let rcvInterrupt: UInt64 = 0x400
    public static let rcvVoucher: UInt64 = 0x800
    public static let rcvGuardedDesc: UInt64 = 0x1000
    public static let rcvSyncWait: UInt64 = 0x4000
    public static let rcvSyncPeek: UInt64 = 0x8000
    public static let sendTrailer: UInt64 = 0x20000
    public static let msgVector: UInt64 = 1 << 32
    public static let sendKobjectCall: UInt64 = 1 << 33
    public static let sendMQCall: UInt64 = 1 << 34
    public static let sendAny: UInt64 = 1 << 35
    public static let sendDKCall: UInt64 = 1 << 36

    /// `MACH_RCV_TRAILER_ELEMENTS(n)` → the trailer size (`mach-ipc.md` §2.6).
    public static func trailerSize(_ options: UInt64) -> Int {
        switch Int((options >> 24) & 0xF) {
        case 0: 8
        case 1: 12
        case 2: 20
        case 3: 52
        case 4: 60
        default: 68
        }
    }
}

/// Notification message IDs (`mach-ipc.md` §3).
public enum MachNotify {
    public static let portDeleted: Int32 = 65
    public static let sendPossible: Int32 = 66
    public static let portDestroyed: Int32 = 69
    public static let noSenders: Int32 = 70
    public static let sendOnce: Int32 = 71
    public static let deadName: Int32 = 72
}

/// `mach_port_construct` option flags (`mach-ipc.md` §1.7).
public enum MachPortConstruct {
    public static let contextAsGuard: UInt32 = 0x01
    public static let qlimit: UInt32 = 0x02
    public static let tempOwner: UInt32 = 0x04
    public static let importanceReceiver: UInt32 = 0x08
    public static let insertSendRight: UInt32 = 0x10
    public static let strict: UInt32 = 0x20
    public static let denapReceiver: UInt32 = 0x40
    public static let immovableReceive: UInt32 = 0x80
    public static let filterMessage: UInt32 = 0x100
    public static let tgBlockTracking: UInt32 = 0x200
    public static let enforceReplyPortSemantics: UInt32 = 0x2000
    public static let typeMask: UInt32 = 0x1DC00
    public static let connectionPort: UInt32 = 0x800
    public static let replyPort: UInt32 = 0x1000
    public static let typeValues: Set<UInt32> = [0, 0x400, 0x800, 0x1000, 0x4000, 0x4400, 0x8000, 0x10000]
    public static let known: UInt32 = 0x3FF | enforceReplyPortSemantics | typeMask
}

/// Queue and message limits (`mach-ipc.md` §2.13).
public enum MachIPCLimits {
    public static let qlimitDefault = 5
    public static let qlimitMax = 1024
    public static let qlimitKernel = 65_534
    public static let maxSendSize: UInt32 = 50_331_580
    public static let maxRightsPerMessage = 16_383
    public static let maxAuxSize = 1024
    /// Ycode's cap on the OOL memory one message may carry (`MACH_MSG_VM_KERNEL` above it).
    public static let maxOOLBytes: UInt64 = 1 << 30
    /// The largest table index a name can encode.
    public static let maxIndex = 0xFF_FFFF
}

/// The 8-byte `NDR_record_t` for arm64 (`mach-ipc.md` §5.2).
public let machNDRRecord: [UInt8] = [0, 0, 0, 0, 1, 0, 0, 0]
