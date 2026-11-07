import Foundation
import Testing
import YcodeEditorKit
import YcodeIDECore
@testable import YcodeIDEShell

/// The Linux IDE's editor against the macOS IDE's (`specs/ide/cross-platform-
/// parity.md` §4, council round 5 rows 115, 116, 139): editor panes, the
/// image editor, the shared wrap, minimap and stepper rules. Headless, on
/// macOS and Linux.
@MainActor
@Suite struct EditorPanesParityTests {
    func model(_ pkg: TempPackage) throws -> WorkspaceShellModel {
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        m.recovery = EditorRecovery(directory: pkg.url.path + "/.recovery-test")
        return m
    }

    // MARK: Panes

    @Test func splitAddsAFocusedPaneShowingTheSameFile() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let a = pkg.path("README.md"), b = pkg.path("Package.swift")
        m.open(a)
        #expect(m.panes.panes.count == 1 && !m.panes.isSplit && m.panes.focusedPane.path == a)
        #expect(m.isEnabled(.splitEditor) && m.isEnabled(.splitEditorBelow))
        m.perform(.splitEditor)
        #expect(m.panes.panes.count == 2 && m.panes.sideBySide && m.panes.focused == 1)
        #expect(m.panes.panes.map(\.path) == [a, a])
        // The focused pane opens another file; the first keeps its own.
        m.open(b)
        #expect(m.panes.panes.map(\.path) == [a, b] && m.document?.path == b)
        let first = m.panes.panes[0].id
        m.focusPane(first)
        #expect(m.panes.focused == 0 && m.document?.path == a && m.editor?.path == a)
        // A third pane goes after the focused one; the first split decided
        // side by side for the window.
        m.perform(.splitEditorBelow)
        #expect(m.panes.panes.count == 3 && m.panes.focused == 1 && m.panes.sideBySide)
    }

    @Test func closingAPaneFocusesTheOneBeforeIt() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let a = pkg.path("README.md"), b = pkg.path("Package.swift")
        m.open(a)
        m.splitEditor(sideBySide: false)
        #expect(!m.panes.sideBySide)
        m.open(b)
        let second = m.panes.panes[1].id
        m.closePane(second)
        #expect(m.panes.panes.count == 1 && m.panes.focused == 0 && m.document?.path == a)
        // The last pane stays.
        m.closePane(m.panes.panes[0].id)
        #expect(m.panes.panes.count == 1)
    }

    @Test func closingTheDocumentInOnePaneKeepsItOpenInTheOther() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let a = pkg.path("README.md")
        m.open(a)
        m.editor?.buffer.setCaret(0)
        m.editor?.buffer.insertText("X")
        m.perform(.splitEditor)
        m.closeCurrentDocument(discard: true)
        #expect(m.document == nil && m.panes.focusedPane.path == nil)
        // The other pane still has the edited text.
        guard case .text(let d) = m.content(of: m.panes.panes[0]) else { Issue.record("no text"); return }
        #expect(d.buffer.text.hasPrefix("X") && m.editedPaths.contains(a))
    }

    @Test func aPaneWithNothingOpenSplitsIntoAnEmptyPane() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        m.perform(.splitEditor)
        #expect(m.panes.panes.count == 2 && m.document == nil && m.editor == nil && m.panes.panes[1].path == nil)
        #expect(m.jumpPath(for: nil).isEmpty)
        // Opening a file shows it in the focused (new) pane only.
        m.open(pkg.path("README.md"))
        #expect(m.panes.panes.map(\.path) == [nil, pkg.path("README.md")])
        guard case .none = m.content(of: m.panes.panes[0]) else { Issue.record("not empty"); return }
    }

    // MARK: The image editor

    static func png(width: Int, height: Int, colorType: UInt8 = 6, ppm: Int? = nil) -> [UInt8] {
        func be(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
        var b: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        b += be(13) + Array("IHDR".utf8) + be(width) + be(height) + [8, colorType, 0, 0, 0] + be(0)
        if let ppm { b += be(9) + Array("pHYs".utf8) + be(ppm) + be(ppm) + [1] + be(0) }
        b += be(0) + Array("IEND".utf8) + be(0)
        return b
    }

    @Test func imageHeadersGiveTheInspectorsValues() {
        let p = ShellImageFile.parse(Self.png(width: 80, height: 180))
        #expect(p == ShellImageFile(pixelWidth: 80, pixelHeight: 180, dpi: nil, colorSpace: "RGB", hasAlpha: true))
        #expect(p?.rows.map(\.1) == ["80 × 180 pixels", "--", "RGB", "Yes"])
        // 144 dpi: half the pixels in points.
        let hi = ShellImageFile.parse(Self.png(width: 800, height: 1800, colorType: 2, ppm: 5669))
        #expect(hi?.dpi == 144 && hi?.hasAlpha == false && hi?.pointSize == CGSize(width: 400, height: 900))
        // A JPEG's frame header (SOF0) and its JFIF density.
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 0x4A, 0x46, 0x49, 0x46, 0, 1, 1, 1, 0, 72, 0, 72, 0, 0,
                             0xFF, 0xC0, 0, 17, 8, 0, 50, 0, 100, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]
        #expect(ShellImageFile.parse(jpeg) == ShellImageFile(pixelWidth: 100, pixelHeight: 50, dpi: 72, colorSpace: "RGB", hasAlpha: false))
        #expect(ShellImageFile.parse(Array("not an image".utf8)) == nil)
        #expect(ShellImageFile.handles("/a/Stripes.PNG") && !ShellImageFile.handles("/a/main.swift"))
    }

    @Test func anImageOpensInTheImageEditor() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let png = pkg.path("Stripes.png")
        try Data(Self.png(width: 80, height: 180)).write(to: URL(fileURLWithPath: png))
        m.open(pkg.path("README.md"))
        m.open(png)
        // At once: no text, no "Binary file", the jump bar names it.
        #expect(m.imagePath == png && m.editor == nil && m.document?.message == nil)
        #expect(m.jumpPath.last?.title.hasPrefix("Stripes") == true)
        #expect(ShellImageFile.read(path: png)?.pixelWidth == 80)
        // A pane without focus shows it too.
        m.perform(.splitEditor)
        m.open(pkg.path("README.md"))
        guard case .image(let p) = m.content(of: m.panes.panes[0]) else { Issue.record("not an image"); return }
        #expect(p == png)
    }

    @Test func imageEditorGeometryIsTheMacOSOnes() {
        let box = ImageEditorMetrics.fitBox(width: 850, height: 784)
        #expect(box == (20, 20, 810, 704))
        // 1:1 when it fits, centred; scaled down (never up) when not.
        let r = ImageEditorMetrics.fittedRect(imageWidth: 80, imageHeight: 180, box: box)
        #expect(r == (385, 282, 80, 180))
        let big = ImageEditorMetrics.fittedRect(imageWidth: 800, imageHeight: 1800, box: box)
        #expect(abs(big.height - 704) < 0.001 && abs(big.width - 704 * 800 / 1800) < 0.001)
        #expect(ImageEditorMetrics.loadingDelay == 0.45)
    }

    // MARK: Shared rules (rows 115, 116, 139)

    @Test func equalPanesWrapAtTheSameColumns() {
        // G.2: 274-point panes a point apart both hold 17 cells of 8.04.
        let advance = 8.0361328125
        #expect(EditorMetrics.wrapColumns(room: 136, advance: advance) == 17)
        #expect(EditorMetrics.wrapColumns(room: 137, advance: advance) == 17)
        // C.1: 80 columns in an 850-point pane.
        #expect(EditorMetrics.wrapColumns(room: 644, advance: advance) == 80)
        // The minimap column is the macOS one: 15 % within 59–135, its
        // separator, and the 14-point scroll lane.
        #expect(EditorMetrics.minimapWidth(editorWidth: 274) == 59 && EditorMetrics.minimapWidth(editorWidth: 850) == 127)
        #expect(EditorMetrics.scrollerLane - EditorMetrics.minimapStrip == 11)
    }

    /// Where rows break, as the macOS text system breaks them (UAX #14 for
    /// source text): not before closing punctuation, after a hyphen, inside
    /// a string interpolation's `\(`.
    @Test func rowsBreakWhereTheMacOSEditorBreaksThem() {
        func starts(_ s: String, _ cols: Int, _ rest: Int) -> [Int] {
            EditorTextGeometry.rowStarts(of: Array(s), firstColumns: cols, continuationColumns: rest)
        }
        // "fancy }" moves as one: "}" never starts a row.
        #expect(starts("enum Kind: Int { case plain, fancy }", 35, 31) == [29])
        #expect(starts("aa foo-bar", 8, 8) == [7])
        // The macOS editor at 17 columns: `"Hello, \` / `(name` / `)! \` / `(coun` (rows of 5 after the indent).
        #expect(starts("        \"Hello, \\(name)! \\(count + 100)\"", 17, 5) == [17, 22, 26, 31, 35])
        #expect(!EditorTextGeometry.isBreakOpportunity(before: 2, in: Array("a ,b")))
        #expect(!EditorTextGeometry.isBreakOpportunity(before: 2, in: Array("a ;b")))
        #expect(!EditorTextGeometry.isBreakOpportunity(before: 2, in: Array("a )b")))
        #expect(EditorTextGeometry.isBreakOpportunity(before: 2, in: Array("a b")))
    }

    @Test func minimapRowsAreTheTextsVisualRows() {
        let band = Array("// " + String(repeating: "\u{2588}", count: 110))
        let w = MinimapRows.wrap(band, columns: 80, indent: 4)
        let rows = MinimapRows.rows(chars: band, keys: Array(repeating: 0, count: band.count), joins: Array(repeating: true, count: band.count),
                                    starts: w.starts, indent: w.indent)
        #expect(rows.count == 3 && rows.map { $0.map(\.length) } == [[2], [76], [34]])
        #expect(Double(rows.count) * EditorMetrics.minimapLinePitch == 9)
    }

    @Test func issueStepperShowsWithTheCapsulesCounts() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        #expect(IssueStepper.kind(errors: m.issueCounts.errors, warnings: m.issueCounts.warnings) == nil)
        #expect(IssueStepper.kind(errors: 0, warnings: 3) == .warning && IssueStepper.kind(errors: 1, warnings: 0) == .error)
        #expect(IssueStepper.width == 2 * IssueStepper.chevronWidth + IssueStepper.symbolWidth + 2 * IssueStepper.spacing)
    }
}
