import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

@Suite struct FindOptionTests {
    let text = "let greet = 1\nfunc greeting() {}\nGreet()\n// a.b and axb\n"

    @MainActor @Test func navigatorAppliesOptions() throws {
        _ = NSApplication.shared
        let dir = try WindowSnapshotTests().samplePackage()
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        wc.navigator.select(3)
        wc.navigator.find("greet")
        #expect(wc.navigator.rows(3).first?.children.count == 5)
        wc.navigator.findOptionsValue = .init(wholeWord: true, ignoreCase: false)
        wc.navigator.find("greet")
        #expect(wc.navigator.rows(3).first?.children.map(\.line) == [5, 15])
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "find-options.png")
        wc.navigator.refreshSymbols()
        #expect(wc.navigator.symbolRows.first?.children.first?.children.map(\.title) == ["name", "greet"])
    }
}
