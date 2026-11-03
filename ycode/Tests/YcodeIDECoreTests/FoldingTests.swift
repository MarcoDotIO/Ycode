import Foundation
import Testing
@testable import YcodeIDECore

@Suite struct FoldRegionTests {
    @Test func braceRegions() {
        let text = "struct A {\n  func f() {\n    let s = \"{\"\n    // }\n  }\n  var x = 1\n}\nlet y = { 1 }\n"
        let r = FoldRegions.regions(in: text, language: .swift)
        #expect(r == [FoldRegion(startLine: 1, endLine: 7, depth: 0), FoldRegion(startLine: 2, endLine: 5, depth: 1)])
        #expect(r[0].hiddenLines == 2...6)
        #expect(FoldRegions.innermost(r, containing: 3) == r[1])
        #expect(FoldRegions.innermost(r, containing: 6) == r[0])
        #expect(FoldRegions.regions(in: "x", language: .plain).isEmpty)
    }
}
