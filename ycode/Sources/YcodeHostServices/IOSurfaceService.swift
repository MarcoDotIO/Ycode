// The host IOSurface service `com.apple.IOSurface.Remote`
// (specs/simulator/iosurface-remote.md), served by the VMM's host task.
// Written from the spec; nothing here comes from the research test server.
//
// - Clients connect with the hand-shake 0x77303074 (§2.2): descriptor 0 is
//   the connection port (a receive right the service keeps and serves),
//   descriptor 1 a client port (kept, never used).
// - Requests 0x10000000 carry one `!CPX` dictionary with `Method` (§3);
//   replies 0x20000000 carry one `!CPX` dictionary with `ErrorCode`
//   (an IOReturn sign-extended to 64 bits) (§2.3, §2.4).
// - Each surface is a SharedMemoryObject (host memory that every guest VM
//   maps) behind a memory entry (§6); look-up by ID works for every
//   surface of the device, look-up by port for ports from Method 14.
// - A connection's references go when its port loses its senders (the
//   client process ended, §2.5); a surface goes when no connection holds a
//   reference and no Method-14 port has senders (§8 item 8).

import Foundation
import YcodeDarwinABI
import YcodeDarwinKernel
import YcodeXPC

/// A surface as the host sees it (no copy): its shared memory and layout.
public struct IOSurfaceInfo: @unchecked Sendable {
    public var id: UInt32
    public var memory: SharedMemoryObject
    public var width: Int, height: Int, bytesPerRow: Int, bytesPerElement: Int
    public var pixelFormat: UInt32
    public var allocationSize: Int
    /// Per plane (planar surfaces): offset, width, height, bytes per row.
    public var planes: [(offset: Int, width: Int, height: Int, bytesPerRow: Int)]
}

/// One surface's pixels, copied for the host (screenshots).
public struct IOSurfaceSnapshot: Sendable {
    public var id: UInt32
    public var name: String
    public var width: Int, height: Int, bytesPerRow: Int, bytesPerElement: Int
    public var pixelFormat: UInt32
    public var bytes: [UInt8]
}

public final class IOSurfaceHostService: @unchecked Sendable {
    public static let serviceName = "com.apple.IOSurface.Remote"
    static let handshakeID: Int32 = 0x7730_3074
    static let requestID: Int32 = 0x1000_0000
    static let replyID: Int32 = 0x2000_0000

    enum IOReturn {
        static let success: UInt32 = 0
        static let badArgument: UInt32 = 0xE000_02C2
        static let unsupported: UInt32 = 0xE000_02C7
        static let notFound: UInt32 = 0xE000_02F0
        static let noMemory: UInt32 = 0xE000_02BD
    }

    final class Surface {
        let id: UInt32
        let memory: SharedMemoryObject
        let entry: UInt32  // the host task's send right to the memory entry
        var width: UInt32, height: UInt32, bytesPerRow: UInt32, allocationSize: UInt32
        var pixelFormat: UInt32, cacheMode: UInt32, planeCount: UInt32
        var bytesPerElement: UInt32, elementWidth: UInt32, elementHeight: UInt32
        var seed: UInt32 = 0
        var castingAllowed = true
        var serial: UInt32
        var name: String
        var creation: [(key: String, value: OSValue)]
        var planes: [OSValue]
        var values: [(key: String, value: OSValue)] = []
        var attachments: [String: XPCObject] = [:]
        var lockCount = 0
        var useCount = 0
        var purgeable: UInt64 = 0
        var ports: Set<UInt32> = []

        init(id: UInt32, memory: SharedMemoryObject, entry: UInt32, serial: UInt32, name: String,
             creation: [(key: String, value: OSValue)], planes: [OSValue], layout: Layout) {
            self.id = id
            self.memory = memory
            self.entry = entry
            self.serial = serial
            self.name = name
            self.creation = creation
            self.planes = planes
            width = layout.width
            height = layout.height
            bytesPerRow = layout.bytesPerRow
            allocationSize = layout.allocationSize
            pixelFormat = layout.pixelFormat
            cacheMode = layout.cacheMode
            planeCount = UInt32(planes.count)
            bytesPerElement = layout.bytesPerElement
            elementWidth = layout.elementWidth
            elementHeight = layout.elementHeight
            castingAllowed = layout.castingAllowed
        }

        /// SurfaceState (§4.1): 18 u32.
        var state: [UInt8] {
            let words: [UInt32] = [0, id, allocationSize, width, height, bytesPerRow, 0, pixelFormat, cacheMode, planeCount,
                                   bytesPerElement, elementWidth, elementHeight, seed, 0,
                                   (castingAllowed ? 1 : 0) | serial << 8, 1, 1]
            return words.flatMap(le32)
        }
    }

    struct Layout {
        var width: UInt32 = 0, height: UInt32 = 0, bytesPerRow: UInt32 = 0, allocationSize: UInt32 = 0
        var pixelFormat: UInt32 = 0, cacheMode: UInt32 = 0
        var bytesPerElement: UInt32 = 1, elementWidth: UInt32 = 1, elementHeight: UInt32 = 1
        var castingAllowed = true
    }

    final class Connection {
        let clientPort: UInt32
        var references: [UInt32: Int] = [:]
        init(clientPort: UInt32) { self.clientPort = clientPort }
    }

    public let host: MachHostTask
    /// The service port: a receive right of the host task, with a send right
    /// under the same name (registered into the guest with 701).
    public let servicePort: UInt32
    private let portSet: UInt32
    private let log: (String) -> Void
    private let lock = NSLock()
    private var surfaces: [UInt32: Surface] = [:]
    private var connections: [UInt32: Connection] = [:]
    private var surfacePorts: [UInt32: UInt32] = [:]
    private var nextSurfaceSerial: UInt32 = 1
    private var stopping = false
    private var thread: Thread?
    /// Statistics.
    public private(set) var requestCount = 0

    public init(host: MachHostTask, log: @escaping (String) -> Void) throws {
        self.host = host
        self.log = log
        servicePort = try host.makePort(sendRight: true, qlimit: 1024)
        portSet = try host.makePortSet()
        try host.addMember(servicePort, to: portSet)
    }

    public func start() {
        let t = Thread { [self] in run() }
        t.name = "ycode-iosurface"
        thread = t
        t.start()
    }

    public func stop() { lock.withLock { stopping = true } }

    private func run() {
        while !lock.withLock({ stopping }) {
            let m: MachHostReceivedMessage
            do {
                m = try host.receive(on: portSet, timeout: 200_000_000, tracked: true)
            } catch let e as MachHostError where e == .timedOut || e == .interrupted {
                continue
            } catch {
                if !lock.withLock({ stopping }) { log("iosurface: receive failed: \(error); stopping") }
                return
            }
            handle(m)
            host.finishedMessage()
        }
    }

    // MARK: Messages

    func handle(_ m: MachHostReceivedMessage) {
        if m.localPort == servicePort {
            if m.id == Self.handshakeID { connect(m) } else { drop(m) }
            return
        }
        if m.id == MachNotify.noSenders {
            noSenders(on: m.localPort)
            return
        }
        guard m.id == Self.requestID, lock.withLock({ connections[m.localPort] != nil }) else {
            drop(m)
            return
        }
        request(m)
    }

    private func connect(_ m: MachHostReceivedMessage) {
        guard m.descriptors.count >= 2, case let .port(connection, type) = m.descriptors[0], type == 16,
              case let .port(client, _) = m.descriptors[1] else {
            log("iosurface: malformed hand-shake")
            drop(m)
            return
        }
        do {
            try host.addMember(connection, to: portSet)
            // No-senders on the connection port itself: the client ended.
            _ = try host.requestNotification(connection, id: MachNotify.noSenders, sync: 0, notifyPort: connection)
        } catch {
            log("iosurface: cannot serve connection \(connection): \(error)")
            try? host.destroyPort(connection)
            try? host.deallocate(client)
            return
        }
        lock.withLock { connections[connection] = Connection(clientPort: client) }
    }

    /// The right a request or notification brought, dropped (a send right to
    /// one of the service's own ports drops only that send reference).
    private func drop(_ m: MachHostReceivedMessage) {
        var names: [UInt32] = []
        if MachPortName.isValid(m.replyPort) { names.append(m.replyPort) }
        for d in m.descriptors { if case let .port(name, _) = d { names.append(name) } }
        for name in names where MachPortName.isValid(name) {
            guard let (type, _) = host.rights(of: name) else { continue }
            if type & MachPortType.receive != 0 {
                if type & MachPortType.send != 0 { try? host.modRefs(name, right: MachPortRight.send, delta: -1) }
            } else {
                try? host.deallocate(name)
            }
        }
    }

    private func noSenders(on port: UInt32) {
        var freed: [Surface] = []
        lock.withLock {
            if let c = connections.removeValue(forKey: port) {
                try? host.destroyPort(port)
                try? host.deallocate(c.clientPort)
                for id in c.references.keys { if let s = releaseIfUnused(id) { freed.append(s) } }
            } else if let id = surfacePorts.removeValue(forKey: port) {
                try? host.destroyPort(port)
                surfaces[id]?.ports.remove(port)
                if let s = releaseIfUnused(id) { freed.append(s) }
            }
        }
        for s in freed { try? host.deallocate(s.entry) }
    }

    /// Removes the surface when no connection references it and no port
    /// has senders (lock held). Returns it so the caller drops its entry.
    private func releaseIfUnused(_ id: UInt32) -> Surface? {
        guard let s = surfaces[id], s.ports.isEmpty,
              !connections.values.contains(where: { ($0.references[id] ?? 0) > 0 }) else { return nil }
        surfaces[id] = nil
        return s
    }

    private func request(_ m: MachHostReceivedMessage) {
        let wire: [XPCWireDescriptor] = m.descriptors.map {
            switch $0 {
            case let .port(name, type): return .port(name: name, disposition: type)
            case let .ool(data, _, _): return .ool(bytes: data)
            case let .oolPorts(names, type): return .oolPorts(names: names, disposition: type)
            case let .guardedPort(name, _, type): return .guardedPort(name: name, disposition: type)
            }
        }
        var reply: [(String, XPCObject)]
        var afterReply: (() -> Void)?
        do {
            let object = try XPCWire.decode(body: m.body, descriptors: wire)
            guard case let .dictionary(d) = object else { throw XPCWireError.noPayload }
            (reply, afterReply) = perform(d, connection: m.localPort)
            if Self.failureLog, let code = reply.first(where: { $0.0 == "ErrorCode" })?.1.uint64Value, code != 0 {
                logFailure(d, code: code)
            }
        } catch {
            log("iosurface: undecodable request: \(error)")
            reply = [("ErrorCode", Self.code(IOReturn.badArgument))]
        }
        requestCount += 1
        do {
            let encoded = try XPCWire.encode(.dictionary(XPCDict(reply.map { XPCDict.Entry(key: $0.0, value: $0.1) })),
                                             magic: XPCWire.sim2hostMagic)
            let descriptors: [MachHostDescriptor] = encoded.descriptors.compactMap {
                if case let .port(name, disposition) = $0 { return .port(name: name, disposition: disposition) }
                return nil
            }
            try host.reply(to: m, id: Self.replyID, descriptors: descriptors, body: encoded.body)
        } catch {
            log("iosurface: reply failed: \(error)")
        }
        var rest = m
        rest.replyPort = 0
        drop(rest)
        afterReply?()
    }

    /// Diagnostics (`YCODE_IOSURFACE_LOG=1`): each failed request is logged
    /// (the first 64): method, error, and the creation keys of a create.
    static let failureLog = ProcessInfo.processInfo.environment["YCODE_IOSURFACE_LOG"] == "1"
    private var failuresLogged = 0

    private func logFailure(_ d: XPCDict, code: UInt64) {
        guard failuresLogged < 64 else { return }
        failuresLogged += 1
        var text = "iosurface: method \(d["Method"]?.uint64Value ?? .max) failed \(String(format: "0x%08x", UInt32(truncatingIfNeeded: code)))"
        if case let .data(blob)? = d["PropertiesDictionary"], let props = try? OSSerialize.decode(blob), let pairs = props.dictionaryValue {
            text += "; properties: " + pairs.map { "\($0.key)=\($0.value.numberValue.map(String.init) ?? $0.value.stringValue ?? "…")" }
                .sorted().joined(separator: " ")
        }
        log(text)
    }

    static func code(_ ioReturn: UInt32) -> XPCObject { .uint64(UInt64(bitPattern: Int64(Int32(bitPattern: ioReturn)))) }

    // MARK: Methods (§3)

    /// The reply entries for one request, and work to do after the reply is
    /// sent (arming a no-senders request for a new surface port).
    func perform(_ d: XPCDict, connection: UInt32) -> ([(String, XPCObject)], (() -> Void)?) {
        let method = d["Method"]?.uint64Value ?? .max
        let surfaceID = d["SurfaceID"].flatMap { $0.uint64Value }.map { UInt32(truncatingIfNeeded: $0) }
        if method == 4, let id = surfaceID, (d["Options"]?.uint64Value ?? 0) & 2 == 0 { gpuWriteWait?(id) }
        return lock.withLock {
            func fail(_ e: UInt32) -> ([(String, XPCObject)], (() -> Void)?) { ([("ErrorCode", Self.code(e))], nil) }
            func withState(_ s: Surface, _ extra: [(String, XPCObject)] = []) -> ([(String, XPCObject)], (() -> Void)?) {
                ([("ErrorCode", Self.code(0)), ("SurfaceState", .data(s.state)), ("SurfaceID", .uint64(UInt64(s.id)))] + extra, nil)
            }
            switch method {
            case 0:
                let limits: [UInt32] = [1, 0x3FFF, 0x7F, 0x8000, 0x4000, 0x4000, 1, 0, 1, 0]
                return ([("Limits", .data(limits.flatMap(le32))), ("ErrorCode", Self.code(0)), ("ProtocolVersion", .uint64(1))], nil)
            case 2:
                return createOrLookUp(d, connection: connection)
            default:
                break
            }
            guard let id = surfaceID, let s = surfaces[id] else { return fail(IOReturn.notFound) }
            switch method {
            case 3:
                if let c = connections[connection], let n = c.references[id], n > 0 {
                    c.references[id] = n - 1
                    if let freed = releaseIfUnused(id) { try? host.deallocate(freed.entry) }
                }
                return fail(0)
            case 4:
                let options = d["Options"]?.uint64Value ?? 0
                if options & 1 == 0 { s.seed &+= 1 }
                s.lockCount += 1
                return withState(s)
            case 5:
                guard s.lockCount > 0 else { return fail(IOReturn.badArgument) }
                s.lockCount -= 1
                return withState(s)
            case 6:
                let index = Int(d["PlaneIndex"]?.uint64Value ?? 0)
                guard index < s.planes.count else { return fail(IOReturn.badArgument) }
                return withState(s, [("PlaneState", .data(planeState(s, index)))])
            case 9:
                guard case let .data(blob)? = d["PropertiesDictionary"], let v = try? OSSerialize.decode(blob) else {
                    return fail(IOReturn.badArgument)
                }
                if v["isSetValues"]?.boolValue == true, let values = v["value"]?.dictionaryValue {
                    for (k, value) in values { setValue(s, k, value) }
                } else if let k = v["key"]?.stringValue, let value = v["value"] {
                    setValue(s, k, value)
                } else {
                    return fail(IOReturn.badArgument)
                }
                return withState(s)
            case 10:
                return withState(s, [("PropertiesDictionary", .data(OSSerialize.encode(allValues(s))))])
            case 11:
                guard let key = d["PropertyKey"]?.stringValue else { return fail(IOReturn.badArgument) }
                s.values.removeAll { $0.key == key }
                return withState(s)
            case 12:
                s.values.removeAll()
                return withState(s)
            case 13:
                let old = s.purgeable
                let new = (d["NewState"]?.uint64Value ?? 3) & 0xFF
                if new != 3 { s.purgeable = new }
                return withState(s, [("OldState", .uint64(old))])
            case 14:
                guard let port = try? host.makePort() else { return fail(IOReturn.noMemory) }
                surfacePorts[port] = id
                s.ports.insert(port)
                let host = self.host, set = portSet
                return ([("ErrorCode", Self.code(0)), ("SurfaceState", .data(s.state)), ("SurfaceID", .uint64(UInt64(id))),
                         ("MachPort", .sendRight(XPCPort(name: port, disposition: XPCDisposition.makeSend)))], {
                    try? host.addMember(port, to: set)
                    _ = try? host.requestNotification(port, id: MachNotify.noSenders, sync: 1, notifyPort: port)
                })
            case 15:
                s.useCount += 1
                return withState(s)
            case 16:
                s.useCount = max(0, s.useCount - 1)
                return withState(s)
            case 17:
                return withState(s, [("IsInUse", .bool(s.useCount > 0 || !s.ports.isEmpty))])
            case 20:
                for e in d.entries where Self.attachmentDefaults[e.key] != nil { s.attachments[e.key] = e.value }
                return withState(s)
            case 21:
                let all = Self.attachmentOrder.map { ($0, s.attachments[$0] ?? Self.attachmentDefaults[$0]!) }
                return withState(s, all)
            default:
                return fail(IOReturn.unsupported)
            }
        }
    }

    static let attachmentOrder = ["ChromaLocationTopField", "ChromaLocationBottomField", "FieldCount", "FieldDetail",
                                  "ChromaSubsampling", "PremultipliedAlpha", "TransferFunctionIndex", "ColorPrimariesIndex",
                                  "YCbCrMatrixIndex", "GammaLevel", "EDRFactor", "ContentLightLevelInfo", "PixelAspectRatio",
                                  "MasteringDisplayColorVolume", "CleanAperture"]
    static let attachmentDefaults: [String: XPCObject] = [
        "ChromaLocationTopField": .uint64(0), "ChromaLocationBottomField": .uint64(0), "FieldCount": .uint64(0),
        "FieldDetail": .uint64(0), "ChromaSubsampling": .uint64(0x80), "PremultipliedAlpha": .uint64(0),
        "TransferFunctionIndex": .uint64(0), "ColorPrimariesIndex": .uint64(0), "YCbCrMatrixIndex": .uint64(0),
        "GammaLevel": .data([UInt8](repeating: 0, count: 8)), "EDRFactor": .data([UInt8](repeating: 0, count: 8)),
        "ContentLightLevelInfo": .data([UInt8](repeating: 0, count: 8)),
        "PixelAspectRatio": .data([UInt8](repeating: 0, count: 24)),
        "MasteringDisplayColorVolume": .data([UInt8](repeating: 0, count: 32)),
        "CleanAperture": .data([UInt8](repeating: 0, count: 40)),
    ]

    private func setValue(_ s: Surface, _ key: String, _ value: OSValue) {
        if key == "IOSurfaceName", let name = value.stringValue { s.name = name }
        if let i = s.values.firstIndex(where: { $0.key == key }) { s.values[i].value = value } else { s.values.append((key, value)) }
    }

    /// Method 10's blob: the stored values plus the three the service adds (§3.1).
    private func allValues(_ s: Surface) -> OSValue {
        var pairs = s.values
        if !pairs.contains(where: { $0.key == "IOSurfaceName" }) { pairs.append(("IOSurfaceName", .string(s.name))) }
        var creation = s.creation
        if !creation.contains(where: { $0.key == "IOSurfacePixelSizeCastingAllowed" }) {
            creation.append(("IOSurfacePixelSizeCastingAllowed", .bool(s.castingAllowed)))
        }
        pairs.append(("CreationProperties", .dictionary(creation)))
        if !pairs.contains(where: { $0.key == "HorizontalDisparityAdjustment" }) {
            pairs.append(("HorizontalDisparityAdjustment", .number(0, bits: 32)))
        }
        return .dictionary(pairs)
    }

    private func planeState(_ s: Surface, _ index: Int) -> [UInt8] {
        let p = s.planes[index]
        func n(_ key: String) -> UInt32 { UInt32(truncatingIfNeeded: p[key]?.numberValue ?? 0) }
        var words = [UInt32](repeating: 0, count: 18)
        words[0] = UInt32(index) << 16
        words[1] = n("IOSurfacePlaneWidth")
        words[2] = n("IOSurfacePlaneHeight")
        words[3] = n("IOSurfacePlaneOffset")
        words[4] = n("IOSurfacePlaneBytesPerRow")
        words[5] = n("IOSurfacePlaneSize")
        words[10] = (n("IOSurfacePlaneBytesPerElement") & 0xFF) | 1 << 16 | 1 << 24
        return words.flatMap(le32)
    }

    // MARK: Create and look up (Method 2)

    private func createOrLookUp(_ d: XPCDict, connection: UInt32) -> ([(String, XPCObject)], (() -> Void)?) {
        func fail(_ e: UInt32) -> ([(String, XPCObject)], (() -> Void)?) { ([("ErrorCode", Self.code(e))], nil) }
        let surface: Surface
        if case let .data(blob)? = d["PropertiesDictionary"] {
            guard let props = try? OSSerialize.decode(blob), let pairs = props.dictionaryValue,
                  let layout = Self.layout(props) else { return fail(IOReturn.badArgument) }
            let size = (UInt64(layout.allocationSize) + 0x3FFF) & ~0x3FFF
            guard let memory = try? SharedMemoryObject(size: size), let entry = try? host.makeMemoryEntry(memory) else {
                return fail(IOReturn.noMemory)
            }
            var id: UInt32 = 1
            while surfaces[id] != nil { id += 1 }
            let name = props["IOSurfaceName"]?.stringValue ?? ""
            surface = Surface(id: id, memory: memory, entry: entry, serial: nextSurfaceSerial, name: name, creation: pairs,
                              planes: props["IOSurfacePlaneInfo"]?.arrayValue ?? [], layout: layout)
            nextSurfaceSerial &+= 1
            surfaces[id] = surface
        } else if let lookup = d["LookupID"]?.uint64Value {
            guard let s = surfaces[UInt32(truncatingIfNeeded: lookup)] else { return fail(IOReturn.notFound) }
            surface = s
        } else if case let .sendRight(port)? = d["MachPort"] {
            guard let id = surfacePorts[port.name], let s = surfaces[id] else { return fail(IOReturn.notFound) }
            surface = s
        } else {
            return fail(IOReturn.badArgument)
        }
        connections[connection]?.references[surface.id, default: 0] += 1
        return ([("MemoryObject", .sharedMemory(size: UInt32(surface.memory.size),
                                                port: XPCPort(name: surface.entry, disposition: XPCDisposition.copySend))),
                 ("ErrorCode", Self.code(0)), ("SurfaceState", .data(surface.state))], nil)
    }

    /// §4.2: bytes per row and allocation size, computed when not given.
    static func layout(_ p: OSValue) -> Layout? {
        func n(_ key: String) -> UInt64? { p[key]?.numberValue }
        var l = Layout()
        guard let width = n("IOSurfaceWidth"), let height = n("IOSurfaceHeight"), width > 0, height > 0,
              width <= 0x4000, height <= 0x4000 else { return nil }
        l.width = UInt32(width)
        l.height = UInt32(height)
        l.bytesPerElement = UInt32(max(n("IOSurfaceBytesPerElement") ?? 1, 1))
        l.elementWidth = UInt32(max(n("IOSurfaceElementWidth") ?? 1, 1))
        l.elementHeight = UInt32(max(n("IOSurfaceElementHeight") ?? 1, 1))
        l.pixelFormat = UInt32(truncatingIfNeeded: n("IOSurfacePixelFormat") ?? 0)
        l.cacheMode = UInt32(truncatingIfNeeded: n("IOSurfaceCacheMode") ?? 0)
        if let casting = p["IOSurfacePixelSizeCastingAllowed"]?.boolValue { l.castingAllowed = casting }
        let rowGiven = n("IOSurfaceBytesPerRow")
        let row = rowGiven ?? ((width * UInt64(l.bytesPerElement) + 127) & ~127)
        guard row > 0, row <= 0x40000 else { return nil }
        l.bytesPerRow = UInt32(row)
        var alloc = n("IOSurfaceAllocSize") ?? 0
        if alloc == 0 {
            var total = row * height
            if let planes = p["IOSurfacePlaneInfo"]?.arrayValue {
                for plane in planes {
                    let end = (plane["IOSurfacePlaneOffset"]?.numberValue ?? 0) + (plane["IOSurfacePlaneSize"]?.numberValue ?? 0)
                    total = max(total, end)
                }
            }
            alloc = (total + 0x3FFF) & ~0x3FFF
        }
        guard alloc > 0, alloc <= 1 << 31 else { return nil }
        l.allocationSize = UInt32(alloc)
        return l
    }

    /// A surface made by the host itself for a shared texture (Ycode's Metal
    /// host, messageType 19; metal-sim-protocol.md §5.10, visionos.md
    /// §10.10.2), as the reference host makes it: width, height, bytes per
    /// row, pixel format and plane count 0, bytes per element 1, the given
    /// allocation size (the memory is rounded up to 16 KiB), the name, and
    /// the given creation properties (numbers; 64-bit when the value needs
    /// it) plus `IOSurfaceName`. Every process that looks the surface up by
    /// ID or port sees them (Method 10). It has a Method-14 port: a receive
    /// right of the host task whose send right the caller hands to the
    /// guest, which looks the surface up by it like any surface port.
    /// Returns the port name, or nil.
    public func makeSharedTextureSurface(allocationSize: UInt32, name: String,
                                         properties: [(key: String, value: UInt64)]) -> UInt32? {
        guard allocationSize > 0, allocationSize <= 1 << 31 else { return nil }
        var l = Layout()
        l.allocationSize = allocationSize
        let size = (UInt64(allocationSize) + 0x3FFF) & ~0x3FFF
        guard let memory = try? SharedMemoryObject(size: size),
              let entry = try? host.makeMemoryEntry(memory), let port = try? host.makePort() else { return nil }
        var creation: [(key: String, value: OSValue)] = properties.map {
            ($0.key, .number($0.value, bits: $0.value > UInt64(UInt32.max) ? 64 : 32))
        }
        if let i = creation.firstIndex(where: { $0.key == "IOSurfaceAllocSize" }) {
            creation.insert(("IOSurfaceName", .string(name)), at: i + 1)
        } else {
            creation.append(("IOSurfaceName", .string(name)))
        }
        lock.withLock {
            var id: UInt32 = 1
            while surfaces[id] != nil { id += 1 }
            let surface = Surface(id: id, memory: memory, entry: entry, serial: nextSurfaceSerial, name: name, creation: creation,
                                  planes: [], layout: l)
            nextSurfaceSerial &+= 1
            surface.ports.insert(port)
            surfaces[id] = surface
            surfacePorts[port] = id
        }
        try? host.addMember(port, to: portSet)
        _ = try? host.requestNotification(port, id: MachNotify.noSenders, sync: 1, notifyPort: port)
        return port
    }

    /// One plane of a surface the host lays out itself (`makeHostSurface`).
    public struct HostPlane: Sendable, Equatable {
        public var offset: Int, width: Int, height: Int, bytesPerRow: Int, bytesPerElement: Int, size: Int
        public init(offset: Int, width: Int, height: Int, bytesPerRow: Int, bytesPerElement: Int, size: Int) {
            (self.offset, self.width, self.height) = (offset, width, height)
            (self.bytesPerRow, self.bytesPerElement, self.size) = (bytesPerRow, bytesPerElement, size)
        }
    }

    /// A surface the host makes and fills itself (camera frames,
    /// camera-host.md §5), with a full layout: width, height, pixel format,
    /// bytes per element and row, allocation size, and per-plane info for
    /// planar formats. The creation properties are the public
    /// `IOSurfaceRef.h` keys a guest client would have passed (so Method 10
    /// and the plane methods answer as for a guest-made surface), plus
    /// `IOSurfaceName`. `attachments` preset Method 21's values (known keys
    /// only). Like a shared texture surface it has a Method-14 port (a
    /// receive right of the host task) that keeps it alive until
    /// `releaseHostSurface(port:)`; guests look it up by ID or by a send
    /// right to that port. Returns the port and the surface, or nil.
    public func makeHostSurface(width: Int, height: Int, pixelFormat: UInt32, bytesPerElement: Int, bytesPerRow: Int,
                                allocationSize: Int, planes: [HostPlane], name: String,
                                attachments: [String: UInt64] = [:]) -> (port: UInt32, surface: IOSurfaceInfo)? {
        guard width > 0, height > 0, width <= 0x4000, height <= 0x4000, allocationSize > 0, allocationSize <= 1 << 31,
              planes.allSatisfy({ $0.offset >= 0 && $0.offset + $0.size <= allocationSize }) else { return nil }
        var l = Layout()
        l.width = UInt32(width)
        l.height = UInt32(height)
        l.pixelFormat = pixelFormat
        l.bytesPerElement = UInt32(max(bytesPerElement, 1))
        l.bytesPerRow = UInt32(bytesPerRow)
        l.allocationSize = UInt32(allocationSize)
        func n(_ v: Int) -> OSValue { .number(UInt64(v), bits: 32) }
        let planeInfo: [OSValue] = planes.map {
            .dictionary([("IOSurfacePlaneWidth", n($0.width)), ("IOSurfacePlaneHeight", n($0.height)),
                         ("IOSurfacePlaneBytesPerRow", n($0.bytesPerRow)), ("IOSurfacePlaneOffset", n($0.offset)),
                         ("IOSurfacePlaneSize", n($0.size)), ("IOSurfacePlaneBytesPerElement", n($0.bytesPerElement))])
        }
        var creation: [(key: String, value: OSValue)] = [
            ("IOSurfaceWidth", n(width)), ("IOSurfaceHeight", n(height)), ("IOSurfacePixelFormat", n(Int(pixelFormat))),
            ("IOSurfaceBytesPerElement", n(Int(l.bytesPerElement))), ("IOSurfaceBytesPerRow", n(bytesPerRow)),
            ("IOSurfaceAllocSize", n(allocationSize)), ("IOSurfaceName", .string(name)),
        ]
        if !planeInfo.isEmpty { creation.append(("IOSurfacePlaneInfo", .array(planeInfo))) }
        let size = (UInt64(allocationSize) + 0x3FFF) & ~0x3FFF
        guard let memory = try? SharedMemoryObject(size: size),
              let entry = try? host.makeMemoryEntry(memory), let port = try? host.makePort() else { return nil }
        let info: IOSurfaceInfo = lock.withLock {
            var id: UInt32 = 1
            while surfaces[id] != nil { id += 1 }
            let surface = Surface(id: id, memory: memory, entry: entry, serial: nextSurfaceSerial, name: name, creation: creation,
                                  planes: planeInfo, layout: l)
            nextSurfaceSerial &+= 1
            for (k, v) in attachments where Self.attachmentDefaults[k] != nil { surface.attachments[k] = .uint64(v) }
            surface.ports.insert(port)
            surfaces[id] = surface
            surfacePorts[port] = id
            return self.info(surface)
        }
        try? host.addMember(port, to: portSet)
        _ = try? host.requestNotification(port, id: MachNotify.noSenders, sync: 1, notifyPort: port)
        return (port, info)
    }

    /// Ends the host's hold on a surface from `makeHostSurface` (or
    /// `makeSharedTextureSurface`): its port is destroyed, and the surface
    /// goes once no guest connection references it (§8 item 8).
    public func releaseHostSurface(port: UInt32) {
        var freed: Surface?
        lock.withLock {
            guard let id = surfacePorts.removeValue(forKey: port) else { return }
            try? host.destroyPort(port)
            surfaces[id]?.ports.remove(port)
            freed = releaseIfUnused(id)
        }
        if let s = freed { try? host.deallocate(s.entry) }
    }

    /// After the host wrote a surface's pixels: raises its seed, as a guest
    /// lock for writing does (§3.1), so readers that skip unchanged surfaces
    /// (the GPU back end) see the new contents. Returns the new seed.
    @discardableResult
    public func hostDidWrite(id: UInt32) -> UInt32? {
        lock.withLock {
            guard let s = surfaces[id] else { return nil }
            s.seed &+= 1
            return s.seed
        }
    }

    /// What guests hold on a surface: the use count (Methods 15, 16), the
    /// lock count (Methods 4, 5), and the connections that reference it
    /// (Method 2). Nil when there is no such surface.
    public func guestUsage(id: UInt32) -> (useCount: Int, lockCount: Int, references: Int)? {
        lock.withLock {
            guard let s = surfaces[id] else { return nil }
            let refs = connections.values.reduce(0) { $0 + max(0, $1.references[id] ?? 0) }
            return (s.useCount, s.lockCount, refs)
        }
    }

    /// The surface behind a Method-14 port (a host-task name): its ID and
    /// its creation properties that are numbers, or nil.
    public func creationNumbers(forPort port: UInt32) -> (id: UInt32, numbers: [String: UInt64])? {
        lock.withLock {
            guard let id = surfacePorts[port], let s = surfaces[id] else { return nil }
            var numbers: [String: UInt64] = [:]
            for (k, v) in s.creation { if let n = v.numberValue { numbers[k] = n } }
            return (id, numbers)
        }
    }

    /// Tests: a connection without a Mach port behind it.
    func addTestConnection(_ name: UInt32) { lock.withLock { connections[name] = Connection(clientPort: 0) } }

    // MARK: Host access

    /// The surface behind a Method-14 port (a host-task name), or nil.
    public func surface(forPort port: UInt32) -> IOSurfaceInfo? {
        lock.withLock { surfacePorts[port].flatMap { surfaces[$0] }.map(info) }
    }

    /// The surface with `id`, or nil. Its pixels are complete: GPU work that
    /// writes the surface and was reported scheduled is waited for first
    /// (`gpuWriteWait`), so host readers (the display server, screenshots)
    /// never see a frame the GPU is still drawing.
    public func surface(id: UInt32) -> IOSurfaceInfo? {
        gpuWriteWait?(id)
        return lock.withLock { surfaces[id].map(info) }
    }

    /// Waits until GPU work that writes the surface is complete (set by the
    /// Metal host's wiring; never called under this service's lock). Used
    /// by `surface(id:)` and by guest locks without kIOSurfaceLockAvoidSync,
    /// as IOSurfaceLock synchronizes with pending GPU access.
    public var gpuWriteWait: (@Sendable (UInt32) -> Void)?

    /// The surface's seed (raised by every lock for writing) and whether any
    /// lock is held, or nil when there is no such surface. The GPU back end
    /// skips copying in a surface whose seed did not change.
    public func lockState(id: UInt32) -> (seed: UInt32, locked: Bool)? {
        lock.withLock { surfaces[id].map { ($0.seed, $0.lockCount > 0) } }
    }

    private func info(_ s: Surface) -> IOSurfaceInfo {
        let planes = s.planes.map { p -> (offset: Int, width: Int, height: Int, bytesPerRow: Int) in
            func n(_ key: String) -> Int { Int(truncatingIfNeeded: p[key]?.numberValue ?? 0) }
            return (n("IOSurfacePlaneOffset"), n("IOSurfacePlaneWidth"), n("IOSurfacePlaneHeight"), n("IOSurfacePlaneBytesPerRow"))
        }
        return IOSurfaceInfo(id: s.id, memory: s.memory, width: Int(s.width), height: Int(s.height), bytesPerRow: Int(s.bytesPerRow),
                             bytesPerElement: Int(s.bytesPerElement), pixelFormat: s.pixelFormat,
                             allocationSize: Int(s.allocationSize), planes: planes)
    }

    /// A copy of a surface's pixels and layout, or nil.
    public func snapshot(surfaceID: UInt32) -> IOSurfaceSnapshot? {
        gpuWriteWait?(surfaceID)  // a screenshot shows finished pixels (see `surface(id:)`)
        return lock.withLock {
            guard let s = surfaces[surfaceID] else { return nil }
            let count = Int(min(UInt64(s.allocationSize), s.memory.size))
            let bytes = [UInt8](UnsafeRawBufferPointer(start: s.memory.host, count: count))
            return IOSurfaceSnapshot(id: s.id, name: s.name, width: Int(s.width), height: Int(s.height),
                                     bytesPerRow: Int(s.bytesPerRow), bytesPerElement: Int(s.bytesPerElement),
                                     pixelFormat: s.pixelFormat, bytes: bytes)
        }
    }

    // MARK: Snapshot (snapshot.md §2.6, §8)

    /// Field tags of the service's state record.
    enum SnapTag {
        static let nextSerial: UInt16 = 1, surfaces: UInt16 = 2, connections: UInt16 = 3
        // surface
        static let id: UInt16 = 10, entry: UInt16 = 11, serial: UInt16 = 12, name: UInt16 = 13, creation: UInt16 = 14
        static let planes: UInt16 = 15, layout: UInt16 = 16, seed: UInt16 = 17, casting: UInt16 = 18, values: UInt16 = 19
        static let attachments: UInt16 = 20, lockCount: UInt16 = 21, useCount: UInt16 = 22, purgeable: UInt16 = 23
        static let ports: UInt16 = 24
        // connection
        static let port: UInt16 = 30, client: UInt16 = 31, refIDs: UInt16 = 32, refCounts: UInt16 = 33
    }

    /// The service's whole state (surfaces, connections, surface ports), as
    /// host-task names; nil when the service is busy (its lock is taken):
    /// the snapshot tries again. Called with the kernel lock held, so it
    /// only tries the service lock (the service takes it before the kernel lock).
    public func trySnapshotState() -> SnapshotFields? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        typealias T = SnapTag
        var g = SnapshotFields()
        g.u64(T.nextSerial, UInt64(nextSurfaceSerial))
        g.list(T.surfaces, surfaces.values.sorted { $0.id < $1.id }.map { s in
            var f = SnapshotFields()
            f.u64(T.id, UInt64(s.id))
            f.u64(T.entry, UInt64(s.entry))
            f.u64(T.serial, UInt64(s.serial))
            f.string(T.name, s.name)
            f.bytes(T.creation, OSSerialize.encode(.dictionary(s.creation)))
            f.bytes(T.planes, OSSerialize.encode(.array(s.planes)))
            f.u64s(T.layout, [s.width, s.height, s.bytesPerRow, s.allocationSize, s.pixelFormat, s.cacheMode,
                              s.bytesPerElement, s.elementWidth, s.elementHeight].map(UInt64.init))
            f.u64(T.seed, UInt64(s.seed))
            f.bool(T.casting, s.castingAllowed)
            f.bytes(T.values, OSSerialize.encode(.dictionary(s.values)))
            let attachments = XPCDict(s.attachments.sorted { $0.key < $1.key }.map { XPCDict.Entry(key: $0.key, value: $0.value) })
            if let bytes = try? XPCWire.encodePayload(.dictionary(attachments)) { f.bytes(T.attachments, bytes) }
            f.i64(T.lockCount, Int64(s.lockCount))
            f.i64(T.useCount, Int64(s.useCount))
            f.u64(T.purgeable, s.purgeable)
            f.u64s(T.ports, s.ports.sorted().map(UInt64.init))
            return f
        })
        g.list(T.connections, connections.sorted { $0.key < $1.key }.map { port, c in
            var f = SnapshotFields()
            f.u64(T.port, UInt64(port))
            f.u64(T.client, UInt64(c.clientPort))
            let refs = c.references.sorted { $0.key < $1.key }
            f.u64s(T.refIDs, refs.map { UInt64($0.key) })
            f.u64s(T.refCounts, refs.map { UInt64(max(0, $0.value)) })
            return f
        })
        return g
    }

    /// After a restore, before any guest thread runs: the recorded state.
    /// The host task holds the recorded rights under their recorded names
    /// (connection and surface ports with their no-senders requests, set
    /// membership, memory entries), so only the service's tables come back.
    /// Returns the number of surfaces.
    @discardableResult
    public func restoreState(_ r: SnapshotFieldReader) throws -> Int {
        typealias T = SnapTag
        var restored: [UInt32: Surface] = [:]
        var ports: [UInt32: UInt32] = [:]
        for f in r.list(T.surfaces) {
            let entry = f.u32(T.entry)
            guard let (memory, _, _) = host.memoryEntry(entry) else {
                throw SnapshotError("IOSurface \(f.u32(T.id)): memory entry 0x\(String(entry, radix: 16)) is gone")
            }
            let l = f.u64s(T.layout).map { UInt32(truncatingIfNeeded: $0) } + [UInt32](repeating: 1, count: 9)
            var layout = Layout()
            (layout.width, layout.height, layout.bytesPerRow, layout.allocationSize) = (l[0], l[1], l[2], l[3])
            (layout.pixelFormat, layout.cacheMode) = (l[4], l[5])
            (layout.bytesPerElement, layout.elementWidth, layout.elementHeight) = (l[6], l[7], l[8])
            layout.castingAllowed = f.bool(T.casting, default: true)
            let creation = (try? OSSerialize.decode(f.bytes(T.creation)))?.dictionaryValue ?? []
            let planes = (try? OSSerialize.decode(f.bytes(T.planes)))?.arrayValue ?? []
            let s = Surface(id: f.u32(T.id), memory: memory, entry: entry, serial: f.u32(T.serial), name: f.string(T.name) ?? "",
                            creation: creation, planes: planes, layout: layout)
            s.seed = f.u32(T.seed)
            s.values = (try? OSSerialize.decode(f.bytes(T.values)))?.dictionaryValue ?? []
            if f.has(T.attachments), case let .dictionary(d)? = try? XPCWire.decodePayload(f.bytes(T.attachments), ports: nil) {
                for e in d.entries { s.attachments[e.key] = e.value }
            }
            s.lockCount = Int(f.i64(T.lockCount))
            s.useCount = Int(f.i64(T.useCount))
            s.purgeable = f.u64(T.purgeable)
            for p in f.u64s(T.ports) {
                let port = UInt32(truncatingIfNeeded: p)
                s.ports.insert(port)
                ports[port] = s.id
            }
            restored[s.id] = s
        }
        var conns: [UInt32: Connection] = [:]
        for f in r.list(T.connections) {
            let c = Connection(clientPort: f.u32(T.client))
            for (id, n) in zip(f.u64s(T.refIDs), f.u64s(T.refCounts)) { c.references[UInt32(truncatingIfNeeded: id)] = Int(n) }
            conns[f.u32(T.port)] = c
        }
        lock.withLock {
            surfaces = restored
            surfacePorts = ports
            connections = conns
            nextSurfaceSerial = max(nextSurfaceSerial, r.u32(T.nextSerial))
        }
        return restored.count
    }

    /// The IDs and names of the live surfaces (diagnostics).
    public var surfaceSummary: [(id: UInt32, name: String, width: Int, height: Int)] {
        lock.withLock { surfaces.values.sorted { $0.id < $1.id }.map { ($0.id, $0.name, Int($0.width), Int($0.height)) } }
    }
}

func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
