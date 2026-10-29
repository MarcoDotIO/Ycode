// The host's audio server `com.apple.audio.audiohald` (specs/simulator/
// audio-host.md; visionos.md §10.17, §10.19): the endpoint every guest
// CoreAudio client talks to. Ycode serves the smallest service the
// reference was tested with (audio-host.md §8): the system object, one
// 48 kHz stereo Float32 output device with one stream, IO contexts, the
// private aggregates clients create, and the IO protocol of §10: a shared
// region per running IO context, a 24-byte cycle message from the client
// answered by a 24-byte wake paced at the device's real rate on the host's
// monotonic clock, and a workgroup port the client's IO thread joins (a
// work interval of Ycode's kernel, WorkInterval.swift). The output is
// discarded, or written to `YCODE_AUDIO_CAPTURE=<path.wav>`. Real host
// playback would take the blocks where the capture does (`deliver`).
//
// Written from audio-host.md and the public CoreAudio headers; no Apple code.

import Foundation
import YcodeDarwinABI
import YcodeDarwinKernel

public final class AudioHostService: @unchecked Sendable {
    public static let serviceName = "com.apple.audio.audiohald"
    /// `YCODE_DEBUG_NO_AUDIO=1`: no service (A/B; the guest then has no
    /// audio system, as before).
    public static let disabled = getenv("YCODE_DEBUG_NO_AUDIO").map { String(cString: $0) == "1" } ?? false
    /// `YCODE_DEBUG_AUDIO=1`: one line per request (object, address, answer).
    static let debug = getenv("YCODE_DEBUG_AUDIO").map { String(cString: $0) == "1" } ?? false

    /// Request n has ID 1010000 + n; its reply 1010100 + n (audio-host.md §2).
    public static let base: Int32 = 1_010_000
    public enum Message {
        public static let getObject: Int32 = 2, createIOContext: Int32 = 3, createAggregate: Int32 = 5
        public static let setIOContextPort: Int32 = 10, stopIO: Int32 = 12, hasProperty: Int32 = 13
        public static let isSettable: Int32 = 14, getBytesQualified: Int32 = 15, getU32: Int32 = 16
        public static let getU32Array: Int32 = 19, getU32ArrayQualified: Int32 = 20, getString: Int32 = 21
        public static let getF64: Int32 = 25, getF64Array: Int32 = 26, getPlist: Int32 = 27
        public static let setBytesQualified: Int32 = 29, setU32: Int32 = 30, setF32: Int32 = 31
        public static let addListener: Int32 = 35, removeListener: Int32 = 36, setU32Array: Int32 = 46
        public static let workgroupPort: Int32 = 59, startIO: Int32 = 63, registerClient: Int32 = 71
    }

    /// The NDR record; `MIG_BAD_ID`.
    static let ndr: [UInt8] = [0, 0, 0, 0, 1, 0, 0, 0]
    static let migBadID: Int32 = -303

    /// IO region layout (audio-host.md §10).
    public enum Region {
        public static let ticksPerFrame = 0x000, framesPerTick = 0x008, rateScalar = 0x010, bufferFrames = 0x018
        public static let zeroTime = 0x020, nowTime = 0x060, inputTime = 0x0A0, outputTime = 0x0E0, cycle = 0x124
        public static let bufferTable = 0x4000, outputData = 0x8000
        public static let plainSize = 65_536, aggregateSize = 245_760
        public static let plainCapacity: UInt32 = 8_192, aggregateCapacity: UInt32 = 196_608
    }

    /// The workgroup a running IO thread joins: kWorkIntervalTypeCoreAudio,
    /// joinable, its own thread group (`sys/work_interval.h`; level 1).
    public static let workgroupFlags = WorkIntervalABI.typeCoreAudio | WorkIntervalABI.flagJoinable | WorkIntervalABI.flagGroup

    public let servicePort: UInt32
    let portSet: UInt32
    let notifyPort: UInt32
    let host: MachHostTask
    let log: (String) -> Void
    let lock = NSLock()
    let model = AudioObjectModel()
    private var stopping = false

    /// Guest mach time now and its frequency (the device's host times are in
    /// the guest's `mach_absolute_time` units). Set by the VMM; the default
    /// is the 24 MHz timebase on the host's monotonic clock.
    private var guestClock: () -> (ticks: UInt64, frequency: UInt64) = { (MachTimebase.now(), MachTimebase.frequency) }

    public func setGuestClock(_ clock: @escaping () -> (ticks: UInt64, frequency: UInt64)) {
        lock.withLock { guestClock = clock }
        resumeRestoredIO()
    }
    /// Where the output goes besides the capture (host playback would hook
    /// in here): interleaved Float32 blocks and the host monotonic ns at
    /// which the device plays them.
    public var deliver: (([Float], UInt64) -> Void)?
    /// The device's volume and output choice (simulator-features.md §4.11,
    /// §4.12, "Ycode implementation"): the output is scaled by the volume
    /// (0…1) before the capture and `deliver`; with the output device "None"
    /// it is silence. Set by the settings controller.
    public func setOutput(volume: Float, muted: Bool) {
        lock.withLock {
            outputGain = min(1, max(0, volume))
            outputMuted = muted
        }
        log("audio: output volume \(Int(volume * 100)) %\(muted ? ", muted (output None)" : "")")
    }
    private var outputGain: Float = 1
    private var outputMuted = false
    let capture: AudioCaptureWriter?

    struct Client {
        var name: String
        var port: UInt32
    }

    /// One running IO context (audio-host.md §10).
    final class IOState {
        let contextID: UInt32
        let deviceID: UInt32
        let pid: Int32
        let region: SharedMemoryObject
        let regionSize: Int
        /// A send right to the region's memory entry, kept so a snapshot
        /// finds the region again by name.
        let entry: UInt32
        let ioPort: UInt32
        let wakePort: UInt32
        var anchored = false
        var anchorNs: UInt64 = 0
        var anchorTicks: UInt64 = 0
        var ticksPerFrame = 500.0
        /// The sample time of the last wake's "now" (frames since the anchor).
        var sampleTime = 0.0
        var lastWakeID: UInt32 = 0
        /// A wake owed at a host time: its ID and sample time.
        var due: (id: UInt32, sampleTime: Double, at: UInt64)?
        /// The block the client writes after the last wake: its frames and
        /// the host time it plays at.
        var block: (frames: Int, at: UInt64)?
        var cycles = 0, restarts = 0, failedWakes = 0
        var peak: Float = 0
        var nonZero = 0

        init(contextID: UInt32, deviceID: UInt32, pid: Int32, region: SharedMemoryObject, regionSize: Int, entry: UInt32,
             ioPort: UInt32, wakePort: UInt32) {
            self.contextID = contextID
            self.deviceID = deviceID
            self.pid = pid
            self.region = region
            self.regionSize = regionSize
            self.entry = entry
            self.ioPort = ioPort
            self.wakePort = wakePort
        }
    }

    private var objectPorts: [UInt32: UInt32] = [:]
    private var clients: [Int32: Client] = [:]
    private var running: [UInt32: IOState] = [:]
    private var contextByIOPort: [UInt32: UInt32] = [:]
    /// The workgroup port (a host send right) of each IO context.
    private var workgroups: [UInt32: UInt32] = [:]
    private var firstSeen: Set<Int32> = []
    /// Statistics.
    public private(set) var requestCount = 0
    public private(set) var totalCycles = 0

    /// The capture file `YCODE_AUDIO_CAPTURE` names, if any.
    public static var capturePathFromEnvironment: String? {
        getenv("YCODE_AUDIO_CAPTURE").map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Host monotonic ns when the service was made (log time stamps).
    let startNs = MachTimebase.hostMonotonicNanoseconds()

    public init(host: MachHostTask, log: @escaping (String) -> Void,
                capturePath: String? = AudioHostService.capturePathFromEnvironment) throws {
        self.host = host
        let started = startNs
        // Every line carries the seconds since the service was made.
        self.log = { line in
            let t = Double(MachTimebase.hostMonotonicNanoseconds() &- started) / 1e9
            log(line.hasPrefix("audio: ") ? "audio: [\(String(format: "%.3f", t)) s] " + line.dropFirst(7) : line)
        }
        servicePort = try host.makePort(sendRight: true, qlimit: 64)
        portSet = try host.makePortSet()
        notifyPort = try host.makePort()
        try host.addMember(servicePort, to: portSet)
        try host.addMember(notifyPort, to: portSet)
        if let path = capturePath {
            do {
                capture = try AudioCaptureWriter(path: path, sampleRate: Int(AudioObjectModel.sampleRate),
                                                 channels: Int(AudioObjectModel.channels))
            } catch {
                log("audio: cannot write the capture \(path): \(error)")
                capture = nil
            }
        } else {
            capture = nil
        }
    }

    public func start() {
        let t = Thread { [self] in run() }
        t.name = "ycode-audio"
        t.qualityOfService = .userInteractive
        t.start()
    }

    public func stop() {
        lock.withLock { stopping = true }
        finishCapture()
    }

    /// Writes the capture's pending audio and header (also at the end of a run).
    public func finishCapture() {
        lock.withLock {
            guard let c = capture else { return }
            c.flush()
            log("audio: capture \(c.path): \(c.writtenFrames) frames (\(String(format: "%.1f", Double(c.writtenFrames) / AudioObjectModel.sampleRate)) s), "
                + "\(c.blocks) blocks, \(c.nonZeroSamples) samples not zero, peak \(String(format: "%.4f", c.peak))")
        }
    }

    // MARK: The service thread

    private func run() {
        log("audio: serving \(Self.serviceName): '\(AudioObjectModel.deviceName)', \(Int(AudioObjectModel.sampleRate)) Hz, "
            + "\(AudioObjectModel.channels) channels, \(AudioObjectModel.bufferFrames)-frame cycles"
            + (capture.map { "; capture to \($0.path)" } ?? ""))
        while !lock.withLock({ stopping }) {
            let now = MachTimebase.hostMonotonicNanoseconds()
            let next = lock.withLock { running.values.compactMap { $0.due?.at }.min() }
            let timeout = next.map { $0 > now ? min($0 - now, 200_000_000) : 0 } ?? 200_000_000
            do {
                let m = try host.receive(on: portSet, timeout: timeout, tracked: true)
                lock.withLock { handle(m) }
                host.finishedMessage()
            } catch let e as MachHostError where e == .timedOut || e == .interrupted || e == .portChanged {
                // A wake may be due.
            } catch let e as MachHostError where e == MachHostError(MachMsgReturn.rcvInvalidName) {
                return  // the host task ended
            } catch {
                if !lock.withLock({ stopping }) { log("audio: receive failed: \(error); stopping") }
                return
            }
            lock.withLock { fireDueWakes(MachTimebase.hostMonotonicNanoseconds()) }
        }
    }

    // MARK: Requests (lock held)

    func handle(_ m: MachHostReceivedMessage) {
        requestCount += 1
        if let ctx = contextByIOPort[m.localPort] {
            cycle(ctx, id: UInt32(bitPattern: m.id), m)
            return
        }
        if m.localPort == notifyPort {
            deadName(m)
            return
        }
        let n = m.id &- Self.base
        if firstSeen.insert(n).inserted, !Self.debug {
            log("audio: first request \(n) from pid \(m.sender?.pid ?? -1) (\(m.size) bytes)")
        }
        guard let (descriptors, body) = answer(m) else {
            host.discard(m)
            return
        }
        dropRights(m, keeping: keptRights)
        keptRights = []
        guard MachPortName.isValid(m.replyPort) else { return }
        do {
            try host.reply(to: m, descriptors: descriptors, body: body)
        } catch {
            log("audio: reply to request \(n) failed: \(error)")
        }
    }

    /// Rights a request brought that the handler keeps (not dropped).
    private var keptRights: Set<UInt32> = []

    private func dropRights(_ m: MachHostReceivedMessage, keeping: Set<UInt32>) {
        for d in m.descriptors {
            switch d {
            case let .port(name, _), let .guardedPort(name, _, _):
                if !keeping.contains(name), MachPortName.isValid(name) { try? host.deallocate(name) }
            case let .oolPorts(names, _): for n in names where MachPortName.isValid(n) { try? host.deallocate(n) }
            case .ool: break
            }
        }
    }

    /// Word `i` after the NDR record.
    static func word(_ m: MachHostReceivedMessage, _ i: Int) -> UInt32 {
        let at = 8 + 4 * i
        guard m.body.count >= at + 4 else { return 0 }
        return UInt32(m.body[at]) | UInt32(m.body[at + 1]) << 8 | UInt32(m.body[at + 2]) << 16 | UInt32(m.body[at + 3]) << 24
    }

    static func address(_ m: MachHostReceivedMessage, at i: Int) -> AudioPropertyAddress {
        AudioPropertyAddress(word(m, i), word(m, i + 1), word(m, i + 2))
    }

    /// The bytes of the request's `i`th out-of-line descriptor.
    static func ool(_ m: MachHostReceivedMessage, _ i: Int) -> [UInt8] {
        var k = 0
        for d in m.descriptors {
            if case let .ool(data, _, _) = d {
                if k == i { return data }
                k += 1
            }
        }
        return []
    }

    static func le(_ v: UInt32) -> [UInt8] { AudioHAL.le32(v) }

    /// A simple reply: NDR, return code, values.
    static func simple(_ status: UInt32, _ values: [UInt32] = []) -> ([MachHostDescriptor], [UInt8]) {
        ([], ndr + le(status) + values.flatMap(le))
    }

    /// A complex reply with one out-of-line region: NDR and a count.
    static func outOfLine(_ data: [UInt8], count: Int) -> ([MachHostDescriptor], [UInt8]) {
        ([.ool(data: data)], ndr + le(UInt32(count)))
    }

    /// The reply (descriptors, body after them) to one request; nil for a
    /// one-way message.
    func answer(_ m: MachHostReceivedMessage) -> ([MachHostDescriptor], [UInt8])? {
        let pid = m.sender?.pid ?? -1
        let n = m.id &- Self.base
        let obj = Self.word(m, 0)
        switch n {
        case Message.registerClient:
            var port: UInt32 = 0
            for d in m.descriptors { if case let .port(name, _) = d { port = name } }
            let units = Self.ool(m, 0)
            let name = String(decoding: stride(from: 0, to: units.count - units.count % 2, by: 2).map {
                UInt16(units[$0]) | UInt16(units[$0 + 1]) << 8
            }, as: UTF16.self)
            register(pid: pid, name: name, port: port)
            return Self.simple(0)

        case Message.getObject:
            guard let (cls, base) = model.classes(of: obj) else {
                trace(pid, "get object \(obj): no such object")
                return ([.port(name: 0, disposition: MachMsgType.makeSend)], Self.ndr + Self.le(0) + Self.le(0))
            }
            let port = objectPort(obj)
            trace(pid, "get object \(obj) -> \(fourCCText(cls))/\(fourCCText(base))")
            return ([.port(name: port, disposition: MachMsgType.makeSend)], Self.ndr + Self.le(cls) + Self.le(base))

        case Message.hasProperty:
            let a = Self.address(m, at: 1)
            let has = hasProperty(obj, a, pid: pid)
            trace(pid, "has \(obj) \(a) -> \(has ? 1 : 0)")
            return Self.simple(0, [has ? 1 : 0])

        case Message.isSettable:
            let a = Self.address(m, at: 1)
            let settable = model.isSettable(obj, a)
            trace(pid, "settable \(obj) \(a) -> \(settable ? 1 : 0)")
            return Self.simple(0, [settable ? 1 : 0])

        case Message.getU32:
            let a = Self.address(m, at: 1)
            let v = model.value(obj, a, pid: pid)
            trace(pid, "get u32 \(obj) \(a) -> \(v.map { "\($0)" } ?? "none")")
            switch v {
            case let .u32(x): return Self.simple(0, [x])
            case let .u32s(x) where !x.isEmpty: return Self.simple(0, [x[0]])
            case let .f32(x): return Self.simple(0, [x.bitPattern])
            default: return Self.simple(AudioHAL.unknownProperty, [0])
            }

        case Message.getF64:
            let a = Self.address(m, at: 1)
            let v = model.value(obj, a, pid: pid)
            trace(pid, "get f64 \(obj) \(a) -> \(v.map { "\($0)" } ?? "none")")
            let x: Double?
            switch v {
            case let .f64(d): x = d
            case let .u32(u): x = Double(u)
            case let .f32(f): x = Double(f)
            case let .f64s(a) where !a.isEmpty: x = a[0]
            default: x = nil
            }
            guard let x else { return ([], Self.ndr + Self.le(AudioHAL.unknownProperty) + AudioHAL.le64(0)) }
            return ([], Self.ndr + Self.le(0) + AudioHAL.le64(x.bitPattern))

        case Message.getU32Array, Message.getU32ArrayQualified:
            let qualified = n == Message.getU32ArrayQualified
            let a = Self.address(m, at: 1)
            let v = model.value(obj, a, pid: pid, qualifier: qualified ? Self.ool(m, 0) : [])
            trace(pid, "get u32[] \(obj) \(a) -> \(v.map { "\($0)" } ?? "none")")
            switch v {
            case let .u32s(x): return Self.outOfLine(x.flatMap(Self.le), count: x.count)
            case let .u32(x): return Self.outOfLine(Self.le(x), count: 1)
            default: return Self.outOfLine([], count: 0)
            }

        case Message.getF64Array:
            let a = Self.address(m, at: 1)
            let v = model.value(obj, a, pid: pid)
            trace(pid, "get f64[] \(obj) \(a) -> \(v.map { "\($0)" } ?? "none")")
            switch v {
            case let .f64s(x): return Self.outOfLine(x.flatMap { AudioHAL.le64($0.bitPattern) }, count: x.count)
            case let .f64(x): return Self.outOfLine(AudioHAL.le64(x.bitPattern), count: 1)
            default: return Self.outOfLine([], count: 0)
            }

        case Message.getString:
            let a = Self.address(m, at: 1)
            let v = model.value(obj, a, pid: pid)
            trace(pid, "get string \(obj) \(a) -> \(v.map { "\($0)" } ?? "none")")
            guard case let .string(s) = v else { return Self.outOfLine([], count: 0) }
            return Self.outOfLine(AudioValue.string(s).rawBytes, count: s.utf16.count)

        case Message.getPlist:
            let a = Self.address(m, at: 1)
            let v = model.value(obj, a, pid: pid)
            trace(pid, "get plist \(obj) \(a) -> \(v.map { _ in "a property list" } ?? "none")")
            guard case let .plist(b) = v else { return Self.outOfLine([], count: 0) }
            return Self.outOfLine(b, count: b.count)

        case Message.getBytesQualified:
            let a = Self.address(m, at: 1)
            let v = model.value(obj, a, pid: pid, qualifier: Self.ool(m, 0))
            let bytes = v?.rawBytes ?? []
            trace(pid, "get bytes \(obj) \(a) -> \(v == nil ? "none" : "\(bytes.count) bytes")")
            return Self.outOfLine(bytes, count: bytes.count)

        case Message.setU32:
            let a = Self.address(m, at: 1)
            let status = model.set(obj, a, .u32(Self.word(m, 4)))
            trace(pid, "set u32 \(obj) \(a) = \(Self.word(m, 4)) -> \(fourCCText(status))")
            return Self.simple(status)

        case Message.setF32:
            let a = Self.address(m, at: 1)
            let f = Float(bitPattern: Self.word(m, 4))
            let status = model.set(obj, a, .f32(f))
            trace(pid, "set f32 \(obj) \(a) = \(f) -> \(fourCCText(status))")
            return Self.simple(status)

        case Message.setU32Array:
            let a = Self.address(m, at: 1)
            let data = Self.ool(m, 0)
            let values = stride(from: 0, to: data.count - data.count % 4, by: 4).map {
                UInt32(data[$0]) | UInt32(data[$0 + 1]) << 8 | UInt32(data[$0 + 2]) << 16 | UInt32(data[$0 + 3]) << 24
            }
            let status = model.set(obj, a, .u32s(values))
            trace(pid, "set u32[] \(obj) \(a) = \(values) -> \(fourCCText(status))")
            return Self.simple(status)

        case Message.setBytesQualified:
            let a = Self.address(m, at: 1)
            let status = model.set(obj, a, .bytes(Self.ool(m, 1)))
            trace(pid, "set bytes \(obj) \(a) (\(Self.ool(m, 1).count) bytes) -> \(fourCCText(status))")
            return Self.simple(status)

        case Message.addListener, Message.removeListener:
            // Listeners are accepted silently: no notification is ever sent
            // (audio-host.md §8, boot b8).
            return nil

        case Message.createIOContext:
            switch model.createIOContext(description: Self.ool(m, 0), pid: pid) {
            case let .success(id):
                trace(pid, "create IO context -> \(id) (device \(model.context(id)?.deviceID ?? 0))")
                return Self.simple(0, [id])
            case let .failure(e):
                log("audio: pid \(pid): IO context refused: \(e)")
                return Self.simple(e.code, [0])
            }

        case Message.createAggregate:
            switch model.createAggregate(description: Self.ool(m, 0), pid: pid) {
            case let .success(id):
                let uid = model.aggregates[id]?.uid ?? "?"
                log("audio: pid \(pid) (\(clients[pid]?.name ?? "?")) made aggregate \(id) '\(uid)'")
                return Self.simple(0, [id])
            case let .failure(e):
                log("audio: pid \(pid): aggregate refused: \(e)")
                return Self.simple(e.code, [0])
            }

        case Message.setIOContextPort:
            // The client's port for IO-context notifications: none is sent.
            trace(pid, "set IO context port \(obj)")
            return Self.simple(model.context(obj) == nil ? AudioHAL.badObject : 0)

        case Message.startIO:
            var wake: UInt32 = 0
            for d in m.descriptors { if case let .port(name, _) = d { wake = name } }
            return startIO(obj, wake: wake, pid: pid)

        case Message.workgroupPort:
            return workgroup(obj, pid: pid)

        case Message.stopIO:
            stopIO(obj, reason: "stopped by the client")
            return Self.simple(model.context(obj) == nil ? AudioHAL.badObject : 0)

        default:
            log("audio: unknown request \(m.id) from pid \(pid) (\(m.size) bytes)")
            return Self.simple(UInt32(bitPattern: Self.migBadID))
        }
    }

    func hasProperty(_ obj: UInt32, _ a: AudioPropertyAddress, pid: Int32) -> Bool {
        model.value(obj, a, pid: pid) != nil
    }

    private func trace(_ pid: Int32, _ text: @autoclosure () -> String) {
        if Self.debug { log("audio: pid \(pid): " + text()) }
    }

    /// The object port of `id` (made on first use; the system object's is
    /// the service port).
    private func objectPort(_ id: UInt32) -> UInt32 {
        if id == AudioObjectModel.systemID { return servicePort }
        if let p = objectPorts[id] { return p }
        guard let p = try? host.makePort(qlimit: 16) else { return 0 }
        try? host.addMember(p, to: portSet)
        objectPorts[id] = p
        return p
    }

    private func register(pid: Int32, name: String, port: UInt32) {
        if let old = clients[pid], old.port != port, MachPortName.isValid(old.port) { try? host.deallocate(old.port) }
        clients[pid] = Client(name: name, port: port)
        if MachPortName.isValid(port) {
            keptRights.insert(port)
            // Its death tells that the client process ended.
            _ = try? host.requestNotification(port, id: MachNotify.deadName, notifyPort: notifyPort)
        }
        log("audio: client pid \(pid) registered (\(name.isEmpty ? "no name" : name))")
    }

    /// A client's registration port died: its process ended.
    private func deadName(_ m: MachHostReceivedMessage) {
        guard m.id == MachNotify.deadName else {
            host.discard(m)
            return
        }
        let name = Self.word(m, 0)
        guard let (pid, client) = clients.first(where: { $0.value.port == name }) else {
            try? host.deallocate(name)
            return
        }
        clients[pid] = nil
        // The dead name's reference and the notification's.
        try? host.deallocate(name)
        try? host.deallocate(name)
        for (id, st) in running where st.pid == pid { stop(st, id, reason: "the client ended") }
        let removed = model.removeClient(pid: pid)
        for id in removed.objects {
            if let wg = workgroups.removeValue(forKey: id) { try? host.deallocate(wg) }
            if let p = objectPorts.removeValue(forKey: id) { try? host.destroyPort(p) }
        }
        log("audio: client pid \(pid) (\(client.name)) ended: \(removed.aggregates) aggregates and "
            + "\(removed.contexts) IO contexts removed")
    }

    // MARK: IO (audio-host.md §10)

    private func startIO(_ id: UInt32, wake: UInt32, pid: Int32) -> ([MachHostDescriptor], [UInt8]) {
        let fail: ([MachHostDescriptor], [UInt8]) = ([.port(name: 0, disposition: MachMsgType.makeSend),
                                                       .port(name: 0, disposition: MachMsgType.makeSend)],
                                                      Self.ndr + Self.le(0))
        guard let ctx = model.context(id), MachPortName.isValid(wake) else {
            log("audio: pid \(pid): start IO on \(id) refused (no such context or no wake port)")
            return fail
        }
        if let old = running[id] { stop(old, id, reason: "started again") }
        let aggregate = model.isAggregate(ctx.deviceID)
        let size = aggregate ? Region.aggregateSize : Region.plainSize
        guard let region = try? SharedMemoryObject(size: UInt64(size)), let entry = try? host.makeMemoryEntry(region),
              let ioPort = try? host.makePort(qlimit: 16) else {
            log("audio: pid \(pid): no memory for IO context \(id)")
            return fail
        }
        try? host.addMember(ioPort, to: portSet)
        // One more send right to the entry: the reply moves one, the service keeps one.
        try? host.modRefs(entry, right: MachPortRight.send, delta: 1)
        let st = IOState(contextID: id, deviceID: ctx.deviceID, pid: pid, region: region, regionSize: size, entry: entry,
                         ioPort: ioPort, wakePort: wake)
        keptRights.insert(wake)
        // The region's fixed part.
        let clock = guestClock()
        st.ticksPerFrame = Double(clock.frequency) / AudioObjectModel.sampleRate
        put(st, f64: st.ticksPerFrame, at: Region.ticksPerFrame)
        put(st, f64: 1 / st.ticksPerFrame, at: Region.framesPerTick)
        put(st, f64: 1, at: Region.rateScalar)
        put(st, u32: ctx.bufferFrames, at: Region.bufferFrames)
        put(st, u32: 1, at: Region.bufferTable)
        put(st, u32: aggregate ? Region.aggregateCapacity : Region.plainCapacity, at: Region.bufferTable + 4)
        running[id] = st
        contextByIOPort[ioPort] = id
        log("audio: IO started on context \(id) (device \(ctx.deviceID)\(aggregate ? ", aggregate" : ""), pid \(pid) "
            + "\(clients[pid]?.name ?? "?")): region \(size) bytes, \(ctx.bufferFrames)-frame cycles")
        return ([.port(name: ioPort, disposition: MachMsgType.makeSend), .port(name: entry, disposition: MachMsgType.moveSend)],
                Self.ndr + Self.le(UInt32(size)))
    }

    private func workgroup(_ id: UInt32, pid: Int32) -> ([MachHostDescriptor], [UInt8]) {
        guard model.context(id) != nil else {
            log("audio: pid \(pid): workgroup of unknown context \(id)")
            return ([.port(name: 0, disposition: MachMsgType.copySend)], [])
        }
        if workgroups[id] == nil {
            do {
                let port = try host.makeWorkIntervalPort(flags: Self.workgroupFlags)
                workgroups[id] = port
                log("audio: workgroup for context \(id): work interval #\(host.workInterval(named: port)?.id ?? 0)")
            } catch {
                log("audio: no workgroup for context \(id): \(error)")
                return ([.port(name: 0, disposition: MachMsgType.copySend)], [])
            }
        }
        return ([.port(name: workgroups[id]!, disposition: MachMsgType.copySend)], [])
    }

    private func stopIO(_ id: UInt32, reason: String) {
        guard let st = running[id] else { return }
        stop(st, id, reason: reason)
    }

    private func stop(_ st: IOState, _ id: UInt32, reason: String) {
        running[id] = nil
        contextByIOPort[st.ioPort] = nil
        try? host.destroyPort(st.ioPort)
        try? host.deallocate(st.wakePort)
        try? host.deallocate(st.entry)
        log("audio: IO stopped on context \(id) (pid \(st.pid) \(clients[st.pid]?.name ?? "?"); \(reason)): \(st.cycles) cycles, "
            + "\(st.restarts) restarts, \(st.failedWakes) failed wakes, \(st.nonZero) output samples not zero, "
            + "peak \(String(format: "%.4f", st.peak))")
    }

    /// The client's cycle message `id` on an IO port: it finished the cycle
    /// of the last wake (its output is in the region) and waits for the next.
    private func cycle(_ ctxID: UInt32, id: UInt32, _ m: MachHostReceivedMessage) {
        host.discard(m)
        guard let st = running[ctxID] else { return }
        if Self.debug, st.cycles < 8 || id != st.lastWakeID {
            log("audio: context \(ctxID) (pid \(st.pid)): cycle message \(id) (last wake \(st.lastWakeID), cycle \(st.cycles))")
        }
        let now = MachTimebase.hostMonotonicNanoseconds()
        let frames = Double(model.context(ctxID)?.bufferFrames ?? AudioObjectModel.bufferFrames)
        if let block = st.block {
            take(st, block)
            st.block = nil
        }
        guard st.anchored else {
            st.anchored = true
            st.anchorNs = now
            st.anchorTicks = guestClock().ticks
            wake(st, id: id &+ 1, sampleTime: 0, frames: frames)
            return
        }
        let next = st.sampleTime + frames
        let due = st.anchorNs + nanoseconds(frames: next)
        let period = nanoseconds(frames: frames)
        if now > due + period {
            // Late by more than a cycle: restart the numbering with wake 0 at
            // the cycle the device's clock is in now (audio-host.md §10).
            st.restarts += 1
            let elapsed = Double(now - st.anchorNs) * AudioObjectModel.sampleRate / 1e9
            wake(st, id: 0, sampleTime: max(next, (elapsed / frames).rounded(.down) * frames), frames: frames)
        } else if now >= due {
            wake(st, id: id &+ 1, sampleTime: next, frames: frames)
        } else {
            st.due = (id &+ 1, next, due)
        }
    }

    private func fireDueWakes(_ now: UInt64) {
        for st in running.values {
            guard let d = st.due, d.at <= now else { continue }
            let frames = Double(model.context(st.contextID)?.bufferFrames ?? AudioObjectModel.bufferFrames)
            wake(st, id: d.id, sampleTime: d.sampleTime, frames: frames)
        }
    }

    private func nanoseconds(frames: Double) -> UInt64 { UInt64(frames / AudioObjectModel.sampleRate * 1e9) }

    /// Writes the cycle's timestamps and sends wake `id` (audio-host.md §10).
    private func wake(_ st: IOState, id: UInt32, sampleTime: Double, frames: Double) {
        st.due = nil
        st.sampleTime = sampleTime
        let host = { (s: Double) -> UInt64 in
            st.anchorTicks &+ UInt64(bitPattern: Int64((s * st.ticksPerFrame).rounded()))
        }
        put(st, u32: UInt32(frames), at: Region.bufferFrames)
        putTimeStamp(st, at: Region.zeroTime, sample: sampleTime, host: host(sampleTime), flags: 3)
        putTimeStamp(st, at: Region.nowTime, sample: sampleTime, host: host(sampleTime), flags: 7)
        putTimeStamp(st, at: Region.inputTime, sample: sampleTime - frames, host: host(sampleTime - frames), flags: 7)
        putTimeStamp(st, at: Region.outputTime, sample: sampleTime + frames, host: host(sampleTime + frames), flags: 7)
        put(st, u32: id, at: Region.cycle)
        do {
            try self.host.send(MachHostOutgoingMessage(remotePort: st.wakePort, remoteDisposition: MachMsgType.copySend,
                                                       id: Int32(bitPattern: id)), timeout: 0)
            st.lastWakeID = id
            st.cycles += 1
            totalCycles += 1
            st.block = (Int(frames), st.anchorNs + nanoseconds(frames: sampleTime + frames))
            if st.cycles == 1 || st.cycles % 4096 == 0 {
                log("audio: context \(st.contextID) (pid \(st.pid)): \(st.cycles) cycles, \(st.restarts) restarts, "
                    + "\(st.nonZero) output samples not zero")
            }
        } catch let e as MachHostError where e == MachHostError(MachMsgReturn.sendTimedOut) {
            st.failedWakes += 1  // the client has not taken the previous wake
        } catch {
            st.failedWakes += 1
            stop(st, st.contextID, reason: "the wake port is gone (\(error))")
        }
    }

    /// The output the client wrote for a cycle (interleaved Float32 at 0x8000).
    private func take(_ st: IOState, _ block: (frames: Int, at: UInt64)) {
        let count = block.frames * Int(AudioObjectModel.channels)
        guard Region.outputData + count * 4 <= st.regionSize else { return }
        let p = st.region.host.advanced(by: Region.outputData).assumingMemoryBound(to: Float.self)
        var nonZero = 0
        var peak = st.peak
        for i in 0..<count where p[i] != 0 {
            nonZero += 1
            peak = max(peak, abs(p[i]))
        }
        st.nonZero += nonZero
        st.peak = peak
        guard capture != nil || deliver != nil else { return }
        var samples = Array(UnsafeBufferPointer(start: p, count: count))
        if outputMuted {
            samples = [Float](repeating: 0, count: count)
        } else if outputGain != 1 {
            for i in samples.indices { samples[i] *= outputGain }
        }
        capture?.add(samples, at: block.at)
        deliver?(samples, block.at)
    }

    private func put(_ st: IOState, u32 v: UInt32, at offset: Int) {
        st.region.host.storeBytes(of: v.littleEndian, toByteOffset: offset, as: UInt32.self)
    }

    private func put(_ st: IOState, f64 v: Double, at offset: Int) {
        st.region.host.storeBytes(of: v.bitPattern.littleEndian, toByteOffset: offset, as: UInt64.self)
    }

    private func put(_ st: IOState, u64 v: UInt64, at offset: Int) {
        st.region.host.storeBytes(of: v.littleEndian, toByteOffset: offset, as: UInt64.self)
    }

    /// An AudioTimeStamp (64 bytes): sample time, host time, rate scalar,
    /// word clock time, SMPTE time (24 bytes), flags, reserved.
    private func putTimeStamp(_ st: IOState, at offset: Int, sample: Double, host: UInt64, flags: UInt32) {
        put(st, f64: sample, at: offset)
        put(st, u64: host, at: offset + 8)
        put(st, f64: 1, at: offset + 16)
        put(st, u64: 0, at: offset + 24)
        for i in stride(from: 32, to: 56, by: 8) { put(st, u64: 0, at: offset + i) }
        put(st, u32: flags, at: offset + 56)
        put(st, u32: 0, at: offset + 60)
    }

    // MARK: Snapshot (snapshot.md §2.6; audio-host.md, "Ycode implementation")

    enum SnapTag {
        static let nextID: UInt16 = 1, powerHint: UInt16 = 2, volume: UInt16 = 3
        static let aggregates: UInt16 = 4, contexts: UInt16 = 5, objectPorts: UInt16 = 6, clients: UInt16 = 7
        static let workgroups: UInt16 = 8, running: UInt16 = 9
        // aggregate
        static let id: UInt16 = 20, stream: UInt16 = 21, subdevice: UInt16 = 22, uid: UInt16 = 23, name: UInt16 = 24
        static let pid: UInt16 = 25, composition: UInt16 = 26, stereo: UInt16 = 27, layout: UInt16 = 28
        // context
        static let device: UInt16 = 30, frames: UInt16 = 31, usageScopes: UInt16 = 32, usage: UInt16 = 33
        // pairs, clients
        static let keys: UInt16 = 40, values: UInt16 = 41, port: UInt16 = 42
        // running IO
        static let regionSize: UInt16 = 50, entry: UInt16 = 51, ioPort: UInt16 = 52, wakePort: UInt16 = 53
        static let sampleTime: UInt16 = 54, ticksPerFrame: UInt16 = 55
    }

    /// The service's whole state as host-task names; nil while the service
    /// is busy (the snapshot tries again). Called with the kernel lock
    /// held: the service takes its lock before the kernel's, so this only
    /// tries it.
    public func trySnapshotState() -> SnapshotFields? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        typealias T = SnapTag
        let st = model.state
        var g = SnapshotFields()
        g.u64(T.nextID, UInt64(st.nextID))
        g.u64(T.powerHint, UInt64(st.powerHint))
        g.u64(T.volume, UInt64(st.volume.bitPattern))
        g.list(T.aggregates, st.aggregates.map { a in
            var f = SnapshotFields()
            f.u64(T.id, UInt64(a.id))
            f.u64(T.stream, UInt64(a.streamID))
            f.u64(T.subdevice, UInt64(a.subdeviceID))
            f.string(T.uid, a.uid)
            f.string(T.name, a.name)
            f.i64(T.pid, Int64(a.creatorPID))
            f.bytes(T.composition, a.composition)
            f.u64s(T.stereo, a.preferredStereo.map(UInt64.init))
            f.bytes(T.layout, a.layout)
            return f
        })
        g.list(T.contexts, st.contexts.map { c in
            var f = SnapshotFields()
            f.u64(T.id, UInt64(c.id))
            f.u64(T.device, UInt64(c.deviceID))
            f.i64(T.pid, Int64(c.creatorPID))
            f.u64(T.frames, UInt64(c.bufferFrames))
            let usage = c.streamUsage.sorted { $0.key < $1.key }
            f.u64s(T.usageScopes, usage.map { UInt64($0.key) })
            f.list(T.usage, usage.map { var u = SnapshotFields(); u.u64s(T.values, $0.value.map(UInt64.init)); return u })
            return f
        })
        let ports = objectPorts.sorted { $0.key < $1.key }
        var op = SnapshotFields()
        op.u64s(T.keys, ports.map { UInt64($0.key) })
        op.u64s(T.values, ports.map { UInt64($0.value) })
        g.nested(T.objectPorts, op)
        let groups = workgroups.sorted { $0.key < $1.key }
        var wg = SnapshotFields()
        wg.u64s(T.keys, groups.map { UInt64($0.key) })
        wg.u64s(T.values, groups.map { UInt64($0.value) })
        g.nested(T.workgroups, wg)
        g.list(T.clients, clients.sorted { $0.key < $1.key }.map { pid, c in
            var f = SnapshotFields()
            f.i64(T.pid, Int64(pid))
            f.string(T.name, c.name)
            f.u64(T.port, UInt64(c.port))
            return f
        })
        g.list(T.running, running.values.sorted { $0.contextID < $1.contextID }.map { io in
            var f = SnapshotFields()
            f.u64(T.id, UInt64(io.contextID))
            f.u64(T.device, UInt64(io.deviceID))
            f.i64(T.pid, Int64(io.pid))
            f.u64(T.regionSize, UInt64(io.regionSize))
            f.u64(T.entry, UInt64(io.entry))
            f.u64(T.ioPort, UInt64(io.ioPort))
            f.u64(T.wakePort, UInt64(io.wakePort))
            f.u64(T.sampleTime, io.sampleTime.bitPattern)
            f.u64(T.ticksPerFrame, io.ticksPerFrame.bitPattern)
            return f
        })
        return g
    }

    /// After a restore: the recorded state. The host task holds the
    /// recorded rights under their recorded names (object and IO ports in
    /// the service's port set, the clients' ports with their dead-name
    /// requests, wake ports, memory entries, workgroup ports), so only the
    /// tables come back. Each running IO context gets a wake 0 at once
    /// (audio-host.md §10: a restart), so a client waiting since the save
    /// carries on. Returns the number of running IO contexts.
    @discardableResult
    public func restoreState(_ r: SnapshotFieldReader) throws -> Int {
        typealias T = SnapTag
        func u32s(_ f: SnapshotFieldReader, _ tag: UInt16) -> [UInt32] { f.u64s(tag).map { UInt32(truncatingIfNeeded: $0) } }
        var state = AudioObjectModel.State(aggregates: [], contexts: [], nextID: r.u32(T.nextID, default: 0x100),
                                           powerHint: r.u32(T.powerHint), volume: Float(bitPattern: r.u32(T.volume)))
        for f in r.list(T.aggregates) {
            state.aggregates.append(AudioObjectModel.Aggregate(
                id: f.u32(T.id), streamID: f.u32(T.stream), subdeviceID: f.u32(T.subdevice), uid: f.string(T.uid) ?? "",
                name: f.string(T.name) ?? "", creatorPID: f.i32(T.pid), composition: f.bytes(T.composition),
                preferredStereo: u32s(f, T.stereo), layout: f.bytes(T.layout)))
        }
        for f in r.list(T.contexts) {
            var c = AudioObjectModel.IOContext(id: f.u32(T.id), deviceID: f.u32(T.device), creatorPID: f.i32(T.pid))
            c.bufferFrames = f.u32(T.frames, default: AudioObjectModel.bufferFrames)
            for (scope, u) in zip(u32s(f, T.usageScopes), f.list(T.usage)) { c.streamUsage[scope] = u32s(u, T.values) }
            state.contexts.append(c)
        }
        var ports: [UInt32: UInt32] = [:]
        if let op = r.nested(T.objectPorts) { for (k, v) in zip(u32s(op, T.keys), u32s(op, T.values)) { ports[k] = v } }
        var groups: [UInt32: UInt32] = [:]
        if let wg = r.nested(T.workgroups) { for (k, v) in zip(u32s(wg, T.keys), u32s(wg, T.values)) { groups[k] = v } }
        var restoredClients: [Int32: Client] = [:]
        for f in r.list(T.clients) { restoredClients[f.i32(T.pid)] = Client(name: f.string(T.name) ?? "", port: f.u32(T.port)) }
        var io: [IOState] = []
        for f in r.list(T.running) {
            let entry = f.u32(T.entry)
            guard let (memory, _, _) = host.memoryEntry(entry) else {
                throw SnapshotError("audio: IO context \(f.u32(T.id)): memory entry 0x\(String(entry, radix: 16)) is gone")
            }
            let st = IOState(contextID: f.u32(T.id), deviceID: f.u32(T.device), pid: f.i32(T.pid), region: memory,
                             regionSize: Int(f.u64(T.regionSize)), entry: entry, ioPort: f.u32(T.ioPort), wakePort: f.u32(T.wakePort))
            st.sampleTime = Double(bitPattern: f.u64(T.sampleTime))
            st.ticksPerFrame = Double(bitPattern: f.u64(T.ticksPerFrame, default: 500.0.bitPattern))
            io.append(st)
        }
        lock.withLock {
            model.restore(state)
            objectPorts = ports
            workgroups = groups
            clients = restoredClients
            running = [:]
            contextByIOPort = [:]
            for p in ports.values { try? host.addMember(p, to: portSet) }
            for st in io {
                try? host.addMember(st.ioPort, to: portSet)
                running[st.contextID] = st
                contextByIOPort[st.ioPort] = st.contextID
            }
            resumePending = !io.isEmpty
        }
        log("audio: restored \(state.aggregates.count) aggregates, \(state.contexts.count) IO contexts "
            + "(\(io.count) running), \(restoredClients.count) clients")
        return io.count
    }

    /// Restored IO contexts wait for the guest clock (`setGuestClock`).
    private var resumePending = false

    /// After a restore, once the guest clock is known: each running IO
    /// context's device clock goes on from its saved cycle, and the client
    /// gets a wake 0 (a restart).
    public func resumeRestoredIO() {
        lock.withLock {
            guard resumePending else { return }
            resumePending = false
            let now = MachTimebase.hostMonotonicNanoseconds()
            let ticks = guestClock().ticks
            for st in running.values {
                let frames = Double(model.context(st.contextID)?.bufferFrames ?? AudioObjectModel.bufferFrames)
                let next = st.sampleTime + frames
                st.anchored = true
                st.anchorNs = now &- nanoseconds(frames: next)
                st.anchorTicks = ticks &- UInt64((next * st.ticksPerFrame).rounded())
                st.restarts += 1
                wake(st, id: 0, sampleTime: next, frames: frames)
            }
        }
    }

    // MARK: Statistics (tests, logs)

    public var runningContexts: [UInt32] { lock.withLock { running.keys.sorted() } }
    public func cycles(of context: UInt32) -> Int { lock.withLock { running[context]?.cycles ?? 0 } }
    public var aggregateCount: Int { lock.withLock { model.aggregates.count } }
}
