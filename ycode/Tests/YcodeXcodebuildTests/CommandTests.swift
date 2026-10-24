import Foundation
import Testing
@testable import YcodeXcodebuild

/// Expected texts come from specs/xcodebuild/ (black-box observations).
@Suite struct ListAndErrorTests {
    @Test func listText() throws {
        let proj = try writeMultiProject()
        let r = runTool(["-list"], cwd: proj.deletingLastPathComponent().path)
        #expect(r.code == 0)
        #expect(r.out == """
        Command line invocation:
            /usr/local/bin/ycodebuild -list

        Information about project "Multi":
            Targets:
                Lib
                App

            Build Configurations:
                Debug
                Release

            If no build configuration is specified and -scheme is not passed then "Debug" is used.

            Schemes:
                App
                Lib


        """)
    }

    @Test func listJSON() throws {
        let proj = try writeMultiProject()
        let r = runTool(["-list", "-json", "-project", "Multi.xcodeproj"], cwd: proj.deletingLastPathComponent().path)
        let obj = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: [String: Any]]
        #expect(obj?["project"]?["schemes"] as? [String] == ["App", "Lib"])
        #expect(obj?["project"]?["targets"] as? [String] == ["Lib", "App"])
        #expect(r.out.contains("\"name\" : \"Multi\""))
        #expect(!r.out.contains("Command line invocation"))
    }

    @Test func containerErrors() throws {
        let proj = try writeMultiProject()
        let dir = proj.deletingLastPathComponent().path
        var r = runTool(["-project", "Nope.xcodeproj", "-list"], cwd: dir)
        #expect(r.code == 66 && r.err == "xcodebuild: error: 'Nope.xcodeproj' does not exist.\n")
        #expect(r.out.hasPrefix("Command line invocation:\n"))
        r = runTool(["-project", "Multi.xcodeproj", "-workspace", "W.xcworkspace"], cwd: dir)
        #expect(r.code == 64 && r.out.isEmpty && r.err == "xcodebuild: error: You cannot specify both an Xcode project and a workspace.\n")
        r = runTool(["-showBuildSettings", "-target", "Nope"], cwd: dir)
        #expect(r.code == 65 && r.err == "xcodebuild: error: The project 'Multi.xcodeproj' does not contain a target named 'Nope'.\n")
        r = runTool(["-showBuildSettings", "-scheme", "Nope"], cwd: dir)
        #expect(r.code == 65 && r.err.hasPrefix("xcodebuild: error: The project named \"Multi\" does not contain a scheme named \"Nope\"."))
        r = runTool(["frob"], cwd: dir)
        #expect(r.code == 65 && r.err == "xcodebuild: error: Unknown build action 'frob'.\n")
        r = runTool(["-list"], cwd: FileManager.default.temporaryDirectory.appendingPathComponent("ycodebuild-empty-\(UUID())").path)
        #expect(r.code == 66 && r.err.contains("does not contain an Xcode project, workspace or package."))
        r = runTool(["-foo"], cwd: dir)
        #expect(r.code == 64 && r.err.hasPrefix("xcodebuild: error: invalid option '-foo'\n\nUsage: xcodebuild"))
        r = runTool(["-alltargets", "-target", "App", "-showBuildSettings"], cwd: dir)
        #expect(r.code == 64 && r.err == "xcodebuild: error: You cannot specify -alltargets and also specify individual targets.\n")
        r = runTool(["installsrc"], cwd: dir)
        #expect(r.code == 70 && r.err.contains("does not support the installsrc action yet"))
    }

    @Test func versionIsYcodes() {
        let r = runTool(["-version"], cwd: "/")
        #expect(r.code == 0 && r.out == "Ycode \(YcodeVersion.version)\nBuild version \(YcodeVersion.build)\n")
    }
}

@Suite struct ShowBuildSettingsFormatTests {
    @Test func textAndJSON() throws {
        let proj = try writeMultiProject(named: "My App")
        let dir = proj.deletingLastPathComponent().path
        let fake = FakeSettings(values: ["ZED": "z", "arch": "undefined_arch", "AAA": "", "PATH": "/bin"])
        var r = runTool(["-showBuildSettings", "-alltargets", "FOO=bar baz"], cwd: dir, settings: fake)
        #expect(r.code == 0)
        let blocks = r.out.components(separatedBy: "Build settings for action build and target ")
        // All targets, then the first again (observed).
        #expect(blocks.dropFirst().map { $0.prefix { $0 != ":" } } == ["Lib", "App", "Lib"])
        #expect(r.out.contains("    /usr/local/bin/ycodebuild -showBuildSettings -alltargets \"FOO=bar baz\"\n"))
        #expect(r.out.contains("Build settings from command line:\n    FOO = bar baz\n\n"))
        // Byte order: upper case before lower case; empty values keep "= ".
        #expect(r.out.contains("    AAA = \n    ACTION = build\n    CONFIGURATION = Debug\n    PATH = /bin\n    TARGET_NAME = Lib\n    ZED = z\n    arch = undefined_arch\n\n"))
        r = runTool(["-showBuildSettings", "-json", "-configuration", "Release"], cwd: dir, settings: fake)
        let list = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [[String: Any]]
        #expect(list?.count == 1 && list?.first?["target"] as? String == "Lib" && list?.first?["action"] as? String == "build")
        #expect((list?.first?["buildSettings"] as? [String: String])?["CONFIGURATION"] == "Release")
    }

    @Test func quotesTargetNames() {
        #expect(ShellQuote.quote("kleinian hybrid") == "\"kleinian hybrid\"")
        #expect(ShellQuote.quote("I=a,b") == "I=a,b")
        #expect(ShellQuote.quote("Q=a\\b") == "\"Q=a\\\\b\"")
        #expect(ShellQuote.quote("C=q\"r") == "\"C=q\\\"r\"")
        #expect(ShellQuote.quote("Z=é") == "Z=é")
        #expect(ShellQuote.quote("J=a:b") == "\"J=a:b\"")
    }

    @Test func unknownConfigurationWarns() throws {
        let proj = try writeMultiProject()
        let r = runTool(["-showBuildSettings", "-configuration", "Nope"], cwd: proj.deletingLastPathComponent().path)
        #expect(r.err == "--- xcodebuild: WARNING: Configuration Nope is not in the project. Building default configuration.\n\n")
        #expect(r.out.contains("CONFIGURATION = Debug"))
    }

    @Test func xcconfigListing() throws {
        let proj = try writeMultiProject()
        let r = runTool(["-showBuildSettings", "-xcconfig", "Base.xcconfig"], cwd: proj.deletingLastPathComponent().path)
        #expect(r.out.contains("Build settings from configuration file 'Base.xcconfig':\n    MY_BASE = base\n    WARNING_CFLAGS = -Wall\n\n"))
    }
}

@Suite struct PIFTests {
    @Test func guidsAndShape() throws {
        let proj = try writeMultiProject()
        let container = try ContainerLocator.loadProjectContainer(proj)
        let pif = XcodePIF(container: container)
        #expect(pif.workspaceGUID == MD5.hex("Multi"))
        let projectGUID = pif.projectGUID(container.projects[0])
        #expect(projectGUID == MD5.hex("Multi.xcodeproj"))
        let objects = pif.objects()
        #expect(objects.map { $0["type"] as? String } == ["workspace", "project", "target", "target"])
        let ws = objects[0]["contents"] as! [String: Any]
        #expect(ws["path"] as? String == proj.appendingPathComponent("project.xcworkspace").path)
        let app = objects[3]["contents"] as! [String: Any]
        #expect(app["guid"] as? String == projectGUID + MD5.hex("B10000000000000000000030"))
        #expect((app["dependencies"] as? [[String: Any]])?.first?["guid"] as? String == projectGUID + MD5.hex("B10000000000000000000020"))
        // The library product is linked by target reference.
        let phases = app["buildPhases"] as! [[String: Any]]
        let frameworks = phases.first { $0["type"] as? String == "com.apple.buildphase.frameworks" }!
        #expect((frameworks["buildFiles"] as? [[String: Any]])?.first?["targetReference"] as? String == projectGUID + MD5.hex("B10000000000000000000020"))
        // Synchronized folder: its C file joins the sources phase, the JSON
        // file nothing (no resources phase), nested folders become groups.
        let sources = phases.first { $0["type"] as? String == "com.apple.buildphase.sources" }!
        #expect((sources["buildFiles"] as? [[String: Any]])?.count == 2)
        let project = objects[1]["contents"] as! [String: Any]
        let tree = project["groupTree"] as! [String: Any]
        #expect(tree["name"] as? String == "Multi" && tree["path"] as? String == "")
        let extra = (tree["children"] as! [[String: Any]]).first { $0["path"] as? String == "Extra" }!
        #expect((extra["children"] as! [[String: Any]]).map { $0["type"] as? String } == ["file", "group"])
        let base = (project["buildConfigurations"] as! [[String: Any]])[0]["baseConfigurationFileReference"] as? String
        #expect(base == projectGUID + MD5.hex("B10000000000000000000008"))
        #expect(try JSONSerialization.jsonObject(with: pif.serialized()) is [Any])
    }

    @Test func derivedDataNames() {
        #expect(DerivedDataName.folder(name: "kleinian hybrid", path: "/x/kleinian hybrid.xcodeproj").hasPrefix("kleinian_hybrid-"))
        #expect(DerivedDataName.hash("/x").count == 28)
    }
}

@Suite struct SDKRegistryTests {
    /// A fake developer directory with SDK metadata files only.
    func makeDeveloperDirectory() throws -> String {
        let fm = FileManager.default
        let dev = fm.temporaryDirectory.appendingPathComponent("ycodebuild-dev-\(UUID().uuidString)")
        func platform(_ dir: String, name: String, description: String, version: String, sdk: String, canonical: String, display: String, alias: String?) throws {
            let p = dev.appendingPathComponent("Platforms/\(dir).platform")
            let sdks = p.appendingPathComponent("Developer/SDKs")
            try fm.createDirectory(at: sdks.appendingPathComponent(sdk + ".sdk/System/Library/CoreServices"), withIntermediateDirectories: true)
            let info: [String: Any] = ["Name": name, "Description": description, "Version": version]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: p.appendingPathComponent("Info.plist"))
            let settings: [String: Any] = ["CanonicalName": canonical, "DisplayName": display, "Version": version, "IsBaseSDK": "YES"]
            try JSONSerialization.data(withJSONObject: settings).write(to: sdks.appendingPathComponent(sdk + ".sdk/SDKSettings.json"))
            let sv: [String: Any] = ["ProductName": description, "ProductVersion": version, "BuildID": "B"]
            try PropertyListSerialization.data(fromPropertyList: sv, format: .xml, options: 0)
                .write(to: sdks.appendingPathComponent(sdk + ".sdk/System/Library/CoreServices/SystemVersion.plist"))
            if let alias { try fm.createSymbolicLink(atPath: sdks.appendingPathComponent(alias + ".sdk").path, withDestinationPath: sdk + ".sdk") }
        }
        try platform("MacOSX", name: "macosx", description: "macOS", version: "27.0", sdk: "MacOSX", canonical: "macosx27.0", display: "macOS 27.0", alias: "MacOSX27.0")
        try platform("iPhoneOS", name: "iphoneos", description: "iOS", version: "27.1", sdk: "iPhoneOS", canonical: "iphoneos27.1", display: "iOS 27.1", alias: "iPhoneOS27.1")
        try platform("DriverKit", name: "driverkit", description: "DriverKit", version: "27.0", sdk: "DriverKit", canonical: "driverkit27.0", display: "DriverKit 27.0", alias: nil)
        return dev.path
    }

    @Test func showsdksAndVersion() throws {
        let dev = try makeDeveloperDirectory()
        var r = runTool(["-showsdks"], cwd: "/", developerDirectory: dev)
        #expect(r.out == "DriverKit SDKs:\n\tDriverKit 27.0                \t-sdk driverkit27.0\n\niOS SDKs:\n\tiOS 27.1                      \t-sdk iphoneos27.1\n\nmacOS SDKs:\n\tmacOS 27.0                    \t-sdk macosx27.0\n\n")
        r = runTool(["-version", "-sdk", "macosx"], cwd: "/", developerDirectory: dev)
        #expect(r.out.hasPrefix("MacOSX27.0.sdk - macOS 27.0 (macosx27.0)\nSDKVersion: 27.0\nPath: \(dev)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk\nPlatformVersion: 27.0\n"))
        #expect(r.out.hasSuffix("BuildID: B\nProductName: macOS\nProductVersion: 27.0\n\n"))
        r = runTool(["-version", "-sdk", "iphoneos", "SDKVersion"], cwd: "/", developerDirectory: dev)
        #expect(r.out == "27.1\n")
        r = runTool(["-version", "-sdk", "nosuch"], cwd: "/", developerDirectory: dev)
        #expect(r.code == 64 && r.err == "xcodebuild: error: SDK \"nosuch\" cannot be located.\n")
        r = runTool(["-showsdks", "-json"], cwd: "/", developerDirectory: dev)
        let list = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as! [[String: Any]]
        #expect(list.map { $0["canonicalName"] as? String } == ["driverkit27.0", "iphoneos27.1", "macosx27.0"])
        #expect(list[2]["isBaseSdk"] as? Bool == true && list[2]["buildID"] as? String == "B" && list[2]["productName"] as? String == "macOS")
    }
}

@Suite struct BuildLogTests {
    func log(_ messages: [[String: Any]], quiet: Bool = false, ok: Bool) -> (String, String, Bool) {
        let capture = CapturingConsole()
        var log = BuildLog(quiet: quiet, console: capture.console, schemeName: "Tool", projectName: "Tool")
        for m in messages { log.handle(m) }
        log.handle(["kind": "buildCompleted", "result": ok ? "ok" : "failed"])
        let success = log.finish(action: .build)
        return (capture.stdout, capture.stderr, success)
    }

    let stream: [[String: Any]] = [
        ["kind": "taskStarted", "id": 1, "ruleInfo": "ComputeTargetDependencyGraph"],
        ["kind": "note", "message": "Target dependency graph (1 target)", "locationContext": ["locationType": "globalTask", "taskID": 1],
         "childDiagnostics": [["kind": "note", "message": "Target 'Tool' in project 'Tool' (no dependencies)"]]],
        ["kind": "taskComplete", "id": 1, "result": "success"],
        ["kind": "targetStarted", "id": 0, "name": "Tool", "projectName": "Tool"],
        ["kind": "taskStarted", "id": 2, "targetID": 0, "ruleInfo": "CompileC /o/main.o /s/main.c normal arm64 c com.apple.compilers.llvm.clang.1_0.compiler",
         "commandLineDisplayString": "    cd /s\n    clang -c /s/main.c\n"],
        ["kind": "taskOutput", "taskID": 2, "data": "/s/main.c:1:1: error: boom\n"],
        ["kind": "error", "message": "boom", "location": ["locationType": "path", "path": "/s/main.c", "line": 1, "column": 1],
         "locationContext": ["locationType": "task", "taskID": 2]],
        ["kind": "taskComplete", "id": 2, "result": "failed"],
        ["kind": "warning", "message": "target warning", "locationContext": ["locationType": "target", "targetID": 0]],
    ]

    @Test func fullLog() {
        let (out, err, ok) = log(stream, ok: false)
        #expect(!ok)
        #expect(out == """
        ComputeTargetDependencyGraph
        note: Target dependency graph (1 target)
            Target 'Tool' in project 'Tool' (no dependencies)

        CompileC /o/main.o /s/main.c normal arm64 c com.apple.compilers.llvm.clang.1_0.compiler (in target 'Tool' from project 'Tool')
            cd /s
            clang -c /s/main.c
        /s/main.c:1:1: error: boom

        warning: target warning (in target 'Tool' from project 'Tool')

        """)
        #expect(err == "** BUILD FAILED **\n\n\nThe following build commands failed:\n\tCompileC /o/main.o /s/main.c normal arm64 c com.apple.compilers.llvm.clang.1_0.compiler (in target 'Tool' from project 'Tool')\n\tBuilding project Tool with scheme Tool\n(2 failures)\n")
    }

    @Test func quietLog() {
        let (out, err, _) = log(stream, quiet: true, ok: false)
        #expect(out == "/s/main.c:1:1: error: boom\nwarning: target warning (in target 'Tool' from project 'Tool')\n")
        #expect(err == "** BUILD FAILED **\n\n")
        let (out2, err2, ok2) = log([], quiet: false, ok: true)
        #expect(ok2 && out2 == "** BUILD SUCCEEDED **\n\n" && err2.isEmpty)
    }
}
