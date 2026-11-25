import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore
import YcodeWorkspace

/// Beta 5's shared popover model (B5-POPOVERS, `specs/ide/popovers.md`),
/// which both IDEs lay out from: placement, the chooser rows and keys, the
/// in-window panels, the New Scheme sheet and Product ▸ Destination.
@Suite struct PopoverModelTests {
    // MARK: Placement (§2.2, §4, §11.1)

    /// The scheme chooser under its half (x 600–740 of the capsule, y
    /// 8–44): centred on it, the arrow's tip at the capsule's bottom edge,
    /// the body 213 wide and its frame 241 wide (window (549, 40), ±1).
    @Test func schemeChooserHangsCentredUnderItsHalf() {
        let list = SchemeChooser.list(schemes: ["Parity"], current: "Parity")
        let place = PopoverPlacement.place(anchor: CGRect(x: 600, y: 8, width: 140, height: 36),
                                           bodySize: CGSize(width: PopoverMetrics.schemeBodyWidth, height: list.bodyHeight), edge: .below)
        #expect(abs(place.body.midX - 670) <= 1)
        #expect(place.arrowTip == CGPoint(x: place.body.minX + place.arrowTipX, y: 44))
        #expect(abs(place.body.minY - 54) <= 1)
        #expect(abs(place.frame.width - 241) <= 1 && abs(place.frame.height - 191) <= 1)
        #expect(abs(place.frame.minX - 549) <= 1 && abs(place.frame.minY - 40) <= 1)
    }

    /// Quick Help: above the symbol, the arrow down with its tip 3 over the
    /// line, centred on the symbol, and never flipped: a symbol on the
    /// first line puts the body above the window's top (negative y).
    @Test func quickHelpOpensAboveTheSymbolNeverFlipped() {
        let symbol = CGRect(x: 1380, y: 600, width: 66, height: 16)
        let p = PopoverPlacement.place(anchor: symbol, bodySize: CGSize(width: 386, height: 220), edge: .above, gap: PopoverMetrics.textAnchorGap)
        #expect(p.edge == .above && p.arrowTip.y == 597)
        #expect(abs(p.body.maxY - (597 - PopoverMetrics.arrowHeight)) < 0.001)
        #expect(abs(p.body.midX - symbol.midX) <= 0.5)
        let top = PopoverPlacement.place(anchor: CGRect(x: 500, y: 90, width: 30, height: 16), bodySize: CGSize(width: 386, height: 300),
                                         edge: .above, gap: 3)
        #expect(top.body.minY < 0, "it extends past the window's top instead of flipping below")
    }

    /// Shifted along the edge to stay on the screen; the arrow stays on the
    /// anchor, clear of the rounded corners.
    @Test func placementShiftsToStayInsideItsBoundsArrowOnTheAnchor() {
        let p = PopoverPlacement.place(anchor: CGRect(x: 10, y: 8, width: 40, height: 36), bodySize: CGSize(width: 415, height: 223),
                                       edge: .below, bounds: CGRect(x: 0, y: 0, width: 1400, height: 880))
        #expect(p.body.minX == 0)
        #expect(p.arrowTipX == PopoverMetrics.cornerRadius + PopoverMetrics.arrowWidth / 2)
    }

    // MARK: The scheme chooser (§2.3, P-111)

    @Test func schemeChooserRowsAndHeight() {
        let list = SchemeChooser.list(schemes: ["Parity"], current: "Parity")
        #expect(list.rows.map(\.title) == ["Parity", "", "Edit Scheme…", "New Scheme…", "Manage Schemes…"])
        #expect(list.rows[0].isChecked && list.highlighted == 0, "the current scheme is highlighted on opening")
        // 7 + 30 + 6, one row, a separator, three commands, 12: the body's 163.
        #expect(list.bodyHeight == 163)
        #expect(SchemeChooser.command(list.rows[3]) == .new)
        let filtered = SchemeChooser.list(schemes: ["App", "Tool"], current: "App", filter: "to")
        #expect(filtered.rows.first?.title == "Tool")
    }

    /// Up and Down skip separators and headings and stop at the ends.
    @Test func keysMoveTheHighlightOverSelectableRows() {
        var list = SchemeChooser.list(schemes: ["A", "B"], current: "B")
        #expect(list.highlighted == 1)
        list.move(1)
        #expect(list.current?.title == "Edit Scheme…")
        list.move(-1)
        list.move(-1)
        list.move(-1)
        #expect(list.current?.title == "A")
        list.move(10)
        #expect(list.current?.title == "Manage Schemes…")
        list.hover(2)
        #expect(list.current?.title == "Manage Schemes…", "hovering a separator leaves the highlight")
    }

    // MARK: The destination chooser (§2.3–§2.4, P-113)

    func model(incompatible: [Destination] = []) -> DestinationMenuModel {
        DestinationMenuModel(current: Destination.myMac, devices: [], simulators: incompatible, platforms: ["macOS"])
    }

    @Test func destinationChooserListsTheMacOnceUnderRecent() {
        var mac = Destination.myMac
        mac.osVersion = "27.2"
        let m = DestinationMenuModel(current: mac, devices: [], simulators: [], platforms: ["macOS"])
        let list = DestinationChooser.list(model: m, current: mac, expanded: false)
        #expect(list.rows.filter { $0.title == "My Mac" }.count == 1)
        #expect(list.rows.map(\.title) == ["Recent", "My Mac", "Build", "Any Mac (arm64, x86_64)", "", "Incompatible", "", "Manage Devices…"])
        #expect(list.rows[1].isChecked && list.rows[1].trailing == "27.2" && list.highlighted == 1)
        // The reference's 442 × 251 frame: a 223-tall body.
        #expect(list.bodyHeight == 223)
        #expect(list.rows[5].isEnabled == false, "nothing incompatible: the disclosure is disabled")
    }

    @Test func incompatibleExpandsInPlace() {
        let sim = Destination(name: "iPhone 17", specifier: "id=1", platform: "iOS", kind: .simulator, osVersion: "27.1", identifier: "1")
        let m = model(incompatible: [sim])
        let closed = DestinationChooser.list(model: m, current: .myMac, expanded: false)
        let i = try? #require(closed.rows.firstIndex { DestinationChooser.isIncompatible($0) })
        #expect(closed.rows[i ?? 0].kind == .disclosure(expanded: false) && closed.rows[i ?? 0].isEnabled)
        let open = DestinationChooser.list(model: m, current: .myMac, expanded: true)
        #expect(open.rows[i ?? 0].kind == .disclosure(expanded: true))
        #expect(open.rows[(i ?? 0) + 1].title == "iPhone 17 (mismatched platform)" && open.rows[(i ?? 0) + 1].trailing == "27.1")
        #expect(open.rows.last?.title == "Manage Devices…", "Manage Devices… moves to the bottom")
        #expect(open.bodyHeight == closed.bodyHeight + PopoverMetrics.rowHeight, "the popover grows downward by the rows")
    }

    /// Ycode's own rows sit under the Simulators heading, never at the bottom.
    @Test func ycodeRowsGoUnderSimulators() {
        let extra = ChooserRow(kind: .command, title: "Set Up Ycode Simulator…", key: "command:setUp")
        let list = DestinationChooser.list(model: model(), current: .myMac, expanded: false, extras: [extra])
        let s = try? #require(list.rows.firstIndex { $0.kind == .heading && $0.title == "Simulators" })
        #expect(list.rows[(s ?? 0) + 1].title == "Set Up Ycode Simulator…")
        #expect(list.rows.last?.title == "Manage Devices…")
    }

    /// The Linux IDE's groups: this computer under Devices, the simulator
    /// hosts under Simulators, the current one under Recent only.
    @Test func linuxGroupsMapToTheSameHeadings() {
        let host = Destination(name: "My Computer", specifier: "platform=Linux", platform: "Linux", kind: .mac)
        let sim = Destination(name: "iPhone 17 on thor", specifier: "id=2", platform: "iOS", kind: .simulator, identifier: "2")
        let groups = [DestinationGroup(title: "My Computer", destinations: [host]), DestinationGroup(title: "thor", destinations: [sim])]
        let list = DestinationChooser.list(sections: DestinationChooser.sections(groups: groups, current: host), incompatible: [], current: host,
                                           expanded: false)
        #expect(list.rows.map(\.title).prefix(4) == ["Recent", "My Computer", "Simulators", "iPhone 17 on thor"])
    }

    // MARK: Product ▸ Destination (§9, P-014)

    @Test func destinationMenuRowsCarryVersionsAndNoEmptyHeading() {
        var mac = Destination.myMac
        mac.osVersion = "27.2"
        #expect(DestinationProductMenu.title(mac) == "My Mac 27.2")
        #expect(DestinationProductMenu.title(.anyMac) == "Any Mac (arm64, x86_64)")
        let m = DestinationMenuModel(current: mac, devices: [], simulators: [], platforms: ["macOS"])
        #expect(DestinationProductMenu.sections(m).map(\.title) == ["Devices", "Build"], "no empty Simulators heading")
    }

    // MARK: In-window panels (§5, §10) and the sheet (§3)

    @Test func capsulesSitCentredUnderTheToolbar() {
        #expect(InWindowPanel.jumpToLine.frame(windowWidth: 1400) == CGRect(x: 380, y: 69, width: 640, height: 55))
        #expect(InWindowPanel.quickActions.frame(windowWidth: 1400) == CGRect(x: 420, y: 55, width: 560, height: 55))
        #expect(InWindowPanel.openQuickly.frame(windowWidth: 1400) == CGRect(x: 380, y: 70, width: 640, height: 55))
        #expect(OpenQuicklyLayout.top == 70)
        #expect(InWindowPanel.jumpToLine.fieldFrame == CGRect(x: 61, y: 10, width: 560, height: 36))
        #expect(InWindowPanel.jumpToLine.cornerRadius == 27.5 && InWindowPanel.jumpToLine.placeholder == "Line Number")
        #expect(InWindowPanel.quickActions.placeholder == "Quick Actions" && InWindowPanel.quickActions.fieldWidth == 480)
        #expect(QuickNewProject.height(rows: QuickNewProject.rows.count) == 355)
    }

    @Test func newSchemeSheetButtons() {
        typealias M = NewSchemeSheetMetrics
        #expect(M.width == 493 && M.height == 122)
        #expect(M.okFrame == CGRect(x: 389, y: 82, width: 84, height: 23))
        #expect(M.cancelFrame == CGRect(x: 293, y: 82, width: 84, height: 23))
    }

    @Test func palettes() {
        var qa = PaletteList(["Build", "Clean Build Folder…", "Run"], emptyQueryShowsAll: false) { $0 }
        #expect(qa.shown.isEmpty, "Quick Actions lists nothing until something is typed")
        qa.setQuery("build")
        #expect(qa.shown.first == "Build" && qa.shown.count == 2)
        qa.move(5)
        #expect(qa.current == "Clean Build Folder…")
        var qnp = QuickNewProject.list()
        #expect(qnp.shown.map(\.title) == NewProjectPicker.rows.map(\.title))
        qnp.setQuery("tool")
        #expect(qnp.current?.title == "Command Line Tool" && qnp.current?.index == 1)
        #expect(JumpToLineInput.line("12", lineCount: 40) == 12 && JumpToLineInput.line("3:4", lineCount: 40) == 3)
        #expect(JumpToLineInput.line("999", lineCount: 40) == 40 && JumpToLineInput.line("x", lineCount: 40) == nil)
    }

    // MARK: New Scheme writes a shared scheme (P-112)

    @Test func newSchemeWritesASharedSchemeForTheTarget() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-newscheme-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var o = ProjectOptions()
        o.productName = "Glass"
        o.organizationIdentifier = "org.ycode.tests"
        o.testing = .none
        o.setStorage(.none)
        let url = try ProjectTemplate.app.create(platform: "iOS", options: o, in: dir)
        let ws = try WorkspaceModel(url: url)
        var m = NewSchemeModel(model: ws)
        #expect(m.targets.map(\.name) == ["Glass"] && m.name == "Glass")
        #expect(throws: NewSchemeModel.Failure.exists("Glass")) { try m.create(in: ws) }
        m.name = "Glass Debug"
        let s = try m.create(in: ws)
        #expect(s.isShared && s.url?.path.contains("xcshareddata/xcschemes/Glass Debug.xcscheme") == true)
        #expect(FileManager.default.fileExists(atPath: s.url!.path))
        // The autocreated scheme was written too, so both stay listed.
        let names = Scheme.discover(in: url).map(\.name)
        #expect(names.contains("Glass") && names.contains("Glass Debug"))
        m.name = "   "
        #expect(!m.canCreate)
    }
}
