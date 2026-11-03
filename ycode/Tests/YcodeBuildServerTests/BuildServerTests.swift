import Foundation
import Testing
import YcodeDebug
@testable import YcodeBuildServer
import YcodeXcodebuild
import YcodeLanguage

/// Settings for the sample project from Ycode's resolver, without an SDK
/// (the same on macOS and Linux).
@Suite struct IndexSettingsTests {
    @Test func resolverSettingsForTheSample() throws {
        let dir = try freshScratch("settings")
        let proj = try SampleProject.write(.iOS, in: dir)
        let context = BuildContext(derivedDataFolder: dir.appendingPathComponent("DD/Sample-x").path, developerDirectory: nil,
                                   hostArchitecture: "arm64", isLinuxHost: false)
        let model = try IndexModel(containerURL: proj, context: context)
        let kit = try #require(model.graph.targets.first { $0.name == "Kit" })
        let ctx = try #require(model.compileContext(kit.id))
        #expect(ctx.value("CONFIGURATION") == "Debug")
        #expect(ctx.moduleName == "Kit")
        #expect(ctx.value("PLATFORM_NAME") == "iphonesimulator")
        #expect(ctx.productsDirectory == context.productsRoot + "/Debug-iphonesimulator")
        #expect(ctx.objectFile(for: "/x/Greeter.swift") == context.intermediatesRoot
            + "/Sample.build/Debug-iphonesimulator/Kit.build/Objects-normal/arm64/Greeter.o")
        #expect(ctx.triple == "arm64-apple-ios18.0-simulator")
        #expect(ctx.exportsClangModule)

        // App: conditions, definitions, bridging header and the project's
        // header folders.
        let main = dir.appendingPathComponent("Sample-iOS/App/AppMain.swift").path
        let args = try #require(model.arguments(for: main, targetID: nil)).arguments
        #expect(CompilerArgumentsTests.has(args, "-D", "DEBUG"))
        #expect(CompilerArgumentsTests.has(args, "-Xcc", "-DDEBUG=1"))
        #expect(CompilerArgumentsTests.has(args, "-swift-version", "5"))
        #expect(args.contains("-enable-testing") && args.contains("-Onone"))
        #expect(CompilerArgumentsTests.has(args, "-import-objc-header", dir.appendingPathComponent("Sample-iOS/App/App-Bridging-Header.h").path))
        #expect(CompilerArgumentsTests.has(args, "-Xcc", "-iquote", "-Xcc", dir.appendingPathComponent("Sample-iOS/Kit").path))

        // A configuration the project lacks falls back to Debug; a
        // destination on another platform family leaves the SDK alone.
        var other = context
        other.configuration = "Nope"
        other.destination = "platform=macOS"
        let m2 = try IndexModel(containerURL: proj, context: other)
        let c2 = try #require(m2.compileContext(kit.id))
        #expect(c2.value("CONFIGURATION") == "Debug" && c2.value("PLATFORM_NAME") == "iphonesimulator")
        other.destination = "platform=iOS,arch=arm64e"
        let c3 = try #require(try IndexModel(containerURL: proj, context: other).compileContext(kit.id))
        #expect(c3.value("PLATFORM_NAME") == "iphoneos" && c3.triple == "arm64e-apple-ios18.0")
    }

    @Test func reloadReportsChangedTargets() throws {
        let dir = try freshScratch("reload")
        let proj = try SampleProject.write(.portable, in: dir)
        let model = try IndexModel(containerURL: proj, context: BuildContext(derivedDataFolder: dir.appendingPathComponent("DD").path))
        #expect(model.reloadIfChanged().isEmpty)
        // A new file in the synchronized folder changes AppTests.
        let tests = dir.appendingPathComponent("Sample-portable/AppTests")
        try "".write(to: tests.appendingPathComponent("More.swift"), atomically: true, encoding: .utf8)
        // Folder modification times have one-second resolution on some file systems.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: tests.path)
        let changed = model.reloadIfChanged()
        #expect(changed.compactMap { id in model.graph.target(id: id)?.name } == ["AppTests"])
        // A setting change in the project file changes every target it reaches.
        let pbx = proj.appendingPathComponent("project.pbxproj")
        let text = try String(contentsOf: pbx, encoding: .utf8).replacingOccurrences(of: "SWIFT_VERSION = 5.0;", with: "SWIFT_VERSION = 6.0;")
        try text.write(to: pbx, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: pbx.path)
        #expect(Set(model.reloadIfChanged().compactMap { model.graph.target(id: $0)?.name }) == ["Kit", "App", "AppTests"])
    }
}

/// The server over an in-memory channel.
@Suite struct BuildServerProtocolTests {
    final class Channel: @unchecked Sendable {
        let lock = NSLock()
        var decoder = DAPFraming.Decoder()
        var messages: [JSON] = []
        func received(_ data: Data) {
            lock.withLock {
                for body in decoder.append(data) { if let m = try? JSON.decode(body) { messages.append(m) } }
            }
        }
        /// Waits for the response to `id`.
        func response(_ id: Int, timeout: TimeInterval = 120) -> JSON? {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                if let m = lock.withLock({ messages.first { $0["id"]?.int == id } }) { return m }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return nil
        }
    }

    static func request(_ server: BuildServer, _ id: Int, _ method: String, _ params: JSON = .null) {
        server.receive(DAPFraming.frame(JSON.object(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]).encoded()))
    }

    @Test func initializeTargetsSourcesOptions() throws {
        let dir = try freshScratch("protocol")
        let proj = try SampleProject.write(.portable, in: dir)
        let context = BuildContext(derivedDataFolder: dir.appendingPathComponent("DD/Sample").path)
        let model = try IndexModel(containerURL: proj, context: context)
        let channel = Channel()
        let server = BuildServer(model: model, send: { channel.received($0) })

        Self.request(server, 1, "build/initialize", ["displayName": "test", "version": "1", "bspVersion": "2.2.0", "rootUri": "file:///tmp",
                                                      "capabilities": ["languageIds": ["swift"]]])
        let initResult = try #require(channel.response(1)?["result"])
        #expect(initResult["dataKind"] == "sourceKit")
        #expect(initResult["data"]?["indexStorePath"]?.string == context.indexStorePath)
        #expect(initResult["data"]?["indexDatabasePath"]?.string == context.indexDatabasePath)
        #expect(initResult["data"]?["prepareProvider"] == true && initResult["data"]?["sourceKitOptionsProvider"] == true)
        #expect(initResult["capabilities"]?["buildTargetChangedProvider"] == true)
        server.receive(DAPFraming.frame(JSON.object(["jsonrpc": "2.0", "method": "build/initialized", "params": [:]]).encoded()))

        Self.request(server, 2, "workspace/buildTargets")
        let targets = try #require(channel.response(2)?["result"]?["targets"]?.array)
        #expect(targets.compactMap { $0["displayName"]?.string } == ["Kit", "App", "AppTests"])
        let app = try #require(targets.first { $0["displayName"] == "App" })
        let kitID = try #require(targets.first { $0["displayName"] == "Kit" }?["id"])
        #expect(app["dependencies"]?.array == [kitID])
        #expect(app["tags"]?.array == ["application"])
        #expect(targets.first { $0["displayName"] == "AppTests" }?["tags"]?.array == ["test"])

        Self.request(server, 3, "buildTarget/sources", ["targets": [app["id"]!]])
        let items = try #require(channel.response(3)?["result"]?["items"]?.array)
        let main = dir.appendingPathComponent("Sample-portable/App/main.swift")
        #expect(items.first?["sources"]?.array?.compactMap { $0["uri"]?.string } == [main.absoluteString])
        #expect(items.first?["sources"]?.array?.first?["data"]?["language"] == "swift")

        Self.request(server, 4, "textDocument/sourceKitOptions", ["textDocument": ["uri": .string(main.absoluteString)], "target": app["id"]!,
                                                                    "language": "swift"])
        let options = try #require(channel.response(4)?["result"])
        let args = options["compilerArguments"]?.array?.compactMap(\.string) ?? []
        #expect(Array(args.prefix(3)) == ["-module-name", "App", main.path])
        #expect(options["workingDirectory"]?.string == dir.appendingPathComponent("Sample-portable").path)

        // Unknown files get null; unknown methods an error.
        Self.request(server, 5, "textDocument/sourceKitOptions", ["textDocument": ["uri": "file:///nowhere.swift"], "target": app["id"]!,
                                                                    "language": "swift"])
        #expect(channel.response(5)?["result"] == .null)
        Self.request(server, 6, "buildTarget/compile")
        #expect(channel.response(6)?["error"]?["code"]?.int == -32601)

        // A project change is reported as changed targets.
        let pbx = proj.appendingPathComponent("project.pbxproj")
        let text = try String(contentsOf: pbx, encoding: .utf8).replacingOccurrences(of: "SWIFT_VERSION = 5.0;", with: "SWIFT_VERSION = 6.0;")
        try text.write(to: pbx, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: pbx.path)
        Self.request(server, 7, "workspace/waitForBuildSystemUpdates")
        #expect(channel.response(7) != nil)
        let change = channel.lock.withLock { channel.messages.first { $0["method"] == "buildTarget/didChange" } }
        #expect(change?["params"]?["changes"]?.array?.count == 3)

        Self.request(server, 8, "build/shutdown")
        #expect(channel.response(8)?["result"] == .null)
    }

    @Test func configFile() throws {
        let dir = try freshScratch("config")
        let file = try BuildServerConfigFile.write(argv: ["/bin/ycode-bsp", "serve", "/p/App.xcodeproj"], into: dir)
        #expect(file.path.hasSuffix(".bsp/ycode.json"))
        let json = try JSON.decode(Data(contentsOf: file))
        #expect(json["name"] == "Ycode" && json["bspVersion"] == "2.2.0")
        #expect(json["argv"]?.array == ["/bin/ycode-bsp", "serve", "/p/App.xcodeproj"])
        #expect(json["languages"]?.array?.contains("objective-c") == true)
    }
}

/// The IDE side (`YcodeLanguage.BuildServerLaunch`) writes what the server
/// side reads.
@Suite struct BuildServerLaunchTests {
    @Test func connectionFileAgreesWithTheServer() throws {
        let argv = ["/x/ycode-bsp", "serve", "/p/App.xcodeproj", "--scheme", "App"]
        #expect(BuildServerLaunch.configJSON(argv: argv) == BuildServerConfigFile.json(argv: argv))
        #expect(BuildServerLaunch.argv(server: "/x/ycode-bsp", container: URL(fileURLWithPath: "/p/App.xcodeproj"), scheme: "App") == argv)
        #expect(BuildServerLaunch.initializationOptions["bypassWorkspaceTrust"] == true)
    }

    @Test func privateFolderAndLookup() throws {
        let dir = try freshScratch("launch")
        let env = ["HOME": dir.path, "XDG_CACHE_HOME": dir.appendingPathComponent("cache").path, "YCODE_BSP": "/bin/sh"]
        let project = URL(fileURLWithPath: "/p/My App.xcodeproj")
        let folder = BuildServerLaunch.workspaceFolder(for: project, environment: env)
        #expect(folder == BuildServerLaunch.workspaceFolder(for: project, environment: env))
        #expect(folder.lastPathComponent.hasPrefix("My_App-") && folder.path.hasPrefix(dir.path))
        #expect(folder != BuildServerLaunch.workspaceFolder(for: URL(fileURLWithPath: "/q/My App.xcodeproj"), environment: env))
        let prepared = try #require(BuildServerLaunch.prepareWorkspaceFolder(container: project, environment: env, defaults: .standard))
        let json = try JSON.decode(Data(contentsOf: prepared.appendingPathComponent(".bsp/ycode.json")))
        #expect(json["argv"]?.array?.first == "/bin/sh")
        // Lookup: next to the executable, then in Contents/Helpers.
        let app = dir.appendingPathComponent("Y.app/Contents")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
        let helper = app.appendingPathComponent("Helpers/ycode-bsp")
        FileManager.default.createFile(atPath: helper.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        #expect(BuildServerLaunch.locate(environment: [:], executableURL: app.appendingPathComponent("MacOS/Y")) == helper.path)
        #expect(BuildServerLaunch.locate(environment: ["PATH": "/nonexistent"], executableURL: nil) == nil)
    }
}
