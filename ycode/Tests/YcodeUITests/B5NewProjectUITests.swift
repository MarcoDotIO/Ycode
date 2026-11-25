import AppKit
import CYcodeTestOffscreen
import Foundation
import Testing
@testable import YcodeIDECore
import YcodeProject
@testable import YcodeUI

private let worktree = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

/// Beta 5's New Project and Welcome items (B5-NEWPROJECT;
/// `specs/ide/parity-inventory.md`): the template chooser's keyboard,
/// filter and grid (P-181), the options step's look (P-182), the bare
/// window behind the chooser (P-183) and Welcome's Open…, close button and
/// accessibility (P-186). Every window stays off the displays (the
/// offscreen guard); screenshots (`cacheDisplay`, never the screen) go to
/// `.build-ide/b5-shots/`.
@MainActor
@Suite(.serialized) struct B5NewProjectUITests {
    typealias M = TemplateChooserMetrics

    func tempDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-b5-newproject-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Ycode's own view, rendered offscreen to a PNG in both appearances.
    func shot(_ view: NSView, _ name: String) throws {
        let dir = worktree.appendingPathComponent(".build-ide/b5-shots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for dark in [true, false] {
            let saved = view.appearance
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:]))
                .write(to: dir.appendingPathComponent("macos-\(name)-\(dark ? "dark" : "light").png"))
            view.appearance = saved
        }
    }

    /// The template sheet in an offscreen window of its own, as a sheet's.
    func sheetInWindow(_ td: TestDefaults) -> (NewProjectSheetController, NSWindow) {
        _ = NSApplication.shared
        let sheet = NewProjectSheetController(defaults: td.defaults)
        let w = NSWindow(contentViewController: sheet)
        w.setContentSize(NSSize(width: M.sheetWidth, height: M.sheetHeight))
        w.appearance = NSAppearance(named: .darkAqua)
        w.makeKeyAndOrderFront(nil)
        sheet.view.layoutSubtreeIfNeeded()
        return (sheet, w)
    }

    // MARK: P-181

    @Test func chooserGridFilterAndKeyboard() throws {
        #expect(YcodeOffscreenIsActive())
        let td = TestDefaults("b5-np-chooser")
        defer { td.remove() }
        let (sheet, w) = sheetInWindow(td)
        defer { w.close() }
        sheet.setPlatform("macOS")
        sheet.view.layoutSubtreeIfNeeded()
        // The heading is regular weight.
        #expect(sheet.titleLabel.font?.fontDescriptor.symbolicTraits.contains(.bold) == false)
        // The filter is always 202 points wide, at the right of the tabs.
        #expect(abs(sheet.filterField.frame.width - 202) < 0.5)
        #expect(sheet.platformControl.font?.pointSize == 10)
        let grid = try #require(sheet.grid)
        #expect(grid.columns == 5 && grid.tileStyle == .outlined)
        #expect(grid.scroll.borderType == .noBorder && !grid.scroll.drawsBackground)
        // Five columns on a 137-point pitch.
        let first = try #require(grid.tiles.first), second = grid.tiles[1]
        let a = first.convert(first.bounds, to: nil), b = second.convert(second.bounds, to: nil)
        #expect(abs(b.minX - a.minX - 137) < 0.5)
        // Section headers sit on bands.
        #expect(grid.headers.allSatisfy { $0.superview is SectionBandView })
        // The macOS library order: Framework, Library, Metal Library, XPC Service, Bundle.
        let lib = ProjectTemplates.sections(platform: "macOS").first { $0.title == "Framework & Library" }
        #expect(lib?.entries.map(\.title) == ["Framework", "Library", "Metal Library", "XPC Service", "Bundle"])
        // No description line (the empty state only); the summary is the tooltip.
        #expect(sheet.captionLabel.isHidden)
        #expect(first.toolTip?.isEmpty == false)
        // The grid has focus; Right moves the selection, Left back, Down a row.
        #expect(sheet.focusGrid())
        #expect(w.firstResponder === grid)
        let start = try #require(sheet.selectedTemplate?.title)
        let titles = grid.tiles.map(\.entry.title)
        let i = try #require(titles.firstIndex(of: start))
        sheet.moveSelection(.right)
        #expect(sheet.selectedTemplate?.title == titles[min(i + 1, titles.count - 1)])
        sheet.moveSelection(.left)
        #expect(sheet.selectedTemplate?.title == start)
        grid.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                         context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}",
                                                         isARepeat: false, keyCode: 124)))
        #expect(sheet.selectedTemplate?.title == titles[min(i + 1, titles.count - 1)])
        // Tab alternates the filter and the grid.
        #expect(sheet.filterField.nextKeyView === grid && grid.nextKeyView === sheet.filterField)
        try shot(sheet.view, "b5-chooser")
        // The filter's empty state is the only caption.
        sheet.setFilter("zzzz")
        #expect(!sheet.captionLabel.isHidden && sheet.captionLabel.stringValue.hasPrefix("No templates match"))
        sheet.setFilter("")
    }

    @Test func gridNavigationRule() {
        // Sections of 7 and 3 in five columns.
        let counts = [7, 3]
        func move(_ k: TemplateGridNavigation.Key, _ i: Int?) -> Int? {
            TemplateGridNavigation.index(moving: k, from: i, sectionCounts: counts, columns: 5)
        }
        #expect(move(.right, nil) == 0)
        #expect(move(.right, 6) == 7 && move(.left, 7) == 6)
        #expect(move(.down, 1) == 6)   // row 2 of section 1 has two tiles
        #expect(move(.down, 4) == 6)   // the last row's last tile
        #expect(move(.down, 6) == 8)   // next section, same column (1)
        #expect(move(.up, 9) == 6)     // back up: section 1's last row, column 2 → its last tile
        #expect(move(.up, 2) == 2 && move(.down, 9) == 9 && move(.right, 9) == 9 && move(.left, 0) == 0)
    }

    // MARK: P-182

    @Test func optionsStepLook() throws {
        #expect(YcodeOffscreenIsActive())
        let td = TestDefaults("b5-np-options")
        defer { td.remove() }
        let (sheet, w) = sheetInWindow(td)
        defer { w.close() }
        #expect(sheet.select(templateID: "ios.app"))
        sheet.nextClicked()
        #expect(sheet.flow.step == .options)
        sheet.view.layoutSubtreeIfNeeded()
        #expect(sheet.titleLabel.font?.fontDescriptor.symbolicTraits.contains(.bold) == false)
        let pops = sheet.fieldControls.values.compactMap { $0 as? NSPopUpButton }
        #expect(!pops.isEmpty)
        for p in pops {
            #expect(abs(p.frame.height - 20) < 0.5, "\(p.identifier?.rawValue ?? "")")
            #expect(abs(p.frame.width - 267) < 0.5, "\(p.identifier?.rawValue ?? "")")
            #expect(p.bezelColor == NewProjectSheetController.popUpBezel)
        }
        // Rows on a 33-point pitch.
        let ys = sheet.flow.form.visibleFields.compactMap { sheet.fieldControls[$0.id] }.map { $0.convert($0.bounds, to: nil).midY }
        for (a, b) in zip(ys, ys.dropFirst()) { #expect(abs(a - b - 33) < 0.6, "\(ys)") }
        // Product Name: borderless, no focus ring.
        let name = try #require(sheet.fieldControls[TemplateOptionID.productName] as? NSTextField)
        #expect(!name.isBordered && !name.isBezeled && name.focusRingType == .none)
        // Dark fill #2F2F31.
        var dark = NSColor.clear
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            dark = NewProjectSheetController.popUpBezel.usingColorSpace(.sRGB) ?? .clear
        }
        #expect(Int((dark.redComponent * 255).rounded()) == 0x2F && Int((dark.blueComponent * 255).rounded()) == 0x31)
        #expect(NewProjectSheetController.optionsFadeDuration == 0.19)
        try shot(sheet.view, "b5-options")
    }

    // MARK: P-183

    @Test func windowBehindTheChooserIsBare() throws {
        #expect(YcodeOffscreenIsActive())
        _ = NSApplication.shared
        let wc = NewProjectFlow.emptyWorkspaceWindow()
        defer { wc.close() }
        #expect(wc.window?.title == "Untitled")
        #expect(wc.isBareChooserHost)
        #expect(wc.editorArea.view.isHidden && wc.schemePopUp.isHidden && wc.destinationPopUp.isHidden)
        #expect(wc.navigator.outlineView.enclosingScrollView?.isHidden ?? wc.navigator.outlineView.isHidden)
        #expect(wc.activityView.workspaceName.isEmpty)
        if let content = wc.window?.contentView {
            content.frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
            try shot(content, "b5-bare-host")
        }
    }

    // MARK: P-186

    @Test func welcomeCloseButtonAccessibilityAndMenu() throws {
        #expect(YcodeOffscreenIsActive())
        _ = NSApplication.shared
        let td = TestDefaults("b5-np-welcome")
        defer { td.remove() }
        let welcome = WelcomeWindowController(recents: RecentProjects(defaults: td.defaults))
        welcome.window?.appearance = NSAppearance(named: .darkAqua)
        let content = try #require(welcome.window?.contentView)
        content.layoutSubtreeIfNeeded()
        // A 37-point circle with a 13-point glyph.
        #expect(abs(welcome.closeButton.frame.width - 37) < 0.5 && abs(welcome.closeButton.frame.height - 37) < 0.5)
        let close = try #require(welcome.closeButton as? WelcomeCloseButton)
        // The ×'s ink is 13 points.
        let image = try #require(close.image)
        let k = 4
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width) * k, pixelsHigh: Int(image.size.height) * k,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: close.glyphRect(for: image.size).offsetBy(dx: -close.glyphRect(for: image.size).minX, dy: -close.glyphRect(for: image.size).minY))
        NSGraphicsContext.restoreGraphicsState()
        var xs: [Int] = [], ys: [Int] = []
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { xs.append(x); ys.append(y) } }
        let ink = Double(max((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0)) + 1) / Double(k)
        #expect(abs(ink - 13) < 0.5, "ink \(ink)")
        // The hover fill: #3C3D3E, then #505152.
        func rgb(_ c: NSColor) -> Int {
            var out = NSColor.clear
            NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { out = c.usingColorSpace(.sRGB) ?? .clear }
            return Int((out.redComponent * 255).rounded()) << 16 | Int((out.greenComponent * 255).rounded()) << 8 | Int((out.blueComponent * 255).rounded())
        }
        #expect(rgb(close.currentFill) == 0x3C3D3E)
        close.setHovered(true)
        #expect(rgb(close.currentFill) == 0x505152)
        close.setHovered(false)
        // Accessibility: close first; names as descriptions; recents an outline.
        #expect(content.subviews.first === welcome.closeButton)
        #expect(welcome.closeButton.accessibilityTitle() == nil && welcome.closeButton.accessibilityLabel() == "Close")
        #expect(welcome.openButton.accessibilityTitle() == nil && welcome.openButton.accessibilityLabel() == "Open…")
        #expect(welcome.cloneButton.accessibilityLabel() == "Clone…")
        #expect(welcome.newProjectButton.accessibilityLabel() == "New Project")
        #expect(welcome.table.accessibilityRole() == .outline)
        // The New Project menu: the rows without the title item, 10 below.
        let pull = try #require(welcome.newProjectButton as? WelcomePullDown)
        #expect(pull.dropDownMenu().items.map(\.title) == ["App", "Command Line Tool", "Package…", "Playground", "", "Choose Template…"])
        let gap = pull.isFlipped ? pull.dropDownOrigin.y - pull.bounds.maxY : pull.bounds.minY - pull.dropDownOrigin.y
        #expect(abs(gap - 10) < 0.01)
        // The recent row's text: 2.75 left and 0.5 higher than before.
        #expect(WelcomeRecentRow.textShift == -8.75 && WelcomeRecentRow.titleDrop == 1.5 && WelcomeRecentRow.pathDrop == 3.0)
        try shot(content, "b5-welcome")
    }

    @Test func welcomeOpenClosesWelcomeFirst() async throws {
        #expect(YcodeOffscreenIsActive())
        _ = NSApplication.shared
        let td = TestDefaults("b5-np-open")
        defer { td.remove() }
        let saved = WelcomeWindowController.runOpenPanel
        defer { WelcomeWindowController.runOpenPanel = saved }
        let welcome = WelcomeWindowController(recents: RecentProjects(defaults: td.defaults))
        var opened: [URL] = []
        welcome.openWorkspace = { url, done in opened.append(url); done(true) }
        var visibleWhenPanelRan: Bool?
        var answer: [URL] = []
        WelcomeWindowController.runOpenPanel = { _, done in
            visibleWhenPanelRan = welcome.window?.isVisible
            done(answer)
        }
        // Cancel: Welcome closed before the panel, and comes back.
        welcome.showWindow(nil)
        welcome.openClicked(nil)
        let end = Date().addingTimeInterval(20)
        while visibleWhenPanelRan == nil, Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(visibleWhenPanelRan == false)
        #expect(welcome.window?.isVisible == true)
        // The opacity is back for the next time (set right after the fade).
        let end3 = Date().addingTimeInterval(5)
        while welcome.window?.alphaValue != 1, Date() < end3 { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(welcome.window?.alphaValue == 1)
        // A choice opens it; Welcome stays closed.
        visibleWhenPanelRan = nil
        answer = [URL(fileURLWithPath: "/tmp/Sample.xcodeproj")]
        welcome.openClicked(nil)
        let end2 = Date().addingTimeInterval(20)
        while visibleWhenPanelRan == nil, Date() < end2 { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(visibleWhenPanelRan == false)
        #expect(opened == answer)
        #expect(welcome.window?.isVisible == false)
    }
}
