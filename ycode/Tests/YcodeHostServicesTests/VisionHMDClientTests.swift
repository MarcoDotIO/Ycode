// The host end of vhmdd (visionos.md §5.5.3, §5.5.4; VisionHMDClient), driven
// against a fake vhmdd in a second host task: the connection hand-shake, the
// `cmd` dictionaries in the sim-to-host encoding, replies and events.

import Foundation
import Testing
@testable import YcodeDarwinKernel
@testable import YcodeHostServices
import YcodeDisplayStream
import YcodeXPC

@Suite(.serialized) struct VisionHMDClientTests {
    @Test func roomsFromEnvironmentsData() {
        let json = #"{"MuseumDay":{"displayName":"Museum (Day)","thumbnailURL":"file:///x.png"},"KitchenNight":{"displayName":"Kitchen (Night)"}}"#
        let rooms = VisionHMDClient.rooms(fromJSON: json)
        #expect(rooms.map(\.key) == ["KitchenNight", "MuseumDay"])
        #expect(rooms.last?.displayName == "Museum (Day)")
        #expect(VisionHMDClient.rooms(fromJSON: "not json").isEmpty)
        #expect(VisionHMDClient.knownRooms.count == 6)
    }

    /// A fake vhmdd: answers get_pose with its pose, keeps set_pose's, and for
    /// request_environments / set_active_environment sends the events of §5.5.4.
    final class FakeVHMDD: @unchecked Sendable {
        let task: MachHostTask
        let service: UInt32
        var pose = SpatialPose.identity.matrixBytes
        var commands: [String] = []
        var sawSim2Host = false
        let lock = NSLock()
        init(task: MachHostTask) throws {
            self.task = task
            service = try task.makePort(qlimit: 16)
        }
        func run(until: Date) {
            var connection: UInt32?
            var events: UInt32?
            while Date() < until {
                let ports = [service] + (connection.map { [$0] } ?? [])
                for p in ports {
                    guard let m = try? task.receive(on: p, timeout: 20_000_000) else { continue }
                    if m.id == 0x7730_3074, m.descriptors.count == 2,
                       case let .port(c, _) = m.descriptors[0], case let .port(e, _) = m.descriptors[1] {
                        connection = c
                        events = e
                        continue
                    }
                    guard m.id == 0x1000_0000 else { continue }
                    let magic = m.body.count >= 4 ? m.body.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } : 0
                    guard let object = try? XPCWire.decode(body: m.body, descriptors: []), case let .dictionary(d) = object,
                          let cmd = d["cmd"]?.stringValue else { continue }
                    lock.withLock {
                        commands.append(cmd)
                        if magic == XPCWire.sim2hostMagic { sawSim2Host = true }
                    }
                    var reply = XPCDict()
                    reply.append(key: "majorVersion", value: .uint64(1))
                    reply.append(key: "minorVersion", value: .uint64(1))
                    var after: [XPCDict] = []
                    switch cmd {
                    case "get_pose": reply.append(key: "pose", value: .data(lock.withLock { pose }))
                    case "set_pose": if let p = d["pose"]?.dataValue { lock.withLock { pose = p } }
                    case "request_environments":
                        after = [["cmd": "environments_changed",
                                  "environments_data": .string(#"{"LivingRoomDay":{"displayName":"Living Room (Day)"},"MuseumDay":{"displayName":"Museum (Day)"}}"#)]]
                    case "set_active_environment":
                        let id = d["environment_id"]?.stringValue ?? ""
                        after = [["cmd": "active_environment_changed", "environment_id": .string(id)],
                                 ["cmd": "active_environment_changed", "environment_id": .string(id)],
                                 ["cmd": "synthetic_environment_did_load", "environment_id": .string(id), "load_error": ""]]
                    default: break
                    }
                    if let r = try? XPCWire.encode(.dictionary(reply), magic: XPCWire.sim2hostMagic) {
                        try? task.reply(to: m, id: 0x2000_0000, body: r.body)
                    }
                    for event in after {
                        guard let events, let e = try? XPCWire.encode(.dictionary(event), magic: XPCWire.sim2hostMagic) else { continue }
                        try? task.send(MachHostOutgoingMessage(remotePort: events, remoteDisposition: MachMsgType.copySend,
                                                               id: 0x1000_0000, body: e.body), timeout: 1_000_000_000)
                    }
                }
            }
        }
    }

    @Test func commandsAndEvents() throws {
        let system = DarwinSystem()
        let host = system.hostTask
        let guestTask = system.lock.withLock { MachHostTask(lock: system.lock, system: system.mach, log: { _ in }) }
        let fake = try FakeVHMDD(task: guestTask)
        let serverThread = Thread { fake.run(until: Date().addingTimeInterval(20)) }
        serverThread.start()
        var logs: [String] = []
        let logLock = NSLock()
        let client = VisionHMDClient(host: host, find: { try guestTask.give(fake.service, disposition: MachMsgType.makeSend, to: host.ipc) },
                                     log: { line in logLock.withLock { logs.append(line) } })
        defer { client.stop() }
        // Identity after boot (§5.5.3).
        #expect(try client.getPose() == .identity)
        // set_pose: the same matrix comes back from get_pose.
        let pose = SpatialPose(position: SpatialVector(0.5, 0.2, -1), rotation: SpatialQuaternion(axis: SpatialVector(0, 1, 0), radians: 0.3))
        try client.setPoseNow(pose)
        let back = try client.getPose()
        #expect((back.position - pose.position).length < 1e-6 && (back.forward - pose.forward).length < 1e-5)
        // The queued path (latest wins) reaches vhmdd too.
        client.setPose(SpatialPose(position: SpatialVector(0, 0, 2)))
        let deadline = Date().addingTimeInterval(5)
        while client.posesSent < 1 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(try client.getPose().position == SpatialVector(0, 0, 2))
        // Rooms: the list arrives as an event after the empty reply.
        let rooms = try client.requestEnvironments()
        #expect(rooms.map(\.key) == ["LivingRoomDay", "MuseumDay"])
        // A live switch waits for synthetic_environment_did_load.
        #expect(try client.setActiveEnvironment("MuseumDay", wait: 5) == "")
        #expect(client.activeRoom == "MuseumDay")
        #expect(fake.lock.withLock { fake.sawSim2Host && fake.commands.contains("set_active_environment") })
    }
}
