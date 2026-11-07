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

// B5-OPENVIEWS (`specs/ide/cross-platform-parity.md` §2, §15 OV-1, OV-7):
// client-side window buttons for hidden title bars, the hit test that moves
// and resizes undecorated windows, the on-demand menu bar, window
// behaviours, the active state and launch behaviour.

struct DecoratedApp: App {
    static var content: () -> AnyView = { AnyView(EmptyView()) }
    static var mainLaunch = SceneLaunchBehavior.automatic
    static var welcomeLaunch = SceneLaunchBehavior.automatic
    static var menuBar = MenuBarPresentation.automatic

    var body: some Scene {
        WindowGroup("Main") { Self.content() }
            .defaultSize(width: 900, height: 600)
            .windowStyle(.hiddenTitleBar)
            .menuBarPresentation(Self.menuBar)
            .defaultLaunchBehavior(Self.mainLaunch)
        Window("Welcome", id: "welcome") { Text("Welcome card").frame(width: 480, height: 400) }
            .windowStyle(.plain)
            .windowResizability(.contentSize)
            .defaultLaunchBehavior(Self.welcomeLaunch)
    }
}

/// A toolbar band like the IDE's: a button, a title and empty space.
struct BandContent: View {
    @State var count = 0
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Color.clear.frame(width: 90, height: 1)
                Button("Run") { count += 1 }
                Text("Merger")
                Spacer()
            }
            .frame(height: 52)
            Text("Body \(count)").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

@MainActor
final class DecoratedHarness {
    let backend: HeadlessBackend
    let host: AppHost

    init<V: View>(menuBar: Bool = true, presentation: MenuBarPresentation = .automatic,
                  main: SceneLaunchBehavior = .automatic, welcome: SceneLaunchBehavior = .automatic,
                  @ViewBuilder content: @escaping () -> V) {
        backend = HeadlessBackend(scale: 1)
        DecoratedApp.content = { AnyView(content()) }
        DecoratedApp.menuBar = presentation
        DecoratedApp.mainLaunch = main
        DecoratedApp.welcomeLaunch = welcome
        host = AppHost(DecoratedApp.self, backend: backend)
        host.makePresenter = { _ in nil }
        host.showsMenuBar = menuBar
        host.appName = "Demo"
        host.launch()
        host.run(until: 0.5)
    }

    var mains: [WindowHost] { host.windows.filter { !$0.isPopup } }
    var main: WindowHost { mains.first { $0.sceneID == nil }! }
    var platform: HeadlessWindow { main.platform as! HeadlessWindow }  // swiftlint:disable:this force_cast
    var popups: [WindowHost] { host.windows.filter(\.isPopup) }

    func run(until t: TimeInterval) { host.run(until: t) }

    func pointer(_ phase: PointerPhase, _ p: CGPoint, modifiers: KeyModifiers = [], at t: TimeInterval) {
        backend.post(.pointer(PointerEvent(window: main.platform.id, kind: .mouse, phase: phase, location: p,
                                           button: phase == .moved ? 0 : 1, isPressed: phase == .down,
                                           modifiers: modifiers, timestamp: t)), at: t)
        run(until: t + 0.01)
    }

    func click(_ p: CGPoint, modifiers: KeyModifiers = [], at t: TimeInterval) {
        pointer(.moved, p, modifiers: modifiers, at: t)
        pointer(.down, p, modifiers: modifiers, at: t + 0.02)
        pointer(.up, p, modifiers: modifiers, at: t + 0.07)
    }

    func key(_ k: Key, _ modifiers: KeyModifiers = [], down: Bool = true, at t: TimeInterval) {
        backend.post(.key(KeyEvent(window: main.platform.id, key: k, isDown: down, modifiers: modifiers, timestamp: t)), at: t)
        run(until: t + 0.01)
    }

    func elements(_ w: WindowHost? = nil) -> [AccessibilityElement] {
        (w ?? main).accessibilityTree().flattened
    }

    func button(_ label: String) -> AccessibilityElement? {
        elements().first { $0.role == .button && $0.label == label }
    }
}

@MainActor
@Suite("B5 window decorations")
struct WindowDecorationTests {
    @Test func hiddenTitleBarWindowIsUndecoratedWithThreeButtonsAtTheMacPlaces() throws {
        let h = DecoratedHarness { BandContent() }
        #expect(h.platform.isDecorated == false)
        #expect(h.platform.hitTest != nil)
        // The macOS IDE's view dump: 14 × 14 at x 19, 42, 65, y 19.
        for (label, x) in [("Close", 19.0), ("Minimize", 42.0), ("Zoom", 65.0)] {
            let b = try #require(h.button(label))
            #expect(abs(b.frame.minX - x) < 0.01 && abs(b.frame.minY - 19) < 0.01, "\(label) \(b.frame)")
            #expect(abs(b.frame.width - 14) < 0.01 && abs(b.frame.height - 14) < 0.01)
            #expect(b.actionNames == ["default"])
        }
        // The window buttons come first in the window's reading order.
        let labels = h.main.accessibilityTree().flattened.dropFirst().compactMap(\.label)
        #expect(Array(labels.prefix(3)) == ["Close", "Minimize", "Zoom"])
        // On demand: no menu bar in the layout, the content starts at y 0.
        let run = try #require(h.elements().first { $0.label == "Run" })
        #expect(run.frame.midY < 52 && run.frame.minY > 0)
    }

    @Test func hitTestMovesOnTheBandAndResizesAtTheEdges() throws {
        let h = DecoratedHarness { BandContent() }
        let run = try #require(h.elements().first { $0.label == "Run" })
        let title = try #require(h.elements().first { $0.label == "Merger" })
        #expect(h.platform.hitRegion(at: CGPoint(x: 600, y: 26)) == .draggable)
        #expect(h.platform.hitRegion(at: CGPoint(x: title.frame.midX, y: title.frame.midY)) == .draggable)
        #expect(h.platform.hitRegion(at: CGPoint(x: run.frame.midX, y: run.frame.midY)) == .normal)
        #expect(h.platform.hitRegion(at: CGPoint(x: 26, y: 26)) == .normal)   // the close button
        #expect(h.platform.hitRegion(at: CGPoint(x: 600, y: 300)) == .normal) // below the band
        #expect(h.platform.hitRegion(at: CGPoint(x: 2, y: 300)) == .resizeLeft)
        #expect(h.platform.hitRegion(at: CGPoint(x: 898, y: 598)) == .resizeBottomRight)
        #expect(h.platform.hitRegion(at: CGPoint(x: 450, y: 1)) == .resizeTop)
        // Maximised: no resize edges.
        h.platform.setMaximized(true)
        #expect(h.platform.hitRegion(at: CGPoint(x: 2, y: 300)) == .normal)
        #expect(h.platform.hitRegion(at: CGPoint(x: 450, y: 1)) == .draggable)
    }

    @Test func buttonsMinimizeZoomAndClose() throws {
        let h = DecoratedHarness(welcome: .presented, content: { BandContent() })
        // Welcome is presented: two windows (the main group is automatic,
        // so with a presented scene it does not open)…
        #expect(h.mains.count == 1 && h.mains[0].sceneID == "welcome")
        h.host.openWindow(id: nil)
        h.run(until: 0.6)
        #expect(h.mains.count == 2)
        h.click(CGPoint(x: 49, y: 26), at: 1)      // minimize
        #expect(h.platform.isMinimized)
        h.click(CGPoint(x: 72, y: 26), at: 1.5)    // zoom: full screen
        #expect(h.platform.isFullscreen)
        h.click(CGPoint(x: 72, y: 26), at: 2)      // zoom again: back
        #expect(!h.platform.isFullscreen)
        h.click(CGPoint(x: 72, y: 26), modifiers: .option, at: 2.5)  // Alt: maximise
        #expect(h.platform.isMaximized && !h.platform.isFullscreen)
        h.click(CGPoint(x: 26, y: 26), at: 3)      // close
        #expect(h.mains.count == 1 && h.mains[0].sceneID == "welcome")
    }

    @Test func glyphsOnHoverAndGreyWhenInactive() {
        let h = DecoratedHarness { BandContent() }
        let state = h.main.windowChrome
        #expect(!state.buttonsHovered)
        h.pointer(.moved, CGPoint(x: 49, y: 26), at: 1)
        #expect(state.buttonsHovered)
        h.pointer(.moved, CGPoint(x: 300, y: 300), at: 1.1)
        #expect(!state.buttonsHovered)
        // Another window takes the focus: this one is inactive.
        #expect(h.main.activeState == .key)
        h.backend.post(.window(h.main.platform.id, .focusLost))
        h.run(until: 1.3)
        #expect(h.main.activeState == .inactive)
        #expect(h.main.graph.environment.controlActiveState == .inactive)
        // The buttons themselves draw the inactive look.
        func keys() -> [Bool] {
            var out: [Bool] = []
            h.main.graph.root?.forEachNode { n in if let b = n.view as? WindowButton { out.append(b.isKey) } }
            return out
        }
        #expect(keys() == [false, false, false])
        h.backend.post(.window(h.main.platform.id, .focusGained))
        h.run(until: 1.4)
        #expect(h.main.activeState == .key)
        #expect(keys() == [true, true, true])
    }

    @Test func behavioursDisableButtonsAndAModalDisablesClose() throws {
        struct Content: View {
            @State var alert = false
            var body: some View {
                BandContent()
                    .windowMinimizeBehavior(.disabled)
                    .alert("Merge?", isPresented: $alert) { Button("OK") {} }
                    .onAppear { alert = true }
            }
        }
        let h = DecoratedHarness { Content() }
        h.run(until: 1)
        let close = try #require(h.button("Close"))
        let minimize = try #require(h.button("Minimize"))
        let zoom = try #require(h.button("Zoom"))
        #expect(close.actionNames.isEmpty)      // a sheet or alert is up
        #expect(minimize.actionNames.isEmpty)   // windowMinimizeBehavior(.disabled)
        #expect(zoom.actionNames == ["default"])
        h.click(CGPoint(x: 26, y: 26), at: 2)
        #expect(h.mains.count == 1)
    }

    @Test func onDemandMenuBarRevealsAtTheTopEdgeWithF10AndAlt() throws {
        let h = DecoratedHarness { BandContent() }
        let state = h.main.windowChrome
        #expect(state.menuBarOnDemand && !state.menuBarRevealed)
        #expect(h.main.chrome?.menuBar == false)
        // Resting at the top edge.
        h.pointer(.moved, CGPoint(x: 400, y: 1), at: 1)
        h.run(until: 1.2)
        #expect(!state.menuBarRevealed)
        h.run(until: 1.5)
        #expect(state.menuBarRevealed)
        // Revealed, its titles take presses (not a window move).
        #expect(h.platform.hitRegion(at: CGPoint(x: 400, y: 12)) == .normal)
        h.pointer(.moved, CGPoint(x: 400, y: 300), at: 2)
        #expect(!state.menuBarRevealed)
        // F10 shows it and opens the first menu; Escape closes the menu,
        // then the bar.
        h.key(.function(10), at: 3)
        #expect(state.menuBarRevealed && h.popups.count == 1)
        h.backend.post(.key(KeyEvent(window: h.popups[0].platform.id, key: .escape, timestamp: 3.1)), at: 3.1)
        h.run(until: 3.2)
        #expect(h.popups.isEmpty)
        #expect(!state.menuBarRevealed)
        // Alt tapped alone toggles it; Alt with another key does not.
        let alt = Key.other(0x4000_00E2)
        h.key(alt, at: 4)
        h.key(alt, down: false, at: 4.05)
        #expect(state.menuBarRevealed)
        h.key(.escape, at: 4.2)
        #expect(!state.menuBarRevealed)
        h.key(alt, at: 5)
        h.key(.character("f"), [.option], at: 5.02)
        h.key(alt, down: false, at: 5.05)
        #expect(!state.menuBarRevealed)
    }

    @Test func inWindowPresentationKeepsTheBarAndMovesTheButtonsBelowIt() throws {
        let h = DecoratedHarness(presentation: .inWindow) { BandContent() }
        #expect(h.main.chrome?.menuBar == true)
        let close = try #require(h.button("Close"))
        #expect(abs(close.frame.minY - (26 + 19)) < 0.01)
        #expect(h.platform.hitRegion(at: CGPoint(x: 600, y: 10)) == .normal)      // the menu bar
        #expect(h.platform.hitRegion(at: CGPoint(x: 600, y: 26 + 26)) == .draggable)
    }

    @Test func plainWindowHasNoButtonsAndLaunchBehaviourPicksIt() {
        let h = DecoratedHarness(main: .suppressed, content: { BandContent() })
        #expect(h.mains.count == 1 && h.mains[0].sceneID == "welcome")
        let w = h.mains[0]
        #expect((w.platform as? HeadlessWindow)?.isDecorated == false)
        #expect(!w.accessibilityTree().flattened.contains { $0.label == "Close" })
        #expect(w.isResizable == false)
    }

    @Test func contentSizedWindowTakesItsContentsSizeAndButtonsCanBeHidden() throws {
        struct Wizard: View {
            var body: some View {
                Text("Wizard").frame(width: 760, height: 600).windowButtonsShown(.close)
            }
        }
        let h = DecoratedHarness(main: .suppressed) { Wizard() }
        h.host.openWindow(id: nil)
        h.run(until: 1)
        // The main group has a default size; the welcome scene sizes to its
        // content (480 × 400 there).
        let welcome = try #require(h.mains.first { $0.sceneID == "welcome" })
        #expect(welcome.size == CGSize(width: 480, height: 400))
        // Only close is drawn; minimize and zoom keep their places.
        let labels = h.elements().compactMap { $0.role == .button ? $0.label : nil }
        #expect(labels.contains("Close") && !labels.contains("Minimize") && !labels.contains("Zoom"))
        #expect(h.platform.hitRegion(at: CGPoint(x: 49, y: 26)) == .draggable)
    }
}
