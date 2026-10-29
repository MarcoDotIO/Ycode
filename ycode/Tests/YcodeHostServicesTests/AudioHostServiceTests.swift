import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel
@testable import YcodeHostServices

/// com.apple.audio.audiohald (audio-host.md), driven by a second host task
/// acting as a guest CoreAudio client: message IDs and exact reply sizes,
/// the object model, aggregate creation, the IO cycle and the workgroup port.
@Suite(.serialized) struct AudioHostServiceTests {
    static let base = AudioHostService.base
    static let ndr: [UInt8] = [0, 0, 0, 0, 1, 0, 0, 0]
    static let glob = fourCC("glob"), outp = fourCC("outp"), inpt = fourCC("inpt")

    final class Client {
        let system = DarwinSystem()
        let service: AudioHostService
        let guest: MachHostTask
        let server: UInt32
        let reply: UInt32

        init(pid: Int32 = 321) throws {
            let host = system.hostTask
            service = try AudioHostService(host: host, log: { _ in }, capturePath: nil)
            service.start()
            let system = self.system
            let g = system.lock.withLock { MachHostTask(lock: system.lock, system: system.mach, log: { _ in }) }
            g.pid = pid
            guest = g
            server = try host.give(service.servicePort, disposition: MachMsgType.copySend, to: g.ipc)
            reply = try g.makePort()
        }

        deinit { service.stop() }

        /// Sends request n and returns the reply.
        func call(_ n: Int32, to port: UInt32? = nil, _ words: [UInt32] = [], descriptors: [MachHostDescriptor] = [])
            throws -> MachHostReceivedMessage {
            try guest.send(MachHostOutgoingMessage(remotePort: port ?? server, remoteDisposition: MachMsgType.copySend,
                                                   localPort: reply, localDisposition: MachMsgType.makeSendOnce,
                                                   id: AudioHostServiceTests.base + n, descriptors: descriptors,
                                                   body: AudioHostServiceTests.ndr + words.flatMap(le32)))
            let m = try guest.receive(on: reply, timeout: 5_000_000_000)
            #expect(m.id == AudioHostServiceTests.base + 100 + n)
            return m
        }

        func get(_ n: Int32, _ obj: UInt32, _ sel: String, _ scope: UInt32 = AudioHostServiceTests.glob, element: UInt32 = 0)
            throws -> MachHostReceivedMessage {
            try call(n, [obj, fourCC(sel), scope, element])
        }

        func has(_ obj: UInt32, _ sel: String, _ scope: UInt32 = AudioHostServiceTests.glob) throws -> UInt32 {
            let m = try get(13, obj, sel, scope)
            #expect(m.size == 40 && word(m.body, 0) == 0)
            return word(m.body, 1)
        }

        func u32s(_ obj: UInt32, _ sel: String, _ scope: UInt32 = AudioHostServiceTests.glob, qualifier: [UInt8]? = nil)
            throws -> [UInt32] {
            let m: MachHostReceivedMessage
            if let qualifier {
                m = try call(20, [obj, fourCC(sel), scope, 0, UInt32(qualifier.count)], descriptors: [.ool(data: qualifier)])
            } else {
                m = try get(19, obj, sel, scope)
            }
            #expect(m.size == 56 && m.descriptors.count == 1)
            let data = ool(m)
            #expect(word(m.body, 0) == UInt32(data.count / 4))
            return stride(from: 0, to: data.count, by: 4).map { u32(data, $0) }
        }

        func plist(_ obj: UInt32, _ sel: String) throws -> [String: Any] {
            let m = try get(27, obj, sel)
            #expect(m.size == 56)
            let data = ool(m)
            #expect(word(m.body, 0) == UInt32(data.count))
            return try #require(try PropertyListSerialization.propertyList(from: Data(data), format: nil) as? [String: Any])
        }
    }

    static func le32(_ v: UInt32) -> [UInt8] { AudioHAL.le32(v) }
    static func word(_ body: [UInt8], _ i: Int) -> UInt32 { u32(body, 8 + 4 * i) }
    static func u32(_ b: [UInt8], _ at: Int) -> UInt32 { b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) } }
    static func f64(_ b: [UInt8], _ at: Int) -> Double { b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: Double.self) } }
    static func ool(_ m: MachHostReceivedMessage) -> [UInt8] {
        for d in m.descriptors { if case let .ool(data, _, _) = d { return data } }
        return []
    }
    static func ports(_ m: MachHostReceivedMessage) -> [UInt32] {
        m.descriptors.compactMap { if case let .port(name, _) = $0 { return name } else { return nil } }
    }

    /// Register the way a client does (message 71: notification port, process name).
    @discardableResult
    func register(_ c: Client, name: String = "probe") throws -> UInt32 {
        let port = try c.guest.makePort()
        let units = Array(name.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let m = try c.call(71, [1, 0, 9, 0, UInt32(name.utf16.count), 2],
                           descriptors: [.port(name: port, disposition: MachMsgType.makeSend), .ool(data: units)])
        #expect(m.size == 36 && !m.isComplex && Self.word(m.body, 0) == 0)
        return port
    }

    @Test func systemAndDeviceWalk() throws {
        let c = try Client()
        try register(c)
        let dev = AudioObjectModel.deviceID
        // System: version, empty lists, the device list, the defaults.
        #expect(try c.has(1, "vers") == 1)
        let vers = try c.get(16, 1, "vers")
        #expect(vers.size == 40 && Self.word(vers.body, 0) == 0 && Self.word(vers.body, 1) == 1)
        for sel in ["plg#", "box#", "clk#", "tps#", "prs#"] { #expect(try c.u32s(1, sel) == []) }
        #expect(try c.u32s(1, "dev#") == [dev])
        #expect(Self.word(try c.get(16, 1, "dOut").body, 1) == dev)
        #expect(Self.word(try c.get(16, 1, "dIn ").body, 1) == 0)
        #expect(Self.word(try c.get(16, 1, "mlkf").body, 1) == 2)
        let setPower = try c.call(30, [1, fourCC("powh"), Self.glob, 0, 0])
        #expect(setPower.size == 36 && Self.word(setPower.body, 0) == 0)
        // Message 2: the object's port and classes.
        let obj = try c.call(2, [dev])
        #expect(obj.size == 56 && obj.isComplex && Self.ports(obj).count == 1)
        #expect(Self.word(obj.body, 0) == fourCC("adev") && Self.word(obj.body, 1) == fourCC("aobj"))
        let devPort = Self.ports(obj)[0]
        // Requests about the device go to its port.
        let uid = try c.call(21, to: devPort, [dev, fourCC("uid "), Self.glob, 0])
        #expect(uid.size == 56)
        let units = Self.ool(uid)
        #expect(Self.word(uid.body, 0) == UInt32(units.count / 2))
        #expect(String(decoding: stride(from: 0, to: units.count, by: 2).map { UInt16(units[$0]) | UInt16(units[$0 + 1]) << 8 },
                       as: UTF16.self) == AudioObjectModel.deviceUID)
        let rate = try c.get(25, dev, "nsrt")
        #expect(rate.size == 44 && Self.word(rate.body, 0) == 0 && Self.f64(rate.body, 12) == 48_000)
        #expect(try c.u32s(dev, "stm#", Self.outp) == [AudioObjectModel.streamID])
        #expect(try c.u32s(dev, "stm#", Self.inpt) == [])
        #expect(try c.u32s(dev, "ctrl") == [])
        #expect(try c.has(dev, "cust") == 1 && c.u32s(dev, "cust") == [])
        #expect(try c.u32s(dev, "dch2", Self.outp) == [1, 2])
        #expect(try c.has(dev, "dch2", Self.inpt) == 0)
        #expect(try c.has(dev, "srnd", Self.inpt) == 0)
        for sel in ["lisa", "siso", "acom", "rsrc", "zzzz"] { #expect(try c.has(dev, sel) == 0) }
        let layout = try c.call(15, [dev, fourCC("srnd"), Self.outp, 0, 0], descriptors: [.ool(data: [])])
        #expect(layout.size == 56 && Self.ool(layout).count == 52 && Self.word(layout.body, 0) == 52)
        #expect(Self.u32(Self.ool(layout), 8) == 2 && Self.u32(Self.ool(layout), 12) == 1 && Self.u32(Self.ool(layout), 32) == 2)
        #expect(try c.call(14, [dev, fourCC("appv"), Self.outp, 0]).size == 40)
        let vol = try c.call(31, [dev, fourCC("appv"), Self.outp, 0, Float(0.6).bitPattern])
        #expect(vol.size == 36 && Self.word(vol.body, 0) == 0)
        // The 'ioct' description.
        let ioct = try c.plist(dev, "ioct")
        #expect((ioct["device id"] as? NSNumber)?.uint32Value == dev && ioct["master uid"] as? String == AudioObjectModel.deviceUID)
        #expect((ioct["grid-out"] as? [[String: Any]])?.first?["channels"] as? NSNumber == 2)
        // The stream.
        let stream = AudioObjectModel.streamID
        let s = try c.call(2, [stream])
        #expect(Self.word(s.body, 0) == fourCC("astr"))
        #expect(try c.has(stream, "cust") == 0)
        let sdir = try c.get(16, stream, "sdir"), schn = try c.get(16, stream, "schn")
        #expect(Self.word(sdir.body, 1) == 0 && Self.word(schn.body, 1) == 1)
        let fmt = try c.call(15, [stream, fourCC("sfmt"), Self.outp, 0, 0], descriptors: [.ool(data: [])])
        let asbd = Self.ool(fmt)
        #expect(asbd.count == 40 && Self.f64(asbd, 0) == 48_000 && Self.u32(asbd, 8) == fourCC("lpcm") && Self.u32(asbd, 12) == 9)
        #expect(Self.u32(asbd, 16) == 8 && Self.u32(asbd, 24) == 8 && Self.u32(asbd, 28) == 2 && Self.u32(asbd, 32) == 32)
        // A listener (one-way, no reply), then an unknown routine: MIG_BAD_ID.
        try c.guest.send(MachHostOutgoingMessage(remotePort: c.server, id: Self.base + 35,
                                                 body: Self.ndr + [1, fourCC("****"), fourCC("****"), 0xFFFF_FFFF].flatMap(Self.le32)))
        let bad = try c.call(99, [1])
        #expect(bad.size == 36 && Int32(bitPattern: Self.word(bad.body, 0)) == -303)
    }

    @Test func aggregateCreation() throws {
        let c = try Client(pid: 4321)
        try register(c, name: "backboardd")
        let dev = AudioObjectModel.deviceID
        let uid = "iOSSimulatorAudioDevice-4321-0"
        let desc: [String: Any] = [
            "master": AudioObjectModel.deviceUID, "name": uid, "uid": uid, "private": 1,
            "subdevices": [["channels-in": 0, "channels-out": 2, "drift": 1, "name": AudioObjectModel.deviceName,
                            "uid": AudioObjectModel.deviceUID] as [String: Any]],
        ]
        let xml = [UInt8](try PropertyListSerialization.data(fromPropertyList: desc, format: .xml, options: 0))
        let made = try c.call(5, [UInt32(xml.count)], descriptors: [.ool(data: xml)])
        #expect(made.size == 40 && Self.word(made.body, 0) == 0)
        let agg = Self.word(made.body, 1)
        #expect(agg != 0 && agg != dev)
        // It is in this process's device list.
        #expect(try c.u32s(1, "dev#") == [dev, agg])
        let o = try c.call(2, [agg])
        #expect(Self.word(o.body, 0) == fourCC("aagg") && Self.word(o.body, 1) == fourCC("adev"))
        #expect(Self.word(try c.get(16, agg, "tran").body, 1) == fourCC("grup"))
        let sub = try c.u32s(agg, "ownd", qualifier: [])
        #expect(sub.count == 1)
        let so = try c.call(2, [sub[0]])
        #expect(Self.word(so.body, 0) == fourCC("asub") && Self.word(so.body, 1) == fourCC("adev"))
        #expect(try c.has(sub[0], "cust") == 1)
        #expect(try c.u32s(agg, "stm#", Self.outp).count == 1)
        #expect(try c.u32s(agg, "agrp") == [dev])
        // Settable channel preferences and layout.
        #expect(Self.word(try c.call(14, [agg, fourCC("dch2"), Self.outp, 0]).body, 1) == 1)
        let set = try c.call(46, [agg, fourCC("dch2"), Self.outp, 0, 2], descriptors: [.ool(data: [1, 0, 0, 0, 2, 0, 0, 0])])
        #expect(set.size == 36 && Self.word(set.body, 0) == 0)
        let layout = AudioHAL.channelLayout(labels: [0xFFFF_FFFF, 0xFFFF_FFFF])
        let setLayout = try c.call(29, [agg, fourCC("srnd"), Self.outp, 0, 0, UInt32(layout.count)],
                                   descriptors: [.ool(data: []), .ool(data: layout)])
        #expect(setLayout.size == 36 && Self.word(setLayout.body, 0) == 0)
        // The composition and the aggregate's 'ioct'.
        let acom = try c.plist(agg, "acom")
        let entry = try #require((acom["subdevices"] as? [[String: Any]])?.first)
        #expect(entry["drift quality"] as? NSNumber == 127 && entry["latency-out"] as? NSNumber == 0 && entry["don't pad"] != nil)
        let ioct = try c.plist(agg, "ioct")
        #expect((ioct["device id"] as? NSNumber)?.uint32Value == agg && ioct["LDCM"] as? Bool == false)
        // The same UID again: 'nope'.
        let again = try c.call(5, [UInt32(xml.count)], descriptors: [.ool(data: xml)])
        #expect(Self.word(again.body, 0) == fourCC("nope"))
        // Another process does not see the private aggregate.
        let other = try MachHostTask.makeGuest(c.system, pid: 999)
        let otherServer = try c.system.hostTask.give(c.service.servicePort, disposition: MachMsgType.copySend, to: other.ipc)
        let otherReply = try other.makePort()
        try other.send(MachHostOutgoingMessage(remotePort: otherServer, localPort: otherReply,
                                               localDisposition: MachMsgType.makeSendOnce, id: Self.base + 19,
                                               body: Self.ndr + [1, fourCC("dev#"), Self.glob, 0].flatMap(Self.le32)))
        let list = try other.receive(on: otherReply, timeout: 5_000_000_000)
        #expect(Self.ool(list) == Self.le32(dev))
    }

    @Test func ioCycleAndWorkgroup() throws {
        let c = try Client(pid: 777)
        try register(c)
        let dev = AudioObjectModel.deviceID
        // An IO context from the device's description.
        let desc = Self.ool(try c.get(27, dev, "ioct"))
        let made = try c.call(3, [UInt32(desc.count)], descriptors: [.ool(data: desc)])
        #expect(made.size == 40 && Self.word(made.body, 0) == 0)
        let ctx = Self.word(made.body, 1)
        let o = try c.call(2, [ctx])
        #expect(Self.word(o.body, 0) == fourCC("ioct") && Self.word(o.body, 1) == fourCC("aobj"))
        let grid = try c.call(15, [ctx, fourCC("grid"), Self.outp, 0, 0], descriptors: [.ool(data: [])])
        #expect(Self.ool(grid).count == 56 && Self.u32(Self.ool(grid), 0) == dev && Self.f64(Self.ool(grid), 16) == 48_000)
        #expect(Self.ool(try c.call(15, [ctx, fourCC("grid"), Self.inpt, 0, 0], descriptors: [.ool(data: [])])).isEmpty)
        #expect(Self.word(try c.get(16, ctx, "fsiz").body, 1) == 512)
        let range = Self.ool(try c.call(15, [ctx, fourCC("fsz#"), Self.glob, 0, 0], descriptors: [.ool(data: [])]))
        #expect(range.count == 16 && Self.f64(range, 0) == 14 && Self.f64(range, 8) == 1024)
        let usage = try c.call(46, [ctx, fourCC("guse"), Self.outp, 0, 2], descriptors: [.ool(data: [1, 0, 0, 0, 1, 0, 0, 0])])
        #expect(Self.word(usage.body, 0) == 0)
        let port = try c.guest.makePort()
        let setPort = try c.call(10, [ctx], descriptors: [.port(name: port, disposition: MachMsgType.makeSend)])
        #expect(setPort.size == 36 && Self.word(setPort.body, 0) == 0)
        // Start: the IO port, the region's memory entry and its size.
        let wake = try c.guest.makePort()
        let start = try c.call(63, [ctx], descriptors: [.port(name: wake, disposition: MachMsgType.makeSend)])
        #expect(start.size == 64 && Self.ports(start).count == 2 && Self.word(start.body, 0) == 65_536)
        let ioPort = Self.ports(start)[0]
        let entry = try #require(c.guest.memoryEntry(Self.ports(start)[1]))
        #expect(entry.size == 65_536)
        let region = entry.object.host
        func f64(_ at: Int) -> Double { region.load(fromByteOffset: at, as: Double.self) }
        func u32(_ at: Int) -> UInt32 { region.load(fromByteOffset: at, as: UInt32.self) }
        func u64(_ at: Int) -> UInt64 { region.load(fromByteOffset: at, as: UInt64.self) }
        #expect(f64(0) == 500 && f64(8) == 1.0 / 500 && f64(0x10) == 1 && u32(0x18) == 512)
        #expect(u32(0x4000) == 1 && u32(0x4004) == 8_192)
        // The workgroup: a joinable CoreAudio work interval.
        let wg = try c.call(59, [ctx])
        #expect(wg.size == 40 && wg.isComplex && wg.body.isEmpty && Self.ports(wg).count == 1)
        let wi = try #require(c.guest.workInterval(named: Self.ports(wg)[0]))
        #expect(wi.createFlags & WorkIntervalABI.flagJoinable != 0 && wi.createFlags & WorkIntervalABI.typeMask == WorkIntervalABI.typeCoreAudio)
        // A second ask gives the same workgroup.
        #expect(c.guest.workInterval(named: Self.ports(try c.call(59, [ctx]))[0]) === wi)

        // The cycle: client message n → wake n + 1, paced at 512 frames per 48 kHz.
        func cycle(_ id: UInt32) throws -> (MachHostReceivedMessage, UInt64) {
            try c.guest.send(MachHostOutgoingMessage(remotePort: ioPort, id: Int32(bitPattern: id)))
            let w = try c.guest.receive(on: wake, timeout: 5_000_000_000)
            return (w, MachTimebase.hostMonotonicNanoseconds())
        }
        let (w1, t1) = try cycle(0)
        #expect(w1.id == 1 && w1.size == 24 && !w1.isComplex && w1.body.isEmpty)
        #expect(u32(0x124) == 1 && f64(0x60) == 0 && f64(0xE0) == 512 && f64(0xA0) == -512)
        #expect(u32(0x60 + 56) == 7 && u32(0x20 + 56) == 3 && f64(0x60 + 16) == 1)
        let host0 = u64(0x68)
        #expect(u64(0xE8) == host0 + 512 * 500)
        // Output for the cycle.
        let out = region.advanced(by: 0x8000).assumingMemoryBound(to: Float.self)
        for i in 0..<1024 { out[i] = 0.25 }
        let (w2, t2) = try cycle(1)
        #expect(w2.id == 2 && u32(0x124) == 2 && f64(0x60) == 512 && u64(0x68) == host0 + 512 * 500)
        #expect(t2 - t1 >= 8_000_000)  // paced: about 10.7 ms after the first wake
        // Late by more than a cycle: wake 0 restarts the numbering at the clock's cycle.
        Thread.sleep(forTimeInterval: 0.05)
        let (w3, _) = try cycle(2)
        #expect(w3.id == 0 && u32(0x124) == 0 && f64(0x60) >= 2048)
        #expect(f64(0x60).truncatingRemainder(dividingBy: 512) == 0)
        let (w4, _) = try cycle(0)
        #expect(w4.id == 1)
        #expect(c.service.cycles(of: ctx) == 4)
        // Stop.
        let stop = try c.call(12, [ctx])
        #expect(stop.size == 36 && Self.word(stop.body, 0) == 0)
        #expect(c.service.runningContexts.isEmpty)
    }

    @Test func aggregateRegionAndClientDeath() throws {
        let c = try Client(pid: 55)
        let regPort = try register(c, name: "systemsoundserver-simd")
        let uid = "iOSSimulatorAudioDevice-55-0"
        let xml = [UInt8](try PropertyListSerialization.data(fromPropertyList: ["uid": uid, "name": uid, "master": AudioObjectModel.deviceUID,
                                                                                 "private": 1], format: .xml, options: 0))
        let agg = Self.word(try c.call(5, [UInt32(xml.count)], descriptors: [.ool(data: xml)]).body, 1)
        let desc = Self.ool(try c.get(27, agg, "ioct"))
        let ctx = Self.word(try c.call(3, [UInt32(desc.count)], descriptors: [.ool(data: desc)]).body, 1)
        let wake = try c.guest.makePort()
        let start = try c.call(63, [ctx], descriptors: [.port(name: wake, disposition: MachMsgType.makeSend)])
        #expect(start.size == 64 && Self.word(start.body, 0) == 245_760)
        let entry = try #require(c.guest.memoryEntry(Self.ports(start)[1]))
        #expect(entry.size == 245_760 && entry.object.host.load(fromByteOffset: 0x4004, as: UInt32.self) == 196_608)
        #expect(c.service.aggregateCount == 1 && c.service.runningContexts == [ctx])
        // The client's registration port dies: its aggregate and IO go.
        try c.guest.destroyPort(regPort)
        let deadline = Date().addingTimeInterval(5)
        while c.service.aggregateCount > 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(c.service.aggregateCount == 0 && c.service.runningContexts.isEmpty)
    }

    /// A snapshot keeps the objects, the clients and running IO; the service
    /// of the restored run takes them back and wakes the client with 0.
    @Test func snapshotRoundTrip() throws {
        let c = try Client(pid: 88)
        try register(c, name: "backboardd")
        let uid = "iOSSimulatorAudioDevice-88-0"
        let xml = [UInt8](try PropertyListSerialization.data(fromPropertyList: ["uid": uid, "name": uid, "master": AudioObjectModel.deviceUID,
                                                                                 "private": 1], format: .xml, options: 0))
        let agg = Self.word(try c.call(5, [UInt32(xml.count)], descriptors: [.ool(data: xml)]).body, 1)
        let desc = Self.ool(try c.get(27, agg, "ioct"))
        let ctx = Self.word(try c.call(3, [UInt32(desc.count)], descriptors: [.ool(data: desc)]).body, 1)
        let ctxPort = Self.ports(try c.call(2, [ctx]))[0]
        let wake = try c.guest.makePort()
        let start = try c.call(63, [ctx], descriptors: [.port(name: wake, disposition: MachMsgType.makeSend)])
        let ioPort = Self.ports(start)[0]
        let region = try #require(c.guest.memoryEntry(Self.ports(start)[1])).object.host
        try c.guest.send(MachHostOutgoingMessage(remotePort: ioPort, id: 0))
        #expect(try c.guest.receive(on: wake, timeout: 5_000_000_000).id == 1)
        let saved = try #require(c.service.trySnapshotState())
        c.service.stop()
        Thread.sleep(forTimeInterval: 0.3)  // its thread leaves its receive
        // The restored run's service over the same host task.
        let b = try AudioHostService(host: c.system.hostTask, log: { _ in }, capturePath: nil)
        b.start()
        defer { b.stop() }
        #expect(try b.restoreState(SnapshotFieldReader(saved.bytes)) == 1)
        #expect(b.aggregateCount == 1 && b.runningContexts == [ctx])
        b.resumeRestoredIO()
        let w = try c.guest.receive(on: wake, timeout: 5_000_000_000)
        #expect(w.id == 0 && region.load(fromByteOffset: 0x124, as: UInt32.self) == 0)
        #expect(region.load(fromByteOffset: 0x60, as: Double.self) == 512)  // the cycle after the saved one
        // Requests on the restored object port are served; the cycle goes on.
        let fsiz = try c.call(16, to: ctxPort, [ctx, fourCC("fsiz"), Self.glob, 0])
        #expect(Self.word(fsiz.body, 1) == 512)
        try c.guest.send(MachHostOutgoingMessage(remotePort: ioPort, id: 0))
        #expect(try c.guest.receive(on: wake, timeout: 5_000_000_000).id == 1)
    }

    @Test func captureWriterMixesAndCollapsesGaps() throws {
        let path = NSTemporaryDirectory() + "ycode-audio-\(UUID().uuidString).wav"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let w = try AudioCaptureWriter(path: path, sampleRate: 48_000, channels: 2)
        let t0: UInt64 = 1_000_000_000
        let block = [Float](repeating: 0.5, count: 1024)
        // Two clients play the same 512 frames: they add up.
        w.add(block, at: t0)
        w.add(block, at: t0)
        // The next block, 10.67 ms later.
        w.add([Float](repeating: -0.25, count: 1024), at: t0 + 10_666_667)
        // Five seconds of nothing, then a block: the gap is left out.
        w.add(block, at: t0 + 5_000_000_000)
        w.close()
        let data = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(Array(data[0..<4]) == Array("RIFF".utf8) && Array(data[8..<12]) == Array("WAVE".utf8))
        #expect(Self.u32(data, 24) == 48_000 && data[22] == 2 && data[34] == 16)
        let frames = Int(Self.u32(data, 40)) / 4
        #expect(frames == 1536 && data.count == 44 + frames * 4)
        func sample(_ i: Int) -> Int16 { Int16(bitPattern: UInt16(data[44 + 2 * i]) | UInt16(data[45 + 2 * i]) << 8) }
        #expect(sample(0) == 32767 && sample(1023) == 32767)  // 0.5 + 0.5, clipped at full scale
        #expect(sample(1024) == Int16(-0.25 * 32767))
        #expect(sample(2048) == Int16(0.5 * 32767))
        #expect(w.nonZeroSamples == 4096 && w.peak == 0.5)
    }

    @Test func modelAnswersHasZeroForAnythingElse() {
        let m = AudioObjectModel()
        #expect(m.value(1, AudioPropertyAddress("dOut"), pid: 1) == .u32(AudioObjectModel.deviceID))
        #expect(m.value(AudioObjectModel.deviceID, AudioPropertyAddress("tran"), pid: 1) == .u32(fourCC("bltn")))
        #expect(m.value(AudioObjectModel.deviceID, AudioPropertyAddress("abcd"), pid: 1) == nil)
        #expect(m.value(12345, AudioPropertyAddress("clas"), pid: 1) == nil)
        #expect(m.set(1, AudioPropertyAddress("dev#"), .u32s([])) == AudioHAL.unknownProperty)
        // 'fsiz' of an IO context is settable within the range.
        let desc = m.ioContextDescription(AudioObjectModel.deviceID)
        guard case let .success(ctx) = m.createIOContext(description: desc, pid: 1) else {
            Issue.record("no context")
            return
        }
        #expect(m.set(ctx, AudioPropertyAddress("fsiz"), .u32(256)) == 0 && m.context(ctx)?.bufferFrames == 256)
        #expect(m.set(ctx, AudioPropertyAddress("fsiz"), .u32(4096)) == AudioHAL.illegalOperation)
        #expect(fourCCText(fourCC("dev#")) == "'dev#'")
    }
}

extension MachHostTask {
    /// A second host task standing for a guest process (tests).
    static func makeGuest(_ system: DarwinSystem, pid: Int32) throws -> MachHostTask {
        let t = system.lock.withLock { MachHostTask(lock: system.lock, system: system.mach, log: { _ in }) }
        t.pid = pid
        return t
    }
}
