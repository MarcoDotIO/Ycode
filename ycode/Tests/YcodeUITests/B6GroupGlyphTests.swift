import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Council round 6, row 166 (`editor-area.md` H.9): the Repositories view's
/// Recents and Stashes groups take filled grey glyphs like the others (a
/// clock in a filled circle, a filled tray), the same names as the Linux
/// IDE's own artwork. Photographs the navigator off every display, light
/// and dark, to `.build-ide/b3-shots/` (B6-OPENVIEWS).
@MainActor
@Suite(.serialized) struct B6GroupGlyphTests {
    @Test func recentsAndStashesAreFilledInTheNavigator() throws {
        #expect(RepositoriesViewStyle.groupSymbols["Recents"] == "clock.fill")
        #expect(RepositoriesViewStyle.groupSymbols["Stashes"] == "tray.fill")
        for name in ["clock.fill", "tray.fill"] { #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)") }
        let tree = SourceControlNavigatorModel.repositoriesTree(
            repository: "FlickDemo", branch: "main",
            branches: [.init(name: "main", isCurrent: true), .init(name: "release", isCurrent: false), .init(name: "feature/observe", isCurrent: false)],
            recents: ["release", "feature/observe"], tags: [.init(name: "v1.0", isCurrent: false)],
            stashes: ["stash@{0}: WIP on main: e570b2d Package"], remotes: [], remoteBranches: [])
        let repo = try #require(tree.first)
        #expect(repo.children.map(\.symbol) == ["square.stack.3d.up.fill", "clock.fill", "tag.fill", "tray.fill", "globe"])

        let fc = FidelityCouncilTests()
        let dir = try fc.project("b6-scm")
        let wc = try fc.window(dir)
        wc.window?.isExcludedFromWindowsMenu = true
        wc.window?.setFrame(NSRect(x: -6000, y: -6000, width: 1400, height: 880), display: false)
        defer { wc.window?.close() }
        let nav = wc.navigator
        nav.select(1)
        nav.setSourceControlRoots(tree)
        nav.outline.expandItem(repo.children[1])
        nav.outline.expandItem(repo.children[3])
        let out = ycodeDir.appendingPathComponent(".build-ide/b3-shots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            wc.window?.appearance = NSAppearance(named: appearance)
            let view: NSView = nav.view
            view.layoutSubtreeIfNeeded()
            let rect = NSRect(x: 0, y: view.isFlipped ? 0 : max(0, view.bounds.height - 420), width: view.bounds.width, height: min(420, view.bounds.height))
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: rect))
            view.cacheDisplay(in: rect, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            let url = out.appendingPathComponent("b6-scm-groups-mac-\(scheme).png")
            try png.write(to: url)
            print("B6GLYPH shot \(url.path)")
        }
        let shown = (0..<nav.outline.numberOfRows).compactMap { (nav.outline.item(atRow: $0) as? OutlineItem)?.title }
        #expect(shown.contains("Recents") && shown.contains("Stashes"))
    }
}
