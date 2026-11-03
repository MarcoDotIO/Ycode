import Foundation
import OVDBus

// The AT-SPI2 exporter: exports an application's accessible objects on the
// accessibility bus (at-spi2-core `xml/*.xml`, public interface
// descriptions; Ycode's own implementation).
//
// - **Bus.** `AT_SPI_BUS_ADDRESS`, else `org.a11y.Bus.GetAddress` on the
//   session bus (the bus launcher); no bus, no export.
// - **Registration.** `org.a11y.atspi.Socket.Embed((so))` on the registry's
//   root with our unique name and `/org/a11y/atspi/accessible/root`; the
//   registry sets our `Application.Id` while the call runs (answered,
//   because replies are awaited asynchronously) and returns the desktop.
// - **Objects.** The application root (role application, children = the
//   windows), one object per accessible node at
//   `/org/a11y/atspi/accessible/<key>` with Accessible and Component, and
//   Action, Text (+ EditableText), Value and Selection when the node has
//   them; the Cache at `/org/a11y/atspi/cache` (`GetItems`,
//   `AddAccessible`, `RemoveAccessible`).
// - **Laziness.** No window's tree is built until a client asks for one of
//   its objects. While no assistive technology has registered an event
//   listener with the registry (`GetRegisteredEvents`,
//   `EventListenerRegistered`/`Deregistered`), nothing is rebuilt after
//   frames; with listeners, windows whose revision changed are rebuilt
//   after each frame and the difference is sent as events.
// - **Events** (`org.a11y.atspi.Event.*`, body `(siiva{sv})`): focus
//   (`Event.Focus.Focus` and `state-changed:focused`), state changes,
//   name/description/value property changes, children added and removed,
//   text inserted and deleted, caret moves, window activate/deactivate,
//   create and destroy. Only events a listener asked for are sent.

@MainActor
public final class ATSPIExporter: DBusObjectTree {
    public let connection: DBusConnection
    public weak var provider: (any ATSPIProvider)?
    /// The id the registry gave the application (`Application.Id`).
    public private(set) var applicationID: Int32 = 0
    /// The registry's desktop (the reply to Embed).
    public private(set) var desktop: (name: String, path: String)?
    public private(set) var isEmbedded = false
    /// Snapshots made so far (windows a client asked for or that are kept
    /// current for listeners).
    public private(set) var snapshots: [String: ATSPIWindowSnapshot] = [:]
    /// Snapshot builds (statistics: laziness tests).
    public private(set) var buildCount = 0
    /// Event listeners by the AT's bus name; nil until the registry told us.
    public private(set) var listeners: [String: [String]]?
    /// Every event sent, as `object:state-changed:focused <key>` (tests).
    public var recordedEvents: [String]?
    public var log: ((String) -> Void)?

    private var knownWindows: [String]?

    public init(connection: DBusConnection, provider: any ATSPIProvider) {
        self.connection = connection
        self.provider = provider
    }

    // MARK: Connecting

    /// The accessibility bus address: `AT_SPI_BUS_ADDRESS`, else asked of
    /// the bus launcher on the session bus. Nil when there is none.
    public static func accessibilityBusAddress(environment: [String: String] = ProcessInfo.processInfo.environment,
                                               timeout: Double = 3) -> String? {
        if let a = environment["AT_SPI_BUS_ADDRESS"], !a.isEmpty { return a }
        guard let s = environment["DBUS_SESSION_BUS_ADDRESS"], !s.isEmpty,
              let session = try? DBusConnection.open(address: s, timeout: timeout) else { return nil }
        defer { session.close() }
        let call = DBusMessage.methodCall(destination: ATSPI.busLauncherName, path: ATSPI.busLauncherPath,
                                          interface: ATSPI.busLauncherName, member: "GetAddress")
        guard let reply = try? session.call(call, timeout: timeout), let a = reply.body.first?.stringValue, !a.isEmpty else {
            return nil
        }
        return a
    }

    /// Connects to the accessibility bus, exports the root and registers
    /// with the registry. Nil when there is no accessibility bus.
    public static func start(provider: any ATSPIProvider,
                             environment: [String: String] = ProcessInfo.processInfo.environment) -> ATSPIExporter? {
        guard let address = accessibilityBusAddress(environment: environment),
              let c = try? DBusConnection.open(address: address) else { return nil }
        let e = ATSPIExporter(connection: c, provider: provider)
        e.register()
        c.startDispatch()
        return e
    }

    /// Exports the objects, subscribes to the registry's listener signals
    /// and embeds the application (replies arrive asynchronously).
    public func register() {
        connection.objects = self
        connection.onSignal = { [weak self] in self?.received($0) }
        do {
            try connection.addMatch("type='signal',interface='\(ATSPI.registryInterface)',member='EventListenerRegistered'")
            try connection.addMatch("type='signal',interface='\(ATSPI.registryInterface)',member='EventListenerDeregistered'")
            try connection.addMatch("type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged'")
            try connection.call(.methodCall(destination: ATSPI.registryName, path: ATSPI.registryPath,
                                            interface: ATSPI.registryInterface, member: "GetRegisteredEvents")) { [weak self] r in
                guard let self, r.type == .methodReturn else { return }
                var l: [String: [String]] = [:]
                for case .structure(let f) in r.body.first?.arrayValue ?? [] where f.count == 2 {
                    l[f[0].stringValue ?? "", default: []].append(f[1].stringValue ?? "")
                }
                self.listeners = l
                self.log?("registered events: \(l.values.flatMap { $0 }.sorted())")
            }
            let plug = DBusValue.structure([.string(connection.uniqueName ?? ""), .objectPath(ATSPI.rootPath)])
            try connection.call(.methodCall(destination: ATSPI.registryName, path: ATSPI.registryRootPath,
                                            interface: ATSPI.socket, member: "Embed", body: [plug])) { [weak self] r in
                guard let self else { return }
                if r.type == .methodReturn, let f = r.body.first?.structValue, f.count == 2 {
                    self.desktop = (f[0].stringValue ?? "", f[1].stringValue ?? "")
                    self.isEmbedded = true
                    self.log?("embedded; desktop \(f[0].stringValue ?? "") id \(self.applicationID)")
                } else {
                    self.log?("Embed failed: \(r.errorName ?? "") \(r.errorMessage)")
                }
            }
        } catch {
            log?("registration failed: \(error)")
        }
    }

    public func stop() {
        connection.close()
        snapshots = [:]
    }

    private func received(_ m: DBusMessage) {
        switch (m.interface, m.member) {
        case (ATSPI.registryInterface, "EventListenerRegistered"):
            guard m.body.count >= 2, let bus = m.body[0].stringValue, let event = m.body[1].stringValue else { return }
            var l = listeners ?? [:]
            l[bus, default: []].append(event)
            listeners = l
            log?("listener \(bus) \(event)")
            // The state the next changes are measured against.
            afterFrame()
        case (ATSPI.registryInterface, "EventListenerDeregistered"):
            guard m.body.count >= 2, let bus = m.body[0].stringValue, let event = m.body[1].stringValue else { return }
            if let i = listeners?[bus]?.firstIndex(of: event) { listeners?[bus]?.remove(at: i) }
            if listeners?[bus]?.isEmpty == true { listeners?[bus] = nil }
        case ("org.freedesktop.DBus", "NameOwnerChanged"):
            // An AT that left the bus listens no more.
            guard m.body.count == 3, let name = m.body[0].stringValue, m.body[2].stringValue?.isEmpty == true else { return }
            listeners?[name] = nil
        default: break
        }
    }

    // MARK: Listening

    /// True while some AT listens for events (or the registry did not say).
    public var hasListeners: Bool { listeners.map { !$0.isEmpty } ?? true }

    /// True if a registered listener covers `event` (`class:major:minor`).
    public func wants(_ event: String) -> Bool {
        guard let listeners else { return true }
        let e = Self.components(event)
        for l in listeners.values.joined() {
            let c = Self.components(l)
            if c.count <= e.count && zip(c, e).allSatisfy({ $0 == $1 }) { return true }
        }
        return false
    }

    static func components(_ s: String) -> [String] {
        s.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
            .split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            .reversed().drop { $0.isEmpty }.reversed()
    }

    // MARK: Keeping current

    /// After a frame: with listeners, rebuild the windows whose revision
    /// changed and send the differences; without, nothing.
    public func afterFrame() {
        guard connection.isConnected, let provider, hasListeners else { return }
        syncWindowList(provider.windowKeys())
        for w in provider.windowKeys() {
            if snapshots[w] == nil {
                materialize(w)
            } else if provider.revision(ofWindow: w) != snapshots[w]?.revision {
                refresh(w)
            }
        }
    }

    /// The snapshot of window `w`, made now or brought up to date.
    @discardableResult
    func current(_ w: String) -> ATSPIWindowSnapshot? {
        guard let provider else { return nil }
        if snapshots[w] == nil {
            guard provider.windowKeys().contains(w) else { return nil }
            materialize(w)
        } else if provider.revision(ofWindow: w) != snapshots[w]?.revision {
            refresh(w)
        }
        return snapshots[w]
    }

    private func materialize(_ w: String) {
        guard let s = provider?.snapshot(ofWindow: w) else { return }
        buildCount += 1
        snapshots[w] = s
        if knownWindows == nil { knownWindows = provider?.windowKeys() }
    }

    private func refresh(_ w: String) {
        guard let old = snapshots[w] else { return materialize(w) }
        guard let new = provider?.snapshot(ofWindow: w) else {
            snapshots[w] = nil
            return
        }
        buildCount += 1
        snapshots[w] = new
        diff(old, new)
    }

    private func syncWindowList(_ now: [String]) {
        guard let before = knownWindows else {
            knownWindows = now
            return
        }
        guard before != now else { return }
        knownWindows = now
        for (i, w) in before.enumerated() where !now.contains(w) {
            if let s = snapshots.removeValue(forKey: w) {
                for k in s.orderedKeys { emitCache("RemoveAccessible", ref(k)) }
            }
            emitObject(nil, "ChildrenChanged", "remove", Int32(i), 0, ref(w))
            emitWindow(w, "Destroy")
        }
        for (i, w) in now.enumerated() where !before.contains(w) {
            emitObject(nil, "ChildrenChanged", "add", Int32(i), 0, ref(w))
            emitWindow(w, "Create")
            if hasListeners, current(w) != nil, let s = snapshots[w] {
                for k in s.orderedKeys { if let item = cacheItem(k) { emitCache("AddAccessible", item) } }
            }
        }
    }

    /// Sends the events for the change from `old` to `new`.
    private func diff(_ old: ATSPIWindowSnapshot, _ new: ATSPIWindowSnapshot) {
        let removed = old.orderedKeys.filter { new.nodes[$0] == nil }
        let added = new.orderedKeys.filter { old.nodes[$0] == nil }
        let removedSet = Set(removed), addedSet = Set(added)
        for k in removed {
            emitCache("RemoveAccessible", ref(k))
            if let n = old.nodes[k], let p = n.parent, !removedSet.contains(p), new.nodes[p] != nil {
                emitObject(p, "ChildrenChanged", "remove", Int32(n.indexInParent), 0, ref(k))
            }
        }
        for k in added {
            if let item = cacheItem(k) { emitCache("AddAccessible", item) }
            if let n = new.nodes[k], let p = n.parent, !addedSet.contains(p) {
                emitObject(p, "ChildrenChanged", "add", Int32(n.indexInParent), 0, ref(k))
            }
        }
        // Focus is reported lost before it is reported gained.
        var gained: [String] = []
        for k in new.orderedKeys {
            guard let a = old.nodes[k], let b = new.nodes[k] else { continue }
            if a.name != b.name { emitObject(k, "PropertyChange", "accessible-name", 0, 0, .string(b.name)) }
            if a.description != b.description {
                emitObject(k, "PropertyChange", "accessible-description", 0, 0, .string(b.description))
            }
            if a.role != b.role { emitObject(k, "PropertyChange", "accessible-role", 0, 0, .uint32(b.role.rawValue)) }
            if let v = b.value, a.value?.current != v.current {
                emitObject(k, "PropertyChange", "accessible-value", 0, 0, .double(v.current))
            }
            if a.states != b.states {
                for s in ATSPIState.allCases where a.states.contains(s) != b.states.contains(s) {
                    let on = b.states.contains(s)
                    if s == .focused && on {
                        gained.append(k)
                        continue
                    }
                    emitObject(k, "StateChanged", s.eventName, on ? 1 : 0, 0, .int32(0))
                    if s == .active && k == new.rootKey { emitWindow(k, on ? "Activate" : "Deactivate") }
                }
            }
            if let ta = a.text, let tb = b.text {
                if ta.string != tb.string { textChanged(k, ta.scalars, tb.scalars) }
                if ta.caret != tb.caret { emitObject(k, "TextCaretMoved", "", Int32(tb.caret), 0, .int32(0)) }
            }
        }
        for k in added where new.nodes[k]?.states.contains(.focused) == true { gained.append(k) }
        for k in gained { focusGained(k) }
    }

    private func focusGained(_ k: String) {
        emitObject(k, "StateChanged", ATSPIState.focused.eventName, 1, 0, .int32(0))
        if wants("focus:") {
            send(path(k), ATSPI.eventFocus, "Focus", event: "focus:", key: k,
                 body: Self.eventBody("", 0, 0, .int32(0)))
        }
    }

    private func textChanged(_ k: String, _ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) {
        var prefix = 0
        while prefix < a.count && prefix < b.count && a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix && suffix < b.count - prefix && a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        let deleted = a[prefix..<(a.count - suffix)], inserted = b[prefix..<(b.count - suffix)]
        if !deleted.isEmpty {
            emitObject(k, "TextChanged", "delete", Int32(prefix), Int32(deleted.count), .string(Self.string(deleted)))
        }
        if !inserted.isEmpty {
            emitObject(k, "TextChanged", "insert", Int32(prefix), Int32(inserted.count), .string(Self.string(inserted)))
        }
    }

    static func string(_ s: ArraySlice<Unicode.Scalar>) -> String {
        var v = String.UnicodeScalarView()
        v.append(contentsOf: s)
        return String(v)
    }

    // MARK: Emitting

    static func eventBody(_ detail: String, _ d1: Int32, _ d2: Int32, _ any: DBusValue) -> [DBusValue] {
        [.string(detail), .int32(d1), .int32(d2), .variant(any), .emptyProperties]
    }

    static func kebab(_ member: String) -> String {
        var out = ""
        for (i, c) in member.enumerated() {
            if c.isUppercase && i > 0 { out += "-" }
            out += c.lowercased()
        }
        return out
    }

    /// An `org.a11y.atspi.Event.Object` signal from `key` (nil: the root).
    private func emitObject(_ key: String?, _ member: String, _ detail: String, _ d1: Int32, _ d2: Int32, _ any: DBusValue) {
        let event = "object:" + Self.kebab(member) + (detail.isEmpty ? "" : ":" + detail)
        guard wants(event) else { return }
        send(key.map(path) ?? ATSPI.rootPath, ATSPI.eventObject, member, event: event, key: key ?? "root",
             body: Self.eventBody(detail, d1, d2, any))
    }

    private func emitWindow(_ key: String, _ member: String) {
        let event = "window:" + Self.kebab(member)
        guard wants(event) else { return }
        send(path(key), ATSPI.eventWindow, member, event: event, key: key, body: Self.eventBody("", 0, 0, .int32(0)))
    }

    private func emitCache(_ member: String, _ item: DBusValue) {
        send(ATSPI.cachePath, ATSPI.cache, member, event: "cache:" + member, key: "", body: [item])
    }

    private func send(_ path: String, _ interface: String, _ member: String, event: String, key: String, body: [DBusValue]) {
        recordedEvents?.append(key.isEmpty ? event : "\(event) \(key)")
        do {
            try connection.emit(path: path, interface: interface, member: member, body: body)
        } catch {
            log?("emit \(event): \(error)")
        }
    }

    // MARK: Paths and references

    func path(_ key: String) -> String { ATSPI.objectPrefix + key }

    func ref(_ key: String) -> DBusValue { .structure([.string(connection.uniqueName ?? ""), .objectPath(path(key))]) }

    var rootRef: DBusValue { .structure([.string(connection.uniqueName ?? ""), .objectPath(ATSPI.rootPath)]) }

    static let nullRef = DBusValue.structure([.string(""), .objectPath(ATSPI.nullPath)])

    var desktopRef: DBusValue {
        guard let desktop else { return Self.nullRef }
        return .structure([.string(desktop.name), .objectPath(desktop.path)])
    }

    /// The node key of an object path (nil: the root or not ours).
    static func key(of path: String) -> String? {
        guard path.hasPrefix(ATSPI.objectPrefix), path != ATSPI.rootPath else { return nil }
        let k = String(path.dropFirst(ATSPI.objectPrefix.count))
        return k.isEmpty || k.contains("/") ? nil : k
    }

    static func window(of key: String) -> String { key.split(separator: "_", maxSplits: 1).first.map(String.init) ?? key }

    /// The node `key`, its window's snapshot made current.
    public func node(_ key: String) -> ATSPINode? { current(Self.window(of: key))?.nodes[key] }

    private func windows() -> [String] {
        let w = provider?.windowKeys() ?? []
        if knownWindows == nil { knownWindows = w }
        return w
    }

    // MARK: DBusObjectTree

    public func interfaces(at path: String) -> [DBusInterfaceDescription]? {
        if path == ATSPI.rootPath { return [ATSPIInterfaces.accessible, ATSPIInterfaces.application] }
        if path == ATSPI.cachePath { return [ATSPIInterfaces.cache] }
        guard let k = Self.key(of: path), let n = node(k) else { return nil }
        return n.interfaces.compactMap { ATSPIInterfaces.all[$0] }
    }

    public func handle(_ call: DBusMessage) -> DBusCallResult {
        let path = call.path ?? ""
        if path == ATSPI.cachePath {
            guard call.member == "GetItems", call.body.isEmpty else { return .unknownMethod }
            return .reply([.array(Self.cacheItemType, allCacheItems())])
        }
        if path == ATSPI.rootPath { return handleRoot(call) }
        guard let k = Self.key(of: path), let n = node(k) else {
            return .error(name: DBusErrorName.unknownObject, message: "no object at \(path)")
        }
        switch call.interface ?? "" {
        case ATSPI.accessible, "": return handleAccessible(call, n) ?? handleComponent(call, n) ?? .unknownMethod
        case ATSPI.component: return handleComponent(call, n) ?? .unknownMethod
        case ATSPI.action: return handleAction(call, n)
        case ATSPI.text: return handleText(call, n)
        case ATSPI.editableText: return handleEditableText(call, n)
        case ATSPI.selection: return handleSelection(call, n)
        default: return .unknownMethod
        }
    }

    public func property(_ name: String, interface: String, at path: String) -> DBusValue? {
        if name == "version" { return .uint32(1) }
        if path == ATSPI.rootPath { return rootProperty(name, interface: interface) }
        if path == ATSPI.cachePath { return nil }
        guard let k = Self.key(of: path), let n = node(k) else { return nil }
        switch interface {
        case ATSPI.accessible:
            switch name {
            case "Name": return .string(n.name)
            case "Description": return .string(n.description)
            case "Parent": return n.parent.map(ref) ?? rootRef
            case "ChildCount": return .int32(Int32(n.children.count))
            case "Locale": return .string(Self.locale())
            case "AccessibleId": return .string(n.identifier)
            case "HelpText": return .string(n.description)
            default: return nil
            }
        case ATSPI.action:
            return name == "NActions" ? .int32(Int32(n.actions.count)) : nil
        case ATSPI.text:
            guard let t = n.text else { return nil }
            if name == "CharacterCount" { return .int32(Int32(t.count)) }
            if name == "CaretOffset" { return .int32(Int32(t.caret)) }
            return nil
        case ATSPI.value:
            guard let v = n.value else { return nil }
            switch name {
            case "MinimumValue": return .double(v.minimum)
            case "MaximumValue": return .double(v.maximum)
            case "MinimumIncrement": return .double(v.increment)
            case "CurrentValue": return .double(v.current)
            case "Text": return .string(v.text)
            default: return nil
            }
        case ATSPI.selection:
            return name == "NSelectedChildren" ? .int32(Int32(selectedChildren(n).count)) : nil
        default:
            return nil
        }
    }

    public func setProperty(_ name: String, interface: String, at path: String, to value: DBusValue) -> DBusCallResult {
        if path == ATSPI.rootPath && interface == ATSPI.application && name == "Id", case .int32(let id) = value {
            applicationID = id
            return .reply([])
        }
        if interface == ATSPI.value && name == "CurrentValue", let k = Self.key(of: path), let d = value.doubleValue {
            return provider?.setValue(d, on: k) == true ? .reply([]) : .error(name: DBusErrorName.failed, message: "value not set")
        }
        return .error(name: DBusErrorName.propertyReadOnly, message: "\(interface).\(name) is read-only")
    }

    // MARK: The root

    private func rootProperty(_ name: String, interface: String) -> DBusValue? {
        switch (interface, name) {
        case (ATSPI.accessible, "Name"): return .string(provider?.applicationName ?? "")
        case (ATSPI.accessible, "Description"), (ATSPI.accessible, "AccessibleId"), (ATSPI.accessible, "HelpText"):
            return .string("")
        case (ATSPI.accessible, "Parent"): return desktopRef
        case (ATSPI.accessible, "ChildCount"): return .int32(Int32(windows().count))
        case (ATSPI.accessible, "Locale"): return .string(Self.locale())
        case (ATSPI.application, "ToolkitName"): return .string("OpenViews")
        case (ATSPI.application, "Version"), (ATSPI.application, "ToolkitVersion"):
            return .string(provider?.toolkitVersion ?? "1.0")
        case (ATSPI.application, "AtspiVersion"): return .string("2.1")
        case (ATSPI.application, "InterfaceVersion"): return .uint32(1)
        case (ATSPI.application, "Id"): return .int32(applicationID)
        default: return nil
        }
    }

    private func handleRoot(_ call: DBusMessage) -> DBusCallResult {
        let w = windows()
        switch (call.interface ?? ATSPI.accessible, call.member ?? "", call.signature) {
        case (ATSPI.accessible, "GetChildAtIndex", "i"):
            let i = call.body[0].intValue ?? -1
            return .reply([w.indices.contains(i) ? ref(w[i]) : Self.nullRef])
        case (ATSPI.accessible, "GetChildren", ""): return .reply([.array(.structure([.string, .objectPath]), w.map(ref))])
        case (ATSPI.accessible, "GetIndexInParent", ""): return .reply([.int32(-1)])
        case (ATSPI.accessible, "GetRelationSet", ""): return .reply([Self.emptyRelations])
        case (ATSPI.accessible, "GetRole", ""): return .reply([.uint32(ATSPIRole.application.rawValue)])
        case (ATSPI.accessible, "GetRoleName", ""), (ATSPI.accessible, "GetLocalizedRoleName", ""):
            return .reply([.string(ATSPIRole.application.name)])
        case (ATSPI.accessible, "GetState", ""): return .reply([Self.stateValue(ATSPIStateSet())])
        case (ATSPI.accessible, "GetAttributes", ""): return .reply([.stringDictionary(["toolkit": "OpenViews"])])
        case (ATSPI.accessible, "GetApplication", ""): return .reply([rootRef])
        case (ATSPI.accessible, "GetInterfaces", ""): return .reply([.strings([ATSPI.accessible, ATSPI.application])])
        case (ATSPI.application, "GetLocale", "u"): return .reply([.string(Self.locale())])
        case (ATSPI.application, "GetApplicationBusAddress", ""): return .reply([.string("")])
        default: return .unknownMethod
        }
    }

    static let referenceType = DBusType.structure([.string, .objectPath])
    /// `((so)(so)(so)iiassusau)`.
    static let cacheItemType = DBusType.structure([
        referenceType, referenceType, referenceType, .int32, .int32, .array(.string), .string, .uint32, .string, .array(.uint32),
    ])

    static let emptyRelations = DBusValue.array(.structure([.uint32, .array(.structure([.string, .objectPath]))]), [])

    static func stateValue(_ s: ATSPIStateSet) -> DBusValue { .array(.uint32, s.words.map { .uint32($0) }) }

    static func locale() -> String {
        let env = ProcessInfo.processInfo.environment
        for v in ["LC_ALL", "LC_MESSAGES", "LANG"] {
            if let l = env[v], !l.isEmpty { return l }
        }
        return "C"
    }

    // MARK: Cache

    func cacheItem(_ k: String) -> DBusValue? {
        guard let s = snapshots[Self.window(of: k)], let n = s.nodes[k] else { return nil }
        return .structure([
            ref(k), rootRef, n.parent.map(ref) ?? rootRef, .int32(Int32(n.parent == nil ? windows().firstIndex(of: k) ?? -1 : n.indexInParent)),
            .int32(Int32(n.children.count)), .strings(n.interfaces), .string(n.name), .uint32(n.role.rawValue),
            .string(n.description), Self.stateValue(n.states),
        ])
    }

    private func allCacheItems() -> [DBusValue] {
        var items: [DBusValue] = [.structure([
            rootRef, rootRef, desktopRef, .int32(-1), .int32(Int32(windows().count)),
            .strings([ATSPI.accessible, ATSPI.application]), .string(provider?.applicationName ?? ""),
            .uint32(ATSPIRole.application.rawValue), .string(""), Self.stateValue(ATSPIStateSet()),
        ])]
        for w in windows() {
            guard let s = current(w) else { continue }
            items += s.orderedKeys.compactMap(cacheItem)
        }
        return items
    }

    // MARK: Accessible

    private func handleAccessible(_ call: DBusMessage, _ n: ATSPINode) -> DBusCallResult? {
        switch (call.member ?? "", call.signature) {
        case ("GetChildAtIndex", "i"):
            let i = call.body[0].intValue ?? -1
            return .reply([n.children.indices.contains(i) ? ref(n.children[i]) : Self.nullRef])
        case ("GetChildren", ""): return .reply([.array(.structure([.string, .objectPath]), n.children.map(ref))])
        case ("GetIndexInParent", ""):
            if n.parent == nil { return .reply([.int32(Int32(windows().firstIndex(of: n.key) ?? -1))]) }
            return .reply([.int32(Int32(n.indexInParent))])
        case ("GetRelationSet", ""): return .reply([Self.emptyRelations])
        case ("GetRole", ""): return .reply([.uint32(n.role.rawValue)])
        case ("GetRoleName", ""), ("GetLocalizedRoleName", ""): return .reply([.string(n.role.name)])
        case ("GetState", ""): return .reply([Self.stateValue(n.states)])
        case ("GetAttributes", ""):
            var a = n.attributes
            a["toolkit"] = "OpenViews"
            if !n.identifier.isEmpty { a["id"] = n.identifier }
            return .reply([.stringDictionary(a)])
        case ("GetApplication", ""): return .reply([rootRef])
        case ("GetInterfaces", ""): return .reply([.strings(n.interfaces)])
        default: return nil
        }
    }

    // MARK: Component

    /// The node's extents in `coord` coordinates.
    func extents(_ n: ATSPINode, _ coord: UInt32) -> ATSPIRect {
        switch ATSPICoordType(rawValue: coord) ?? .screen {
        case .window: return n.frame
        case .screen:
            let o = provider?.screenOrigin(ofWindow: Self.window(of: n.key)) ?? (0, 0)
            return n.frame.offsetBy(o.x, o.y)
        case .parent:
            guard let p = n.parent, let pn = node(p) else { return extents(n, ATSPICoordType.screen.rawValue) }
            return n.frame.offsetBy(-pn.frame.x, -pn.frame.y)
        }
    }

    private func handleComponent(_ call: DBusMessage, _ n: ATSPINode) -> DBusCallResult? {
        let a = call.body
        func int(_ i: Int) -> Int32 { Int32(a[i].intValue ?? 0) }
        func uint(_ i: Int) -> UInt32 { UInt32(a[i].intValue ?? 0) }
        switch (call.member ?? "", call.signature) {
        case ("Contains", "iiu"):
            return .reply([.boolean(extents(n, uint(2)).contains(x: int(0), y: int(1)))])
        case ("GetAccessibleAtPoint", "iiu"):
            // Deepest descendant containing the point (later siblings on top).
            let coord = uint(2)
            var hit: ATSPINode?
            var current = n
            while true {
                let child = current.children.reversed().compactMap(node).first {
                    extents($0, coord).contains(x: int(0), y: int(1))
                }
                guard let child else { break }
                hit = child
                current = child
            }
            return .reply([hit.map { ref($0.key) } ?? Self.nullRef])
        case ("GetExtents", "u"):
            let r = extents(n, uint(0))
            return .reply([.structure([.int32(r.x), .int32(r.y), .int32(r.width), .int32(r.height)])])
        case ("GetPosition", "u"):
            let r = extents(n, uint(0))
            return .reply([.int32(r.x), .int32(r.y)])
        case ("GetSize", ""): return .reply([.int32(n.frame.width), .int32(n.frame.height)])
        case ("GetLayer", ""):
            return .reply([.uint32((n.parent == nil ? ATSPILayer.window : ATSPILayer.widget).rawValue)])
        case ("GetMDIZOrder", ""): return .reply([.int16(0)])
        case ("GrabFocus", ""): return .reply([.boolean(provider?.grabFocus(n.key) ?? false)])
        case ("GetAlpha", ""): return .reply([.double(1)])
        case ("SetExtents", "iiiiu"), ("SetPosition", "iiu"), ("SetSize", "ii"), ("ScrollTo", "u"), ("ScrollToPoint", "uii"):
            return .reply([.boolean(false)])
        default: return nil
        }
    }

    // MARK: Action

    private func handleAction(_ call: DBusMessage, _ n: ATSPINode) -> DBusCallResult {
        let i = call.body.first?.intValue ?? -1
        let action = n.actions.indices.contains(i) ? n.actions[i] : nil
        switch (call.member ?? "", call.signature) {
        case ("GetName", "i"): return .reply([.string(action?.name ?? "")])
        case ("GetLocalizedName", "i"): return .reply([.string(action?.localizedName ?? "")])
        case ("GetDescription", "i"): return .reply([.string(action?.description ?? "")])
        case ("GetKeyBinding", "i"): return .reply([.string(action?.keyBinding ?? "")])
        case ("GetActions", ""):
            return .reply([.array(.structure([.string, .string, .string]), n.actions.map {
                .structure([.string($0.localizedName), .string($0.description), .string($0.keyBinding)])
            })])
        case ("DoAction", "i"):
            guard action != nil else { return .reply([.boolean(false)]) }
            return .reply([.boolean(provider?.performAction(i, on: n.key) ?? false)])
        default: return .unknownMethod
        }
    }

    // MARK: Text

    private func handleText(_ call: DBusMessage, _ n: ATSPINode) -> DBusCallResult {
        guard let t = n.text else { return .unknownMethod }
        let s = t.scalars
        let a = call.body
        func int(_ i: Int) -> Int { a[i].intValue ?? 0 }
        func clamp(_ o: Int) -> Int { min(max(o, 0), s.count) }
        func triple(_ r: Range<Int>) -> DBusCallResult {
            .reply([.string(Self.string(s[r])), .int32(Int32(r.lowerBound)), .int32(Int32(r.upperBound))])
        }
        switch (call.member ?? "", call.signature) {
        case ("GetText", "ii"):
            let start = clamp(int(0)), end = int(1) < 0 ? s.count : clamp(int(1))
            return .reply([.string(start < end ? Self.string(s[start..<end]) : "")])
        case ("GetStringAtOffset", "iu"):
            return triple(TextSegments.range(s, at: clamp(int(0)), granularity: ATSPITextGranularity(rawValue: UInt32(int(1))) ?? .character))
        case ("GetTextAtOffset", "iu"), ("GetTextBeforeOffset", "iu"), ("GetTextAfterOffset", "iu"):
            let boundary = ATSPITextBoundary(rawValue: UInt32(int(1))) ?? .character
            var r = TextSegments.range(s, at: clamp(int(0)), boundary: boundary)
            if call.member == "GetTextBeforeOffset" {
                r = r.lowerBound > 0 ? TextSegments.range(s, at: r.lowerBound - 1, boundary: boundary) : 0..<0
            } else if call.member == "GetTextAfterOffset" {
                r = r.upperBound < s.count ? TextSegments.range(s, at: r.upperBound, boundary: boundary) : s.count..<s.count
            }
            return triple(r)
        case ("GetCharacterAtOffset", "i"):
            let o = int(0)
            return .reply([.int32(s.indices.contains(o) ? Int32(s[o].value) : 0)])
        case ("GetAttributeValue", "is"): return .reply([.string("")])
        case ("GetAttributes", "i"), ("GetAttributeRun", "ib"):
            return .reply([.stringDictionary([:]), .int32(0), .int32(Int32(s.count))])
        case ("GetDefaultAttributes", ""), ("GetDefaultAttributeSet", ""): return .reply([.stringDictionary([:])])
        case ("GetCharacterExtents", "iu"):
            let r = characterExtents(n, s.count, clamp(int(0)), UInt32(int(1)))
            return .reply([.int32(r.x), .int32(r.y), .int32(r.width), .int32(r.height)])
        case ("GetRangeExtents", "iiu"):
            let lo = clamp(int(0)), hi = max(lo, clamp(int(1)))
            let a0 = characterExtents(n, s.count, lo, UInt32(int(2)))
            let a1 = characterExtents(n, s.count, max(lo, hi - 1), UInt32(int(2)))
            return .reply([.int32(a0.x), .int32(a0.y), .int32(a1.x + a1.width - a0.x), .int32(a0.height)])
        case ("GetOffsetAtPoint", "iiu"):
            let r = extents(n, UInt32(int(2)))
            guard r.contains(x: Int32(int(0)), y: Int32(int(1))), r.width > 0 else { return .reply([.int32(-1)]) }
            let o = Int(Int64(int(0) - Int(r.x)) * Int64(max(s.count, 1)) / Int64(r.width))
            return .reply([.int32(Int32(clamp(o)))])
        case ("GetNSelections", ""): return .reply([.int32(t.selection.isEmpty ? 0 : 1)])
        case ("GetSelection", "i"):
            guard int(0) == 0, !t.selection.isEmpty else { return .reply([.int32(0), .int32(0)]) }
            return .reply([.int32(Int32(t.selection.lowerBound)), .int32(Int32(t.selection.upperBound))])
        case ("AddSelection", "ii"), ("SetSelection", "iii"):
            let first = call.member == "AddSelection" ? 0 : 1
            if call.member == "SetSelection" && int(0) != 0 { return .reply([.boolean(false)]) }
            let lo = clamp(min(int(first), int(first + 1))), hi = clamp(max(int(first), int(first + 1)))
            return .reply([.boolean(provider?.setSelection(lo..<hi, on: n.key) ?? false)])
        case ("RemoveSelection", "i"):
            guard int(0) == 0 else { return .reply([.boolean(false)]) }
            return .reply([.boolean(provider?.setSelection(t.caret..<t.caret, on: n.key) ?? false)])
        case ("SetCaretOffset", "i"):
            let o = clamp(int(0))
            return .reply([.boolean(provider?.setSelection(o..<o, on: n.key) ?? false)])
        case ("GetBoundedRanges", "iiiiuuu"):
            return .reply([.array(.structure([.int32, .int32, .string, .variant]), [])])
        case ("ScrollSubstringTo", "iiu"), ("ScrollSubstringToPoint", "iiuii"): return .reply([.boolean(false)])
        default: return .unknownMethod
        }
    }

    /// Character boxes: the node's extents divided evenly along its first
    /// line (OpenViews does not export glyph geometry yet).
    private func characterExtents(_ n: ATSPINode, _ count: Int, _ offset: Int, _ coord: UInt32) -> ATSPIRect {
        let r = extents(n, coord)
        let w = count > 0 ? r.width / Int32(max(count, 1)) : 0
        return ATSPIRect(x: r.x + w * Int32(offset), y: r.y, width: w, height: r.height)
    }

    private func handleEditableText(_ call: DBusMessage, _ n: ATSPINode) -> DBusCallResult {
        guard let t = n.text, t.isEditable, let provider else { return .unknownMethod }
        let a = call.body
        let count = t.count
        func int(_ i: Int) -> Int { min(max(a[i].intValue ?? 0, 0), count) }
        func range(_ i: Int, _ j: Int) -> Range<Int> { min(int(i), int(j))..<max(int(i), int(j)) }
        switch (call.member ?? "", call.signature) {
        case ("SetTextContents", "s"): return .reply([.boolean(provider.setText(a[0].stringValue ?? "", on: n.key))])
        case ("InsertText", "isi"):
            let text = a[1].stringValue ?? ""
            let length = a[2].intValue ?? -1
            let inserted = length < 0 ? text : Self.string(Array(text.unicodeScalars).prefix(length))
            return .reply([.boolean(provider.replaceText(in: int(0)..<int(0), with: inserted, on: n.key))])
        case ("DeleteText", "ii"): return .reply([.boolean(provider.replaceText(in: range(0, 1), with: "", on: n.key))])
        case ("CopyText", "ii"):
            _ = provider.copyText(range(0, 1), on: n.key, cut: false)
            return .reply([])
        case ("CutText", "ii"): return .reply([.boolean(provider.copyText(range(0, 1), on: n.key, cut: true))])
        case ("PasteText", "i"): return .reply([.boolean(provider.pasteText(at: int(0), on: n.key))])
        default: return .unknownMethod
        }
    }

    // MARK: Selection

    private func selectedChildren(_ n: ATSPINode) -> [String] {
        n.children.filter { node($0)?.states.contains(.selected) == true }
    }

    private func handleSelection(_ call: DBusMessage, _ n: ATSPINode) -> DBusCallResult {
        let i = call.body.first?.intValue ?? -1
        let selected = selectedChildren(n)
        switch (call.member ?? "", call.signature) {
        case ("GetSelectedChild", "i"): return .reply([selected.indices.contains(i) ? ref(selected[i]) : Self.nullRef])
        case ("SelectChild", "i"):
            guard n.children.indices.contains(i) else { return .reply([.boolean(false)]) }
            return .reply([.boolean(provider?.selectChild(i, of: n.key) ?? false)])
        case ("IsChildSelected", "i"):
            return .reply([.boolean(n.children.indices.contains(i) && selected.contains(n.children[i]))])
        case ("DeselectSelectedChild", "i"), ("DeselectChild", "i"): return .reply([.boolean(false)])
        case ("SelectAll", ""), ("ClearSelection", ""): return .reply([.boolean(false)])
        default: return .unknownMethod
        }
    }
}

/// Text segments for the Text interface (scalar offsets).
enum TextSegments {
    static func isSpace(_ c: Unicode.Scalar) -> Bool { c.properties.isWhitespace }
    static func isNewline(_ c: Unicode.Scalar) -> Bool { c == "\n" || c == "\r" || c == "\u{2028}" || c == "\u{2029}" }

    static func range(_ s: [Unicode.Scalar], at o: Int, granularity g: ATSPITextGranularity) -> Range<Int> {
        switch g {
        case .character: return o < s.count ? o..<(o + 1) : s.count..<s.count
        case .word: return range(s, at: o, boundary: .wordStart)
        case .sentence: return range(s, at: o, boundary: .sentenceStart)
        case .line, .paragraph: return range(s, at: o, boundary: .lineStart)
        }
    }

    /// The segment around offset `o`.
    static func range(_ s: [Unicode.Scalar], at o: Int, boundary b: ATSPITextBoundary) -> Range<Int> {
        let n = s.count
        guard n > 0 else { return 0..<0 }
        let o = min(max(o, 0), n)
        switch b {
        case .character:
            return o < n ? o..<(o + 1) : n..<n
        case .wordStart:
            // From the start of the word at (or before) o to the start of
            // the next word.
            var lo = min(o, n - 1)
            while lo > 0 && isSpace(s[lo]) { lo -= 1 }
            while lo > 0 && !isSpace(s[lo - 1]) { lo -= 1 }
            var hi = lo
            while hi < n && !isSpace(s[hi]) { hi += 1 }
            while hi < n && isSpace(s[hi]) { hi += 1 }
            return lo..<hi
        case .wordEnd:
            // From the end of the previous word to the end of this one.
            var hi = o
            while hi < n && isSpace(s[hi]) { hi += 1 }
            while hi < n && !isSpace(s[hi]) { hi += 1 }
            var lo = min(o, hi)
            while lo > 0 && !isSpace(s[lo - 1]) { lo -= 1 }
            while lo > 0 && isSpace(s[lo - 1]) { lo -= 1 }
            return lo..<hi
        case .sentenceStart, .sentenceEnd:
            var lo = min(o, n)
            while lo > 0 && !(s[lo - 1] == "." || s[lo - 1] == "!" || s[lo - 1] == "?" || isNewline(s[lo - 1])) { lo -= 1 }
            while lo < n && isSpace(s[lo]) && lo < o { lo += 1 }
            var hi = o
            while hi < n && !(s[hi] == "." || s[hi] == "!" || s[hi] == "?" || isNewline(s[hi])) { hi += 1 }
            if hi < n { hi += 1 }
            while hi < n && s[hi] == " " { hi += 1 }
            return lo..<hi
        case .lineStart, .lineEnd:
            var lo = min(o, n)
            if lo == n && lo > 0 && isNewline(s[lo - 1]) { return n..<n }
            while lo > 0 && !isNewline(s[lo - 1]) { lo -= 1 }
            var hi = lo
            while hi < n && !isNewline(s[hi]) { hi += 1 }
            if hi < n { hi += 1 }
            return lo..<hi
        }
    }
}
