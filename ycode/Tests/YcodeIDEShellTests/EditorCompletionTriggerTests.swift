import Foundation
import Testing
import YcodeEditorKit
import YcodeSyntax
@testable import YcodeIDEShell

/// P-080 on Linux: the shell editor asks for completions at the start of a
/// word and after "." in Swift (the macOS rules), never in comments,
/// strings or plain text, and again while an incomplete list shows.
@MainActor
struct EditorCompletionTriggerTests {
    func typed(_ s: String, after text: String, language: SyntaxLanguage = .swift, showing: [EditorCompletion]? = nil) -> Bool {
        let b = EditorBuffer(text: text, language: language)
        b.setCaret((text as NSString).length)
        b.insertText(s)
        return EditorCompletion.shouldRequest(typed: s, in: b, showing: showing)
    }

    @Test func wordsAndMembers() {
        #expect(typed("C", after: "struct V {\n    func f() {\n        "))
        #expect(!typed("o", after: "    C"))
        #expect(typed(".", after: "counter"))
        #expect(!typed(".", after: "x", language: .objc))
        #expect(typed("N", after: "[", language: .objc))
        #expect(!typed("C", after: "// "))
        #expect(!typed("C", after: "let s = \"x"))
        #expect(!typed("x", after: "let "))
        #expect(!typed("C", after: "# ", language: .markdown))
    }

    @Test func incompleteListsAskAgain() {
        var item = EditorCompletion(label: "Counter", text: "Counter")
        #expect(!typed("o", after: "    C", showing: [item]))
        item.fromIncompleteList = true
        #expect(typed("o", after: "    C", showing: [item]))
        // The first letter of a word with a list showing: the list filters.
        #expect(!typed("C", after: "    ", showing: [item]))
    }
}
