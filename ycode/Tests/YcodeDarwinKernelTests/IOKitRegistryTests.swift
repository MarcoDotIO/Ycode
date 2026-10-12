import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// The minimal IOKit registry: host_get_io_main (private routine 16) and the
/// IOKit MIG subsystem (2800) on its ports.
@Suite struct IOKitRegistryTests {
    let s = IPCEnv.scratch + 0x30000

    func migString(_ text: String) -> [UInt8] {
        var b = Array(text.utf8) + [0]
        let n = UInt32(b.count)
        while b.count % 4 != 0 { b.append(0) }
        return le32(0) + le32(n) + b
    }

    /// Sends a request with a reply port and returns the reply.
    func call(_ env: IPCEnv, _ target: UInt32, _ id: Int32, _ args: [UInt8] = []) -> Received {
        let reply = env.allocate()
        #expect(env.send(TestMessage(remote: target, remoteDisposition: MachMsgType.copySend, local: reply,
                                     localDisposition: MachMsgType.makeSendOnce, id: id,
                                     inline: machNDRRecord + args).bytes) == 0)
        let (k, raw) = env.receive(reply)
        #expect(k == 0)
        return Received(raw)
    }

    @Test func rootDomainLookup() throws {
        let env = try IPCEnv()
        #expect(env.kr(0x7963_2010, [0x303, s]) == 0)
        let main = env.r32(s)
        #expect(env.ipc.kernelObjectKind(of: main) == .ioMain)
        #expect(env.kr(0x7963_2010, [0x1234, s]) == MachKern.invalidArgument)
        // io_server_version: not answered (legacy routines).
        #expect(call(env, main, 2877).u32(32) == MachKern.migBadID)
        // io_registry_entry_from_path: the root domain; an unknown path gives no entry.
        let r = call(env, main, 2809, migString("IOPower:/IOPowerConnection/IOPMrootDomain"))
        #expect(r.id == 2909 && r.bits & MachMsgBits.complex != 0 && r.u32(24) == 1)
        let root = r.u32(28)
        #expect(MachPortName.isValid(root))
        #expect(call(env, main, 2809, migString("IOService:/nothing")).u32(28) == 0)
        // io_object_get_class / conforms_to / get_name / registry id.
        let cls = call(env, root, 2800)
        #expect(cls.u32(32) == 0 && cls.u32(40) == 15)
        #expect(String(decoding: cls.raw[44..<58], as: UTF8.self) == "IOPMrootDomain")
        #expect(call(env, root, 2801, migString("IOService")).u32(36) == 1)
        #expect(call(env, root, 2801, migString("IOMedia")).u32(36) == 0)
        // Properties: none; user clients: none.
        #expect(call(env, root, 2805, migString("PMSettings")).u32(32) == IOReturn.notFound)
        // An interest notification is a new object port.
        let wake = env.allocate()
        let reply = env.allocate()
        let args = machNDRRecord + migString("IOGeneralInterest") + le32(1) + le64(0x77)
        // mach_msg_port_descriptor_t: name, pad, {pad2 u16, disposition u8, type u8 (0 = port)}.
        let portDescriptor = le32(wake) + le32(0) + [0, 0, UInt8(MachMsgType.makeSend), 0]
        #expect(env.send(TestMessage(remote: root, remoteDisposition: MachMsgType.copySend, local: reply,
                                     localDisposition: MachMsgType.makeSendOnce, id: 2869,
                                     descriptors: [portDescriptor], inline: args).bytes) == 0)
        let (k, raw) = env.receive(reply)
        #expect(k == 0)
        let n = Received(raw)
        #expect(n.id == 2969 && n.u32(24) == 1)
        if case let (_, object)? = env.ipc.kernelObject(named: n.u32(28)) {
            #expect(object.description.hasPrefix("iokit-object#"))
        } else {
            Issue.record("no notification object")
        }
        // A user client: methods succeed with zeroed outputs.
        let task = env.task
        let openReply = env.allocate()
        let open = machNDRRecord + le32(7) + machNDRRecord + le32(0)
        #expect(env.send(TestMessage(remote: root, remoteDisposition: MachMsgType.copySend, local: openReply,
                                     localDisposition: MachMsgType.makeSendOnce, id: 2862,
                                     descriptors: [le32(UInt32(task)) + le32(0) + [0, 0, UInt8(MachMsgType.copySend), 0]],
                                     inline: open).bytes) == 0)
        let (ko, openRaw) = env.receive(openReply)
        #expect(ko == 0)
        let opened = Received(openRaw)
        #expect(opened.u32(24) == 1 && opened.u32(48) == 0)
        let connection = opened.u32(28)
        // selector 3, two scalar inputs, no inband input, ool 0/0, inband out max 16, scalar out max 2, ool out 0/0.
        let method = le32(3) + le32(2) + le64(5) + le64(6) + le32(0) + le64(0) + le64(0) + le32(16) + le32(2) + le64(0) + le64(0)
        let mr = call(env, connection, 2865, method)
        #expect(mr.u32(32) == 0 && mr.u32(36) == 16 && mr.u32(56) == 2 && mr.u64(60) == 0)
        // Matching: an empty iterator.
        let it = call(env, main, 2804, migString("<dict/>"))
        #expect(it.u32(24) == 1)
        #expect(call(env, it.u32(28), 2802).u32(32) == IOReturn.noDevice)
    }
}
