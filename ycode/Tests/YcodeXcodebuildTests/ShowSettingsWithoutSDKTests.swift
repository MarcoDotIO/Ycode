import Foundation
import Testing
@testable import YcodeXcodebuild

/// `-showBuildSettings` for Apple-platform projects on a host without their
/// SDKs (Linux): swift-build still evaluates the settings, and ycodebuild
/// says which ones it could not know. `specs/xcodebuild/show-build-settings.md` §5.1.
@Suite struct UnavailableSDKWarningTests {
    @Test func oneWarningPerSDKThatStayedAName() {
        let all: [[String: String]] = [
            ["SDKROOT": "iphoneos", "PRODUCT_NAME": "App"],
            ["SDKROOT": "iphoneos", "PRODUCT_NAME": "AppTests"],
            ["SDKROOT": "macosx"],
        ]
        let w = ShowBuildSettings.unavailableSDKWarnings(all)
        #expect(w.count == 2)
        #expect(w[0].hasPrefix("ycodebuild: warning: the SDK \"iphoneos\" is not installed on this computer."))
        #expect(w[1].contains("\"macosx\""))
        #expect(w[0].contains("-unknown"))
    }

    @Test func swiftBuildsXcodeVersionPlaceholderIsNamedOnce() {
        let all: [[String: String]] = [
            ["SDKROOT": "macosx", "XCODE_PRODUCT_BUILD_VERSION": "99T999"],
            ["SDKROOT": "macosx", "XCODE_PRODUCT_BUILD_VERSION": "99T999"],
        ]
        let w = ShowBuildSettings.unavailableSDKWarnings(all)
        #expect(w.count == 2)
        #expect(w[1] == "ycodebuild: warning: there is no Xcode on this computer: XCODE_VERSION_ACTUAL, XCODE_VERSION_MAJOR, "
            + "XCODE_VERSION_MINOR and XCODE_PRODUCT_BUILD_VERSION are swift-build's placeholders (99T999).")
        #expect(ShowBuildSettings.unavailableSDKWarnings([["XCODE_PRODUCT_BUILD_VERSION": "27A9269"]]).isEmpty)
    }

    @Test func aResolvedSDKOrNoSDKIsQuiet() {
        let all: [[String: String]] = [
            ["SDKROOT": "/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk", "SDK_NAME": "macosx27.0"],
            ["SDKROOT": "macosx", "SDK_NAME": "macosx27.0"],
            ["SDKROOT": ""],
            ["PRODUCT_NAME": "Aggregate"],
        ]
        #expect(ShowBuildSettings.unavailableSDKWarnings(all).isEmpty)
    }
}

/// End to end through the helper (skipped without one): a macOS and an iOS
/// project. On macOS the SDKs resolve; on Linux the settings print anyway,
/// with the warning, in the same format.
@Suite(.serialized, .timeLimit(.minutes(5))) struct ShowSettingsOnThisHostTests {
    func run(_ args: [String], cwd: String, helper: String) -> (out: String, err: String, code: Int32) {
        let capture = CapturingConsole()
        var ctx = XcodebuildContext.current(console: capture.console)
        ctx.cwd = cwd
        ctx.environment["YCODE_SWB"] = helper
        let code = Xcodebuild.run(args, context: ctx)
        return (capture.stdout, capture.stderr, code)
    }

    /// The fixture project, for macOS as written or switched to iOS.
    func project(sdk: String) throws -> String {
        let proj = try writeMultiProject()
        if sdk != "macosx" {
            let file = proj.appendingPathComponent("project.pbxproj")
            let text = try String(contentsOf: file, encoding: .utf8)
                .replacingOccurrences(of: "SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0;", with: "SDKROOT = \(sdk); IPHONEOS_DEPLOYMENT_TARGET = 18.0;")
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        return proj.deletingLastPathComponent().path
    }

    @Test(arguments: ["macosx", "iphoneos"]) func appleProjectSettings(sdk: String) throws {
        guard let helper = SwiftBuildEndToEndTests.helper else { return }
        let dir = try project(sdk: sdk)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let json = run(["-showBuildSettings", "-json", "-target", "App", "-configuration", "Release"], cwd: dir, helper: helper)
        #expect(json.code == 0, "\(json.err)")
        let list = try #require(try JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [[String: Any]])
        #expect(list.count == 1)
        #expect(list.first?["target"] as? String == "App")
        #expect(list.first?["action"] as? String == "build")
        let s = try #require(list.first?["buildSettings"] as? [String: String])
        // Linux leaves out the settings of the SDK and the platform.
        #if os(macOS)
        #expect(s.count > 400, "\(s.count)")
        #else
        #expect(s.count > 300, "\(s.count)")
        #endif
        #expect(s["CONFIGURATION"] == "Release")
        #expect(s["PROJECT_GUID"] == MD5.hex("Multi.xcodeproj"))
        #expect(s["MY_BASE"] == "base")

        let text = run(["-showBuildSettings"], cwd: dir, helper: helper)
        #expect(text.code == 0, "\(text.err)")
        #expect(text.out.contains("Build settings for action build and target Lib:\n"))
        #if os(macOS)
        // The warning is Linux's; on a Mac the SDK resolves (iOS when its platform is installed).
        if sdk == "macosx" {
            #expect(s["SDKROOT"]?.hasPrefix("/") == true)
            #expect(!(s["SDK_NAME"] ?? "").isEmpty)
        }
        #expect(!text.err.contains("is not installed on this computer"))
        #else
        #expect(s["SDKROOT"] == sdk)
        #expect(s["EFFECTIVE_PLATFORM_NAME"] == "-unknown")
        #expect(s["BUILT_PRODUCTS_DIR"] == dir + "/build/Release-unknown")
        #expect(text.err.contains("ycodebuild: warning: the SDK \"\(sdk)\" is not installed on this computer."))
        #expect(json.err.contains("is not installed on this computer"))
        #expect(text.err.contains("swift-build's placeholders (99T999)"))
        #endif
    }
}
