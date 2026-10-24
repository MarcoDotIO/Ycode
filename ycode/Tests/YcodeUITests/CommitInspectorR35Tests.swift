import AppKit
import Foundation
import Testing
@testable import YcodeUI

/// reference-ui-4.md §2.6 (reference-ui-5.md §11.6, P16): the Commit
/// section's Files rows carry file icons, names and status letters.
@MainActor
@Suite struct CommitInspectorR35Tests {
    @Test func filesRowsHaveIconsNamesAndStatus() {
        _ = NSApplication.shared
        let rows = SourceControlInspector.fileRows("M  Sources/App/main.swift\nA  Assets.xcassets\nD  Info.plist")
        #expect(rows.map(\.name) == ["main.swift", "Assets.xcassets", "Info.plist"])
        #expect(rows.map(\.status) == ["M", "A", "D"])
        #expect(rows.map(\.symbol) == ["swift", "photo.on.rectangle", "list.bullet.rectangle"])
        #expect(rows.allSatisfy { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) != nil })
        let v = SourceControlInspector.view(sections: [("Commit", [("Identifier", "abc"), ("Files", "M  Sources/App/main.swift\nA  README.md")])])
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        let fileViews = all(v).filter { $0.identifier?.rawValue.hasPrefix("commitFile:") == true }
        #expect(fileViews.count == 2)
        let first = all(fileViews[0])
        #expect(first.contains { $0 is NSImageView })
        #expect(first.compactMap { ($0 as? NSTextField)?.stringValue } == ["main.swift", "M"])
        let tips = first.compactMap { ($0 as? NSTextField)?.toolTip }
        #expect(tips.contains("Sources/App/main.swift"))
    }
}
