import Foundation
import Testing
import YcodeProject
@testable import YcodeBuild

/// A minimal pbxproj: one macOS command-line tool target with one C file.
/// Written by hand from `specs/formats/pbxproj.md`; IDs are arbitrary.
let toolProjectText = """
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 77;
	objects = {
		A10000000000000000000001 = {isa = PBXBuildFile; fileRef = A10000000000000000000002; };
		A10000000000000000000002 = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.c; path = main.c; sourceTree = "<group>"; };
		A10000000000000000000003 = {isa = PBXFileReference; explicitFileType = "compiled.mach-o.executable"; includeInIndex = 0; path = Tool; sourceTree = BUILT_PRODUCTS_DIR; };
		A10000000000000000000004 = {isa = PBXGroup; children = (A10000000000000000000005, A10000000000000000000006); sourceTree = "<group>"; };
		A10000000000000000000005 = {isa = PBXGroup; children = (A10000000000000000000002); path = Tool; sourceTree = "<group>"; };
		A10000000000000000000006 = {isa = PBXGroup; children = (A10000000000000000000003); name = Products; sourceTree = "<group>"; };
		A10000000000000000000007 = {isa = PBXNativeTarget; buildConfigurationList = A10000000000000000000008; buildPhases = (A10000000000000000000009); buildRules = (); dependencies = (); name = Tool; productName = Tool; productReference = A10000000000000000000003; productType = "com.apple.product-type.tool"; };
		A10000000000000000000008 = {isa = XCConfigurationList; buildConfigurations = (A1000000000000000000000A, A1000000000000000000000B); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
		A10000000000000000000009 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A10000000000000000000001); runOnlyForDeploymentPostprocessing = 0; };
		A1000000000000000000000A = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; }; name = Debug; };
		A1000000000000000000000B = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; }; name = Release; };
		A1000000000000000000000C = {isa = PBXProject; buildConfigurationList = A1000000000000000000000D; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = A10000000000000000000004; productRefGroup = A10000000000000000000006; preferredProjectObjectVersion = 77; projectDirPath = ""; projectRoot = ""; targets = (A10000000000000000000007); };
		A1000000000000000000000D = {isa = XCConfigurationList; buildConfigurations = (A1000000000000000000000E, A1000000000000000000000F); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
		A1000000000000000000000E = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; ONLY_ACTIVE_ARCH = YES; GCC_OPTIMIZATION_LEVEL = 0; }; name = Debug; };
		A1000000000000000000000F = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; }; name = Release; };
	};
	rootObject = A1000000000000000000000C;
}

"""

let toolSource = """
#include <stdio.h>
int main(void) { printf("hello from swift-build\\n"); return 0; }

"""

/// Writes the tool project under `dir` and returns the `.xcodeproj` URL.
func writeToolProject(at dir: URL, source: String = toolSource) throws -> URL {
    let fm = FileManager.default
    try? fm.removeItem(at: dir)
    let proj = dir.appendingPathComponent("Tool.xcodeproj")
    try fm.createDirectory(at: proj, withIntermediateDirectories: true)
    try fm.createDirectory(at: dir.appendingPathComponent("Tool"), withIntermediateDirectories: true)
    try toolProjectText.write(to: proj.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
    try source.write(to: dir.appendingPathComponent("Tool/main.c"), atomically: true, encoding: .utf8)
    return proj
}

let ideScratch = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent(".build-ide")

@Suite struct PIFGeneratorTests {
    @Test func toolTargetPIF() throws {
        let projURL = try writeToolProject(at: ideScratch.appendingPathComponent("pif-unit"))
        let proj = try PBXProj(contentsOf: projURL)
        let pif = try PIFGenerator(proj: proj, xcodeprojURL: projURL).pif()
        let objects = try #require(pif.arrayValue)
        #expect(objects.map { $0["type"]?.stringValue } == ["workspace", "project", "target"])
        let project = try #require(objects[1]["contents"])
        #expect(project["projectIsPackage"] == "false")
        #expect(project["defaultConfigurationName"] == "Release")
        #expect(project["groupTree"]?["sourceTree"] == "<group>" && project["groupTree"]?["name"] == "Tool")
        let toolGroup = try #require(project["groupTree"]?["children"]?.arrayValue?.first)
        #expect(toolGroup["path"] == "Tool")
        #expect(toolGroup["children"]?.arrayValue?.first?["fileType"] == "sourcecode.c.c")
        let target = try #require(objects[2]["contents"])
        #expect(target["productTypeIdentifier"] == "com.apple.product-type.tool")
        let files = try #require(target["buildPhases"]?.arrayValue?.first?["buildFiles"]?.arrayValue)
        // The build file points at the file reference's GUID.
        #expect(files.first?["fileReference"] == toolGroup["children"]?.arrayValue?.first?["guid"])
        #expect(objects[0]["contents"]?["projects"] == [objects[1]["signature"]!])
        let json = try pif.serialized()
        #expect(try JSONSerialization.jsonObject(with: json) is [Any])
    }

    @Test func rejectsUnsupportedTargets() throws {
        let projURL = try writeToolProject(at: ideScratch.appendingPathComponent("pif-unit2"))
        var proj = try PBXProj(contentsOf: projURL)
        var t = proj["A10000000000000000000007"]!
        t["productType"] = .string("com.apple.product-type.bundle.unit-test")
        proj["A10000000000000000000007"] = t
        #expect(throws: PIFGenerator.GenerationError.self) { try PIFGenerator(proj: proj, xcodeprojURL: projURL).pif() }
    }
}
