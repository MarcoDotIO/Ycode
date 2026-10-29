import AppKit
import Foundation
import Testing
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Writes an `.xcarchive` in the documented layout: Info.plist, and (with
/// `app`) an ad hoc signed application under Products/Applications.
func makeArchive(in dir: URL, name: String, app: String?, version: String, build: String, created: Date, comment: String? = nil) throws -> URL {
    let fm = FileManager.default
    let url = dir.appendingPathComponent("\(name).xcarchive")
    try fm.createDirectory(at: url.appendingPathComponent("dSYMs"), withIntermediateDirectories: true)
    var info: [String: Any] = ["ArchiveVersion": 2, "CreationDate": created, "Name": name, "SchemeName": name]
    if let comment { info["Comment"] = comment }
    if let app {
        let bundle = url.appendingPathComponent("Products/Applications/\(app).app/Contents")
        try fm.createDirectory(at: bundle.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleExecutable": app, "CFBundleIdentifier": "com.example.\(app)", "CFBundleShortVersionString": version,
                                    "CFBundleVersion": build, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Info.plist"))
        let src = dir.appendingPathComponent("\(app).c")
        try "int main(void) { return 0; }\n".write(to: src, atomically: true, encoding: .utf8)
        for args in [["clang", "-o", bundle.appendingPathComponent("MacOS/\(app)").path, src.path],
                     ["codesign", "--force", "--sign", "-", bundle.deletingLastPathComponent().path]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            p.arguments = args
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
        }
        info["ApplicationProperties"] = ["ApplicationPath": "Applications/\(app).app", "Architectures": ["arm64"],
                                         "CFBundleIdentifier": "com.example.\(app)", "CFBundleShortVersionString": version,
                                         "CFBundleVersion": build, "SigningIdentity": "", "Team": ""]
    }
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Info.plist"))
    return url
}

@MainActor
@Suite(.serialized) struct OrganizerTests {
    func archivesDir() throws -> URL {
        let dir = ycodeDir.appendingPathComponent(".build-ide/organizer")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Archives/2026-10-16"), withIntermediateDirectories: true)
        return dir
    }

    @Test func listsGroupsAndExports() throws {
        let dir = try archivesDir()
        let day = dir.appendingPathComponent("Archives/2026-10-16")
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let a1 = try makeArchive(in: day, name: "Hello 1", app: "Hello", version: "1.0", build: "1", created: t0, comment: "First")
        _ = try makeArchive(in: day, name: "Hello 2", app: "Hello", version: "1.1", build: "2", created: t0.addingTimeInterval(60))
        _ = try makeArchive(in: day, name: "tool", app: nil, version: "", build: "", created: t0.addingTimeInterval(30))
        let list = Organizer.archives(in: dir.appendingPathComponent("Archives"))
        #expect(list.map(\.name) == ["Hello 2", "tool", "Hello 1"])
        let groups = Organizer.grouped(list)
        #expect(groups.map(\.app) == ["Hello", "tool"] && groups[0].archives.map(\.versionText) == ["1.1 (2)", "1.0 (1)"])

        let org = OrganizerController(archivesDirectory: dir.appendingPathComponent("Archives"))
        org.select(archiveAt: a1)
        // The app picker lists both apps; the list shows the chosen one's archives.
        #expect(org.appPickerTitles == ["Hello", "tool"] && org.selectedApp == "Hello")
        #expect(org.rows.map(\.title) == ["Hello", "Hello 2", "Hello 1"])
        #expect(org.detailRows.contains { $0 == ("Version", "1.0 (1)") } && org.detailRows.contains { $0 == ("Comment", "First") })
        #expect(org.detailRows.contains { $0 == ("Status", "Archived") })

        // Distribute App → Copy App through ycodebuild's export path.
        let out = dir.appendingPathComponent("Export")
        let app = try #require(org.distribute(to: out))
        #expect(org.lastExport?.output.contains("** EXPORT SUCCEEDED **") == true)
        #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/Hello").path))
        #expect(org.selected?.status == "Exported")
        _ = try WindowSnapshotTests().render(org.view, to: "organizer.png")
    }

    @Test func archiveOpensTheOrganizer() throws {
        _ = NSApplication.shared
        let dir = try archivesDir()
        let proj = dir.appendingPathComponent("Hello.xcodeproj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: ycodeDir.appendingPathComponent("Tests/YcodeProjectTests/Fixtures/Hello.xcodeproj/project.pbxproj"),
                                         to: proj.appendingPathComponent("project.pbxproj"))
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: proj)), loadDestinations: false, startLanguageService: false)
        wc.archivesDirectory = dir.appendingPathComponent("Archives")
        var calls: [(URL, String)] = []
        wc.archiveRunner = { container, scheme in
            calls.append((container, scheme))
            _ = try? makeArchive(in: dir.appendingPathComponent("Archives/2026-10-16"), name: "\(scheme) new", app: nil, version: "", build: "", created: Date())
            return (0, "** ARCHIVE SUCCEEDED **\n")
        }
        #expect(wc.archiveProduct(nil))
        #expect(calls.first?.0 == proj.standardizedFileURL && calls.first?.1 == "Hello")
        #expect(wc.organizer?.selected?.name == "Hello new")
        wc.archiveRunner = { _, _ in (65, "** ARCHIVE FAILED **\n") }
        #expect(!wc.archiveProduct(nil))
        #expect(wc.session.displayedIssues.first?.message.hasPrefix("Archive failed") == true)
    }

    /// Synthetic listings (no real names or identifiers).
    static let simctl = """
    {"devicetypes": [{"identifier": "com.apple.CoreSimulator.SimDeviceType.Phone-A", "name": "Phone A"}],
     "runtimes": [{"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-30-1", "version": "30.1"}],
     "devices": {"com.apple.CoreSimulator.SimRuntime.iOS-30-1": [
        {"name": "Phone A", "udid": "00000000-0000-0000-0000-00000000000A", "state": "Shutdown", "isAvailable": true,
         "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.Phone-A"},
        {"name": "Phone B", "udid": "00000000-0000-0000-0000-00000000000B", "state": "Booted", "isAvailable": false,
         "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.Phone-B"}],
       "com.apple.CoreSimulator.SimRuntime.Unknown-1": [{"name": "X", "udid": "U"}]}}
    """
    static let devicectl = """
    {"result": {"devices": [
      {"identifier": "11111111-2222-3333-4444-555555555555",
       "deviceProperties": {"name": "Test Device", "osVersionNumber": "30.0"},
       "hardwareProperties": {"platform": "iOS", "reality": "physical", "marketingName": "Test Model", "udid": "TESTUDID"},
       "connectionProperties": {"pairingState": "paired", "tunnelState": "disconnected"}},
      {"identifier": "sim", "deviceProperties": {"name": "Simulated"}, "hardwareProperties": {"reality": "virtual"}}]}}
    """

    @Test func devicesAndSimulators() throws {
        let sims = DevicesList.simulators(simctlJSON: Data(Self.simctl.utf8))
        #expect(sims.map(\.name) == ["Phone A", "Phone B"])
        #expect(sims[0].model == "Phone A" && sims[0].osVersion == "30.1" && sims[1].state == "Booted" && !sims[1].isAvailable)
        let devs = DevicesList.devices(devicectlJSON: Data(Self.devicectl.utf8))
        #expect(devs.count == 1 && devs[0].state == "paired, disconnected" && devs[0].model == "Test Model")
        let c = DevicesController(devices: devs, simulators: sims)
        c.view.frame = NSRect(x: 0, y: 0, width: 820, height: 480)
        // A disconnected device is listed under Unavailable, after the simulators.
        c.show(.devices)
        #expect(c.detailRows.contains { $0 == ("Connection", "paired, disconnected") })
        c.show(.simulators)
        c.select(row: 1)
        #expect(c.detailRows.contains { $0 == ("State", "Booted") } && c.detailRows.contains { $0 == ("OS", "iOS 30.1") })
        let empty = DevicesController(devices: [], simulators: [])
        _ = empty.view
        #expect(empty.detailRows.first?.0 == "No Selection")
        _ = try WindowSnapshotTests().render(c.view, to: "devices.png")
    }
}
