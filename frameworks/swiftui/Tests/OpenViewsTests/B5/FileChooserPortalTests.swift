import Foundation
import OVDBus
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// Beta 5, B5-OPENVIEWS (specs/ide/parity-inventory.md P-217, Linux row
// L-229): file dialogs ask the desktop portal's FileChooser, so the user
// gets the desktop's own Open and Save dialogs; OpenViews' panel remains
// when there is no portal. The live test runs a stand-in portal on a
// private bus (skipped where `dbus-daemon` is not installed, as on macOS).

/// A stand-in portal: answers OpenFile and SaveFile with the request path
/// and then emits that request's Response with the given URIs.
@MainActor
final class StandInPortal: DBusObjectTree {
    let connection: DBusConnection
    var calls: [(String, [String: DBusValue])] = []
    var uris: [String] = ["file:///tmp/Chosen.swift"]
    var response: UInt32 = 0

    init(address: String) throws {
        connection = try DBusConnection.open(address: address)
        _ = try connection.call(.methodCall(destination: DBusConnection.busName, path: DBusConnection.busPath,
                                            interface: DBusConnection.busName, member: "RequestName",
                                            body: [.string("org.freedesktop.portal.Desktop"), .uint32(4)]))
        connection.objects = self
    }

    func interfaces(at path: String) -> [DBusInterfaceDescription]? {
        path == "/org/freedesktop/portal/desktop" ? [DBusInterfaceDescription("org.freedesktop.portal.FileChooser", methods: [
            .method("OpenFile", in: ["s", "s", "a{sv}"], out: ["o"]), .method("SaveFile", in: ["s", "s", "a{sv}"], out: ["o"]),
        ])] : nil
    }

    func handle(_ call: DBusMessage) -> DBusCallResult {
        guard let member = call.member, call.body.count == 3, case .array(_, let entries) = call.body[2] else { return .invalidArgs("args") }
        var options: [String: DBusValue] = [:]
        for e in entries { if case .dictEntry(.string(let k), .variant(let v)) = e { options[k] = v } }
        calls.append((member, options))
        guard case .string(let token)? = options["handle_token"], let sender = call.sender else { return .invalidArgs("token") }
        let path = FileChooserPortal.requestPath(sender: sender, token: token)
        let results: DBusValue = .array(.dictEntry(.string, .variant), [
            .dictEntry(.string("uris"), .variant(.array(.string, uris.map { .string($0) }))),
        ])
        // (The real portal answers when the user has chosen; the signal
        // may come before the method's reply, which the client allows.)
        try? connection.emit(path: path, interface: "org.freedesktop.portal.Request", member: "Response",
                             body: [.uint32(response), results])
        return .reply([.objectPath(path)])
    }

    func property(_ name: String, interface: String, at path: String) -> DBusValue? { nil }
}

@MainActor
@Suite("B5 desktop file chooser (P-217)")
struct FileChooserPortalTests {
    @Test func openOptionsNameTheFolderTheFiltersAndTheToken() {
        let body = FileChooserPortal.options(.open(types: [.swiftSource], multiple: true), start: URL(fileURLWithPath: "/home/u"),
                                             confirmation: "Open", token: "t1")
        guard case .array(_, let entries)? = body.first else { Issue.record("a{sv}"); return }
        var o: [String: DBusValue] = [:]
        for e in entries { if case .dictEntry(.string(let k), .variant(let v)) = e { o[k] = v } }
        #expect(o["handle_token"] == .string("t1"))
        #expect(o["multiple"] == .boolean(true))
        #expect(o["accept_label"] == .string("Open"))
        #expect(o["current_folder"] == .array(.byte, Array("/home/u".utf8).map { .byte($0) } + [.byte(0)]))
        #expect("\(o["filters"] ?? .string(""))".contains("*.swift"))
        #expect(body.first?.signature == "a{sv}")
    }

    @Test func foldersAskForADirectoryAndSavesForAName() {
        func options(_ m: FileDialogMode) -> [String: DBusValue] {
            guard case .array(_, let entries)? = FileChooserPortal.options(m, start: URL(fileURLWithPath: "/"), confirmation: nil, token: "t").first
            else { return [:] }
            var o: [String: DBusValue] = [:]
            for e in entries { if case .dictEntry(.string(let k), .variant(let v)) = e { o[k] = v } }
            return o
        }
        #expect(options(.open(types: [.folder], multiple: false))["directory"] == .boolean(true))
        let save = options(.save(type: .json, defaultName: "Theme", write: { _ in }))
        #expect(save["current_name"] == .string("Theme.json"))
    }

    @Test func requestPathsAndResponses() {
        #expect(FileChooserPortal.requestPath(sender: ":1.42", token: "abc") == "/org/freedesktop/portal/desktop/request/1_42/abc")
        let ok: [String: DBusValue] = ["uris": .variant(.array(.string, [.string("file:///home/u/A%20B.swift")]))]
        #expect(FileChooserPortal.urls(response: 0, results: ok) == [URL(fileURLWithPath: "/home/u/A B.swift")])
        #expect(FileChooserPortal.urls(response: 1, results: ok) == nil)
        #expect(FileChooserPortal.urls(response: 0, results: [:]) == nil)
    }

    @Test(.enabled(if: PrivateBus.daemonPath != nil)) func theDesktopPortalAnswersAnOpenRequest() throws {
        guard let bus = PrivateBus() else { return }
        let portal = try StandInPortal(address: bus.address)
        let client = try DBusConnection.open(address: bus.address)
        let chooser = FileChooserPortal(connection: client)
        var chosen: [URL]?
        var unavailable = false
        var finished = false
        chooser.present(.open(types: [.swiftSource], multiple: false), start: URL(fileURLWithPath: "/tmp"), title: "Open",
                        confirmation: nil, finish: { chosen = $0; finished = true }, unavailable: { unavailable = true })
        pumpAll([client, portal.connection]) { finished || unavailable }
        #expect(!unavailable)
        #expect(portal.calls.first?.0 == "OpenFile")
        #expect(chosen == [URL(fileURLWithPath: "/tmp/Chosen.swift")])
        // A cancel answers nil.
        portal.response = 1
        finished = false
        chooser.present(.open(types: [], multiple: false), start: URL(fileURLWithPath: "/tmp"), title: "Open",
                        confirmation: nil, finish: { chosen = $0; finished = true }, unavailable: { unavailable = true })
        pumpAll([client, portal.connection]) { finished }
        #expect(finished && chosen == nil)
    }

    @Test(.enabled(if: PrivateBus.daemonPath != nil)) func withoutAPortalThePanelIsUsed() throws {
        guard let bus = PrivateBus() else { return }
        let client = try DBusConnection.open(address: bus.address)
        let chooser = FileChooserPortal(connection: client)
        var unavailable = false
        chooser.present(.open(types: [], multiple: false), start: URL(fileURLWithPath: "/tmp"), title: "Open",
                        confirmation: nil, finish: { _ in }, unavailable: { unavailable = true })
        pumpAll([client]) { unavailable }
        #expect(unavailable)
    }
}
