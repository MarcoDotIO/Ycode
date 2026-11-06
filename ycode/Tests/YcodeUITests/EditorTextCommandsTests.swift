import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

private func nsr(_ a: Int, _ l: Int = 0) -> NSRange { NSRange(location: a, length: l) }
private func offset(_ text: String, line: Int, column: Int = 0) -> Int { LineIndex(text).range(ofLine: line)!.location + column }

/// The text commands of `reference-ui-5.md` §6.4, as functions of the text.
@Suite struct EditorTextCommandsTests {
    // MARK: Minimap (E5)

    @Test @MainActor func minimapWidth() {
        // 15 % of the editor within 59…135, plus the 1-point separator
        // (editor-area.md §C.5, E.6: the floor and ceiling of round 3).
        #expect(MinimapView.width(forEditorWidth: 962) == 136)
        #expect(MinimapView.width(forEditorWidth: 480) == 73)
        #expect(MinimapView.width(forEditorWidth: 300) == 60)
    }
}
