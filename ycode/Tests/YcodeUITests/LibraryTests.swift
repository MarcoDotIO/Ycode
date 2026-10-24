import AppKit
import Foundation
import Testing
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@MainActor
@Suite(.serialized) struct LibraryTests {
    @Test func contentIsOwnAndUsable() {
        let forbidden = ["swift", "applelogo", "hammer", "hammer.fill", "xcode", "applewatch", "visionpro", "iphone", "ipad"]
        #expect(LibraryContent.symbolNames.allSatisfy { name in !forbidden.contains { name == $0 || name.hasPrefix($0 + ".") } })
        #expect(Set(LibraryContent.symbolNames).count == LibraryContent.symbolNames.count)
        #expect(LibraryController.availableSymbols.count > 150)
        #expect(Set(LibraryContent.snippets.map(\.title)).count == LibraryContent.snippets.count)
        #expect(LibraryContent.snippets.allSatisfy { $0.body.contains("<#") && $0.body.contains("#>") })
    }

    @Test func filterInsertAndDrag() throws {
        _ = NSApplication.shared
        let dir = ycodeDir.appendingPathComponent(".build-ide/library")
        try? FileManager.default.removeItem(at: dir)
        let src = dir.appendingPathComponent("Sources/Lib")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Lib\", targets: [.target(name: \"Lib\")])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let file = src.appendingPathComponent("Lib.swift")
        try "func f(x: Int?) {\n    \n}\n".write(to: file, atomically: true, encoding: .utf8)
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        wc.open(path: file.path, line: nil)

        let lib = wc.showLibrary(nil)
        _ = lib.view
        lib.filter = "guard"
        #expect(lib.snippets.map(\.title) == ["Guard Let", "C Include Guard"])
        wc.editor.textView.setSelectedRange(NSRange(location: 22, length: 0))
        #expect(lib.insert(row: 0))
        #expect(wc.editor.textView.string == "func f(x: Int?) {\n    guard let <#name#> = <#optional#> else {\n    <#return#>\n}\n}\n")
        let sel = wc.editor.textView.selectedRange()
        #expect((wc.editor.textView.string as NSString).substring(with: sel) == "<#name#>")

        lib.select(tab: .symbols)
        lib.filter = "star"
        #expect(lib.symbols.contains("star.fill") && lib.symbols.allSatisfy { $0.contains("star") })
        let i = try #require(lib.symbols.firstIndex(of: "star.fill"))
        #expect(lib.insertionText(row: i) == "\"star.fill\"")
        let writer = lib.tableView(lib.table, pasteboardWriterForRow: i) as? NSString
        #expect(writer == "\"star.fill\"")
        wc.editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(lib.insert(row: i))
        #expect(wc.editor.textView.string.hasPrefix("\"star.fill\"func f"))

        lib.filter = ""
        lib.select(tab: .snippets)
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .aqua)
        panel.contentViewController = lib
        panel.setContentSize(NSSize(width: 420, height: 520))
        lib.table.selectRowIndexes([0], byExtendingSelection: false)
        panel.layoutIfNeeded()
        _ = try WindowSnapshotTests().render(panel.contentView!, to: "library-snippets.png")
        lib.select(tab: .symbols)
        panel.layoutIfNeeded()
        _ = try WindowSnapshotTests().render(panel.contentView!, to: "library-symbols.png")
    }
}
