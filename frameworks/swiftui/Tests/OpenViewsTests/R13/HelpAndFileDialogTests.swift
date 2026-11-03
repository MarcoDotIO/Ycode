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

// Round R13: tooltips (`help`), `toolbar(removing: .sidebarToggle)` and the
// empty column bar, the file dialogs (`fileImporter`, `fileExporter`) and
// OpenViews' `UTType`.

@MainActor
extension CommandsHarness {
    /// The frame of the accessibility element with this identifier.
    func identified(_ id: String) -> CGRect? {
        AccessibilityTree.build(main).flattened.first { $0.identifier == id }?.frame
    }

    func click(identified id: String, at t: TimeInterval) {
        guard let f = identified(id) else {
            Issue.record("no element \(id)")
            return
        }
        click(CGPoint(x: f.midX, y: f.midY), at: t)
    }
}

/// A scratch folder: A.swift, notes.txt, Demo.xcodeproj/, Sub/B.swift, .hidden.
func makeDialogFolder() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ov-r13-dialog-\(UUID().uuidString)")
    let fm = FileManager.default
    try fm.createDirectory(at: root.appendingPathComponent("Sub"), withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appendingPathComponent("Demo.xcodeproj"), withIntermediateDirectories: true)
    try Data("let a = 1\n".utf8).write(to: root.appendingPathComponent("A.swift"))
    try Data("notes\n".utf8).write(to: root.appendingPathComponent("notes.txt"))
    try Data("".utf8).write(to: root.appendingPathComponent(".hidden"))
    try Data("let b = 2\n".utf8).write(to: root.appendingPathComponent("Sub/B.swift"))
    try Data("{}".utf8).write(to: root.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
    return root.standardizedFileURL
}

let projectType = UTType(filenameExtension: "xcodeproj", conformingTo: .package)!

@MainActor
final class DialogLog {
    var results: [String] = []
}

struct ImporterView: View {
    let folder: URL
    let log: DialogLog
    @State var shown = true
    var body: some View {
        Text("Window")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .fileImporter(isPresented: $shown, allowedContentTypes: [.swiftSource, projectType]) { r in
                switch r {
                case .success(let u): log.results.append(u.lastPathComponent)
                case .failure(let e): log.results.append("error \(e)")
                }
            }
            .fileDialogDefaultDirectory(folder)
    }
}

struct TextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct ExporterView: View {
    let folder: URL
    let log: DialogLog
    @State var shown = true
    var body: some View {
        Text("Window")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .fileExporter(isPresented: $shown, document: TextDocument(text: "hello"), contentType: .plainText,
                          defaultFilename: "Summary") { r in
                switch r {
                case .success(let u): log.results.append(u.lastPathComponent)
                case .failure(let e): log.results.append("error \(e)")
                }
            }
            .fileDialogDefaultDirectory(folder)
    }
}

@MainActor
@Suite("R13 help, sidebar toggle, file dialogs")
struct HelpAndFileDialogTests {
    @Test func helpShowsATooltipAfterTheDelayAndHidesOnLeave() {
        let h = CommandsHarness(menuBar: false) {
            VStack(spacing: 40) {
                Button("Build") {}.help("Build the scheme")
                Button("Clean") {}.help("Remove the build products")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        guard let build = h.textFrame("Build"), let clean = h.textFrame("Clean") else { Issue.record("buttons"); return }
        h.hover(CGPoint(x: build.midX, y: build.midY), at: 1.0)
        h.run(until: 1.5)
        #expect(h.textFrame("Build the scheme") == nil)
        h.run(until: 2.0)
        guard let tip = h.textFrame("Build the scheme") else { Issue.record("no tooltip"); return }
        // Under the pointer.
        #expect(tip.minY > build.midY && tip.minX >= build.midX - 1)
        // Leaving hides it; the next view with help shows its tip at once.
        h.hover(CGPoint(x: clean.midX, y: clean.midY), at: 2.1)
        h.run(until: 2.15)
        #expect(h.textFrame("Build the scheme") == nil)
        #expect(h.textFrame("Remove the build products") != nil)
        // A press hides it.
        h.click(CGPoint(x: clean.midX, y: clean.midY), at: 2.3)
        #expect(h.textFrame("Remove the build products") == nil)
        // The help text is the accessibility hint.
        let tree = AccessibilityTree.build(h.main)
        #expect(tree.flattened.first { $0.label == "Build" }?.hint == "Build the scheme")
    }

    @Test func tooltipsStayInsideTheWindow() {
        let h = CommandsHarness(menuBar: false) {
            HStack {
                Spacer()
                Text("Edge").help("A rather long help text near the right edge of the window")
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        guard let edge = h.textFrame("Edge") else { Issue.record("edge"); return }
        h.hover(CGPoint(x: edge.midX, y: edge.midY), at: 1.0)
        h.run(until: 2.0)
        guard let tip = h.textFrame("A rather long help text near the right edge of the window") else {
            Issue.record("no tooltip")
            return
        }
        #expect(tip.maxX <= 800 && tip.maxY <= 500)
        #expect(tip.maxY <= edge.midY)   // above the pointer: no room below
    }

    struct Split: View {
        var removed: Bool
        var body: some View {
            if removed {
                NavigationSplitView { Text("Side") } detail: { Text("Detail") }
                    .toolbar(removing: .sidebarToggle)
            } else {
                NavigationSplitView { Text("Side") } detail: { Text("Detail") }
            }
        }
    }

    @Test func removingTheSidebarToggleLeavesNoColumnBar() {
        let with = CommandsHarness(menuBar: false, desktop: true) { Split(removed: false) }
        let without = CommandsHarness(menuBar: false, desktop: true) { Split(removed: true) }
        guard let a = with.textFrame("Side"), let b = without.textFrame("Side") else { Issue.record("columns"); return }
        // The toggle's 44-point bar is gone.
        #expect(a.minY - b.minY > 20)   // (the content is centred in its column)
        // The split view settles: its toolbar registration does not
        // re-evaluate the column's bar in a loop (the update ran into the
        // pass limit on desktop hosts before R13).
        #expect(with.main.graph.passCount < 20 && without.main.graph.passCount < 20)
        var buttons = 0
        without.main.graph.root?.forEachNode { n in
            if let i = n.view as? Image, case .system("sidebar.left") = i.source, !n.isInSuspendedSubtree { buttons += 1 }
        }
        #expect(buttons == 0)
    }

    @Test func utTypesConformAndMapExtensions() {
        #expect(UTType.swiftSource.conforms(to: .sourceCode) && UTType.swiftSource.conforms(to: .text))
        #expect(UTType.swiftSource.conforms(to: .data) && UTType.swiftSource.conforms(to: .item))
        #expect(!UTType.png.conforms(to: .text))
        #expect(UTType.folder.conforms(to: .directory))
        #expect(UTType(filenameExtension: "swift") == .swiftSource)
        #expect(UTType(filenameExtension: "JPG") == .jpeg)
        #expect(UTType("public.json") == .json)
        #expect(projectType.conforms(to: .package) && projectType.conforms(to: .directory))
        #expect(projectType.preferredFilenameExtension == "xcodeproj")
        #expect(UTType(filenameExtension: "") == nil)
    }

    @Test func thePanelModelListsAndChooses() throws {
        let root = try makeDialogFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let m = FilePanelModel(mode: .open(types: [.swiftSource, projectType], multiple: false), start: root)
        #expect(m.entries.map(\.name) == ["A.swift", "Demo.xcodeproj", "notes.txt", "Sub"])
        #expect(m.entries.map(\.isAllowed) == [true, true, false, false])
        #expect(m.entries.map(\.isFolder) == [false, false, false, true])
        #expect(m.choice == nil)                      // nothing selected, folders not allowed
        m.selection = [root.appendingPathComponent("notes.txt")]
        #expect(!m.canConfirm)
        m.selection = [root.appendingPathComponent("Sub")]
        #expect(m.confirmEntersFolder)
        #expect(m.confirm() == nil)
        #expect(m.folder.lastPathComponent == "Sub" && m.entries.map(\.name) == ["B.swift"])
        m.goUp()
        #expect(m.folder.path == FilePanelModel.normalized(root).path)
        m.goTo = root.appendingPathComponent("Demo.xcodeproj").path
        #expect(m.goToPath()?.map(\.lastPathComponent) == ["Demo.xcodeproj"])
        m.goTo = "Sub"
        #expect(m.goToPath() == nil && m.folder.lastPathComponent == "Sub")
        m.goTo = "/does/not/exist"
        #expect(m.goToPath() == nil && m.error != nil)
        // A folder importer chooses the shown folder with nothing selected.
        let f = FilePanelModel(mode: .open(types: [.folder], multiple: false), start: root)
        #expect(f.choice?.map(\.path) == [FilePanelModel.normalized(root).path])
        #expect(f.entries.first { $0.name == "Sub" }?.isAllowed == true)
    }

    @Test func theImporterOpensInTheWindowAndReportsTheChoice() throws {
        let root = try makeDialogFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DialogLog()
        let h = CommandsHarness(menuBar: false) { ImporterView(folder: root, log: log) }
        h.run(until: 1.0)
        #expect(h.textFrame("A.swift") != nil && h.textFrame("Sub") != nil)
        #expect(h.textFrame(".hidden") == nil)
        // A double click opens a folder.
        guard let sub = h.textFrame("Sub") else { return }
        h.click(CGPoint(x: sub.midX, y: sub.midY), at: 1.2)
        h.click(CGPoint(x: sub.midX, y: sub.midY), at: 1.3)
        h.run(until: 1.5)
        #expect(h.textFrame("B.swift") != nil)
        h.click(identified: "file dialog up", at: 1.7)
        h.run(until: 1.9)
        // A click selects, the confirm button chooses.
        guard let a = h.textFrame("A.swift") else { Issue.record("A.swift"); return }
        h.click(CGPoint(x: a.midX, y: a.midY), at: 2.0)
        // At once (a double click waiting on the row does not hold the press).
        h.click(identified: "file dialog confirm", at: 2.2)
        h.run(until: 3.0)
        #expect(log.results == ["A.swift"])
        #expect(h.textFrame("A.swift") == nil)       // dismissed
    }

    @Test func theImporterCancelsWithEscape() throws {
        let root = try makeDialogFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DialogLog()
        let h = CommandsHarness(menuBar: false) { ImporterView(folder: root, log: log) }
        h.run(until: 1.0)
        h.key(.escape, at: 1.1)
        h.run(until: 2.0)
        #expect(log.results.isEmpty)
        #expect(h.textFrame("A.swift") == nil)
    }

    @Test func theExporterWritesTheDocumentAndAsksBeforeReplacing() throws {
        let root = try makeDialogFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DialogLog()
        let h = CommandsHarness(menuBar: false) { ExporterView(folder: root, log: log) }
        h.run(until: 1.0)
        h.click(identified: "file dialog confirm", at: 1.1)
        h.run(until: 2.0)
        #expect(log.results == ["Summary.txt"])
        #expect((try? String(contentsOf: root.appendingPathComponent("Summary.txt"), encoding: .utf8)) == "hello")
        // Saving over notes.txt asks first.
        let m = FilePanelModel(mode: .save(type: .plainText, defaultName: "notes", write: { _ in }), start: root)
        #expect(m.name == "notes.txt")
        #expect(m.confirm() == nil && m.confirmReplace?.lastPathComponent == "notes.txt")
        #expect(m.confirm()?.map(\.lastPathComponent) == ["notes.txt"])
    }
}
