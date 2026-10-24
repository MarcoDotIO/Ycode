import AppKit
import Foundation
import Testing
import YcodePlist
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@MainActor
@Suite(.serialized) struct SigningTests {
    @Test func signingAndCapabilities() throws {
        _ = NSApplication.shared
        let dir = ycodeDir.appendingPathComponent(".build-ide/signing")
        try? FileManager.default.removeItem(at: dir)
        let proj = dir.appendingPathComponent("Hello.xcodeproj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: ycodeDir.appendingPathComponent("Tests/YcodeProjectTests/Fixtures/Hello.xcodeproj/project.pbxproj"),
                                         to: proj.appendingPathComponent("project.pbxproj"))
        let file = proj.appendingPathComponent("project.pbxproj")
        let session = WorkspaceSession(model: try WorkspaceModel(url: proj))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        let pe = try #require(wc.openProjectEditor(proj.path))
        pe.select(tab: .signing)
        #expect(pe.model.capabilities(target: "Hello", configuration: "Debug").isEmpty)

        pe.setAutomaticSigning(false)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("CODE_SIGN_STYLE = Manual;"))
        pe.setSetting("DEVELOPMENT_TEAM", "ABCDE12345")
        #expect(pe.model.teams == ["ABCDE12345"])

        // "+ Capability" → Outgoing Connections also adds the sandbox.
        let library = pe.capabilityLibrary()
        _ = library.view
        library.select(.outgoingNetwork)
        #expect(library.addSelectedCapability())
        let ent = dir.appendingPathComponent("Hello/Hello.entitlements")
        let doc = try PropertyListDocument(data: Data(contentsOf: ent))
        #expect(doc.root == .dictionary([PropertyListEntry(key: "com.apple.security.app-sandbox", value: .bool(true)),
                                         PropertyListEntry(key: "com.apple.security.network.client", value: .bool(true))]))
        let pbx = try String(contentsOf: file, encoding: .utf8)
        #expect(pbx.contains("CODE_SIGN_ENTITLEMENTS = Hello/Hello.entitlements;") && pbx.contains("path = Hello/Hello.entitlements;"))
        try pe.addCapability(.hardenedRuntime)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("ENABLE_HARDENED_RUNTIME = YES;"))
        #expect(pe.model.capabilities(target: "Hello", configuration: "Debug") == [.appSandbox, .hardenedRuntime, .outgoingNetwork])
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "project-editor-signing.png")

        // Removing the sandbox removes what depends on it.
        try pe.removeCapability(.appSandbox)
        #expect(pe.model.capabilities(target: "Hello", configuration: "Debug") == [.hardenedRuntime])
        #expect(try PropertyListDocument(data: Data(contentsOf: ent)).root == .dictionary([]))
        #expect(pe.model.signingCertificate(target: "Hello", configuration: "Debug") == "None")
    }
}
