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
    /// A new port of the host (a receive right) that names an exported
    /// shared event (messageType 17); nil when none can be made.
    func makeEventPort() -> UInt32?
    /// Destroys a port made by `makeEventPort`.
    func destroyEventPort(_ name: UInt32)
}

extension MetalHostTransport {
    func makeEventPort() -> UInt32? { nil }
    func destroyEventPort(_ name: UInt32) {}
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

    // Internal (not private) for the snapshot extension (MetalHostSnapshot.swift).
    let lock = NSLock()
    var processes: [MetalProcessID: Process] = [:]
    var connections: [UInt32: Connection] = [:]
    var nextProcess: MetalProcessID = 1
    var nextHandle: UInt64 = 1
    var nextGPUAddress: UInt64 = 0x100_0000_0000
    /// Command buffers handed to the backend whose completion event is not
    /// sent yet (a snapshot waits for 0, snapshot.md §8 option 2).
    var inFlight = 0
    /// Exported shared events by host port (messageType 17/18).
    var exportedEvents: [UInt32: SharedEventGroup] = [:]
    /// Shared textures by IOSurface ID (messageTypes 19 and 20): the live
    /// handles over each surface's GPU image, in any process.
    var sharedTextures: [UInt32: Set<MetalHandle>] = [:]
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
        /// How the object was made, for a replay after a snapshot restore.
        var recipe: MetalRecipe?
        /// The guest asked for the buffer's GPU address (op 38).
        var addressQueried = false
        /// A shared event exported (messageType 17) or opened from a handle
        /// (messageType 18): every ref of the group names one event.
        var eventGroup: SharedEventGroup?
        /// A shared texture (messageType 19 or 20): its IOSurface's ID.
        var sharedSurface: UInt32?
        /// messageType 20: the handle's label, and that the object was
        /// opened from a handle (it may share its image with another process).
        var sharedLabel: String?
        var openedHandle = false
        init(kind: MetalRefKind, ref: UInt32) { self.kind = kind; self.ref = ref }
    }

    /// One shared event and the refs that name it, in any process
    /// (visionos.md §10.6.5): the host port its handles carry, the backend
    /// handle of the first ref (the others are backend aliases of it), how
    /// many refs are alive, and the CPU value when the backend keeps none.
    /// Read and written under the core's lock.
    final class SharedEventGroup {
        let original: MetalHandle
        var port: UInt32 = 0
        var members = 1
        var cpuValue: UInt64 = 0
        init(original: MetalHandle) { self.original = original }
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
        /// Released objects that live objects were made from (a pipeline's
        /// function, a view's parent): kept for a replay. `dependents`: how
        /// many live or kept recipes name each handle.
        var ghosts: [MetalHandle: (kind: MetalRefKind, recipe: MetalRecipe)] = [:]
        var dependents: [MetalHandle: Int] = [:]
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

    /// The guest pids of the live client processes (snapshot.md §8 option 1).
    func clientPIDs() -> [Int32] {
        lock.withLock { processes.values.map(\.guestPID).filter { $0 > 0 }.sorted() }
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
            p.ghosts.removeAll()
            p.dependents.removeAll()
            return all
        }
        for (h, o) in objects {
            if let port = leaveEventGroup(o) { transport?.destroyEventPort(port) }
            leaveSharedSurface(h, o)
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
        leaveSharedSurface(h, o)
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
        case 17: return newSharedEventHandle(d, process)
        case 18: return openSharedEventHandle(d, process)
        case 19: return newSharedTexture(d, process)
        case 20: return openSharedTexture(d, process)
        default:
            refuse("\(mt)", "unknown message type; keys: \(Self.describeKeys(d))")
            return Outcome(reply: [:])
        }
    }

    /// The keys of a message with a short form of each value (the first
    /// refusal of an unknown message type logs it).
    static func describeKeys(_ d: XPCDict) -> String {
        d.keys.sorted().map { key -> String in
            guard let v = d[key] else { return key }
            switch v {
            case let .data(b): return "\(key)=data(\(b.count): \(b.prefix(48).map { String(format: "%02x", $0) }.joined()))"
            case let .uint64(x): return "\(key)=\(x)"
            case let .int64(x): return "\(key)=\(x)"
            case let .bool(x): return "\(key)=\(x)"
            case let .string(x): return "\(key)=\"\(x)\""
            case .sendRight: return "\(key)=send right"
            case .receiveRight: return "\(key)=receive right"
            case let .dictionary(sub): return "\(key)={\(describeKeys(sub))}"
            case let .array(a): return "\(key)=array(\(a.count))"
            default: return "\(key)=\(v)"
            }
        }.joined(separator: ", ")
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
        var recipe = MetalRecipe(mt: 1)
        recipe.length = length
        recipe.options = options
        if case let .sharedMemory(size, port)? = d["sharedMem"] { (recipe.right, recipe.rightSize) = (port.name, UInt64(size)) }
        return makeBuffer(p, length: length, storage: storage, region: region, retained: retained, heap: nil, recipe: recipe,
                          reply: { ref in ["bufferRef": .uint64(UInt64(ref))] })
    }

    private func makeBuffer(_ p: Process, length: Int, storage: MetalStorageMode, region: GuestSharedRegion?, retained: [UInt32],
                            heap: MetalHandle?, recipe: MetalRecipe, reply: (UInt32) -> XPCDict) -> Outcome {
        let span = (UInt64(max(length, 1)) + 0xFFFF) & ~0xFFFF
        let (h, ref) = add(.resource, p) { o in
            o.recipe = recipe
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
        let (_, ref) = add(.queue, p) { $0.recipe = MetalRecipe(mt: 7) }
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
                let (h, ref) = add(.resource, p) { $0.recipe = MetalRecipe(mt: 8, op: 1, body: rec.body) }
                do { try backend.createTexture(h, desc, iosurface: nil) } catch { backendFailed("createTexture \(h)", error) }
                finishCreate(h, p)
                return Outcome(reply: Self.refReply(ref, words: 1))
            case 3:
                let desc = try MetalDescriptorCodec.sampler(rec.body)
                let (h, ref) = add(.sampler, p) { $0.recipe = MetalRecipe(mt: 8, op: 3, body: rec.body) }
                do { try backend.createSampler(h, desc) } catch { backendFailed("createSampler \(h)", error) }
                finishCreate(h, p)
                return Outcome(reply: Self.refReply(ref, words: 1))
            case 4:
                let desc = try MetalDescriptorCodec.depthStencil(rec.body)
                let (h, ref) = add(.depthStencil, p) { $0.recipe = MetalRecipe(mt: 8, op: 4, body: rec.body) }
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
        var recipe = MetalRecipe(mt: 13, op: 47, body: rec.body)
        recipe.right = retained.first ?? 0
        recipe.plane = plane
        let (h, ref) = add(.resource, p) { $0.rights = retained; $0.recipe = recipe }
        do { try backend.createTexture(h, desc, iosurface: backing) } catch { backendFailed("createTexture(IOSurface) \(h)", error) }
        finishCreate(h, p)
        return Outcome(reply: Self.refReply(ref), retained: retained)
    }

    // messageType 19: a shared texture (`newSharedTextureWithDescriptor:`,
    // metal-sim-protocol.md §5.10, visionos.md §10.10.2; wakeboardd's
    // compositor layers). The command is an op-42 record whose body is the
    // texture descriptor (36 bytes, word 0 first). Ycode makes an IOSurface
    // for it in its IOSurface service as the reference host does: width,
    // height, bytes per row and pixel format 0, bytes per element 1, the
    // allocation size op 22 answers for the descriptor + 16, the name
    // "Metal", and creation properties that describe the texture with
    // `kMetal…` keys, `kMetalRegistryID` (the hand-shake's `registryID`)
    // first among them: the guest's `newSharedTextureHandle` needs it. The
    // reply has exactly `iosurfaceXPCObject` (a send right to the surface's
    // port, looked up with IOSurfaceLookupFromXPCObject) and `replyData`
    // (the texture's ref, u32 0). The texture is GPU memory of the host's
    // own (the surface's memory is not linked to it); a handle opened from
    // the surface (messageType 20) names the same GPU image.
    private func newSharedTexture(_ d: XPCDict, _ p: Process) -> Outcome {
        guard let rec = command(d), rec.op == 42 else {
            refuse("19", "no op-42 record")
            return Outcome(reply: [:])
        }
        var r = ByteReader(rec.body)
        guard let desc = try? MetalDescriptorCodec.texture(&r, leadingWord: rec.body.count >= 36) else {
            refuse("19:42", "malformed descriptor")
            return Outcome(reply: [:])
        }
        let allocation = Int(Self.heapTextureSizeAndAlign(desc).size) + 16
        guard let surfaces,
              let port = surfaces.makeSharedTextureSurface(allocationSize: allocation, name: "Metal",
                                                           properties: Self.sharedTextureProperties(desc, allocation: allocation,
                                                                                                     registryID: registryID)) else {
            refuse("19:surface", "no IOSurface for a shared texture")
            return Outcome(reply: [:])
        }
        let surfaceID = surfaces.surfaceDescription(forSurfacePort: port)?.id
        var recipe = MetalRecipe(mt: 19, op: 42, body: rec.body)
        recipe.right = port
        let (h, ref) = add(.resource, p) {
            $0.recipe = recipe
            $0.sharedSurface = surfaceID
        }
        if let surfaceID { lock.withLock { sharedTextures[surfaceID, default: []].insert(h) } }
        do { try backend.createTexture(h, desc, iosurface: nil) } catch { backendFailed("createTexture(shared) \(h)", error) }
        finishCreate(h, p)
        var reply = Self.refReply(ref)
        reply["iosurfaceXPCObject"] = .sendRight(XPCPort(name: port, disposition: XPCDisposition.makeSend))
        return Outcome(reply: reply)
    }

    /// The creation properties of a shared texture's surface
    /// (metal-sim-protocol.md §5.10; `IOSurfaceName` is added by the service).
    static func sharedTextureProperties(_ d: MetalTextureDescriptor, allocation: Int,
                                        registryID: UInt64) -> [(key: String, value: UInt64)] {
        [
            ("IOSurfaceAllocSize", UInt64(allocation)),
            ("IOSurfacePixelSizeCastingAllowed", 1),
            ("IOSurfaceProtectionOptions", 0),
            ("kAGXCompressionMode", 0),
            ("kMetalRegistryID", registryID),
            ("kMetalTextureType", UInt64(d.textureType)),
            ("kMetalTexturePixelFormat", UInt64(d.pixelFormat)),
            ("kMetalTextureWidth", UInt64(max(d.width, 0))),
            ("kMetalTextureHeight", UInt64(max(d.height, 0))),
            ("kMetalTextureDepth", UInt64(max(d.depth, 0))),
            ("kMetalTextureArrayLength", UInt64(max(d.arrayLength, 0))),
            ("kMetalTextureMipmapLevelCount", UInt64(max(d.mipmapLevelCount, 0))),
            ("kMetalTextureSampleCount", UInt64(max(d.sampleCount, 0))),
            ("kMetalTextureUsage", UInt64(d.usage)),
            ("kMetalTextureResourceOptions", UInt64(d.resourceOptions)),
            ("kMetalTextureGPUOptimization", d.allowGPUOptimizedContents ? 1 : 0),
            ("kMetalTextureSwizzleKey", 0x0504_0302),
            ("kMetalTextureRotation", 0),
            ("kMetalTextureCSCMatrix", 0),
            ("kMetalTextureFootprint", 0),
            ("kMetalTextureSparseValue", 0),
            ("kMetalTextureResourceIndex", 0),
            ("kMetalTextureWriteAccessPattern", 0),
        ]
    }

    /// The texture a surface's `kMetal…` creation properties describe, or
    /// nil when they do not (no type, format, width or height).
    static func sharedTextureDescriptor(_ n: [String: UInt64]) -> MetalTextureDescriptor? {
        guard let type = n["kMetalTextureType"], let format = n["kMetalTexturePixelFormat"],
              let width = n["kMetalTextureWidth"], let height = n["kMetalTextureHeight"] else { return nil }
        func v(_ key: String, _ fallback: Int) -> Int { n[key].map { Int(truncatingIfNeeded: $0) } ?? fallback }
        return MetalTextureDescriptor(textureType: UInt8(truncatingIfNeeded: type), pixelFormat: UInt32(truncatingIfNeeded: format),
                                      width: Int(truncatingIfNeeded: width), height: Int(truncatingIfNeeded: height),
                                      depth: v("kMetalTextureDepth", 1), mipmapLevelCount: v("kMetalTextureMipmapLevelCount", 1),
                                      sampleCount: v("kMetalTextureSampleCount", 1), arrayLength: v("kMetalTextureArrayLength", 1),
                                      usage: UInt16(truncatingIfNeeded: n["kMetalTextureUsage"] ?? 0),
                                      resourceOptions: UInt16(truncatingIfNeeded: n["kMetalTextureResourceOptions"] ?? 0),
                                      allowGPUOptimizedContents: (n["kMetalTextureGPUOptimization"] ?? 0) != 0)
    }

    /// Diagnostics: labels of opened shared-texture handles logged so far.
    private var labelsLogged = 0

    // messageType 20: `newSharedTextureWithHandle:` (metal-sim-protocol.md
    // §5.11, visionos.md §10.10.2), in the creating process or any other.
    // The request has `command` (op 43, u32 0), `iosurface` (a send right
    // for the handle's surface, from the IOSurface service) and `label`
    // when the handle has one. The host finds the surface by that right,
    // takes the texture from its `kMetal…` creation properties and makes a
    // new ref over the same GPU image as the surface's existing texture
    // (a message-19 texture, or an earlier opening), or over the surface's
    // memory for a surface a guest made. The reply's `replyData` is 36
    // bytes: the ref, then descriptor words 1–8, with hazard tracking
    // "tracked" when the descriptor gives none. A surface without the
    // properties gets an empty reply (the guest then returns nil).
    private func openSharedTexture(_ d: XPCDict, _ p: Process) -> Outcome {
        guard let rec = command(d), rec.op == 43 else {
            refuse("20", "no op-43 record")
            return Outcome(reply: [:])
        }
        guard let port = d["iosurface"]?.port else {
            refuse("20", "no iosurface right")
            return Outcome(reply: [:])
        }
        let label: String? = { if case let .string(s)? = d["label"] { return s }; return nil }()
        guard let surface = surfaces?.surfaceDescription(forSurfacePort: port.name) else {
            refuse("20:surface", "IOSurface port unknown")
            return Outcome(reply: [:])
        }
        guard var desc = Self.sharedTextureDescriptor(surface.numbers) else {
            refuse("20:properties", "surface \(surface.id) has no kMetal texture properties")
            return Outcome(reply: [:])
        }
        if desc.resourceOptions & 0x300 == 0 { desc.resourceOptions |= 0x200 }
        let logIt: Bool = lock.withLock {
            labelsLogged += 1
            return labelsLogged <= 64
        }
        if logIt {
            log("metal: shared texture opened by process \(p.id) (guest pid \(p.guestPID)): surface \(surface.id) " +
                "\(desc.width)x\(desc.height) format \(desc.pixelFormat) type \(desc.textureType)" +
                (label.map { "; label \"\($0)\"" } ?? ""))
        }
        // The surface's live texture, in any process.
        let parent: MetalHandle? = lock.withLock { sharedTextures[surface.id]?.min() }
        var recipe = MetalRecipe(mt: 20, op: 43)
        var w = MetalByteWriter()
        MetalDescriptorCodec.encodeTexture(desc, into: &w)
        recipe.body = w.bytes
        recipe.right = port.name
        let (h, ref) = add(.resource, p) {
            $0.rights = [port.name]
            $0.recipe = recipe
            $0.sharedSurface = surface.id
            $0.sharedLabel = label
            $0.openedHandle = true
        }
        lock.withLock { sharedTextures[surface.id, default: []].insert(h) }
        do {
            if let parent {
                try backend.createTextureView(h, parent: parent, MetalTextureViewDescriptor(pixelFormat: 0))
            } else {
                try backend.createTexture(h, desc, iosurface: surfaces?.backing(forSurfacePort: port.name, plane: 0))
            }
        } catch {
            backendFailed("openSharedTexture \(h)", error)
        }
        finishCreate(h, p)
        var reply = MetalByteWriter()
        reply.u32(ref)
        var words = MetalByteWriter()
        MetalDescriptorCodec.encodeTexture(desc, into: &words)
        reply.append(Array(words.bytes.dropFirst(4)))
        return Outcome(reply: ["replyData": .data(reply.bytes)], retained: [port.name])
    }

    /// Diagnostics (`YCODE_METAL_SHARED_CONTENT=1`, with `YCODE_METAL_STATS`):
    /// for each shared-texture surface with a 4-byte colour format, read
    /// slice 0 of level 0 back through **every** live ref that names it (the
    /// message-19 texture in the creating process and each message-20
    /// opening, e.g. backboardd's own refs of wakeboardd's layers) and
    /// report how many pixels are not black and the mean of each byte
    /// channel; then the value of each exported shared event (the layer
    /// events of visionos.md §10.12.2) as the back end and the CPU see it.
    static let sharedContentStats = ProcessInfo.processInfo.environment["YCODE_METAL_SHARED_CONTENT"] == "1"

    func sharedTextureContent() -> [String] {
        guard Self.sharedContentStats else { return [] }
        let entries: [(UInt32, MetalHandle, MetalTextureDescriptor, String)] = lock.withLock {
            var out: [(UInt32, MetalHandle, MetalTextureDescriptor, String)] = []
            for (id, handles) in sharedTextures.sorted(by: { $0.key < $1.key }) {
                for h in handles.sorted() {
                    for p in processes.values {
                        guard let o = p.objects[h], let r = o.recipe else { continue }
                        var br = ByteReader(r.body)
                        if let d = try? MetalDescriptorCodec.texture(&br, leadingWord: r.body.count >= 36),
                           MetalPixelFormat.bytesPerPixel(d.pixelFormat) == 4, d.pixelFormat != 252 {
                            let what = (o.openedHandle ? "opened (20)" : "made (19)") + " by pid \(p.guestPID)"
                                + (o.sharedLabel.map { " \"\($0.prefix(48))\"" } ?? "")
                            out.append((id, h, d, what))
                        }
                    }
                }
            }
            return out
        }
        let events: [(UInt32, MetalHandle, Int, UInt64)] = lock.withLock {
            exportedEvents.sorted(by: { $0.key < $1.key }).map { ($0.key, $0.value.original, $0.value.members, $0.value.cpuValue) }
        }
        var lines: [String] = []
        for (port, h, members, cpu) in events {
            lines.append("metal:   shared event port 0x\(String(port, radix: 16)) (\(h), \(members) refs): value \(backend.eventValue(h).map(String.init) ?? "?") (CPU \(cpu))")
        }
        for (id, h, d, what) in entries {
            let w = max(d.width, 1), hh = max(d.height, 1), row = w * 4, count = row * hh
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 64)
            defer { buffer.deallocate() }
            buffer.initializeMemory(as: UInt8.self, repeating: 0, count: count)
            let region = GuestSharedRegion(pointer: buffer, length: count, objectID: UInt64.max - UInt64(id), owner: nil)
            do {
                try backend.getBytes(texture: h, MetalRegion(width: w, height: hh), level: 0, slice: 0, into: region,
                                     bytesPerRow: row, bytesPerImage: count)
            } catch {
                lines.append("metal:   shared surface \(id) (\(h), \(what)): read failed: \(error)")
                continue
            }
            let px = buffer.assumingMemoryBound(to: UInt8.self)
            var nonBlack = 0, nonZero = 0
            var sums: [Int] = [0, 0, 0, 0]
            var i = 0
            while i < count {
                if px[i] | px[i + 1] | px[i + 2] != 0 { nonBlack += 1 }
                if px[i] | px[i + 1] | px[i + 2] | px[i + 3] != 0 { nonZero += 1 }
                for c in 0..<4 { sums[c] += Int(px[i + c]) }
                i += 4 * 16  // every 16th pixel
            }
            let n = max(count / 64, 1)
            lines.append("metal:   shared surface \(id) (\(h), \(what)) \(w)x\(hh) fmt \(d.pixelFormat): \(nonBlack) of \(n) sampled pixels not black, "
                         + "\(nonZero) not zero; mean bytes \(sums.map { $0 / n })")
        }
        return lines
    }

    /// The object leaves its surface's shared-texture set (released).
    private func leaveSharedSurface(_ h: MetalHandle, _ o: Object) {
        guard let id = o.sharedSurface else { return }
        lock.withLock {
            sharedTextures[id]?.remove(h)
            if sharedTextures[id]?.isEmpty == true { sharedTextures[id] = nil }
        }
    }

    /// The IOSurface pixel format (a FourCC) of a Metal pixel format, for a
    /// surface the host makes; 0 when there is none.
    static func ioSurfaceFourCC(_ pixelFormat: UInt32) -> UInt32 {
        func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
        switch pixelFormat {
        case 80, 81: return fourCC("BGRA")
        case 70, 71: return fourCC("RGBA")
        case 115: return fourCC("RGhA")
        case 90: return fourCC("l10r")
        case 10: return fourCC("L008")
        default: return 0
        }
    }

    // messageType 15 (§6)
    private func newFunction(_ d: XPCDict, _ p: Process) -> Outcome {
        guard let ir = bytes(of: d["functionIR"]) else {
            refuse("15", "no functionIR")
            return Outcome(reply: [:])
        }
        let (h, ref) = add(.function, p) { $0.recipe = MetalRecipe(mt: 15, body: ir) }
        do { try backend.createFunction(h, metallib: ir) } catch { backendFailed("createFunction \(h)", error) }
        finishCreate(h, p)
        return Outcome(reply: Self.refReply(ref))
    }

    /// Argument-encoder set calls (op 19; visionos.md §10.20.7, §9 Q25)
    /// write the member into the argument buffer's memory: the guest driver
    /// leaves that to the host, and the guest's argument buffers stay zero
    /// otherwise. Kind 0 names the argument buffer and its offset; kinds 1,
    /// 2, 3 write a buffer's GPU address (plus the call's offset), a
    /// texture's or a sampler's resource ID as 8 bytes at the member index
    /// times 8, the layout ycode-airc reads (`metal-shaders.md` §3.6, every
    /// member 8 bytes, members in id order). `YCODE_METAL_ARGUMENT_ENCODER=0`
    /// refuses the calls instead (the behaviour before §10.20.7).
    static let argumentEncoderWrites = ProcessInfo.processInfo.environment["YCODE_METAL_ARGUMENT_ENCODER"] != "0"
    private var argumentTargets: [String: (MetalHandle, Int)] = [:]
    private var argumentWritesLogged = 0

    private func argumentEncoderSet(_ body: [UInt8], _ p: Process) {
        var r = ByteReader(body)
        guard body.count >= 36, let encoder = try? r.u32(), let kind = try? r.u8(), let index = try? r.u8() else {
            refuse("12:19", "malformed argument-encoder set call")
            return
        }
        _ = try? r.u16()
        for _ in 0..<4 { _ = try? r.u32() }
        guard let object = try? r.u32(), let offset = try? r.int64() else { return }
        let key = "\(p.id)/\(encoder)"
        var value: UInt64?
        switch kind {
        case 0:
            if let h = lookUp(.resource, object, p) { lock.withLock { argumentTargets[key] = (h, Int(offset)) } }
            return
        case 1:
            if object == 0 { value = 0 } else if let h = lookUp(.resource, object, p) {
                let base = backend.gpuAddress(ofBuffer: h) ?? lock.withLock { p.objects[h]?.gpuAddress } ?? 0
                value = base == 0 ? 0 : base &+ UInt64(bitPattern: Int64(offset))
            }
        case 2:
            if object == 0 { value = 0 } else if let h = lookUp(.resource, object, p) { value = backend.gpuResourceID(ofTexture: h) }
        case 3:
            if object == 0 { value = 0 } else if let h = lookUp(.sampler, object, p) { value = backend.gpuResourceID(ofSampler: h) ?? h.raw }
        default:
            break
        }
        guard let v = value, let (target, base) = lock.withLock({ argumentTargets[key] }) else {
            refuse("12:19", "argument-encoder set call without a target or object")
            return
        }
        var w = MetalByteWriter()
        w.u64(v)
        let ok = backend.writeBuffer(target, offset: base + 8 * Int(index), w.bytes)
        if argumentWritesLogged < 24 || !ok {
            argumentWritesLogged += 1
            log("metal: argument encoder \(encoder) of process \(p.id): kind \(kind) index \(index) object \(object) -> "
                + "\(target) +\(base + 8 * Int(index)) = 0x\(String(v, radix: 16))" + (ok ? "" : " (not written: no CPU-visible memory)"))
        }
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
                retire(h, o, p)
                return (h, o)
            }
            return nil
        }
        guard let (h, o) = found else {
            log("metal: release op \(rec.op) of unknown ref \(ref) (process \(p.id))")
            return
        }
        if let port = leaveEventGroup(o) { transport?.destroyEventPort(port) }
        leaveSharedSurface(h, o)
        if Self.isBackendObject(o.kind) { backend.release(h) }
        for right in o.rights { transport?.dropRight(right) }
    }

    // MARK: Shared-event handles (messageTypes 17 and 18, visionos.md §10.6.5)

    /// The object leaves its event group (it was released): returns the
    /// group's port when it was the last member, for the caller to destroy.
    private func leaveEventGroup(_ o: Object) -> UInt32? {
        lock.withLock {
            guard let g = o.eventGroup else { return nil }
            o.eventGroup = nil
            g.members -= 1
            guard g.members <= 0, g.port != 0 else { return nil }
            exportedEvents[g.port] = nil
            defer { g.port = 0 }
            return g.port
        }
    }

    // messageType 17: `eventRef` → `eventPort` (a send right for the event)
    // and `labelTraceID` 0. One port per event, made on the first request.
    private func newSharedEventHandle(_ d: XPCDict, _ p: Process) -> Outcome {
        let ref = UInt32(truncatingIfNeeded: d["eventRef"]?.integerValue ?? 0)
        guard let h = lookUp(.event, ref, p) else {
            refuse("17", "unknown event ref")
            return Outcome(reply: ["labelTraceID": .uint64(0)])
        }
        var port: UInt32 = lock.withLock { p.objects[h]?.eventGroup?.port ?? 0 }
        if port == 0 {
            guard let made = transport?.makeEventPort() else {
                refuse("17", "no event port could be made")
                return Outcome(reply: ["labelTraceID": .uint64(0)])
            }
            let (winner, spare): (UInt32, UInt32?) = lock.withLock {
                guard let o = p.objects[h] else { return (0, made) }
                if let g = o.eventGroup, g.port != 0 { return (g.port, made) }
                let g = o.eventGroup ?? SharedEventGroup(original: h)
                if o.eventGroup == nil { g.cpuValue = o.eventValue }
                g.port = made
                o.eventGroup = g
                exportedEvents[made] = g
                return (made, nil)
            }
            if let spare { transport?.destroyEventPort(spare) }
            port = winner
            if port == 0 { return Outcome(reply: ["labelTraceID": .uint64(0)]) }
        }
        noteEventHandle("17: process \(p.id) (guest pid \(p.guestPID)) exports event ref \(ref) as port 0x\(String(port, radix: 16))")
        return Outcome(reply: ["eventPort": .sendRight(XPCPort(name: port, disposition: XPCDisposition.makeSend)),
                               "labelTraceID": .uint64(0)])
    }

    /// Diagnostics: the first 32 shared-event exports and openings.
    private var eventHandleNotes = 0
    /// messageType 18 requests with a null port (answered empty).
    public private(set) var nullEventOpenings = 0
    private func noteEventHandle(_ line: String) {
        let logIt: Bool = lock.withLock {
            eventHandleNotes += 1
            return eventHandleNotes <= 32
        }
        if logIt { log("metal: shared event " + line) }
    }

    // messageType 18: `eventPort` (+ `command` op 40, u32 0) → a new event
    // ref in this process naming the same event (`replyData` u32 ref, u32 0).
    // `eventPort` MACH_PORT_NULL (or absent) is the driver's form of
    // `newSharedEventWithHandle:nil`: the reference answers an empty
    // dictionary (no `replyData`, no `error`), so the call returns nil.
    // visionOS backboardd and wakeboardd send one after each real opening of
    // a layer event (visionos.md §10.12.2). No event, nothing refused.
    private func openSharedEventHandle(_ d: XPCDict, _ p: Process) -> Outcome {
        let portName = d["eventPort"]?.port?.name ?? 0
        if portName == 0 {
            lock.withLock { nullEventOpenings += 1 }
            return Outcome(reply: [:])
        }
        let group: SharedEventGroup? = lock.withLock {
            guard portName != 0, let g = exportedEvents[portName] else { return nil }
            g.members += 1
            return g
        }
        noteEventHandle("18: process \(p.id) (guest pid \(p.guestPID)) opens port 0x\(String(portName, radix: 16))"
                        + (group == nil ? " (no exported event)" : ""))
        let (h, ref) = add(.event, p) { o in
            o.recipe = MetalRecipe(mt: 12, op: 28)
            o.eventGroup = group
        }
        if let g = group {
            do { try backend.createEventAlias(h, of: g.original) } catch { backendFailed("createEventAlias \(h)", error) }
        } else {
            refuse("18", "event port names no exported event; keys: \(Self.describeKeys(d))")
            do { try backend.createEvent(h) } catch { backendFailed("createEvent \(h)", error) }
        }
        finishCreate(h, p)
        return Outcome(reply: Self.refReply(ref))
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
        if let limit = Self.dumpOps[rec.op] { dumpBody(rec, limit: limit) }
        do {
            if let reply = try deviceOp(rec, p) { return Outcome(reply: reply) }
            refuse("12:\(rec.op)", "unknown device op")
        } catch {
            refuse("12:\(rec.op)", "malformed: \(error)")
        }
        return Outcome(reply: [:])
    }

    /// Diagnostics (`YCODE_METAL_DUMP_OPS=21,22`): the first 16 request
    /// bodies of each listed device op (`op:count` for another number) are
    /// logged in hex, to compare the wire with metal-sim-protocol.md §4.2.
    static let dumpOps: [UInt32: Int] = {
        guard let text = ProcessInfo.processInfo.environment["YCODE_METAL_DUMP_OPS"] else { return [:] }
        var ops: [UInt32: Int] = [:]
        for item in text.split(separator: ",") {
            let parts = item.split(separator: ":")
            if let op = parts.first.flatMap({ UInt32($0) }) { ops[op] = parts.count > 1 ? Int(parts[1]) ?? 16 : 16 }
        }
        return ops
    }()
    private var dumped: [UInt32: Int] = [:]
    static let limitsOverride: [UInt64]? = ProcessInfo.processInfo.environment["YCODE_METAL_LIMITS"].flatMap { text in
        let v = text.split(separator: ",").compactMap { UInt64($0) }
        return v.count == 4 ? v : nil
    }

    private func dumpBody(_ rec: MetalRecord, limit: Int) {
        let n = lock.withLock { () -> Int in
            dumped[rec.op, default: 0] += 1
            return dumped[rec.op]!
        }
        guard n <= limit else { return }
        let hex = rec.body.prefix(256).map { String(format: "%02x", $0) }.joined()
        log("metal: dump 12:\(rec.op) #\(n) body \(rec.body.count) bytes: \(hex)")
    }

    private static func u64Reply(_ values: [UInt64]) -> XPCDict {
        var w = MetalByteWriter()
        for v in values { w.u64(v) }
        return ["replyData": .data(w.bytes)]
    }

    /// Heap size and alignment of a texture (op 22), by the rule fitted to
    /// the reference's answers (visionos.md §10.8.3): 16 KiB tiles (128 ×
    /// 128 pixels at 1 byte per pixel … 32 × 32 at 16); a dimension below
    /// the tile's is padded to a power of two, a larger one to a multiple of
    /// the tile; each 2D level rounded to 128, plus compression metadata
    /// (next powers of two of width × height / 32, rounded to 128) when the
    /// usage is not 0, has no ShaderWrite and the level is at least 16 × 16;
    /// mip levels summed; cube 6 ×, 3D depth ×, arrays length ×; texture
    /// buffers width × bytes exactly with alignment 16; alignment 128
    /// otherwise. Formats without a fitted tile (compressed, 3- or 6-byte)
    /// keep Ycode's earlier estimate (levels rounded to 1 KiB).
    static func heapTextureSizeAndAlign(_ t: MetalTextureDescriptor) -> (size: UInt64, align: UInt64) {
        let bppOpt = MetalPixelFormat.bytesPerPixel(t.pixelFormat)
        let tiles: [Int: (Int, Int)] = [1: (128, 128), 2: (128, 64), 4: (64, 64), 8: (64, 32), 16: (32, 32)]
        guard let b = bppOpt, let tile = tiles[b] else {
            return ((legacyHeapTextureSize(t) + 127) & ~127, 128)
        }
        func round(_ v: UInt64, _ m: UInt64) -> UInt64 { (v + m - 1) / m * m }
        func pow2(_ v: Int) -> UInt64 { var p: UInt64 = 1; while p < UInt64(max(v, 1)) { p <<= 1 }; return p }
        func pad(_ v: Int, _ tileDim: Int) -> UInt64 { v < tileDim ? pow2(v) : round(UInt64(v), UInt64(tileDim)) }
        let bytes = UInt64(b)
        if t.textureType == MetalTextureType.typeTextureBuffer {
            return (UInt64(max(t.width, 1)) * bytes, 16)
        }
        let is1D = t.textureType == MetalTextureType.type1D || t.textureType == MetalTextureType.type1DArray
        let metadataUsage = t.usage != 0 && t.usage & MetalTextureUsage.shaderWrite == 0
        var total: UInt64 = 0
        for level in 0..<max(t.mipmapLevelCount, 1) {
            let w = max(t.width >> level, 1), h = is1D ? 1 : max(t.height >> level, 1)
            var size: UInt64
            if is1D {
                size = round(pad(w, tile.0) * bytes, 128)
            } else {
                size = round(pad(w, tile.0) * pad(h, tile.1) * bytes * UInt64(max(t.sampleCount, 1)), 128)
                if metadataUsage && w >= 16 && h >= 16 { size += round(pow2(w) * pow2(h) / 32, 128) }
            }
            if t.textureType == MetalTextureType.type3D { size *= UInt64(max(t.depth >> level, 1)) }
            total += size
        }
        let faces: UInt64 = t.textureType == MetalTextureType.typeCube || t.textureType == MetalTextureType.typeCubeArray ? 6 : 1
        let arrays: UInt64
        switch t.textureType {
        case MetalTextureType.type1DArray, MetalTextureType.type2DArray, MetalTextureType.typeCubeArray,
             MetalTextureType.type2DMultisampleArray: arrays = UInt64(max(t.arrayLength, 1))
        default: arrays = 1
        }
        return (total * faces * arrays, 128)
    }

    /// The bytes a texture takes in its heap (op 21's used size): op 22's answer.
    static func heapTextureSize(_ t: MetalTextureDescriptor) -> UInt64 { heapTextureSizeAndAlign(t).size }

    /// Ycode's earlier estimate: levels rounded to 1 KiB, slices and samples
    /// multiplied (formats the fitted rule does not cover).
    static func legacyHeapTextureSize(_ t: MetalTextureDescriptor) -> UInt64 {
        let bpp = UInt64(MetalPixelFormat.bytesPerPixel(t.pixelFormat) ?? 16)
        var total: UInt64 = 0
        for level in 0..<max(t.mipmapLevelCount, 1) {
            let w = UInt64(max(t.width >> level, 1)), h = UInt64(max(t.height >> level, 1)), dd = UInt64(max(t.depth >> level, 1))
            total += (w * h * dd * bpp + 1023) & ~1023
        }
        let faces: UInt64 = t.textureType == MetalTextureType.typeCube || t.textureType == MetalTextureType.typeCubeArray ? 6 : 1
        return total * UInt64(max(t.arrayLength, 1)) * faces * UInt64(max(t.sampleCount, 1))
    }

    /// A heap's size as granted (op 20, answered by op 31): the requested
    /// size rounded up to a multiple of 16 KiB (visionos.md §10.8.3).
    static func grantedHeapSize(_ requested: UInt64) -> UInt64 { max((requested + 16383) & ~16383, 16384) }

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
            let parentHandle = lookUp(.resource, parentRef, p)
            let (h, ref) = add(.resource, p) { $0.recipe = MetalRecipe(mt: 12, op: rec.op, body: rec.body, deps: parentHandle.map { [$0] } ?? []) }
            noteDependencies(h, p)
            if let parent = parentHandle {
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
            let fHandle = lookUp(.function, fref, p)
            let (h, ref) = add(.computePipeline, p) { $0.recipe = MetalRecipe(mt: 12, op: 11, body: rec.body, deps: fHandle.map { [$0] } ?? []) }
            noteDependencies(h, p)
            var info = MetalComputePipelineInfo()
            if let f = fHandle {
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
            let (h, ref) = add(.fence, p) { $0.recipe = MetalRecipe(mt: 12, op: 13) }
            do { try backend.createFence(h) } catch { backendFailed("createFence \(h)", error) }
            finishCreate(h, p)
            return Self.refReply(ref)
        case 14:
            let payload = try MetalPipelineCodec.payload(rec.body)
            var refMap: [(UInt32, MetalHandle)] = []
            let desc = try lock.withLock {
                try MetalPipelineCodec.renderPipeline(payload) { ref in
                    let h = p.handle(.function, ref)
                    if let h { refMap.append((ref, h)) }
                    return h
                }
            }
            noteUnknownKeys("render pipeline", desc.unknownKeys)
            var recipe = MetalRecipe(mt: 12, op: 14, body: rec.body, deps: refMap.map(\.1))
            recipe.refMap = refMap
            let (h, ref) = add(.renderPipeline, p) { $0.recipe = recipe }
            noteDependencies(h, p)
            do { try backend.createRenderPipeline(h, desc) } catch { backendFailed("createRenderPipeline \(h)", error) }
            finishCreate(h, p)
            return Self.refReply(ref)
        case 16:
            let (_, ref) = add(.argumentLayout, p) { $0.recipe = MetalRecipe(mt: 12, op: 16) }
            refuse("12:16", "argument-buffer layouts are answered but not modelled")
            var w = MetalByteWriter()
            w.u32(ref); w.u32(0); w.u32(0xFFFF_0001); w.u32(0xFFFF_FFFF)
            return ["replyData": .data(w.bytes)]
        case 17:
            let (_, ref) = add(.argumentEncoder, p) { $0.recipe = MetalRecipe(mt: 12, op: 17) }
            var w = MetalByteWriter()
            w.u32(ref); w.u32(0); w.u16(24); w.u16(8); w.u32(0)
            return ["replyData": .data(w.bytes)]
        case 19:
            guard Self.argumentEncoderWrites else {
                refuse("12:19", "argument-encoder set calls are not modelled")
                return [:]
            }
            argumentEncoderSet(rec.body, p)
            return [:]
        case 20:
            _ = try r.u32()
            let size = try r.u64()
            let (_, ref) = add(.heap, p) { $0.heapSize = Self.grantedHeapSize(size); $0.recipe = MetalRecipe(mt: 12, op: 20, body: rec.body) }
            return Self.refReply(ref)
        case 21:
            _ = try r.u32()
            let heapRef = try r.u32()
            // u32 0, u32 heap, descriptor words 1–8, 12 bytes 0 (52 bytes;
            // a 56-byte body carries word 0 as well).
            var desc = try MetalDescriptorCodec.texture(&r, leadingWord: rec.body.count >= 56)
            desc.resourceOptions = (desc.resourceOptions & ~0xF0) | 0x20
            let heap = lookUp(.heap, heapRef, p)
            let bytes = Self.heapTextureSize(desc)
            let (h, ref) = add(.resource, p) {
                $0.heap = heap
                $0.heapBytes = heap == nil ? 0 : bytes
                $0.recipe = MetalRecipe(mt: 12, op: 21, body: rec.body)
            }
            if let heap { lock.withLock { if let ho = p.objects[heap] { ho.heapUsed += bytes } } }
            do { try backend.createTexture(h, desc, iosurface: nil) } catch { backendFailed("createTexture(heap) \(h)", error) }
            finishCreate(h, p)
            return Self.refReply(ref)
        case 22:
            // Descriptor words 1–8 (32 bytes); 36 bytes: with word 0.
            let desc = try MetalDescriptorCodec.texture(&r, leadingWord: rec.body.count >= 36)
            let answer = Self.heapTextureSizeAndAlign(desc)
            return Self.u64Reply([answer.size, answer.align])
        case 23:
            let length = try r.u64()
            // The macOS host answered 1000 → 1000, 256 (§4.2).
            return Self.u64Reply([length, 256])
        case 24:
            _ = try r.u32()
            let heapRef = try r.u32()
            let length = try r.int64()
            let heap = lookUp(.heap, heapRef, p)
            var recipe = MetalRecipe(mt: 12, op: 24, body: rec.body)
            recipe.length = length
            let outcome = makeBuffer(p, length: length, storage: .private, region: nil, retained: [], heap: heap, recipe: recipe,
                                     reply: { Self.refReply($0) })
            return outcome.reply
        case 25:
            return ["replyData": .data([0])]
        case 28:
            let (h, ref) = add(.event, p) { $0.recipe = MetalRecipe(mt: 12, op: 28) }
            do { try backend.createEvent(h) } catch { backendFailed("createEvent \(h)", error) }
            finishCreate(h, p)
            return Self.refReply(ref)
        case 30:
            let ref = try r.u32(), value = try r.u64()
            if let h = lookUp(.event, ref, p) {
                lock.withLock {
                    p.objects[h]?.eventValue = value
                    p.objects[h]?.eventGroup?.cpuValue = value
                }
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
            var values = [l.maxThreadsPerThreadgroup.x, l.maxThreadsPerThreadgroup.y, l.maxThreadsPerThreadgroup.z,
                          l.maxThreadgroupMemoryLength]
            // Diagnostics (`YCODE_METAL_LIMITS=x,y,z,memory`): another reply.
            // Parity (visionos.md §10.6.1): the reference host's reply lets
            // the guest driver keep its own cap of 512 for z; a Vulkan device
            // limit of 64 must not lower it (dispatches use far fewer).
            values[2] = max(values[2], 512)
            if let o = Self.limitsOverride { values = o }
            return Self.u64Reply(values)
        case 38:
            let ref = try r.u32()
            guard let h = lookUp(.resource, ref, p) else { return Self.u64Reply([0]) }
            lock.withLock { p.objects[h]?.addressQueried = true }
            let address = backend.gpuAddress(ofBuffer: h) ?? lock.withLock { p.objects[h]?.gpuAddress } ?? 0
            return Self.u64Reply([address])
        case 39:
            let ref = try r.u32()
            guard let h = lookUp(.sampler, ref, p) else { return Self.u64Reply([0]) }
            return Self.u64Reply([backend.gpuResourceID(ofSampler: h) ?? h.raw])
        case 41:
            let ref = try r.u32()
            guard let h = lookUp(.event, ref, p) else { return Self.u64Reply([0]) }
            return Self.u64Reply([backend.eventValue(h) ?? lock.withLock {
                p.objects[h].map { $0.eventGroup?.cpuValue ?? $0.eventValue }
            } ?? 0])
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
        let receivedAt = DispatchTime.now().uptimeNanoseconds
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
        // Decoded outside the core lock (0.1-1 ms per frame of the render
        // server, which held up every other request): the refs resolve
        // through a copy of the process's tables taken under the lock, which
        // sees exactly what the lock would have shown at that moment
        // (stage8-contract.md §15).
        let (tables, queue) = lock.withLock { (p.tables, p.handle(.queue, queueRef)) }
        var (cb, unknownOps) = MetalCommandDecoder.decode(segments: segments, process: p.id, queue: queue,
                                                          commandBufferRef: cbRef) { kind, ref in
            if let h = tables[kind]?.map[ref] { return h }
            missing += 1
            return nil
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
        if !newUnknown.isEmpty {
            // The first body of each new op (diagnostics: the record's layout).
            var bodies: [UInt32: [UInt8]] = [:]
            for pass in cb.passes {
                switch pass {
                case .render(let r):
                    for c in r.commands { if case let .unknown(op, body) = c, bodies[op] == nil { bodies[op] = body } }
                case .compute(let cs):
                    for c in cs { if case let .unknown(op, body) = c, bodies[op] == nil { bodies[op] = body } }
                case .blit(let cs):
                    for c in cs { if case let .unknown(op, body) = c, bodies[op] == nil { bodies[op] = body } }
                default: break
                }
            }
            for op in newUnknown.sorted() {
                let body = bodies[op].map { b in " first body \(b.count) bytes: " + b.prefix(96).map { String(format: "%02x", $0) }.joined() } ?? ""
                log("metal: unknown command record op \(op) from process \(p.id) (guest pid \(p.guestPID)) (kept as .unknown; counted from now on)\(body)")
            }
        }
        if missing > 0 { log("metal: submission \(cbRef) of process \(p.id) names \(missing) unknown refs") }
        for diag in cb.diagnostics { log("metal: submission \(cbRef): \(diag)") }

        cb.receivedAtNs = receivedAt
        let flight = InFlight(start: clock())
        lock.withLock { inFlight += 1 }
        backend.submit(cb, scheduled: { [weak self] in
            guard let core = self else { return }
            p.events.async { core.sendScheduled(p, cbRef, flight) }
        }, completed: { [weak self] status in
            guard let core = self else { return }
            p.events.async {
                core.sendCompleted(p, cbRef, flight, status: status)
                core.lock.withLock { core.inFlight -= 1 }
            }
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
