import Foundation
import Testing
import YcodePlist
import YcodeProject
@testable import YcodeIDECore

/// The first line where two texts differ (test messages).
func firstDifference(_ a: String, _ b: String) -> String {
    let x = a.components(separatedBy: "\n"), y = b.components(separatedBy: "\n")
    for i in 0..<max(x.count, y.count) where (i < x.count ? x[i] : nil) != (i < y.count ? y[i] : nil) {
        return "line \(i + 1): \(i < x.count ? x[i] : "<end>") | \(i < y.count ? y[i] : "<end>")"
    }
    return "same"
}

/// reference-ui-5.md §11.1 (R35): the project editor's remaining gaps.
@MainActor
@Suite struct ProjectEditorR35Tests {
    static let pbxproj = """
    // !$*UTF8*$!
    { archiveVersion = 1; classes = {}; objectVersion = 77; objects = {
    P1 = { isa = PBXProject; buildConfigurationList = PL; mainGroup = G1; productRefGroup = G2; targets = (T1, T2); knownRegions = (en, Base, de); developmentRegion = en;
           attributes = { BuildIndependentTargetsInParallel = 1; KnownAssetTags = (Level1, Intro); }; };
    G1 = { isa = PBXGroup; children = (G3, G2); sourceTree = "<group>"; };
    G2 = { isa = PBXGroup; children = (AP, TP); name = Products; sourceTree = "<group>"; };
    G3 = { isa = PBXGroup; children = (); path = App; sourceTree = "<group>"; };
    AP = { isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = App.app; sourceTree = BUILT_PRODUCTS_DIR; };
    TP = { isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = AppTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
    PL = { isa = XCConfigurationList; buildConfigurations = (PD, PR); defaultConfigurationName = Release; };
    PD = { isa = XCBuildConfiguration; name = Debug; buildSettings = { SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 27.0; }; };
    PR = { isa = XCBuildConfiguration; name = Release; buildSettings = { SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 27.0; }; };
    T1 = { isa = PBXNativeTarget; name = App; productName = App; productReference = AP; productType = "com.apple.product-type.application"; buildConfigurationList = TL;
           buildPhases = (S1, F1, R1); buildRules = (BR1); dependencies = (D1); packageProductDependencies = (PR1); };
    T2 = { isa = PBXNativeTarget; name = AppTests; productName = AppTests; productReference = TP; productType = "com.apple.product-type.bundle.unit-test"; buildConfigurationList = TL2;
           buildPhases = (S2); buildRules = (); dependencies = (); };
    D1 = { isa = PBXTargetDependency; productRef = PR1; };
    PR1 = { isa = XCSwiftPackageProductDependency; productName = "plugin:LintPlugin"; };
    S1 = { isa = PBXSourcesBuildPhase; files = (); };
    S2 = { isa = PBXSourcesBuildPhase; files = (); };
    F1 = { isa = PBXFrameworksBuildPhase; files = (); };
    R1 = { isa = PBXResourcesBuildPhase; files = (); };
    BR1 = { isa = PBXBuildRule; name = Alpha; compilerSpec = com.apple.compilers.proxy.script; fileType = pattern.proxy; filePatterns = "*.foo"; isEditable = 1; outputFiles = (); script = "echo hi"; };
    TL = { isa = XCConfigurationList; buildConfigurations = (TD, TR); defaultConfigurationName = Release; };
    TD = { isa = XCBuildConfiguration; name = Debug; buildSettings = { SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; TARGETED_DEVICE_FAMILY = "1,2"; PRODUCT_NAME = App;
           GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES; INFOPLIST_KEY_UILaunchScreen_Generation = YES;
           INFOPLIST_KEY_CFBundleDisplayName = "$(PRODUCT_NAME) Pro"; INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
           INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft"; }; };
    TR = { isa = XCBuildConfiguration; name = Release; buildSettings = { SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; TARGETED_DEVICE_FAMILY = "1,2"; PRODUCT_NAME = App;
           GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES; INFOPLIST_KEY_UILaunchScreen_Generation = YES;
           INFOPLIST_KEY_CFBundleDisplayName = "$(PRODUCT_NAME) Pro"; INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
           INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft"; }; };
    TL2 = { isa = XCConfigurationList; buildConfigurations = (TD2); defaultConfigurationName = Debug; };
    TD2 = { isa = XCBuildConfiguration; name = Debug; buildSettings = { PRODUCT_NAME = AppTests; }; };
    }; rootObject = P1; }
    """

    static func model() throws -> ProjectEditorModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-pe-r35-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("App"), withIntermediateDirectories: true)
        let proj = dir.appendingPathComponent("App.xcodeproj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        return ProjectEditorModel(proj: try PBXProj(parsing: Self.pbxproj), xcodeprojURL: proj)
    }

    // MARK: P5

    @Test func infoShowsGeneratedKeysReadablyWithDefinitions() throws {
        let m = try Self.model()
        let items = m.infoItems(target: "App", configuration: "Debug")
        let keys = items.map(\.key)
        #expect(Array(keys.prefix(8)) == ["Bundle name", "Bundle identifier", "InfoDictionary version", "Bundle version string (short)",
                                          "Bundle version", "Executable file", "Application requires iPhone environment", "Application Scene Manifest"])
        #expect(keys.contains("Bundle display name") && keys.contains("Launch Screen") && keys.contains("Supported interface orientations (iPhone)"))
        #expect(!keys.contains { $0.contains("INFOPLIST_KEY") || $0.hasSuffix("_Generation") })
        func item(_ raw: String) -> ProjectEditorModel.InfoItem? { items.first { $0.rawKey == raw } }
        // Values from build settings stay as $(…).
        #expect(item("CFBundleIdentifier")?.value == "$(PRODUCT_BUNDLE_IDENTIFIER)")
        #expect(item("CFBundleDisplayName")?.value == "$(PRODUCT_NAME) Pro")
        #expect(item("UIApplicationSupportsIndirectInputEvents")?.type == "Boolean")
        let orient = try #require(item("UISupportedInterfaceOrientations~iphone"))
        #expect(orient.type == "Array" && orient.value == "(2 items)" && orient.children.map(\.key) == ["Item 0", "Item 1"])
        #expect(item("UIApplicationSceneManifest")?.type == "Dictionary")
        #expect(item("UIApplicationSceneManifest")?.children.first?.key == "Enable Multiple Windows")
    }

    @Test func identityPlusWritesInfoPlistFile() throws {
        var m = try Self.model()
        let dir = m.proj.projectDirectory(xcodeprojURL: m.xcodeprojURL)
        let plist = dir.appendingPathComponent("App/Info.plist")
        try PropertyListDocument(root: .dictionary([.init(key: "Zeta", value: .string("z"))])).data().write(to: plist)
        m.setSetting("INFOPLIST_FILE", "App/Info.plist", target: "App")
        m.setSetting("GENERATE_INFOPLIST_FILE", "NO", target: "App")
        let version = try #require(ProjectEditorModel.identityRows.first { $0.title == "Version" })
        #expect(!m.identityRowInInfo(version, target: "App", configuration: "Debug"))
        try m.addIdentityKeyToInfo(version, target: "App", configuration: "Debug")
        guard case .dictionary(let d) = try PropertyListDocument(data: Data(contentsOf: plist)).root else { Issue.record("not a dict"); return }
        #expect(d.map(\.key) == ["Zeta", "CFBundleShortVersionString"] && d[1].value == .string("$(MARKETING_VERSION)"))
        #expect(m.identityRowInInfo(version, target: "App", configuration: "Debug"))
    }

    /// Build rules belong to native targets only.
    @Test func noBuildRulesOnAggregateTargets() throws {
        var m = try Self.model()
        var t = try #require(m.target(named: "AppTests"))
        t["isa"] = "PBXAggregateTarget"
        m.proj[t.id] = t
        #expect(m.addBuildRule(target: "AppTests") == nil && m.copyBuildRule("BR1", toTarget: "AppTests") == nil)
        #expect(m.proj[t.id]?.references("buildRules") == [])
    }

    /// A UI Testing Bundle's class is named after the target, as the file
    /// is (templates.md: `NUITests/NUITests.swift`), not `<Name>UITests`.
    @Test func uiTestingBundleClassIsNamedAfterTheTarget() throws {
        let m = try Self.model()
        let (_, files) = try TargetTemplateCatalog.make(template: "UI Testing Bundle", platform: "iOS", name: "AppUITests",
                                                        organization: "com.example", host: (id: "T1", name: "App"), proj: m.proj)
        #expect(files.map(\.0) == ["AppUITests/AppUITests.swift"])
        let source = try #require(files.first?.1)
        #expect(source.contains("final class AppUITests: XCTestCase {"))
        #expect(!source.contains("UITestsUITests"))
    }

    /// An older project (object version 46): the new target's sources go in
    /// a group with its file in Compile Sources.
    @Test func addTargetToOlderProject() throws {
        var m = try Self.model()
        m.proj.objectVersion = "46"
        try m.addTarget(template: "Framework", platform: "iOS", name: "Kit", hostTarget: nil)
        let t = try #require(m.target(named: "Kit"))
        #expect(t["fileSystemSynchronizedGroups"] == nil)
        let group = try #require(m.proj.objects.values.first { $0.isa == "PBXGroup" && $0.string("path") == "Kit" })
        let ref = try #require(group.references("children").first.flatMap { m.proj[$0] })
        #expect(ref.string("path") == "Kit.swift")
        let sources = m.proj.buildPhases(ofTarget: t.id).first { $0.isa == "PBXSourcesBuildPhase" }
        #expect(sources?.references("files").compactMap { m.proj.fileReference(ofBuildFile: $0)?.id } == [ref.id])
    }
}

/// Over the local corpus (see README; the manifest of `PBXProjCorpusTests`):
/// project-editor edits that are undone restore every project byte for byte.
@Suite struct ProjectEditorR35CorpusTests {
    static let entries: [String] = {
        let manifest = ProcessInfo.processInfo.environment["YCODE_PBXPROJ_CORPUS"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("research/dirty/pbxproj-corpus.txt")
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).filter { $0.count > 2 }
    }()

    /// The checked-in fixture always runs.
    @Test func undoneEditsRestoreFixtureBytes() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("YcodeProjectTests/Fixtures/Hello.xcodeproj")
        try undoneEditsRestoreBytes("= " + fixture.path)
        // And the fixture's text itself is what the writer produces.
        let (file, name) = PBXProj.locate(fixture.path)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(try PBXProj(parsing: text).serialized(projectName: name) == text)
    }

    @Test(.enabled(if: !entries.isEmpty, "no local corpus manifest"), arguments: entries)
    func undoneEditsRestoreBytes(_ entry: String) throws {
        let (file, name) = PBXProj.locate(String(entry.dropFirst(2)))
        let original = try PBXProj(parsing: try String(contentsOf: file, encoding: .utf8))
        let before = original.serialized(projectName: name)
        var m = ProjectEditorModel(proj: original, xcodeprojURL: file.deletingLastPathComponent())
        if let cfg = m.configurations(of: nil).names.first, let copy = m.duplicateConfiguration(cfg) {
            m.removeConfiguration(copy)
        }
        let tag = m.addResourceTag()
        m.removeResourceTag(tag)
        if let t = m.targets.first?.string("name"), let rule = m.addBuildRule(target: t) { m.removeBuildRule(rule) }
        let after = m.proj.serialized(projectName: name)
        #expect(after == before, "\(file.path): \(firstDifference(before, after))")
    }
}
