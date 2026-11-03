import Foundation
import Testing
@testable import YcodeIDECore

@MainActor
@Suite(.serialized) struct EditorAreaTests {
    @Test func historyModel() {
        var h = NavigationHistory()
        h.visit("a"); h.visit("b"); h.visit("b"); h.visit("c")
        #expect(h.items == ["a", "b", "c"])
        #expect(h.back() == "b" && h.back() == "a" && h.back() == nil)
        #expect(h.forward() == "b")
        h.visit("d")
        #expect(h.items == ["a", "b", "d"] && !h.canGoForward)
    }

    @Test func counterpartRules() {
        let files = ["/p/A/Foo.h", "/p/A/Foo.m", "/p/B/Foo.c", "/p/App/View.swift", "/p/Tests/ViewTests.swift",
                     "/p/App/Main.storyboard", "/p/App/Other.swift"]
        let docs = ["/p/App/Main.storyboard": "<viewController customClass=\"View\" id=\"a\"/>"]
        let read = { (p: String) in docs[p] }
        #expect(Counterparts.of("/p/A/Foo.h", in: files, readFile: read) == ["/p/A/Foo.m", "/p/B/Foo.c"])
        #expect(Counterparts.of("/p/A/Foo.m", in: files, readFile: read) == ["/p/A/Foo.h"])
        #expect(Counterparts.of("/p/App/View.swift", in: files, readFile: read) == ["/p/Tests/ViewTests.swift", "/p/App/Main.storyboard"])
        #expect(Counterparts.of("/p/Tests/ViewTests.swift", in: files, readFile: read) == ["/p/App/View.swift"])
        #expect(Counterparts.of("/p/App/Main.storyboard", in: files, readFile: read) == ["/p/App/View.swift"])
        #expect(Counterparts.of("/p/App/Other.swift", in: files, readFile: read).isEmpty)
    }

    @Test func assistantModeRules() {
        let files = ["/p/a.c", "/p/a.h", "/p/util.h", "/p/Model.swift", "/p/ModelTests.swift", "/p/OtherTests.swift", "/p/Main.storyboard", "/p/VC.swift"]
        let texts = ["/p/a.c": "#include \"a.h\"\n#include \"util.h\"\n#include <stdio.h>\n",
                     "/p/Model.swift": "import Foundation\nstruct Thing {}\n",
                     "/p/OtherTests.swift": "let t = Thing()\n", "/p/ModelTests.swift": "// none\n",
                     "/p/Main.storyboard": "<document><scenes><scene sceneID=\"s\"><objects><viewController id=\"v\" customClass=\"VC\"/></objects></scene></scenes></document>"]
        let read = { (p: String) in texts[p] }
        #expect(AssistantMode.available(for: "/p/a.c") == [.counterparts, .manual, .includes, .tests])
        #expect(AssistantMode.available(for: "/p/Main.storyboard") == [.counterparts, .manual, .topLevelObjects])
        #expect(AssistantMode.includes.files(for: "/p/a.c", in: files, readFile: read) == ["/p/a.h", "/p/util.h"])
        #expect(AssistantMode.tests.files(for: "/p/Model.swift", in: files, readFile: read) == ["/p/ModelTests.swift", "/p/OtherTests.swift"])
        #expect(AssistantMode.topLevelObjects.files(for: "/p/Main.storyboard", in: files, readFile: read) == ["/p/VC.swift"])
        #expect(AssistantMode.manual.files(for: "/p/a.c", in: files, readFile: read).isEmpty)
    }
}
