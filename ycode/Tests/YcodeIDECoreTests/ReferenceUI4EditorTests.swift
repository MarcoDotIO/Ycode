import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore

/// reference-ui-4.md §4 (inline issues) and §7 (Quick Help).
@Suite struct ReferenceUI4EditorTests {
    static let hover = """
    ```swift
    func area(of circle: Circle, scale: Double) throws -> Double
    ```

    ---

    Computes the area of a circle.

    The result is scaled.
    Second line of the discussion.

    - Parameters:
      - circle: The circle to measure.
      - scale: A factor applied to
        the result.
    - Returns: The scaled area.
    - Throws: `GeometryError` for a negative radius.
    - Note: Uses `Double.pi`.
    - Warning: Not for huge circles.
    """

    @Test func quickHelpParsesSwiftMarkup() {
        let d = QuickHelpDocument(hover: Self.hover, file: "/tmp/Geometry.swift")
        #expect(d.title == "area")
        #expect(d.summary == "Computes the area of a circle.")
        #expect(d.declaration.hasPrefix("func area(of circle"))
        #expect(d.parameters.map(\.name) == ["circle", "scale"])
        #expect(d.parameters[1].text == "A factor applied to the result.")
        #expect(d.returns == "The scaled area.")
        #expect(d.throwsText == "GeometryError for a negative radius.")
        #expect(d.discussion == ["The result is scaled. Second line of the discussion."])
        #expect(d.callouts.map(\.title) == ["Note", "Warning"])
        #expect(d.sectionOrder == ["Title", "Summary", "Declaration", "File", "Parameters", "Return Value", "Throws",
                                   "Discussion", "Note", "Warning", "Open in Developer Documentation"])
    }

    @Test func quickHelpSingleParameterAndUndocumented() {
        let one = QuickHelpDocument(hover: "```swift\nfunc f(x: Int)\n```\n\nDoes f.\n\n- Parameter x: The x.\n")
        #expect(one.parameters == [.init(name: "x", text: "The x.")])
        let bare = QuickHelpDocument(hover: "```swift\nstruct Circle\n```")
        #expect(bare.title == "Circle")
        #expect(bare.sectionOrder == ["Title", "Declaration", "Open in Developer Documentation"])
    }
}
