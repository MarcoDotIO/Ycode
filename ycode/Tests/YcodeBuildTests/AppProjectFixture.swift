import Foundation

/// A minimal macOS AppKit application project: one Swift file, a generated
/// Info.plist, and an asset catalog with one color. Hand-written from
/// `specs/formats/pbxproj.md`; IDs are arbitrary.
let appProjectText = """
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 77;
	objects = {
		B10000000000000000000001 = {isa = PBXBuildFile; fileRef = B10000000000000000000002; };
		B10000000000000000000002 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = main.swift; sourceTree = "<group>"; };
		B10000000000000000000003 = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = SmokeApp.app; sourceTree = BUILT_PRODUCTS_DIR; };
		B10000000000000000000004 = {isa = PBXGroup; children = (B10000000000000000000005, B10000000000000000000006); sourceTree = "<group>"; };
		B10000000000000000000005 = {isa = PBXGroup; children = (B10000000000000000000002, B10000000000000000000012); path = SmokeApp; sourceTree = "<group>"; };
		B10000000000000000000006 = {isa = PBXGroup; children = (B10000000000000000000003); name = Products; sourceTree = "<group>"; };
		B10000000000000000000007 = {isa = PBXNativeTarget; buildConfigurationList = B10000000000000000000008; buildPhases = (B10000000000000000000009, B10000000000000000000010, B10000000000000000000014); buildRules = (); dependencies = (); name = SmokeApp; productName = SmokeApp; productReference = B10000000000000000000003; productType = "com.apple.product-type.application"; };
		B10000000000000000000008 = {isa = XCConfigurationList; buildConfigurations = (B1000000000000000000000A, B1000000000000000000000B); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
		B10000000000000000000009 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (B10000000000000000000001); runOnlyForDeploymentPostprocessing = 0; };
		B10000000000000000000010 = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (B10000000000000000000011); runOnlyForDeploymentPostprocessing = 0; };
		B10000000000000000000011 = {isa = PBXBuildFile; fileRef = B10000000000000000000012; };
		B10000000000000000000012 = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; };
		B10000000000000000000014 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
		B1000000000000000000000A = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = org.ycode.SmokeApp; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_NSPrincipalClass = NSApplication; SWIFT_VERSION = 5.0; MARKETING_VERSION = 1.0; CURRENT_PROJECT_VERSION = 1; }; name = Debug; };
		B1000000000000000000000B = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = org.ycode.SmokeApp; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_NSPrincipalClass = NSApplication; SWIFT_VERSION = 5.0; MARKETING_VERSION = 1.0; CURRENT_PROJECT_VERSION = 1; }; name = Release; };
		B1000000000000000000000C = {isa = PBXProject; buildConfigurationList = B1000000000000000000000D; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = B10000000000000000000004; productRefGroup = B10000000000000000000006; preferredProjectObjectVersion = 77; projectDirPath = ""; projectRoot = ""; targets = (B10000000000000000000007); };
		B1000000000000000000000D = {isa = XCConfigurationList; buildConfigurations = (B1000000000000000000000E, B1000000000000000000000F); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
		B1000000000000000000000E = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; ONLY_ACTIVE_ARCH = YES; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; ALWAYS_SEARCH_USER_PATHS = NO; }; name = Debug; };
		B1000000000000000000000F = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; ALWAYS_SEARCH_USER_PATHS = NO; }; name = Release; };
	};
	rootObject = B1000000000000000000000C;
}

"""

/// With `--ycode-smoke` the app reports its bundle identifier and whether
/// the asset catalog's color loaded, then exits without showing UI.
let appSource = """
import AppKit

if CommandLine.arguments.contains("--ycode-smoke") {
    let id = Bundle.main.bundleIdentifier ?? "?"
    let color = NSColor(named: "Smoke") != nil
    print("launched \\(id) color=\\(color)")
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.run()

"""

let colorSetJSON = """
{
  "colors" : [ { "color" : { "color-space" : "srgb", "components" : { "red" : "0.2", "green" : "0.4", "blue" : "0.8", "alpha" : "1.0" } }, "idiom" : "universal" } ],
  "info" : { "author" : "ycode", "version" : 1 }
}

"""

func writeAppProject(at dir: URL) throws -> URL {
    let fm = FileManager.default
    try? fm.removeItem(at: dir)
    let proj = dir.appendingPathComponent("SmokeApp.xcodeproj")
    let src = dir.appendingPathComponent("SmokeApp")
    let colorSet = src.appendingPathComponent("Assets.xcassets/Smoke.colorset")
    try fm.createDirectory(at: proj, withIntermediateDirectories: true)
    try fm.createDirectory(at: colorSet, withIntermediateDirectories: true)
    try appProjectText.write(to: proj.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
    try appSource.write(to: src.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
    try "{\n  \"info\" : { \"author\" : \"ycode\", \"version\" : 1 }\n}\n"
        .write(to: src.appendingPathComponent("Assets.xcassets/Contents.json"), atomically: true, encoding: .utf8)
    try colorSetJSON.write(to: colorSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    return proj
}
