import Foundation
import OVPlatform
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// Beta 5, B5-OPENVIEWS (specs/ide/parity-inventory.md P-033; Linux rows
// L-001, L-002): the on-demand menu bar moves the window's content down
// while it shows instead of covering the toolbar, and a window too narrow
// for every title (Welcome, 480 points) shows the titles that fit in full
// and the rest in an overflow menu, instead of cutting them to "Yc…".

/// Commands that make a bar as long as Ycode's (twelve titles).
struct ManyMenus: Commands {
    var body: some Commands {
        CommandMenu("Find") { Button("Find…") {} }
        CommandMenu("Navigate") { Button("Reveal") {} }
        CommandMenu("Editor") { Button("Show Minimap") {} }
        CommandMenu("Product") { Button("Build") {} }
        CommandMenu("Debug") { Button("Pause") {} }
        CommandMenu("Integrate") { Button("Commit…") {} }
    }
}

struct NarrowApp: App {
    var body: some Scene {
        WindowGroup("Main") { BandContent() }
            .defaultSize(width: 1400, height: 600)
            .windowStyle(.hiddenTitleBar)
            .commands { ManyMenus() }
        Window("Welcome", id: "welcome") { Text("Welcome card").frame(width: 480, height: 400) }
            .windowStyle(.plain)
            .windowResizability(.contentSize)
            .defaultLaunchBehavior(.presented)
    }
}

@MainActor
@Suite("B5 on-demand menu bar (P-033)")
struct OnDemandMenuBarTests {
    @Test func theRevealedBarMovesTheContentDownInsteadOfCoveringIt() throws {
        let h = DecoratedHarness { BandContent() }
        let state = h.main.windowChrome
        func run() -> CGRect? { h.elements().first { $0.label == "Run" }?.frame }
        let before = try #require(run())
        h.pointer(.moved, CGPoint(x: 400, y: 1), at: 1)
        h.run(until: 1.8)
        #expect(state.menuBarRevealed && state.menuBarShown)
        // The toolbar band (its Run button) is now under the bar's 26 points.
        let after = try #require(run())
        #expect(abs(after.minY - before.minY - 26) < 0.01, "\(before) → \(after)")
        let bar = try #require(h.elements().first { $0.role == .menuBar })
        #expect(bar.frame.maxY <= after.minY)
        // The window buttons move with the content.
        let close = try #require(h.button("Close"))
        #expect(abs(close.frame.minY - 45) < 0.01, "\(close.frame)")
        // The bar stays while the pointer is in the band under it; it goes
        // (and the content comes back up) below the band.
        h.pointer(.moved, CGPoint(x: 400, y: 60), at: 2)
        #expect(state.menuBarRevealed)
        h.pointer(.moved, CGPoint(x: 400, y: 300), at: 2.1)
        h.run(until: 2.6)
        #expect(!state.menuBarShown)
        let back = try #require(run())
        #expect(abs(back.minY - before.minY) < 0.01)
    }

    @Test func anOpenMenuKeepsTheContentDown() throws {
        let h = DecoratedHarness { BandContent() }
        let state = h.main.windowChrome
        h.key(.function(10), at: 1)
        h.run(until: 1.5)
        #expect(state.menuBarMenuOpen && state.menuBarShown && h.popups.count == 1)
        #expect(h.main.chromeContentTop == 26)
    }

    @Test func aNarrowWindowShowsWholeTitlesAndAnOverflowMenu() throws {
        let backend = HeadlessBackend(scale: 1)
        let host = AppHost(NarrowApp.self, backend: backend)
        host.makePresenter = { _ in nil }
        host.showsMenuBar = true
        host.appName = "Ycode"
        host.launch()
        host.run(until: 0.5)
        let welcome = try #require(host.windows.first { $0.sceneID == "welcome" })
        #expect(welcome.size.width == 480)
        // Revealed (Alt tapped alone).
        let alt = Key.other(0x4000_00E2)
        backend.post(.key(KeyEvent(window: welcome.platform.id, key: alt, isDown: true, timestamp: 1)), at: 1)
        backend.post(.key(KeyEvent(window: welcome.platform.id, key: alt, isDown: false, timestamp: 1.05)), at: 1.05)
        host.run(until: 1.5)
        // The bar is at the window's top and the fixed-size card under it.
        let barElement = try #require(welcome.accessibilityTree().flattened.first { $0.role == .menuBar })
        #expect(abs(barElement.frame.minY) < 0.5, "\(barElement.frame)")
        let bar = try #require(welcome.services.menuBar)
        #expect(bar.menus.count == 12, "\(bar.menuTitles)")
        #expect(bar.overflowShown)
        let hidden = bar.hiddenMenus
        #expect(!hidden.isEmpty && hidden.count < 12)
        #expect(hidden == Array(hidden.first!..<12))
        // Every title shown is whole: no ellipsis, inside the window.
        let tree = welcome.accessibilityTree().flattened
        let items = tree.filter { $0.role == .menuBarItem && $0.frame.minX >= 0 }
        #expect(items.count == 12 - hidden.count + 1)
        #expect(items.allSatisfy { $0.frame.maxX <= 480 })
        let texts = OpenViewsAutomation.texts(host.windows.filter { !$0.isPopup }.firstIndex { $0 === welcome } ?? 0)
        #expect(!texts.contains { $0.text.contains("…") })
        // The overflow lists the menus left out.
        let more = try #require(items.first { $0.label == "More Menus" })
        AccessibilityTree.perform("default", on: more.id, in: welcome)
        host.run(until: 2)
        let popup = try #require(host.windows.first { $0.isPopup })
        let rows = popup.accessibilityTree().flattened.compactMap(\.label)
        for i in hidden { #expect(rows.contains(bar.menus[i].title), "\(rows)") }
    }

    @Test func titlesThatFitAllShowWithoutTheOverflow() {
        #expect(MenuBarTitlesLayout.shownCount(widths: [40, 30, 30], overflow: 20, available: 100) == 3)
        #expect(MenuBarTitlesLayout.shownCount(widths: [40, 30, 31], overflow: 20, available: 100) == 2)
        #expect(MenuBarTitlesLayout.shownCount(widths: [40, 50, 30], overflow: 20, available: 100) == 1)
    }
}
