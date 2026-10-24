import XCTest
@testable import YcodeUI

/// Round 28 audit of specs/ide/previews.md §Discovery.
final class PreviewsAuditTests: XCTestCase {
    func testProviderInCommentOrStringIsIgnored() {
        let text = """
        // struct Old: PreviewProvider { }
        /* struct Older: PreviewProvider { } */
        let s = "struct Fake: PreviewProvider"
        struct Real_Previews: PreviewProvider {
            static var previews: some View { Text("x") }
        }
        """
        let p = PreviewDiscovery.previews(in: text)
        XCTAssertEqual(p.map(\.name), ["Real_Previews"])
        XCTAssertEqual(p.first?.line, 4)
    }

    func testEscapedQuoteInPreviewName() {
        let p = PreviewDiscovery.previews(in: "#Preview(\"Say \\\"hi\\\"\") { Text(\"a\") }\n#Preview { Text(\"b\") }\n#Preview { Text(\"c\") }")
        XCTAssertEqual(p.map(\.name), ["Say \"hi\"", "Preview", "Preview 2"])
    }

    func testNameOnlyWhenFirstArgument() {
        let p = PreviewDiscovery.previews(in: "#Preview(traits: .fixedLayout(width: 200, height: 100)) { Text(\"a\") }")
        XCTAssertEqual(p.first?.name, "Preview")
        XCTAssertEqual(p.first?.fixedSize, CGSize(width: 200, height: 100))
    }

    func testCodeOnlyKeepsLength() {
        let t = "a // c\n\"s\" b"
        XCTAssertEqual(PreviewDiscovery.codeOnly(t).utf16.count, t.utf16.count)
        XCTAssertEqual(PreviewDiscovery.codeOnly(t), "a     \n    b")
    }
}
