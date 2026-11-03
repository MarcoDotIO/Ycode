import Foundation
import Testing
import YcodePlist
@testable import YcodeIDECore

@MainActor
@Suite(.serialized) struct PlistEditorTests {
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
