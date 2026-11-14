import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// Council round 9, group A1, on the macOS IDE (`specs/ide/fidelity-council.md`
/// rows 208–213): the navigator's file glyphs (single-colour line art in
/// the reference's box and tints, white on a focused selection, the
/// unfocused tint on a selected row without focus), the JSON glyph,
/// folders and the project row, the glyphs in the jump bar and Open
/// Quickly, and the title area's mark and build ring. Windows stay off
/// every display. With `YCODE_B9_SHOTS=<dir>` the tests save pictures.
@MainActor
@Suite(.serialized) struct CouncilRound9GlyphUITests {
    let r5 = CouncilRound5ChromeTests()

    static func shot(_ w: NSWindow?, _ name: String) {
        guard let w, let dir = ProcessInfo.processInfo.environment["YCODE_B9_SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        UISpacingProbeTests.shot(w, URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    /// A picture of a view drawn alone at 2x (the sidebar is missing from
    /// a picture of a window drawn off the displays), over `fill`.
    static func viewShot(_ v: NSView, _ name: String, dark: Bool) {
        guard let dir = ProcessInfo.processInfo.environment["YCODE_B9_SHOTS"],
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width * 2), pixelsHigh: Int(v.bounds.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = v.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (dark ? NSColor(srgbRed: 0x25 / 255.0, green: 0x26 / 255.0, blue: 0x27 / 255.0, alpha: 1)
              : NSColor(srgbRed: 0xF2 / 255.0, green: 0xF2 / 255.0, blue: 0xF3 / 255.0, alpha: 1)).setFill()
        NSRect(origin: .zero, size: v.bounds.size).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let over = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8,
                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            over.size = v.bounds.size
            v.cacheDisplay(in: v.bounds, to: over)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSImage(size: v.bounds.size).then { $0.addRepresentation(over) }.draw(in: NSRect(origin: .zero, size: v.bounds.size))
            NSGraphicsContext.restoreGraphicsState()
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    /// The test project's tree with round 9's test files (Bands.swift,
    /// convert.py, NOTES.md, palette.json at depth 2).
    static func tree() -> NavigatorNode {
        NavigatorNode(name: "GlassScroll", kind: .container, path: "/tmp/r9/GlassScroll.xcodeproj", children: [
            NavigatorNode(name: "GlassScroll", kind: .folder, path: "/tmp/r9/GlassScroll", children: [
                NavigatorNode(name: "Models", kind: .folder, path: "/tmp/r9/GlassScroll/Models", children: []),
                NavigatorNode(name: "Bands.swift", kind: .file, path: "/tmp/r9/GlassScroll/Bands.swift"),
                NavigatorNode(name: "convert.py", kind: .file, path: "/tmp/r9/GlassScroll/convert.py"),
                NavigatorNode(name: "NOTES.md", kind: .file, path: "/tmp/r9/GlassScroll/NOTES.md"),
                NavigatorNode(name: "palette.json", kind: .file, path: "/tmp/r9/GlassScroll/palette.json"),
            ]),
            NavigatorNode(name: "Plain", kind: .group, path: "/tmp/r9/Plain", objectID: "PLAIN", children: []),
        ])
    }

    /// The most frequent colour of a view's own drawing (at 2x, over
    /// nothing) that is opaque, as 0xRRGGBB. The sidebar is not in a
    /// picture of the window drawn off the displays, so the icon view is
    /// drawn alone, as the window draws it (no vibrancy).
    static func ink(of v: NSView, appearance: NSAppearance) -> UInt32? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width * 2), pixelsHigh: Int(v.bounds.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = v.bounds.size
        appearance.performAsCurrentDrawingAppearance { v.cacheDisplay(in: v.bounds, to: rep) }
        let srgb = rep.retagging(with: .sRGB) ?? rep
        var counts: [UInt32: Int] = [:]
        for y in 0..<srgb.pixelsHigh {
            for x in 0..<srgb.pixelsWide {
                guard let c = srgb.colorAt(x: x, y: y), c.alphaComponent > 0.99 else { continue }
                let v = UInt32((c.redComponent * 255).rounded()) << 16 | UInt32((c.greenComponent * 255).rounded()) << 8
                    | UInt32((c.blueComponent * 255).rounded())
                counts[v, default: 0] += 1
            }
        }
        return counts.max { $0.value < $1.value }?.key
    }

    static func near(_ a: UInt32, _ b: UInt32, _ tolerance: Int = 3) -> Bool {
        (0..<3).allSatisfy { abs(Int(a >> (8 * $0) & 255) - Int(b >> (8 * $0) & 255)) <= tolerance }
    }

    static func hex(_ c: NSColor?, dark: Bool) -> UInt32 {
        var v: UInt32 = 0
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            guard let s = c?.usingColorSpace(.sRGB) else { return }
            v = UInt32((s.redComponent * 255).rounded()) << 16 | UInt32((s.greenComponent * 255).rounded()) << 8 | UInt32((s.blueComponent * 255).rounded())
        }
        return v
    }

    func window(_ tag: String) throws -> (WorkspaceWindowController, NSOutlineView) {
        let (wc, _) = try r5.longWindow("r9-\(tag)")
        wc.navigator.setProjectTree(Self.tree())
        let o = wc.navigator.outlineView
        o.expandItem(nil, expandChildren: true)
        o.layoutSubtreeIfNeeded()
        return (wc, o)
    }

    func row(_ o: NSOutlineView, _ title: String) throws -> Int {
        // By the row's file name (the title may hide its extension).
        try #require((0..<o.numberOfRows).first { r in
            guard let item = o.item(atRow: r) as? OutlineItem else { return false }
            return item.title == title || item.nodePath.map { ($0 as NSString).lastPathComponent == title } == true
        }, "\(title) in \((0..<o.numberOfRows).compactMap { (o.item(atRow: $0) as? OutlineItem)?.title })")
    }

    /// An icon's frame in the window (y down) and the cell.
    func icon(_ o: NSOutlineView, _ row: Int) throws -> (frame: NSRect, cell: NavigatorCellView) {
        let cell = try #require(o.view(atColumn: 0, row: row, makeIfNecessary: true) as? NavigatorCellView)
        let image = try #require(cell.imageView)
        return (r5.frameInWindow(image), cell)
    }

    // MARK: Row 208: box, position and the line-art drawing

    /// A file glyph at depth 2 spans x 55.5–70 (14.5 wide), centred on its
    /// row; JSON 54.5–71; the name starts about 6 after the glyph; the
    /// project's mark spans x 27–42.
    @Test func glyphBoxesAndPositions() throws {
        let (wc, o) = try window("boxes")
        defer { wc.window?.orderOut(nil) }
        for (title, expected) in [("Bands.swift", (55.5, 70.0)), ("NOTES.md", (55.5, 70.0)), ("palette.json", (54.5, 71.0))] {
            let r = try row(o, title)
            let (f, cell) = try icon(o, r)
            let item = try #require(o.item(atRow: r) as? OutlineItem)
            let icon = try #require(item.rowIcon)
            let d = try #require(FileGlyphs.navigatorDrawing(icon))
            #expect(icon.isGlyph && cell.imageView is NavigatorFlatIconView && cell.imageView?.image?.isTemplate == true)
            let left = f.midX - CGFloat(d.width) / 2
            // Laid out at 1x off the displays, the frame snaps to whole
            // points; unsnapped, the glyph's centre is the reference's 62.75.
            let unsnapped = r5.frameInWindow(cell).minX + NavigatorAreaController.iconInset - NavigatorAreaController.glyphLeadOut + 9
            #expect(abs(unsnapped - 62.75) < 0.01, "\(title) centre \(unsnapped)")
            #expect(abs(left - expected.0) <= 0.5 && abs(left + CGFloat(d.width) - expected.1) <= 0.5, "\(title) \(left)")
            let label = try #require(cell.textField)
            // The label's frame where it was (its text's ink about 3 in: x 76).
            let labelX = r5.frameInWindow(label).minX
            #expect(abs(labelX - 73) <= 0.5, "\(title) label \(labelX)")
            let rowRect = r5.frameInWindow(try #require(o.rowView(atRow: r, makeIfNecessary: true)))
            #expect(abs(f.midY - rowRect.midY) <= 0.5)
        }
        let project = try icon(o, 0)
        #expect(abs(project.frame.midX - 34.5) <= 0.5 && project.cell.imageView?.image?.size == NSSize(width: 15, height: 15),
                "project \(project.frame)")
        Self.shot(wc.window, "mac-r9-208-navigator-light.png")
    }

    // MARK: Rows 208, 209, 210, 213: tints on screen

    /// The glyphs' ink is the type's tint, in light and in dark.
    @Test func glyphTintsOnScreen() throws {
        let (wc, o) = try window("tints")
        defer { wc.window?.orderOut(nil) }
        let w = try #require(wc.window)
        let cases: [(String, GlyphColor)] = [
            ("Bands.swift", GlyphColor(0xF77640, 0xFFA54D)), ("convert.py", GlyphColor(0xEFBD00, 0xFFF62A)),
            ("NOTES.md", GlyphColor(0x52788D, 0xCCEAFF)), ("palette.json", GlyphColor(0xEE2C22, 0xFF695E)),
            ("Models", GlyphColor(0x3FA1F6, 0x5BC6FF)), ("Plain", GlyphColor(0x7B7B80, 0xB6B7BC)),
        ]
        o.deselectAll(nil)
        for dark in [false, true] {
            w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            o.reloadData()
            o.expandItem(nil, expandChildren: true)
            o.layoutSubtreeIfNeeded()
            for (title, tint) in cases {
                let r = try row(o, title)
                let cell = try icon(o, r).cell
                #expect(Self.hex(cell.imageView?.contentTintColor, dark: dark) == tint.hex(dark: dark), "\(title) \(dark)")
                let image = try #require(cell.imageView)
                let found = Self.ink(of: image, appearance: NSAppearance(named: dark ? .darkAqua : .aqua)!)
                #expect(found.map { Self.near($0, tint.hex(dark: dark)) } == true,
                        "\(title) \(dark ? "dark" : "light"): \(found.map { String($0, radix: 16) } ?? "none")")
            }
            Self.shot(w, "mac-r9-208-navigator-\(dark ? "dark" : "light").png")
            Self.viewShot(o, "mac-r9-208-outline-\(dark ? "dark" : "light").png", dark: dark)
        }
    }

    // MARK: Rows 208, 209: selection states

    /// White on a focused selection (Markdown too, row 209); on a selected
    /// row without focus the type's tint, Swift's #EC6D38 / #FFB75F.
    @Test func selectionStates() throws {
        let (wc, o) = try window("selection")
        defer { wc.window?.orderOut(nil) }
        for title in ["Bands.swift", "NOTES.md", "palette.json", "Models"] {
            let r = try row(o, title)
            o.selectRowIndexes([r], byExtendingSelection: false)
            let rv = try #require(o.rowView(atRow: r, makeIfNecessary: true) as? NavigatorRowView)
            let cell = try icon(o, r).cell
            rv.isEmphasized = true
            cell.backgroundStyle = rv.interiorBackgroundStyle
            #expect(Self.hex(cell.imageView?.contentTintColor, dark: false) == 0xFFFFFF, "\(title) focused")
            rv.isEmphasized = false
            cell.backgroundStyle = rv.interiorBackgroundStyle
            let item = try #require(o.item(atRow: r) as? OutlineItem)
            let t = WorkspaceChrome.iconTint(kind: item.nodeKind ?? .file, name: title)
            let expected = try #require(FileGlyphs.unfocusedSelectedTint(t))
            for dark in [false, true] {
                #expect(Self.hex(cell.imageView?.contentTintColor, dark: dark) == expected.hex(dark: dark), "\(title) unfocused \(dark)")
            }
            if title == "NOTES.md" {
                rv.isEmphasized = true
                cell.backgroundStyle = rv.interiorBackgroundStyle
                Self.shot(wc.window, "mac-r9-209-markdown-focused.png")
                Self.viewShot(o, "mac-r9-209-outline-markdown-focused.png", dark: false)
            }
        }
        // Swift's unfocused tint differs from its tint on no band.
        let r = try row(o, "Bands.swift")
        o.selectRowIndexes([r], byExtendingSelection: false)
        let rv = try #require(o.rowView(atRow: r, makeIfNecessary: true) as? NavigatorRowView)
        rv.isEmphasized = false
        let cell = try icon(o, r).cell
        cell.applyStyle()
        #expect(Self.hex(cell.imageView?.contentTintColor, dark: false) == 0xEC6D38 && Self.hex(cell.imageView?.contentTintColor, dark: true) == 0xFFB75F)
        Self.viewShot(o, "mac-r9-208-outline-swift-unfocused-light.png", dark: false)
        Self.viewShot(o, "mac-r9-208-outline-swift-unfocused-dark.png", dark: true)
        o.deselectAll(nil)
        cell.applyStyle()
        #expect(Self.hex(cell.imageView?.contentTintColor, dark: false) == 0xF77640)
    }

    // MARK: Row 211: the jump bar and Open Quickly

    /// The jump bar's file component draws the navigator's glyph in the
    /// jump bar's tint (Markdown 12 × 10.5, #5A8095 / #B7D5EB), the
    /// project the Ycode mark, a group the folder.
    @Test func jumpBarGlyphs() throws {
        let (wc, dir) = try r5.longWindow("r9-jump")
        defer { wc.window?.orderOut(nil) }
        let notes = dir.appendingPathComponent("GlassScroll/NOTES.md")
        try "# Notes\n".write(to: notes, atomically: true, encoding: .utf8)
        wc.open(path: notes.path, line: nil)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        let bar = wc.editor.jumpBar
        let parts = bar.pathState.parts
        let file = try #require(parts.last?.icon)
        #expect(file.isGlyph && file.image?.accessibilityDescription == "Markdown")
        #expect(abs(file.inkWidth - 13) < 0.01 && file.image?.size.height == 10.5)
        #expect(Self.hex(file.tint, dark: false) == 0x5A8095 && Self.hex(file.tint, dark: true) == 0xB7D5EB)
        let project = try #require(parts.first?.icon)
        #expect(project.isLogo && project.image?.accessibilityDescription == "Ycode project" && abs(project.inkWidth - 13) < 0.01)
        if parts.count > 2 { #expect(parts[1].icon?.image?.accessibilityDescription == "folder") }
        Self.shot(wc.window, "mac-r9-211-jump-bar-markdown.png")
        Self.viewShot(bar, "mac-r9-211-jump-bar-markdown-view.png", dark: false)
        // JSON: 14 wide in the system red (round 10, row 246).
        let json = dir.appendingPathComponent("GlassScroll/palette.json")
        try "{}\n".write(to: json, atomically: true, encoding: .utf8)
        wc.open(path: json.path, line: nil)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        let j = try #require(wc.editor.jumpBar.pathState.parts.last?.icon)
        #expect(j.isGlyph && j.image?.accessibilityDescription == "JSON" && abs(j.inkWidth - 14) < 0.01)
        #expect(Self.hex(j.tint, dark: false) == 0xFF383C)
        Self.shot(wc.window, "mac-r9-210-jump-bar-json.png")
        Self.viewShot(wc.editor.jumpBar, "mac-r9-210-jump-bar-json-view.png", dark: false)
    }

    /// Open Quickly's file result: the glyph at 24.5 × 20.5 in its tint,
    /// white when its row is selected.
    @Test func openQuicklyGlyph() throws {
        let v = FileGlyphIconView(fileName: "Long.swift", box: FileGlyphs.openQuicklyBox)
        #expect(v.image?.size == NSSize(width: 24.5, height: 20.5) && v.image?.isTemplate == true && !v.allowsVibrancy)
        #expect(Self.hex(v.contentTintColor, dark: false) == 0xF77640)
        v.isOnSelection = true
        #expect(Self.hex(v.contentTintColor, dark: false) == 0xFFFFFF)
        let other = FileGlyphIconView(fileName: "Info.plist", box: FileGlyphs.openQuicklyBox)
        #expect(other.image?.isTemplate != false)
    }

    /// The Open Quickly panel itself (row 215's cell with row 211's glyph):
    /// the selected file row draws its vector glyph white, its ink white on
    /// #0064E1 / #0059D1; the row below keeps its type's tint. The panel is
    /// hosted in a borderless window off every display, never ordered in.
    @Test(arguments: [false, true]) func openQuicklySelectedRowGlyphIsWhite(dark: Bool) throws {
        func file(_ name: String) -> FuzzyMatch.Candidate {
            FuzzyMatch.Candidate(title: name, detail: "GlassScroll", path: "/tmp/GlassScroll/\(name)", line: nil, kind: .file,
                                 symbolKind: nil, groupPath: ["GlassScroll", "GlassScroll"])
        }
        let oq = OpenQuicklyController(candidates: [file("Long.swift"), file("Long.json")])
        let w = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 640, height: 54), styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.contentView = oq.view
        oq.onResize = { h in w.setContentSize(NSSize(width: 640, height: h)) }
        defer { w.orderOut(nil) }
        oq.search("long")
        oq.view.layoutSubtreeIfNeeded()
        oq.table.layoutSubtreeIfNeeded()
        let cells = oq.rowCells
        try #require(cells.count == 2)
        // Which name ranks first is the matcher's business: take the cells by row.
        let (selected, plain) = (cells[0], cells[1])
        #expect(selected.isSelectedRow && !plain.isSelectedRow)
        func tint(_ cell: OpenQuicklyCell) -> UInt32 {
            cell.candidate?.title == "Long.swift" ? (dark ? 0xFFA54D : 0xF77640) : (dark ? 0xFF695E : 0xEE2C22)
        }
        func description(_ cell: OpenQuicklyCell) -> String { cell.candidate?.title == "Long.swift" ? "swift" : "JSON" }
        // The cell's glyph is group A1's vector glyph at the 24.5 × 20.5 box.
        for cell in cells {
            #expect(cell.glyph.image?.isTemplate == true && cell.glyph.image?.size == NSSize(width: 24.5, height: 20.5))
            #expect(cell.glyph.frame.size == NSSize(width: 24.5, height: 20.5))
        }
        #expect(Set(cells.compactMap { $0.candidate?.title }) == ["Long.swift", "Long.json"])
        for cell in cells { #expect(cell.glyph.image?.accessibilityDescription == description(cell)) }
        #expect(selected.glyph.isOnSelection && Self.hex(selected.glyph.contentTintColor, dark: dark) == 0xFFFFFF)
        #expect(!plain.glyph.isOnSelection && Self.hex(plain.glyph.contentTintColor, dark: dark) == tint(plain))
        // The ink drawn: every opaque pixel of the selected row's glyph white.
        oq.view.displayIfNeeded()
        let v = selected.glyph
        let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
        v.cacheDisplay(in: v.bounds, to: rep)
        var ink = 0, white = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.95 else { continue }
                ink += 1
                if c.redComponent > 0.97 && c.greenComponent > 0.97 && c.blueComponent > 0.97 { white += 1 }
            }
        }
        print("R9INT 211/215 selected glyph ink \(ink) px, white \(white) (\(dark ? "dark" : "light"))")
        #expect(ink > 20 && white == ink, "\(white) of \(ink)")
        // Down: the selection moves and the glyphs follow it.
        oq.table.selectRowIndexes([1], byExtendingSelection: false)
        oq.table.layoutSubtreeIfNeeded()
        #expect(Self.hex(plain.glyph.contentTintColor, dark: dark) == 0xFFFFFF)
        #expect(Self.hex(selected.glyph.contentTintColor, dark: dark) == tint(selected))
        Self.shot(w, "mac-r9-int-open-quickly-glyph-\(dark ? "dark" : "light").png")
    }

    // MARK: Row 212: the title area's mark and build ring

    /// Ycode's mark in a 19.5 box at x 383.5, centred on the title's
    /// line, the title 8 after it; while busy the 19 ring in its place.
    @Test func titleMarkAndBuildRing() throws {
        let (wc, _) = try r5.longWindow("r9-title")
        defer { wc.window?.orderOut(nil) }
        let a = wc.activityView
        a.layoutSubtreeIfNeeded()
        let f = r5.frameInWindow(a.icon)
        #expect(f.width == 19.5 && f.height == 19.5)
        #expect(a.icon.image?.accessibilityDescription == "Ycode project")
        #expect(abs((a.textStart - a.icon.frame.maxX) - 8) < 0.01)
        if wc.window?.toolbar?.isVisible == true, let history = a.leadingNeighbor, history.window != nil {
            let hx = r5.frameInWindow(history).maxX
            #expect(abs(f.minX - hx - 12.5) <= 0.5, "mark \(f.minX) after \(hx)")
        }
        // Centred on the title's capitals without a subtitle; at the same
        // place with one (round 10, row 237).
        #expect(abs(a.icon.frame.midY - a.titleCapMidY) < 0.01)
        let restY = a.icon.frame.midY
        a.status = "Building GlassScroll"
        a.layoutSubtreeIfNeeded()
        #expect(abs(a.icon.frame.midY - restY) < 0.01)
        a.isBusy = true
        a.layoutSubtreeIfNeeded()
        #expect(a.showsSpinner && a.icon.isHidden)
        let ring = a.spinner
        ring.layoutSubtreeIfNeeded()
        #expect(abs(ring.ringRect.width + CGFloat(FileGlyphs.buildRingStroke) - 19) < 0.01 && ring.frame == a.icon.frame)
        #expect(ring.arc.lineWidth == 2.5 && abs(ring.arc.strokeEnd - CGFloat(BuildRingProgress.startFraction)) < 0.001)
        #expect(ring.track.strokeColor.flatMap { NSColor(cgColor: $0) }.map { Self.hex($0, dark: false) } == 0xE6E6E6 || ring.isDark)
        Self.shot(wc.window, "mac-r9-212-title-building.png")
        Self.viewShot(a, "mac-r9-212-title-ring-view.png", dark: false)
        a.isBusy = false
        #expect(!a.showsSpinner && !a.icon.isHidden)
        a.status = ""
        Self.shot(wc.window, "mac-r9-212-title-mark.png")
        Self.viewShot(a, "mac-r9-212-title-mark-view.png", dark: false)
    }
}

private extension NSImage {
    func then(_ f: (NSImage) -> Void) -> NSImage { f(self); return self }
}
