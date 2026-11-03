import Foundation

// A connection to a message bus (D-Bus Specification 0.43, "Message Bus
// Specification"): after authentication the client sends `Hello` to
// `org.freedesktop.DBus` and gets its unique name; method calls get a
// method return or an error with REPLY_SERIAL; signals are broadcast or
// sent to a destination; `AddMatch` subscribes to broadcast signals.
//
// Objects are exported through a `DBusObjectTree`: the connection routes a
// method call by path, and answers the standard interfaces itself —
// `org.freedesktop.DBus.Peer` (Ping, GetMachineId),
// `org.freedesktop.DBus.Introspectable` (Introspect, from the tree's
// interface descriptions) and `org.freedesktop.DBus.Properties` (Get,
// GetAll, Set).
//
// Everything runs on the main actor: incoming data is read when the
// socket is readable (a dispatch source on the main queue, or `pump` in
// tests and while a blocking call waits; calls that arrive meanwhile are
// answered then, so a peer may call back while we wait for its reply).

/// The interfaces, methods, properties and signals of one exported object
/// (for introspection and `GetAll`).
public struct DBusInterfaceDescription: Sendable, Equatable {
    public struct Argument: Sendable, Equatable {
        public var name: String?
        public var type: String
        public init(_ type: String, _ name: String? = nil) {
            self.type = type
            self.name = name
        }
    }

    public struct Method: Sendable, Equatable {
        public var name: String
        public var arguments: [Argument]
        public var results: [Argument]
        public init(_ name: String, _ arguments: [Argument] = [], _ results: [Argument] = []) {
            self.name = name
            self.arguments = arguments
            self.results = results
        }
    }

    public struct Property: Sendable, Equatable {
        public enum Access: String, Sendable { case read, write, readwrite }
        public var name: String
        public var type: String
        public var access: Access
        public init(_ name: String, _ type: String, _ access: Access = .read) {
            self.name = name
            self.type = type
            self.access = access
        }
    }

    public struct Signal: Sendable, Equatable {
        public var name: String
        public var arguments: [Argument]
        public init(_ name: String, _ arguments: [Argument] = []) {
            self.name = name
            self.arguments = arguments
        }
    }

    public var name: String
    public var methods: [Method]
    public var properties: [Property]
    public var signals: [Signal]

    public init(_ name: String, methods: [Method] = [], properties: [Property] = [], signals: [Signal] = []) {
        self.name = name
        self.methods = methods
        self.properties = properties
        self.signals = signals
    }

    /// The method `name`, if the interface has it.
    public func method(_ name: String) -> Method? { methods.first { $0.name == name } }

}

extension DBusInterfaceDescription.Method {
    /// A method with unnamed arguments and results given as signatures.
    public static func method(_ name: String, in arguments: [String] = [], out results: [String] = []) -> Self {
        Self(name, arguments.map { .init($0) }, results.map { .init($0) })
    }
}

/// The outcome of a method call on an exported object.
public enum DBusCallResult: Equatable, Sendable {
    case reply([DBusValue])
    case error(name: String, message: String)
    /// No such method: the connection answers UnknownMethod.
    case unknownMethod

    public static func invalidArgs(_ message: String) -> DBusCallResult {
        .error(name: DBusErrorName.invalidArgs, message: message)
    }
}

/// Standard error names.
public enum DBusErrorName {
    public static let failed = "org.freedesktop.DBus.Error.Failed"
    public static let unknownMethod = "org.freedesktop.DBus.Error.UnknownMethod"
    public static let unknownObject = "org.freedesktop.DBus.Error.UnknownObject"
    public static let unknownInterface = "org.freedesktop.DBus.Error.UnknownInterface"
    public static let unknownProperty = "org.freedesktop.DBus.Error.UnknownProperty"
    public static let propertyReadOnly = "org.freedesktop.DBus.Error.PropertyReadOnly"
    public static let invalidArgs = "org.freedesktop.DBus.Error.InvalidArgs"
}

/// Objects a connection exports.
@MainActor
public protocol DBusObjectTree: AnyObject {
    /// The interfaces of the object at `path` (without the standard
    /// ones), or nil when there is no object there.
    func interfaces(at path: String) -> [DBusInterfaceDescription]?
    /// Names of the child nodes of `path` (introspection).
    func childNodes(at path: String) -> [String]
    /// Runs a method call of one of the object's interfaces.
    func handle(_ call: DBusMessage) -> DBusCallResult
    /// The value of a property (nil: no such property).
    func property(_ name: String, interface: String, at path: String) -> DBusValue?
    /// Sets a writable property.
    func setProperty(_ name: String, interface: String, at path: String, to value: DBusValue) -> DBusCallResult
}

extension DBusObjectTree {
    public func childNodes(at path: String) -> [String] { [] }
    public func setProperty(_ name: String, interface: String, at path: String, to value: DBusValue) -> DBusCallResult {
        .error(name: DBusErrorName.propertyReadOnly, message: "\(interface).\(name) is read-only")
    }
}

/// A connection to a bus.
@MainActor
public final class DBusConnection {
    public let socket: DBusSocket
    /// Our unique name (`:1.42`), after `Hello`.
    public private(set) var uniqueName: String?
    public var objects: (any DBusObjectTree)?
    /// Called for every signal received.
    public var onSignal: ((DBusMessage) -> Void)?
    /// Called once when the peer closes the connection.
    public var onDisconnect: (() -> Void)?
    public private(set) var isConnected = true
    /// Messages sent and received (statistics for tests).
    public private(set) var sentCount = 0
    public private(set) var receivedCount = 0

    private var nextSerial: UInt32 = 1
    private var input: [UInt8] = []
    private var replyHandlers: [UInt32: (DBusMessage) -> Void] = [:]
    private var arrivedReplies: [UInt32: DBusMessage] = [:]
    private var waitingFor: Set<UInt32> = []
    private var source: (any DispatchSourceRead)?
    private var dispatching = false

    public static let busName = "org.freedesktop.DBus"
    public static let busPath = "/org/freedesktop/DBus"

    init(socket: DBusSocket) { self.socket = socket }

    /// Connects, authenticates and registers with the bus (`Hello`).
    public static func open(address: String, timeout: Double = 5) throws -> DBusConnection {
        let c = DBusConnection(socket: try DBusSocket.connect(address: address, timeout: timeout))
        let reply = try c.call(.methodCall(destination: busName, path: busPath, interface: busName, member: "Hello"),
                               timeout: timeout)
        c.uniqueName = reply.body.first?.stringValue
        return c
    }

    /// Connects to the session bus (`DBUS_SESSION_BUS_ADDRESS`).
    public static func session(timeout: Double = 5) throws -> DBusConnection {
        guard let a = ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"], !a.isEmpty else {
            throw DBusError.noAddress("DBUS_SESSION_BUS_ADDRESS is not set")
        }
        return try open(address: a, timeout: timeout)
    }

    public func close() {
        source?.cancel()
        source = nil
        socket.close()
        if isConnected {
            isConnected = false
            onDisconnect?()
        }
    }

    // MARK: Sending

    /// Sends a message and returns its serial.
    @discardableResult
    public func send(_ message: DBusMessage) throws -> UInt32 {
        guard isConnected else { throw DBusError.disconnected }
        var m = message
        m.serial = nextSerial
        nextSerial = nextSerial == UInt32.max ? 1 : nextSerial + 1
        let bytes = try m.encoded()
        do {
            try socket.write(bytes)
        } catch {
            close()
            throw error
        }
        sentCount += 1
        return m.serial
    }

    /// Sends a method call; `reply` gets the return or the error message.
    public func call(_ message: DBusMessage, reply: @escaping (DBusMessage) -> Void) throws {
        let serial = try send(message)
        replyHandlers[serial] = reply
    }

    /// Sends a method call and waits for its reply, answering incoming
    /// calls meanwhile. Throws `.remote` for an error reply.
    @discardableResult
    public func call(_ message: DBusMessage, timeout: Double = 5) throws -> DBusMessage {
        let serial = try send(message)
        waitingFor.insert(serial)
        defer { waitingFor.remove(serial) }
        let deadline = Date().addingTimeInterval(timeout)
        while arrivedReplies[serial] == nil {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else {
                throw DBusError.timeout("\(message.interface ?? "").\(message.member ?? "")")
            }
            guard isConnected else { throw DBusError.disconnected }
            _ = pump(timeout: left)
        }
        let r = arrivedReplies.removeValue(forKey: serial)!
        if r.type == .error { throw DBusError.remote(name: r.errorName ?? "", message: r.errorMessage) }
        return r
    }

    /// Emits a signal from `path`.
    public func emit(path: String, interface: String, member: String, body: [DBusValue] = [],
                     destination: String? = nil) throws {
        try send(.signal(path: path, interface: interface, member: member, body: body, destination: destination))
    }

    /// Subscribes to broadcast signals matching `rule` (no reply awaited).
    public func addMatch(_ rule: String) throws {
        try call(.methodCall(destination: Self.busName, path: Self.busPath, interface: Self.busName, member: "AddMatch",
                             body: [.string(rule)])) { _ in }
    }

    // MARK: Receiving

    /// Reads incoming data on `queue` (the main queue) as it arrives.
    public func startDispatch(queue: DispatchQueue = .main) {
        guard source == nil, socket.fd >= 0 else { return }
        let s = DispatchSource.makeReadSource(fileDescriptor: socket.fd, queue: queue)
        s.setEventHandler { [weak self] in
            MainActor.assumeIsolated { _ = self?.pump(timeout: 0) }
        }
        s.resume()
        source = s
    }

    /// Reads and dispatches what arrives within `timeout` seconds (at least
    /// one read when data is there). Returns true if a message was handled.
    @discardableResult
    public func pump(timeout: Double) -> Bool {
        guard isConnected else { return false }
        var handled = false
        if socket.waitReadable(timeout: timeout) {
            do {
                if let data = try socket.readAvailable() {
                    if data.isEmpty {
                        close()
                        return handled
                    }
                    input += data
                }
            } catch {
                close()
                return handled
            }
        }
        while let m = nextMessage() {
            handled = true
            dispatch(m)
        }
        return handled
    }

    private func nextMessage() -> DBusMessage? {
        do {
            guard let n = try DBusMessage.frameLength(input[...]), input.count >= n else { return nil }
            let bytes = Array(input[0..<n])
            input.removeFirst(n)
            receivedCount += 1
            return try DBusMessage.decode(bytes)
        } catch {
            // A corrupt stream cannot be resynchronised.
            close()
            return nil
        }
    }

    private func dispatch(_ m: DBusMessage) {
        switch m.type {
        case .methodReturn, .error:
            guard let r = m.replySerial else { return }
            if waitingFor.contains(r) {
                arrivedReplies[r] = m
            } else if let h = replyHandlers.removeValue(forKey: r) {
                h(m)
            }
        case .signal:
            onSignal?(m)
        case .methodCall:
            let result = answer(m)
            guard !m.flags.contains(.noReplyExpected) else { return }
            let reply: DBusMessage
            switch result {
            case .reply(let body): reply = .reply(to: m, body: body)
            case .error(let name, let message): reply = .error(to: m, name: name, message: message)
            case .unknownMethod:
                reply = .error(to: m, name: DBusErrorName.unknownMethod,
                               message: "no method \(m.interface ?? "").\(m.member ?? "") (\(m.signature)) at \(m.path ?? "")")
            }
            do {
                try send(reply)
            } catch {
                // An unencodable reply becomes an error reply.
                _ = try? send(.error(to: m, name: DBusErrorName.failed, message: "\(error)"))
            }
        }
    }

    // MARK: Exported objects

    private func answer(_ m: DBusMessage) -> DBusCallResult {
        let path = m.path ?? "/"
        let member = m.member ?? ""
        switch m.interface {
        case "org.freedesktop.DBus.Peer":
            if member == "Ping" { return .reply([]) }
            if member == "GetMachineId" { return .reply([.string(Self.machineID())]) }
            return .unknownMethod
        case "org.freedesktop.DBus.Introspectable":
            guard member == "Introspect" else { return .unknownMethod }
            return .reply([.string(introspect(path))])
        default: break
        }
        guard let tree = objects, let interfaces = tree.interfaces(at: path) else {
            if m.interface == nil && member == "Introspect" { return .reply([.string(introspect(path))]) }
            return .error(name: DBusErrorName.unknownObject, message: "no object at \(path)")
        }
        if m.interface == "org.freedesktop.DBus.Properties" {
            return properties(m, path: path, interfaces: interfaces, tree: tree)
        }
        if m.interface == nil && member == "Introspect" { return .reply([.string(introspect(path))]) }
        if let i = m.interface, !interfaces.contains(where: { $0.name == i }) {
            return .error(name: DBusErrorName.unknownInterface, message: "\(path) has no interface \(i)")
        }
        return tree.handle(m)
    }

    private func properties(_ m: DBusMessage, path: String, interfaces: [DBusInterfaceDescription],
                            tree: any DBusObjectTree) -> DBusCallResult {
        let args = m.body
        func describe(_ i: String) -> DBusInterfaceDescription? { interfaces.first { $0.name == i } }
        switch (m.member, m.signature) {
        case ("Get", "ss"):
            let i = args[0].stringValue ?? "", n = args[1].stringValue ?? ""
            guard describe(i) != nil else { return .error(name: DBusErrorName.unknownInterface, message: "no interface \(i)") }
            guard let v = tree.property(n, interface: i, at: path) else {
                return .error(name: DBusErrorName.unknownProperty, message: "no property \(i).\(n)")
            }
            return .reply([.variant(v)])
        case ("GetAll", "s"):
            let i = args[0].stringValue ?? ""
            // An empty interface name (or one without properties) gives an
            // empty dictionary.
            let names = describe(i)?.properties.map(\.name) ?? []
            var entries: [(DBusValue, DBusValue)] = []
            for n in names {
                if let v = tree.property(n, interface: i, at: path) { entries.append((.string(n), .variant(v))) }
            }
            return .reply([.dictionary(key: .string, value: .variant, entries)])
        case ("Set", "ssv"):
            let i = args[0].stringValue ?? "", n = args[1].stringValue ?? ""
            guard let p = describe(i)?.properties.first(where: { $0.name == n }) else {
                return .error(name: DBusErrorName.unknownProperty, message: "no property \(i).\(n)")
            }
            guard p.access != .read else { return .error(name: DBusErrorName.propertyReadOnly, message: "\(i).\(n) is read-only") }
            guard let v = args[2].variantValue, v.signature == p.type else {
                return .invalidArgs("\(i).\(n) has type \(p.type)")
            }
            return tree.setProperty(n, interface: i, at: path, to: v)
        default:
            return .unknownMethod
        }
    }

    /// The introspection XML of `path` ("Introspection Data Format").
    public func introspect(_ path: String) -> String {
        var x = "<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\"\n"
        x += " \"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">\n<node>\n"
        if let interfaces = objects?.interfaces(at: path) {
            for i in Self.standardInterfaces + interfaces { x += Self.xml(i) }
        }
        for c in objects?.childNodes(at: path) ?? [] { x += "  <node name=\"\(Self.escapeXML(c))\"/>\n" }
        return x + "</node>\n"
    }

    public static let standardInterfaces: [DBusInterfaceDescription] = [
        DBusInterfaceDescription("org.freedesktop.DBus.Peer", methods: [
            .method("Ping"), .method("GetMachineId", out: ["s"]),
        ]),
        DBusInterfaceDescription("org.freedesktop.DBus.Introspectable", methods: [.method("Introspect", out: ["s"])]),
        DBusInterfaceDescription("org.freedesktop.DBus.Properties", methods: [
            .method("Get", in: ["s", "s"], out: ["v"]), .method("GetAll", in: ["s"], out: ["a{sv}"]),
            .method("Set", in: ["s", "s", "v"]),
        ], signals: [.init("PropertiesChanged", [.init("s"), .init("a{sv}"), .init("as")])]),
    ]

    static func xml(_ i: DBusInterfaceDescription) -> String {
        func arg(_ a: DBusInterfaceDescription.Argument, _ direction: String?) -> String {
            var s = "      <arg"
            if let n = a.name { s += " name=\"\(escapeXML(n))\"" }
            s += " type=\"\(escapeXML(a.type))\""
            if let direction { s += " direction=\"\(direction)\"" }
            return s + "/>\n"
        }
        var x = "  <interface name=\"\(i.name)\">\n"
        for m in i.methods {
            x += "    <method name=\"\(m.name)\">\n"
            for a in m.arguments { x += arg(a, "in") }
            for a in m.results { x += arg(a, "out") }
            x += "    </method>\n"
        }
        for s in i.signals {
            x += "    <signal name=\"\(s.name)\">\n"
            for a in s.arguments { x += arg(a, nil) }
            x += "    </signal>\n"
        }
        for p in i.properties {
            x += "    <property name=\"\(p.name)\" type=\"\(escapeXML(p.type))\" access=\"\(p.access.rawValue)\"/>\n"
        }
        return x + "  </interface>\n"
    }

    static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The machine ID (`/etc/machine-id`), or a fixed one.
    static func machineID() -> String {
        for p in ["/etc/machine-id", "/var/lib/dbus/machine-id"] {
            if let s = try? String(contentsOfFile: p, encoding: .utf8) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count == 32 { return t }
            }
        }
        return String(repeating: "0", count: 32)
    }
}
