import Foundation
import Testing
import YcodeProject
@testable import YcodeIDECore

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct LevelsViewTests {
    @Test func strippedCopyKeepsOnlyThePlatform() throws {
        let url = ycodeDir.appendingPathComponent("Tests/YcodeProjectTests/Fixtures/Hello.xcodeproj")
        let s = DefaultsLevel.stripped(try PBXProj(contentsOf: url))
        let all = s.objects.values.filter { $0.isa == "XCBuildConfiguration" }.flatMap { $0["buildSettings"]?.dictionary?.keys ?? [] }
        #expect(Set(all).isSubset(of: ["SDKROOT", "SUPPORTED_PLATFORMS"]))
    }
}
