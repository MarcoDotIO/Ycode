import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel
@testable import YcodeHostServices

/// The file-event service (fsevents-host.md): requests sent by the host task
/// to the service port, as the guest's client library sends them, and the
/// event messages it gets back. The service is not started: the tests call
/// `handle`, `changed` and `flush` themselves.
@Suite struct FSEventsHostServiceTests {
    typealias Wire = FSEventsHostService.Wire
    static let dataDevice: UInt32 = 0x0100_0010

    let host = DarwinSystem().hostTask
    let dir: String

    init() throws {
        dir = NSTemporaryDirectory() + "ycode-fse-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    func service(identity: ((String) -> (inode: UInt64, documentID: UInt32)?)? = nil) throws -> FSEventsHostService {
        try FSEventsHostService(host: host, configuration: .init(statePath: dir + "/state.plist", volumes: [Self.dataDevice: "/"],
                                                                 identity: identity), log: { _ in })
    }

    static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }
    static func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }
    static let ndr: [UInt8] = [0, 0, 0, 0, 1, 0, 0, 0]

    /// Sends a request to `port` with a reply port; the service handles it
    /// (with `pid` as the sender); returns the reply.
    func call(_ s: FSEventsHostService, port: UInt32, id: Int32, body: [UInt8] = ndr,
              descriptors: [MachHostDescriptor] = [], pid: Int32 = 321) throws -> MachHostReceivedMessage {
        let reply = try host.makePort()
        try host.send(MachHostOutgoingMessage(remotePort: port, remoteDisposition: MachMsgType.makeSend, localPort: reply,
                                              localDisposition: MachMsgType.makeSendOnce, id: id, descriptors: descriptors,
                                              body: body))
        var m = try host.receive(on: port, timeout: 0)
        m.sender = MachAuditToken(words: [501, 501, 20, 501, 20, UInt32(bitPattern: pid), 1, 1])
        s.handle(m)
        let r = try host.receive(on: reply, timeout: 0)
        try? host.destroyPort(reply)
        return r
    }

    func retCode(_ r: MachHostReceivedMessage) -> Int32 { r.body.readLE(Int32.self, at: 8) }

    /// A 66000 request (§3.1): (client receive right, stream send right).
    func register(_ s: FSEventsHostService, paths: [String], exclusions: [String] = [], dev: UInt32 = 0,
                  flags: UInt32, latency: UInt64 = 0, since: UInt64 = .max, pid: Int32 = 321) throws -> (client: UInt32, stream: UInt32) {
        func pack(_ list: [String]) -> ([UInt8], [UInt8]) {
            var offsets: [UInt8] = [], bytes: [UInt8] = []
            for p in list { offsets += Self.le32(UInt32(bytes.count)); bytes += Array(p.utf8) + [0] }
            return (offsets, bytes)
        }
        let (po, pb) = pack(paths), (eo, eb) = pack(exclusions)
        var body = Self.ndr + Self.le32(dev) + Self.le32(UInt32(paths.count)) + Self.le32(UInt32(paths.count))
        body += Self.le32(UInt32(pb.count)) + Self.le32(UInt32(exclusions.count)) + Self.le32(UInt32(exclusions.count))
        body += Self.le32(UInt32(eb.count)) + Self.le64(latency) + Self.le32(flags) + Self.le64(since)
        #expect(body.count == 56)
        let client = try host.makePort()
        let r = try call(s, port: s.servicePort, id: 66000, body: body,
                         descriptors: [.port(name: client, disposition: MachMsgType.makeSend), .ool(data: po), .ool(data: pb),
                                       .ool(data: eo), .ool(data: eb)], pid: pid)
        #expect(r.id == 66100 && r.isComplex && r.descriptors.count == 1)
        guard case let .port(stream, _) = r.descriptors.first else { throw MachHostError.timedOut }
        return (client, stream)
    }

    /// The events of one 67000 message on `client`, or nil when none waits.
    func events(_ client: UInt32) -> [(path: String, flags: UInt32, id: UInt64, extra: [UInt8])]? {
        guard let m = try? host.receive(on: client, timeout: 0) else { return nil }
        #expect(m.id == 67000 && m.descriptors.count == 4 && m.replyPort == 0)
        let ool = m.descriptors.map { d -> [UInt8] in if case let .ool(data, _, _) = d { return data } else { return [] } }
        let n = Int(m.body.readLE(UInt32.self, at: 8))
        #expect(m.body.count == 28 && Int(m.body.readLE(UInt32.self, at: 24)) == ool[3].count)
        return (0..<n).map { i in
            let at = Int(ool[0].readLE(UInt32.self, at: 4 * i))
            let end = i + 1 < n ? Int(ool[0].readLE(UInt32.self, at: 4 * (i + 1))) : ool[3].count
            let path = String(decoding: ool[3][at...].prefix { $0 != 0 }, as: UTF8.self)
            let extra = Array(ool[3][(at + path.utf8.count + 1)..<end])
            return (path, ool[1].readLE(UInt32.self, at: 4 * i), ool[2].readLE(UInt64.self, at: 8 * i), extra)
        }
    }

    @Test func deviceUUIDAndEventIDsPersist() throws {
        let a = try service()
        let uuid = try call(a, port: a.servicePort, id: 66002, body: Self.ndr + Self.le32(Self.dataDevice))
        #expect(uuid.id == 66102 && uuid.body.count == 48 && retCode(uuid) == 0)
        let text = String(decoding: uuid.body[12..<48], as: UTF8.self)
        #expect(UUID(uuidString: text) != nil && text == a.storeUUID)
        let unknown = try call(a, port: a.servicePort, id: 66002, body: Self.ndr + Self.le32(0x0100_0011))
        #expect(Array(unknown.body[12..<48]) == Array("NO-UUID-UNKNOWN-DEVICE".utf8) + [UInt8](repeating: 0, count: 14))
        let current = try call(a, port: a.servicePort, id: 66003)
        #expect(current.id == 66103 && retCode(current) == 0)
        let first = current.body.readLE(UInt64.self, at: 12)
        #expect(first >= 1000)
        // 66004 knows no history; anything else is MIG_BAD_ID.
        let before = try call(a, port: a.servicePort, id: 66004, body: Self.ndr + Self.le32(Self.dataDevice) + Self.le64(0))
        #expect(before.id == 66104 && retCode(before) == 0 && before.body.readLE(UInt64.self, at: 12) == 0)
        #expect(retCode(try call(a, port: a.servicePort, id: 66005)) == -303)
        // A new instance (the next boot): same UUID, ids never go back.
        a.stop()
        let b = try service()
        #expect(b.storeUUID == a.storeUUID && b.currentEventID > first)
        b.stop()
    }

    @Test func registerFlushStopAndHistoryDone() throws {
        let s = try service(identity: { _ in (inode: 77, documentID: 9) })
        // A stream since an old id gets HistoryDone with that id (§5).
        let (client, stream) = try register(s, paths: ["/data/Docs"], flags: 0x1F1, latency: 200_000, since: 1234)
        let history = try #require(events(client))
        #expect(history.count == 1 && history[0].path == "/data/Docs" && history[0].flags == Wire.historyDone && history[0].id == 1234)
        #expect(history[0].extra.isEmpty)
        // A change below it, by another process, then by the stream's own (MarkSelf).
        s.changed(FileChange(kind: .created, item: .file, path: "/data/Docs/a.txt", pid: 99))
        s.changed(FileChange(kind: .modified, item: .file, path: "/data/Docs/a.txt", pid: 99))
        s.changed(FileChange(kind: .created, item: .directory, path: "/data/Docs/sub", pid: 321))
        s.changed(FileChange(kind: .modified, item: .file, path: "/data/Other/b", pid: 99))   // not watched
        #expect(events(client) == nil)                                                       // waits for the latency
        // FlushSync: the events now, coalesced per path, then the last id.
        let flushed = try call(s, port: stream, id: 66001)
        let got = try #require(events(client))
        #expect(got.map(\.path) == ["/data/Docs/a.txt", "/data/Docs/sub"])
        #expect(got[0].flags == Wire.created | Wire.modified | Wire.file)
        #expect(got[1].flags == Wire.createdDirectory | Wire.directory | Wire.ownEvent)
        #expect(got[1].id == got[0].id + 1)
        #expect(got[0].extra == Self.le64(77) + Self.le32(9))                                 // UseExtendedData
        #expect(flushed.id == 66101 && retCode(flushed) == 0, "\(flushed.id) \(flushed.body)")
        #expect(flushed.body.readLE(UInt64.self, at: 12) == got[1].id, "\(got.map(\.id))")
        // Stop: nothing more.
        let stopped = try call(s, port: stream, id: 66006)
        #expect(stopped.id == 66106 && retCode(stopped) == 0 && stopped.body.count == 12)
        s.changed(FileChange(kind: .removed, item: .file, path: "/data/Docs/a.txt", pid: 99))
        s.flush(stream)
        #expect(events(client) == nil)
        // The client drops its send right: the stream ends.
        try host.deallocate(stream)
        let notice = try host.receive(on: stream, timeout: 0)
        #expect(notice.id == MachNotify.noSenders)
        s.handle(notice)
        #expect(s.snapshotStreams.isEmpty)
    }

    @Test func directoryLevelRelativeIgnoreSelfAndExclusions() throws {
        let s = try service()
        // Directory-level (no FileEvents), relative to the data device, IgnoreSelf, one exclusion.
        let (client, stream) = try register(s, paths: ["data/Library"], exclusions: ["data/Library/Caches"],
                                            dev: Self.dataDevice, flags: 0x8, latency: 0)
        s.changed(FileChange(kind: .modified, item: .file, path: "/data/Library/Preferences/x.plist", pid: 99))
        s.changed(FileChange(kind: .created, item: .file, path: "/data/Library/Preferences/y.plist", pid: 99))
        s.changed(FileChange(kind: .modified, item: .file, path: "/data/Library/Caches/z", pid: 99))       // excluded
        s.changed(FileChange(kind: .modified, item: .file, path: "/data/Library/Preferences/own", pid: 321)) // own: ignored
        s.changed(FileChange(kind: .cloned, item: .file, path: "/data/Library/c", pid: 99))
        s.flush(stream)
        let got = try #require(events(client))
        #expect(got.map(\.path) == ["data/Library/Preferences/", "data/Library/"])
        #expect(got.map(\.flags) == [0, Wire.cloned])
        #expect(got.allSatisfy { $0.extra.isEmpty })
    }

    @Test func wireFlagsOfEachChange() {
        func f(_ k: FileChange.Kind, _ i: FileChange.Item) -> UInt32 {
            FSEventsHostService.wireFlags(FileChange(kind: k, item: i, path: "/x", pid: 1))
        }
        // §3.4 examples: a new file 0x00800011 (+ OwnEvent), mkdir 0x01000080, rmdir 0x01000002.
        #expect(f(.created, .file) | f(.modified, .file) == 0x0080_0011)
        #expect(f(.created, .directory) == 0x0100_0080 && f(.removed, .directory) == 0x0100_0002)
        #expect(f(.owner, .file) == 0x0080_0100 && f(.extendedAttribute, .file) == 0x0080_0200)
        #expect(f(.renamed, .symbolicLink) == 0x0040_0008 && f(.cloned, .file) == 0x0080_4000)
        #expect(f(.inodeMetadata, .other) == 0x4)
    }

    @Test func malformedRegistrationIsRefused() throws {
        let s = try service()
        let r = try call(s, port: s.servicePort, id: 66000, body: Self.ndr)
        #expect(r.id == 66100 && !r.isComplex && retCode(r) == -304)
        #expect(s.snapshotStreams.isEmpty)
    }

    @Test func snapshotRecordsRoundTrip() throws {
        let s = try service()
        let (_, stream) = try register(s, paths: ["/data/A", "/data/B/"], exclusions: ["/data/A/x"], flags: 0x10, latency: 5)
        let list = s.snapshotStreams
        #expect(list.count == 1 && list[0].port == stream && list[0].registered == ["/data/A", "/data/B/"])
        #expect(list[0].canonical == ["/data/A", "/data/B"] && list[0].exclusions == ["/data/A/x"] && list[0].pid == 321)
        let t = try service()
        t.restoreStreams(list)
        #expect(t.snapshotStreams == list)
    }
}
