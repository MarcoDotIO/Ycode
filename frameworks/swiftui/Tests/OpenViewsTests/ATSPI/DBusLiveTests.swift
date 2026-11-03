import Foundation
import OVDBus
import OVPlatform
import Testing
@testable import OVAccessibilityATSPI
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// OV-ATSPI against a real message bus: a private `dbus-daemon` (the
// reference bus daemon, run as a separate program when it is installed;
// the tests are skipped otherwise, as on macOS). Our client connects,
// authenticates, calls, replies, signals and exports objects; then the
// exporter registers with a stand-in registry and answers a stand-in
// assistive technology, all over the bus.

/// A private bus daemon with an open policy.
final class PrivateBus {
    let process = Process()
    let address: String
    let directory: URL

    static var daemonPath: String? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/usr/bin"]
        return paths.map { $0 + "/dbus-daemon" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    init?() {
        guard let daemon = Self.daemonPath else { return nil }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ov-atspi-bus-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = """
        <!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
         "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
        <busconfig>
          <type>session</type>
          <listen>unix:dir=\(directory.path)</listen>
          <auth>EXTERNAL</auth>
          <policy context="default">
            <allow send_destination="*" eavesdrop="true"/>
            <allow eavesdrop="true"/>
            <allow own="*"/>
          </policy>
        </busconfig>
        """
        let configURL = directory.appendingPathComponent("bus.conf")
        guard (try? config.write(to: configURL, atomically: true, encoding: .utf8)) != nil else { return nil }
        let out = Pipe()
        process.executableURL = URL(fileURLWithPath: daemon)
        process.arguments = ["--config-file=\(configURL.path)", "--nofork", "--print-address=1"]
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        var line = Data()
        while !line.contains(UInt8(ascii: "\n")) {
            let d = out.fileHandleForReading.availableData
            if d.isEmpty { break }
            line += d
        }
        address = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if address.isEmpty { return nil }
    }

    deinit {
        // Not waitUntilExit: on Linux it waits for the main queue, which a
        // main-actor test holds.
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Progress on stderr with OV_ATSPI_TEST_TRACE=1 (diagnosing hangs).
func trace(_ s: String) {
    if ProcessInfo.processInfo.environment["OV_ATSPI_TEST_TRACE"] != nil {
        FileHandle.standardError.write(Data("[atspi-test] \(s)\n".utf8))
    }
}

/// Pumps every connection until `done` or 5 s.
@MainActor
func pumpAll(_ connections: [DBusConnection], until done: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !done() && Date() < deadline {
        for c in connections { c.pump(timeout: 0.002) }
    }
}

/// A method call from `from`, answered while all connections are pumped.
@MainActor
func roundTrip(_ from: DBusConnection, _ m: DBusMessage, _ all: [DBusConnection]) throws -> DBusMessage {
    var reply: DBusMessage?
    try from.call(m) { reply = $0 }
    pumpAll(all) { reply != nil }
    guard let r = reply else { throw DBusError.timeout(m.member ?? "") }
    if r.type == .error { throw DBusError.remote(name: r.errorName ?? "", message: r.errorMessage) }
    return r
}

/// A test object: `org.ycode.Test` with Echo, Fail and a Count property.
@MainActor
final class EchoObjects: DBusObjectTree {
    var count: Int32 = 3
    static let iface = DBusInterfaceDescription("org.ycode.Test", methods: [
        .method("Echo", in: ["v"], out: ["v"]), .method("Fail"),
    ], properties: [.init("Count", "i", .readwrite), .init("Name", "s")], signals: [.init("Changed", [.init("s")])])

    func interfaces(at path: String) -> [DBusInterfaceDescription]? { path == "/test" ? [Self.iface] : nil }
    func childNodes(at path: String) -> [String] { path == "/" ? ["test"] : [] }
    func handle(_ call: DBusMessage) -> DBusCallResult {
        switch (call.member, call.signature) {
        case ("Echo", "v"): return .reply(call.body)
        case ("Fail", ""): return .error(name: "org.ycode.Test.Error.Failed", message: "asked to fail")
        default: return .unknownMethod
        }
    }
    func property(_ name: String, interface: String, at path: String) -> DBusValue? {
        name == "Count" ? .int32(count) : name == "Name" ? .string("echo") : nil
    }
    func setProperty(_ name: String, interface: String, at path: String, to value: DBusValue) -> DBusCallResult {
        guard name == "Count", case .int32(let v) = value else { return .invalidArgs("Count") }
        count = v
        return .reply([])
    }
}

/// A stand-in for the AT-SPI registry: owns `org.a11y.atspi.Registry`,
/// answers Embed (setting the plug's Id first, as the real one does) and
/// GetRegisteredEvents.
@MainActor
final class StandInRegistry: DBusObjectTree {
    let connection: DBusConnection
    var plugs: [String] = []
    var events: [(String, String)] = []

    init(address: String) throws {
        connection = try DBusConnection.open(address: address)
        let r = try connection.call(.methodCall(destination: DBusConnection.busName, path: DBusConnection.busPath,
                                                interface: DBusConnection.busName, member: "RequestName",
                                                body: [.string(ATSPI.registryName), .uint32(4)]))
        #expect(r.body.first == .uint32(1)) // primary owner
        connection.objects = self
    }

    func interfaces(at path: String) -> [DBusInterfaceDescription]? {
        switch path {
        case ATSPI.registryRootPath: return [DBusInterfaceDescription(ATSPI.socket, methods: [.method("Embed", in: ["(so)"], out: ["(so)"])])]
        case ATSPI.registryPath: return [DBusInterfaceDescription(ATSPI.registryInterface, methods: [.method("GetRegisteredEvents", out: ["a(ss)"])])]
        default: return nil
        }
    }

    func handle(_ call: DBusMessage) -> DBusCallResult {
        switch call.member {
        case "Embed":
            guard let plug = call.body.first?.structValue, plug.count == 2, let name = plug[0].stringValue else {
                return .invalidArgs("plug")
            }
            plugs.append(name)
            try? connection.call(.methodCall(destination: name, path: plug[1].stringValue ?? "/",
                                             interface: "org.freedesktop.DBus.Properties", member: "Set",
                                             body: [.string(ATSPI.application), .string("Id"), .variant(.int32(7))])) { _ in }
            return .reply([.structure([.string(connection.uniqueName ?? ""), .objectPath(ATSPI.registryRootPath)])])
        case "GetRegisteredEvents":
            return .reply([.array(.structure([.string, .string]), events.map { .structure([.string($0.0), .string($0.1)]) })])
        default:
            return .unknownMethod
        }
    }

    func property(_ name: String, interface: String, at path: String) -> DBusValue? { nil }

    /// An AT registers a listener (the registry's signal).
    func register(_ bus: String, _ event: String) throws {
        events.append((bus, event))
        try connection.emit(path: ATSPI.registryPath, interface: ATSPI.registryInterface, member: "EventListenerRegistered",
                            body: [.string(bus), .string(event), .strings([])])
    }
}

@MainActor
@Suite("OV-ATSPI over a private bus", .serialized, .timeLimit(.minutes(1)))
struct DBusLiveTests {
    @Test func callsRepliesErrorsSignalsAndProperties() throws {
        trace("start")
        guard let bus = PrivateBus() else { return }
        trace("bus \(bus.address)")
        let a = try DBusConnection.open(address: bus.address)
        let b = try DBusConnection.open(address: bus.address)
        #expect(a.uniqueName?.hasPrefix(":") == true && a.uniqueName != b.uniqueName)
        #expect(!a.socket.serverGUID.isEmpty)
        let objects = EchoObjects()
        a.objects = objects
        let all = [a, b]
        func call(_ member: String, _ iface: String, _ body: [DBusValue] = [], path: String = "/test") throws -> DBusMessage {
            try roundTrip(b, .methodCall(destination: a.uniqueName, path: path, interface: iface, member: member, body: body), all)
        }
        trace("1 Echo a nested AT-SPI-shaped value, an")
        // Echo a nested AT-SPI-shaped value, and a large one (several reads).
        let item = DBusValue.variant(.structure([.structure([.string(":1.9"), .objectPath("/x")]), .int32(-1),
                                                 .strings(["a", "b"]), .array(.uint32, [.uint32(5), .uint32(0)])]))
        #expect(try call("Echo", "org.ycode.Test", [item]).body == [item])
        let big = DBusValue.variant(.string(String(repeating: "abcdefgh", count: 40_000)))
        #expect(try call("Echo", "org.ycode.Test", [big]).body == [big])
        trace("2 Errors.")
        // Errors.
        #expect(throws: DBusError.remote(name: "org.ycode.Test.Error.Failed", message: "asked to fail")) {
            try call("Fail", "org.ycode.Test")
        }
        #expect(throws: DBusError.self) { try call("Echo", "org.ycode.Test", [item], path: "/nothing") }
        #expect(throws: DBusError.self) { try call("Nope", "org.ycode.Test") }
        trace("3 Standard interfaces.")
        // Standard interfaces.
        #expect(try call("Ping", "org.freedesktop.DBus.Peer").body.isEmpty)
        let xml = try call("Introspect", "org.freedesktop.DBus.Introspectable").body.first?.stringValue ?? ""
        #expect(xml.contains("<interface name=\"org.ycode.Test\">") && xml.contains("<arg type=\"v\" direction=\"in\"/>"))
        #expect(xml.contains("<property name=\"Count\" type=\"i\" access=\"readwrite\"/>"))
        let root = try call("Introspect", "org.freedesktop.DBus.Introspectable", path: "/").body.first?.stringValue ?? ""
        #expect(root.contains("<node name=\"test\"/>"))
        let props = "org.freedesktop.DBus.Properties"
        #expect(try call("Get", props, [.string("org.ycode.Test"), .string("Count")]).body == [.variant(.int32(3))])
        _ = try call("Set", props, [.string("org.ycode.Test"), .string("Count"), .variant(.int32(9))])
        #expect(objects.count == 9)
        let allProps = try call("GetAll", props, [.string("org.ycode.Test")]).body.first?.dictionaryValue
        #expect(allProps?["Count"] == .variant(.int32(9)) && allProps?["Name"] == .variant(.string("echo")))
        #expect(throws: DBusError.self) { try call("Set", props, [.string("org.ycode.Test"), .string("Name"), .variant(.string("x"))]) }
        trace("4 Signals: b subscribes, a emits.")
        // Signals: b subscribes, a emits.
        var got: [DBusMessage] = []
        b.onSignal = { if $0.interface == "org.ycode.Test" { got.append($0) } }
        try b.addMatch("type='signal',interface='org.ycode.Test'")
        _ = try roundTrip(b, .methodCall(destination: DBusConnection.busName, path: DBusConnection.busPath,
                                         interface: "org.freedesktop.DBus.Peer", member: "Ping"), all)
        try a.emit(path: "/test", interface: "org.ycode.Test", member: "Changed", body: [.string("now")])
        pumpAll(all) { !got.isEmpty }
        #expect(got.first?.body == [.string("now")] && got.first?.sender == a.uniqueName)
        trace("5 A blocking call to the bus itself.")
        // A blocking call to the bus itself.
        let names = try b.call(.methodCall(destination: DBusConnection.busName, path: DBusConnection.busPath,
                                           interface: DBusConnection.busName, member: "ListNames"))
        #expect(names.body.first?.arrayValue?.contains(.string(a.uniqueName ?? "")) == true)
        a.close()
        #expect(!a.isConnected)
    }

    @Test func theExporterRegistersAndAnswersAnAssistiveTechnology() throws {
        trace("start")
        guard let bus = PrivateBus() else { return }
        trace("bus \(bus.address)")
        let registry = try StandInRegistry(address: bus.address)
        let at = try DBusConnection.open(address: bus.address)
        let h = CommandsHarness(menuBar: true) { ATSPIProbeView() }
        let export = AccessibilityExport(host: h.host)
        let app = try DBusConnection.open(address: bus.address)
        let exporter = ATSPIExporter(connection: app, provider: export)
        exporter.recordedEvents = []
        export.attach(exporter)
        h.host.accessibilityExport = export
        exporter.register()
        let all = [registry.connection, app, at]
        pumpAll(all) { exporter.isEmbedded && exporter.applicationID == 7 && exporter.listeners != nil }
        #expect(exporter.isEmbedded && exporter.applicationID == 7)
        #expect(registry.plugs == [app.uniqueName ?? ""])
        #expect(exporter.desktop?.name == registry.connection.uniqueName)
        trace("6 Nobody listens and nobody asked: fram")
        // Nobody listens and nobody asked: frames build nothing.
        h.run(until: h.now + 0.5)
        _ = export.performAction(0, on: "w1") // no such element yet: nothing happens
        h.run(until: h.now + 0.5)
        #expect(exporter.buildCount == 0)

        func call(_ path: String, _ iface: String, _ member: String, _ body: [DBusValue] = []) throws -> [DBusValue] {
            try roundTrip(at, .methodCall(destination: app.uniqueName, path: path, interface: iface, member: member, body: body), all).body
        }
        func prop(_ path: String, _ iface: String, _ name: String) throws -> DBusValue? {
            try call(path, "org.freedesktop.DBus.Properties", "Get", [.string(iface), .string(name)]).first?.variantValue
        }
        trace("7 The application root.")
        // The application root.
        #expect(try call(ATSPI.rootPath, ATSPI.accessible, "GetRole") == [.uint32(ATSPIRole.application.rawValue)])
        #expect(try prop(ATSPI.rootPath, ATSPI.accessible, "Name") == .string("Demo"))
        #expect(try prop(ATSPI.rootPath, ATSPI.application, "ToolkitName") == .string("OpenViews"))
        #expect(try prop(ATSPI.rootPath, ATSPI.application, "Id") == .int32(7))
        let windows = try call(ATSPI.rootPath, ATSPI.accessible, "GetChildren").first?.arrayValue ?? []
        #expect(windows.count == 1)
        let windowPath = windows.first?.structValue?[1].stringValue ?? ""
        #expect(windowPath == ATSPI.objectPrefix + "w1")
        trace("8 Walk the tree as an AT would: names a")
        // Walk the tree as an AT would: names and roles.
        var found: [String: String] = [:] // "role:name" → path
        func walk(_ path: String) throws {
            let role = try call(path, ATSPI.accessible, "GetRole").first?.intValue ?? -1
            let name = try prop(path, ATSPI.accessible, "Name")?.stringValue ?? ""
            found["\(role):\(name)"] = path
            for c in try call(path, ATSPI.accessible, "GetChildren").first?.arrayValue ?? [] {
                try walk(c.structValue?[1].stringValue ?? "")
            }
        }
        try walk(windowPath)
        #expect(exporter.buildCount == 1)
        let build = found["\(ATSPIRole.pushButton.rawValue):Build"]
        #expect(build != nil)
        #expect(found["\(ATSPIRole.menuBar.rawValue):"] != nil)
        #expect(found["\(ATSPIRole.treeItem.rawValue):Sources"] != nil)
        #expect(found["\(ATSPIRole.text.rawValue):"] != nil)
        let fieldPath = found["\(ATSPIRole.entry.rawValue):"] ?? ""
        trace("9 Interfaces, states, extents, introspe")
        // Interfaces, states, extents, introspection.
        let ifaces = try call(fieldPath, ATSPI.accessible, "GetInterfaces").first?.arrayValue ?? []
        #expect(ifaces.contains(.string(ATSPI.editableText)) && ifaces.contains(.string(ATSPI.component)))
        let state = ATSPIStateSet(words: (try call(fieldPath, ATSPI.accessible, "GetState").first?.arrayValue ?? []).compactMap {
            $0.intValue.map(UInt32.init)
        })
        #expect(state.contains(.editable) && state.contains(.focusable) && !state.contains(.focused))
        let ext = try call(fieldPath, ATSPI.component, "GetExtents", [.uint32(1)]).first?.structValue ?? []
        #expect(ext.count == 4 && (ext[2].intValue ?? 0) > 0)
        let xml = try call(fieldPath, "org.freedesktop.DBus.Introspectable", "Introspect").first?.stringValue ?? ""
        #expect(xml.contains("<interface name=\"org.a11y.atspi.Text\">"))
        #expect(try call(fieldPath, ATSPI.text, "GetText", [.int32(0), .int32(-1)]) == [.string("Ycode")])
        trace("10 The cache: the root and every object.")
        // The cache: the root and every object.
        let items = try call(ATSPI.cachePath, ATSPI.cache, "GetItems").first?.arrayValue ?? []
        #expect(items.count == 1 + exporter.snapshots.values.reduce(0) { $0 + $1.nodes.count })
        #expect(items.count >= found.count)

        trace("11 Actions over the bus.")
        // Actions over the bus.
        ATSPIProbeLog.shared.builds = 0
        #expect(try call(build ?? "", ATSPI.action, "GetName", [.int32(0)]) == [.string("click")])
        #expect(try call(build ?? "", ATSPI.action, "DoAction", [.int32(0)]) == [.boolean(true)])
        #expect(ATSPIProbeLog.shared.builds == 1)

        trace("12 An AT listens for focus: grabbing the")
        // An AT listens for focus: grabbing the field's focus sends
        trace("13 state-changed:focused and focus: to i")
        // state-changed:focused and focus: to it.
        var events: [DBusMessage] = []
        at.onSignal = { if $0.interface?.hasPrefix("org.a11y.atspi.Event") == true { events.append($0) } }
        try at.addMatch("type='signal',interface='org.a11y.atspi.Event.Object'")
        try at.addMatch("type='signal',interface='org.a11y.atspi.Event.Focus'")
        try registry.register(at.uniqueName ?? "", "object:state-changed:focused")
        try registry.register(at.uniqueName ?? "", "focus:")
        try registry.register(at.uniqueName ?? "", "object:text-changed")
        pumpAll(all) { exporter.wants("focus:") }
        h.run(until: h.now + 0.2) // a frame with listeners: the baseline
        #expect(try call(fieldPath, ATSPI.component, "GrabFocus") == [.boolean(true)])
        h.run(until: h.now + 0.2)
        pumpAll(all) { events.contains { $0.member == "Focus" } }
        let focus = events.first { $0.member == "StateChanged" && $0.body.first == .string("focused") && $0.body[1] == .int32(1) }
        #expect(focus?.path == fieldPath)
        #expect(events.contains { $0.member == "Focus" && $0.path == fieldPath })
        trace("14 Typing through EditableText sends tex")
        // Typing through EditableText sends text-changed:insert.
        #expect(try call(fieldPath, ATSPI.editableText, "InsertText", [.int32(5), .string(" IDE"), .int32(4)]) == [.boolean(true)])
        h.run(until: h.now + 0.2)
        pumpAll(all) { events.contains { $0.member == "TextChanged" } }
        let insert = events.first { $0.member == "TextChanged" }
        #expect(insert?.body.prefix(4) == [.string("insert"), .int32(5), .int32(4), .variant(.string(" IDE"))])
        trace("15 Events nobody asked for are not sent.")
        // Events nobody asked for are not sent.
        #expect(!(exporter.recordedEvents ?? []).contains { $0.hasPrefix("object:property-change") })
        trace("16 more listeners")
        // With every object and window event wanted: a toggle's state, a
        // slider's value, an outline folder's new children, the window's
        // activation.
        try at.addMatch("type='signal',interface='org.a11y.atspi.Event.Window'")
        try registry.register(at.uniqueName ?? "", "object:")
        try registry.register(at.uniqueName ?? "", "window:")
        pumpAll(all) { exporter.wants("window:activate") }
        events = []
        let toggle = found["\(ATSPIRole.toggleButton.rawValue):Wi-Fi"] ?? ""
        let slider = found["\(ATSPIRole.slider.rawValue):"] ?? ""
        let folder = found["\(ATSPIRole.treeItem.rawValue):Sources"] ?? ""
        let tree = found["\(ATSPIRole.tree.rawValue):"] ?? ""
        _ = try call(toggle, ATSPI.action, "DoAction", [.int32(0)])
        _ = try call(slider, "org.freedesktop.DBus.Properties", "Set",
                     [.string(ATSPI.value), .string("CurrentValue"), .variant(.double(0.9))])
        _ = try call(folder, ATSPI.action, "DoAction", [.int32(1)])
        h.run(until: h.now + 0.5)
        h.backend.post(.window(h.windowID, .focusLost))
        h.run(until: h.now + 0.2)
        h.backend.post(.window(h.windowID, .focusGained))
        h.run(until: h.now + 0.2)
        pumpAll(all) { events.contains { $0.member == "Activate" } }
        func saw(_ member: String, _ path: String, _ detail: String, _ d1: Int32? = nil) -> Bool {
            events.contains { $0.member == member && $0.path == path && $0.body.first == .string(detail) && (d1 == nil || $0.body[1] == .int32(d1!)) }
        }
        #expect(saw("StateChanged", toggle, "checked", 0))
        #expect(saw("PropertyChange", slider, "accessible-value"))
        #expect(events.first { $0.member == "PropertyChange" && $0.path == slider }?.body[3] == .variant(.double(0.9)))
        #expect(saw("StateChanged", folder, "expanded", 1))
        #expect(saw("ChildrenChanged", tree, "add"))
        #expect(saw("StateChanged", windowPath, "active", 0) && saw("StateChanged", windowPath, "active", 1))
        #expect(events.contains { $0.member == "Deactivate" && $0.path == windowPath })
        #expect(events.contains { $0.member == "Activate" && $0.path == windowPath })
        exporter.stop()
        at.close()
        registry.connection.close()
    }
}
