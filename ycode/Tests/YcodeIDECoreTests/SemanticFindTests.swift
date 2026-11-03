import Foundation
import Testing
import YcodeDebug
@testable import YcodeIDECore
@testable import YcodeLanguage

/// The semantic find kinds against a stand-in language server: symbol
/// definitions and references, callers, ancestor, descendent and
/// conforming types (specs/ide/navigators.md §Find navigator, "Ycode
/// implementation"). `SourceKitLSPFindTests` runs them on sourcekit-lsp.
@Suite struct SemanticFindTests {
    struct Stub: SemanticFindService {
        static let a = URL(fileURLWithPath: "/w/A.swift"), b = URL(fileURLWithPath: "/w/B.swift")
        static func p(_ l: Int, _ c: Int = 0) -> Position { Position(line: l, character: c) }
        static func loc(_ u: URL, _ l: Int, _ c: Int = 0) -> Location { Location(url: u, start: p(l, c), end: p(l, c + 1)) }

        var unsupported = false

        func workspaceSymbols(_ query: String) async throws -> [WorkspaceSymbol] {
            [WorkspaceSymbol(name: "Shape", kind: 11, location: Self.loc(Self.a, 0)),
             WorkspaceSymbol(name: "Base", kind: 5, location: Self.loc(Self.a, 2)),
             WorkspaceSymbol(name: "Square", kind: 5, containerName: nil, location: Self.loc(Self.b, 0)),
             WorkspaceSymbol(name: "area()", kind: 6, containerName: "Square", location: Self.loc(Self.b, 1)),
             WorkspaceSymbol(name: "areaOfAll(_:)", kind: 12, location: Self.loc(Self.b, 4)),
             WorkspaceSymbol(name: "Shaped", kind: 11, location: Self.loc(Self.a, 6))]
        }

        func references(_ url: URL, at p: Position) async throws -> [Location] {
            // The call in B line 5 is reported twice; it is listed once.
            [Self.loc(Self.b, 1, 9), Self.loc(Self.b, 5, 4), Self.loc(Self.a, 9, 2), Self.loc(Self.b, 5, 4)]
        }

        func item(_ name: String, _ u: URL, _ l: Int) -> CallHierarchyItem { CallHierarchyItem(name: name, url: u, selection: Self.p(l)) }
        func prepareCallHierarchy(_ url: URL, at p: Position) async throws -> [CallHierarchyItem] { [item("area()", url, p.line)] }
        func incomingCalls(_ i: CallHierarchyItem) async throws -> [(caller: CallHierarchyItem, ranges: [Position])] {
            switch i.name {
            case "area()": [(item("areaOfAll(_:)", Self.b, 4), [Self.p(5)]), (item("main", Self.a, 9), [Self.p(9)])]
            case "areaOfAll(_:)": [(item("report()", Self.a, 12), [Self.p(13)])]
            case "report()": [(item("deep()", Self.a, 20), [])]
            default: []
            }
        }

        func type(_ n: String, _ k: Int, _ u: URL, _ l: Int) -> TypeHierarchyItem { TypeHierarchyItem(name: n, kind: k, url: u, selection: Self.p(l)) }
        func prepareTypeHierarchy(_ url: URL, at p: Position) async throws -> [TypeHierarchyItem] {
            if unsupported { throw LSPClient.ResponseError(method: "textDocument/prepareTypeHierarchy", code: -32601, message: "Unknown method") }
            switch (url, p.line) {
            case (Self.a, 0): return [type("Shape", 11, Self.a, 0)]
            case (Self.a, 2): return [type("Base", 5, Self.a, 2)]
            default: return [type("Square", 5, Self.b, 0)]
            }
        }
        func supertypes(_ i: TypeHierarchyItem) async throws -> [TypeHierarchyItem] {
            switch i.name {
            case "Square": [type("Base", 5, Self.a, 2), type("Shape", 11, Self.a, 0)]
            case "Base": [type("Shape", 11, Self.a, 0)]
            default: []
            }
        }
        func subtypes(_ i: TypeHierarchyItem) async throws -> [TypeHierarchyItem] {
            switch i.name {
            case "Shape": [type("Base", 5, Self.a, 2), type("Shaped", 11, Self.a, 6), type("Square", 5, Self.b, 0)]
            case "Base": [type("Square", 5, Self.b, 0)]
            default: []
            }
        }
    }

    static let lines: SemanticFind.LineReader = { path, line in
        if path.hasSuffix("B.swift") && line == 1 { return "    func area() -> Int { 1 }" }
        return "line \(line)"
    }

    @Test func definitionsByNameAndMatchStyle() async {
        let r = await SemanticFind.run(FindQuery("shape", kind: .symbols), service: Stub(), lines: Self.lines)
        #expect(r.heading == "shape — 2 definitions" && r.count == 2)
        #expect(r.nodes.map(\.title) == ["A.swift"] && r.nodes[0].children.map(\.title) == ["Shape", "Shaped"])
        #expect(r.nodes[0].children.map(\.line) == [1, 7] && r.nodes[0].children[0].symbolKind == 11)
        let exact = await SemanticFind.run(FindQuery("Shape", kind: .symbols, match: .matchingWord, ignoreCase: false), service: Stub(), lines: Self.lines)
        #expect(exact.count == 1)
        #expect(await SemanticFind.run(FindQuery("Nope", kind: .symbols), service: Stub()).message == "No symbol named \u{201C}Nope\u{201D}")
        #expect(await SemanticFind.run(FindQuery("x", kind: .symbols), service: nil).message == "No language server")
        #expect(SemanticFind.nameMatches("area()", FindQuery("area", match: .matchingWord)))
        #expect(SemanticFind.nameMatches("areaOfAll(_:)", FindQuery("all", match: .endingWith)))
        #expect(!SemanticFind.nameMatches("areaOfAll(_:)", FindQuery("all", match: .endingWith, ignoreCase: false)))
    }

    @Test func referencesMergeByFileAndLine() async {
        let r = await SemanticFind.run(FindQuery("area", kind: .symbols, match: .matchingWord, symbolRole: .references), service: Stub(), lines: Self.lines)
        #expect(r.heading == "area — 3 references" && r.count == 3)
        #expect(r.nodes.map(\.title) == ["A.swift", "B.swift"] && r.nodes.map(\.detail) == ["(1)", "(2)"])
        #expect(r.nodes[1].children.map(\.title) == ["2: func area() -> Int { 1 }", "6: line 5"] && r.nodes[1].children.map(\.line) == [2, 6])
        // The seed's position is moved onto the name in its line.
        #expect(SemanticFind.namePosition("area()", at: Position(line: 1, character: 0), path: "/w/B.swift", lines: Self.lines)
                == Position(line: 1, character: 9))
    }

    @Test func callersTwoLevelsDeep() async {
        let r = await SemanticFind.run(FindQuery("area", kind: .callHierarchy, match: .matchingWord), service: Stub(), lines: Self.lines)
        #expect(r.heading == "Callers of area()" && r.count == 2)
        let titles = r.nodes.flatMap(\.flattened).map(\.title)
        #expect(titles == ["area()", "areaOfAll(_:)", "report()", "main"])
        // From the caret, the same tree.
        let seed = SemanticFind.Seed(url: Stub.b, position: Position(line: 1, character: 9), name: "area()")
        #expect(await SemanticFind.run(.callHierarchy, at: seed, service: Stub()).nodes == r.nodes)
    }

    @Test func ancestorDescendentAndConformingTypes() async {
        let up = await SemanticFind.run(FindQuery("Square", kind: .ancestorTypes, match: .matchingWord), service: Stub())
        #expect(up.heading == "Ancestor types of Square" && up.nodes[0].flattened.map(\.title) == ["Square", "Base", "Shape"] && up.count == 2)
        let down = await SemanticFind.run(FindQuery("Base", kind: .descendentTypes, match: .matchingWord), service: Stub())
        #expect(down.nodes[0].flattened.map(\.title) == ["Base", "Square"])
        // A protocol's descendants are the protocols refining it; its conforming types the others.
        let refining = await SemanticFind.run(FindQuery("Shape", kind: .descendentTypes, match: .matchingWord, ignoreCase: false), service: Stub())
        #expect(refining.nodes[0].flattened.map(\.title) == ["Shape", "Shaped"])
        let conforming = await SemanticFind.run(FindQuery("Shape", kind: .conformingTypes, match: .matchingWord, ignoreCase: false), service: Stub())
        #expect(conforming.heading == "Types conforming to Shape" && conforming.nodes[0].flattened.map(\.title) == ["Shape", "Base", "Square"])
        // Conforming Types looks up protocols only.
        #expect(await SemanticFind.run(FindQuery("Base", kind: .conformingTypes, match: .matchingWord), service: Stub()).message != nil)
        // A server without type hierarchy says so.
        let none = await SemanticFind.run(FindQuery("Square", kind: .ancestorTypes, match: .matchingWord), service: Stub(unsupported: true))
        #expect(none.message == "The language server does not support ancestor types")
    }
}
