import Foundation
import SwiftUI
import YcodeBuild
import YcodeIDECore
import YcodeIDEShell
import YcodeLanguage
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_B4LANG=<prefix>: the beta 4 language walk (P-070, P-080,
// P-121) in a project opened by the app whose `ContentView.swift` uses a
// type from another file of the target and whose unit tests `import XCTest`
// and `@testable import` the app. Prints the live issues after each step
// and writes <prefix>-<step>.png:
//
//   view       ContentView.swift once the server answered: no false
//              "Cannot find 'Counter'"
//   tests      the unit tests: no "No such module"
//   typing-co  "Co" typed on a new line of main.swift: the completion list
//              is open and the line is not marked an error while typing
//   held-end   after the pause: the partial word's error appears, in
//              display form

#if os(Linux)
extension ShellDriver {
    static func b4LanguageWalk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else {
            say("b4lang: no workspace")
            return
        }
        func issues() -> String {
            let live = (w.session.language?.liveIssues ?? [:]).flatMap { path, list in
                list.map { "\(URL(fileURLWithPath: path).lastPathComponent):\($0.location?.line ?? 0) \($0.severity.rawValue): \($0.message)" }
            }
            return "live [\(live.sorted().joined(separator: "; "))] editor lines \(w.editorIssues.keys.sorted())"
        }
        func shot(_ step: String) async {
            await pause(0.6)
            say("b4lang \(step): \(issues()) " + OpenViewsAutomation.screenshot(to: "\(prefix)-\(step).png"))
        }
        func file(_ name: String) -> String? { w.root.allFiles.first { $0.name == name }?.path }
        for _ in 0..<240 where w.session.language == nil { await pause(0.25) }
        say("b4lang: server \(w.session.language == nil ? "missing" : "started")")
        guard let view = file("ContentView.swift"), let tests = file("CounterAppTests.swift") else {
            say("b4lang: no ContentView.swift / CounterAppTests.swift")
            return
        }
        // Both files open in the server; wait for their answers with no error.
        w.open(tests)
        await pause(0.5)
        w.open(view)
        let began = Date()
        for _ in 0..<240 {
            let live = w.session.language?.liveDiagnostics ?? [:]
            let answered = [view, tests].allSatisfy { live[URL(fileURLWithPath: $0).standardizedFileURL.path] != nil }
            if answered, !(w.session.language?.liveIssues.values.joined().contains { $0.severity == .error } ?? true) { break }
            await pause(0.5)
        }
        say("b4lang: settled after \(Int(Date().timeIntervalSince(began))) s")
        await shot("view")
        w.open(tests)
        await shot("tests")
        w.open(view)
        await pause(0.5)

        // A new line in the body, then "Co": the list opens by itself.
        // Top-level code (main.swift) or a function body: where the list
        // holds types and values.
        if let main = file("main.swift") { w.open(main) }
        await pause(0.5)
        guard let b = w.editor?.buffer, let r = b.text.range(of: "let view = ContentView()") ?? b.text.range(of: "var counter = Counter()") else {
            say("b4lang: no counter line")
            return
        }
        let end = b.text.utf16.distance(from: b.text.utf16.startIndex, to: r.upperBound.samePosition(in: b.text.utf16) ?? b.text.utf16.endIndex)
        // The editor takes the keyboard, then the caret goes after the line.
        if let e = frame("editor") { await OpenViewsAutomation.click(at: CGPoint(x: e.midX, y: e.minY + 40)) }
        await pause(0.3)
        b.setCaret(end)
        OpenViewsAutomation.press(.return)
        await pause(0.2)
        // One keystroke each, as typed.
        OpenViewsAutomation.type("C")
        await pause(0.15)
        OpenViewsAutomation.type("o")
        // Within the hold: the list is open and the line is not marked.
        await pause(0.3)
        await shot("typing-co")
        let items = await w.completions()
        say("b4lang: completions for Co: \(items.prefix(8).map(\.label))")
        // After the pause the partial word's error shows, in display form.
        await pause(2.5)
        await shot("held-end")
        OpenViewsAutomation.press(.escape)
    }
}
#endif
