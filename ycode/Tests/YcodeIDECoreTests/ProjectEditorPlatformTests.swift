import Foundation
import Testing
import YcodePlist
import YcodeProject
@testable import YcodeIDECore

/// General sections per platform, the Project Document inspector writes,
/// the Info type sections and User-Defined grouping (reference-ui-3.md §1).
/// Projects are written only in temporary directories.
@MainActor
@Suite struct ProjectEditorPlatformTests {
    /// The table in specs/formats/pbxproj.md (Project format).
    @Test func compatibilityTableMatchesSpec() {
        let spec: [(String, Int)] = [("Xcode 16.0", 77), ("Xcode 15.3", 63), ("Xcode 15.0", 60), ("Xcode 14.0", 56),
            ("Xcode 13.0", 55), ("Xcode 12.0", 54), ("Xcode 11.4", 53), ("Xcode 11.0", 52), ("Xcode 10.0", 51),
            ("Xcode 9.3", 50), ("Xcode 8.0", 48), ("Xcode 6.3", 47), ("Xcode 3.2", 46), ("Xcode 3.1", 45)]
        #expect(ProjectEditorModel.compatibilityVersions.map(\.title) == spec.map(\.0))
        #expect(ProjectEditorModel.compatibilityVersions.map(\.objectVersion) == spec.map(\.1))
        #expect(ProjectEditorModel.compatibility(objectVersion: "110") == "Xcode 16.0")
        #expect(ProjectEditorModel.compatibility(objectVersion: "45") == "Xcode 3.1")
    }
}
