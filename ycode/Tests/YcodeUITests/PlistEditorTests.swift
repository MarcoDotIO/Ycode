import AppKit
import Foundation
import Testing
import YcodePlist
@testable import YcodeUI

@MainActor
@Suite(.serialized) struct PlistEditorTests {
    @Test func editsWriteTheFile() throws {
        _ = NSApplication.shared
        let dir = try WindowSnapshotTests().samplePackage()
        let file = dir.appendingPathComponent("Sources/Sample/Info.plist")
        let original: [String: Any] = ["CFBundleName": "Sample", "Count": 2, "Flags": ["a", "b"] as [Any]]
        try PropertyListSerialization.data(fromPropertyList: original, format: .xml, options: 0).write(to: file)
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        wc.open(path: file.path, line: nil)
        let pe = try #require(wc.plistEditor)
        #expect(wc.editor.auxiliary === pe.view)
        // Root row plus three keys plus two array items.
        #expect(pe.outline.numberOfRows == 6)
        func reread() throws -> NSDictionary { try #require(NSDictionary(contentsOf: file)) }

        // Keys are in file order (Foundation sorted them): CFBundleName, Count, Flags.
        pe.setKey("CFBundleDisplayName", at: [0])
        #expect(try reread()["CFBundleDisplayName"] as? String == "Sample")
        #expect(pe.setValueText("7", at: [1]))
        #expect((try reread()["Count"] as? Int) == 7)
        #expect(!pe.setValueText("seven", at: [1])) // not a number: refused
        pe.setType("Boolean", at: [1])
        #expect(try reread()["Count"] as? Bool == true)
        let new = pe.insert(after: [1])
        #expect(new == [2])
        pe.setKey("Version", at: new)
        pe.setValueText("1.0", at: new)
        #expect(try reread()["Version"] as? String == "1.0")
        pe.insert(after: [3], asChild: true) // into Flags
        #expect((try reread()["Flags"] as? [String]) == ["", "a", "b"])
        pe.remove(at: [3, 0])
        #expect((try reread()["Flags"] as? [String]) == ["a", "b"])
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "plist-editor.png")

        // The written file is our XML layout with keys in editing order.
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(try PropertyListDocument(data: Data(text.utf8)).xml() == text)
        guard case .dictionary(let d) = try PropertyListDocument(data: Data(text.utf8)).root else { return }
        #expect(d.map(\.key) == ["CFBundleDisplayName", "Count", "Version", "Flags"])
    }

    /// reference-ui-5.md §11.2 (P8): a binary list shows and keeps its key order.
    @Test func binaryListKeepsKeyOrder() throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-bplist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Settings.plist")
        let doc = PropertyListDocument(root: .dictionary([.init(key: "Zebra", value: .string("z")), .init(key: "Apple", value: .integer(1)),
                                                          .init(key: "Mango", value: .bool(true))]), format: .binary)
        try doc.data().write(to: file)
        let pe = try PlistEditorController(url: file)
        _ = pe.view
        #expect(PlistTree.children(of: pe.tree.root).map(\.key) == ["Zebra", "Apple", "Mango"])
        #expect(pe.setValueText("2", at: [1]))
        let written = try Data(contentsOf: file)
        #expect(written.starts(with: Array("bplist00".utf8)))
        guard case .dictionary(let d) = try PropertyListDocument(data: written).root else { Issue.record("not a dict"); return }
        #expect(d.map(\.key) == ["Zebra", "Apple", "Mango"] && d[1].value == .integer(2))
    }

    @Test func treeOperations() {
        var t = PlistTree(root: .dictionary([PropertyListEntry(key: "a", value: .string("x"))]))
        #expect(t.insert(after: [0]) == [1])
        #expect(t.insert(after: [0]) == [1]) // second new key gets a distinct name
        #expect(PlistTree.children(of: t.root).map(\.key) == ["a", "New item - 2", "New item"])
        t.setKey("a", at: [1]) // duplicate key refused
        #expect(PlistTree.children(of: t.root)[1].key == "New item - 2")
        #expect(PlistTree.parse("<00ff>", as: "Data") == .data(Data([0, 255])))
        #expect(PlistTree.parse("NO", as: "Boolean") == .bool(false))
        #expect(PlistTree.parse("2.5", as: "Number") == .real(2.5))
    }
}
