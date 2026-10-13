// The service logic, independent of Mach (metal-sim-protocol.md §2–§8,
// §12): processes and their three connections, guest refs → handles,
// messages → backend calls and reply dictionaries, completion events.
// `MetalHostService` feeds it from the host task; tests feed it directly.

import Foundation
import YcodeXPC

/// What the core needs from the transport.
protocol MetalHostTransport: AnyObject {
    /// Sends a one-way event dictionary to a client's event port. Returns
    /// false when the port is gone.
    func sendEvent(_ event: XPCDict, to port: UInt32) -> Bool
    /// Drops one reference of a right the service kept.
    func dropRight(_ name: UInt32)
}

/// Counters for logs and tests.
public struct MetalHostStatistics: Sendable {
    public var messages: [UInt64: Int] = [:]
    public var deviceOps: [UInt32: Int] = [:]
    public var submissions = 0
    public var scheduledEvents = 0
    public var completedEvents = 0
    /// Records the decoder did not know, by op.
    public var unknownRecords: [UInt32: Int] = [:]
    /// Messages or device ops the service refused (key "mt" or "mt:op").
    public var refused: [String: Int] = [:]
    public var backendErrors = 0
    public var processes = 0
    public var liveObjects = 0
    public init() {}
}

final class MetalHostCore: @unchecked Sendable {
    static let handshakeVersion: UInt64 = 10
    static let hostFeatureProfile: UInt64 = 10

    let backend: MetalBackend
    let memory: MetalGuestMemoryResolver?
    let surfaces: IOSurfaceResolver?
    let log: (String) -> Void
    let registryID: UInt64
    weak var transport: MetalHostTransport?
    /// Clock for event times (host seconds).
    var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }

    private let lock = NSLock()
    private var processes: [MetalProcessID: Process] = [:]
    private var connections: [UInt32: Connection] = [:]
    private var nextProcess: MetalProcessID = 1
    private var nextHandle: UInt64 = 1
    private var nextGPUAddress: UInt64 = 0x100_0000_0000
    private var stats = MetalHostStatistics()
    private var loggedUnknown: Set<String> = []

    init(backend: MetalBackend, memory: MetalGuestMemoryResolver?, surfaces: IOSurfaceResolver?,
         registryID: UInt64 = 0x1_0000_0059, log: @escaping (String) -> Void) {
        self.backend = backend
        self.memory = memory
        self.surfaces = surfaces
        self.registryID = registryID
        self.log = log
    }

    // MARK: State

    struct Connection {
        var clientPort: UInt32
        var type: UInt64?
        var process: MetalProcessID?
    }

    /// Per-kind guest refs: lowest free number from 1 (released refs are reused).
    struct RefTable {
        var map: [UInt32: MetalHandle] = [:]
        var next: UInt32 = 1
        var free: [UInt32] = []

        mutating func allocate(_ h: MetalHandle) -> UInt32 {
            let ref: UInt32
            if let i = free.indices.min(by: { free[$0] < free[$1] }) {
                ref = free.remove(at: i)
            } else {
                ref = next
                next += 1
            }
            map[ref] = h
            return ref
        }

        mutating func remove(_ ref: UInt32) -> MetalHandle? {
            guard let h = map.removeValue(forKey: ref) else { return nil }
            free.append(ref)
            return h
        }
    }

    final class Object {
        let kind: MetalRefKind
        let ref: UInt32
        /// Rights kept for the object's life (shared memory, IOSurface port).
        var rights: [UInt32] = []
        var heap: MetalHandle?
        var heapBytes: UInt64 = 0
        var heapSize: UInt64 = 0
        var heapUsed: UInt64 = 0
        var gpuAddress: UInt64 = 0
        var eventValue: UInt64 = 0
        /// Between `add` and the end of the backend's create call.
        var pendingCreate = false
        init(kind: MetalRefKind, ref: UInt32) { self.kind = kind; self.ref = ref }
    }

    /// Every `var` of a process is read and written only under the core's lock.
    final class Process: @unchecked Sendable {
        let id: MetalProcessID
        var connections: Set<UInt32> = []
        var eventPort: UInt32 = 0
        var tables: [MetalRefKind: RefTable] = [:]
        var objects: [MetalHandle: Object] = [:]
        /// Objects whose create call was still running when the process
        /// ended: `finishCreate` releases them.
        var orphans: [MetalHandle: Object] = [:]
        var ended = false
        /// The guest pid of the first hand-shake's sender (diagnostics; 0 = unknown).
        var guestPID: Int32 = 0
        /// Diagnostics: submissions, events sent, the last submission (host seconds).
        var submitted = 0
        var scheduledSent = 0
        var completedSent = 0
        var errorsCompleted = 0
        var lastSubmit: Double = 0
        let events: DispatchQueue
        init(id: MetalProcessID) {
            self.id = id
            events = DispatchQueue(label: "ycode.metal.events.\(id)")
        }

        func handle(_ kind: MetalRefKind, _ ref: UInt32) -> MetalHandle? { tables[kind]?.map[ref] }
    }

    var statistics: MetalHostStatistics {
        lock.withLock {
            var s = stats
            s.processes = processes.count
            s.liveObjects = processes.values.reduce(0) { $0 + $1.objects.count }
            return s
        }
    }

    /// Diagnostics: one line per live client process (guest pid, objects,
    /// submissions, events sent, submissions still waiting for event 101).
    func processSummary() -> [String] {
        lock.withLock {
            let now = clock()
            return processes.values.sorted { $0.id < $1.id }.map { p in
                let idle = p.lastSubmit == 0 ? "never" : String(format: "%.1f s ago", now - p.lastSubmit)
                return "process \(p.id) (guest pid \(p.guestPID)): \(p.objects.count) objects, \(p.submitted) submitted, "
                    + "\(p.scheduledSent) scheduled, \(p.completedSent) completed (\(p.errorsCompleted) with errors), "
                    + "\(p.submitted - p.completedSent) outstanding; last submission \(idle)"
            }
        }
    }

    // MARK: Connections

    func connectionOpened(_ id: UInt32, clientPort: UInt32) {
        lock.withLock { connections[id] = Connection(clientPort: clientPort) }
    }

    /// The connection's port lost its senders (the client ended or closed
    /// it). Returns the client port to drop. Ends the process when it was
    /// its last connection.
    @discardableResult
    func connectionClosed(_ id: UInt32) -> UInt32? {
        var ended: Process?
        let client: UInt32? = lock.withLock {
            guard let c = connections.removeValue(forKey: id) else { return nil }
            if let pid = c.process, let p = processes[pid] {
                p.connections.remove(id)
                if p.connections.isEmpty {
                    processes[pid] = nil
                    p.ended = true
                    ended = p
                }
            }
            return c.clientPort
        }
        if let p = ended { tearDown(p) }
        return client
    }

    /// Whether objects of this kind exist in the backend.
    static func isBackendObject(_ kind: MetalRefKind) -> Bool {
        ![.queue, .argumentLayout, .argumentEncoder, .heap].contains(kind)
    }

    private func tearDown(_ p: Process) {
        let objects = lock.withLock { () -> [(key: MetalHandle, value: Object)] in
            var all: [(key: MetalHandle, value: Object)] = []
            for (h, o) in p.objects.sorted(by: { $0.key > $1.key }) {
                if o.pendingCreate { p.orphans[h] = o } else { all.append((h, o)) }
            }
            p.objects.removeAll()
            return all
        }
        for (h, o) in objects {
            if Self.isBackendObject(o.kind) { backend.release(h) }
            for r in o.rights { transport?.dropRight(r) }
        }
        log("metal: process \(p.id) (guest pid \(p.guestPID)) ended; released \(objects.count) objects")
    }

    /// Called after every backend create call (successful or not, or
    /// skipped). If the process ended meanwhile, the object is released
    /// here, so nothing created for a dead process stays in the backend.
    private func finishCreate(_ h: MetalHandle, _ p: Process) {
        let orphan: Object? = lock.withLock {
            let o = p.objects[h] ?? p.orphans[h]
            o?.pendingCreate = false
            guard p.ended else { return nil }
            p.objects[h] = nil
            return p.orphans.removeValue(forKey: h) ?? o
        }
        guard let o = orphan else { return }
        log("metal: \(h) was created after process \(p.id) ended; released")
        if Self.isBackendObject(o.kind) { backend.release(h) }
        for r in o.rights { transport?.dropRight(r) }
    }

    // MARK: Messages

    struct Outcome {
        /// The reply (nil: none, for one-way messages).
        var reply: XPCDict?
        /// Rights of the message the core keeps (the transport drops the rest).
        var retained: [UInt32] = []
    }

    private func refuse(_ key: String, _ why: String) {
        let first = lock.withLock { () -> Bool in
            stats.refused[key, default: 0] += 1
            return loggedUnknown.insert("refuse " + key).inserted
        }
        if first { log("metal: refused \(key): \(why) (further ones counted, not logged)") }
    }

    /// Logs each pipeline-descriptor key the decoder does not model, once
    /// per kind and key (with the first value seen).
    private func noteUnknownKeys(_ kind: String, _ keys: [UInt8: UInt64]) {
        guard !keys.isEmpty else { return }
        let fresh: [(UInt8, UInt64)] = lock.withLock {
            keys.sorted { $0.key < $1.key }.filter { loggedUnknown.insert("\(kind) key \($0.key)").inserted }
        }
        for (k, v) in fresh { log("metal: \(kind) descriptor key \(k) is not modelled (first value \(v)); ignored") }
    }

    private func backendFailed(_ what: String, _ error: Error) {
        lock.withLock { stats.backendErrors += 1 }
        log("metal: backend \(what) failed: \(error)")
    }

    func handle(_ d: XPCDict, connection: UInt32, senderPID: Int32 = 0) -> Outcome {
        let mt = d["messageType"]?.integerValue ?? .max
        lock.withLock { stats.messages[mt, default: 0] += 1 }
        if mt == 0 { return handshake(d, connection: connection, senderPID: senderPID) }
        guard let process = lock.withLock({ () -> Process? in
            guard let c = connections[connection], let pid = c.process else { return nil }
            return processes[pid]
        }) else {
            refuse("\(mt)", "message before the hand-shake")
            return Outcome(reply: mt == 6 || mt == 14 ? nil : [:])
        }
        switch mt {
        case 1: return newBuffer(d, process)
        case 6: submit(d, process); return Outcome(reply: nil)
        case 7: return newQueue(d, process)
        case 8: return newStateObject(d, process)
        case 9: return replaceRegion(d, process)
        case 10: return getBytes(d, process)
        case 12: return deviceOp(d, process)
        case 13: return newIOSurfaceTexture(d, process)
        case 14: release(d, process); return Outcome(reply: nil)
        case 15: return newFunction(d, process)
        default:
            refuse("\(mt)", "unknown message type")
            return Outcome(reply: [:])
        }
    }

    // MARK: Hand-shake (§2.3)

    private func handshake(_ d: XPCDict, connection: UInt32, senderPID: Int32) -> Outcome {
        let type = d["connectionType"]?.integerValue ?? 0
        let requested = d["processRef"]?.integerValue ?? 0
        let pid: MetalProcessID = lock.withLock {
            var p: Process
            if requested != 0, let existing = processes[requested] {
                p = existing
            } else {
                p = Process(id: nextProcess)
                nextProcess += 1
                processes[p.id] = p
            }
            if var c = connections[connection] {
                c.type = type
                c.process = p.id
                connections[connection] = c
                if type == 0 { p.eventPort = c.clientPort }
            }
            p.connections.insert(connection)
            if p.guestPID == 0 { p.guestPID = senderPID }
            return p.id
        }
        if requested != 0 && requested != pid { log("metal: hand-shake named unknown process \(requested); new process \(pid)") }
        return Outcome(reply: ["version": .uint64(Self.handshakeVersion), "processRef": .uint64(pid),
                               "registryID": .uint64(registryID), "hostFeatureProfile": .uint64(Self.hostFeatureProfile)])
    }

    // MARK: Objects

    /// Allocates a handle and a guest ref of `kind` (lock taken).
    private func add(_ kind: MetalRefKind, _ p: Process, configure: (Object) -> Void = { _ in }) -> (MetalHandle, UInt32) {
        lock.withLock {
            let h = MetalHandle(nextHandle)
            nextHandle += 1
            var t = p.tables[kind] ?? RefTable()
            let ref = t.allocate(h)
            p.tables[kind] = t
            let o = Object(kind: kind, ref: ref)
            o.pendingCreate = Self.isBackendObject(kind)
            configure(o)
            p.objects[h] = o
            return (h, ref)
        }
    }

    private func lookUp(_ kind: MetalRefKind, _ ref: UInt32, _ p: Process) -> MetalHandle? {
        lock.withLock { p.handle(kind, ref) }
    }

    static func refReply(_ ref: UInt32, words: Int = 2) -> XPCDict {
        var w = MetalByteWriter()
        w.u32(ref)
        for _ in 1..<max(words, 1) { w.u32(0) }
        return ["replyData": .data(w.bytes)]
    }

    /// The bytes of a data value: inline, or by memory entry (copied).
    private func bytes(of value: XPCObject?) -> [UInt8]? {
        switch value {
        case let .data(b)?: return b
        case let .largeData(length, port)?:
            guard let region = memory?.region(forMemoryEntry: port.name), region.length >= Int(length) else {
                log("metal: cannot map \(length) bytes of data by memory entry \(port)")
                return nil
            }
            return region.bytes(count: Int(length))
        default: return nil
        }
    }

    private func command(_ d: XPCDict) -> MetalRecord? {
        guard let data = bytes(of: d["command"]) else { return nil }
        return try? MetalRecord.parse(data)
    }

    // messageType 1 (§5.1)
    private func newBuffer(_ d: XPCDict, _ p: Process) -> Outcome {
        let length = Int(d["length"]?.integerValue ?? 0)
        let options = d["options"]?.integerValue ?? 0
        var storage = MetalStorageMode(resourceOptions: options)
        var region: GuestSharedRegion?
        var retained: [UInt32] = []
        if case let .sharedMemory(size, port)? = d["sharedMem"] {
            if let r = memory?.region(forMemoryEntry: port.name) {
                region = r.slice(at: 0, count: max(length, min(Int(size), r.length)))
                retained.append(port.name)
            } else {
                log("metal: buffer of \(length) bytes: shared memory \(port) not resolvable; host memory instead")
            }
        }
        if region == nil, storage == .shared || storage == .managed { storage = .private }
        return makeBuffer(p, length: length, storage: storage, region: region, retained: retained, heap: nil,
                          reply: { ref in ["bufferRef": .uint64(UInt64(ref))] })
    }

    private func makeBuffer(_ p: Process, length: Int, storage: MetalStorageMode, region: GuestSharedRegion?, retained: [UInt32],
                            heap: MetalHandle?, reply: (UInt32) -> XPCDict) -> Outcome {
        let span = (UInt64(max(length, 1)) + 0xFFFF) & ~0xFFFF
        let (h, ref) = add(.resource, p) { o in
            o.rights = retained
            o.heap = heap
            o.heapBytes = heap == nil ? 0 : (UInt64(length) + 255) & ~255
            o.gpuAddress = self.nextGPUAddress
            self.nextGPUAddress += span + 0x1_0000
        }
        if let heap {
            lock.withLock { if let ho = p.objects[heap] { ho.heapUsed += (UInt64(length) + 255) & ~255 } }
        }
        do { try backend.createBuffer(h, length: length, storage: storage, guestMemory: region) } catch {
            backendFailed("createBuffer \(h)", error)
        }
        finishCreate(h, p)
        return Outcome(reply: reply(ref), retained: retained)
    }

    // messageType 7 (§8.1)
    private func newQueue(_ d: XPCDict, _ p: Process) -> Outcome {
        let (_, ref) = add(.queue, p)
        return Outcome(reply: ["commandQueueRef": .uint64(UInt64(ref))])
    }

    // messageType 8: ops 1, 3, 4 (§5.2, §5.5, §5.6)
    private func newStateObject(_ d: XPCDict, _ p: Process) -> Outcome {
        guard let rec = command(d) else {
            refuse("8", "no command record")
            return Outcome(reply: [:])
        }
        do {
            switch rec.op {
            case 1:
                var r = ByteReader(rec.body)
                let desc = try MetalDescriptorCodec.texture(&r)
                let (h, ref) = add(.resource, p)
                do { try backend.createTexture(h, desc, iosurface: nil) } catch { backendFailed("createTexture \(h)", error) }
                finishCreate(h, p)
                return Outcome(reply: Self.refReply(ref, words: 1))
            case 3:
                let desc = try MetalDescriptorCodec.sampler(rec.body)
                let (h, ref) = add(.sampler, p)
                do { try backend.createSampler(h, desc) } catch { backendFailed("createSampler \(h)", error) }
                finishCreate(h, p)
                return Outcome(reply: Self.refReply(ref, words: 1))
            case 4:
                let desc = try MetalDescriptorCodec.depthStencil(rec.body)
                let (h, ref) = add(.depthStencil, p)
                do { try backend.createDepthStencilState(h, desc) } catch { backendFailed("createDepthStencilState \(h)", error) }
                finishCreate(h, p)
                return Outcome(reply: Self.refReply(ref, words: 1))
            default:
                refuse("8:\(rec.op)", "unknown object op")
                return Outcome(reply: [:])
            }
        } catch {
            refuse("8:\(rec.op)", "malformed: \(error)")
            return Outcome(reply: [:])
        }
    }

    // messageType 13 op 47 (§5.4)
    private func newIOSurfaceTexture(_ d: XPCDict, _ p: Process) -> Outcome {
        guard let rec = command(d), rec.op == 47 else {
            refuse("13", "no op-47 record")
            return Outcome(reply: [:])
        }
        var r = ByteReader(rec.body)
        guard let desc = try? MetalDescriptorCodec.texture(&r) else {
            refuse("13:47", "malformed descriptor")
            return Outcome(reply: [:])
        }
        let plane = Int((try? r.u32()) ?? 0)
        var backing: IOSurfaceBacking?
        var retained: [UInt32] = []
        if let port = d["iosurface"]?.port {
            backing = surfaces?.backing(forSurfacePort: port.name, plane: plane)
            retained.append(port.name)
            if backing == nil { log("metal: IOSurface port \(port) unknown; texture gets host memory") }
        } else {
            log("metal: op 47 without an iosurface right")
        }
        let (h, ref) = add(.resource, p) { $0.rights = retained }
        do { try backend.createTexture(h, desc, iosurface: backing) } catch { backendFailed("createTexture(IOSurface) \(h)", error) }
        finishCreate(h, p)
        return Outcome(reply: Self.refReply(ref), retained: retained)
    }

    // messageType 15 (§6)
    private func newFunction(_ d: XPCDict, _ p: Process) -> Outcome {
        guard let ir = bytes(of: d["functionIR"]) else {
            refuse("15", "no functionIR")
            return Outcome(reply: [:])
        }
        let (h, ref) = add(.function, p)
        do { try backend.createFunction(h, metallib: ir) } catch { backendFailed("createFunction \(h)", error) }
        finishCreate(h, p)
        return Outcome(reply: Self.refReply(ref))
    }

    // messageType 14 (§3)
    static func releaseKinds(_ op: UInt32) -> [MetalRefKind]? {
        switch op {
        case 1000, 1001: [.resource]
        case 1002: [.depthStencil]
        case 1003: [.sampler]
        case 1005: [.function]
        case 1006: [.computePipeline]
        case 1007: [.renderPipeline]
        case 1008: [.queue]
        case 1009: [.fence]
        case 1010: [.argumentLayout, .argumentEncoder]
        case 1011: [.argumentEncoder, .argumentLayout]
        case 1012: [.heap]
        case 1013: [.event]
        default: nil
        }
    }

    private func release(_ d: XPCDict, _ p: Process) {
        guard let rec = command(d), let kinds = Self.releaseKinds(rec.op) else {
            refuse("14", "unknown release record")
            return
        }
        var r = ByteReader(rec.body)
        guard let ref = try? r.u32() else { return }
        let found: (MetalHandle, Object)? = lock.withLock {
            for k in kinds {
                guard var t = p.tables[k], let h = t.remove(ref) else { continue }
                p.tables[k] = t
                guard let o = p.objects.removeValue(forKey: h) else { return nil }
                if let heap = o.heap, let ho = p.objects[heap] { ho.heapUsed -= min(ho.heapUsed, o.heapBytes) }
                return (h, o)
            }
            return nil
        }
        guard let (h, o) = found else {
            log("metal: release op \(rec.op) of unknown ref \(ref) (process \(p.id))")
            return
        }
        if Self.isBackendObject(o.kind) { backend.release(h) }
        for right in o.rights { transport?.dropRight(right) }
    }

    // messageType 9 op 2 (§5.3)
    private func replaceRegion(_ d: XPCDict, _ p: Process) -> Outcome {
        guard let rec = command(d), rec.op == 2 else {
            refuse("9", "no op-2 record")
            return Outcome(reply: [:])
        }
        var r = ByteReader(rec.body)
        guard let head = try? MetalDescriptorCodec.regionHead(&r) else {
            refuse("9:2", "malformed")
            return Outcome(reply: [:])
        }
        let pixels = r.rest()
        if let h = lookUp(.resource, head.texture, p) {
            do {
                try backend.replaceRegion(texture: h, head.region, level: head.level, slice: head.slice, bytes: pixels,
                                          bytesPerRow: head.bytesPerRow, bytesPerImage: head.bytesPerImage)
            } catch { backendFailed("replaceRegion \(h)", error) }
        } else {
            log("metal: replaceRegion of unknown texture ref \(head.texture)")
        }
        return Outcome(reply: [:])
    }

    // messageType 10 op 5 (§5.3)
    private func getBytes(_ d: XPCDict, _ p: Process) -> Outcome {
        guard let rec = command(d), rec.op == 5 else {
            refuse("10", "no op-5 record")
            return Outcome(reply: [:])
        }
        var r = ByteReader(rec.body)
        guard let head = try? MetalDescriptorCodec.regionHead(&r) else {
            refuse("10:5", "malformed")
            return Outcome(reply: [:])
        }
        let size = Int((try? r.u64()) ?? 0)
        guard case let .sharedMemory(_, port)? = d["sharedMem"], let region = memory?.region(forMemoryEntry: port.name) else {
            log("metal: getBytes without resolvable shared memory")
            return Outcome(reply: [:])
        }
        if let h = lookUp(.resource, head.texture, p) {
            do {
                try backend.getBytes(texture: h, head.region, level: head.level, slice: head.slice,
                                     into: region.slice(at: 0, count: size > 0 ? size : region.length),
                                     bytesPerRow: head.bytesPerRow, bytesPerImage: head.bytesPerImage)
            } catch { backendFailed("getBytes \(h)", error) }
        } else {
            log("metal: getBytes of unknown texture ref \(head.texture)")
        }
        return Outcome(reply: [:])
    }

    // MARK: Device operations (messageType 12, §4.2)

    private func deviceOp(_ d: XPCDict, _ p: Process) -> Outcome {
        guard let rec = command(d) else {
            refuse("12", "no command record")
            return Outcome(reply: [:])
        }
        lock.withLock { stats.deviceOps[rec.op, default: 0] += 1 }
        do {
            if let reply = try deviceOp(rec, p) { return Outcome(reply: reply) }
            refuse("12:\(rec.op)", "unknown device op")
        } catch {
            refuse("12:\(rec.op)", "malformed: \(error)")
        }
        return Outcome(reply: [:])
    }

    private static func u64Reply(_ values: [UInt64]) -> XPCDict {
        var w = MetalByteWriter()
        for v in values { w.u64(v) }
        return ["replyData": .data(w.bytes)]
    }

    /// Heap size of a texture (op 22): levels rounded to 1 KiB, slices and
    /// samples multiplied, at least what the texture needs (an over-estimate).
    static func heapTextureSize(_ t: MetalTextureDescriptor) -> UInt64 {
        let bpp = UInt64(MetalPixelFormat.bytesPerPixel(t.pixelFormat) ?? 16)
        var total: UInt64 = 0
        for level in 0..<max(t.mipmapLevelCount, 1) {
            let w = UInt64(max(t.width >> level, 1)), h = UInt64(max(t.height >> level, 1)), dd = UInt64(max(t.depth >> level, 1))
            total += (w * h * dd * bpp + 1023) & ~1023
        }
        let faces: UInt64 = t.textureType == MetalTextureType.typeCube || t.textureType == MetalTextureType.typeCubeArray ? 6 : 1
        return total * UInt64(max(t.arrayLength, 1)) * faces * UInt64(max(t.sampleCount, 1))
    }

    private func deviceOp(_ rec: MetalRecord, _ p: Process) throws -> XPCDict? {
        var r = ByteReader(rec.body)
        switch rec.op {
        case 7, 8, 27:
            _ = try r.u32()
            let parentRef = try r.u32()
            var view: MetalTextureViewDescriptor
            if rec.op == 7 {
                view = MetalTextureViewDescriptor(pixelFormat: try r.u32())
            } else {
                let pf = try r.u16(), type = try r.u16()
                let ll = try r.int64(), ln = try r.int64(), sl = try r.int64(), sn = try r.int64()
                view = MetalTextureViewDescriptor(pixelFormat: UInt32(pf), textureType: UInt8(truncatingIfNeeded: type),
                                                  levels: ll..<(ll + ln), slices: sl..<(sl + sn))
                if rec.op == 27 {
                    let s = try r.u32()
                    view.swizzle = [UInt8(s & 0xFF), UInt8((s >> 8) & 0xFF), UInt8((s >> 16) & 0xFF), UInt8(s >> 24)]
                }
            }
            let (h, ref) = add(.resource, p)
            if let parent = lookUp(.resource, parentRef, p) {
                do { try backend.createTextureView(h, parent: parent, view) } catch { backendFailed("createTextureView \(h)", error) }
            } else {
                log("metal: texture view of unknown parent ref \(parentRef)")
            }
            finishCreate(h, p)
            return Self.refReply(ref)
        case 11:
            let computePayload = try MetalPipelineCodec.payload(rec.body)
            let fref = try MetalPipelineCodec.computeFunctionRef(computePayload)
            noteUnknownKeys("compute pipeline", MetalPipelineCodec.computeUnknownKeys(computePayload))
            let (h, ref) = add(.computePipeline, p)
            var info = MetalComputePipelineInfo()
            if let f = lookUp(.function, fref, p) {
                do { info = try backend.createComputePipeline(h, function: f) } catch { backendFailed("createComputePipeline \(h)", error) }
            } else {
                log("metal: compute pipeline with unknown function ref \(fref)")
            }
            finishCreate(h, p)
            var w = MetalByteWriter()
            w.u32(ref); w.u32(0); w.u16(info.maxTotalThreadsPerThreadgroup); w.u16(info.threadExecutionWidth)
            w.pad(to: 24)
            return ["replyData": .data(w.bytes)]
        case 13:
            let (h, ref) = add(.fence, p)
            do { try backend.createFence(h) } catch { backendFailed("createFence \(h)", error) }
            finishCreate(h, p)
            return Self.refReply(ref)
        case 14:
            let payload = try MetalPipelineCodec.payload(rec.body)
            let desc = try lock.withLock {
                try MetalPipelineCodec.renderPipeline(payload) { p.handle(.function, $0) }
            }
            noteUnknownKeys("render pipeline", desc.unknownKeys)
            let (h, ref) = add(.renderPipeline, p)
            do { try backend.createRenderPipeline(h, desc) } catch { backendFailed("createRenderPipeline \(h)", error) }
            finishCreate(h, p)
            return Self.refReply(ref)
        case 16:
            let (_, ref) = add(.argumentLayout, p)
            refuse("12:16", "argument-buffer layouts are answered but not modelled")
            var w = MetalByteWriter()
            w.u32(ref); w.u32(0); w.u32(0xFFFF_0001); w.u32(0xFFFF_FFFF)
            return ["replyData": .data(w.bytes)]
        case 17:
            let (_, ref) = add(.argumentEncoder, p)
            var w = MetalByteWriter()
            w.u32(ref); w.u32(0); w.u16(24); w.u16(8); w.u32(0)
            return ["replyData": .data(w.bytes)]
        case 19:
            refuse("12:19", "argument-encoder set calls are not modelled")
            return [:]
        case 20:
            _ = try r.u32()
            let size = try r.u64()
            let (_, ref) = add(.heap, p) { $0.heapSize = size }
            return Self.refReply(ref)
        case 21:
            _ = try r.u32()
            let heapRef = try r.u32()
            var desc = try MetalDescriptorCodec.texture(&r)
            desc.resourceOptions = (desc.resourceOptions & ~0xF0) | 0x20
            let heap = lookUp(.heap, heapRef, p)
            let bytes = Self.heapTextureSize(desc)
            let (h, ref) = add(.resource, p) { $0.heap = heap; $0.heapBytes = heap == nil ? 0 : bytes }
            if let heap { lock.withLock { if let ho = p.objects[heap] { ho.heapUsed += bytes } } }
            do { try backend.createTexture(h, desc, iosurface: nil) } catch { backendFailed("createTexture(heap) \(h)", error) }
            finishCreate(h, p)
            return Self.refReply(ref)
        case 22:
            let desc = try MetalDescriptorCodec.texture(&r)
            return Self.u64Reply([(Self.heapTextureSize(desc) + 127) & ~127, 128])
        case 23:
            let length = try r.u64()
            // The macOS host answered 1000 → 1000, 256 (§4.2).
            return Self.u64Reply([length, 256])
        case 24:
            _ = try r.u32()
            let heapRef = try r.u32()
            let length = try r.int64()
            let heap = lookUp(.heap, heapRef, p)
            let outcome = makeBuffer(p, length: length, storage: .private, region: nil, retained: [], heap: heap,
                                     reply: { Self.refReply($0) })
            return outcome.reply
        case 25:
            return ["replyData": .data([0])]
        case 28:
            let (h, ref) = add(.event, p)
            do { try backend.createEvent(h) } catch { backendFailed("createEvent \(h)", error) }
            finishCreate(h, p)
            return Self.refReply(ref)
        case 30:
            let ref = try r.u32(), value = try r.u64()
            if let h = lookUp(.event, ref, p) {
                lock.withLock { p.objects[h]?.eventValue = value }
                backend.signalEvent(h, value: value)
            }
            return [:]
        case 31:
            let ref = try r.u32()
            let (size, used): (UInt64, UInt64) = lock.withLock {
                guard let h = p.handle(.heap, ref), let o = p.objects[h] else { return (0, 0) }
                return (o.heapSize, o.heapUsed)
            }
            return Self.u64Reply([size, size, used])
        case 32:
            let ref = try r.u32()
            let alignment = max(try r.u64(), 1)
            let available: UInt64 = lock.withLock {
                guard let h = p.handle(.heap, ref), let o = p.objects[h] else { return 0 }
                return (o.heapSize - min(o.heapUsed, o.heapSize)) / alignment * alignment
            }
            return Self.u64Reply([available])
        case 33, 34:
            return Self.u64Reply([16])
        case 35:
            refuse("12:35", "argument-encoder op answered with zero")
            return Self.u64Reply([0])
        case 37:
            let l = backend.limits()
            return Self.u64Reply([l.maxThreadsPerThreadgroup.x, l.maxThreadsPerThreadgroup.y, l.maxThreadsPerThreadgroup.z,
                                  l.maxThreadgroupMemoryLength])
        case 38:
            let ref = try r.u32()
            guard let h = lookUp(.resource, ref, p) else { return Self.u64Reply([0]) }
            let address = backend.gpuAddress(ofBuffer: h) ?? lock.withLock { p.objects[h]?.gpuAddress } ?? 0
            return Self.u64Reply([address])
        case 39:
            let ref = try r.u32()
            guard let h = lookUp(.sampler, ref, p) else { return Self.u64Reply([0]) }
            return Self.u64Reply([backend.gpuResourceID(ofSampler: h) ?? h.raw])
        case 41:
            let ref = try r.u32()
            guard let h = lookUp(.event, ref, p) else { return Self.u64Reply([0]) }
            return Self.u64Reply([backend.eventValue(h) ?? lock.withLock { p.objects[h]?.eventValue } ?? 0])
        default:
            return nil
        }
    }

    // MARK: Submission and completion (§8.1, §8.5, §9)

    final class InFlight: @unchecked Sendable {
        var sentScheduled = false
        var sentCompleted = false
        let start: Double
        init(start: Double) { self.start = start }
    }

    private func submit(_ d: XPCDict, _ p: Process) {
        let cbRef = d["commandBufferRef"]?.integerValue ?? 0
        let queueRef = UInt32(truncatingIfNeeded: d["commandQueue"]?.integerValue ?? 0)
        var segments: [[UInt8]] = []
        for (i, s) in (d["segments"]?.arrayValue ?? []).enumerated() {
            guard let b = bytes(of: s) else {
                log("metal: submission \(cbRef): segment \(i) unreadable")
                continue
            }
            segments.append(b)
        }
        var missing = 0
        let (cb, unknownOps) = lock.withLock {
            MetalCommandDecoder.decode(segments: segments, process: p.id, queue: p.handle(.queue, queueRef),
                                       commandBufferRef: cbRef) { kind, ref in
                if let h = p.handle(kind, ref) { return h }
                missing += 1
                return nil
            }
        }
        var newUnknown: [UInt32] = []
        lock.withLock {
            stats.submissions += 1
            p.submitted += 1
            p.lastSubmit = clock()
            for (op, n) in unknownOps {
                stats.unknownRecords[op, default: 0] += n
                if loggedUnknown.insert("record \(op)").inserted { newUnknown.append(op) }
            }
        }
        for op in newUnknown.sorted() { log("metal: unknown command record op \(op) (kept as .unknown; counted from now on)") }
        if missing > 0 { log("metal: submission \(cbRef) of process \(p.id) names \(missing) unknown refs") }
        for diag in cb.diagnostics { log("metal: submission \(cbRef): \(diag)") }

        let flight = InFlight(start: clock())
        backend.submit(cb, scheduled: { [weak self] in
            guard let core = self else { return }
            p.events.async { core.sendScheduled(p, cbRef, flight) }
        }, completed: { [weak self] status in
            guard let core = self else { return }
            p.events.async { core.sendCompleted(p, cbRef, flight, status: status) }
        })
    }

    private func event(_ type: UInt64, _ cbRef: UInt64, status: Int, start: Double, end: Double) -> XPCDict {
        ["messageType": .uint64(type), "commandBufferRef": .uint64(cbRef), "status": .uint64(UInt64(status)),
         "error": .uint64(1), "startTime": .double(start), "endTime": .double(end)]
    }

    /// The process's event port, read under the lock; nil once the process ended.
    private func eventPort(_ p: Process) -> UInt32? {
        lock.withLock { p.ended ? nil : p.eventPort }
    }

    /// On `p.events` (the `InFlight` flags are touched only there).
    private func sendScheduled(_ p: Process, _ cbRef: UInt64, _ f: InFlight) {
        guard !f.sentScheduled, !f.sentCompleted, let port = eventPort(p) else { return }
        f.sentScheduled = true
        _ = transport?.sendEvent(event(100, cbRef, status: MetalCommandBufferStatus.scheduled, start: f.start, end: clock()),
                                 to: port)
        lock.withLock { stats.scheduledEvents += 1; p.scheduledSent += 1 }
    }

    /// On `p.events`. Sends 100 first when the backend never reported it.
    private func sendCompleted(_ p: Process, _ cbRef: UInt64, _ f: InFlight, status: Int) {
        guard !f.sentCompleted, eventPort(p) != nil else { return }
        let end = clock()
        if !f.sentScheduled { sendScheduled(p, cbRef, f) }
        guard let port = eventPort(p) else { return }
        f.sentCompleted = true
        _ = transport?.sendEvent(event(101, cbRef, status: status, start: f.start, end: end), to: port)
        lock.withLock {
            stats.completedEvents += 1
            p.completedSent += 1
            if status != MetalCommandBufferStatus.completed { p.errorsCompleted += 1 }
        }
    }

    /// Waits until every event queued so far for every process is sent (tests).
    func drainEvents() {
        let ps = lock.withLock { Array(processes.values) }
        for p in ps { p.events.sync {} }
    }
}
