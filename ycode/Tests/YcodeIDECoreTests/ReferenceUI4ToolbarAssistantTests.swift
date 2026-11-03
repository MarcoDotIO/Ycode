import Foundation
import Testing
@testable import YcodeIDECore

/// reference-ui-4.md §14 (toolbar right group, editor options) and §16 (assistant modes).
@MainActor
@Suite(.serialized) struct ReferenceUI4ToolbarAssistantTests {
    @Test func catalogOrderAndEnablement() {
        #expect(AssistantModeCatalog.titles.prefix(19) == ["Counterparts", "Superclasses", "Subclasses", "Siblings", "Extensions", "Categories",
            "Protocols", "User Interfaces", "Includes", "Included By", "Callers", "Callees", "Test Classes", "Test Callers",
            "Preprocess", "Assembly", "Disassembly", "Generated Interface", "Documentation Preview"])
        let swift = AssistantModeCatalog.enabled(for: "/p/A.swift", hasLanguageService: true)
        #expect(swift.isSuperset(of: ["Counterparts", "Callers", "Callees", "Generated Interface", "Documentation Preview", "Extensions"]))
        #expect(!swift.contains("Disassembly") && !swift.contains("Superclasses"))
        #expect(!AssistantModeCatalog.enabled(for: "/p/A.swift", hasLanguageService: false).contains("Callers"))
        #expect(AssistantModeCatalog.enabled(for: "/p/a.h", hasLanguageService: false).contains("Included By"))
    }

    @Test func fileModes() {
        let texts = ["/p/a.c": "#include \"a.h\"\n", "/p/a.h": "int a(void);\n", "/p/b.m": "#import \"a.h\"\n",
                     "/p/Model.swift": "struct Model {}\n", "/p/Model+X.swift": "extension Model {\n}\n", "/p/Other.swift": "extension Other {}\n",
                     "/p/Main.storyboard": "<document><objects><viewController customClass=\"Model\"/></objects></document>"]
        let files = Array(texts.keys)
        let read = { (p: String) in texts[p] }
        #expect(AssistantModeCatalog.includedBy("/p/a.h", in: files, readFile: read) == ["/p/a.c", "/p/b.m"])
        #expect(AssistantModeCatalog.extensions(of: "/p/Model.swift", in: files, readFile: read) == ["/p/Model+X.swift"])
        #expect(AssistantModeCatalog.userInterfaces(of: "/p/Model.swift", in: files, readFile: read) == ["/p/Main.storyboard"])
    }

    @Test func generatedInterfaceAndDocumentationPreview() {
        let src = """
        import Foundation

        /// A shape.
        public struct Circle {
            /// The radius.
            public var radius: Double = 1
            private var cache = 0

            /// Area.
            /// - Returns: The area.
            public func area() -> Double {
                let r = radius
                return r * r * .pi
            }
        }
        """
        let i = AssistantModeCatalog.generatedInterface(src)
        #expect(i == """
        import Foundation
        /// A shape.
        public struct Circle {
            /// The radius.
            public var radius: Double
            /// Area.
            /// - Returns: The area.
            public func area() -> Double
        }
        """)
        let d = AssistantModeCatalog.documentationPreview(src)
        #expect(d.contains("Circle\n======\nA shape."))
        #expect(d.contains("Return Value\n  The area."))
    }
}
