import Foundation

/// Reading and writing Gauge traces (`specs/ide/profiler.md` §4.1): one
/// JSON document. Integers above 2⁵³ (kernel addresses) are written as
/// "0x…" strings so every JSON reader keeps them exact; readers accept
/// both spellings.
public enum GaugeTraceCodec {
    public struct Failure: Error, CustomStringConvertible, Equatable {
        public var description: String
        public init(_ d: String) { description = d }
    }

    // MARK: Writing

    public static func encode(_ t: GaugeTrace, pretty: Bool = false) throws -> Data {
        var root: [String: Any] = ["format": GaugeTrace.format, "version": GaugeTrace.version]
        let r = t.recording
        root["recording"] = [
            "target": r.target, "recorder": r.recorder, "host": r.host, "command": r.command, "device": r.device,
            "startDate": ISO8601DateFormatter().string(from: r.startDate), "durationNs": num(r.durationNs),
            "sampleIntervalNs": num(r.sampleIntervalNs), "hangThresholdNs": num(r.hangThresholdNs),
            "clock": r.clock, "notes": r.notes,
        ] as [String: Any]
        root["processes"] = t.processes.map { ["pid": $0.pid, "name": $0.name, "path": $0.path, "target": $0.isTarget] as [String: Any] }
        root["threads"] = t.threads.map { ["id": num($0.id), "pid": $0.pid, "name": $0.name, "main": $0.isMain, "kind": $0.kind] as [String: Any] }
        root["images"] = t.images.map { i -> [String: Any] in
            var d: [String: Any] = ["id": i.id, "name": i.name, "path": i.path, "kind": i.kind.rawValue,
                                    "base": num(i.base), "size": num(i.size),
                                    "symbols": i.symbols.map { [num($0.start), num($0.end), $0.name] as [Any] }]
            if let u = i.uuid { d["uuid"] = u }
            if !i.files.isEmpty { d["files"] = i.files }
            if !i.lines.isEmpty { d["lines"] = i.lines.map { [num($0.offset), $0.file, $0.line] as [Any] } }
            return d
        }
        root["frames"] = t.frames.map { [$0.image, num($0.offset)] as [Any] }
        root["stacks"] = t.stacks.map { [$0.prefix, $0.frame] }
        root["samples"] = [
            "time": t.samples.time.map { num($0) }, "thread": t.samples.thread.map { num($0) },
            "stack": t.samples.stack, "state": t.samples.state.map(\.rawValue),
        ] as [String: Any]
        root["signposts"] = t.signposts.map { s -> [String: Any] in
            ["name": s.name, "subsystem": s.subsystem, "category": s.category, "id": num(s.id), "thread": num(s.thread),
             "begin": num(s.begin), "end": s.end.map { num($0) } ?? NSNull(), "kind": s.kind.rawValue,
             "message": s.message, "flags": s.flags]
        }
        root["hangs"] = t.hangs.map { ["thread": num($0.thread), "begin": num($0.begin), "end": num($0.end)] }
        root["presents"] = t.presents.map { num($0) }
        root["gpu"] = t.gpu.map { ["pid": $0.pid, "process": $0.process, "submit": num($0.submit), "end": num($0.end), "gpuNs": num($0.gpuNs)] as [String: Any] }
        var options: JSONSerialization.WritingOptions = [.sortedKeys]
        if pretty { options.insert(.prettyPrinted) }
        return try JSONSerialization.data(withJSONObject: root, options: options)
    }

    public static func write(_ t: GaugeTrace, to url: URL) throws {
        try encode(t).write(to: url, options: .atomic)
    }

    /// A JSON number when exact in a double, else a hex string.
    static func num(_ v: UInt64) -> Any { v <= 1 << 53 ? NSNumber(value: v) : "0x" + String(v, radix: 16) }

    // MARK: Reading

    public static func read(_ url: URL) throws -> GaugeTrace {
        try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> GaugeTrace {
        if data.count >= 2, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B {
            throw Failure("compressed Gauge traces are not supported by this version; decompress it first (gunzip)")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure("not a JSON object") }
        guard root["format"] as? String == GaugeTrace.format else { throw Failure("not a Gauge trace (format is not \(GaugeTrace.format))") }
        let version = int(root["version"]) ?? 0
        guard version >= 1, version <= GaugeTrace.version else {
            throw Failure("Gauge trace version \(version) is newer than this Ycode reads (\(GaugeTrace.version)); update Ycode")
        }
        let r = root["recording"] as? [String: Any] ?? [:]
        let recording = GaugeTrace.Recording(
            target: r["target"] as? String ?? "", recorder: r["recorder"] as? String ?? "", host: r["host"] as? String ?? "",
            command: r["command"] as? String ?? "", device: r["device"] as? String ?? "",
            startDate: (r["startDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date(timeIntervalSince1970: 0),
            durationNs: u64(r["durationNs"]) ?? 0, sampleIntervalNs: u64(r["sampleIntervalNs"]) ?? 1_000_000,
            hangThresholdNs: u64(r["hangThresholdNs"]) ?? 250_000_000, clock: r["clock"] as? String ?? "monotonic",
            notes: r["notes"] as? [String] ?? [])
        var t = GaugeTrace(recording: recording)
        t.processes = (root["processes"] as? [[String: Any]] ?? []).map {
            GaugeTrace.Process(pid: int($0["pid"]) ?? 0, name: $0["name"] as? String ?? "", path: $0["path"] as? String ?? "",
                               isTarget: $0["target"] as? Bool ?? true)
        }
        t.threads = (root["threads"] as? [[String: Any]] ?? []).map {
            GaugeTrace.Thread(id: u64($0["id"]) ?? 0, pid: int($0["pid"]) ?? 0, name: $0["name"] as? String ?? "",
                              isMain: $0["main"] as? Bool ?? false, kind: $0["kind"] as? String ?? "thread")
        }
        t.images = try (root["images"] as? [[String: Any]] ?? []).enumerated().map { index, d in
            let symbols = try (d["symbols"] as? [[Any]] ?? []).map { a -> GaugeTrace.Symbol in
                guard a.count >= 3, let s = u64(a[0]), let e = u64(a[1]), let n = a[2] as? String else { throw Failure("bad symbol in image \(index)") }
                return GaugeTrace.Symbol(start: s, end: e, name: n)
            }
            let lines = try (d["lines"] as? [[Any]] ?? []).map { a -> GaugeTrace.LineEntry in
                guard a.count >= 3, let o = u64(a[0]), let f = int(a[1]), let l = int(a[2]) else { throw Failure("bad line entry in image \(index)") }
                return GaugeTrace.LineEntry(offset: o, file: f, line: l)
            }
            return GaugeTrace.Image(id: int(d["id"]) ?? index, name: d["name"] as? String ?? "", path: d["path"] as? String ?? "",
                                    uuid: d["uuid"] as? String, kind: GaugeTrace.ImageKind(rawValue: d["kind"] as? String ?? "") ?? .unknown,
                                    base: u64(d["base"]) ?? 0, size: u64(d["size"]) ?? 0,
                                    symbols: symbols.sorted { $0.start < $1.start }, files: d["files"] as? [String] ?? [],
                                    lines: lines.sorted { $0.offset < $1.offset })
        }
        t.frames = try (root["frames"] as? [[Any]] ?? []).map { a in
            guard a.count >= 2, let i = int(a[0]), let o = u64(a[1]) else { throw Failure("bad frame") }
            return GaugeTrace.Frame(image: i, offset: o)
        }
        t.stacks = try (root["stacks"] as? [[Any]] ?? []).enumerated().map { index, a in
            guard a.count >= 2, let p = int(a[0]), let f = int(a[1]), p < index, f < t.frames.count else { throw Failure("bad stack \(index)") }
            return GaugeTrace.Stack(prefix: p, frame: f)
        }
        if let s = root["samples"] as? [String: Any] {
            let time = (s["time"] as? [Any] ?? []).compactMap(u64)
            let thread = (s["thread"] as? [Any] ?? []).compactMap(u64)
            let stack = (s["stack"] as? [Any] ?? []).compactMap(int)
            let state = (s["state"] as? [Any] ?? []).map { ($0 as? String).flatMap(GaugeTrace.SampleState.init(rawValue:)) ?? .user }
            guard time.count == thread.count, time.count == stack.count, time.count == state.count else {
                throw Failure("sample columns have different lengths")
            }
            guard stack.allSatisfy({ $0 >= -1 && $0 < t.stacks.count }) else { throw Failure("a sample names a missing stack") }
            t.samples.time = time
            t.samples.thread = thread
            t.samples.stack = stack
            t.samples.state = state
        }
        t.signposts = (root["signposts"] as? [[String: Any]] ?? []).map {
            GaugeTrace.Signpost(name: $0["name"] as? String ?? "", subsystem: $0["subsystem"] as? String ?? "",
                                category: $0["category"] as? String ?? "", id: u64($0["id"]) ?? 0, thread: u64($0["thread"]) ?? 0,
                                begin: u64($0["begin"]) ?? 0, end: u64($0["end"]),
                                kind: GaugeTrace.Signpost.Kind(rawValue: $0["kind"] as? String ?? "") ?? .interval,
                                message: $0["message"] as? String ?? "", flags: $0["flags"] as? [String] ?? [])
        }
        t.hangs = (root["hangs"] as? [[String: Any]] ?? []).map {
            GaugeTrace.Hang(thread: u64($0["thread"]) ?? 0, begin: u64($0["begin"]) ?? 0, end: u64($0["end"]) ?? 0)
        }
        t.presents = (root["presents"] as? [Any] ?? []).compactMap(u64)
        t.gpu = (root["gpu"] as? [[String: Any]] ?? []).map {
            GaugeTrace.GPUWork(pid: int($0["pid"]) ?? 0, process: $0["process"] as? String ?? "", submit: u64($0["submit"]) ?? 0,
                               end: u64($0["end"]) ?? 0, gpuNs: u64($0["gpuNs"]) ?? 0)
        }
        return t
    }

    static func u64(_ v: Any?) -> UInt64? {
        switch v {
        case let n as Int: return n < 0 ? nil : UInt64(n)
        case let n as UInt64: return n
        case let n as Int64: return n < 0 ? nil : UInt64(n)
        case let d as Double: return d < 0 || d > 1.8e19 ? nil : UInt64(d)
        case let n as NSNumber:
            let d = n.doubleValue
            if d < 0 { return nil }
            return n.uint64Value
        case let s as String:
            if s.hasPrefix("0x") { return UInt64(s.dropFirst(2), radix: 16) }
            return UInt64(s)
        default: return nil
        }
    }

    static func int(_ v: Any?) -> Int? {
        switch v {
        case let n as Int: return n
        case let n as Int64: return Int(n)
        case let d as Double: return Int(exactly: d.rounded())
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }
}
