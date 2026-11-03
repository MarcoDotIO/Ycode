import Foundation
import OVPlatform
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// Round R13: `Table` (sortable, resizable columns, selection).

struct FileRow: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let size: Int
    let kind: String
}

let tableRows = [
    FileRow(name: "main.swift", size: 300, kind: "Swift"),
    FileRow(name: "Package.swift", size: 120, kind: "Swift"),
    FileRow(name: "README.md", size: 2048, kind: "Markdown"),
]

@MainActor
final class TableProbe {
    var selection: Set<String> = []
    var order: [KeyPathComparator<FileRow>] = []
}

struct FilesTable: View {
    let probe: TableProbe
    @State private var rows = tableRows.sorted(using: KeyPathComparator(\FileRow.name))
    @State private var selection: Set<String> = []
    @State private var order = [KeyPathComparator(\FileRow.name)]

    var body: some View {
        Table(rows, selection: Binding(get: { selection }, set: { selection = $0; probe.selection = $0 }),
              sortOrder: Binding(get: { order }, set: { order = $0; probe.order = $0 })) {
            TableColumn("Name", value: \.name)
            TableColumn("Size", value: \.size) { r in Text("\(r.size)") }
                .width(80)
            TableColumn("Kind") { r in Text(r.kind) }
                .width(min: 60, ideal: 120)
        }
        .onChange(of: order) { _, new in rows.sort(using: new) }
    }
}

@MainActor
@Suite("R13 tables")
struct TableTests {
    func header(_ h: CommandsHarness, _ i: Int) -> CGRect? { h.identified("table header \(i)") }

    @Test func columnsLayOutWithFixedIdealAndFlexibleWidths() {
        let probe = TableProbe()
        let h = CommandsHarness(menuBar: false) { FilesTable(probe: probe) }
        guard let name = header(h, 0), let size = header(h, 1), let kind = header(h, 2) else { Issue.record("headers"); return }
        #expect(abs(size.width - 80) < 0.5)
        #expect(abs(kind.width - 120) < 0.5)
        // The flexible column takes the rest of the 800-point window.
        #expect(abs(name.width - 600) < 0.5)
        #expect(name.maxX <= size.minX + 0.5 && size.maxX <= kind.minX + 0.5)
        // Cells sit under their headers, in data order.
        guard let main = h.textFrame("main.swift"), let readme = h.textFrame("README.md"), let big = h.textFrame("2048")
        else { Issue.record("cells"); return }
        #expect(main.minX >= name.minX && main.maxX <= name.maxX)
        #expect(big.minX >= size.minX && big.maxX <= size.maxX + 0.5)
        let order = tableRows.sorted(using: KeyPathComparator(\FileRow.name)).map(\.name)
        #expect((order.firstIndex(of: "README.md")! > order.firstIndex(of: "main.swift")!) == (readme.minY > main.minY))
    }

    @Test func headerClicksWriteTheSortOrderAndTheAppSorts() {
        let probe = TableProbe()
        let h = CommandsHarness(menuBar: false) { FilesTable(probe: probe) }
        guard let name = header(h, 0), let size = header(h, 1) else { Issue.record("headers"); return }
        // Name is the first sort column: a click reverses it.
        h.click(CGPoint(x: name.midX, y: name.midY), at: 1.0)
        #expect(probe.order.first?.order == .reverse)
        h.run(until: 1.2)
        // (The order is Foundation's for String key paths: the localized
        // standard order on Apple hosts, the plain one on Linux.)
        let expected = tableRows.sorted(using: KeyPathComparator(\FileRow.name, order: .reverse)).map(\.name)
        let shown = expected.compactMap { h.textFrame($0) }.map(\.minY)
        #expect(shown.count == 3 && shown == shown.sorted())
        // Size goes first, forward.
        h.click(CGPoint(x: size.midX, y: size.midY), at: 1.5)
        #expect(probe.order.count == 2 && probe.order.first?.keyPath == \FileRow.size && probe.order.first?.order == .forward)
        h.run(until: 1.7)
        if let p = h.textFrame("Package.swift"), let m = h.textFrame("main.swift"), let r = h.textFrame("README.md") {
            #expect(p.minY < m.minY && m.minY < r.minY)
        }
        // A column without a comparator does not sort.
        guard let kind = header(h, 2) else { return }
        h.click(CGPoint(x: kind.midX, y: kind.midY), at: 2.0)
        #expect(probe.order.first?.keyPath == \FileRow.size)
    }

    @Test func rowsSelectLikeAList() {
        let probe = TableProbe()
        let h = CommandsHarness(menuBar: false) { FilesTable(probe: probe) }
        guard let main = h.textFrame("main.swift") else { Issue.record("rows"); return }
        h.click(CGPoint(x: main.midX, y: main.midY), at: 1.0)
        #expect(probe.selection == ["main.swift"])
        // Shift and an arrow extend towards the other rows (sorted by name).
        let order = tableRows.sorted(using: KeyPathComparator(\FileRow.name)).map(\.name)
        let i = order.firstIndex(of: "main.swift")!
        let next = i + 1 < order.count ? order[i + 1] : order[i - 1]
        h.key(i + 1 < order.count ? .downArrow : .upArrow, .shift, at: 1.2)
        #expect(probe.selection == ["main.swift", next])
        // A click on another column's cell selects that row too.
        guard let size = h.textFrame("120") else { return }
        h.click(CGPoint(x: size.midX, y: size.midY), at: 1.5)
        #expect(probe.selection == ["Package.swift"])
    }

    @Test func draggingAHeaderDividerResizesTheColumn() {
        let probe = TableProbe()
        let h = CommandsHarness(menuBar: false) { FilesTable(probe: probe) }
        guard let name = header(h, 0) else { Issue.record("headers"); return }
        let start = CGPoint(x: name.maxX - 1, y: name.midY)
        let w = h.windowID
        h.backend.post(.pointer(PointerEvent(window: w, kind: .mouse, phase: .down, location: start, button: 1, timestamp: 1.0)), at: 1.0)
        for i in 1...10 {
            let p = CGPoint(x: start.x - CGFloat(i) * 20, y: start.y)
            h.backend.post(.pointer(PointerEvent(window: w, kind: .mouse, phase: .moved, location: p, button: 1, timestamp: 1.0 + Double(i) * 0.02)),
                           at: 1.0 + Double(i) * 0.02)
        }
        let end = CGPoint(x: start.x - 200, y: start.y)
        h.backend.post(.pointer(PointerEvent(window: w, kind: .mouse, phase: .up, location: end, button: 1, isPressed: false, timestamp: 1.3)), at: 1.3)
        h.run(until: 1.5)
        guard let after = header(h, 0), let size = header(h, 1) else { Issue.record("headers"); return }
        #expect(abs(after.width - 400) < 2)
        #expect(abs(size.minX - after.maxX) < 1)
        #expect(abs(size.width - 80) < 0.5)
        // No sort happened.
        #expect(probe.order.isEmpty)
    }
}
