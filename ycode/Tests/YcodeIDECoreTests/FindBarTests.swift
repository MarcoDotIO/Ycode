import Foundation
import Testing
@testable import YcodeIDECore

@Suite struct EditorFindTests {
    @Test func matchesStepsAndReplaces() {
        var f = EditorFind()
        f.query = "ab"
        f.update(text: "ab xab AB", from: 2)
        #expect(f.matches == [NSRange(location: 0, length: 2), NSRange(location: 4, length: 2), NSRange(location: 7, length: 2)])
        #expect(f.current == 1) // first match at or after the caret
        f.step(true); f.step(true)
        #expect(f.current == 0) // wraps
        f.step(false)
        #expect(f.current == 2)
        f.options.wholeWord = true
        f.update(text: "ab xab AB")
        #expect(f.matches.count == 2)
        f.options = .init(regularExpression: true, ignoreCase: false)
        f.query = "(\\w)b"
        f.replacement = "<$1>"
        f.update(text: "ab xab AB")
        #expect(f.replacingAll(in: "ab xab AB").0 == "<a> x<a> AB")
        #expect(f.replacementText(in: "ab xab AB", range: NSRange(location: 4, length: 2)) == "<a>")
        // Text mode treats `$` literally in the replacement.
        var t = EditorFind()
        t.query = "a"
        t.replacement = "$1"
        #expect(t.replacingAll(in: "aa").0 == "$1$1")
    }
}
