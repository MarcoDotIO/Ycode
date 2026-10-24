import Foundation
import Testing
import YcodePlist
import YcodeProject
@testable import YcodeUI

/// specs/ide/reference-ui-3.md §1, §2.
@Suite struct ProjectEditorReferenceTests {
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

    @Test func generalSectionsAndDestinations() throws {
        let m = try model()
        #expect(ProjectEditorModel.generalSectionTitles.first == "Supported Destinations")
        #expect(ProjectEditorModel.generalSectionTitles.last == "Supported Intents")
        #expect(m.supportedDestinations(target: "App", configuration: "Debug").map(\.name) ==
                ["iPhone", "iPad", "Mac (Designed for iPad)", "Apple Vision (Designed for iPad)"])
        let md = m.minimumDeployments(target: "App", configuration: "Debug")
        #expect(md.count == 1 && md[0].sdk == "iOS" && md[0].value == "27.0")
    }

    @Test func signing() throws {
        let m = try model()
        let box = try #require(m.signingBoxes(target: "App", configuration: "Debug").first)
        #expect(box.platform == "iOS" && box.provisioningProfile == "Xcode Managed Profile")
        #expect(box.status == ["Signing for \u{201C}App\u{201D} requires a development team.",
                               "Select a development team in the Signing & Capabilities editor."])
        #expect(m.capabilityLibraryError(target: "App", configuration: "Debug")?.first == "Error Loading Capabilities")
        let lib = ProjectEditorModel.capabilityLibrary().map(\.rawValue)
        #expect(lib == lib.sorted())
        #expect(ProjectEditorModel.signingScopes == ["All", "Debug", "Release"])
    }

    @Test func infoKeysAndSections() throws {
        let m = try model()
        #expect(ProjectEditorModel.readableKey("CFBundleShortVersionString") == "Bundle version string (short)")
        #expect(ProjectEditorModel.readableKey("Custom") == "Custom")
        #expect(m.infoSectionTitle(target: "App", configuration: "Debug") == "Custom iOS Target Properties")
        #expect(m.infoTypeSections(target: "App", configuration: "Debug") ==
                ["Document Types (0)", "Exported Type Identifiers (0)", "Imported Type Identifiers (0)", "URL Types (0)"])
    }

    @Test func buildSettings() throws {
        let m = try model()
        let sections = m.basicSettingSections(target: "App", configuration: "Debug")
        #expect(sections.map(\.title) == ["Deployment", "Info.plist Values", "Linking - General", "Packaging", "Signing",
                                          "Versioning", "Swift Compiler - Language", "User-Defined"])
        #expect(sections.last?.names == ["MY_FLAG"])
        #expect(m.isDefinedAtShownLevel("PRODUCT_NAME", target: "App", configuration: "Debug"))
        #expect(!m.isDefinedAtShownLevel("SDKROOT", target: "App", configuration: "Debug"))
        #expect(m.levelsColumnTitles(target: "App") == ["Setting", "Resolved", "App", "App", "iOS Default"])
        let v = m.valuesByConfiguration("SWIFT_OPTIMIZATION_LEVEL", target: "App")
        #expect(v.collapsed == "<Multiple values>" && v.perConfiguration?.map(\.0) == ["Debug", "Release"])
        #expect(m.valuesByConfiguration("PRODUCT_NAME", target: "App").perConfiguration == nil)
    }

    @Test func buildPhasesAndRules() throws {
        let m = try model()
        #expect(ProjectEditorModel.phaseTitle("Compile Sources", count: 2) == "Compile Sources (2 items)")
        #expect(ProjectEditorModel.phaseTitle("Compile Sources", count: 1) == "Compile Sources (1 item)")
        let s = m.synchronizedPhaseItems(target: "App")
        #expect(s.sources == ["AppMain.swift \u{2026}in App", "ContentView.swift \u{2026}in App"])
        #expect(s.resources == ["Assets.xcassets \u{2026}in App", "data.json \u{2026}in App"])
        let menu = m.addPhaseMenu(target: "App")
        #expect(menu.map(\.title).first == "New Copy Files Phase" && menu[1].separatorAfter)
        #expect(menu.filter(\.enabled).map(\.title) == ["New Copy Files Phase", "New Run Script Phase"])
        let rules = m.ruleSections(target: "App")
        #expect(rules.map(\.title) == ["Alpha", "Beta"])
        #expect(rules[0].process == "Process: *.foo" && rules[1].using == "Using: com.example.tool")
    }

    @Test func projectInfoPackagesInspector() throws {
        let m = try model()
        let info = m.projectInfo
        #expect(info.configurations == ["Debug", "Release"] && info.commandLineConfiguration == "Release")
        #expect(info.parallelizeCommandLine && info.usesBaseInternationalization)
        #expect(info.localizations.map(\.name) == ["English (Development Language)"])
        #expect(ProjectEditorModel.packagesHeader(count: 0) == "Packages (0 items)")
        let doc = m.projectDocumentSection
        #expect(doc.compatibility == "Xcode 16.0" && doc.minimizeProjectReferences && doc.organization == "Acme")
    }

    @Test func plistKeepsOrderNumberAndCounts() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>z</key><integer>1</integer><key>a</key><real>1.5</real>
        <key>m</key><array><string>x</string><string>y</string></array></dict></plist>
        """
        let doc = try PropertyListDocument(data: Data(xml.utf8))
        let kids = PlistTree.children(of: doc.root)
        #expect(kids.map(\.key) == ["z", "a", "m"])
        #expect(kids[0].value.typeName == "Number" && kids[1].value.typeName == "Number")
        #expect(kids[2].value.summary == "(2 items)" && doc.root.summary == "(3 items)")
    }
}
