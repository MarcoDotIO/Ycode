// The objects of in-process Mach IPC (specs/simulator/mach-ipc.md §1.1,
// §1.3, §2): ports, port sets, name-space entries, rights carried by
// messages, and kernel messages. Every field is changed only with the kernel
// lock held.

/// What a kernel-object port stands for (`mach-ipc.md` §1.6). Its receive
/// right belongs to the kernel.
public enum MachKernelObject: Equatable, Sendable, CustomStringConvertible {
    case task
    case thread(serial: UInt64)
    case host
    /// The bootstrap port until `launchd_sim` owns it (`host-libraries.md` §10).
    case bootstrap
    /// A clock service port (0 system, 1 calendar).
    case clock(id: Int32)
    case semaphore(serial: UInt64)

    public var description: String {
        switch self {
        case .task: "task"
        case let .thread(serial): "thread#\(serial)"
        case .host: "host"
        case .bootstrap: "bootstrap"
        case let .clock(id): "clock(\(id))"
        case let .semaphore(serial): "semaphore#\(serial)"
        }
    }
}

/// A Mach port: a kernel message queue (`mach-ipc.md` §1.3).
final class IPCPort {
    let serial: UInt64
    /// Set for kernel-object ports (receive right held by the kernel).
    var kernelObject: MachKernelObject?
    /// The semaphore object behind a semaphore port.
    var semaphore: KernelSemaphore?
    /// Kind *special reply* (`thread_get_special_reply_port`, §4.2).
    var isSpecialReply = false
    /// False once the port died.
    var active = true
    /// True while the task's space holds the receive right.
    var inSpace = false
    /// While the receive right is in transit: the port whose queue holds the
    /// message that carries it (for the circularity check, §2.8 step 6).
    weak var transitHolder: IPCPort?

    /// Send rights in existence (entries counted once, plus rights in messages).
    var srights = 0
    var sorights = 0
    var mscount: UInt32 = 0
    var seqno: UInt32 = 0
    var qlimit = MachIPCLimits.qlimitDefault
    var messages = MessageQueue()

    var context: UInt64 = 0
    var guarded = false
    var strict = false
    var immovable = false

    /// Requests, each holding one send-once right to its notify port.
    var pdRequest: IPCPort?
    var nsRequest: IPCPort?
    /// Dead-name requests by the watched name in the space.
    var dnRequests: [UInt32: IPCPort] = [:]
    /// Names whose dead-name request fired at death; their lazy conversion
    /// adds the notification's dead-name reference (§1.5).
    var deadNameNotified: Set<UInt32> = []

    /// Port sets this port is a member of.
    var sets: [IPCPortSet] = []
    /// When the queue last became ready (round robin in set receives, §2.9).
    var readyStamp: UInt64 = 0
    /// Bumped when the receive right moves, dies, or changes set membership:
    /// a receiver blocked on the port then gets `MACH_RCV_PORT_CHANGED`.
    var changeStamp: UInt64 = 0
    /// Receivers blocked directly on this port.
    var waitingReceivers = 0
    let receiveWaiters = WaitQueue()
    let sendWaiters = WaitQueue()

    init(serial: UInt64) {
        self.serial = serial
    }

    var isKernelObject: Bool { kernelObject != nil }
}

/// A port set (`mach-ipc.md` §1.1).
final class IPCPortSet {
    let serial: UInt64
    /// The set's name in the space.
    var name: UInt32 = 0
    var members: [IPCPort] = []
    var active = true
    var changeStamp: UInt64 = 0
    var waitingReceivers = 0
    let waiters = WaitQueue()

    init(serial: UInt64) {
        self.serial = serial
    }
}

/// One slot of the name table (`mach-ipc.md` §1.2, §1.4).
struct IPCEntry {
    /// The 6-bit generation of the current (or last) name of the slot.
    var generation: UInt32 = 63
    var inUse = false
    /// `MACH_PORT_TYPE_*` right bits.
    var bits: UInt32 = 0
    var urefs: UInt32 = 0
    var port: IPCPort?
    var set: IPCPortSet?
}

/// A right inside a message, a request, or the kernel.
enum CarriedRight {
    case null
    case dead
    case send(IPCPort)
    case sendOnce(IPCPort)
    case receive(IPCPort)

    var port: IPCPort? {
        switch self {
        case .null, .dead: nil
        case let .send(p), let .sendOnce(p), let .receive(p): p
        }
    }

    /// The raw name a right-less value stands for.
    var rawName: UInt32? {
        switch self {
        case .null: MachPortName.null
        case .dead: MachPortName.dead
        default: nil
        }
    }
}

/// One descriptor of a message in kernel form.
enum KItem {
    /// A port right; `type` is the received type (16/17/18), or the sent
    /// disposition's received type for NULL/DEAD.
    case port(CarriedRight, type: UInt32)
    /// Out-of-line memory captured at send time (`data.count` = size).
    case ool(data: [UInt8], copy: UInt8, volatile: Bool)
    case oolPorts([CarriedRight], type: UInt32, copy: UInt8)
    case guarded(CarriedRight, flags: UInt16, type: UInt32)

    var wireSize: Int {
        if case .port = self { return 12 }
        return 16
    }

    var rightCount: Int {
        switch self {
        case .port, .guarded: 1
        case let .oolPorts(rights, _, _): rights.count
        case .ool: 0
        }
    }
}

/// A message in kernel form (`mach-ipc.md` §2).
struct KMessage {
    var complex: Bool
    var destination: CarriedRight
    /// Received type of the destination right (17 or 18).
    var destinationType: UInt32
    var reply: CarriedRight
    /// Received type of the reply right (0 when the reply disposition was 0).
    var replyType: UInt32
    /// The voucher field when the voucher disposition was 0 (legacy round trip).
    var voucherRaw: UInt32 = 0
    var id: Int32
    var items: [KItem] = []
    /// The bytes after the descriptors.
    var inline: [UInt8] = []
    /// Auxiliary data of a vector send (with its 8-byte header), if any.
    var aux: [UInt8]?
    /// Kernel-originated (notification or kernel-object reply): kernel trailer.
    var fromKernel = false

    /// The received size without trailer (§2.5).
    var size: Int {
        24 + (complex ? 4 + items.reduce(0) { $0 + $1.wireSize } : 0) + inline.count
    }

    /// Every receive right the message carries.
    var receiveRights: [IPCPort] {
        var out: [IPCPort] = []
        for item in items {
            switch item {
            case let .port(.receive(p), _), let .guarded(.receive(p), _, _): out.append(p)
            case let .oolPorts(rights, _, _):
                for case let .receive(p) in rights { out.append(p) }
            default: break
            }
        }
        return out
    }
}

/// A FIFO of messages with O(1) removal at the head.
struct MessageQueue {
    private var items: [KMessage] = []
    private var head = 0

    var count: Int { items.count - head }
    var isEmpty: Bool { count == 0 }
    var first: KMessage? { isEmpty ? nil : items[head] }

    mutating func append(_ m: KMessage) { items.append(m) }

    mutating func popFirst() -> KMessage? {
        guard !isEmpty else { return nil }
        let m = items[head]
        head += 1
        if head > 64 && head * 2 > items.count {
            items.removeFirst(head)
            head = 0
        }
        return m
    }

    mutating func removeAll() -> [KMessage] {
        let all = Array(items[head...])
        items = []
        head = 0
        return all
    }

    var all: ArraySlice<KMessage> { items[head...] }
}

/// What a name can be received on (for kevent's `EVFILT_MACHPORT` checks).
public enum MachReceiveTarget: Equatable, Sendable {
    /// No entry under the name.
    case none
    /// The name holds no receive right and is not a port set.
    case notReceivable
    case port
    case specialReplyPort
    case portSet
}
