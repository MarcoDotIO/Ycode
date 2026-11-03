import Foundation

/// A sample project written for the build-server tests: a framework `Kit`
/// (Swift, plus Objective-C with public headers in the iOS flavor), an
/// app `App` that links it, and a unit-test bundle `AppTests` in a
/// synchronized folder that depends on the app.
///
/// - `.iOS`: an iOS app (`SDKROOT = iphoneos`), mixed Swift and
///   Objective-C, with a bridging header.
/// - `.portable`: Swift only, `SDKROOT = macosx`, the app a command-line
///   tool, so that it also indexes on Linux.
///
/// Tests use it, and `ycode-bsp sample <dir> [ios|portable]` writes it for
/// trying the build server by hand.
public enum SampleProject {
    public enum Flavor: Sendable { case iOS, portable }

    public static let greeter = """
    import Foundation

    /// Says hello.
    public struct Greeter {
        public let name: String
        public init(name: String) { self.name = name }
        public func greet(times: Int) -> String { String(repeating: "Hello \\(name)! ", count: times) }
    }

    """

    public static let greeterMixed = greeter + """

    extension Greeter {
        /// From the framework's Objective-C half.
        public var answer: Int { KitLegacy.answer() }
    }

    """

    public static let appMainIOS = """
    import UIKit
    import Kit

    @main
    final class AppDelegate: UIResponder, UIApplicationDelegate {
        var window: UIWindow?
        func greeting() -> String {
            let g = Greeter(name: "Ycode")
            _ = Helper.shared()
            window?.backgroundColor = UIColor.red
            return g.greet(times: 2)
        }
    }

    """

    public static let appMainPortable = """
    import Kit

    let g = Greeter(name: "Ycode")
    print(g.greet(times: 2))

    """

    public static let testsIOS = """
    import XCTest
    @testable import App
    import Kit

    final class AppTests: XCTestCase {
        func testGreeting() {
            XCTAssertEqual(Greeter(name: "a").greet(times: 1), "Hello a! ")
            XCTAssertFalse(AppDelegate().greeting().isEmpty)
        }
    }

    """

    public static let testsPortable = """
    import XCTest
    import Kit

    final class AppTests: XCTestCase {
        func testGreeting() {
            XCTAssertEqual(Greeter(name: "a").greet(times: 1), "Hello a! ")
        }
    }

    """

    /// Writes the project into a new folder under `parent`; returns the
    /// `.xcodeproj`.
    public static func write(_ flavor: Flavor, in parent: URL) throws -> URL {
        let fm = FileManager.default
        let dir = parent.appendingPathComponent("Sample-\(flavor == .iOS ? "iOS" : "portable")")
        try? fm.removeItem(at: dir)
        for sub in ["Sample.xcodeproj", "App", "Kit", "AppTests"] {
            try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        func put(_ rel: String, _ text: String) throws {
            try text.write(to: dir.appendingPathComponent(rel), atomically: true, encoding: .utf8)
        }
        try put("Sample.xcodeproj/project.pbxproj", pbxproj(flavor))
        if flavor == .iOS {
            try put("Kit/Greeter.swift", greeterMixed)
            try put("Kit/Kit.h", "#import <Foundation/Foundation.h>\n#import <Kit/KitLegacy.h>\n")
            try put("Kit/KitLegacy.h", "#import <Foundation/Foundation.h>\n\n@interface KitLegacy : NSObject\n+ (NSInteger)answer;\n@end\n")
            try put("Kit/KitLegacy.m", "#import \"KitLegacy.h\"\n\n@implementation KitLegacy\n+ (NSInteger)answer { return 42; }\n@end\n")
            try put("App/AppMain.swift", appMainIOS)
            try put("App/Helper.h", "#import <Foundation/Foundation.h>\n\n@interface Helper : NSObject\n+ (instancetype)shared;\n@end\n")
            try put("App/Helper.m", "#import \"Helper.h\"\n#import <Kit/Kit.h>\n\n@implementation Helper\n+ (instancetype)shared { (void)[KitLegacy answer]; return [Helper new]; }\n@end\n")
            try put("App/App-Bridging-Header.h", "#import \"Helper.h\"\n")
            try put("AppTests/AppTests.swift", testsIOS)
        } else {
            try put("Kit/Greeter.swift", greeter)
            try put("App/main.swift", appMainPortable)
            try put("AppTests/AppTests.swift", testsPortable)
        }
        return dir.appendingPathComponent("Sample.xcodeproj")
    }

    // MARK: pbxproj

    static func pbxproj(_ flavor: Flavor) -> String {
        let iOS = flavor == .iOS
        var o: [(String, String)] = []
        func add(_ id: String, _ body: String) { o.append((id, body)) }
        // Files
        add("A00000000000000000000001", "{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Greeter.swift; sourceTree = \"<group>\"; }")
        if iOS {
            add("A00000000000000000000002", "{isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = Kit.h; sourceTree = \"<group>\"; }")
            add("A00000000000000000000003", "{isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = KitLegacy.h; sourceTree = \"<group>\"; }")
            add("A00000000000000000000004", "{isa = PBXFileReference; lastKnownFileType = sourcecode.c.objc; path = KitLegacy.m; sourceTree = \"<group>\"; }")
            add("A00000000000000000000005", "{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AppMain.swift; sourceTree = \"<group>\"; }")
            add("A00000000000000000000006", "{isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = Helper.h; sourceTree = \"<group>\"; }")
            add("A00000000000000000000007", "{isa = PBXFileReference; lastKnownFileType = sourcecode.c.objc; path = Helper.m; sourceTree = \"<group>\"; }")
            add("A00000000000000000000008", "{isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = \"App-Bridging-Header.h\"; sourceTree = \"<group>\"; }")
            add("A00000000000000000000009", "{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = App.app; sourceTree = BUILT_PRODUCTS_DIR; }")
        } else {
            add("A00000000000000000000005", "{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = main.swift; sourceTree = \"<group>\"; }")
            add("A00000000000000000000009", "{isa = PBXFileReference; explicitFileType = \"compiled.mach-o.executable\"; includeInIndex = 0; path = App; sourceTree = BUILT_PRODUCTS_DIR; }")
        }
        add("A0000000000000000000000A", "{isa = PBXFileReference; explicitFileType = wrapper.framework; includeInIndex = 0; path = Kit.framework; sourceTree = BUILT_PRODUCTS_DIR; }")
        add("A0000000000000000000000B", "{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = AppTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }")
        // Groups
        let kitFiles = iOS ? "A00000000000000000000001, A00000000000000000000002, A00000000000000000000003, A00000000000000000000004" : "A00000000000000000000001"
        let appFiles = iOS ? "A00000000000000000000005, A00000000000000000000006, A00000000000000000000007, A00000000000000000000008" : "A00000000000000000000005"
        add("B00000000000000000000001", "{isa = PBXGroup; children = (B00000000000000000000002, B00000000000000000000003, B00000000000000000000005, B00000000000000000000004); sourceTree = \"<group>\"; }")
        add("B00000000000000000000002", "{isa = PBXGroup; children = (\(appFiles)); path = App; sourceTree = \"<group>\"; }")
        add("B00000000000000000000003", "{isa = PBXGroup; children = (\(kitFiles)); path = Kit; sourceTree = \"<group>\"; }")
        add("B00000000000000000000004", "{isa = PBXGroup; children = (A00000000000000000000009, A0000000000000000000000A, A0000000000000000000000B); name = Products; sourceTree = \"<group>\"; }")
        add("B00000000000000000000005", "{isa = PBXFileSystemSynchronizedRootGroup; path = AppTests; sourceTree = \"<group>\"; }")
        // Build files
        add("C00000000000000000000001", "{isa = PBXBuildFile; fileRef = A00000000000000000000001; }")
        add("C00000000000000000000005", "{isa = PBXBuildFile; fileRef = A00000000000000000000005; }")
        add("C0000000000000000000000A", "{isa = PBXBuildFile; fileRef = A0000000000000000000000A; }")
        if iOS {
            add("C00000000000000000000002", "{isa = PBXBuildFile; fileRef = A00000000000000000000002; settings = {ATTRIBUTES = (Public, ); }; }")
            add("C00000000000000000000003", "{isa = PBXBuildFile; fileRef = A00000000000000000000003; settings = {ATTRIBUTES = (Public, ); }; }")
            add("C00000000000000000000004", "{isa = PBXBuildFile; fileRef = A00000000000000000000004; }")
            add("C00000000000000000000007", "{isa = PBXBuildFile; fileRef = A00000000000000000000007; }")
        }
        // Phases
        add("D00000000000000000000001", "{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (C00000000000000000000001\(iOS ? ", C00000000000000000000004" : "")); runOnlyForDeploymentPostprocessing = 0; }")
        add("D00000000000000000000002", "{isa = PBXHeadersBuildPhase; buildActionMask = 2147483647; files = (\(iOS ? "C00000000000000000000002, C00000000000000000000003" : "")); runOnlyForDeploymentPostprocessing = 0; }")
        add("D00000000000000000000003", "{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (C00000000000000000000005\(iOS ? ", C00000000000000000000007" : "")); runOnlyForDeploymentPostprocessing = 0; }")
        add("D00000000000000000000004", "{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (C0000000000000000000000A); runOnlyForDeploymentPostprocessing = 0; }")
        add("D00000000000000000000005", "{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }")
        // Targets
        add("E00000000000000000000001", "{isa = PBXNativeTarget; buildConfigurationList = F00000000000000000000011; buildPhases = (D00000000000000000000002, D00000000000000000000001); buildRules = (); dependencies = (); name = Kit; productName = Kit; productReference = A0000000000000000000000A; productType = \"com.apple.product-type.framework\"; }")
        add("E00000000000000000000002", "{isa = PBXNativeTarget; buildConfigurationList = F00000000000000000000021; buildPhases = (D00000000000000000000003, D00000000000000000000004); buildRules = (); dependencies = (E00000000000000000000011); name = App; productName = App; productReference = A00000000000000000000009; productType = \"\(iOS ? "com.apple.product-type.application" : "com.apple.product-type.tool")\"; }")
        add("E00000000000000000000003", "{isa = PBXNativeTarget; buildConfigurationList = F00000000000000000000031; buildPhases = (D00000000000000000000005); buildRules = (); dependencies = (E00000000000000000000013); fileSystemSynchronizedGroups = (B00000000000000000000005); name = AppTests; productName = AppTests; productReference = A0000000000000000000000B; productType = \"com.apple.product-type.bundle.unit-test\"; }")
        add("E00000000000000000000011", "{isa = PBXTargetDependency; target = E00000000000000000000001; targetProxy = E00000000000000000000012; }")
        add("E00000000000000000000012", "{isa = PBXContainerItemProxy; containerPortal = F00000000000000000000001; proxyType = 1; remoteGlobalIDString = E00000000000000000000001; remoteInfo = Kit; }")
        add("E00000000000000000000013", "{isa = PBXTargetDependency; target = E00000000000000000000002; targetProxy = E00000000000000000000014; }")
        add("E00000000000000000000014", "{isa = PBXContainerItemProxy; containerPortal = F00000000000000000000001; proxyType = 1; remoteGlobalIDString = E00000000000000000000002; remoteInfo = App; }")
        // Project and configurations
        add("F00000000000000000000001", "{isa = PBXProject; attributes = {LastSwiftUpdateCheck = 2700; LastUpgradeCheck = 2700; TargetAttributes = {E00000000000000000000003 = {TestTargetID = E00000000000000000000002; }; }; }; buildConfigurationList = F00000000000000000000002; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = B00000000000000000000001; minimizedProjectReferenceProxies = 1; preferredProjectObjectVersion = 77; productRefGroup = B00000000000000000000004; projectDirPath = \"\"; projectRoot = \"\"; targets = (E00000000000000000000001, E00000000000000000000002, E00000000000000000000003); }")
        let sdk = iOS ? "SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 18.0; TARGETED_DEVICE_FAMILY = \"1,2\";" : "SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0;"
        let common = "CLANG_ENABLE_MODULES = YES; CLANG_ENABLE_OBJC_ARC = YES; GCC_C_LANGUAGE_STANDARD = gnu17; SWIFT_VERSION = 5.0; \(sdk)"
        add("F00000000000000000000002", "{isa = XCConfigurationList; buildConfigurations = (F00000000000000000000003, F00000000000000000000004); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }")
        add("F00000000000000000000003", "{isa = XCBuildConfiguration; buildSettings = {\(common) ENABLE_TESTABILITY = YES; GCC_OPTIMIZATION_LEVEL = 0; GCC_PREPROCESSOR_DEFINITIONS = (\"DEBUG=1\", \"$(inherited)\", ); ONLY_ACTIVE_ARCH = YES; SWIFT_ACTIVE_COMPILATION_CONDITIONS = \"DEBUG $(inherited)\"; SWIFT_OPTIMIZATION_LEVEL = \"-Onone\"; }; name = Debug; }")
        add("F00000000000000000000004", "{isa = XCBuildConfiguration; buildSettings = {\(common) SWIFT_COMPILATION_MODE = wholemodule; }; name = Release; }")
        let kit = "DEFINES_MODULE = YES; GENERATE_INFOPLIST_FILE = YES; PRODUCT_BUNDLE_IDENTIFIER = org.ycode.sample.Kit; PRODUCT_NAME = \"$(TARGET_NAME:c99extidentifier)\"; SKIP_INSTALL = YES;"
        let bridging = iOS ? " SWIFT_OBJC_BRIDGING_HEADER = \"App/App-Bridging-Header.h\";" : ""
        let app = "GENERATE_INFOPLIST_FILE = YES; PRODUCT_BUNDLE_IDENTIFIER = org.ycode.sample.App; PRODUCT_NAME = \"$(TARGET_NAME)\";\(bridging)"
        let tests = "BUNDLE_LOADER = \"$(TEST_HOST)\"; GENERATE_INFOPLIST_FILE = YES; PRODUCT_BUNDLE_IDENTIFIER = org.ycode.sample.AppTests; PRODUCT_NAME = \"$(TARGET_NAME)\";\(iOS ? " TEST_HOST = \"$(BUILT_PRODUCTS_DIR)/App.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/App\";" : "")"
        for (list, first, settings) in [("F00000000000000000000011", 0x12, kit), ("F00000000000000000000021", 0x22, app), ("F00000000000000000000031", 0x32, tests)] {
            let d = String(format: "F000000000000000000000%02X", first), r = String(format: "F000000000000000000000%02X", first + 1)
            add(list, "{isa = XCConfigurationList; buildConfigurations = (\(d), \(r)); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }")
            add(d, "{isa = XCBuildConfiguration; buildSettings = {\(settings) }; name = Debug; }")
            add(r, "{isa = XCBuildConfiguration; buildSettings = {\(settings) }; name = Release; }")
        }
        let body = o.sorted { $0.0 < $1.0 }.map { "\t\t\($0.0) = \($0.1);" }.joined(separator: "\n")
        return "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 77;\n\tobjects = {\n\(body)\n\t};\n\trootObject = F00000000000000000000001;\n}\n"
    }
}
