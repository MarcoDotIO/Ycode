import AppKit
import Foundation
import Testing
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Regression: with a panel-backed editor (project or plist editor) shown,
/// the jump bar used to come out blank in window captures, because the
/// panel painted the whole dirty rect it was given, past its own bounds.
@MainActor
@Suite(.serialized) struct JumpBarRenderingTests {
    @Test func jumpBarDrawsAboveAPanelEditor() throws {
        _ = NSApplication.shared
        let dir = try WindowSnapshotTests().samplePackage()
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        wc.editor.showAuxiliary(PanelBackgroundView(), path: [("Probe", "doc"), ("File.txt", "doc.text")])
        let frame = wc.window!.contentView!.superview!
        _ = try WindowSnapshotTests().render(frame, to: "jump-bar-over-panel.png")
        let rep = try #require(NSBitmapImageRep(data: try Data(contentsOf: ycodeDir.appendingPathComponent(".build-ide/snapshots/jump-bar-over-panel.png"))))
        let bar = frame.convert(wc.editor.jumpBar.bounds, from: wc.editor.jumpBar)
        let scale = CGFloat(rep.pixelsWide) / frame.bounds.width
        var darkest: CGFloat = 1
        for x in stride(from: bar.minX, to: min(bar.maxX, bar.minX + 250), by: 1) {
            for y in stride(from: bar.minY, to: bar.maxY, by: 1) {
                if let c = rep.colorAt(x: Int(x * scale), y: Int((frame.bounds.height - y) * scale))?.usingColorSpace(.sRGB) {
                    darkest = min(darkest, c.brightnessComponent)
                }
            }
        }
        #expect(darkest < 0.3, "jump bar text not drawn (darkest \(darkest))")
    }
}
