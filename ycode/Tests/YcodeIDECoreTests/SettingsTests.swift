import Foundation
import Testing
import YcodeBuild
import YcodeDebug
import YcodeXcodebuild
@testable import YcodeIDECore

@MainActor
@Suite(.serialized, .heavyIntegration) struct SettingsTests {
    @Test func buildSystemPreference() {
        let t = TestDefaults("settings")
        defer { t.remove() }
        let d = t.defaults
        #expect(BuildSystemPreference.current(d) == .swiftBuild) // the default
        #expect(BuildSystemPreference.swiftBuild.makeEngine(locateSwiftBuild: { nil }).name == "xcodebuild")
        let fb = BuildSystemPreference.swiftBuild.makeEngine(locateSwiftBuild: { "/x/swbuild" })
        #expect(fb.name == "swift-build")
        // Workspaces are not described by our PIF yet: they go to xcodebuild.
        let engine = try! #require(fb as? FallbackEngine)
        // A workspace that cannot be read falls back to xcodebuild.
        #expect(engine.engine(for: BuildRequest(container: .workspace("/w.xcworkspace"))).name == "xcodebuild")
        #expect((engine.primary as? SwiftBuildEngine)?.pifSource is XcodePIFSource)
        #expect(engine.engine(for: BuildRequest(container: .package("/p"))).name == "swift-build")
    }

    /// The fallback test is XcodePIFSource's: a project that loads but
    /// applies a build-tool plug-in where plug-ins cannot run goes to
    /// xcodebuild (PIF-PKG's `supports`).
    @Test func fallbackUsesThePIFSourceSupportsCheck() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-fallback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let proj = dir.appendingPathComponent("Plug.xcodeproj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try """
        // !$*UTF8*$!
        { archiveVersion = 1; classes = {}; objectVersion = 77; objects = {
        P1 = { isa = PBXProject; buildConfigurationList = PL; mainGroup = G1; packageReferences = (R1); targets = (T1); };
        G1 = { isa = PBXGroup; children = (); sourceTree = "<group>"; };
        PL = { isa = XCConfigurationList; buildConfigurations = (PD); defaultConfigurationName = Debug; };
        PD = { isa = XCBuildConfiguration; name = Debug; buildSettings = { SDKROOT = macosx; }; };
        TL = { isa = XCConfigurationList; buildConfigurations = (TD); defaultConfigurationName = Debug; };
        TD = { isa = XCBuildConfiguration; name = Debug; buildSettings = { PRODUCT_NAME = "$(TARGET_NAME)"; }; };
        T1 = { isa = PBXNativeTarget; buildConfigurationList = TL; buildPhases = (); dependencies = (D1); name = Tool; productName = Tool; productType = "com.apple.product-type.tool"; };
        D1 = { isa = PBXTargetDependency; productRef = PR1; };
        PR1 = { isa = XCSwiftPackageProductDependency; package = R1; productName = "plugin:GenPlugin"; };
        R1 = { isa = XCLocalSwiftPackageReference; relativePath = Gen; };
        }; rootObject = P1; }

        """.write(to: proj.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        let engine = try #require(BuildSystemPreference.swiftBuild.makeEngine(locateSwiftBuild: { "/x/swbuild" }) as? FallbackEngine)
        let request = BuildRequest(container: .project(proj.path))
        #expect((try? XcodePIFSource.container(for: request)) != nil)
        #expect(engine.supports(request) == XcodePIFSource.supports(request))
        #expect(engine.engine(for: request).name == (ProjectPlugins.isSupported ? "swift-build" : "xcodebuild"))
    }
}
