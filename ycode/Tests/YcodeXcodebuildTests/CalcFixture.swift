import Foundation

/// A hand-written project with a static library and a unit-test bundle
/// holding XCTest and swift-testing tests (passing, failing, skipped,
/// parameterized). IDs are arbitrary.
let calcProjectText = """
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 77;
	objects = {
		C10000000000000000000001 = {isa = PBXBuildFile; fileRef = C10000000000000000000002; };
		C10000000000000000000002 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Calc.swift; sourceTree = "<group>"; };
		C10000000000000000000003 = {isa = PBXFileReference; explicitFileType = archive.ar; includeInIndex = 0; path = libCalcKit.a; sourceTree = BUILT_PRODUCTS_DIR; };
		C10000000000000000000004 = {isa = PBXBuildFile; fileRef = C10000000000000000000005; };
		C10000000000000000000005 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CalcXCTests.swift; sourceTree = "<group>"; };
		C10000000000000000000006 = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = CalcTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
		C10000000000000000000007 = {isa = PBXBuildFile; fileRef = C10000000000000000000003; };
		C10000000000000000000008 = {isa = PBXBuildFile; fileRef = C10000000000000000000009; };
		C10000000000000000000009 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CalcSwiftTests.swift; sourceTree = "<group>"; };
		C10000000000000000000010 = {isa = PBXGroup; children = (C10000000000000000000011, C10000000000000000000012, C10000000000000000000013); sourceTree = "<group>"; };
		C10000000000000000000011 = {isa = PBXGroup; children = (C10000000000000000000002); path = CalcKit; sourceTree = "<group>"; };
		C10000000000000000000012 = {isa = PBXGroup; children = (C10000000000000000000005, C10000000000000000000009); path = CalcTests; sourceTree = "<group>"; };
		C10000000000000000000013 = {isa = PBXGroup; children = (C10000000000000000000003, C10000000000000000000006); name = Products; sourceTree = "<group>"; };
		C10000000000000000000020 = {isa = PBXNativeTarget; buildConfigurationList = C10000000000000000000021; buildPhases = (C10000000000000000000022); buildRules = (); dependencies = (); name = CalcKit; productName = CalcKit; productReference = C10000000000000000000003; productType = "com.apple.product-type.library.static"; };
		C10000000000000000000021 = {isa = XCConfigurationList; buildConfigurations = (C10000000000000000000023, C10000000000000000000024); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
		C10000000000000000000022 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (C10000000000000000000001); runOnlyForDeploymentPostprocessing = 0; };
		C10000000000000000000023 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; }; name = Debug; };
		C10000000000000000000024 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; }; name = Release; };
		C10000000000000000000030 = {isa = PBXNativeTarget; buildConfigurationList = C10000000000000000000031; buildPhases = (C10000000000000000000032, C10000000000000000000035); buildRules = (); dependencies = (C10000000000000000000036); name = CalcTests; productName = CalcTests; productReference = C10000000000000000000006; productType = "com.apple.product-type.bundle.unit-test"; };
		C10000000000000000000031 = {isa = XCConfigurationList; buildConfigurations = (C10000000000000000000033, C10000000000000000000034); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
		C10000000000000000000032 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (C10000000000000000000004, C10000000000000000000008); runOnlyForDeploymentPostprocessing = 0; };
		C10000000000000000000033 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = "org.example.CalcTests"; GENERATE_INFOPLIST_FILE = YES; }; name = Debug; };
		C10000000000000000000034 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = "org.example.CalcTests"; GENERATE_INFOPLIST_FILE = YES; }; name = Release; };
		C10000000000000000000035 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (C10000000000000000000007); runOnlyForDeploymentPostprocessing = 0; };
		C10000000000000000000036 = {isa = PBXTargetDependency; target = C10000000000000000000020; targetProxy = C10000000000000000000037; };
		C10000000000000000000037 = {isa = PBXContainerItemProxy; containerPortal = C10000000000000000000040; proxyType = 1; remoteGlobalIDString = C10000000000000000000020; remoteInfo = CalcKit; };
		C10000000000000000000040 = {isa = PBXProject; buildConfigurationList = C10000000000000000000041; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = C10000000000000000000010; productRefGroup = C10000000000000000000013; preferredProjectObjectVersion = 77; projectDirPath = ""; projectRoot = ""; targets = (C10000000000000000000020, C10000000000000000000030); };
		C10000000000000000000041 = {isa = XCConfigurationList; buildConfigurations = (C10000000000000000000042, C10000000000000000000043); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
		C10000000000000000000042 = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; ONLY_ACTIVE_ARCH = YES; SWIFT_VERSION = 6.0; ENABLE_TESTABILITY = YES; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; DEBUG_INFORMATION_FORMAT = dwarf; CODE_SIGN_IDENTITY = "-"; }; name = Debug; };
		C10000000000000000000043 = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; SWIFT_VERSION = 6.0; CODE_SIGN_IDENTITY = "-"; }; name = Release; };
	};
	rootObject = C10000000000000000000040;
}

"""

/// Writes the Calc project and its sources into a fresh directory.
func writeCalcProject() throws -> URL {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("ycodebuild-tests-\(UUID().uuidString)")
    let proj = dir.appendingPathComponent("Calc.xcodeproj")
    try fm.createDirectory(at: proj, withIntermediateDirectories: true)
    for sub in ["CalcKit", "CalcTests"] { try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true) }
    try calcProjectText.write(to: proj.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
    try """
    public enum Calc {
        public static func add(_ a: Int, _ b: Int) -> Int { a + b }
        public static func mul(_ a: Int, _ b: Int) -> Int { a * b }
    }

    """.write(to: dir.appendingPathComponent("CalcKit/Calc.swift"), atomically: true, encoding: .utf8)
    try """
    import XCTest
    @testable import CalcKit

    final class AddTests: XCTestCase {
        func testAdd() { XCTAssertEqual(Calc.add(2, 3), 5) }
        func testAddZero() { XCTAssertEqual(Calc.add(0, 7), 7) }
    }

    final class MulTests: XCTestCase {
        func testMul() { XCTAssertEqual(Calc.mul(2, 3), 6) }
        func testSkipped() throws { throw XCTSkip("not today") }
    }

    final class FailingTests: XCTestCase {
        func testWrong() { XCTAssertEqual(Calc.add(2, 2), 5, "arithmetic") }
    }

    """.write(to: dir.appendingPathComponent("CalcTests/CalcXCTests.swift"), atomically: true, encoding: .utf8)
    try """
    import Testing
    @testable import CalcKit

    @Suite struct SwiftCalcTests {
        @Test func adds() { #expect(Calc.add(1, 1) == 2) }
        @Test(arguments: [1, 2, 3]) func doubles(n: Int) { #expect(Calc.mul(n, 2) == n + n) }
    }

    @Test func freeFunction() { #expect(Calc.mul(0, 9) == 0) }

    @Suite struct SwiftFailing {
        @Test func wrong() { #expect(Calc.mul(2, 2) == 5) }
    }

    """.write(to: dir.appendingPathComponent("CalcTests/CalcSwiftTests.swift"), atomically: true, encoding: .utf8)
    return proj
}
