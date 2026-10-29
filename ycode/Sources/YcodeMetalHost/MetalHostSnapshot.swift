// Snapshot and replay of the Metal host service (specs/simulator/snapshot.md
// §8 option 2). The service keeps, per object, how it was made (a recipe:
// the request's message type, op and record bytes, and the handles it named);
// a snapshot records the service's tables, the recipes, and the contents of
// the textures and buffers that live in GPU memory only; a restore re-creates
// every object on a fresh back end under its old handle, in creation order,
// and writes the contents back. Guest refs, handles, GPU addresses the
// service chose, and the client processes' connections are kept as they were,
// so the restored clients (the render server, SpringBoard) keep running.

import Foundation
import YcodeDarwinKernel
import YcodeXPC

/// How one object was made (the parts of its creation request that the
/// replay needs). `mt` is the message type, `op` the record op.
struct MetalRecipe {
    var mt: UInt8
    var op: UInt32 = 0
    var body: [UInt8] = []
    var length = 0
    var options: UInt64 = 0
    /// mt 1: the `sharedMem` memory entry; mt 13: the IOSurface port (host-task names).
    var right: UInt32 = 0
    var rightSize: UInt64 = 0
    var plane = 0
    /// Objects this one was made from (a view's parent, a pipeline's functions).
    var deps: [MetalHandle] = []
    /// op 14: function refs → handles at creation.
    var refMap: [(UInt32, MetalHandle)] = []

    init(mt: UInt8, op: UInt32 = 0, body: [UInt8] = [], deps: [MetalHandle] = []) {
        self.mt = mt
        self.op = op
        self.body = body
        self.deps = deps
    }

    enum Tag {
        static let mt: UInt16 = 1, op: UInt16 = 2, body: UInt16 = 3, length: UInt16 = 4, options: UInt16 = 5
        static let right: UInt16 = 6, rightSize: UInt16 = 7, plane: UInt16 = 8, deps: UInt16 = 9
        static let mapRefs: UInt16 = 10, mapHandles: UInt16 = 11
    }

    var fields: SnapshotFields {
        var f = SnapshotFields()
        f.u64(Tag.mt, UInt64(mt))
        f.u64(Tag.op, UInt64(op))
        if !body.isEmpty { f.bytes(Tag.body, body) }
        f.i64(Tag.length, Int64(length))
        f.u64(Tag.options, options)
        f.u64(Tag.right, UInt64(right))
        f.u64(Tag.rightSize, rightSize)
        f.i64(Tag.plane, Int64(plane))
        f.u64s(Tag.deps, deps.map(\.raw))
        f.u64s(Tag.mapRefs, refMap.map { UInt64($0.0) })
        f.u64s(Tag.mapHandles, refMap.map { $0.1.raw })
        return f
    }

    init(_ r: SnapshotFieldReader) {
        mt = UInt8(truncatingIfNeeded: r.u64(Tag.mt))
        op = r.u32(Tag.op)
        body = r.bytes(Tag.body)
        length = Int(r.i64(Tag.length))
        options = r.u64(Tag.options)
        right = r.u32(Tag.right)
        rightSize = r.u64(Tag.rightSize)
        plane = Int(r.i64(Tag.plane))
        deps = r.u64s(Tag.deps).map(MetalHandle.init)
        refMap = zip(r.u64s(Tag.mapRefs), r.u64s(Tag.mapHandles)).map { (UInt32(truncatingIfNeeded: $0), MetalHandle($1)) }
    }
}

/// What a replay did (logged by the VMM).
public struct MetalReplayReport: Sendable {
    public var processes = 0, objects = 0, ghosts = 0, failures = 0
    public var textureBytes = 0, bufferBytes = 0, contentsSkipped = 0
    public var addressesChanged = 0, samplerIDsChanged = 0
    public var lines: [String] = []
}

extension MetalHostCore {
    enum SnapTag {
        static let nextProcess: UInt16 = 1, nextHandle: UInt16 = 2, nextGPUAddress: UInt16 = 3
        static let connections: UInt16 = 4, processes: UInt16 = 5
        // connection
        static let port: UInt16 = 10, client: UInt16 = 11, type: UInt16 = 12, hasType: UInt16 = 13, process: UInt16 = 14
        // process
        static let id: UInt16 = 20, guestPID: UInt16 = 21, eventPort: UInt16 = 22, procConnections: UInt16 = 23
        static let tables: UInt16 = 24, objects: UInt16 = 25, ghosts: UInt16 = 26
        // table
        static let kind: UInt16 = 30, refs: UInt16 = 31, handles: UInt16 = 32, next: UInt16 = 33, free: UInt16 = 34
        // object
        static let handle: UInt16 = 40, ref: UInt16 = 41, rights: UInt16 = 42, heap: UInt16 = 43, heapBytes: UInt16 = 44
        static let heapSize: UInt16 = 45, heapUsed: UInt16 = 46, gpuAddress: UInt16 = 47, eventValue: UInt16 = 48
        static let recipe: UInt16 = 49, contents: UInt16 = 50, contentKind: UInt16 = 51, addressQueried: UInt16 = 52
        static let backendAddress: UInt16 = 53
    }

    // MARK: Recipes and dependencies

    /// Counts `h`'s recipe dependencies (after `add`).
    func noteDependencies(_ h: MetalHandle, _ p: Process) {
        lock.withLock {
            guard let deps = p.objects[h]?.recipe?.deps else { return }
            for d in deps { p.dependents[d, default: 0] += 1 }
        }
    }

    /// The object was released (lock held): keep its recipe while other
    /// recipes name it, and drop its own dependencies.
    func retire(_ h: MetalHandle, _ o: Object, _ p: Process) {
        if (p.dependents[h] ?? 0) > 0, let r = o.recipe {
            p.ghosts[h] = (o.kind, r)
        } else {
            dropDependencies(o.recipe, p)
        }
    }

    private func dropDependencies(_ recipe: MetalRecipe?, _ p: Process) {
        for d in recipe?.deps ?? [] {
            let n = (p.dependents[d] ?? 1) - 1
            p.dependents[d] = n > 0 ? n : nil
            if n <= 0, p.objects[d] == nil, let ghost = p.ghosts.removeValue(forKey: d) {
                dropDependencies(ghost.recipe, p)
            }
        }
    }

    /// Snapshots: idle means no request in progress (the transport checks
    /// its own) and no command buffer without its completion event.
    var snapshotBusyReason: String? {
        guard lock.try() else { return "metal core busy" }
        defer { lock.unlock() }
        // Exported shared events name host ports a restore cannot bring back.
        if !exportedEvents.isEmpty { return "\(exportedEvents.count) shared-event handles exported" }
        // Opened shared-texture handles name another object's GPU image.
        let opened = processes.values.reduce(0) { n, p in n + p.objects.values.filter(\.openedHandle).count }
        if opened > 0 { return "\(opened) shared-texture handles opened" }
        return inFlight > 0 ? "\(inFlight) Metal command buffers in flight" : nil
    }

    // MARK: Capture

    /// The service's state with the contents of GPU-only textures and
    /// buffers; nil when not idle (the snapshot tries again). Kernel lock
    /// held: only try-locks of the core's own lock; the back end's reads
    /// need neither lock.
    func trySnapshotState(log: (String) -> Void) -> SnapshotFields? {
        guard lock.try() else { return nil }
        guard inFlight == 0, exportedEvents.isEmpty else { lock.unlock(); return nil }
        // Copies of the tables (the back end is read without the lock).
        typealias T = SnapTag
        var g = SnapshotFields()
        g.u64(T.nextProcess, nextProcess)
        g.u64(T.nextHandle, nextHandle)
        g.u64(T.nextGPUAddress, nextGPUAddress)
        g.list(T.connections, connections.sorted { $0.key < $1.key }.map { port, c in
            var f = SnapshotFields()
            f.u64(T.port, UInt64(port))
            f.u64(T.client, UInt64(c.clientPort))
            if let t = c.type { f.u64(T.type, t); f.bool(T.hasType, true) }
            if let pid = c.process { f.u64(T.process, pid) }
            return f
        })
        let procs = processes.values.sorted { $0.id < $1.id }
        var objectsToRead: [(MetalHandle, MetalRefKind, MetalRecipe?)] = []
        var encoded: [(Process, SnapshotFields, [(MetalHandle, SnapshotFields)])] = []
        for p in procs {
            var f = SnapshotFields()
            f.u64(T.id, p.id)
            f.i64(T.guestPID, Int64(p.guestPID))
            f.u64(T.eventPort, UInt64(p.eventPort))
            f.u64s(T.procConnections, p.connections.sorted().map(UInt64.init))
            f.list(T.tables, p.tables.sorted { $0.key.rawValue < $1.key.rawValue }.map { kind, t in
                var e = SnapshotFields()
                e.string(T.kind, kind.rawValue)
                let refs = t.map.sorted { $0.key < $1.key }
                e.u64s(T.refs, refs.map { UInt64($0.key) })
                e.u64s(T.handles, refs.map { $0.value.raw })
                e.u64(T.next, UInt64(t.next))
                e.u64s(T.free, t.free.map(UInt64.init))
                return e
            })
            var objs: [(MetalHandle, SnapshotFields)] = []
            for (h, o) in p.objects.sorted(by: { $0.key < $1.key }) {
                var e = SnapshotFields()
                e.u64(T.handle, h.raw)
                e.string(T.kind, o.kind.rawValue)
                e.u64(T.ref, UInt64(o.ref))
                e.u64s(T.rights, o.rights.map(UInt64.init))
                if let heap = o.heap { e.u64(T.heap, heap.raw) }
                e.u64(T.heapBytes, o.heapBytes)
                e.u64(T.heapSize, o.heapSize)
                e.u64(T.heapUsed, o.heapUsed)
                e.u64(T.gpuAddress, o.gpuAddress)
                e.u64(T.eventValue, o.eventValue)
                e.bool(T.addressQueried, o.addressQueried)
                if let r = o.recipe { e.nested(T.recipe, r.fields) }
                objs.append((h, e))
                objectsToRead.append((h, o.kind, o.recipe))
            }
            f.list(T.ghosts, p.ghosts.sorted { $0.key < $1.key }.map { h, ghost in
                var e = SnapshotFields()
                e.u64(T.handle, h.raw)
                e.string(T.kind, ghost.kind.rawValue)
                e.nested(T.recipe, ghost.recipe.fields)
                return e
            })
            encoded.append((p, f, objs))
        }
        lock.unlock()

        // Contents (the device is idle: no request runs, nothing in flight).
        backend.snapshotSettle()
        var contents: [MetalHandle: (kind: UInt64, bytes: [UInt8])] = [:]
        var addresses: [MetalHandle: UInt64] = [:]
        var textureBytes = 0, bufferBytes = 0, skipped = 0
        for (h, kind, recipe) in objectsToRead {
            if kind == .sampler, let id = backend.gpuResourceID(ofSampler: h) { addresses[h] = id }
            guard kind == .resource, let recipe else { continue }
            switch (recipe.mt, recipe.op) {
            case (1, _), (12, 24):
                if let a = backend.gpuAddress(ofBuffer: h) { addresses[h] = a }
                // Buffers over guest memory are in the memory snapshot already.
                if recipe.mt == 1, recipe.right != 0, memory?.region(forMemoryEntry: recipe.right) != nil { continue }
                if let b = backend.bufferContents(h) {
                    contents[h] = (1, b)
                    bufferBytes += b.count
                } else {
                    skipped += 1
                }
            case (8, 1), (12, 21):
                guard let desc = try? textureDescriptor(recipe) else { skipped += 1; continue }
                if let bytes = readTexture(h, desc) {
                    contents[h] = (2, bytes)
                    textureBytes += bytes.count
                } else {
                    skipped += 1
                }
            default:
                break  // views share their parent's memory; IOSurface textures live in the surface
            }
        }
        typealias U = SnapTag
        g.list(T.processes, encoded.map { _, f, objs in
            var f = f
            f.list(U.objects, objs.map { h, e in
                var e = e
                if let c = contents[h] {
                    e.u64(U.contentKind, c.kind)
                    e.bytes(U.contents, c.bytes)
                }
                if let a = addresses[h] { e.u64(U.backendAddress, a) }
                return e
            })
            return f
        })
        log("metal: snapshot: \(procs.count) processes, \(objectsToRead.count) objects, "
            + "\(procs.reduce(0) { $0 + $1.ghosts.count }) kept recipes; contents: textures \(textureBytes >> 10) KiB, "
            + "buffers \(bufferBytes >> 10) KiB, \(skipped) not readable")
        return g
    }

    /// Every level and slice of a texture, packed (nil when its format has
    /// no plain byte size, or it is multisampled or a depth/stencil target).
    private func readTexture(_ h: MetalHandle, _ desc: MetalTextureDescriptor) -> [UInt8]? {
        guard desc.sampleCount <= 1, let bpp = MetalPixelFormat.bytesPerPixel(desc.pixelFormat) else { return nil }
        let slices = max(desc.arrayLength, 1)
            * (desc.textureType == MetalTextureType.typeCube || desc.textureType == MetalTextureType.typeCubeArray ? 6 : 1)
        var out: [UInt8] = []
        for level in 0..<max(desc.mipmapLevelCount, 1) {
            let w = max(desc.width >> level, 1), hgt = max(desc.height >> level, 1), d = max(desc.depth >> level, 1)
            let row = w * bpp, image = row * hgt
            for slice in 0..<slices {
                let count = image * d
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1), alignment: 64)
                defer { buffer.deallocate() }
                let region = GuestSharedRegion(pointer: buffer, length: count, objectID: 0, owner: nil)
                do {
                    try backend.getBytes(texture: h, MetalRegion(width: w, height: hgt, depth: d), level: level, slice: slice,
                                         into: region, bytesPerRow: row, bytesPerImage: image)
                } catch {
                    return nil
                }
                out += UnsafeRawBufferPointer(start: buffer, count: count)
            }
        }
        return out
    }

    // MARK: Restore

    /// Rebuilds the tables and replays every object on the (fresh) back end,
    /// before any client runs. `rightsValid`: whether a host-task name still
    /// denotes a right (the restored host task).
    func restoreState(_ g: SnapshotFieldReader) -> MetalReplayReport {
        typealias T = SnapTag
        var report = MetalReplayReport()
        var restored: [MetalProcessID: Process] = [:]
        var conns: [UInt32: Connection] = [:]
        for c in g.list(T.connections) {
            conns[c.u32(T.port)] = Connection(clientPort: c.u32(T.client), type: c.bool(T.hasType) ? c.u64(T.type) : nil,
                                              process: c.has(T.process) ? c.u64(T.process) : nil)
        }
        // (handle, process, kind, recipe, object record or nil for a ghost)
        var replay: [(MetalHandle, Process, MetalRefKind, MetalRecipe, SnapshotFieldReader?)] = []
        for pr in g.list(T.processes) {
            let p = Process(id: pr.u64(T.id))
            p.guestPID = pr.i32(T.guestPID)
            p.eventPort = pr.u32(T.eventPort)
            p.connections = Set(pr.u64s(T.procConnections).map { UInt32(truncatingIfNeeded: $0) })
            for t in pr.list(T.tables) {
                guard let kind = MetalRefKind(rawValue: t.string(T.kind) ?? "") else { continue }
                var table = RefTable()
                for (ref, h) in zip(t.u64s(T.refs), t.u64s(T.handles)) { table.map[UInt32(truncatingIfNeeded: ref)] = MetalHandle(h) }
                table.next = t.u32(T.next, default: 1)
                table.free = t.u64s(T.free).map { UInt32(truncatingIfNeeded: $0) }
                p.tables[kind] = table
            }
            for o in pr.list(T.objects) {
                guard let kind = MetalRefKind(rawValue: o.string(T.kind) ?? "") else { continue }
                let h = MetalHandle(o.u64(T.handle))
                let object = Object(kind: kind, ref: o.u32(T.ref))
                object.rights = o.u64s(T.rights).map { UInt32(truncatingIfNeeded: $0) }
                object.heap = o.has(T.heap) ? MetalHandle(o.u64(T.heap)) : nil
                object.heapBytes = o.u64(T.heapBytes)
                object.heapSize = o.u64(T.heapSize)
                object.heapUsed = o.u64(T.heapUsed)
                object.gpuAddress = o.u64(T.gpuAddress)
                object.eventValue = o.u64(T.eventValue)
                object.addressQueried = o.bool(T.addressQueried)
                object.recipe = o.nested(T.recipe).map(MetalRecipe.init)
                p.objects[h] = object
                if let r = object.recipe {
                    replay.append((h, p, kind, r, o))
                    for d in r.deps { p.dependents[d, default: 0] += 1 }
                }
            }
            for gh in pr.list(T.ghosts) {
                guard let kind = MetalRefKind(rawValue: gh.string(T.kind) ?? ""),
                      let r = gh.nested(T.recipe).map(MetalRecipe.init) else { continue }
                let h = MetalHandle(gh.u64(T.handle))
                p.ghosts[h] = (kind, r)
                replay.append((h, p, kind, r, nil))
                for d in r.deps { p.dependents[d, default: 0] += 1 }
            }
            restored[p.id] = p
            report.processes += 1
        }
        lock.withLock {
            processes = restored
            connections = conns
            nextProcess = max(nextProcess, g.u64(T.nextProcess))
            nextHandle = max(nextHandle, g.u64(T.nextHandle))
            nextGPUAddress = max(nextGPUAddress, g.u64(T.nextGPUAddress))
        }

        // Creation order: dependencies always have lower handles.
        replay.sort { $0.0 < $1.0 }
        for (h, p, kind, recipe, record) in replay {
            do {
                try recreate(h, kind, recipe, p)
                if record == nil { report.ghosts += 1 } else { report.objects += 1 }
            } catch {
                report.failures += 1
                if report.lines.count < 20 { report.lines.append("metal: replay of \(h) (\(kind), mt \(recipe.mt) op \(recipe.op)) failed: \(error)") }
            }
            guard let record else { continue }
            if record.has(T.eventValue), kind == .event, record.u64(T.eventValue) > 0 {
                backend.signalEvent(h, value: record.u64(T.eventValue))
            }
            if record.has(T.contents) {
                let bytes = record.bytes(T.contents)
                if record.u64(T.contentKind) == 1 {
                    if backend.setBufferContents(h, bytes) { report.bufferBytes += bytes.count } else { report.contentsSkipped += 1 }
                } else if writeTexture(h, recipe, bytes) {
                    report.textureBytes += bytes.count
                } else {
                    report.contentsSkipped += 1
                }
            }
            if kind == .sampler, record.has(T.backendAddress), let id = backend.gpuResourceID(ofSampler: h),
               id != record.u64(T.backendAddress) {
                report.samplerIDsChanged += 1
            }
            if kind == .resource, record.has(T.backendAddress), let a = backend.gpuAddress(ofBuffer: h), a != record.u64(T.backendAddress) {
                report.addressesChanged += 1
                if record.bool(T.addressQueried), report.lines.count < 20 {
                    report.lines.append("metal: buffer \(h): its GPU address changed and the guest had read it")
                }
            }
        }
        // The kept recipes are not live objects.
        for (_, p) in restored { for h in p.ghosts.keys { backend.release(h) } }
        return report
    }

    private func textureDescriptor(_ recipe: MetalRecipe) throws -> MetalTextureDescriptor {
        var r = ByteReader(recipe.body)
        if recipe.mt == 12 { _ = try r.u32(); _ = try r.u32() }
        // Op 21 (heap texture): words 1–8 unless the body is the 56-byte form (MetalHostCore).
        var desc = try MetalDescriptorCodec.texture(&r, leadingWord: !(recipe.mt == 12 && recipe.op == 21 && recipe.body.count < 56))
        if recipe.mt == 12, recipe.op == 21 { desc.resourceOptions = (desc.resourceOptions & ~0xF0) | 0x20 }
        return desc
    }

    private func writeTexture(_ h: MetalHandle, _ recipe: MetalRecipe, _ bytes: [UInt8]) -> Bool {
        guard let desc = try? textureDescriptor(recipe), let bpp = MetalPixelFormat.bytesPerPixel(desc.pixelFormat) else { return false }
        let slices = max(desc.arrayLength, 1)
            * (desc.textureType == MetalTextureType.typeCube || desc.textureType == MetalTextureType.typeCubeArray ? 6 : 1)
        var at = 0
        for level in 0..<max(desc.mipmapLevelCount, 1) {
            let w = max(desc.width >> level, 1), hgt = max(desc.height >> level, 1), d = max(desc.depth >> level, 1)
            let row = w * bpp, image = row * hgt
            for slice in 0..<slices {
                let count = image * d
                guard at + count <= bytes.count else { return false }
                do {
                    try backend.replaceRegion(texture: h, MetalRegion(width: w, height: hgt, depth: d), level: level, slice: slice,
                                              bytes: Array(bytes[at..<(at + count)]), bytesPerRow: row, bytesPerImage: image)
                } catch {
                    return false
                }
                at += count
            }
        }
        return true
    }

    /// Makes `h` again on the back end from its recipe.
    private func recreate(_ h: MetalHandle, _ kind: MetalRefKind, _ recipe: MetalRecipe, _ p: Process) throws {
        guard Self.isBackendObject(kind) else { return }
        switch (recipe.mt, recipe.op) {
        case (1, _):
            var storage = MetalStorageMode(resourceOptions: recipe.options)
            var region: GuestSharedRegion?
            if recipe.right != 0, let r = memory?.region(forMemoryEntry: recipe.right) {
                region = r.slice(at: 0, count: max(recipe.length, min(Int(recipe.rightSize), r.length)))
            }
            if region == nil, storage == .shared || storage == .managed { storage = .private }
            try backend.createBuffer(h, length: recipe.length, storage: storage, guestMemory: region)
        case (12, 24):
            try backend.createBuffer(h, length: recipe.length, storage: .private, guestMemory: nil)
        case (8, 1), (12, 21):
            try backend.createTexture(h, try textureDescriptor(recipe), iosurface: nil)
        case (8, 3):
            try backend.createSampler(h, try MetalDescriptorCodec.sampler(recipe.body))
        case (8, 4):
            try backend.createDepthStencilState(h, try MetalDescriptorCodec.depthStencil(recipe.body))
        case (13, 47):
            var r = ByteReader(recipe.body)
            let desc = try MetalDescriptorCodec.texture(&r, leadingWord: true)
            let backing = surfaces?.backing(forSurfacePort: recipe.right, plane: recipe.plane)
            try backend.createTexture(h, desc, iosurface: backing)
        case (19, 42):
            // A shared texture: GPU memory of the host's own; its surface
            // (restored by the IOSurface service) keeps the creation properties.
            var r = ByteReader(recipe.body)
            let desc = try MetalDescriptorCodec.texture(&r, leadingWord: recipe.body.count >= 36)
            try backend.createTexture(h, desc, iosurface: nil)
            if let id = surfaces?.surfaceDescription(forSurfacePort: recipe.right)?.id {
                lock.withLock {
                    p.objects[h]?.sharedSurface = id
                    sharedTextures[id, default: []].insert(h)
                }
            }
        case (15, _):
            try backend.createFunction(h, metallib: recipe.body)
        case (12, 7), (12, 8), (12, 27):
            var r = ByteReader(recipe.body)
            _ = try r.u32()
            _ = try r.u32()
            var view: MetalTextureViewDescriptor
            if recipe.op == 7 {
                view = MetalTextureViewDescriptor(pixelFormat: try r.u32())
            } else {
                let pf = try r.u16(), type = try r.u16()
                let ll = try r.int64(), ln = try r.int64(), sl = try r.int64(), sn = try r.int64()
                view = MetalTextureViewDescriptor(pixelFormat: UInt32(pf), textureType: UInt8(truncatingIfNeeded: type),
                                                  levels: ll..<(ll + ln), slices: sl..<(sl + sn))
                if recipe.op == 27 {
                    let s = try r.u32()
                    view.swizzle = [UInt8(s & 0xFF), UInt8((s >> 8) & 0xFF), UInt8((s >> 16) & 0xFF), UInt8(s >> 24)]
                }
            }
            guard let parent = recipe.deps.first else { return }
            try backend.createTextureView(h, parent: parent, view)
        case (12, 11):
            guard let f = recipe.deps.first else { return }
            _ = try backend.createComputePipeline(h, function: f)
        case (12, 13):
            try backend.createFence(h)
        case (12, 14):
            let payload = try MetalPipelineCodec.payload(recipe.body)
            let map = Dictionary(recipe.refMap, uniquingKeysWith: { a, _ in a })
            let desc = try MetalPipelineCodec.renderPipeline(payload) { map[$0] }
            try backend.createRenderPipeline(h, desc)
        case (12, 28):
            try backend.createEvent(h)
        default:
            break
        }
    }

    /// The connection ports of the restored processes (the transport serves them).
    var connectionPorts: [UInt32] { lock.withLock { Array(connections.keys) } }
}
