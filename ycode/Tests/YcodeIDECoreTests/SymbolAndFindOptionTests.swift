import Foundation
import Testing
@testable import YcodeIDECore

@Suite struct NestedSymbolTests {
    @Test func membersNestUnderTheirTypes() {
        let text = """
        struct Point {
            var x: Int
            let y: Int
            init(x: Int) { self.x = x; let local = 1; _ = local; self.y = 0 }
            func length() -> Int {
                struct Hidden {}
                return 0
            }
            enum Axis { case horizontal, vertical; case depth }
        }
        extension Point {
            static func zero() -> Point { Point(x: 0) }
            var isZero: Bool { x == 0 }
        }
        func free() {}
        """
        let s = SymbolScanner.symbols(in: text, language: .swift)
        #expect(s.map(\.name) == ["Point", "Point", "free"])
        let point = s[0]
        #expect(point.children.map(\.name) == ["x", "y", "init", "length", "Axis"])
        #expect(point.children.map(\.kind) == [.property, .property, .initializer, .function, .enum])
        #expect(point.children[4].children.map(\.name) == ["horizontal", "depth"])
        #expect(point.children[4].children.map(\.line) == [9, 9])
        #expect(s[1].kind == .extension && s[1].children.map(\.name) == ["zero", "isZero"])
        #expect(s[2].children.isEmpty)
    }
}

@Suite struct FindOptionTests {
    let text = "let greet = 1\nfunc greeting() {}\nGreet()\n// a.b and axb\n"

    @Test func ignoreCaseWholeWordRegex() {
        #expect(WorkspaceSearch.search("greet", inText: text).map(\.line) == [1, 2, 3])
        #expect(WorkspaceSearch.search("greet", inText: text, options: .init(ignoreCase: false)).map(\.line) == [1, 2])
        #expect(WorkspaceSearch.search("greet", inText: text, options: .init(wholeWord: true)).map(\.line) == [1, 3])
        #expect(WorkspaceSearch.search("greet", inText: text, options: .init(wholeWord: true, ignoreCase: false)).map(\.line) == [1])
        // Text mode escapes metacharacters; regex mode does not.
        #expect(WorkspaceSearch.search("a.b", inText: text).count == 1)
        #expect(WorkspaceSearch.search("a.b", inText: text, options: .init(regularExpression: true)).count == 2)
        #expect(WorkspaceSearch.search("gree(t|ting)\\(", inText: text, options: .init(regularExpression: true)).map(\.line) == [2, 3])
        // An invalid expression finds nothing instead of failing.
        #expect(WorkspaceSearch.search("(", inText: text, options: .init(regularExpression: true)).isEmpty)
        #expect(WorkspaceSearch.search("^", inText: text, options: .init(regularExpression: true)).isEmpty)
    }
}
