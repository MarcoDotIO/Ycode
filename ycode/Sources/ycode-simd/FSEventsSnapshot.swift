// The file-event service's streams in a snapshot's host-service record
// (snapshot.md §9; fsevents-host.md, "Ycode implementation"): one nested
// entry per stream, under ST_HostService.sessions.

#if os(Linux) && arch(arm64)
import YcodeDarwinKernel
import YcodeHostServices

enum FSEventsSnapshot {
    enum Tag {
        static let port: UInt16 = 1, client: UInt16 = 2, pid: UInt16 = 3, dev: UInt16 = 4, flags: UInt16 = 5
        static let latency: UInt16 = 6, lastID: UInt16 = 7, stopped: UInt16 = 8
        static let registered: UInt16 = 9, canonical: UInt16 = 10, exclusions: UInt16 = 11, text: UInt16 = 1
    }

    static func fields(_ r: FSEventsHostService.StreamRecord) -> SnapshotFields {
        var e = SnapshotFields()
        e.u64(Tag.port, UInt64(r.port))
        e.u64(Tag.client, UInt64(r.client))
        e.u64(Tag.pid, UInt64(UInt32(bitPattern: r.pid)))
        e.u64(Tag.dev, UInt64(r.dev))
        e.u64(Tag.flags, UInt64(r.flags))
        e.u64(Tag.latency, r.latencyMicroseconds)
        e.u64(Tag.lastID, r.lastID)
        e.u64(Tag.stopped, r.stopped ? 1 : 0)
        func strings(_ list: [String]) -> [SnapshotFields] {
            list.map { var f = SnapshotFields(); f.string(Tag.text, $0); return f }
        }
        e.list(Tag.registered, strings(r.registered))
        e.list(Tag.canonical, strings(r.canonical))
        e.list(Tag.exclusions, strings(r.exclusions))
        return e
    }

    static func record(_ e: SnapshotFieldReader) -> FSEventsHostService.StreamRecord {
        func strings(_ tag: UInt16) -> [String] { e.list(tag).map { $0.string(Tag.text) ?? "" } }
        return FSEventsHostService.StreamRecord(
            port: e.u32(Tag.port), client: e.u32(Tag.client), pid: Int32(bitPattern: e.u32(Tag.pid)), dev: e.u32(Tag.dev),
            registered: strings(Tag.registered), canonical: strings(Tag.canonical), exclusions: strings(Tag.exclusions),
            flags: e.u32(Tag.flags), latencyMicroseconds: e.u64(Tag.latency), lastID: e.u64(Tag.lastID),
            stopped: e.u64(Tag.stopped) != 0)
    }
}
#endif
