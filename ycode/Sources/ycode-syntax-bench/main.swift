import Foundation
import YcodeSyntax

// Measures YcodeSyntax on a generated 20,000-line Swift file
// (specs/ide/source-editor.md, "Ycode implementation", Performance).
// Build in release: swift build -c release --product ycode-syntax-bench

func ms(_ seconds: Double) -> String { String(format: seconds < 0.001 ? "%.4f" : "%.2f", seconds * 1000) }
func time(_ body: () -> Void) -> Double {
    let t0 = Date()
    body()
    return Date().timeIntervalSince(t0)
}

let source = SyntaxBenchmark.swiftSource(lines: 20_000)
var doc: SyntaxDocument!
print("full highlight, lexical: \(ms(time { doc = SyntaxDocument(text: source, language: .swift, deferParse: true) })) ms")
print("full highlight, swift-syntax parse and classification: \(ms(time { doc.refine() })) ms")
let at = (source as NSString).range(of: "var name = \"item 2000\"").location
var lexical = 0.0, parser = 0.0
for k in 0..<30 {
    lexical += time { doc.replace(NSRange(location: at + k, length: 0), with: "x") }
    parser += time { doc.refine() }
}
print("incremental, per keystroke: lexical \(ms(lexical / 30)) ms, parser pass \(ms(parser / 30)) ms (\(doc.lastUpdate.linesLexed) lines re-classified)")
@MainActor func returnCost(line: Int) -> Double {
    let caret = doc.lineRange(line).upperBound
    _ = TypingRules.newline(in: doc, selection: NSRange(location: caret, length: 0), options: TypingOptions())   // fills the event cache
    return time { for _ in 0..<30 { _ = TypingRules.newline(in: doc, selection: NSRange(location: caret, length: 0), options: TypingOptions()) } } / 30
}
let inside = (source as NSString).range(of: "    let value: Int = 70000").location
print("Return (indentation from the structure): inside a struct \(ms(returnCost(line: doc.line(containing: inside)))) ms, at top level near the end \(ms(returnCost(line: doc.lineCount - 2))) ms")
let opened = time { doc.replace(NSRange(location: at, length: 0), with: "/*") }
print("opening a block comment (re-lexes to the end of the file): \(ms(opened)) ms, \(doc.lastUpdate.linesLexed) lines")
