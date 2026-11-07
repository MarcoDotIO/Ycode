import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// Council round 5, group D, panes (`specs/ide/fidelity-council.md` rows
/// 133, 135, 113; `editor-area.md` G.1, G.5, G.9) and the navigator and
/// inspector parity items (`cross-platform-parity.md` §3, §5, §7, §8). The
/// windows stay off every display.
@MainActor
@Suite(.serialized) struct CouncilRound5PanesTests {
    /// A council window at the capture's size, off every display.
    func councilWindow(_ tag: String) throws -> (WorkspaceWindowController, URL) {
        let fc = FidelityCouncilTests()
        let dir = try fc.project("r5-\(tag)")
        let wc = try fc.window(dir)
        if let w = wc.window { w.setFrame(NSRect(x: -6000, y: -6000, width: 1400, height: 880), display: false) }
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        return (wc, dir)
    }

    func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }

    /// A view's frame in window points from the window's top left.
    func top(_ v: NSView, in w: NSWindow) -> (y: CGFloat, maxY: CGFloat, x: CGFloat) {
        let r = v.convert(v.bounds, to: nil)
        let h = w.frame.height
        return (h - r.maxY, h - r.minY, r.minX)
    }

    // MARK: Row 135: the image inspector's spacing (G.5)

    @Test func imageInspectorFollowsTheReferenceRhythm() throws {
        let (wc, dir) = try councilWindow("image")
        defer { wc.window?.close() }
        let w = try #require(wc.window)
        wc.open(path: dir.appendingPathComponent("GlassScroll/Stripes.png").path, line: nil)
        wc.inspector.imageProperties = ImageFileProperties(pixelWidth: 80, pixelHeight: 180, dpi: 72, colorSpace: "RGB", hasAlpha: false)
        w.contentView?.layoutSubtreeIfNeeded()
        let views = all(wc.inspector.view)
        func label(_ s: String) throws -> NSView {
            try #require(views.first { ($0 as? NSTextField)?.stringValue == s && !$0.isHidden }, "\(s)")
        }
        // Ink tops are 2.5 below an 11-point label's frame.
        func ink(_ s: String) throws -> CGFloat { try top(label(s), in: w).y + 2.5 }
        // The rules' lines (a separator box draws its line at its middle).
        let rules = views.compactMap { $0 as? NSBox }.filter { $0.boxType == .separator && $0.frame.width < 300 && $0.frame.width > $0.frame.height }
            .map { (top($0, in: w).y + top($0, in: w).maxY - 1) / 2 }.sorted()
        let tags = try #require(wc.inspector.fileControls["On Demand Resource Tags"])
        let localize = try #require(wc.inspector.fileControls["Localize"])
        let report = String(format: "ODR %.1f tags %.1f–%.1f IP %.1f rows %@ Loc %.1f button %.1f–%.1f TM %@ rules %@",
                            try ink("On Demand Resource Tags"), top(tags, in: w).y, top(tags, in: w).maxY, try ink("Image Properties"),
                            try ["Dimensions", "Resolution", "Color Space", "Alpha Channel"].map { String(format: "%.1f", try ink($0)) }.joined(separator: ","),
                            try ink("Localization"), top(localize, in: w).y, top(localize, in: w).maxY,
                            (try? ink("Target Membership")).map { String(format: "%.1f", $0) } ?? "-",
                            rules.map { String(format: "%.1f", $0) }.joined(separator: ","))
        print("R5PANES image inspector: \(report)")
        func near(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 1.5) -> Bool { abs(a - b) <= tol }
        // G.5's reference values, from the On Demand Resource Tags header
        // (267; the rows above it depend on the path's length).
        let o = try ink("On Demand Resource Tags") - 267
        #expect(near(top(tags, in: w).y - o, 289) && near(top(tags, in: w).maxY - o, 313), "\(report)")
        #expect(near(try ink("Image Properties") - o, 333.5), "\(report)")
        let rows = try ["Dimensions", "Resolution", "Color Space", "Alpha Channel"].map { try ink($0) - o }
        for (a, b) in zip(rows, [359, 377, 395.5, 413.5] as [CGFloat]) { #expect(near(a, b), "\(report)") }
        for (a, b) in zip(rows.dropFirst(), rows) { #expect(near(a - b, 18, 0.75), "\(report)") }
        #expect(near(try ink("Localization") - o, 444.5), "\(report)")
        #expect(near(top(localize, in: w).y - o, 472.5) && near(top(localize, in: w).maxY - o, 488.5), "\(report)")
        #expect(near(try ink("Target Membership") - o, 513.5), "\(report)")
        for r in [325, 436, 505] as [CGFloat] { #expect(rules.contains { near($0 - o, r) }, "rule at \(r): \(report)") }
    }

    // MARK: Row 133: the inspector's slide (G.1)

    /// A measurement (`R5_PROFILE=1`): the per-frame cost of the slide's
    /// layout and drawing with Long.swift open, the window ordered in off
    /// every display.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["R5_PROFILE"] != nil), arguments: [true, false])
    func profileInspectorSlide(wrap: Bool) throws {
        let prefs = IsolatedPreferences("r5-profile")
        defer { prefs.restore() }
        Preferences.shared.wrapLines = wrap
        let (wc, dir) = try councilWindow("profile")
        defer { wc.window?.close() }
        let w = try #require(wc.window)
        // Off every display: AppKit would move it onto a screen as it orders in.
        MergeSheetR5UITests.Offscreen.on()
        defer { MergeSheetR5UITests.Offscreen.off() }
        w.setFrame(NSRect(x: -6000, y: -6000, width: 1400, height: 880), display: false)
        w.orderBack(nil)
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        w.contentView?.layoutSubtreeIfNeeded()
        w.displayIfNeeded()
        let split = wc.mainSplit.splitView
        let total = split.bounds.width, divider = split.dividerThickness
        let width = wc.inspector.view.frame.width
        wc.inspectorItem.minimumThickness = 1
        wc.inspector.beginRigidSlide(width: width)
        defer { wc.inspector.endRigidSlide() }
        let passes = ProcessInfo.processInfo.environment["R5_SAMPLE"] != nil && wrap ? 600 : 3
        if passes > 3 { print("R5START"); fflush(stdout) }
        for pass in 0..<passes {
            var editor: [Double] = [], layout: [Double] = [], display: [Double] = []
            for i in 0...24 {
                let p = EditorMetrics.cubicBezier(Double(i % 13) / 12, x1: 0.42, y1: 0, x2: 0.58, y2: 1)
                let q = i < 13 ? p : 1 - p
                let x = (total - divider - width + (width - 1) * CGFloat(q)).rounded()
                let t0 = CACurrentMediaTime()
                split.setPosition(x, ofDividerAt: 1)
                let ta = CACurrentMediaTime()
                wc.centerSplit.splitView.layoutSubtreeIfNeeded()
                let tb = CACurrentMediaTime()
                wc.editor.view.layoutSubtreeIfNeeded()
                let t1 = CACurrentMediaTime()
                if pass == 1, wrap {
                    print(String(format: "R5PROFILE   frame %d hidden %.2f: setPosition %.1f center split %.1f editor %.1f", i, q, (ta - t0) * 1000, (tb - ta) * 1000, (t1 - tb) * 1000))
                }
                w.contentView?.layoutSubtreeIfNeeded()
                let t2 = CACurrentMediaTime()
                w.displayIfNeeded()
                let t3 = CACurrentMediaTime()
                editor.append((t1 - t0) * 1000); layout.append((t2 - t1) * 1000); display.append((t3 - t2) * 1000)
            }
            func f(_ a: [Double]) -> String { String(format: "mean %.1f max %.1f", a.reduce(0, +) / Double(a.count), a.max() ?? 0) }
            if pass < 3 { print("R5PROFILE wrap \(wrap) pass \(pass): split+editor \(f(editor)) rest \(f(layout)) display \(f(display))") }
        }
    }

    // MARK: Parity §7: Source Control rows

    /// A changed file has the project navigator's glyph and colour on both
    /// IDEs (`cross-platform-parity.md` §7), never a trademark-shaped symbol.
    @Test func changedFilesUseTheProjectNavigatorsGlyphs() {
        let forbidden = ["swift", "hammer", "hammer.fill", "xcode"]
        for name in ["a.swift", "b.xcodeproj", "c.png", "d.plist"] {
            #expect(!forbidden.contains(SourceControlNavigatorModel.symbol(for: name)), "\(name)")
            #expect(!forbidden.contains(SourceControlInspector.fileSymbol(name)), "\(name)")
        }
        #expect(SourceControlNavigatorModel.symbol(for: "a.swift") == WorkspaceChrome.fileSymbol("a.swift"))
        let tree = SourceControlNavigatorModel.changesTree(repository: "R", branch: "main",
                                                           changes: [GitRepository.Change(path: "/r/a.swift", index: " ", worktree: "M", status: .modified)],
                                                           root: URL(fileURLWithPath: "/r"))
        let file = tree[0].children[0].children[0]
        #expect(file.symbol == WorkspaceChrome.fileSymbol("a.swift"))
        #expect(file.tint == OutlineItem.color(.orange))
    }
}
