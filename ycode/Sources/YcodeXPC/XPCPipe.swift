import Foundation

// Pipe-routine envelopes and bootstrap routines (`bootstrap-wire.md` §2, §4).

public enum XPCPipe {
    /// Request `msgh_id` = `routineBit | routine` (§2.1).
    public static let routineBit: UInt32 = 0x4000_0000
    /// Reply `msgh_id` for every routine (§2.2).
    public static let replyID: UInt32 = 0x2000_0000
    /// One-way ("simpleroutine") `msgh_id`, no reply port (§2.1).
    public static let oneWayID: UInt32 = 0x1000_0000
    /// Mach header size; descriptor count adds 4 when complex.
    public static let headerSize = 24

    /// Whether `id` is a pipe request (routine or one-way).
    public static func isRequest(id: UInt32) -> Bool {
        id & routineBit != 0 || id & oneWayID != 0
    }
}

/// A pipe message as (id, descriptors, inline body). It maps one-to-one to
/// a Mach message: `COMPLEX` exactly when there are descriptors; the body
/// follows the descriptors.
public struct XPCPipeMessage: Equatable, Sendable {
    public var id: UInt32
    public var descriptors: [XPCWireDescriptor]
    public var body: [UInt8]

    public init(id: UInt32, descriptors: [XPCWireDescriptor] = [], body: [UInt8]) {
        self.id = id
        self.descriptors = descriptors
        self.body = body
    }

    public var isComplex: Bool { !descriptors.isEmpty }
    /// `msgh_id` as a signed value.
    public var msghID: Int32 { Int32(bitPattern: id) }

    /// `msgh_size`: header 24, plus 4 and the descriptors if complex
    /// (12 per port descriptor, 16 per other), plus the body.
    public var messageSize: Int {
        XPCPipe.headerSize + (isComplex ? 4 + descriptors.reduce(0) { $0 + $1.wireSize } : 0) + body.count
    }

    /// Encodes `dictionary` as a message with `id`.
    public static func encode(id: UInt32, _ dictionary: XPCDict) throws -> XPCPipeMessage {
        let e = try XPCWire.encode(.dictionary(dictionary))
        return XPCPipeMessage(id: id, descriptors: e.descriptors, body: e.body)
    }

    /// A routine request (`0x40000000 | routine`), as a client sends it.
    public static func request(routine: UInt32, _ dictionary: XPCDict) throws -> XPCPipeMessage {
        try encode(id: XPCPipe.routineBit | routine, dictionary)
    }

    /// A one-way message (`0x10000000`).
    public static func oneWay(_ dictionary: XPCDict) throws -> XPCPipeMessage {
        try encode(id: XPCPipe.oneWayID, dictionary)
    }

    /// Decodes the payload; the root must be a dictionary.
    public func decodeDictionary() throws -> XPCDict {
        guard case let .dictionary(d) = try XPCWire.decode(body: body, descriptors: descriptors) else {
            throw XPCWireError.rootNotDictionary
        }
        return d
    }
}

/// A decoded pipe request, as the bootstrap server receives it.
public struct XPCPipeRequest: Equatable, Sendable, CustomStringConvertible {
    public enum Failure: Error, Equatable, Sendable {
        /// The id is not a pipe request (neither `0x40000000` nor `0x10000000` set).
        case notPipeRequest(UInt32)
    }

    public var id: UInt32
    /// `id & ~0x40000000` for a routine; `id & ~0x10000000` for a one-way message.
    public var routine: UInt32
    public var isOneWay: Bool
    public var hasReplyPort: Bool
    public var dictionary: XPCDict

    /// Decodes a received pipe message. `body` is the inline bytes after
    /// the descriptors; `descriptors` are the received descriptors (names
    /// in the receiver's space, received types). Throws
    /// `XPCPipeRequest.Failure` or `XPCWireError`.
    public init(id: UInt32, body: [UInt8], descriptors: [XPCWireDescriptor], hasReplyPort: Bool) throws {
        if id & XPCPipe.routineBit != 0 {
            routine = id & ~XPCPipe.routineBit
            isOneWay = false
        } else if id & XPCPipe.oneWayID != 0 {
            routine = id & ~XPCPipe.oneWayID
            isOneWay = true
        } else {
            throw Failure.notPipeRequest(id)
        }
        self.id = id
        self.hasReplyPort = hasReplyPort
        dictionary = try XPCPipeMessage(id: id, descriptors: descriptors, body: body).decodeDictionary()
    }

    /// As above, with a signed `msgh_id`.
    public init(msghID: Int32, body: [UInt8], descriptors: [XPCWireDescriptor], hasReplyPort: Bool) throws {
        try self.init(id: UInt32(bitPattern: msghID), body: body, descriptors: descriptors, hasReplyPort: hasReplyPort)
    }

    public var knownRoutine: XPCBootstrapRoutine? { isOneWay ? nil : XPCBootstrapRoutine(rawValue: routine) }

    /// Every right in the request, depth-first (for releasing them).
    public var ports: [XPCPort] { XPCObject.dictionary(dictionary).ports }

    // Bootstrap keys (§4.1). Integers accept int64 or uint64.
    public var type: UInt64? { dictionary["type"]?.integerValue }
    public var handle: UInt64? { dictionary["handle"]?.integerValue }
    public var name: String? { dictionary["name"]?.stringValue }
    public var flags: UInt64? { dictionary["flags"]?.integerValue }
    public var targetPID: Int64? { dictionary["targetpid"]?.integerValue.map { Int64(bitPattern: $0) } }
    public var instance: UUID? { dictionary["instance"]?.uuidValue }
    public var lookupHandle: UInt64? { dictionary["lookup-handle"]?.integerValue }
    /// The `port` right (203, 204).
    public var port: XPCPort? { dictionary["port"]?.port }

    public var description: String {
        var s = isOneWay ? "pipe one-way" : "pipe \(routine)"
        if let r = knownRoutine { s += " (\(r.label))" }
        s += hasReplyPort ? "" : " no-reply-port"
        return s + " " + dictionary.description
    }
}

/// Reply builders (§2.2, §7): id `0x20000000`, the dictionary inline, rights
/// as descriptors (`COMPLEX` iff any).
public enum XPCPipeReply {
    /// Any reply dictionary.
    public static func dictionary(_ d: XPCDict) throws -> XPCPipeMessage {
        try XPCPipeMessage.encode(id: XPCPipe.replyID, d)
    }

    /// `{error: int64 code}`, not complex (`msgh_size` 64).
    public static func error(_ code: Int64) -> XPCPipeMessage {
        fixed(["error": .int64(code)])
    }

    /// `{key: send right}`, one port descriptor (`msgh_size` 72 for `port`).
    public static func sendRight(_ name: UInt32, disposition: UInt32 = XPCDisposition.makeSend,
                                 key: String = "port") -> XPCPipeMessage {
        fixed([key: .send(name, disposition: disposition)])
    }

    /// `{key: receive right}`, one port descriptor (`msgh_size` 72 for `port`).
    public static func receiveRight(_ name: UInt32, disposition: UInt32 = XPCDisposition.moveReceive,
                                    key: String = "port") -> XPCPipeMessage {
        fixed([key: .receive(name, disposition: disposition)])
    }

    /// The empty dictionary (byte length 4, count 0), not complex.
    public static func empty() -> XPCPipeMessage {
        fixed([:])
    }

    /// Encodes a dictionary that cannot fail (no data, keys from callers
    /// without NUL); a NUL in a caller's key falls back to `error` 22.
    static func fixed(_ d: XPCDict) -> XPCPipeMessage {
        if let m = try? dictionary(d) { return m }
        // swiftlint:disable:next force_try - a constant dictionary always encodes
        return XPCPipeMessage(id: XPCPipe.replyID, body: try! XPCWire.encodePayload(["error": .int64(22)]))
    }
}

/// Bootstrap routine numbers seen on the wire (§4.2).
public enum XPCBootstrapRoutine: UInt32, Sendable, CaseIterable {
    case parent = 203
    case register = 204
    case createService = 205
    case checkIn = 206
    case lookUp = 207
    /// `launchctl print <domain>/<label>` (pipe 708, not the MIG 708).
    case printService = 708
    /// First `xpc_connection_create` of a bundled service (pid-domain setup).
    case pidDomainSetup = 802
    /// Follows 802.
    case pidDomainSetupFollowUp = 803
    case serviceLookUp = 804
    case listenerCheckIn = 805
    /// `launchctl print <domain>`.
    case printDomain = 828

    public var label: String {
        switch self {
        case .parent: "parent"
        case .register: "register"
        case .createService: "create-service"
        case .checkIn: "check-in"
        case .lookUp: "look-up"
        case .printService: "print-service"
        case .pidDomainSetup: "pid-domain-setup"
        case .pidDomainSetupFollowUp: "pid-domain-setup-2"
        case .serviceLookUp: "xpc-look-up"
        case .listenerCheckIn: "xpc-listener-check-in"
        case .printDomain: "print-domain"
        }
    }

    /// 203–207: BOOTSTRAP error codes; the others: errno values (§4.3).
    public var isLegacy: Bool { rawValue < 300 }
}

/// Values of the `type` key (§4.1).
public enum XPCBootstrapDomain {
    public static let system: UInt64 = 1
    public static let user: UInt64 = 2
    public static let pid: UInt64 = 5
    public static let listener: UInt64 = 6
    /// The requester's own domain.
    public static let requester: UInt64 = 7
}

/// Error values for `{error}` replies (§4.2, §4.3).
public enum XPCBootstrapError {
    public static let notPrivileged: Int64 = 1100
    public static let nameInUse: Int64 = 1101
    public static let unknownService: Int64 = 1102
    public static let serviceActive: Int64 = 1103
    /// Seen for `bootstrap_create_service` (205); meaning not established.
    public static let createServiceFailed: Int64 = 126
    public static let eperm: Int64 = 1
    public static let esrch: Int64 = 3
    public static let ealready: Int64 = 37
    /// The catch-all error of `bootstrap-wire.md` §8.1 (Darwin `ENOTSUP`).
    public static let unsupported: Int64 = 45
}

/// The non-pipe startup exchange of `launchd_sim` (§5).
public enum XPCBootstrap {
    /// MIG-style request id, `msgh_size` 24, no body.
    public static let launchdSimServiceRequestID: Int32 = 708
    /// Reply id: complex, one port descriptor (`MOVE_RECEIVE`), `msgh_size` 40.
    public static let launchdSimServiceReplyID: Int32 = 808
}
