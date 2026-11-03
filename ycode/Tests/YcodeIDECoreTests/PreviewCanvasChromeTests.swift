import Foundation
import Testing
@testable import YcodeIDECore
import YcodePreviews

/// reference-ui-4.md §10 and §17: canvas states, header tabs, bottom bar,
/// device menu, settings and placement (no builds).
@MainActor
@Suite(.timeLimit(.minutes(30))) struct PreviewCanvasChromeTests {
    @Test func tabTitlesFromNameOrViewType() {
        let p = PreviewDiscovery.previews(in: "#Preview(\"Named\") { Text(\"a\") }\n#Preview {\n  @Previewable @State var x = 1\n  Badge(text: \"b\")\n}\n#Preview { 42 }")
        #expect(p.map(\.tabTitle) == ["Named", "Badge", "Preview 2"])
        #expect(p.map(\.isNamed) == [true, false, false])
    }
}
