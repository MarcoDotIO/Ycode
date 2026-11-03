import Foundation
import Testing
import YcodeBuild
import YcodeWorkspace
@testable import YcodeIDECore

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Build requests an engine was asked for.
final class RecordedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [BuildRequest] = []
    var all: [BuildRequest] { lock.lock(); defer { lock.unlock() }; return list }
    func append(_ r: BuildRequest) { lock.lock(); list.append(r); lock.unlock() }
}

/// An engine that records each request and succeeds.
struct RecordingEngine: BuildEngine {
    let box: RecordedRequests
    var name: String { "recording" }
    func start(_ request: BuildRequest) -> BuildOperation {
        box.append(request)
        let (s, c) = AsyncStream<BuildEvent>.makeStream()
        c.yield(.output("built"))
        c.yield(.finished(BuildResult(status: .succeeded, exitCode: 0, issues: [])))
        c.finish()
        return BuildOperation(events: s, cancel: {})
    }
}

/// A hand-written macOS command-line tool project: main.swift uses a type
/// from Greeter.swift; one shared scheme with two test plans.
func writeToolProject(at dir: URL) throws -> URL {
    let fm = FileManager.default
    try? fm.removeItem(at: dir)
    func write(_ rel: String, _ text: String) throws {
        let u = dir.appendingPathComponent(rel)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }
    try write("Tool/main.swift", "print(Greeter(name: \"tool\").line)\n")
    try write("Tool/Greeter.swift", "struct Greeter {\n    var name: String\n    var line: String { \"hello, \\(name)\" }\n}\n")
    try write("Tool/util.c", "#define TWICE(x) ((x) * 2)\nint twice(int v) { return TWICE(v); }\n")
    try write("Tool.xcodeproj/project.pbxproj", """
    // !$*UTF8*$!
    {
    	archiveVersion = 1;
    	classes = {
    	};
    	objectVersion = 77;
    	objects = {
    		C10000000000000000000001 = {isa = PBXBuildFile; fileRef = C10000000000000000000002; };
    		C10000000000000000000002 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = main.swift; sourceTree = "<group>"; };
    		C10000000000000000000003 = {isa = PBXFileReference; explicitFileType = "compiled.mach-o.executable"; includeInIndex = 0; path = Tool; sourceTree = BUILT_PRODUCTS_DIR; };
    		C10000000000000000000004 = {isa = PBXGroup; children = (C10000000000000000000005, C10000000000000000000006); sourceTree = "<group>"; };
    		C10000000000000000000005 = {isa = PBXGroup; children = (C10000000000000000000002, C10000000000000000000012, C10000000000000000000014); path = Tool; sourceTree = "<group>"; };
    		C10000000000000000000006 = {isa = PBXGroup; children = (C10000000000000000000003); name = Products; sourceTree = "<group>"; };
    		C10000000000000000000007 = {isa = PBXNativeTarget; buildConfigurationList = C10000000000000000000008; buildPhases = (C10000000000000000000009); buildRules = (); dependencies = (); name = Tool; productName = Tool; productReference = C10000000000000000000003; productType = "com.apple.product-type.tool"; };
    		C10000000000000000000008 = {isa = XCConfigurationList; buildConfigurations = (C1000000000000000000000A, C1000000000000000000000B); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
    		C10000000000000000000009 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (C10000000000000000000001, C10000000000000000000011, C10000000000000000000013); runOnlyForDeploymentPostprocessing = 0; };
    		C10000000000000000000011 = {isa = PBXBuildFile; fileRef = C10000000000000000000012; };
    		C10000000000000000000012 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Greeter.swift; sourceTree = "<group>"; };
    		C10000000000000000000013 = {isa = PBXBuildFile; fileRef = C10000000000000000000014; };
    		C10000000000000000000014 = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.c; path = util.c; sourceTree = "<group>"; };
    		C1000000000000000000000A = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; SWIFT_VERSION = 5.0; SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)"; }; name = Debug; };
    		C1000000000000000000000B = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; SWIFT_VERSION = 5.0; }; name = Release; };
    		C1000000000000000000000C = {isa = PBXProject; buildConfigurationList = C1000000000000000000000D; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = C10000000000000000000004; productRefGroup = C10000000000000000000006; preferredProjectObjectVersion = 77; projectDirPath = ""; projectRoot = ""; targets = (C10000000000000000000007); };
    		C1000000000000000000000D = {isa = XCConfigurationList; buildConfigurations = (C1000000000000000000000E, C1000000000000000000000F); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
    		C1000000000000000000000E = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; }; name = Debug; };
    		C1000000000000000000000F = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; }; name = Release; };
    	};
    	rootObject = C1000000000000000000000C;
    }

    """)
    try write("Tool.xcodeproj/xcshareddata/xcschemes/Tool.xcscheme", """
    <?xml version="1.0" encoding="UTF-8"?>
    <Scheme
       LastUpgradeVersion = "2600"
       version = "1.7">
       <BuildAction
          parallelizeBuildables = "YES"
          buildImplicitDependencies = "YES">
       </BuildAction>
       <TestAction
          buildConfiguration = "Debug"
          selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
          selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
          shouldUseLaunchSchemeArgsEnv = "YES">
          <TestPlans>
             <TestPlanReference
                reference = "container:Smoke.xctestplan"
                default = "YES">
             </TestPlanReference>
             <TestPlanReference
                reference = "container:Full.xctestplan">
             </TestPlanReference>
          </TestPlans>
       </TestAction>
       <LaunchAction
          buildConfiguration = "Debug">
       </LaunchAction>
       <ProfileAction
          buildConfiguration = "Release">
       </ProfileAction>
       <AnalyzeAction
          buildConfiguration = "Debug">
       </AnalyzeAction>
       <ArchiveAction
          buildConfiguration = "Release"
          revealArchiveInOrganizer = "YES">
       </ArchiveAction>
    </Scheme>

    """)
    return dir.appendingPathComponent("Tool.xcodeproj")
}

/// A shell script standing in for `swift`: records its arguments, then
/// prints `output`.
func fakeTool(at url: URL, record: URL, output: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "#!/bin/sh\necho \"$@\" >> '\(record.path)'\ncat <<'EOF'\n\(output)\nEOF\n".write(to: url, atomically: true, encoding: .utf8)
}

@MainActor
@Suite(.serialized) struct ProductActionsR36Tests {
    func scratch(_ name: String) -> URL {
        ycodeDir.appendingPathComponent(".build-ide/r36/\(name)-\(UUID().uuidString)")
    }

    /// Build For ▸ Running / Profiling build the scheme with the Run and
    /// Profile actions' configurations; Build For ▸ Testing builds the
    /// tests with the test tool.
    @Test func buildForPurposes() async throws {
        let dir = scratch("build-for")
        defer { try? FileManager.default.removeItem(at: dir) }
        let proj = try writeToolProject(at: dir)
        let session = WorkspaceSession(model: try WorkspaceModel(url: proj))
        let box = RecordedRequests()
        session.engine = RecordingEngine(box: box)
        #expect(await session.buildFor(.running).status == .succeeded)
        #expect(await session.buildFor(.profiling).status == .succeeded)
        #expect(box.all.map(\.configuration) == ["Debug", "Release"] && box.all.allSatisfy { $0.action == .build && $0.scheme == "Tool" })
        #expect(session.activity == .finished("Build Succeeded"))
        #expect(session.reports.first?.title == "Build Tool")

        // Testing: the test tool's build-for-testing, its issues shown.
        let record = dir.appendingPathComponent("args.txt"), tool = dir.appendingPathComponent("xcodebuild.sh")
        try fakeTool(at: tool, record: record, output: "\(dir.path)/Tool/main.swift:1:1: warning: careful\n** TEST BUILD SUCCEEDED **")
        session.testRunner.xcodebuild = ["/bin/sh", tool.path]
        let r = await session.buildFor(.testing)
        #expect(r.status == .succeeded && box.all.count == 2)
        let args = try String(contentsOf: record, encoding: .utf8)
        #expect(args.contains("-scheme Tool") && args.contains("-configuration Debug") && args.hasSuffix("build-for-testing\n"))
        #expect(session.issues.map(\.message) == ["careful"])
    }

    /// The file's module context for a project: the target's module name,
    /// its Swift files, its settings.
    @Test func fileContextFromTheProject() throws {
        let dir = scratch("ctx")
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = WorkspaceSession(model: try WorkspaceModel(url: try writeToolProject(at: dir)))
        session.destination = .myMac
        let main = dir.appendingPathComponent("Tool/main.swift").standardizedFileURL.path
        let ctx = session.fileBuildContext(for: main)
        #expect(ctx.moduleName == "Tool")
        #expect(ctx.moduleSources.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted() == ["Greeter.swift", "main.swift"])
        #expect(ctx.swiftVersion == "5.0" && ctx.defines == ["DEBUG"])
        #expect(ctx.targetTriple == "\(SwiftBuildEngine.hostArchitecture)-apple-macosx15.0")
        #if os(macOS)
        // The SDK comes from `xcrun`, which exists only on macOS.
        #expect(ctx.sdkPath?.contains("MacOSX") == true)
        #endif
    }
}
