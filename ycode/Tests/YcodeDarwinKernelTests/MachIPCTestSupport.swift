import Foundation
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// A `MachIPC` over a fake address space, with an RW scratch region.
final class IPCEnv: @unchecked Sendable {
    static let scratch: UInt64 = 0x1_0000_0000
    static let scratchSize: UInt64 = 0x40000

    let lock = KernelLock()
    let ipc: MachIPC
    let space: GuestAddressSpace
    let main = ThreadContext(threadID: 1, portName: 0x203, vcpuIndex: 0, kind: .main)
    var lines: [String] { lineBox.all }

    init() throws {
        let box = LineBox()
        ipc = MachIPC(lock: lock, log: { box.append($0) }, pid: 100, uid: 501, gid: 20)
        space = GuestAddressSpace(backing: FakePhysicalBacking())
        _ = try space.mapAnonymous(at: Self.scratch, size: Self.scratchSize, protection: .readWrite, hint: nil)
        lineBox = box
    }

    let lineBox: LineBox

    /// Runs one trap through `MachIPC.handleTrap`. Returns x0.
    @discardableResult
    func trap(_ n: Int64, _ args: [UInt64] = [], context: ThreadContext? = nil) -> UInt64 {
        var f = TrapFrame()
        f.kind = TrapFrame.Kind.svc.rawValue
        f.x[16] = UInt64(bitPattern: n)
        for (i, v) in args.enumerated() { f.x[i] = v }
        let outcome = ipc.handleTrap(x16: n, frame: &f, context: context ?? main, memory: space)
        precondition(outcome != nil, "trap \(n) not handled")
        return f.x[0]
    }

    func kr(_ n: Int64, _ args: [UInt64] = [], context: ThreadContext? = nil) -> UInt32 {
        UInt32(truncatingIfNeeded: trap(n, args, context: context))
    }

    // Memory.
    // The fake backing is not thread-safe: guest memory is touched under the
    // kernel lock, as the kernel itself does.
    func put(_ bytes: [UInt8], at va: UInt64) { lock.withLock { try! space.write(va: va, bytes: bytes) } }
    func read(_ va: UInt64, _ count: Int) -> [UInt8] { lock.withLock { try! space.read(va: va, count: count) } }
    func r32(_ va: UInt64) -> UInt32 { read(va, 4).readLE(UInt32.self, at: 0) }
    func r64(_ va: UInt64) -> UInt64 { read(va, 8).readLE(UInt64.self, at: 0) }

    // Port helpers (target = task 0x103).
    let task: UInt64 = 0x103
    var out: UInt64 { Self.scratch + 0x3F000 }

    func allocate(_ right: UInt32 = MachPortRight.receive) -> UInt32 {
        let k = kr(-16, [task, UInt64(right), out])
        precondition(k == 0)
        return r32(out)
    }

    func construct(flags: UInt32, qlimit: UInt32 = 0, context: UInt64 = 0) -> (UInt32, UInt32) {
        put(le32(flags) + le32(qlimit) + [UInt8](repeating: 0, count: 24), at: out + 0x100)
        let k = kr(-24, [task, out + 0x100, context, out])
        return (k, k == 0 ? r32(out) : 0)
    }

    func insertRight(_ name: UInt32, _ poly: UInt32, _ disposition: UInt32) -> UInt32 {
        kr(-21, [task, UInt64(name), UInt64(poly), UInt64(disposition)])
    }

    func modRefs(_ name: UInt32, _ right: UInt32, _ delta: Int32) -> UInt32 {
        kr(-19, [task, UInt64(name), UInt64(right), UInt64(UInt32(bitPattern: delta))])
    }

    func deallocate(_ name: UInt32) -> UInt32 { kr(-18, [task, UInt64(name)]) }

    func type(_ name: UInt32) -> (UInt32, UInt32) {
        let k = kr(-76, [task, UInt64(name), out])
        return (k, k == 0 ? r32(out) : 0)
    }

    func urefs(_ name: UInt32) -> UInt32 { ipc.entry(name)?.urefs ?? 0 }

    func requestNotification(_ name: UInt32, _ id: Int32, sync: UInt32 = 0, notify: UInt32,
                             poly: UInt32 = MachMsgType.makeSendOnce) -> (UInt32, UInt32) {
        put(le32(0xDEAD), at: out + 0x200)
        let k = kr(-77, [task, UInt64(name), UInt64(UInt32(bitPattern: id)), UInt64(sync), UInt64(notify),
                         UInt64(poly), out + 0x200])
        return (k, r32(out + 0x200))
    }

    // Messages.
    static let sendBuffer: UInt64 = scratch
    static let receiveBuffer: UInt64 = scratch + 0x8000

    /// Sends `msg` with `mach_msg_trap` (−31).
    func send(_ msg: [UInt8], options: UInt64 = MachMsgOption.sendMsg, timeout: UInt32 = 0,
              at buffer: UInt64 = IPCEnv.sendBuffer, context: ThreadContext? = nil) -> UInt32 {
        put(msg, at: buffer)
        return kr(-31, [buffer, options, UInt64(msg.count), 0, 0, UInt64(timeout), 0], context: context)
    }

    /// Receives on `name` with `mach_msg_trap`. Returns the code and the
    /// buffer contents (`size` bytes).
    func receive(_ name: UInt32, size: UInt64 = 0x400, options: UInt64 = MachMsgOption.rcvMsg | MachMsgOption.rcvTimeout,
                 timeout: UInt32 = 0, at buffer: UInt64 = IPCEnv.receiveBuffer,
                 context: ThreadContext? = nil) -> (UInt32, [UInt8]) {
        put([UInt8](repeating: 0xEE, count: Int(size)), at: buffer)
        let k = kr(-31, [buffer, options, 0, size, UInt64(name), UInt64(timeout), 0], context: context)
        return (k, read(buffer, Int(size)))
    }
}

final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ s: String) { lock.withLock { lines.append(s) } }
    var all: [String] { lock.withLock { lines } }
}

/// Builds a message in user layout.
struct TestMessage {
    var remote: UInt32
    var remoteDisposition: UInt32
    var local: UInt32 = 0
    var localDisposition: UInt32 = 0
    var voucher: UInt32 = 0
    var voucherDisposition: UInt32 = 0
    var id: Int32 = 1000
    var descriptors: [[UInt8]] = []
    var inline: [UInt8] = []
    var complex: Bool? = nil
    var extraBits: UInt32 = 0

    var isComplex: Bool { complex ?? !descriptors.isEmpty }

    var bits: UInt32 {
        MachMsgBits.make(remote: remoteDisposition, local: localDisposition, voucher: voucherDisposition,
                         other: (isComplex ? MachMsgBits.complex : 0) | extraBits)
    }

    var bytes: [UInt8] {
        var body: [UInt8] = []
        if isComplex {
            body += le32(UInt32(descriptors.count))
            for d in descriptors { body += d }
        }
        body += inline
        let size = 24 + body.count
        return le32(bits) + le32(UInt32(size)) + le32(remote) + le32(local) + le32(voucher)
            + le32(UInt32(bitPattern: id)) + body
    }

    static func port(_ name: UInt32, _ disposition: UInt32) -> [UInt8] {
        le32(name) + le32(0) + [0, 0, UInt8(disposition), MachMsgDescriptor.port]
    }

    static func ool(_ address: UInt64, size: UInt32, deallocate: Bool = false, copy: UInt8 = 0,
                    type: UInt8 = MachMsgDescriptor.ool) -> [UInt8] {
        le64(address) + [deallocate ? 1 : 0, copy, 0, type] + le32(size)
    }

    static func oolPorts(_ address: UInt64, count: UInt32, disposition: UInt32, deallocate: Bool = false) -> [UInt8] {
        le64(address) + [deallocate ? 1 : 0, 1, UInt8(disposition), MachMsgDescriptor.oolPorts] + le32(count)
    }

    static func guarded(_ name: UInt32, context: UInt64, flags: UInt16,
                        disposition: UInt32 = MachMsgType.moveReceive) -> [UInt8] {
        le64(context) + [UInt8(flags & 0xFF), UInt8(flags >> 8), UInt8(disposition), MachMsgDescriptor.guardedPort]
            + le32(name)
    }
}

/// A received message, decoded.
struct Received {
    let raw: [UInt8]
    var bits: UInt32 { raw.readLE(UInt32.self, at: 0) }
    var size: UInt32 { raw.readLE(UInt32.self, at: 4) }
    var remote: UInt32 { raw.readLE(UInt32.self, at: 8) }
    var local: UInt32 { raw.readLE(UInt32.self, at: 12) }
    var voucher: UInt32 { raw.readLE(UInt32.self, at: 16) }
    var id: Int32 { raw.readLE(Int32.self, at: 20) }
    func u32(_ at: Int) -> UInt32 { raw.readLE(UInt32.self, at: at) }
    func u64(_ at: Int) -> UInt64 { raw.readLE(UInt64.self, at: at) }
    /// The trailer that follows the message.
    func trailer(_ field: Int) -> UInt32 { raw.readLE(UInt32.self, at: Int(size) + field) }

    init(_ raw: [UInt8]) { self.raw = raw }
}
