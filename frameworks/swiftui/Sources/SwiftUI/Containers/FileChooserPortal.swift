import Foundation
import OVDBus
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// The desktop's own file chooser (B5-OPENVIEWS, P-217, Linux row L-229).
// On a Linux desktop `fileImporter` and `fileExporter` show the system's
// Open and Save dialogs, as the macOS IDE shows NSOpenPanel and NSSavePanel:
// the request goes to the desktop portal's FileChooser interface on the
// session bus (`org.freedesktop.portal.FileChooser`, as the XDG desktop
// portal documentation describes it: `OpenFile` and `SaveFile` return a
// request object whose `Response` signal carries the chosen URIs). The
// portal (GNOME, KDE, …) draws the dialog the user knows from every other
// app on that desktop.
//
// OpenViews' own in-window panel (FileDialog.swift) is used instead when
// there is no portal (no session bus, a bare compositor, a headless test
// host), when the request fails, and when `OV_FILE_DIALOG=sheet` (drivers
// and walks, which need the dialog inside the window; `OV_QUIT_AFTER`
// implies it). `OV_FILE_DIALOG=portal` asks for the portal even then.

@MainActor
final class FileChooserPortal {
    static let shared = FileChooserPortal()

    private var connection: DBusConnection?
    private var connectFailed = false
    /// Tests: a connection to their own bus, pumped by the test.
    private let injected: Bool

    init(connection: DBusConnection? = nil) {
        self.connection = connection
        injected = connection != nil
        if let connection { listen(connection) }
    }

    private func listen(_ c: DBusConnection) {
        c.onSignal = { [weak self] m in
            MainActor.assumeIsolated { self?.signal(m) }
        }
    }
    private var pending: [String: (UInt32, [String: DBusValue]) -> Void] = [:]
    private var tokenCounter = 0

    /// Whether this process should try the portal at all.
    static var isWanted: Bool {
        let env = ProcessInfo.processInfo.environment
        switch env["OV_FILE_DIALOG"]?.lowercased() {
        case "sheet", "panel", "openviews": return false
        case "portal": break
        default:
            if env["OV_QUIT_AFTER"] != nil { return false }
        }
        #if os(Linux)
        return env["DBUS_SESSION_BUS_ADDRESS"] != nil || env["XDG_RUNTIME_DIR"] != nil
        #else
        return env["OV_FILE_DIALOG"]?.lowercased() == "portal"
        #endif
    }

    private func bus() -> DBusConnection? {
        if let connection { return connection }
        guard !connectFailed else { return nil }
        do {
            let c = try DBusConnection.session(timeout: 2)
            listen(c)
            c.onDisconnect = { [weak self] in
                MainActor.assumeIsolated {
                    self?.connection = nil
                    self?.failPending()
                }
            }
            c.startDispatch(queue: .main)
            connection = c
            return c
        } catch {
            connectFailed = true
            return nil
        }
    }

    /// The request options for a dialog of `mode`.
    nonisolated static func options(_ mode: FileDialogMode, start: URL, confirmation: String?, token: String) -> [DBusValue] {
        var o: [(String, DBusValue)] = [("handle_token", .string(token)), ("modal", .boolean(true))]
        if let confirmation { o.append(("accept_label", .string(confirmation))) }
        let folder = Array(start.standardizedFileURL.path.utf8) + [0]
        o.append(("current_folder", .array(.byte, folder.map { DBusValue.byte($0) })))
        switch mode {
        case let .open(types, multiple):
            o.append(("multiple", .boolean(multiple)))
            if !types.isEmpty && types.allSatisfy({ $0.conforms(to: .folder) }) {
                o.append(("directory", .boolean(true)))
            } else if let f = filter(types) {
                o.append(("filters", .array(filterType, [f])))
                o.append(("current_filter", f))
            }
        case let .save(type, defaultName, _):
            let base = defaultName ?? "Untitled"
            let name = (base as NSString).pathExtension.isEmpty ? type.preferredFilenameExtension.map { base + "." + $0 } ?? base : base
            o.append(("current_name", .string(name)))
            if let f = filter([type]) { o.append(("filters", .array(filterType, [f]))) }
        }
        return [.array(.dictEntry(.string, .variant), o.map { .dictEntry(.string($0.0), .variant($0.1)) })]
    }

    /// `(sa(us))`: a named filter of glob patterns (kind 0).
    nonisolated static let filterType = DBusType.structure([.string, .array(.structure([.uint32, .string]))])

    nonisolated static func filter(_ types: [UTType]) -> DBusValue? {
        let globs = types.flatMap(\.extensions).map { "*." + $0 }
        guard !globs.isEmpty else { return nil }
        let name = types.map(\.description).joined(separator: ", ")
        return .structure([.string(name), .array(.structure([.uint32, .string]),
                                                  globs.map { .structure([.uint32(0), .string($0)]) })])
    }

    /// The request object a call with `token` answers on.
    nonisolated static func requestPath(sender: String, token: String) -> String {
        let s = sender.hasPrefix(":") ? String(sender.dropFirst()) : sender
        return "/org/freedesktop/portal/desktop/request/" + s.replacingOccurrences(of: ".", with: "_") + "/" + token
    }

    /// The chosen files of a `Response` (nil: cancelled or failed).
    nonisolated static func urls(response: UInt32, results: [String: DBusValue]) -> [URL]? {
        guard response == 0, case .variant(.array(_, let items))? = results["uris"] else { return nil }
        let urls = items.compactMap { v -> URL? in
            guard case .string(let s) = v, let u = URL(string: s), u.isFileURL else { return nil }
            return u
        }
        return urls.isEmpty ? nil : urls
    }

    /// Shows the desktop's dialog. `finish` gets the files chosen, nil for
    /// a cancel; `unavailable` runs (once, instead) when there is no portal.
    /// Returns a closer for the open dialog.
    @discardableResult
    func present(_ mode: FileDialogMode, start: URL, title: String, confirmation: String?,
                 finish: @escaping ([URL]?) -> Void, unavailable: @escaping () -> Void) -> (() -> Void)? {
        guard injected || Self.isWanted, let c = bus(), let sender = c.uniqueName else {
            unavailable()
            return nil
        }
        tokenCounter += 1
        let token = "openviews\(ProcessInfo.processInfo.processIdentifier)_\(tokenCounter)"
        let path = Self.requestPath(sender: sender, token: token)
        let member: String
        switch mode {
        case .open: member = "OpenFile"
        case .save: member = "SaveFile"
        }
        try? c.addMatch("type='signal',interface='org.freedesktop.portal.Request',member='Response',path='\(path)'")
        var done = false
        pending[path] = { response, results in
            guard !done else { return }
            done = true
            finish(Self.urls(response: response, results: results))
        }
        let call = DBusMessage.methodCall(destination: "org.freedesktop.portal.Desktop", path: "/org/freedesktop/portal/desktop",
                                          interface: "org.freedesktop.portal.FileChooser", member: member,
                                          body: [.string(""), .string(title)] + Self.options(mode, start: start, confirmation: confirmation,
                                                                                               token: token))
        do {
            try c.call(call) { [weak self] reply in
                MainActor.assumeIsolated {
                    guard reply.type == .error else { return }
                    // No portal (or it refused): OpenViews' own panel.
                    self?.pending[path] = nil
                    if !done {
                        done = true
                        unavailable()
                    }
                }
            }
        } catch {
            pending[path] = nil
            done = true
            unavailable()
            return nil
        }
        return { [weak self] in
            guard let self, let c = self.connection, !done else { return }
            _ = try? c.send(.methodCall(destination: "org.freedesktop.portal.Desktop", path: path,
                                        interface: "org.freedesktop.portal.Request", member: "Close"))
        }
    }

    private func signal(_ m: DBusMessage) {
        guard m.interface == "org.freedesktop.portal.Request", m.member == "Response", let path = m.path,
              let handler = pending.removeValue(forKey: path) else { return }
        var response: UInt32 = 2
        var results: [String: DBusValue] = [:]
        if case .uint32(let r)? = m.body.first { response = r }
        if m.body.count > 1, case .array(_, let entries) = m.body[1] {
            for e in entries {
                if case .dictEntry(.string(let k), let v) = e { results[k] = v }
            }
        }
        handler(response, results)
    }

    private func failPending() {
        let handlers = pending.values
        pending = [:]
        for h in handlers { h(2, [:]) }
    }
}
