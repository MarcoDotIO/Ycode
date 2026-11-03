import AppKit
import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A package whose tests run with `swift test`: XCTest (one pass, one
/// fail) and swift-testing (one pass).
func writeTestPackage(at dir: URL) throws {
    let fm = FileManager.default
    try? fm.removeItem(at: dir)
    func write(_ rel: String, _ text: String) throws {
        let u = dir.appendingPathComponent(rel)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }
    try write("Package.swift", """
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(name: "Calc", targets: [.target(name: "Calc"), .testTarget(name: "CalcTests", dependencies: ["Calc"])])

    """)
    try write("Sources/Calc/Calc.swift", "public func sum(_ a: Int, _ b: Int) -> Int { a + b }\n")
    try write("Tests/CalcTests/CalcTests.swift", """
    import XCTest
    import Testing
    @testable import Calc

    final class CalcTests: XCTestCase {
        func testAdds() { XCTAssertEqual(sum(1, 2), 3) }
        func testBroken() { XCTAssertEqual(sum(1, 1), 3) }
    }

    @Test func addsZero() { #expect(sum(5, 0) == 5) }

    """)
}

@MainActor
@Suite(.serialized, .heavyIntegration, .timeLimit(.minutes(5))) struct TestRunEndToEndTests {
    @Test func runsTestsAndMarksResults() async throws {
        _ = NSApplication.shared
        let dir = ycodeDir.appendingPathComponent(".build-ide/test-run")
        try writeTestPackage(at: dir)
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        await session.testsDiscovered()   // read in the background
        #expect(session.tests.map(\.identifier) == ["CalcTests/testAdds", "CalcTests/testBroken", "addsZero"])
        let file = dir.appendingPathComponent("Tests/CalcTests/CalcTests.swift").path
        wc.open(path: file, line: nil)
        #expect(wc.editor.gutter.marks.tests == [5: .notRun, 6: .notRun, 7: .notRun, 10: .notRun])

        let outcomes = await session.runTests()
        #expect(outcomes.contains { $0.name == "testAdds" && $0.status == .passed })
        let byName = Dictionary(uniqueKeysWithValues: session.tests.map { ($0.name, session.testResults[$0]) })
        #expect(byName["testAdds"] == .passed && byName["testBroken"] == .failed && byName["addsZero"] == .passed)
        #expect(wc.editor.gutter.marks.tests == [5: .failed, 6: .passed, 7: .failed, 10: .passed])
        #expect(session.issues.contains { $0.location?.line == 7 })
        #expect(session.reports.first?.title.hasPrefix("Test") == true && session.reports.first?.succeeded == false)

        wc.navigator.select(5)
        let plan = try #require(wc.navigator.rows(5).first)
        // reference-ui-6.md §5.4 (R45): "<n> Tests" only.
        #expect(plan.detail?.hasSuffix("Tests") == true && plan.detail?.contains("Failing") == false)
        let suite = try #require(plan.children.first?.children.first)
        #expect(suite.title == "CalcTests" && suite.trailingSymbol == "xmark.diamond.fill")
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "test-navigator.png")

        // A test's diamond runs only that test; the class diamond runs the class.
        #expect(session.testsForDiamond(file: file, line: 6).map(\.identifier) == ["CalcTests/testAdds"])
        #expect(session.testsForDiamond(file: file, line: 5).map(\.identifier) == ["CalcTests/testAdds", "CalcTests/testBroken"])
        let single = await session.runTests(only: session.testsForDiamond(file: file, line: 6))
        #expect(single.map(\.name) == ["testAdds"] && single.first?.status == .passed)
        #expect(session.reports.first?.succeeded == true)
    }
}
