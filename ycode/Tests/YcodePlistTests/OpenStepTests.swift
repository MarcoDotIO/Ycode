import Testing
@testable import YcodePlist

@Suite struct OpenStepParserTests {
    @Test func parsesNestedStructures() throws {
        let v = try OpenStepParser.parse("""
            // !$*UTF8*$!
            {
                name = Ycode; /* trailing comment */
                list = (a, "b c", (nested), );
                empty = ();
                dict = { k = v; };
                blob = <deadBEEF 00>;
            }
            """)
        let d = try #require(v.dictionary)
        #expect(d.keys == ["name", "list", "empty", "dict", "blob"])
        #expect(d["name"] == "Ycode")
        #expect(d["list"] == ["a", "b c", ["nested"]])
        #expect(d["empty"] == .array([]))
        #expect(d["dict"] == ["k": "v"])
        #expect(d["blob"] == .data([0xDE, 0xAD, 0xBE, 0xEF, 0x00]))
    }

    @Test func decodesEscapes() throws {
        let v = try OpenStepParser.parse(#""tab\there\nquote\" back\\ \U00e9 \101 \'""#)
        #expect(v == .string("tab\there\nquote\" back\\ é A '"))
    }

    @Test func decodesSurrogatePairEscapes() throws {
        #expect(try OpenStepParser.parse(#""\UD83D\UDE00""#) == .string("😀"))
    }

    @Test func keepsRawUTF8() throws {
        #expect(try OpenStepParser.parse("\"naïve 日本\"") == .string("naïve 日本"))
    }

    @Test func unquotedStringCharacterSet() throws {
        #expect(try OpenStepParser.parse("a-b+c/d:e.f_$1") == .string("a-b+c/d:e.f_$1"))
    }

    @Test(arguments: ["{ a = b }", "(a b)", "\"open", "{ a = b; } extra", "<abc>", "/* never closed"])
    func rejectsMalformedInput(_ text: String) {
        #expect(throws: OpenStepParser.Error.self) { try OpenStepParser.parse(text) }
    }

    @Test func reportsLineNumbers() {
        do {
            _ = try OpenStepParser.parse("{\n a = b;\n c = ;\n}")
            Issue.record("expected failure")
        } catch {
            #expect(error.line == 3)
        }
    }
}

@Suite struct OpenStepWriterTests {
    @Test(arguments: [
        ("macosx", false), ("14.0", false), ("$(inherited)", true), ("<group>", true),
        ("", true), ("a-b", true), ("a+b", true), ("with space", true),
        ("Sources/App/main.swift", false), ("https://example.com", true),
        ("___VARIABLE___", true), ("__two", false), ("$SRCROOT", false),
    ])
    func quotingPolicy(_ input: String, _ quoted: Bool) {
        #expect(OpenStepWriter.needsQuotes(input) == quoted)
    }

    @Test func escapesSpecialCharacters() {
        #expect(OpenStepWriter.quote("a\"b\\c\nd\te") == #""a\"b\\c\nd\te""#)
        #expect(OpenStepWriter.quote("\u{01}") == #""\U0001""#)
        #expect(OpenStepWriter.quote("é") == "\"é\"")
    }

    @Test func roundTripsThroughParser() throws {
        let value: PlistValue = [
            "z": ["1", "two words", ["k": "v"]],
            "a": .data([1, 2, 3, 4, 5]),
            "escapes": "line\nbreak \"q\"",
        ]
        let text = OpenStepWriter.write(value)
        #expect(try OpenStepParser.parse(text) == value)
    }
}

@Suite struct PlistDictionaryTests {
    @Test func preservesInsertionOrderAndRemoval() {
        var d = PlistDictionary()
        d["b"] = "1"
        d["a"] = "2"
        d["b"] = "3"
        #expect(d.keys == ["b", "a"])
        d["b"] = nil
        #expect(d.keys == ["a"])
        #expect(d.count == 1)
    }
}
