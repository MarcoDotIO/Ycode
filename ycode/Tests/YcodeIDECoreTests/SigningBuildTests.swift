import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore
import YcodeProject

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// IDE builds keep the target's entitlements (specs/ide/signing.md §6): a
/// macOS app with capabilities added in the project editor, built through
/// the IDE's engine (swift-build through the `ycode-swb` helper), is signed
/// ad hoc with its entitlements, build settings in them expanded.
@Suite(.serialized, .heavyIntegration, .timeLimit(.minutes(5))) struct SigningBuildTests {
    @Test func ideBuildsSignTheirEntitlements() async throws {
        #if os(macOS)
        let probe = ycodeDir.appendingPathComponent("Tools/ycode-swb/.build/debug/swbuild").path
        guard let tool = SwiftBuildEngine.locate() ?? (FileManager.default.isExecutableFile(atPath: probe) ? probe : nil),
              SwiftBuildEngine.locateHelper(swbuild: tool) != nil else { return }
        let dir = ycodeDir.appendingPathComponent(".build-ide/signing-build")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = try ProjectTemplate.app.create(name: "Signed", organization: "org.ycode.tests", in: dir)
        var model = ProjectEditorModel(proj: try PBXProj(contentsOf: url), xcodeprojURL: url)
        try model.addCapability(.outgoingNetwork, target: "Signed", configuration: "Debug")
        try model.proj.serialized(projectName: "Signed").write(to: url.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        // An app group whose name uses a build setting.
        let entitlementsFile = try #require(model.entitlementsURL(target: "Signed", configuration: "Debug"))
        var ents = try PropertyListSerialization.propertyList(from: Data(contentsOf: entitlementsFile), format: nil) as! [String: Any]
        ents["com.apple.security.application-groups"] = ["$(PRODUCT_BUNDLE_IDENTIFIER).shared"]
        try PropertyListSerialization.data(fromPropertyList: ents, format: .xml, options: 0).write(to: entitlementsFile)

        let engine = BuildSystemPreference.swiftBuild.makeEngine { tool }
        let req = BuildRequest(container: .project(url.path), scheme: "Signed", destination: "platform=macOS",
                               derivedDataPath: dir.appendingPathComponent("dd").path)
        let r = await engine.start(req).run()
        #expect(r.status == .succeeded, "\(r.issues)")
        let exe = try #require(engine.executablePath(for: req))
        let app = URL(fileURLWithPath: exe).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let signed = try signedEntitlements(app.path)
        #expect(signed["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(signed["com.apple.security.network.client"] as? Bool == true)
        #expect(signed["com.apple.security.get-task-allow"] as? Bool == true)
        #expect(signed["com.apple.security.application-groups"] as? [String] == ["org.ycode.tests.Signed.shared"])
        // No application identifier without a profile: macOS would not launch it.
        #expect(signed["com.apple.application-identifier"] == nil)
        #endif
    }

    /// `codesign -d --entitlements :-` of a bundle, as a dictionary.
    func signedEntitlements(_ path: String) throws -> [String: Any] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-d", "--entitlements", ":-", path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]) ?? [:]
    }
}
