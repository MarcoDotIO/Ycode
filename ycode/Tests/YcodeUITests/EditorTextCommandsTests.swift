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
        // min(128, 15 % of the editor) plus the 1-point separator (editor-area.md §C.5).
        #expect(MinimapView.width(forEditorWidth: 962) == 129)
        #expect(MinimapView.width(forEditorWidth: 480) == 73)
        #expect(MinimapView.width(forEditorWidth: 300) == 46)
    }
}
