import Foundation
import Testing
@testable import YcodeIDECore

/// Writes `.xcarchive` bundles in the layout `specs/ide/organizer.md`
/// reads (Info.plist and, with an application, its Products folder), with
/// no tools: the tests run on macOS and Linux alike.
struct ArchiveFixtures {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-organizer-\(UUID().uuidString)/Archives")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    @discardableResult
    func make(day: String = "2026-11-05", _ name: String, app: String?, version: String = "1.0", build: String = "1",
              created: Date, comment: String? = nil) throws -> URL {
        let url = root.appendingPathComponent(day).appendingPathComponent("\(name).xcarchive")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("dSYMs"), withIntermediateDirectories: true)
        var info: [String: Any] = ["ArchiveVersion": 2, "CreationDate": created, "Name": name, "SchemeName": name]
        if let comment { info["Comment"] = comment }
        if let app {
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Products/Applications/\(app).app/Contents"),
                                                    withIntermediateDirectories: true)
            info["ApplicationProperties"] = ["ApplicationPath": "Applications/\(app).app", "Architectures": ["arm64", "x86_64"],
                                             "CFBundleIdentifier": "org.example.\(app)", "CFBundleShortVersionString": version,
                                             "CFBundleVersion": build]
        }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Info.plist"))
        return url
    }
}

/// The Organizer's shared state (`OrganizerState`), which the macOS and
/// Linux Organizers both draw (`specs/ide/organizer.md`, `reference-ui-3.md` §6).
struct OrganizerStateTests {
    let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    @Test func groupsByApplicationNewestFirstAndPicksTheFirstApp() throws {
        let f = try ArchiveFixtures()
        defer { f.remove() }
        try f.make(day: "2026-11-04", "Greeter 1", app: "Greeter", version: "1.0", build: "1", created: t0, comment: "First")
        try f.make("Greeter 2", app: "Greeter", version: "1.1", build: "2", created: t0 + 3600)
        try f.make("Notes", app: "Notes", version: "2.0", build: "14", created: t0 + 1800)
        try f.make("tool", app: nil, created: t0 + 60)
        // A folder without an Info.plist is not an archive.
        try FileManager.default.createDirectory(at: f.root.appendingPathComponent("2026-11-05/Broken.xcarchive"), withIntermediateDirectories: true)

        var s = OrganizerState()
        #expect(s.appPickerTitles == ["No App"] && s.rows.isEmpty)
        s.load(Organizer.archives(in: f.root))
        #expect(s.appPickerTitles == ["Greeter", "Notes", "tool"])
        #expect(s.selectedApp == "Greeter")
        #expect(s.rows.map(\.title) == ["Greeter", "Greeter 2", "Greeter 1"])
        #expect(s.rows[0].archive == nil && s.rows[1].archive?.versionText == "1.1 (2)")
        #expect(s.detailRows.map(\.0) == ["No Selection"] && !s.canDistribute)

        s.chooseApp("tool")
        #expect(s.rows.map(\.title) == ["tool", "tool"])
        s.chooseApp("Missing")
        #expect(s.selectedApp == "tool")
    }

    @Test func detailsAndCellsDescribeTheSelection() throws {
        let f = try ArchiveFixtures()
        defer { f.remove() }
        let a = try f.make("Greeter 1", app: "Greeter", version: "1.0", build: "7", created: t0, comment: "First")
        let g = try f.make("tool", app: nil, created: t0 + 60)
        var s = OrganizerState()
        s.load(Organizer.archives(in: f.root))
        let rowA = s.select(archiveAt: a)
        #expect(rowA == 1)
        let date = OrganizerState.dateText(t0)
        #expect(s.detailRows.map { "\($0.0)=\($0.1)" } == [
            "Name=Greeter 1", "Creation Date=\(date)", "Version=1.0 (7)", "Identifier=org.example.Greeter", "Type=macOS App Archive",
            "Architectures=arm64, x86_64", "Status=Archived", "Comment=First",
        ])
        #expect(s.canDistribute)
        let entry = try #require(s.selected)
        #expect(OrganizerState.columns.map(\.title) == ["Name", "Creation Date", "Version", "Status"])
        #expect(OrganizerState.columns.map { OrganizerState.cellText(entry, column: $0.id) } == ["Greeter 1", date, "1.0 (7)", "Archived"])

        // Selecting the other application's archive switches the picker.
        let rowG = s.select(archiveAt: g)
        #expect(rowG == 1 && s.selectedApp == "tool")
        #expect(s.detailRows.contains { $0 == ("Type", "Generic Archive") } && s.detailRows.contains { $0 == ("Comment", "No Description") })
        #expect(!s.canDistribute)
        // A heading selects nothing; choosing another app drops the selection.
        s.selectRow(0)
        #expect(s.selected == nil && s.selectedRow == nil)
        s.selectRow(1)
        s.chooseApp("Greeter")
        #expect(s.selected == nil)
    }

    @Test func reloadKeepsTheSelectionAndMarksExports() throws {
        let f = try ArchiveFixtures()
        defer { f.remove() }
        let a = try f.make("Greeter 1", app: "Greeter", created: t0)
        var s = OrganizerState()
        s.load(Organizer.archives(in: f.root))
        s.select(archiveAt: a)
        try f.make("Greeter 2", app: "Greeter", created: t0 + 60)
        s.load(Organizer.archives(in: f.root))
        #expect(s.rows.map(\.title) == ["Greeter", "Greeter 2", "Greeter 1"] && s.selected?.name == "Greeter 1" && s.selectedRow == 2)
        s.markExported(a)
        #expect(s.selected?.status == "Exported" && s.rows[2].archive?.status == "Exported")
        s.load(Organizer.archives(in: f.root), exported: [a.standardizedFileURL.path])
        #expect(s.groups[0].archives.map(\.status) == ["Archived", "Exported"])
    }

    @Test func pagesHistoryAndEmptyStates() {
        var s = OrganizerState()
        #expect(s.history.count == 1 && s.page == "Archives" && !s.canGoBack && !s.canGoForward)
        s.showPage("Archives", section: "Products")
        s.showPage("Archives", section: "Products")
        #expect(s.history.count == 1 && s.showsArchives && s.sidebarRow == 1)
        s.showPage("Overview", section: "Insights")
        s.showPage("Hitches", section: "Metrics")
        #expect(!s.showsArchives && s.emptyState == ("No Hitches Data", "There is no hitches data available for version 1.0."))
        var moved = s.moveInHistory(-1)
        #expect(moved && s.page == "Overview" && s.section == "Insights" && s.canGoForward)
        moved = s.moveInHistory(-1)
        #expect(moved && s.page == "Archives" && !s.canGoBack)
        moved = s.moveInHistory(-1)
        #expect(!moved)
        // A new page drops the pages ahead.
        s.showPage("Crashes", section: "Reports")
        #expect(s.history.map(\.page) == ["Archives", "Crashes"] && !s.canGoForward)
        #expect(OrganizerSidebar.rows[s.sidebarRow ?? 0].page == "Crashes")
    }

    @Test func emptyStateNamesTheChosenAppsVersion() throws {
        let f = try ArchiveFixtures()
        defer { f.remove() }
        try f.make("Notes", app: "Notes", version: "2.0", build: "14", created: t0)
        var s = OrganizerState()
        s.load(Organizer.archives(in: f.root))
        s.showPage("Overview", section: "Insights")
        #expect(s.emptyState.message == "There is no overview data available for version 2.0 (14).")
    }

    @Test func columnsFitTheListBetweenSidebarAndDetails() {
        // 900 − (8 + 180 + 8) − 250 = 454 points for the list.
        #expect(OrganizerState.columns.reduce(0) { $0 + $1.width } <= 454 - 16)
        #expect(Organizer.defaultArchivesDirectory.path.hasSuffix("Library/Developer/Xcode/Archives"))
    }
}
