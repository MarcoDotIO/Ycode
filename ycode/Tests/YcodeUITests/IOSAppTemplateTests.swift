import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
import YcodePlist
import YcodeProject
@testable import YcodeUI

@MainActor
@Suite(.serialized) struct IOSAppTemplateTests {
    func tempDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-iosapp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func options(_ name: String, _ testing: ProjectOptions.Testing, _ storage: ProjectOptions.Storage) -> ProjectOptions {
        var o = ProjectOptions()
        o.productName = name
        o.organizationIdentifier = "org.ycode.tests"
        o.testing = testing
        o.setStorage(storage)
        return o
    }

    func settings(_ p: PBXProj, target: PBXObject, _ config: String = "Debug") -> PlistDictionary? {
        p.buildConfigurations(listID: target.string("buildConfigurationList")).first { $0.string("name") == config }?.attributes["buildSettings"]?.dictionary
    }

    func storyboardOptions(_ name: String, _ testing: ProjectOptions.Testing = .none) -> ProjectOptions {
        var o = options(name, testing, .none)
        o.interface = .storyboard
        return o
    }

    /// Finish on the options step (the compact picker's App row) creates it.
    @Test func finishCreatesIOSApp() throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = try WorkspaceModel(url: try WindowSnapshotTests().samplePackage())
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: host), loadDestinations: false, startLanguageService: false)
        let td = TestDefaults("ios-app-template")
        defer { td.remove() }
        wc.templateDefaults = td.defaults
        wc.newProjectLocation = dir
        // Choose Template… ▸ iOS ▸ App (the picker's App row is the untitled project).
        let sheet = wc.chooseProjectTemplate()
        #expect(sheet.select(templateID: "ios.app"))
        sheet.nextClicked()
        sheet.options = options("Picked", .swiftTesting, .swiftData)
        sheet.nextClicked()
        let url = try #require(wc.lastCreatedProject)
        let p = try PBXProj(contentsOf: url.appendingPathComponent("project.pbxproj"))
        #expect(p.targets.map { $0.string("name") ?? "" } == ["Picked", "PickedTests", "PickedUITests"])
    }

    func run(_ tool: String, _ args: [String]) -> (status: Int32, out: String)? { Self.run(tool, args) }

    nonisolated static func run(_ tool: String, _ args: [String]) -> (status: Int32, out: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
