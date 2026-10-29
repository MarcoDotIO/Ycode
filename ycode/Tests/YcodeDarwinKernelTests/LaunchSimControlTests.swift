import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// The control-channel client (launch-sim-control.md): the spawn blob, and
/// requests and replies against a fake service served by the host task.
@Suite struct LaunchSimControlTests {
    @Test func spawnBlobMatchesTheSpecExample() {
        // launch-sim-control.md §4, the 221-byte example.
        let a = LaunchSimSpawnAttributes(path: "/tmp/ycode-R3/lsguest", argv: ["lsguest-raw", "com.ycode.rawsvc"],
                                         environment: ["YC_RAW=1"], workingDirectory: "/tmp")
        let b = a.blob
        #expect(b.count == 221)
        func w(_ i: Int) -> UInt32 { b.readLE(UInt32.self, at: 4 * i) }
        #expect(w(0) == 221 && w(1) == 0 && w(2) == 2 && w(3) == 0x16 && w(4) == 1 && w(5) == 0x33)
        #expect(w(6) == 0 && w(7) == 0 && w(14) == 0x3C && w(23) == 0 && w(24) == 0x400)
        for i in [8, 9, 10, 11, 12, 13, 15, 22, 25, 38] { #expect(w(i) == 0) }
        let region = Array(b[156...])
        #expect(region == Array("/tmp/ycode-R3/lsguest\0lsguest-raw\0com.ycode.rawsvc\0YC_RAW=1\0/tmp\0".utf8))
        // CPU preference and the suspended flag.
        let c = LaunchSimSpawnAttributes(path: "/x", argv: [], cpuType: 0x0100_000C, startSuspended: true).blob
        #expect(c.readLE(UInt32.self, at: 24) == 1 && c.readLE(UInt32.self, at: 28) == 3)
        #expect(c.readLE(UInt32.self, at: 92) == 1 && c.count == 156 + 3 + 8)
        #expect(c.readLE(UInt32.self, at: 159) == 0x0100_000C && c.readLE(UInt32.self, at: 163) == 0xFFFF_FFFF)
    }

    /// Registrations queued before launchd_sim reads its port: the queue
    /// holds five; the sixth fails at once instead of waiting 5 s
    /// (visionos.md §10.19.3), so the session registers it later.
    @Test func aFullQueueFailsAtOnce() throws {
        let w = TaskWorld()
        let host = w.system.hostTask
        let service = try host.makePort(sendRight: true)
        let control = LaunchSimControl(host: host, channel: service, log: { _ in })
        let target = try host.makePort(sendRight: true)
        for i in 0..<5 { _ = try control.queueRegistration("name.\(i)", port: target) }
        let began = Date()
        #expect(throws: (any Error).self) { _ = try control.queueRegistration("name.5", port: target) }
        #expect(Date().timeIntervalSince(began) < 1)
    }

    @Test func requestsAndReplies() throws {
        let w = TaskWorld()
        let host = w.system.hostTask
        let service = try host.makePort(sendRight: true)
        let control = LaunchSimControl(host: host, channel: service, log: { _ in })
        // The fake launchd_sim: answers each request by id.
        let served = ResultBox<[Int32]>()
        served.value = []
        let server = Thread {
            while true {
                guard let m = try? host.receive(on: service, timeout: 3_000_000_000) else { return }
                served.value!.append(m.id)
                let ndr: [UInt8] = [0, 0, 0, 0, 1, 0, 0, 0]
                switch m.id {
                case 700:
                    try? host.reply(to: m, body: ndr + le32(0))
                case 703:
                    let name = String(decoding: m.body[8...].prefix { $0 != 0 }, as: UTF8.self)
                    if name == "SET" {
                        try? host.reply(to: m, body: ndr + le32(0) + Array("value".utf8) + [UInt8](repeating: 0, count: 123))
                    } else {
                        try? host.reply(to: m, body: ndr + le32(0xC003))
                    }
                case 704:
                    guard case let .ool(data, _, _)? = m.descriptors.first, m.descriptors.count == 4,
                          m.body.readLE(UInt32.self, at: 8) == UInt32(data.count) else {
                        try? host.reply(to: m, body: ndr + le32(111) + le32(UInt32(bitPattern: -1)))
                        continue
                    }
                    try? host.reply(to: m, body: ndr + le32(0) + le32(321))
                case 705:
                    try? host.reply(to: m, body: ndr + le32(0) + le32(0x0700))
                default:
                    try? host.reply(to: m, body: ndr + le32(0xC000 | 45))
                }
                var rest = m
                rest.replyPort = 0
                host.discard(rest)
            }
        }
        server.start()
        try control.bindSession()
        #expect(control.isBound)
        #expect(try control.domainEnvironment("SET") == "value")
        #expect(try control.domainEnvironment("UNSET") == nil)
        let pid = try control.spawn(LaunchSimSpawnAttributes(path: "/bin/true", argv: ["true"]), stdin: 0, stdout: 0, stderr: 0)
        #expect(pid == 321)
        #expect(try control.waitpid(pid) == 0x0700)
        do {
            try control.unregisterEndpoint("nothing")
            Issue.record("unregister should fail")
        } catch let e as LaunchSimControlError {
            #expect(e.errno == 45)
        }
        control.endSession()
        #expect(!control.isBound)
        server.cancel()
        #expect(served.value == [700, 703, 703, 704, 705, 709])
    }
}
