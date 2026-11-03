import Foundation
import Testing
@testable import YcodeIDECore

/// `specs/ide/reference-ui-6.md` R43: menu clean-up (§8, M1–M6) and the
/// pass-6b editor defaults (§4.5, E9).
@MainActor
@Suite(.serialized) struct MenuR43Tests {
    // MARK: E9 — the minimap is on in the factory state

    @Test func minimapIsOnInTheFactoryState() {
        let t = TestDefaults("r43-minimap")
        defer { t.remove() }
        let p = Preferences(defaults: t.defaults)
        #expect(p.showMinimap)
        // Registered, not stored: nothing is written until the user sets it.
        #expect(t.defaults.persistentDomain(forName: t.suite)?["Ycode.minimap"] == nil)
        p.showMinimap = false
        // A user who turned it off keeps it off.
        #expect(!Preferences(defaults: t.defaults).showMinimap)
        p.showMinimap = true
        #expect(Preferences(defaults: t.defaults).showMinimap)
    }
}
