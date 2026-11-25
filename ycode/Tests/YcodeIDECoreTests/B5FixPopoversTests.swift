import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore

/// The beta 5 fix round's popover facts (B5-FIX-POPOVERS; council round 12):
/// the destination chooser's initial highlight (P-113, `popovers.md` §2.7),
/// Quick Help's width, declaration box and module help (P-083, §4.1–§4.2),
/// Quick Actions' rows (P-086, §5.1) and the tooltip timing (P-197,
/// `control-states.md` §8, §8.1). Both machines.
@Suite struct B5FixPopoversTests {
    // MARK: P-113

    let mac = Destination.myMac
    let sim = Destination(name: "iPhone 17", specifier: "platform=iOS Simulator,id=A", platform: "iOS", kind: .simulator, osVersion: "27.1",
                          identifier: "A")
    var extras: [ChooserRow] {
        [ChooserRow(kind: .command, title: "Get a Simulator Runtime…", key: "command:getRuntime"),
         ChooserRow(kind: .command, title: "Set Up Ycode Simulator…", trailing: "Experimental", key: "command:setUpSimulator")]
    }

    @Test func destinationChooserOpensOnTheCheckedRow() {
        let l = DestinationChooser.list(sections: [("Recent", [mac]), ("Devices", [mac]), ("Simulators", [sim]), ("Build", [.anyMac])],
                                        incompatible: [], current: mac, expanded: false, extras: extras)
        let titles = l.rows.map(\.title)
        // Ycode's rows: the last rows of Simulators, in order, before Build.
        let s = titles.firstIndex(of: "Simulators")!, b = titles.firstIndex(of: "Build")!
        #expect(Array(titles[s..<b]) == ["Simulators", "iPhone 17", "Get a Simulator Runtime…", "Set Up Ycode Simulator…"])
        #expect(l.current?.title == mac.name && l.current?.isChecked == true)
        #expect(titles.filter { $0 == mac.name }.count == 1, "listed once")
    }

    @Test func noCheckedRowHighlightsTheFirstDestinationNeverACommand() {
        // The simulators section holds only Ycode's rows and nothing is current.
        let l = DestinationChooser.list(sections: [("Simulators", [])], incompatible: [], current: nil, expanded: false, extras: extras)
        #expect(l.current?.kind != .command)
        let withDevices = DestinationChooser.list(sections: [("Simulators", []), ("Build", [.anyMac])], incompatible: [], current: nil,
                                                  expanded: false, extras: extras)
        #expect(withDevices.current?.kind == .choice && withDevices.current?.title.hasPrefix("Any Mac") == true)
        // A current destination without a Recent section stays listed, checked.
        let noRecent = DestinationChooser.list(sections: [("Devices", [mac]), ("Simulators", [sim])], incompatible: [], current: sim,
                                               expanded: false, extras: extras)
        #expect(noRecent.current?.title == "iPhone 17" && noRecent.current?.isChecked == true)
    }

    @Test func hoverWaitsForThePointerToMove() {
        var gate = ChooserPointerGate()
        let first = gate.admit(CGPoint(x: 10, y: 10))
        let jitter = gate.admit(CGPoint(x: 10.4, y: 10))
        let moved = gate.admit(CGPoint(x: 10, y: 12))
        let after = gate.admit(CGPoint(x: 10, y: 10))
        #expect(!first, "the first report is where the pointer was")
        #expect(!jitter && moved && after)
        var known = ChooserPointerGate(origin: CGPoint(x: 5, y: 5))
        let still = known.admit(CGPoint(x: 5, y: 5))
        let away = known.admit(CGPoint(x: 8, y: 5))
        #expect(!still && away)
    }

    // MARK: P-083

    @Test func quickHelpMetrics() {
        typealias M = QuickHelpPopoverMetrics
        #expect(M.width == 417 && PopoverMetrics.quickHelpBodyWidth == 417)
        #expect(M.declarationWidth == 385 && M.declarationHeight(lines: 2) == 50)
        #expect(M.declarationFill(dark: true) == 0x262626 && M.declarationRadius == 6)
    }

    @Test func modifiersGoOnTheirOwnLine() {
        #expect(QuickHelpDeclarationLines.lines("nonisolated let name: String") == ["nonisolated", "let name: String"])
        #expect(QuickHelpDeclarationLines.lines("let name: String") == ["let name: String"])
        #expect(QuickHelpDeclarationLines.lines("@MainActor public func f(a: Int) -> Int") == ["@MainActor public", "func f(a: Int) -> Int"])
        #expect(QuickHelpDeclarationLines.lines("@available(macOS 15, *) struct S") == ["@available(macOS 15, *)", "struct S"])
        #expect(QuickHelpDeclarationLines.lines("func f(let x: Int)") == ["func f(let x: Int)"])
        #expect(QuickHelpDeclarationLines.lines("struct A\nwhere T: P") == ["struct A", "where T: P"])
    }

    @Test func moduleNamesInImports() {
        let text = "// header\nimport Foundation\n@testable import MyKit\nimport struct Other.Thing\nlet x = Foundation.Date()\n"
        let ns = text as NSString
        func at(_ word: String, after: Int = 0) -> Int {
            ns.range(of: word, range: NSRange(location: after, length: ns.length - after)).location + 1
        }
        #expect(ModuleQuickHelp.moduleName(in: text, at: at("Foundation")) == "Foundation")
        #expect(ModuleQuickHelp.moduleName(in: text, at: at("MyKit")) == "MyKit")
        #expect(ModuleQuickHelp.moduleName(in: text, at: at("Other")) == "Other")
        #expect(ModuleQuickHelp.moduleName(in: text, at: at("import")) == nil, "the keyword is not the module")
        #expect(ModuleQuickHelp.moduleName(in: text, at: at("Foundation", after: ns.range(of: "let").location)) == nil, "not an import")
        #expect(ModuleQuickHelp.offset(in: "ab\ncd", line: 1, character: 1) == 4)
    }

    @Test func moduleDocumentFromItsCatalog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("b5fix-docc-\(UUID().uuidString)")
        let catalog = root.appendingPathComponent("Sources/Gadgets/Gadgets.docc")
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Ycode's own test text (no SDK documentation).
        let article = """
        # ``Gadgets``

        Small gadgets for *test* workshops.

        @Metadata {
            @DisplayName("Gadgets")
        }

        ## Overview

        Gadgets builds tiny contraptions from parts.

        Each contraption has a `Lever` and a spring.

        ## Topics

        ### Parts

        - ``Lever``
        """
        try Data(article.utf8).write(to: catalog.appendingPathComponent("Gadgets.md"))
        let doc = ModuleQuickHelp.document(module: "Gadgets", roots: [root])
        #expect(doc.isModule && doc.title == "Gadgets")
        #expect(doc.summary == "Small gadgets for test workshops.")
        #expect(doc.overview.map(\.plainText) == ["Gadgets builds tiny contraptions from parts.", "Each contraption has a Lever and a spring."])
        #expect(doc.declaration.isEmpty && !doc.showsFileLink && doc.showsDocumentationLink)
        #expect(doc.sectionOrder == ["Title", "Summary", "Overview", "Open in Developer Documentation"])
        // No catalog: the title and the link, never nothing.
        let sdk = ModuleQuickHelp.document(module: "Foundation", roots: [root])
        #expect(sdk.isModule && sdk.title == "Foundation" && sdk.summary == nil && sdk.overview.isEmpty)
        #expect(sdk.sectionOrder == ["Title", "Open in Developer Documentation"])
        #expect(ModuleQuickHelp.searchRoot(container: root.appendingPathComponent("App.xcodeproj")).standardizedFileURL.path == root.standardizedFileURL.path)
    }

    // MARK: P-086

    /// A menu in menu order, like "build"'s results (§5.1).
    var menu: [QuickActionEntry] {
        [QuickActionEntry(menuPath: ["File"], title: "Close Window", shortcut: "⇧⌘W"),
         QuickActionEntry(menuPath: ["Editor", "Syntax Coloring"], title: "Build Phase File List"),
         QuickActionEntry(menuPath: ["Product"], title: "Build", shortcut: "⌘B"),
         QuickActionEntry(menuPath: ["Product"], title: "Build Documentation", shortcut: "⌃⇧⌘D"),
         QuickActionEntry(menuPath: ["Product", "Build For"], title: "Running", shortcut: "⇧⌘R"),
         QuickActionEntry(menuPath: ["Product", "Build For"], title: "Testing", shortcut: "⇧⌘U"),
         QuickActionEntry(menuPath: ["Product", "Build For"], title: "Profiling", shortcut: "⇧⌘I"),
         QuickActionEntry(menuPath: ["Product", "Perform Action"], title: "Build with Timing Summary"),
         QuickActionEntry(menuPath: ["Product"], title: "Clean Build Folder…", shortcut: "⇧⌘K")]
    }

    @Test func quickActionsRankingAndTitles() {
        let order = QuickActionRanking.rank(menu, query: "build").map { menu[$0].displayTitle }
        #expect(order == ["Build", "Build Documentation", "Build For › Running", "Build For › Testing", "Build For › Profiling",
                          "Syntax Coloring › Build Phase File List", "Perform Action › Build with Timing Summary", "Clean Build Folder…"])
        #expect(QuickActionRanking.rank(menu, query: " ").isEmpty, "empty until typed")
        // Ycode's Product menu lists Build For before Build: top-level commands still come first.
        let reordered = [menu[4], menu[2], menu[3]]
        #expect(QuickActionRanking.rank(reordered, query: "build").map { reordered[$0].displayTitle } == ["Build", "Build Documentation", "Build For › Running"])
        let running = menu[4]
        #expect(running.subtitle == "Product › Build For" && menu[2].subtitle == "Product")
        #expect(QuickActionRanking.matchedRanges(running, query: "build") == [0..<5])
        #expect(QuickActionRanking.matchedRanges(menu[1], query: "build") == [18..<23], "the own title's match")
        #expect(QuickActionRanking.matchedRanges(menu[8], query: "build") == [6..<11])
    }

    @Test func quickActionsGlyphs() {
        #expect(menu[2].symbol == "hammer" && menu[3].symbol == "doc.text" && menu[4].symbol == "play")
        #expect(menu[5].symbol == "checkmark.diamond" && menu[8].symbol == "trash" && menu[0].symbol == "xmark")
        #expect(QuickActionEntry(menuPath: ["View"], title: "Zzz").symbol == "eye")
    }

    @Test func quickActionsRowMetrics() {
        typealias M = QuickActionRowMetrics
        #expect(M.rowHeight == 56 && M.textX == 64 && M.glyphCenterX == 33)
        #expect(M.panelHeight(count: 0) == 55 && M.panelHeight(count: 2) == 66 + 112 + 10)
        #expect(M.panelHeight(count: 9) == 495, "grows to 495, then scrolls")
        #expect(M.listHeight(count: 9) == 495 - 66 - 10)
        #expect(M.highlightFrame(row: 1, width: 560) == CGRect(x: 8, y: 56, width: 531, height: 56))
        #expect(M.highlight(dark: true) == 0x0059D1 && M.highlightRadius == 14)
        #expect(M.subtitle(dark: true) == 0xB0B0B4 && M.title(dark: true) == 0xD0D0D0 && M.key(dark: true) == 0xA8A8A8)
    }

    // MARK: P-197

    typealias Session = TooltipSession<String>
    func tip(_ id: String) -> Session.Tip { .init(id: id, text: "tip \(id)", point: .zero) }

    @Test func tooltipTiming() {
        #expect(TooltipTiming.delay == 1.56 && TooltipTiming.hold == 0.35 && TooltipTiming.fade == 0.46)
        #expect(TooltipTiming.opacity(afterLeave: 0.35) == 1)
        #expect(abs(TooltipTiming.opacity(afterLeave: 0.35 + 0.23) - 0.5) < 1e-9, "linear")
        #expect(TooltipTiming.opacity(afterLeave: 0.81) == 0 && abs(TooltipTiming.gone - 0.81) < 1e-9)
    }

    @Test func tooltipAppearsHoldsAndFades() {
        var s = Session()
        s.pointer(over: tip("run"), at: 10)
        s.advance(to: 11.5)
        #expect(s.visible(at: 11.5) == nil)
        s.advance(to: 11.56)
        #expect(s.visible(at: 11.56)?.tip.id == "run" && s.visible(at: 11.56)?.opacity == 1, "1.56 s, one frame")
        s.pointerOverNothing(at: 12)
        #expect(s.visible(at: 12.3)?.opacity == 1, "held 350 ms")
        #expect(abs((s.visible(at: 12.58)?.opacity ?? 0) - 0.5) < 1e-6, "half-way through the 460 ms fade")
        s.advance(to: 12.81)
        #expect(s.visible(at: 12.81) == nil && s.state == .idle)
        // After a complete fade, the next control waits the full delay (§8.1 item 3).
        s.pointer(over: tip("stop"), at: 13)
        #expect(s.nextDeadline == 14.56)
    }

    @Test func movingOntoAnotherControlSwapsAfterTheHold() {
        var s = Session()
        s.pointer(over: tip("a"), at: 0)
        s.advance(to: 1.56)
        // Straight onto the next control: the old one stays 350 ms, then the new one replaces it in one frame.
        s.pointer(over: tip("b"), at: 2)
        #expect(s.visible(at: 2.2)?.tip.id == "a" && s.visible(at: 2.2)?.opacity == 1)
        #expect(s.nextDeadline == 2.35)
        s.advance(to: 2.35)
        #expect(s.visible(at: 2.35)?.tip.id == "b" && s.visible(at: 2.35)?.opacity == 1, "no fade, no new delay")
        // Through a gap with no tooltip, onto a third control while the old one is held.
        s.pointerOverNothing(at: 3)
        s.pointer(over: tip("c"), at: 3.1)
        s.advance(to: 3.35)
        #expect(s.visible(at: 3.35)?.tip.id == "c")
        // A click removes it at once.
        s.dismiss()
        #expect(s.visible(at: 3.4) == nil)
    }

    @Test func leavingTheNextControlBeforeTheSwapKeepsTheFade() {
        var s = Session()
        s.pointer(over: tip("a"), at: 0)
        s.advance(to: 2)
        s.pointer(over: tip("b"), at: 2)
        s.pointerOverNothing(at: 2.1)
        s.advance(to: 2.4)
        #expect(s.visible(at: 2.4)?.tip.id == "a" && (s.visible(at: 2.4)?.opacity ?? 1) < 1, "a fades from its own leave")
    }
}
