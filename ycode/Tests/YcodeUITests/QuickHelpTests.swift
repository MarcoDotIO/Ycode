import AppKit
import Foundation
import Testing
import YcodeDebug
import YcodeLanguage
@testable import YcodeUI

@Suite struct QuickHelpFormatterTests {
    @Test func markdownToPlain() {
        let md = "```swift\nstruct Greeter\n```\n\n---\n\n\n A `greeting` printer.\n"
        #expect(QuickHelpFormatter.plain(md) == "struct Greeter\n\n A greeting printer.")
    }
}

@MainActor
@Suite(.serialized, .heavyIntegration, .timeLimit(.minutes(3))) struct QuickHelpTests {
    /// ⌥-click → hover in the Quick Help inspector; ⌘-click → definition.
    @Test func hoverAndCommandClick() async throws {
        // Heavy work (builds, debugger, language server) takes turns across test processes.
        let heavy = await InterprocessLock.acquire(path: InterprocessLock.debuggerTestLockPath)
        defer { heavy.unlock() }
        guard SourceKitLSP.locate() != nil else { return }
        _ = NSApplication.shared
        let dir = try WindowSnapshotTests().samplePackage()
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        await wc.connectLanguageService(transport: nil)
        #expect(await waitUntil(90) { session.displayedIssues.contains { $0.message.contains("missing") } })

        // Option-click on `Greeter` in line 14.
        let line14 = wc.editor.textView.lineIndex.range(ofLine: 14)!
        let url = try #require(wc.editor.fileURL)
        let text = await wc.showQuickHelp(url: url, at: wc.editor.textView.lineIndex.position(at: line14.location + 10), anchor: .zero)
        #expect(text?.contains("struct Greeter") == true)
        #expect(wc.inspector.quickHelp?.contains("Greeter") == true)
        // Doc comment `/// A greeting printer.` is part of the hover.
        #expect(text?.contains("greeting printer") == true)
        wc.inspector.select(2)
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "quick-help-inspector.png")

        // Command-click on `greet` in line 15 jumps to its declaration (line 5).
        let line15 = wc.editor.textView.lineIndex.range(ofLine: 15)!
        wc.editor.jumpToDefinition(atOffset: line15.location + 8)
        #expect(await waitUntil(30) { wc.editor.currentLine == 5 })
        await session.language?.stop()
    }
}
