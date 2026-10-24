import Foundation
import Testing
import YcodeProject
@testable import YcodeBuild

@Suite struct PIFDependencyTests {
    @Test func dependenciesLinksAndFrameworks() throws {
        let url = try writeMultiProject(at: ideScratch.appendingPathComponent("pif-multi"))
        let gen = PIFGenerator(proj: try PBXProj(contentsOf: url), xcodeprojURL: url)
        let objects = try #require(try gen.pif().arrayValue)
        let targets = objects.filter { $0["type"] == "target" }.compactMap { $0["contents"] }
        #expect(targets.map { $0["name"]?.stringValue } == ["Core", "Kit", "Tool"])
        #expect(targets[1]["productTypeIdentifier"] == "com.apple.product-type.framework")
        let tool = targets[2]
        #expect(tool["dependencies"] == [.object(["guid": targets[0]["guid"]!]), .object(["guid": targets[1]["guid"]!])])
        let link = try #require(tool["buildPhases"]?.arrayValue?.first { $0["type"] == "com.apple.buildphase.frameworks" })
        #expect(link["buildFiles"]?.arrayValue?.first?["targetReference"] == targets[0]["guid"])
        #expect(PIFGenerator.destinationSubfolder(spec: "10") == "$(FRAMEWORKS_FOLDER_PATH)")
    }

    @Test func workspaceJoinsProjects() throws {
        let ws = try writeWorkspace(at: ideScratch.appendingPathComponent("pif-ws"))
        let projects = try SwiftBuildEngine.workspaceProjects(ws)
        #expect(projects.map { $0.1.lastPathComponent } == ["Multi.xcodeproj", "SmokeApp.xcodeproj"])
        let pif = try PIFGenerator.workspacePIF(projects: projects, workspaceURL: ws)
        let objects = try #require(pif.arrayValue)
        #expect(objects.filter { $0["type"] == "project" }.count == 2)
        #expect(objects[0]["contents"]?["projects"]?.arrayValue?.count == 2)
        #expect(SwiftBuildEngine.supports(BuildRequest(container: .workspace(ws.path))))
    }
}

@Suite(.serialized, .timeLimit(.minutes(5))) struct SwiftBuildWorkspaceTests {
    @Test func buildsDependenciesAndWorkspaces() async throws {
        #if os(macOS)
        guard let tool = SwiftBuildEndToEndTests.swbuild else { return }
        let engine = SwiftBuildEngine(swbuild: tool)

        // In-project dependencies: building Tool builds Core and Kit first.
        let dir = ideScratch.appendingPathComponent("swiftbuild-multi")
        let proj = try writeMultiProject(at: dir)
        let req = BuildRequest(container: .project(proj.path), scheme: "Tool", destination: "platform=macOS",
                               derivedDataPath: dir.appendingPathComponent("dd").path)
        let r = await engine.start(req).run()
        #expect(r.status == .succeeded, "\(r.issues)")
        let products = dir.appendingPathComponent("dd/Products/Debug")
        #expect(FileManager.default.fileExists(atPath: products.appendingPathComponent("libCore.a").path))
        #expect(FileManager.default.fileExists(atPath: products.appendingPathComponent("Kit.framework/Versions/A/Kit").path))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try #require(engine.executablePath(for: req)))
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "core=42\n")

        // A workspace with two projects: the app's scheme builds the app.
        let wsDir = ideScratch.appendingPathComponent("swiftbuild-ws")
        let ws = try writeWorkspace(at: wsDir)
        let wreq = BuildRequest(container: .workspace(ws.path), scheme: "SmokeApp", destination: "platform=macOS",
                                derivedDataPath: wsDir.appendingPathComponent("dd").path)
        let w = await engine.start(wreq).run()
        #expect(w.status == .succeeded, "\(w.issues)")
        #expect(try #require(engine.executablePath(for: wreq)).hasSuffix("Products/Debug/SmokeApp.app/Contents/MacOS/SmokeApp"))
        #expect(FileManager.default.isExecutableFile(atPath: try #require(engine.executablePath(for: wreq))))
        #endif
    }
}
