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

// Round R9, suite T-MODAL (10-plan.md §3.2; 06 §6): sheet frames per detent
// in the reference's window, the order of `onAppear`, `onDismiss` and
// `onDisappear`, detent changes, covers, alerts, dialogs and popovers.

@MainActor
final class ModalControls {
    var shown = Controls<Bool>()
    var detent = Controls<PresentationDetent>()
}

struct SheetProbe: View {
    let log: Log
    let controls: ModalControls
    @State private var shown = false
    @State private var detent = PresentationDetent.medium

    var body: some View {
        controls.shown.binding = $shown
        controls.detent.binding = $detent
        return Color.white
            .sheet(isPresented: $shown, onDismiss: { log("onDismiss") }) {
                Color.blue
                    .onAppear { log("sheet appear") }
                    .onDisappear { log("sheet disappear") }
                    .presentationDetents([.medium, .large], selection: $detent)
            }
    }
}

/// The reference's window: 466 × 678 with the safe area 382 × 644.
@MainActor
func phoneHarness<V: View>(@ViewBuilder _ content: @escaping () -> V) -> Harness {
    let h = Harness(size: CGSize(width: 466, height: 678), content: content)
    h.window.safeAreaInsets = EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 84)
    h.run(until: 0.6)
    return h
}

@MainActor
@Suite("R9 presentations (T-MODAL)")
struct PresentationTests {
    func cardFrame(_ h: Harness) -> CGRect? { h.frame { $0 is Color && ($0 as? Color) == .blue } }

    @Test func sheetDetentsFramesAndDismissalOrder() {
        let log = Log(), c = ModalControls()
        let h = phoneHarness { SheetProbe(log: log, controls: c) }
        c.shown.value = true
        h.run(until: 0.65)
        // onAppear when the presentation starts (06 §6).
        #expect(log.take() == ["sheet appear"])
        h.run(until: 1.2)
        #expect(cardFrame(h) == CGRect(x: 8, y: 280, width: 374, height: 356))
        // Setting the detent resizes the sheet.
        c.detent.value = .large
        h.run(until: 1.5)
        #expect(cardFrame(h) == CGRect(x: 8, y: 8, width: 374, height: 636))
        // Idle: nothing left to update or animate.
        #expect(!h.window.graph.needsUpdate && !h.window.graph.isAnimating)
        // Dismissal: onDismiss then onDisappear, both at the end (0.5 s).
        c.shown.value = false
        h.run(until: 1.8)
        #expect(log.take().isEmpty)
        h.run(until: 2.2)
        #expect(log.take() == ["onDismiss", "sheet disappear"])
        #expect(h.window.services.presentations.isEmpty)
    }

    @Test func dismissActionClosesTheSheet() {
        let log = Log()
        struct Inner: View {
            let log: Log
            @Environment(\.dismiss) private var dismiss
            var body: some View {
                Button("Done") { dismiss() }.onDisappear { log("inner disappear") }
            }
        }
        struct Outer: View {
            let log: Log
            @State var shown = true
            var body: some View {
                Text(shown ? "shown" : "hidden")
                    .sheet(isPresented: $shown) { Inner(log: log) }
            }
        }
        let h = Harness(size: CGSize(width: 800, height: 600)) { Outer(log: log) }
        h.run(until: 1.0)
        guard let done = frameOfText("Done", h.window.graph) else { Issue.record("button"); return }
        h.tap(done.center, at: 1.1)
        h.run(until: 2.0)
        #expect(log.take() == ["inner disappear"])
        #expect(frameOfText("hidden", h.window.graph) != nil)
    }

    @Test func fullScreenCoverFillsTheSafeArea() {
        struct Probe: View {
            @State var shown = true
            var body: some View { Color.white.fullScreenCover(isPresented: $shown) { Color.blue } }
        }
        let h = phoneHarness { Probe() }
        h.run(until: 1.5)
        // 06 §6: content frame (0, 0, 382, 644) with the window's safe area.
        #expect(cardFrame(h) == CGRect(x: 0, y: 0, width: 382, height: 644))
    }

    @Test func alertButtonsRunTheirActionAndDismiss() {
        let log = Log()
        struct Probe: View {
            let log: Log
            @State var shown = true
            var body: some View {
                Color.white.alert("Delete file?", isPresented: $shown) {
                    Button("Delete", role: .destructive) { log("delete") }
                    Button("Cancel", role: .cancel) { log("cancel") }
                } message: {
                    Text("This cannot be undone.")
                }
                .onChange(of: shown) { _, v in log("shown \(v)") }
            }
        }
        let h = Harness(size: CGSize(width: 600, height: 500)) { Probe(log: log) }
        h.run(until: 1.0)
        guard let del = frameOfText("Delete", h.window.graph) else { Issue.record("alert"); return }
        // Alerts are 270 points wide on this host and centred.
        let width = h.frame { $0 is AlertCard }?.width
        #expect(width == 270)
        h.tap(del.center, at: 1.1)
        h.run(until: 2.0)
        #expect(log.take() == ["delete", "shown false"])
        #expect(h.window.services.presentations.isEmpty)
    }

    @Test func contentBelowAPresentationTakesNoPresses() {
        let log = Log()
        struct Probe: View {
            let log: Log
            @State var shown = false
            var body: some View {
                VStack {
                    Button("Open") { shown = true }
                    Button("Below") { log("below") }
                }
                .sheet(isPresented: $shown) { Text("Sheet") }
            }
        }
        let h = Harness(size: CGSize(width: 800, height: 600)) { Probe(log: log) }
        guard let open = frameOfText("Open", h.window.graph), let below = frameOfText("Below", h.window.graph) else {
            Issue.record("buttons"); return
        }
        h.tap(open.center, at: 1.0)
        h.run(until: 1.6)
        h.tap(CGPoint(x: 10, y: below.midY), at: 1.7)
        h.tap(CGPoint(x: 790, y: 590), at: 1.8)
        #expect(log.take().isEmpty)
    }

    @Test func popoverOpensAPopUpWindowAndClosesWithTheBinding() {
        @MainActor final class Box { var b: Binding<Bool>? }
        let box = Box()
        struct Probe: View {
            let box: Box
            @State var shown = false
            var body: some View {
                box.b = $shown
                return Text("Anchor").popover(isPresented: $shown) { Text("Popover content") }
            }
        }
        let h = Harness(size: CGSize(width: 600, height: 400)) { Probe(box: box) }
        box.b?.wrappedValue = true
        h.run(until: 1.0)
        let popups = h.host.windows.filter(\.isPopup)
        #expect(popups.count == 1)
        box.b?.wrappedValue = false
        h.run(until: 1.5)
        #expect(h.host.windows.allSatisfy { !$0.isPopup })
    }

    @Test func presentationsTakeThePresentersEnvironment() {
        struct Probe: View {
            @State var shown = true
            var body: some View {
                Color.white.alert("Dark", isPresented: $shown) { Button("OK") {} }
                    .environment(\.colorScheme, .dark)
            }
        }
        let h = Harness(size: CGSize(width: 600, height: 400)) { Probe() }
        h.run(until: 1.0)
        var scheme: ColorScheme?
        h.window.graph.root?.forEachNode { n in if scheme == nil, n.view is AlertCard { scheme = n.environment.colorScheme } }
        #expect(scheme == .dark)
    }
}
