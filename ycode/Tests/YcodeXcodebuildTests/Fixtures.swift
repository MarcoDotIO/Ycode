import Foundation
@testable import YcodeXcodebuild

/// A hand-written project: a static library and a tool that links it, the
/// project based on an xcconfig. IDs are arbitrary.
let multiProjectText = """
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 77;
	objects = {
		B10000000000000000000001 = {isa = PBXBuildFile; fileRef = B10000000000000000000002; };
		B10000000000000000000002 = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.c; path = lib.c; sourceTree = "<group>"; };
		B10000000000000000000003 = {isa = PBXFileReference; explicitFileType = archive.ar; includeInIndex = 0; path = libLib.a; sourceTree = BUILT_PRODUCTS_DIR; };
		B10000000000000000000004 = {isa = PBXBuildFile; fileRef = B10000000000000000000005; };
		B10000000000000000000005 = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.c; path = main.c; sourceTree = "<group>"; };
		B10000000000000000000006 = {isa = PBXFileReference; explicitFileType = "compiled.mach-o.executable"; includeInIndex = 0; path = App; sourceTree = BUILT_PRODUCTS_DIR; };
		B10000000000000000000007 = {isa = PBXBuildFile; fileRef = B10000000000000000000003; };
		B10000000000000000000008 = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Base.xcconfig; sourceTree = "<group>"; };
		B10000000000000000000010 = {isa = PBXGroup; children = (B10000000000000000000008, B10000000000000000000011, B10000000000000000000012, B10000000000000000000013, B10000000000000000000050); sourceTree = "<group>"; };
		B10000000000000000000011 = {isa = PBXGroup; children = (B10000000000000000000002); path = Lib; sourceTree = "<group>"; };
		B10000000000000000000012 = {isa = PBXGroup; children = (B10000000000000000000005); path = App; sourceTree = "<group>"; };
		B10000000000000000000013 = {isa = PBXGroup; children = (B10000000000000000000003, B10000000000000000000006); name = Products; sourceTree = "<group>"; };
		B10000000000000000000020 = {isa = PBXNativeTarget; buildConfigurationList = B10000000000000000000021; buildPhases = (B10000000000000000000022); buildRules = (); dependencies = (); name = Lib; productName = Lib; productReference = B10000000000000000000003; productType = "com.apple.product-type.library.static"; };
		B10000000000000000000021 = {isa = XCConfigurationList; buildConfigurations = (B10000000000000000000023, B10000000000000000000024); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
		B10000000000000000000022 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (B10000000000000000000001); runOnlyForDeploymentPostprocessing = 0; };
		B10000000000000000000023 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; }; name = Debug; };
		B10000000000000000000024 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; }; name = Release; };
		B10000000000000000000030 = {isa = PBXNativeTarget; buildConfigurationList = B10000000000000000000031; buildPhases = (B10000000000000000000032, B10000000000000000000035); buildRules = (); dependencies = (B10000000000000000000036); fileSystemSynchronizedGroups = (B10000000000000000000050); name = App; productName = App; productReference = B10000000000000000000006; productType = "com.apple.product-type.tool"; };
		B10000000000000000000031 = {isa = XCConfigurationList; buildConfigurations = (B10000000000000000000033, B10000000000000000000034); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
		B10000000000000000000032 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (B10000000000000000000004); runOnlyForDeploymentPostprocessing = 0; };
		B10000000000000000000033 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; }; name = Debug; };
		B10000000000000000000034 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; }; name = Release; };
		B10000000000000000000035 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (B10000000000000000000007); runOnlyForDeploymentPostprocessing = 0; };
		B10000000000000000000036 = {isa = PBXTargetDependency; target = B10000000000000000000020; targetProxy = B10000000000000000000037; };
		B10000000000000000000037 = {isa = PBXContainerItemProxy; containerPortal = B10000000000000000000040; proxyType = 1; remoteGlobalIDString = B10000000000000000000020; remoteInfo = Lib; };
		B10000000000000000000040 = {isa = PBXProject; buildConfigurationList = B10000000000000000000041; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = B10000000000000000000010; productRefGroup = B10000000000000000000013; preferredProjectObjectVersion = 77; projectDirPath = ""; projectRoot = ""; targets = (B10000000000000000000020, B10000000000000000000030); };
		B10000000000000000000041 = {isa = XCConfigurationList; buildConfigurations = (B10000000000000000000042, B10000000000000000000043); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
		B10000000000000000000042 = {isa = XCBuildConfiguration; baseConfigurationReference = B10000000000000000000008; buildSettings = {SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; ONLY_ACTIVE_ARCH = YES; }; name = Debug; };
		B10000000000000000000043 = {isa = XCBuildConfiguration; baseConfigurationReference = B10000000000000000000008; buildSettings = {SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; }; name = Release; };
		B10000000000000000000050 = {isa = PBXFileSystemSynchronizedRootGroup; path = Extra; sourceTree = "<group>"; };
	};
	rootObject = B10000000000000000000040;
}

"""

/// Writes the project (and its sources) into a fresh directory.
func writeMultiProject(named name: String = "Multi") throws -> URL {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("ycodebuild-tests-\(UUID().uuidString)")
    let proj = dir.appendingPathComponent("\(name).xcodeproj")
    try fm.createDirectory(at: proj, withIntermediateDirectories: true)
    for sub in ["Lib", "App", "Extra/Nested"] { try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true) }
    try multiProjectText.write(to: proj.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
    try "int lib_value(void) { return 42; }\n".write(to: dir.appendingPathComponent("Lib/lib.c"), atomically: true, encoding: .utf8)
    try "int main(void) { return 0; }\n".write(to: dir.appendingPathComponent("App/main.c"), atomically: true, encoding: .utf8)
    try "int extra(void) { return 1; }\n".write(to: dir.appendingPathComponent("Extra/extra.c"), atomically: true, encoding: .utf8)
    try "{}\n".write(to: dir.appendingPathComponent("Extra/Nested/data.json"), atomically: true, encoding: .utf8)
    try "WARNING_CFLAGS = -Wall // trailing comment\nMY_BASE = base;\n".write(to: dir.appendingPathComponent("Base.xcconfig"), atomically: true, encoding: .utf8)
    return proj
}

/// Settings without swift-build, for formatting tests.
struct FakeSettings: SettingsProvider {
    var values: [String: String]
    func settings(container: Container, targets: [SettingsTarget], parameters: BuildParameters) throws -> [[String: String]] {
        targets.map { t in values.merging(["TARGET_NAME": t.name, "CONFIGURATION": parameters.configuration, "ACTION": parameters.action]) { $1 } }
    }
}

func runTool(_ args: [String], cwd: String, settings: SettingsProvider? = FakeSettings(values: [:]),
             developerDirectory: String? = nil) -> (out: String, err: String, code: Int32) {
    let capture = CapturingConsole()
    let ctx = XcodebuildContext(cwd: cwd, environment: [:], toolPath: "/usr/local/bin/ycodebuild", developerDirectory: developerDirectory,
                                home: "/Users/tester", user: "tester", hostArchitecture: "arm64", console: capture.console,
                                settingsProvider: settings)
    let code = Xcodebuild.run(args, context: ctx)
    return (capture.stdout, capture.stderr, code)
}
