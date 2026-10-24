import Foundation

/// A project with three targets: a static library `Core`, a framework
/// `Kit`, and a tool `Tool` that depends on both and links `libCore.a`.
/// Hand-written from `specs/formats/pbxproj.md`; IDs are arbitrary.
let multiProjectText = """
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 77;
	objects = {
		C1000000000000000000F001 = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.c; path = core.c; sourceTree = "<group>"; };
		C1000000000000000000F002 = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.c; path = kit.c; sourceTree = "<group>"; };
		C1000000000000000000F003 = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.c; path = main.c; sourceTree = "<group>"; };
		C1000000000000000000P001 = {isa = PBXFileReference; explicitFileType = archive.ar; includeInIndex = 0; path = libCore.a; sourceTree = BUILT_PRODUCTS_DIR; };
		C1000000000000000000P002 = {isa = PBXFileReference; explicitFileType = wrapper.framework; includeInIndex = 0; path = Kit.framework; sourceTree = BUILT_PRODUCTS_DIR; };
		C1000000000000000000P003 = {isa = PBXFileReference; explicitFileType = "compiled.mach-o.executable"; includeInIndex = 0; path = Tool; sourceTree = BUILT_PRODUCTS_DIR; };
		C1000000000000000000B001 = {isa = PBXBuildFile; fileRef = C1000000000000000000F001; };
		C1000000000000000000B002 = {isa = PBXBuildFile; fileRef = C1000000000000000000F002; };
		C1000000000000000000B003 = {isa = PBXBuildFile; fileRef = C1000000000000000000F003; };
		C1000000000000000000B004 = {isa = PBXBuildFile; fileRef = C1000000000000000000P001; };
		C1000000000000000000G000 = {isa = PBXGroup; children = (C1000000000000000000G001, C1000000000000000000G002); sourceTree = "<group>"; };
		C1000000000000000000G001 = {isa = PBXGroup; children = (C1000000000000000000F001, C1000000000000000000F002, C1000000000000000000F003); path = Sources; sourceTree = "<group>"; };
		C1000000000000000000G002 = {isa = PBXGroup; children = (C1000000000000000000P001, C1000000000000000000P002, C1000000000000000000P003); name = Products; sourceTree = "<group>"; };
		C1000000000000000000S001 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (C1000000000000000000B001); runOnlyForDeploymentPostprocessing = 0; };
		C1000000000000000000S002 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (C1000000000000000000B002); runOnlyForDeploymentPostprocessing = 0; };
		C1000000000000000000S003 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (C1000000000000000000B003); runOnlyForDeploymentPostprocessing = 0; };
		C1000000000000000000S004 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (C1000000000000000000B004); runOnlyForDeploymentPostprocessing = 0; };
		C1000000000000000000D001 = {isa = PBXTargetDependency; target = C1000000000000000000T001; targetProxy = C1000000000000000000X001; };
		C1000000000000000000D002 = {isa = PBXTargetDependency; target = C1000000000000000000T002; targetProxy = C1000000000000000000X002; };
		C1000000000000000000X001 = {isa = PBXContainerItemProxy; containerPortal = C1000000000000000000R000; proxyType = 1; remoteGlobalIDString = C1000000000000000000T001; remoteInfo = Core; };
		C1000000000000000000X002 = {isa = PBXContainerItemProxy; containerPortal = C1000000000000000000R000; proxyType = 1; remoteGlobalIDString = C1000000000000000000T002; remoteInfo = Kit; };
		C1000000000000000000T001 = {isa = PBXNativeTarget; buildConfigurationList = C1000000000000000000L001; buildPhases = (C1000000000000000000S001); buildRules = (); dependencies = (); name = Core; productName = Core; productReference = C1000000000000000000P001; productType = "com.apple.product-type.library.static"; };
		C1000000000000000000T002 = {isa = PBXNativeTarget; buildConfigurationList = C1000000000000000000L002; buildPhases = (C1000000000000000000S002); buildRules = (); dependencies = (); name = Kit; productName = Kit; productReference = C1000000000000000000P002; productType = "com.apple.product-type.framework"; };
		C1000000000000000000T003 = {isa = PBXNativeTarget; buildConfigurationList = C1000000000000000000L003; buildPhases = (C1000000000000000000S003, C1000000000000000000S004); buildRules = (); dependencies = (C1000000000000000000D001, C1000000000000000000D002); name = Tool; productName = Tool; productReference = C1000000000000000000P003; productType = "com.apple.product-type.tool"; };
		C1000000000000000000L001 = {isa = XCConfigurationList; buildConfigurations = (C1000000000000000000C011, C1000000000000000000C012); defaultConfigurationName = Release; };
		C1000000000000000000L002 = {isa = XCConfigurationList; buildConfigurations = (C1000000000000000000C021, C1000000000000000000C022); defaultConfigurationName = Release; };
		C1000000000000000000L003 = {isa = XCConfigurationList; buildConfigurations = (C1000000000000000000C031, C1000000000000000000C032); defaultConfigurationName = Release; };
		C1000000000000000000L000 = {isa = XCConfigurationList; buildConfigurations = (C1000000000000000000C001, C1000000000000000000C002); defaultConfigurationName = Release; };
		C1000000000000000000C011 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; }; name = Debug; };
		C1000000000000000000C012 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; }; name = Release; };
		C1000000000000000000C021 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = org.ycode.Kit; GENERATE_INFOPLIST_FILE = YES; }; name = Debug; };
		C1000000000000000000C022 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = org.ycode.Kit; GENERATE_INFOPLIST_FILE = YES; }; name = Release; };
		C1000000000000000000C031 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; }; name = Debug; };
		C1000000000000000000C032 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; }; name = Release; };
		C1000000000000000000C001 = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; ONLY_ACTIVE_ARCH = YES; ALWAYS_SEARCH_USER_PATHS = NO; }; name = Debug; };
		C1000000000000000000C002 = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; ALWAYS_SEARCH_USER_PATHS = NO; }; name = Release; };
		C1000000000000000000R000 = {isa = PBXProject; buildConfigurationList = C1000000000000000000L000; developmentRegion = en; knownRegions = (en, Base); mainGroup = C1000000000000000000G000; productRefGroup = C1000000000000000000G002; projectDirPath = ""; projectRoot = ""; targets = (C1000000000000000000T001, C1000000000000000000T002, C1000000000000000000T003); };
	};
	rootObject = C1000000000000000000R000;
}

"""

func writeMultiProject(at dir: URL) throws -> URL {
    let fm = FileManager.default
    try? fm.removeItem(at: dir)
    let proj = dir.appendingPathComponent("Multi.xcodeproj")
    let src = dir.appendingPathComponent("Sources")
    try fm.createDirectory(at: proj, withIntermediateDirectories: true)
    try fm.createDirectory(at: src, withIntermediateDirectories: true)
    try multiProjectText.write(to: proj.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
    try "int core_value(void) { return 42; }\n".write(to: src.appendingPathComponent("core.c"), atomically: true, encoding: .utf8)
    try "int kit_value(void) { return 7; }\n".write(to: src.appendingPathComponent("kit.c"), atomically: true, encoding: .utf8)
    try "#include <stdio.h>\nint core_value(void);\nint main(void) { printf(\"core=%d\\n\", core_value()); return 0; }\n"
        .write(to: src.appendingPathComponent("main.c"), atomically: true, encoding: .utf8)
    return proj
}

/// A workspace holding the multi-target project and the app project.
func writeWorkspace(at dir: URL) throws -> URL {
    let fm = FileManager.default
    try? fm.removeItem(at: dir)
    _ = try writeMultiProject(at: dir.appendingPathComponent("Multi"))
    _ = try writeAppProject(at: dir.appendingPathComponent("App"))
    let ws = dir.appendingPathComponent("Both.xcworkspace")
    try fm.createDirectory(at: ws, withIntermediateDirectories: true)
    try """
    <?xml version="1.0" encoding="UTF-8"?>
    <Workspace
       version = "1.0">
       <FileRef
          location = "group:Multi/Multi.xcodeproj">
       </FileRef>
       <FileRef
          location = "group:App/SmokeApp.xcodeproj">
       </FileRef>
    </Workspace>

    """.write(to: ws.appendingPathComponent("contents.xcworkspacedata"), atomically: true, encoding: .utf8)
    return ws
}
