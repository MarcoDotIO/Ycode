import Foundation
import YcodePlist
import YcodeProject
@testable import YcodeIDECore

/// The small iOS app project the project-editor tests open: a copy of the
/// fixture in YcodeIDECoreTests' `ProjectEditorReferenceTests`, which moved
/// there with the model tests.
struct ProjectEditorFixture {
    static let pbxproj = """
    // !$*UTF8*$!
    { archiveVersion = 1; classes = {}; objectVersion = 77; objects = {
    P1 = { isa = PBXProject; buildConfigurationList = PL; mainGroup = G1; targets = (T1); knownRegions = (en, Base); developmentRegion = en;
           attributes = { ORGANIZATIONNAME = Acme; BuildIndependentTargetsInParallel = 1; }; minimizedProjectReferenceProxies = 1; };
    G1 = { isa = PBXGroup; children = (); sourceTree = "<group>"; };
    PL = { isa = XCConfigurationList; buildConfigurations = (PD, PR); defaultConfigurationName = Release; };
    PD = { isa = XCBuildConfiguration; name = Debug; buildSettings = { SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 27.0; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; }; };
    PR = { isa = XCBuildConfiguration; name = Release; buildSettings = { SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 27.0; SWIFT_OPTIMIZATION_LEVEL = "-O"; }; };
    T1 = { isa = PBXNativeTarget; name = App; productType = "com.apple.product-type.application"; buildConfigurationList = TL;
           buildPhases = (S1, F1, R1); buildRules = (BR2, BR1); fileSystemSynchronizedGroups = (SG); dependencies = (); };
    SG = { isa = PBXFileSystemSynchronizedRootGroup; path = App; sourceTree = "<group>"; };
    S1 = { isa = PBXSourcesBuildPhase; files = (); };
    F1 = { isa = PBXFrameworksBuildPhase; files = (); };
    R1 = { isa = PBXResourcesBuildPhase; files = (); };
    BR1 = { isa = PBXBuildRule; name = Alpha; compilerSpec = com.apple.compilers.proxy.script; fileType = pattern.proxy; filePatterns = "*.foo"; };
    BR2 = { isa = PBXBuildRule; name = Beta; compilerSpec = com.example.tool; fileType = sourcecode.c.c; };
    TL = { isa = XCConfigurationList; buildConfigurations = (TD, TR); defaultConfigurationName = Release; };
    TD = { isa = XCBuildConfiguration; name = Debug; buildSettings = { SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; TARGETED_DEVICE_FAMILY = "1,2";
           SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = YES; SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD = YES; PRODUCT_NAME = App; MY_FLAG = 1; }; };
    TR = { isa = XCBuildConfiguration; name = Release; buildSettings = { SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; TARGETED_DEVICE_FAMILY = "1,2";
           SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = YES; SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD = YES; PRODUCT_NAME = App; MY_FLAG = 1; }; };
    }; rootObject = P1; }
    """

    func model() throws -> ProjectEditorModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-pe-ref-\(UUID().uuidString)")
        let app = dir.appendingPathComponent("App")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Assets.xcassets"), withIntermediateDirectories: true)
        for f in ["AppMain.swift", "ContentView.swift", "Readme.md", "data.json"] {
            try Data().write(to: app.appendingPathComponent(f))
        }
        let proj = dir.appendingPathComponent("App.xcodeproj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        return ProjectEditorModel(proj: try PBXProj(parsing: Self.pbxproj), xcodeprojURL: proj)
    }
}
