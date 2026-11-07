import Foundation
import Testing
@testable import YcodeSyntax

/// Token snapshots per language (`specs/ide/source-editor.md`, "Ycode implementation").
@Suite struct HighlightingTests {
    @Test func languagesByFileName() {
        #expect(SyntaxLanguage(fileName: "a.swift") == .swift)
        #expect(SyntaxLanguage(fileName: "a.m") == .objc && SyntaxLanguage(fileName: "a.mm") == .objc && SyntaxLanguage(fileName: "a.h") == .objc)
        #expect(SyntaxLanguage(fileName: "a.c") == .c && SyntaxLanguage(fileName: "a.cpp") == .cpp && SyntaxLanguage(fileName: "a.hpp") == .cpp)
        #expect(SyntaxLanguage(fileName: "Shaders.metal") == .metal)
        #expect(SyntaxLanguage(fileName: "Info.plist") == .xml && SyntaxLanguage(fileName: "a.entitlements") == .xml && SyntaxLanguage(fileName: "a.xcscheme") == .xml)
        #expect(SyntaxLanguage(fileName: "README.md") == .markdown && SyntaxLanguage(fileName: "c.yml") == .yaml && SyntaxLanguage(fileName: "x.json") == .json)
        #expect(SyntaxLanguage(fileName: "build.sh") == .shell && SyntaxLanguage(fileName: "Debug.xcconfig") == .xcconfig)
        #expect(SyntaxLanguage(fileName: "notes.txt") == .plain)
        #expect(SyntaxLanguage.allCases.prefix(4) == [.swift, .objc, .c, .plain])   // menu tags stay stable
    }

    @Test func swiftThroughTheParser() {
        let t = snapshot("""
        /// Doc
        @MainActor public final class A: B {
            static let s = "a\\(x)b" // c
            func f(_ v: Int) -> [String]? { return nil }
        }
        #if DEBUG
        let n = 0x1F + 2.5e3
        #endif
        let r = /a+b/
        let p = <#value#>
        """, .swift)
        #expect(t == [
            "docComment /// Doc",
            // Declared names have kinds of their own (editor-area.md F.3).
            "attribute @MainActor", "keyword public", "keyword final", "keyword class", "typeDeclaration A", "typeName B",
            "keyword static", "keyword let", "declaration s", "string \"a", "string b\"", "comment // c",
            "keyword func", "declaration f", "typeName Int", "typeName String", "keyword return", "keyword nil",
            "preprocessor #if", "preprocessor DEBUG",
            "keyword let", "declaration n", "number 0x1F", "number 2.5e3",
            "preprocessor #endif",
            "keyword let", "declaration r", "regex /a+b/",
            "keyword let", "declaration p", "placeholder <#value#>",
        ])
    }

    @Test func swiftLexically() {
        let t = snapshot("""
        /* a /* nested */ still */ let s = #"raw "q""#
        let m = \"""
          two \\(lines)
          \"""
        @objc func `default`() {}
        """, .swift, parser: false)
        #expect(t == [
            "comment /* a /* nested */ still */", "keyword let", "declaration s", "string #\"raw \"q\"\"#",
            "keyword let", "declaration m", "string \"\"\"",
            "string   two \\(lines)",
            "string   \"\"\"",
            "attribute @objc", "keyword func",
        ])
    }

    @Test func c() {
        let t = snapshot("""
        #define MAX(a, b) \\
            ((a) > (b) ? (a) : (b)) // max
        static const uint32_t k = 1'000u; char c = '\\n';
        /* block
           comment */ int main(void) { return sizeof(L"w"); }
        """, .c)
        #expect(t == [
            "preprocessor #define MAX(a, b) \\",
            "preprocessor     ((a) > (b) ? (a) : (b)) // max",
            "keyword static", "keyword const", "typeName uint32_t", "number 1'000u", "keyword char", "character '\\n'",
            "comment /* block", "comment    comment */", "keyword int", "keyword void", "keyword return", "keyword sizeof", "string L\"w\"",
        ])
    }

    @Test func cpp() {
        let t = snapshot("""
        template <typename T> [[nodiscard]] auto f() noexcept {
            auto s = R"x(line one
        line ")" two)x";
            return std::string{};
        }
        """, .cpp)
        #expect(t == [
            "keyword template", "keyword typename", "typeName T", "attribute [[nodiscard]]", "keyword auto", "keyword noexcept",
            "keyword auto", "string R\"x(line one",
            "string line \")\" two)x\"",
            "keyword return",
            ])
    }

    @Test func objectiveC() {
        let t = snapshot("""
        #import <Foundation/Foundation.h>
        @interface A : NSObject
        @property (nonatomic, copy) NSString *name;
        - (BOOL)go { return YES && [self run:@"s"]; }
        @end
        """, .objc)
        #expect(t == [
            "preprocessor #import <Foundation/Foundation.h>",
            "keyword @interface", "typeName A", "typeName NSObject",
            "keyword @property", "keyword nonatomic", "keyword copy", "typeName NSString",
            "keyword BOOL", "keyword return", "keyword YES", "keyword self", "string @\"s\"",
            "keyword @end",
        ])
    }

    @Test func metal() {
        let t = snapshot("""
        kernel void add(device float4 *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
            half3x3 m; texture2d<float> tex;
        }
        """, .metal)
        #expect(t == [
            "keyword kernel", "keyword void", "keyword device", "typeName float4", "attribute [[buffer(0)]]", "keyword uint",
            "attribute [[thread_position_in_grid]]",
            "typeName half3x3", "typeName texture2d", "keyword float",
        ])
    }

    @Test func json() {
        let t = snapshot("""
        {
          "name" : "Ycode", // note
          "n": -1.5e2, "ok": [true, null]
        }
        """, .json)
        #expect(t == ["key \"name\"", "string \"Ycode\"", "comment // note", "key \"n\"", "number -1.5e2", "key \"ok\"", "keyword true", "keyword null"])
    }

    @Test func xmlAndPropertyLists() {
        let t = snapshot("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//X//DTD PLIST 1.0//EN" "x.dtd">
        <plist version="1.0"><!-- a
        comment --><dict><key>K&amp;</key><string><![CDATA[<raw>]]></string></dict></plist>
        """, .xml)
        #expect(t == [
            "preprocessor <?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "preprocessor <!DOCTYPE plist PUBLIC \"-//X//DTD PLIST 1.0//EN\" \"x.dtd\">",
            "tagName plist", "attributeName version", "string \"1.0\"", "comment <!-- a",
            "comment comment -->", "tagName dict", "tagName key", "entity &amp;", "tagName key", "tagName string", "string <![CDATA[<raw>]]>",
            "tagName string", "tagName dict", "tagName plist",
        ])
    }

    @Test func markdown() {
        let t = snapshot("""
        # Title
        Some *em*, **strong**, `code` and [a link](https://x.org) <https://y.org>.
        - [ ] task
        1. one
        > quoted
        ```swift
        let x = 1
        ```
        <!-- note -->
        """, .markdown)
        #expect(t == [
            "heading # Title",
            "emphasis *em*", "strong **strong**", "codeSpan `code`", "link [a link]", "url (https://x.org)", "url <https://y.org>",
            "listMarker -", "listMarker [ ]",
            "listMarker 1.",
            "quote > quoted",
            "codeSpan ```swift", "codeSpan let x = 1", "codeSpan ```",
            "comment <!-- note -->",
        ])
    }

    @Test func yaml() {
        let t = snapshot("""
        ---
        name: Ycode # app
        count: 3
        on: true
        list:
          - &a "quoted"
          - *a
        text: |
          block
          scalar
        next: !!str 'x'
        """, .yaml)
        #expect(t == [
            "preprocessor ---",
            "key name", "comment # app",
            "key count", "number 3",
            "key on", "keyword true",
            "key list",
            "listMarker -", "variable &a", "string \"quoted\"",
            "listMarker -", "variable *a",
            "key text", "keyword |",
            "string   block", "string   scalar",
            "key next", "preprocessor !!str", "string 'x'",
        ])
    }

    @Test func shell() {
        let t = snapshot("""
        #!/bin/sh
        # comment
        NAME=world; if [ -n "$NAME" ]; then echo "hi ${NAME}" 'x'; fi
        cat <<EOF
        body $x
        EOF
        """, .shell)
        #expect(t == [
            "preprocessor #!/bin/sh",
            "comment # comment",
            "variable NAME", "keyword if", "string \"", "variable $NAME", "string \"", "keyword then", "string \"hi ", "variable ${NAME}", "string \"",
            "string 'x'", "keyword fi",
            "keyword EOF",
            "string body $x",
            "keyword EOF",
        ])
    }

    @Test func xcconfig() {
        let t = snapshot("""
        #include "Base.xcconfig"
        OTHER_FLAGS[sdk=iphoneos*] = $(inherited) -DX=1 // c
        ENABLE_BITCODE = NO
        """, .xcconfig)
        #expect(t == [
            "preprocessor #include", "string \"Base.xcconfig\"",
            "key OTHER_FLAGS", "attribute [sdk=iphoneos*]", "variable $(inherited)", "comment // c",
            "key ENABLE_BITCODE", "keyword NO",
        ])
    }

    @Test func joinedTokensSpanLines() {
        let toks = SyntaxLexers.tokens(in: "a /* x\n\ny */ b \"s\"", language: .c)
        #expect(toks.map(\.kind) == [.comment, .string])
        #expect(toks[0].range == NSRange(location: 2, length: 10))
    }

    @Test func everyKindHasAThemeRole() {
        let roles = Set(SyntaxTokenKind.allCases.map(\.role))
        #expect(roles.isSubset(of: Set(SyntaxTokenKind.Role.allCases)))
        #expect(SyntaxTokenKind.heading.role == .keyword && SyntaxTokenKind.key.role == .attribute && SyntaxTokenKind.codeSpan.role == .string)
    }
}
