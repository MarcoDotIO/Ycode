import Foundation
import Testing
import YcodePlist
import YcodeProject
@testable import YcodeIDECore

/// P-096 (parity inventory): the Signing section names Ycode, never the
/// reference product, and a Mac target without a team signs to run locally
/// without the "requires a development team" warning.
@Suite struct SigningTrademarkTests {
    func model(sdk: String, platforms: String) throws -> ProjectEditorModel {
        let text = ProjectEditorReferenceTests.pbxproj
            .replacingOccurrences(of: "SDKROOT = iphoneos", with: "SDKROOT = \(sdk)")
            .replacingOccurrences(of: "SUPPORTED_PLATFORMS = \"iphoneos iphonesimulator\"", with: "SUPPORTED_PLATFORMS = \"\(platforms)\"")
            .replacingOccurrences(of: "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = YES; SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD = YES;", with: "")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-signing-\(UUID().uuidString)")
        let proj = dir.appendingPathComponent("App.xcodeproj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        return ProjectEditorModel(proj: try PBXProj(parsing: text), xcodeprojURL: proj)
    }

    @Test func noTrademarkInTheSigningSection() throws {
        let texts = [ProjectEditorModel.automaticSigningCaption, ProjectEditorModel.managedProfileTitle, ProjectEditorModel.noProfileRequiredTitle]
        #expect(texts.allSatisfy { !$0.contains("Xcode") })
        let ios = try model(sdk: "iphoneos", platforms: "iphoneos iphonesimulator")
        let box = try #require(ios.signingBoxes(target: "App", configuration: "Debug").first)
        #expect(box.provisioningProfile == "Ycode Managed Profile" && !box.provisioningProfile.contains("Xcode"))
        // A device platform without a team still warns.
        #expect(box.status.first == "Signing for \u{201C}App\u{201D} requires a development team.")
    }

    @Test func macTargetWithoutTeamSignsToRunLocallyWithoutWarning() throws {
        let mac = try model(sdk: "macosx", platforms: "macosx")
        let box = try #require(mac.signingBoxes(target: "App", configuration: "Debug").first)
        #expect(box.platform == "macOS")
        #expect(box.provisioningProfile == "None Required")
        #expect(box.certificate == "Sign to Run Locally")
        #expect(box.status.isEmpty)
    }
}
