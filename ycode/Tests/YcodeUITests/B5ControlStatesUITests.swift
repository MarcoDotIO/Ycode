import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// B5-STATES on the macOS IDE (P-198, #58, #64; `specs/ui/control-states.md`,
/// `specs/ui/glass-materials.md`): the Settings card pop-up's hover bezel,
/// the editor tab's ×, the sheets' push buttons, the inspector's glass
/// lens, the jump bar's divider and the sticky line's separator. Views are
/// drawn into bitmaps in windows far off every display; no window is
/// ordered in. With `YCODE_B5_SHOTS=<dir>` the tests save pictures.
@MainActor
@Suite(.serialized) struct B5ControlStatesUITests {
    nonisolated static let shots = ProcessInfo.processInfo.environment["YCODE_B5_SHOTS"]

    /// A borderless window far off the displays, never ordered in.
    func host(_ v: NSView, size: NSSize, dark: Bool) -> NSWindow {
        _ = NSApplication.shared
        let w = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: size.width, height: size.height), styleMask: [.borderless],
                         backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.colorSpace = .sRGB
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        w.contentView = root
        root.addSubview(v)
        return w
    }

    /// The view drawn at 1x in sRGB (the window's colour space set to
    /// sRGB, so colours read back as drawn). A view that cannot be drawn
    /// (no size, no window) fails the test instead of trapping the process.
    func bitmap(_ v: NSView, sourceLocation: SourceLocation = #_sourceLocation) throws -> NSBitmapImageRep {
        let dark = v.window?.appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return try #require(CouncilRound10ChromeUITests.bitmap(v, scale: 1, dark: dark),
                            "no bitmap for \(type(of: v)) \(v.frame) in \(v.window.map { "\($0.frame)" } ?? "no window")",
                            sourceLocation: sourceLocation)
    }

    /// The colour at (x, y) points from the view's top-left, as 0xRRGGBB.
    func hex(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> UInt32 {
        let s = CGFloat(rep.pixelsWide) / rep.size.width
        return CouncilRound10ChromeUITests.hex(rep.colorAt(x: Int((CGFloat(x) + 0.5) * s), y: Int((CGFloat(y) + 0.5) * s)))
    }

    func near(_ a: UInt32, _ b: UInt32, _ tol: Int = 3) -> Bool {
        let d = [16, 8, 0].map { abs(Int((a >> $0) & 0xFF) - Int((b >> $0) & 0xFF)) }
        return d.allSatisfy { $0 <= tol }
    }

    func expectPixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int, _ expected: UInt32, tol: Int = 3,
                     sourceLocation: SourceLocation = #_sourceLocation) {
        let got = hex(rep, x, y)
        #expect(near(got, expected, tol), "pixel (\(x), \(y)) is #\(String(got, radix: 16)), not #\(String(expected, radix: 16))",
                sourceLocation: sourceLocation)
    }

    func save(_ rep: NSBitmapImageRep, _ name: String) {
        guard let dir = Self.shots else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("mac-\(name).png"))
    }

    // MARK: Settings pop-up (§4)

    @Test(arguments: [true, false])
    func settingsPopUpShowsABezelOverTheWholeControlOnHover(dark: Bool) throws {
        let p = ClosurePopUp(frame: .zero, pullsDown: false, card: true)
        p.addItems(withTitles: ["Use System Setting", "Always"])
        p.frame = NSRect(x: 40, y: 20, width: p.intrinsicContentSize.width, height: p.intrinsicContentSize.height)
        let w = host(p, size: NSSize(width: 260, height: 64), dark: dark)
        defer { w.close() }
        let tracker = try #require(p.hoverTracker)
        #expect(!tracker.isShown)
        tracker.hover(true)
        #expect(tracker.isShown)
        let bezel = tracker.bezel
        #expect(bezel.superview === p.superview)
        #expect(bezel.frame.height == CGFloat(ControlStates.popUpBezelHeight))
        #expect(bezel.frame.minX == p.frame.minX - CGFloat(ControlStates.popUpBezelLead))
        #expect(bezel.frame.maxX == p.frame.maxX)
        let rep = try bitmap(bezel)
        expectPixel(rep, 4, Int(bezel.bounds.midY), dark ? 0x343436 : 0xE4E4E4)
        save(try bitmap(w.contentView!), "settings-popup-hover-\(dark ? "dark" : "light")")
        // One frame off; none when disabled.
        tracker.hover(false)
        #expect(!tracker.isShown)
        p.isEnabled = false
        tracker.hover(true)
        #expect(!tracker.isShown)
    }

    // MARK: Editor tab × (§5)

    @Test func tabCloseBezelAppearsAtOnceAndFadesOut() throws {
        let b = TabCloseButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")!, target: nil, action: nil)
        b.isBordered = false
        b.frame = NSRect(x: 10, y: 10, width: 18, height: 18)
        let w = host(b, size: NSSize(width: 40, height: 40), dark: true)
        defer { w.close() }
        var t: CFTimeInterval = 100
        b.now = { t }
        #expect(b.bezelOpacity == 0)
        b.setHovered(true)
        #expect(b.bezelOpacity == 1)
        let rep = try bitmap(b)
        save(rep, "tab-close-hover-dark")
        // The bezel's edge (the glyph sits at the centre): #606060.
        expectPixel(rep, 3, 9, 0x606060, tol: 4)
        b.setHovered(false)
        #expect(b.bezelOpacity == 1)
        t += 0.075
        #expect(abs(b.bezelOpacity - 0.5) < 0.01)
        t += 0.1
        #expect(b.bezelOpacity == 0)
        b.isHighlighted = true
        #expect(b.bezelOpacity == 1)
        expectPixel(try bitmap(b), 3, 9, 0x686868, tol: 4)
    }

    // MARK: Sheet push buttons (§4)

    @Test(arguments: [true, false])
    func sheetButtonsTintWhileHeld(dark: Bool) throws {
        let ok = NSButton(title: "Next", target: nil, action: #selector(NSWindow.performClose(_:)))
        ok.bezelStyle = .push
        ok.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: nil, action: nil)
        cancel.bezelStyle = .push
        cancel.keyEquivalent = "\u{1b}"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 40))
        ok.frame = NSRect(x: 112, y: 8, width: 96, height: 24)
        cancel.frame = NSRect(x: 8, y: 8, width: 96, height: 24)
        box.addSubview(ok)
        box.addSubview(cancel)
        let w = host(box, size: box.frame.size, dark: dark)
        defer { w.close() }
        #expect(SheetButtonStates.adopt(in: box) == 2)
        #expect(SheetButtonStates.adopt(in: box) == 0)
        #expect(ok.keyEquivalent == "\r" && cancel.keyEquivalent == "\u{1b}")
        #expect(ok.action == #selector(NSWindow.performClose(_:)))
        var rep = try bitmap(box)
        save(rep, "sheet-buttons-\(dark ? "dark" : "light")")
        expectPixel(rep, 118, 20, 0x0078FE)
        expectPixel(rep, 14, 20, dark ? 0x2F2F31 : 0xEBEBEB)
        ok.isHighlighted = true
        cancel.isHighlighted = true
        rep = try bitmap(box)
        save(rep, "sheet-buttons-held-\(dark ? "dark" : "light")")
        expectPixel(rep, 118, 20, dark ? 0x2C85FD : 0x006CE5)
        expectPixel(rep, 14, 20, dark ? 0x434345 : 0xD3D3D3)
    }

    // MARK: Inspector lens (§3)

    @Test func inspectorLensFollowsThePointerAndSelectsOnRelease() throws {
        let c = InspectorAreaController()
        let w = host(c.view, size: NSSize(width: 260, height: 400), dark: true)
        defer { w.close() }
        c.view.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        c.view.layoutSubtreeIfNeeded()
        c.select(0)
        let lens = c.tabLens
        #expect(lens.buttons().count == 3)
        lens.press(2)
        #expect(!lens.lensView.isHidden)
        #expect(lens.lens?.lensTab == 2)
        // The selection does not change while held.
        #expect(c.selectedIndex == 0)
        lens.drag(1)
        lens.drag(nil)
        #expect(lens.lens?.lensTab == 1)
        lens.release()
        #expect(c.selectedIndex == 1)
        #expect(lens.lensView.isHidden)
        // No hover state: the tabs are not tracked for it.
        #expect(!ControlStates.style(.inspectorTab, dark: true).hasHover)
    }

    // MARK: Jump bar divider and sticky separator (#58)

    @Test(arguments: [true, false])
    func jumpBarDividerIsTwoFixedRows(dark: Bool) throws {
        try #require(EditorBlurVeil.applies, "the default theme")
        let bar = JumpBar(frame: NSRect(x: 0, y: 0, width: 300, height: JumpBar.height))
        let w = host(bar, size: bar.frame.size, dark: dark)
        defer { w.close() }
        let rep = try bitmap(bar)
        let h = Int(JumpBar.height)
        let colors = GlassMaterials.jumpBarDivider(dark: dark)
        expectPixel(rep, 150, h - 2, colors.top.hex, tol: 1)
        expectPixel(rep, 150, h - 1, colors.bottom.hex, tol: 1)
    }

    @Test(arguments: [true, false])
    func stickySeparatorAndOpaqueBand(dark: Bool) throws {
        try #require(EditorBlurVeil.applies, "the default theme")
        let header = ScopeHeaderView(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        header.show([ScopeHeaderView.Row(line: 21, text: NSAttributedString(string: "struct Box0<Value>: Sendable {"))])
        let w = host(header, size: header.frame.size, dark: dark)
        defer { w.close() }
        #expect(header.bandHeight == CGFloat(GlassMaterials.stickyBandHeight))
        let rep = try bitmap(header)
        save(rep, "sticky-line-\(dark ? "dark" : "light")")
        let colors = GlassMaterials.stickySeparator(dark: dark)
        expectPixel(rep, 290, 20, colors.top.hex, tol: 1)
        expectPixel(rep, 290, 21, colors.bottom.hex, tol: 1)
        #expect(!GlassMaterials.workspaceHasProgressiveScrollEdge)
    }

    // MARK: Toolbar (§2, §7)

    @Test func disabledToolbarSegmentPassesThePressToTheWindow() {
        let c = ToolbarSegmentedControl(labels: ["Run", "Stop"], trackingMode: .momentary, target: nil, action: nil)
        c.setWidth(30, forSegment: 0)
        c.setWidth(30, forSegment: 1)
        c.frame = NSRect(x: 0, y: 0, width: 60, height: 24)
        c.setEnabled(false, forSegment: 1)
        #expect(c.segment(atX: 10) == 0)
        #expect(c.segment(atX: 45) == 1)
        #expect(!c.passesPressToWindow(atX: 10))
        #expect(c.passesPressToWindow(atX: 45))
        c.isEnabled = false
        #expect(c.passesPressToWindow(atX: 10))
    }

    @Test func onlyTheHoveredChooserHalfShowsItsBezel() throws {
        let scheme = NSPopUpButton(frame: NSRect(x: 10, y: 4, width: 77, height: 22), pullsDown: false)
        let destination = NSPopUpButton(frame: NSRect(x: 100, y: 4, width: 101, height: 22), pullsDown: false)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        box.addSubview(scheme)
        box.addSubview(destination)
        let w = host(box, size: box.frame.size, dark: true)
        defer { w.close() }
        ToolbarControlStates.installHalfHover([scheme, destination])
        let a = try #require(ToolbarControlStates.tracker(scheme)), b = try #require(ToolbarControlStates.tracker(destination))
        a.hover(true)
        #expect(a.isShown && !b.isShown)
        #expect(a.bezel.frame.width == scheme.frame.width && a.bezel.frame.height == 28)
        expectPixel(try bitmap(a.bezel), 38, 14, 0x4B4B4B)
        a.hover(false)
        b.hover(true)
        #expect(!a.isShown && b.isShown)
    }

    /// A half's tracker lives on its control: a pop-up made at a freed
    /// pop-up's address gets a tracker of its own and its bezel shows (a
    /// table keyed by identity used to hand it the freed one's tracker).
    @Test func aPopUpAtAReusedAddressGetsItsOwnHoverBezel() throws {
        func address(_ o: AnyObject) -> UInt { UInt(bitPattern: Unmanaged.passUnretained(o).toOpaque()) }
        var freed: Set<UInt> = []
        var reused: NSPopUpButton?
        for _ in 0..<4000 where reused == nil {
            // Each pop-up (and what AppKit autoreleases for it) goes before the next.
            autoreleasepool {
                let p = NSPopUpButton(frame: NSRect(x: 10, y: 4, width: 77, height: 22), pullsDown: false)
                if freed.contains(address(p)) {
                    reused = p
                    return
                }
                ToolbarControlStates.installHalfHover([p])
                #expect(ToolbarControlStates.tracker(p)?.control === p)
                freed.insert(address(p))
            }
        }
        let p = try #require(reused, "no address was reused in 4000 pop-ups")
        // Nothing carried over from the freed pop-up.
        #expect(ToolbarControlStates.tracker(p) == nil)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 36))
        box.addSubview(p)
        let w = host(box, size: box.frame.size, dark: true)
        defer { w.close() }
        ToolbarControlStates.installHalfHover([p])
        let t = try #require(ToolbarControlStates.tracker(p))
        #expect(t.control === p)
        t.hover(true)
        #expect(t.isShown && t.bezel.frame.width == p.frame.width && t.bezel.frame.height == 28)
        expectPixel(try bitmap(t.bezel), 38, 14, 0x4B4B4B)
    }
}
