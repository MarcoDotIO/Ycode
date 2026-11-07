import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeIDEShell

/// The Linux IDE's navigator and inspector against the macOS IDE's
/// (`specs/ide/cross-platform-parity.md` §3, §5, §7): the shared metrics,
/// the open file's row, the File inspector's rows, the project icons'
/// colours, the Source Control rows.
@MainActor
@Suite(.serialized) struct PanesParityShellTests {
    func model(_ g: GitPackage) async throws -> WorkspaceShellModel {
        let m = try WorkspaceShellModel(url: g.url, engine: ScriptedEngine(lines: [], issues: []))
        await m.sourceControl.idle()
        return m
    }

    @Test func sharedMetricsAreTheMacOSInspectorsAndOutlines() {
        // §3: 14 per level (the macOS outline's; it was 12 here).
        #expect(WorkspaceChrome.indentationPerLevel == 14)
        // §5: insets 7 and 8, a 72-point key column, values 5 after it.
        #expect(WorkspaceChrome.inspectorLeadingInset == 7 && WorkspaceChrome.inspectorTrailingInset == 8)
        #expect(WorkspaceChrome.inspectorKeyColumnWidth == 72 && WorkspaceChrome.inspectorKeyToValue == 5)
        // Row 135's rhythm (G.5), shared by both IDEs.
        #expect(ResourceInspectorRhythm.propertyInset * 2 + 14 == 18)
    }

    @Test func theOpenFilesRowIsSelectedHoweverItWasOpened() async throws {
        let g = try GitPackage()
        defer { g.remove() }
        let m = try await model(g)
        let path = g.workspacePath("Sources/DemoCore/Greeting.swift")
        #expect(m.projectSelection == nil)
        // Opened without a click on its row (Open Quickly, Find, history).
        m.open(path)
        let row = try #require(m.root.idPath(to: path)?.last)
        #expect(m.selection == nil && m.projectSelection == row)
        // A group row the person selects keeps the band.
        let group = try #require(m.root.idPath(to: path)?.dropLast().last)
        m.selection = group
        #expect(m.projectSelection == group)
        // Another file opened moves it.
        let other = g.workspacePath("Sources/Demo/main.swift")
        m.selection = m.root.idPath(to: other)?.last
        m.open(g.workspacePath("Sources/DemoCore/Greeting.swift"))
        #expect(m.projectSelection == row)
    }

    @Test func fileInspectorHasTheMacOSRows() async throws {
        let g = try GitPackage()
        defer { g.remove() }
        let m = try await model(g)
        let path = g.workspacePath("Sources/DemoCore/Greeting.swift")
        m.open(path)
        let sections = m.fileInspector
        // A package's file: Identity and Type, then Text Settings.
        #expect(sections.map(\.title) == ["Identity and Type", "Text Settings"])
        let keys = sections[0].rows.map(\.key)
        #expect(keys == ["Name", "Type", "Location", "", "Full Path", "Working Copy", "Relative Path"])
        let rel = sections[0].rows.first { $0.key == "Relative Path" }?.value
        #expect(rel == .text("Sources/DemoCore/Greeting.swift"))
        // Rules after Type, Full Path and Line Endings.
        let ruled = sections.flatMap(\.rows).filter(\.ruleAfter).map(\.key)
        #expect(ruled == ["Type", "Full Path", "Line Endings"])
        // The file name under Location is regular weight, as on macOS.
        #expect(sections[0].rows[3].value == .label("Greeting.swift", bold: false))
        // "No Explicit …" titles are grey.
        #expect(sections[1].rows[0].value == .popUp(WorkspaceChrome.textEncodingItems[0], dimmed: true))
    }

    @Test func projectRowsCarryTheIconColourFamilies() async throws {
        let g = try GitPackage()
        defer { g.remove() }
        let m = try await model(g)
        for id in m.root.idPath(to: g.workspacePath("Sources/DemoCore/Greeting.swift")) ?? [] { m.setExpanded(id, true) }
        let rows = m.projectRows
        #expect(rows.first { $0.title == "Greeting" }?.tint == .icon(.orange))
        #expect(rows.first { $0.title == "Sources" }?.tint == .icon(.lightBlue))
        #expect(rows.first?.tint == .icon(.blue))
    }

    @Test func sourceControlRowsMatchTheMacOSNavigator() async throws {
        let g = try GitPackage()
        defer { g.remove() }
        try g.write("Sources/DemoCore/Greeting.swift", "public struct Greeting {}\n")
        let m = try await model(g)
        let changes = m.sourceControl.rows
        // §7: the repository row regular weight, an outline drive in the
        // accent colour; the count right after "Uncommitted Changes"; the
        // project navigator's glyph and colour for a changed file.
        #expect(changes[0].isBold == false && changes[0].symbol == "externaldrive" && changes[0].tint == .accent)
        #expect(changes[1].detail == "1")
        #expect(changes[2].symbol == WorkspaceChrome.fileSymbol("Greeting.swift") && changes[2].tint == .icon(.orange))
        m.sourceControl.mode = .repositories
        let repos = m.sourceControl.rows
        #expect(repos[0].symbol == RepositoriesViewStyle.repositorySymbol && repos[0].tint == .icon(.grey) && !repos[0].isBold)
        #expect(repos.filter { $0.id.hasPrefix("group:") }.allSatisfy { $0.tint == .icon(.grey) })
        #expect(repos.first { $0.id == "branch:main" }?.tint == .accent)
    }

    @Test func imageHeaderReadsPNGProperties() throws {
        // An 80 × 180 RGB PNG with a 144-dpi pHYs chunk (5669 per metre).
        func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
            let n = UInt32(data.count)
            return [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + Array(type.utf8) + data + [0, 0, 0, 0]
        }
        func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        let sig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let png = sig + chunk("IHDR", be(80) + be(180) + [8, 2, 0, 0, 0]) + chunk("pHYs", be(5669) + be(5669) + [1]) + chunk("IDAT", [0]) + chunk("IEND", [])
        let info = try #require(ImageHeaderInfo.parsePNG(png))
        #expect(info.rows.map(\.1) == ["80 × 180 pixels", "144 × 144 DPI", "RGB", "No"])
        let alpha = try #require(ImageHeaderInfo.parsePNG(sig + chunk("IHDR", be(2) + be(2) + [8, 6, 0, 0, 0]) + chunk("IEND", [])))
        #expect(alpha.hasAlpha && alpha.dpi == nil && alpha.rows[1].1 == "--")
        #expect(ImageHeaderInfo.parsePNG([1, 2, 3]) == nil)
    }
}
