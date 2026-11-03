import Foundation
import Testing
import YcodeBuild
import YcodeXcodebuild
@testable import YcodeIDECore

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The IDE's swift-build engine with ycodebuild's XcodePIF as PIF source.
@Suite(.serialized, .heavyIntegration, .timeLimit(.minutes(5))) struct SharedPIFTests {
    @Test func xcodePIFSourceBuildsProjectsAndWorkspaces() async throws {
        let probe = ycodeDir.appendingPathComponent("Tools/ycode-swb/.build/debug/swbuild").path
        guard let tool = SwiftBuildEngine.locate() ?? (FileManager.default.isExecutableFile(atPath: probe) ? probe : nil) else { return }
        let dir = ycodeDir.appendingPathComponent(".build-ide/shared-pif")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let toolProj = try ProjectTemplate.commandLineTool.create(name: "Shared", organization: "org.ycode.tests", in: dir)
        let appProj = try ProjectTemplate.app.create(name: "Shown", organization: "org.ycode.tests", in: dir)
        let ws = dir.appendingPathComponent("Both.xcworkspace")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace
           version = "1.0">
           <FileRef
              location = "group:Shared/Shared.xcodeproj">
           </FileRef>
           <FileRef
              location = "group:Shown/Shown.xcodeproj">
           </FileRef>
        </Workspace>

        """.write(to: ws.appendingPathComponent("contents.xcworkspacedata"), atomically: true, encoding: .utf8)

        // The PIF uses the reference GUID scheme: workspace GUID = md5(name).
        let (data, targets) = try XcodePIFSource().pif(for: BuildRequest(container: .workspace(ws.path)))
        #expect(targets.sorted() == ["Shared", "Shown"])
        let objects = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        let wsGUID = (objects[0]["contents"] as? [String: Any])?["guid"] as? String
        #expect(wsGUID?.count == 32 && wsGUID?.allSatisfy(\.isHexDigit) == true)

        var engine = SwiftBuildEngine(swbuild: tool)
        engine.pifSource = XcodePIFSource()
        for (container, scheme) in [(BuildRequest.Container.project(toolProj.path), "Shared"), (.workspace(ws.path), "Shown")] {
            let req = BuildRequest(container: container, scheme: scheme, destination: "platform=macOS",
                                   derivedDataPath: dir.appendingPathComponent("dd-\(scheme)").path)
            let r = await engine.start(req).run()
            #expect(r.status == .succeeded, "\(scheme): \(r.issues)")
            #expect(FileManager.default.isExecutableFile(atPath: try #require(engine.executablePath(for: req))))
        }
        _ = appProj
    }

    /// Product lookup through swift-build's exported settings (`ycode-swb`),
    /// instead of `xcodebuild -showBuildSettings`.
    @Test func settingsFromTheHelper() throws {
        let helper = ycodeDir.appendingPathComponent("Tools/ycode-swb/.build/debug/ycode-swb").path
        guard FileManager.default.isExecutableFile(atPath: helper) else { return }
        let dir = ycodeDir.appendingPathComponent(".build-ide/shared-settings")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let proj = try ProjectTemplate.commandLineTool.create(name: "Lookup", organization: "org.ycode.tests", in: dir)
        var engine = XcodebuildEngine(command: ["/usr/bin/false"]) // must not be run
        engine.settingsSource = SwiftBuildSettingsSource(helper: helper)
        let req = BuildRequest(container: .project(proj.path), scheme: "Lookup", configuration: "Debug",
                               derivedDataPath: dir.appendingPathComponent("dd").path)
        let all = try engine.buildSettings(for: req)
        #expect(all.first?.target == "Lookup")
        let s = try #require(all.first?.settings)
        #expect(s["EXECUTABLE_PATH"] == "Lookup" && s["CONFIGURATION"] == "Debug")
        // The products folder carries the platform's suffix: none for macOS, and on
        // Linux, which has no macOS platform, swift-build's "-unknown".
        let folder = "Debug" + (s["EFFECTIVE_PLATFORM_NAME"] ?? "")
        #expect(s["TARGET_BUILD_DIR"]?.hasSuffix("dd/Build/Products/\(folder)") == true)
        #expect(engine.executablePath(for: req)?.hasSuffix("Products/\(folder)/Lookup") == true)
        #expect((s["PROJECT_GUID"] ?? "").count >= 32)
    }
}

/// The IDE's package checkouts and the build's `SourcePackages` folder
/// follow one rule (package-dependencies.md; build-pif.md).
@Suite struct PackageCheckoutFolderTests {
    @Test func defaultCheckoutsAreInTheDefaultSourcePackagesFolder() {
        for path in ["/tmp/A/App.xcodeproj", "/tmp/B/App.xcodeproj", "/tmp/Both.xcworkspace"] {
            let url = URL(fileURLWithPath: path)
            #expect(PackageDependencyModel.defaultCheckouts(for: url)
                == PackageGraphLoader.defaultSourcePackages(for: url).appendingPathComponent("checkouts"))
        }
        #expect(PackageDependencyModel.defaultCheckouts(for: URL(fileURLWithPath: "/tmp/A/App.xcodeproj"))
            != PackageDependencyModel.defaultCheckouts(for: URL(fileURLWithPath: "/tmp/B/App.xcodeproj")))
    }
}
