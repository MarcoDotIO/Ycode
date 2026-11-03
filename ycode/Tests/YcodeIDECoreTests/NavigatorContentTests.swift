import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore

@Suite struct IndexTests {
    @Test func searchFindsEveryMatchWithLines() {
        let m = WorkspaceSearch.search("greet", inText: "struct Greeter {\n    func greet() {}\n}\nlet g = Greeter()\n")
        #expect(m.map(\.line) == [1, 2, 4])
        #expect(m[1].text == "func greet() {}")
        #expect(m[0].range == NSRange(location: 7, length: 5))
    }

    @Test func swiftTopLevelSymbols() {
        let text = """
        /// struct NotThis {}
        import Foundation
        public struct Point { var x: Int; func length() -> Int { 0 } }
        final class Box<T> {
            class func make() -> Box { Box() }
            struct Inner {}
        }
        enum Kind { case a }
        protocol P {}
        extension Point: P {}
        actor Counter {}
        typealias Pair = (Int, Int)
        func main() { let s = "func fake()" }
        """
        let s = SymbolScanner.symbols(in: text, language: .swift)
        #expect(s.map(\.name) == ["Point", "Box", "Kind", "P", "Point", "Counter", "Pair", "main"])
        #expect(s.map(\.kind) == [.struct, .class, .enum, .protocol, .extension, .actor, .typealias, .function])
        #expect(s.last?.line == 13)
    }

    @Test func cAndObjCSymbols() {
        let c = "#define X(a) (a)\nstruct Pair { int a; };\nstatic int add(int a, int b) {\n  if (a) { return add(a, b); }\n  return a;\n}\nint proto(void);\n"
        #expect(SymbolScanner.symbols(in: c, language: .c).map(\.name) == ["Pair", "add"])
        let m = "@interface Foo : NSObject\n- (void)x;\n@end\n@implementation Foo\n- (void)x {}\n@end\n"
        #expect(SymbolScanner.symbols(in: m, language: .objc).map(\.kind) == [.interface, .implementation])
    }
}
