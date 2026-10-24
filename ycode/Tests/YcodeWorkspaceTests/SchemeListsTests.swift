import Foundation
import Testing
@testable import YcodeWorkspace

/// The scheme editor's Build targets and Test plans tables (reference-ui-5.md §11.3, P11).
@Suite struct SchemeListsTests {
    func fixture() throws -> (text: String, scheme: Scheme) {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/App.xcodeproj/xcshareddata/xcschemes/App", withExtension: "xcscheme"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return (text, try Scheme(parsing: text, name: "App"))
    }

    static let tests = Scheme.BuildableReference(blueprintIdentifier: "0E0000000000000000000002", buildableName: "AppTests.xctest",
                                                 blueprintName: "AppTests", referencedContainer: "container:App.xcodeproj")

    @Test func addAndRemoveBuildEntries() throws {
        var (text, s) = try fixture()
        s.addBuildEntry(Self.tests, actions: [.testing])
        #expect(s.buildEntries.map(\.reference.blueprintName) == ["App", "AppTests"])
        #expect(s.buildEntries[1].actions == [.testing])
        let written = s.serialized()
        #expect(written.contains("""
                 <BuildActionEntry
                    buildForTesting = "YES"
                    buildForRunning = "NO"
                    buildForProfiling = "NO"
                    buildForArchiving = "NO"
                    buildForAnalyzing = "NO">
                    <BuildableReference
                       BuildableIdentifier = "primary"
                       BlueprintIdentifier = "0E0000000000000000000002"
        """))
        let back = try Scheme(parsing: written, name: "App")
        #expect(back.serialized() == written)
        // Adding twice is a no-op; removing restores the bytes.
        s.addBuildEntry(Self.tests, actions: Set(Scheme.Action.allCases))
        #expect(s.buildEntries.count == 2)
        s.removeBuildEntry(blueprintIdentifier: Self.tests.blueprintIdentifier)
        #expect(s.serialized() == text)
        // The last entry removes the container element.
        s.removeBuildEntry(blueprintIdentifier: "0E0000000000000000000001")
        #expect(s.buildEntries.isEmpty && !s.serialized().contains("BuildActionEntries"))
    }

    @Test func addRemoveAndDefaultTestPlans() throws {
        var (text, s) = try fixture()
        s.addTestPlan(reference: "container:App/App.xctestplan")
        s.addTestPlan(reference: "container:Smoke.xctestplan")
        #expect(s.testPlans.map(\.reference) == ["container:App/App.xctestplan", "container:Smoke.xctestplan"])
        #expect(s.testPlans.map(\.isDefault) == [true, false])
        let written = s.serialized()
        #expect(written.contains("""
              <TestPlans>
                 <TestPlanReference
                    reference = "container:App/App.xctestplan"
                    default = "YES">
                 </TestPlanReference>
                 <TestPlanReference
                    reference = "container:Smoke.xctestplan">
                 </TestPlanReference>
              </TestPlans>
        """))
        // After Testables.
        #expect(written.range(of: "</Testables>")!.lowerBound < written.range(of: "<TestPlans>")!.lowerBound)
        s.setDefaultTestPlan(reference: "container:Smoke.xctestplan")
        #expect(s.testPlans.map(\.isDefault) == [false, true])
        s.removeTestPlan(reference: "container:Smoke.xctestplan")
        #expect(s.testPlans.map(\.isDefault) == [true])
        s.removeTestPlan(reference: "container:App/App.xctestplan")
        #expect(s.serialized() == text)
    }
}
