import Foundation
import Testing
import YcodeLanguage
@testable import YcodeIDECore

@MainActor
@Suite(.serialized) struct PlaceholderTests {
    @Test func scanning() {
        let t = "a(<#x#>, <#y: Int#>) <##> <#bad\nline#> <#z#>"
        let r = Placeholders.ranges(in: t)
        #expect(r.map { (t as NSString).substring(with: $0) } == ["<#x#>", "<#y: Int#>", "<#z#>"])
        #expect(Placeholders.text(of: r[1], in: t) == "y: Int")
        #expect(Placeholders.token(containing: 4, in: t) == r[0])
        #expect(Placeholders.token(containing: 2, in: t) == nil)
        #expect(Placeholders.next(from: NSRange(location: 0, length: 0), in: t) == r[0])
        #expect(Placeholders.next(from: r[0], in: t) == r[1])
        #expect(Placeholders.next(from: r[2], in: t) == r[0]) // wraps
        #expect(Placeholders.next(from: r[1], in: t, backward: true) == r[0])
        #expect(Placeholders.next(from: r[0], in: t, backward: true) == r[2])
    }

    @Test func lspSnippets() {
        #expect(Placeholders.fromLSPSnippet("greet(times: ${1:Int})") == "greet(times: <#Int#>)")
        #expect(Placeholders.fromLSPSnippet("f(${1:a}, ${2:b})$0") == "f(<#a#>, <#b#>)")
        #expect(Placeholders.fromLSPSnippet("g($1) \\$x ${3}") == "g(<#value#>) $x <#value#>")
        #expect(Placeholders.fromLSPSnippet("plain") == "plain")
    }
}
