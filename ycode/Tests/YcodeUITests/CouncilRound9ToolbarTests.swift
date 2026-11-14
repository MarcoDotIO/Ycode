import AppKit
import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore
@testable import YcodeUI

/// Council round 9, group A2, on the macOS IDE (`specs/ide/fidelity-council.md`
/// rows 214–219): the coding assistant button, Open Quickly's panel, the
/// jump bar's collapse and "No Selection", the gap before the toolbar's
/// overflow capsule and the merge sheet's dark segment. Windows stay off
/// every display. With `YCODE_B9_SHOTS=<dir>` the tests save pictures.
@MainActor
@Suite(.serialized) struct CouncilRound9ToolbarTests {
    let r5 = CouncilRound5ChromeTests()

    static func shot(_ w: NSWindow?, _ name: String) {
        guard let w, let dir = ProcessInfo.processInfo.environment["YCODE_B9_SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        UISpacingProbeTests.shot(w, URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    /// A view drawn into a bitmap at `scale` points per point, in sRGB
    /// (as the round 8 tests read colours).
    static func bitmap(_ v: NSView, scale: CGFloat = 2) -> NSBitmapImageRep? {
        guard let base = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width * scale), pixelsHigh: Int(v.bounds.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: base.colorSpaceName, bytesPerRow: 0, bitsPerPixel: 0)?.retagging(with: .sRGB)
        guard let rep else { return nil }
        rep.size = v.bounds.size
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep
    }

    static func hex(_ c: NSColor?) -> UInt32 {
        guard let c = c?.usingColorSpace(.sRGB) else { return 0xFFFF_FFFF }
        return UInt32((c.redComponent * 255).rounded()) << 16 | UInt32((c.greenComponent * 255).rounded()) << 8 | UInt32((c.blueComponent * 255).rounded())
    }

    static func distance(_ a: UInt32, _ b: UInt32) -> Int {
        [16, 8, 0].map { abs(Int(a >> UInt32($0) & 0xFF) - Int(b >> UInt32($0) & 0xFF)) }.max() ?? 0
    }

    // MARK: Row 214: the assistant button

    /// A host for a view on a plain fill, off every display.
    static func host(_ v: NSView, size: NSSize, fill: NSColor, dark: Bool) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height), styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let bg = FillView(frame: NSRect(origin: .zero, size: size))
        bg.fill = fill
        w.contentView = bg
        v.frame.origin = NSPoint(x: (size.width - v.frame.width) / 2, y: (size.height - v.frame.height) / 2)
        bg.addSubview(v)
        return w
    }

    /// The glyph's ink is 18 × 18 (round 10, row 239); its outline's colours follow the angular
    /// gradient clockwise from the top (red-orange at the top, pink at the
    /// right, blue at the bottom, tan at the left), in both appearances.
    @Test(arguments: [false, true]) func assistantGlyphInkAndGradient(dark: Bool) throws {
        typealias G = AssistantButtonGlyph
        let button = AssistantToolbarButton()
        button.frame = NSRect(x: 0, y: 0, width: 36, height: 36)
        let w = Self.host(button, size: NSSize(width: 36, height: 36), fill: .clear, dark: dark)
        defer { w.orderOut(nil) }
        button.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let rep = try #require(Self.bitmap(button, scale: 4))
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let inkW = CGFloat(maxX - minX + 1) / 4, inkH = CGFloat(maxY - minY + 1) / 4
        print("R9A2 214 glyph ink \(inkW) × \(inkH) (\(dark ? "dark" : "light"))")
        #expect(abs(inkW - 18) <= 0.75 && abs(inkH - 18) <= 0.75, "\(inkW) × \(inkH)")
        // The outline's colour on each side, against the shared model.
        let box = (x: (36 - G.width) / 2, y: (36 - G.height) / 2)
        // Read through the window (as the round 8 tests read colours); the
        // button is flipped, so y runs down as the glyph's box.
        func sample(_ gx: Double, _ gy: Double) -> UInt32 {
            CouncilRound8ChromeTests.pixel(NSPoint(x: box.x + gx, y: box.y + gy), in: button)
        }
        let i = G.bubbleStroke / 2
        let probes: [(String, Double, Double)] = [("top", G.center.x, i), ("right", G.width - i, G.center.y), ("left", i, G.center.y - 1)]
        for (side, x, y) in probes {
            let got = sample(x, y)
            let want = AssistantButtonGlyph.color(atDegrees: G.degrees(atX: x, y: y), dark: dark)
            let wantHex = CouncilRound9GroupA2Probe.hex(want)
            print("R9A2 214 \(side): \(String(got, radix: 16)) want \(String(wantHex, radix: 16))")
            #expect(Self.distance(got, wantHex) <= 12, "\(side) \(String(got, radix: 16)) vs \(String(wantHex, radix: 16))")
        }
    }

    /// Hovered, the light capsule darkens from #FBFBFB to #F2F2F2; the dark
    /// one does not change; the toolbar item is the 36-point button.
    @Test(arguments: [false, true]) func assistantHover(dark: Bool) throws {
        let button = AssistantToolbarButton()
        let rest: NSColor = dark ? NSColor(srgbRed: 0x45 / 255.0, green: 0x45 / 255.0, blue: 0x45 / 255.0, alpha: 1)
            : NSColor(srgbRed: 0xFB / 255.0, green: 0xFB / 255.0, blue: 0xFB / 255.0, alpha: 1)
        let w = Self.host(button, size: NSSize(width: 36, height: 36), fill: rest, dark: dark)
        defer { w.orderOut(nil) }
        func corner() throws -> UInt32 {
            // Inside the circle, clear of the glyph: 6 points in from the left at mid height.
            CouncilRound8ChromeTests.pixel(NSPoint(x: 6, y: 18), in: button)
        }
        let before = try corner()
        button.setHovered(true)
        let after = try corner()
        print("R9A2 214 hover (\(dark ? "dark" : "light")): \(String(before, radix: 16)) → \(String(after, radix: 16))")
        #expect(Self.distance(before, dark ? 0x454545 : 0xFBFBFB) <= 1)
        #expect(Self.distance(after, dark ? 0x454545 : 0xF2F2F2) <= 1, "\(String(after, radix: 16))")
        Self.shot(w, "mac-r9-214-hover-\(dark ? "dark" : "light").png")
    }

    @Test func assistantToolbarItem() throws {
        let (wc, _) = try r5.longWindow("r9-assistant")
        defer { wc.window?.orderOut(nil) }
        let item = try #require(wc.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "newConversation" })
        let button = try #require(item.view as? AssistantToolbarButton)
        #expect(button.frame.width == 36 && button.frame.height == 36 && item.isBordered)
        #expect(button.accessibilityLabel() == "New Conversation" && button.accessibilityRole() == .button)
        #expect(button.action == #selector(WorkspaceWindowController.toggleNewConversationPrompt(_:)))
        let w = try #require(wc.window)
        let shapes = CouncilRound8ChromeTests.glassShapes(w, r5)
        let circle = shapes.first { $0.views.contains { $0 === button } }?.rect
        print("R9A2 214 toolbar circle \(String(describing: circle))")
        if let circle { #expect(abs(circle.width - 36) <= 1 && abs(circle.height - 36) <= 1, "\(circle)") }
        Self.shot(w, "mac-r9-214-toolbar-light.png")
        w.appearance = NSAppearance(named: .darkAqua)
        Self.shot(w, "mac-r9-214-toolbar-dark.png")
    }

    // MARK: Row 215: Open Quickly

    /// The panel hosted off screen as the glass panel would show it: one
    /// result for "long", 640 × 130; the separator 54 down, inset 20; the
    /// row 620 × 56 at (10, 64), #0064E1 / #0059D1; the field without
    /// border or focus ring, its text at 66.5; the name at 66 with its
    /// extension dimmed; under it the project's mark and "GlassScroll ›
    /// GlassScroll".
    @Test(arguments: [false, true]) func openQuicklyPanel(dark: Bool) throws {
        typealias Q = OpenQuicklyLayout
        let (wc, _) = try r5.longWindow("r9-oq-\(dark)")
        defer { wc.window?.orderOut(nil) }
        let oq = OpenQuicklyController(candidates: FuzzyMatch.candidates(in: wc.session.model.root))
        let w = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 640, height: 54), styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.contentView = oq.view
        oq.onResize = { h in w.setContentSize(NSSize(width: 640, height: h)) }
        defer { w.orderOut(nil) }
        oq.search("long")
        oq.view.layoutSubtreeIfNeeded()
        #expect(oq.results.count == 1 && oq.results.first?.title == "Long.swift")
        #expect(oq.view.frame.size == NSSize(width: 640, height: 130), "\(oq.view.frame)")
        #expect(oq.separator.frame == NSRect(x: 20, y: 54, width: 600, height: 1), "\(oq.separator.frame)")
        #expect(oq.scroll.frame == NSRect(x: 10, y: 64, width: 620, height: 56), "\(oq.scroll.frame)")
        #expect(oq.magnifier.frame == NSRect(x: 21.5, y: 16.5, width: 21, height: 21), "\(oq.magnifier.frame)")
        #expect(!oq.field.isBezeled && !oq.field.isBordered && oq.field.focusRingType == .none && !oq.field.drawsBackground)
        #expect(oq.field.font?.pointSize == 22 && oq.field.placeholderString == "Open Quickly")
        // The query's first ink at 66.5.
        let text = NSAttributedString(string: "long", attributes: [.font: try #require(oq.field.font)])
            .boundingRect(with: NSSize(width: 400, height: 40), options: [.usesDeviceMetrics, .usesLineFragmentOrigin])
        let queryInk = oq.field.frame.minX + OpenQuicklyField.textInset + text.minX
        print("R9A2 215 query ink x \(queryInk)")
        #expect(abs(queryInk - 66.5) <= 1.5, "\(queryInk)")
        oq.table.layoutSubtreeIfNeeded()
        let cell = try #require(oq.rowCells.first)
        #expect(cell.isSelectedRow)
        #expect(cell.detail.stringValue == "GlassScroll \u{203A} GlassScroll" && !cell.projectGlyph.isHidden)
        let nameX = oq.scroll.frame.minX + cell.convert(cell.name.frame, to: oq.table).minX + 2
        #expect(abs(nameX - 66) <= 0.5, "\(nameX)")
        #expect(abs(oq.scroll.frame.minX + cell.glyph.frame.minX - 23) < 0.01 && cell.glyph.frame.size == NSSize(width: 24.5, height: 20.5))
        // The extension white at 0.75, the base white.
        let s = cell.name.attributedStringValue
        let ext = try #require(s.attribute(.foregroundColor, at: s.length - 1, effectiveRange: nil) as? NSColor)
        let base = try #require(s.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        #expect(abs(ext.alphaComponent - 0.75) < 0.01 && Self.hex(base) == 0xFFFFFF)
        // The selection's fill, sampled beside the name's end.
        oq.view.displayIfNeeded()
        let fill = CouncilRound8ChromeTests.pixel(NSPoint(x: 600, y: 64 + 28), in: oq.view)
        print("R9A2 215 selection \(String(fill, radix: 16)) (\(dark ? "dark" : "light"))")
        #expect(Self.distance(fill, dark ? 0x0059D1 : 0x0064E1) <= 2, "\(String(fill, radix: 16))")
        let sep = CouncilRound8ChromeTests.pixel(NSPoint(x: 320, y: 54.25), in: oq.view)
        #expect(Self.distance(sep, dark ? 0x525252 : 0xE4E4E4) <= 3, "separator \(String(sep, radix: 16))")
        Self.shot(w, "mac-r9-215-open-quickly-\(dark ? "dark" : "light").png")
        // An empty query: the field alone.
        oq.search("")
        #expect(oq.results.isEmpty && oq.view.frame.height == 54 && oq.scroll.isHidden && oq.separator.isHidden)
    }

    // MARK: Row 217: "No Selection" for Markdown and JSON

    @Test func noSelectionForDocumentsWithoutSymbols() throws {
        let (wc, dir) = try r5.longWindow("r9-nosel")
        defer { wc.window?.orderOut(nil) }
        let notes = dir.appendingPathComponent("GlassScroll/NOTES.md"), palette = dir.appendingPathComponent("GlassScroll/palette.json")
        try "# Notes\n\nSome text.\n".write(to: notes, atomically: true, encoding: .utf8)
        try "{ \"accent\": \"#FF0000\" }\n".write(to: palette, atomically: true, encoding: .utf8)
        for url in [notes, palette] {
            wc.open(path: url.path, line: nil)
            r5.spin(0.2)
            #expect(wc.editor.jumpBarSymbol == "No Selection", "\(url.lastPathComponent): \(String(describing: wc.editor.jumpBarSymbol))")
            let bar = wc.editor.jumpBar
            bar.layoutSubtreeIfNeeded()
            let ink = bar.pathInk
            // … name, 7, the 3-wide chevron, 8.5, "No Selection".
            if ink.count >= 3 {
                let (name, chevron, last) = (ink[ink.count - 3], ink[ink.count - 2], ink[ink.count - 1])
                print("R9A2 217 \(url.lastPathComponent): name→chevron \(chevron.minX - name.maxX), chevron \(chevron.maxX - chevron.minX), → last \(last.minX - chevron.maxX)")
                #expect(chevron.view is JumpBarChevronView)
                #expect(abs(chevron.minX - name.maxX - 7) <= 0.75 && abs(last.minX - chevron.maxX - 8.5) <= 0.75)
            } else {
                Issue.record("path \(ink.count)")
            }
            Self.shot(wc.window, "mac-r9-217-\(url.pathExtension)-light.png")
        }
        // The active chevron's colour: #808080 / #DEDEDE.
        for dark in [false, true] {
            let c = JumpBarChevronView.color(active: true)
            var v: UInt32 = 0
            NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance { v = Self.hex(c) }
            #expect(v == (dark ? 0xDEDEDE : 0x808080), "\(String(v, radix: 16))")
        }
        wc.window?.appearance = NSAppearance(named: .darkAqua)
        Self.shot(wc.window, "mac-r9-217-json-dark.png")
    }

    // MARK: Row 216: the collapse at 1250 and 1180 with a split

    /// With a split and the issue stepper (the reference had a warning), at
    /// 1250 and 1180: the groups' icons alone, the project then the file
    /// cut to their initials before they go, "No Selection" whole in the
    /// left pane until the end; text cut with a fade, never an ellipsis.
    @Test func collapseWithAStepper() throws {
        let (wc, dir) = try r5.longWindow("r9-collapse")
        defer { wc.window?.orderOut(nil) }
        let w = try #require(wc.window)
        wc.session.packageIssues = [Diagnostic(severity: .warning, message: "A warning")]
        wc.splitEditor(nil)
        wc.open(path: dir.appendingPathComponent("GlassScroll/Models/Model01.swift").path, line: nil)
        for width in [1250.0, 1180.0] {
            w.setFrame(NSRect(x: -6000, y: -6000, width: width, height: 880), display: true)
            r5.spin(0.3)
            w.contentView?.layoutSubtreeIfNeeded()
            for (i, e) in wc.editorArea.tab.editors.enumerated() {
                let bar = e.jumpBar
                bar.layoutSubtreeIfNeeded()
                let titles = bar.pathState.parts.map { p -> String in
                    let t = p.title
                    if t.isHidden { return "–" }
                    return t.inkCut.map { "\(t.stringValue.prefix(1))…\(Int($0))" } ?? t.stringValue
                }
                let last = bar.pathState.last.map { $0.inkCut.map { "cut \(Int($0))" } ?? $0.stringValue } ?? "none"
                print("R9A2 216 \(Int(width)) pane \(i): \(titles) | \(last)")
                // A cut title keeps at least its initial.
                let parts = bar.pathState.parts
                for p in parts where !p.title.isHidden {
                    if let cut = p.title.inkCut { #expect(cut >= p.title.initialInk - 0.01, "\(p.title.stringValue) \(cut)") }
                }
                // The order: a group's title only with the project's whole;
                // the file's cut only with every leading title gone; the
                // last item cut only with every title gone.
                func whole(_ t: FadingTruncationLabel) -> Bool { !t.isHidden && t.inkCut == nil }
                if parts.count > 2, parts[1..<(parts.count - 1)].contains(where: { !$0.title.isHidden }) { #expect(whole(parts[0].title), "\(titles)") }
                if let file = parts.last?.title, !whole(file) { #expect(parts.dropLast().allSatisfy { $0.title.isHidden }, "\(titles)") }
                if let l = bar.pathState.last, l.inkCut != nil { #expect(parts.allSatisfy { $0.title.isHidden }, "\(titles)") }
                #expect(!e.jumpBar.issueStack.arrangedSubviews.isEmpty, "pane \(i): no stepper")
            }
            Self.shot(w, "mac-r9-216-\(Int(width))-light.png")
        }
    }

    // MARK: Row 218: the gap before the overflow capsule

    /// At 1100 with an error and a warning the editor modes go into the
    /// "»" capsule. The reference's is 5 after the Add Editor capsule;
    /// AppKit's is 26 after it (it keeps the flexible spaces at their
    /// minimum once an item overflows and leaves the overflowed group's
    /// room before the "»"). A spacer taking that room squeezed the
    /// activity view instead, so the gap stays the system's (reported).
    @Test func overflowGapAt1100() throws {
        let (wc, _) = try r5.longWindow("r9-overflow")
        defer { wc.window?.orderOut(nil) }
        let w = try #require(wc.window)
        wc.issueCapsule.errors = 1
        wc.issueCapsule.warnings = 1
        w.setFrame(NSRect(x: -6000, y: -6000, width: 1100, height: 880), display: true)
        r5.spin(0.3)
        wc.fitToolbar()
        w.contentView?.superview?.layoutSubtreeIfNeeded()
        r5.spin(0.3)
        if ProcessInfo.processInfo.environment["YCODE_B9_PROBE"] != nil, let tv = w.standardWindowButton(.closeButton)?.superview {
            func walk(_ v: NSView) {
                let n = String(describing: type(of: v))
                if n.contains("ItemViewer") || n.contains("Clipped") || n.contains("Space") {
                    print("R9A2 218 viewer \(n) \(r5.frameInWindow(v))")
                }
                v.subviews.forEach(walk)
            }
            walk(tv)
        }
        let shapes = CouncilRound8ChromeTests.glassShapes(w, r5)
        for s in shapes {
            let names = Set(s.views.map { String(describing: type(of: $0)) }).sorted().joined(separator: ",")
            print("R9A2 218 shape \(s.rect) \(names.prefix(160))")
        }
        let addEditor = try #require(wc.window?.toolbar?.items.first { $0.itemIdentifier == EditorOptionsMenu.addEditorID })
        #expect(wc.overflowedToolbarItems.contains("editorModes"), "\(wc.overflowedToolbarItems)")
        _ = addEditor
        let inspectorEdge = r5.frameInWindow(wc.inspector.view).minX
        // The Add Editor capsule: the shape after the issue capsule; the
        // overflow: the last shape before the inspector's toggle.
        let issues = shapes.first { $0.views.contains { $0 === wc.issueCapsule } }?.rect
        let after = shapes.filter { $0.rect.minX > (issues?.maxX ?? 0) && $0.rect.maxX <= inspectorEdge + 1 }.map(\.rect)
        print("R9A2 218 after issues: \(after), inspector edge \(inspectorEdge)")
        if after.count >= 2 {
            let gap = after[1].minX - after[0].maxX
            print("R9A2 218 gap Add Editor → » \(gap)")
            // Its own capsule, after Add Editor's, before the inspector's edge.
            #expect(gap >= 4 && gap <= 30 && after[1].maxX <= inspectorEdge - 6, "\(gap)")
        } else {
            Issue.record("shapes after the issue capsule: \(after)")
        }
        Self.shot(w, "mac-r9-218-overflow-light.png")
        w.appearance = NSAppearance(named: .darkAqua)
        Self.shot(w, "mac-r9-218-overflow-dark.png")
    }
}

/// A plain fill drawn by the view (no layer colour conversion).
final class FillView: NSView {
    var fill: NSColor = .clear
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        dirtyRect.fill()
    }
}

/// Hex of a model colour (shared with the core tests' helper).
enum CouncilRound9GroupA2Probe {
    static func hex(_ c: (r: Double, g: Double, b: Double)) -> UInt32 {
        UInt32((c.r * 255).rounded()) << 16 | UInt32((c.g * 255).rounded()) << 8 | UInt32((c.b * 255).rounded())
    }
}
