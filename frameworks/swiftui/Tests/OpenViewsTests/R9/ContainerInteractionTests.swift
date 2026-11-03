import Foundation
import OVPlatform
import OVRender
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// Round R9: list selection and keyboard, outlines and disclosure groups,
// tabs (06 §2.3), split views (06 §2.2 and Ycode's desktop panes), and the
// QA leftover of R8 (a removed spinner row stayed on screen).

struct FileNode: Identifiable, Hashable {
    let id: String
    var children: [FileNode]?
}

let sampleTree: [FileNode] = [
    FileNode(id: "Sources", children: [
        FileNode(id: "App.swift", children: nil),
        FileNode(id: "Views", children: [FileNode(id: "Row.swift", children: nil)]),
    ]),
    FileNode(id: "README.md", children: nil),
]

@MainActor
final class SelectionBox<T> {
    var binding: Binding<T>?
    var value: T { binding!.wrappedValue }
}

@MainActor
@Suite("R9 container interaction")
struct ContainerInteractionTests {
    struct SelectableList: View {
        let box: SelectionBox<Set<Int>>
        @State private var selection: Set<Int> = []
        var body: some View {
            box.binding = $selection
            return List(0..<20, id: \.self, selection: $selection) { i in Text("Item \(i)") }
                .listStyle(.plain)
        }
    }

    func rowCenter(_ i: Int, _ h: Harness) -> CGPoint? { frameOfText("Item \(i)", h.window.graph)?.center }

    @Test func clicksSelectAndModifiersExtend() {
        let box = SelectionBox<Set<Int>>()
        let h = Harness(size: CGSize(width: 400, height: 600)) { SelectableList(box: box) }
        guard let r2 = rowCenter(2, h), let r5 = rowCenter(5, h), let r7 = rowCenter(7, h) else { Issue.record("rows"); return }
        h.tap(r2, at: 1.0)
        #expect(box.value == [2])
        // Shift-click extends from the last clicked row; Ctrl toggles.
        h.backend.post(.pointer(PointerEvent(window: h.windowID, pointer: 0, kind: .mouse, phase: .down, location: r5, button: 1,
                                             isPressed: true, modifiers: .shift, timestamp: 1.2)), at: 1.2)
        h.backend.post(.pointer(PointerEvent(window: h.windowID, pointer: 0, kind: .mouse, phase: .up, location: r5, button: 1,
                                             isPressed: false, modifiers: .shift, timestamp: 1.25)), at: 1.25)
        h.run(until: 1.3)
        #expect(box.value == [2, 3, 4, 5])
        h.backend.post(.pointer(PointerEvent(window: h.windowID, pointer: 0, kind: .mouse, phase: .down, location: r7, button: 1,
                                             isPressed: true, modifiers: .control, timestamp: 1.5)), at: 1.5)
        h.backend.post(.pointer(PointerEvent(window: h.windowID, pointer: 0, kind: .mouse, phase: .up, location: r7, button: 1,
                                             isPressed: false, modifiers: .control, timestamp: 1.55)), at: 1.55)
        h.run(until: 1.6)
        #expect(box.value == [2, 3, 4, 5, 7])
        // The list has the keyboard after a click: Down moves, Shift+Down
        // extends.
        h.key(.downArrow, at: 2.0)
        #expect(box.value == [8])
        h.key(.downArrow, modifiers: .shift, at: 2.1)
        #expect(box.value == [8, 9])
        h.key(.home, at: 2.2)
        #expect(box.value == [0])
    }

    @Test func keyboardSelectionScrollsTheRowIntoView() {
        let box = SelectionBox<Set<Int>>()
        let h = Harness(size: CGSize(width: 400, height: 300)) { SelectableList(box: box) }
        guard let r0 = rowCenter(0, h) else { Issue.record("rows"); return }
        h.tap(r0, at: 1.0)
        h.key(.end, at: 1.2)
        h.run(until: 1.5)
        #expect(box.value == [19])
        let f = frameOfText("Item 19", h.window.graph)
        #expect(f.map { $0.maxY <= 300.01 && $0.minY > 200 } == true)
    }

    struct Outline: View {
        let box: SelectionBox<String?>
        @State private var selection: String?
        var body: some View {
            box.binding = $selection
            return List(sampleTree, children: \.children, selection: $selection) { node in Text(node.id) }
                .listStyle(.sidebar)
        }
    }

    @Test func outlineRowsExpandWithTheChevronAndTheArrowKeys() {
        let box = SelectionBox<String?>()
        let h = Harness(size: CGSize(width: 300, height: 400)) { Outline(box: box) }
        #expect(frameOfText("Sources", h.window.graph) != nil)
        #expect(frameOfText("App.swift", h.window.graph) == nil)      // collapsed by default
        guard let sources = frameOfText("Sources", h.window.graph) else { return }
        // The chevron sits before the label.
        h.tap(CGPoint(x: sources.minX - 10, y: sources.midY), at: 1.0)
        h.run(until: 1.2)
        #expect(frameOfText("App.swift", h.window.graph) != nil)
        #expect(frameOfText("Row.swift", h.window.graph) == nil)
        // Select "Views", Right expands it, Left collapses it, Left again
        // goes to its parent.
        guard let views = frameOfText("Views", h.window.graph) else { Issue.record("Views"); return }
        h.tap(views.center, at: 1.4)
        #expect(box.value == "Views")
        h.key(.rightArrow, at: 1.6)
        h.run(until: 1.7)
        #expect(frameOfText("Row.swift", h.window.graph) != nil)
        h.key(.rightArrow, at: 1.8)
        #expect(box.value == "Row.swift")                             // Right on an expanded row: first child
        h.key(.leftArrow, at: 1.9)
        #expect(box.value == "Views")                                 // Left on a leaf: the parent
        h.key(.leftArrow, at: 2.0)
        h.run(until: 2.1)
        #expect(frameOfText("Row.swift", h.window.graph) == nil)      // collapsed
        h.key(.leftArrow, at: 2.2)
        #expect(box.value == "Sources")
    }

    @Test func disclosureGroupOutsideAListTogglesItsContent() {
        let h = Harness(size: CGSize(width: 300, height: 300)) {
            DisclosureGroup("Details") { Text("Hidden detail") }
        }
        #expect(frameOfText("Hidden detail", h.window.graph) == nil)
        guard let label = frameOfText("Details", h.window.graph) else { Issue.record("label"); return }
        h.tap(label.center, at: 1.0)
        h.run(until: 1.5)
        #expect(frameOfText("Hidden detail", h.window.graph) != nil)
    }

    @Test func tabsAreBuiltWhenSelectedAndAppearBeforeTheOldOneDisappears() {
        let log = Log()
        let box = SelectionBox<Int>()
        struct Tabs: View {
            let log: Log
            let box: SelectionBox<Int>
            @State private var tab = 0
            var body: some View {
                box.binding = $tab
                return TabView(selection: $tab) {
                    Tab("One", systemImage: "star", value: 0) {
                        Text("first").onAppear { log("0 appear") }.onDisappear { log("0 disappear") }
                    }
                    Tab("Two", systemImage: "gear", value: 1) {
                        Text("second").onAppear { log("1 appear") }.onDisappear { log("1 disappear") }
                    }
                }
            }
        }
        let h = Harness(size: CGSize(width: 382, height: 644)) { Tabs(log: log, box: box) }
        #expect(log.take() == ["0 appear"])                           // only the selected tab
        box.binding?.wrappedValue = 1
        h.run(until: 1.0)
        #expect(log.take() == ["1 appear", "0 disappear"])            // 06 §2.3 order
        box.binding?.wrappedValue = 0
        h.run(until: 1.5)
        #expect(log.take() == ["0 appear", "1 disappear"])
        // Content is laid out under the floating bar (full height).
        let first = h.frame { ($0 as? Text)?.plainString == "first" }
        #expect(first.map { abs($0.midY - 322) < 1 } == true)
    }

    struct CollapsedSplit: View {
        let log: Log
        let box: SelectionBox<Int?>
        @State private var selection: Int?
        var body: some View {
            box.binding = $selection
            return NavigationSplitView {
                List(0..<3, id: \.self, selection: $selection) { i in Text("Row \(i)") }
                    .onAppear { log("sidebar appear") }
                    .onDisappear { log("sidebar disappear") }
            } detail: {
                Text("Detail \(selection ?? -1)")
                    .onAppear { log("detail appear") }
                    .onDisappear { log("detail disappear") }
            }
        }
    }

    @Test func compactSplitViewCollapsesToAStack() {
        let log = Log(), box = SelectionBox<Int?>()
        let h = phoneHarness { CollapsedSplit(log: log, box: box) }
        // 06 §2.2: the sidebar first.
        #expect(log.take() == ["sidebar appear"])
        box.binding?.wrappedValue = 1
        h.run(until: 0.7)
        #expect(log.take() == ["detail appear"])                      // at once
        h.run(until: 1.4)
        #expect(log.take() == ["sidebar disappear"])                  // at the end of the push
        box.binding?.wrappedValue = nil
        h.run(until: 1.45)
        #expect(log.take() == ["sidebar appear"])
        h.run(until: 2.2)
        #expect(log.take() == ["detail disappear"])
        box.binding?.wrappedValue = 2
        h.run(until: 3.0)
        #expect(log.take() == ["detail appear", "sidebar disappear"])
        // Back (the bar's back button) clears the selection.
        h.tap(CGPoint(x: 30, y: 22), at: 3.2)
        h.run(until: 4.0)
        #expect(box.value == nil)
    }

    @Test func regularSplitViewHasResizableColumns() {
        let h = Harness(size: CGSize(width: 1000, height: 600)) {
            NavigationSplitView {
                Color.red
            } content: {
                Color.green
            } detail: {
                Color.blue
            }
        }
        let side = h.frame(of: .red), content = h.frame(of: .green), detail = h.frame(of: .blue)
        #expect(side?.width == 240 && content?.width == 280)
        #expect(detail.map { abs($0.width - (1000 - 240 - 280 - 2)) < 0.01 } == true)
        // Drag the first divider 60 points right: the sidebar grows, the
        // content column shrinks.
        guard let s = side else { return }
        h.drag(from: CGPoint(x: s.maxX + 0.5, y: 300), delta: CGSize(width: 6, height: 0), steps: 10, at: 1.0)
        h.run(until: 1.3)
        #expect(h.frame(of: .red)?.width == 300)
        #expect(h.frame(of: .green)?.width == 220)
    }

    @Test func hSplitViewDividerRespectsPaneLimits() {
        let h = Harness(size: CGSize(width: 600, height: 300)) {
            HSplitView {
                Color.red.frame(minWidth: 100, idealWidth: 200, maxWidth: 300)
                Color.blue.frame(minWidth: 150)
            }
        }
        #expect(h.frame(of: .red)?.width == 200)
        #expect(h.frame(of: .blue)?.width == 399)
        guard let r = h.frame(of: .red) else { return }
        // Past the maximum: stops at 300.
        h.drag(from: CGPoint(x: r.maxX + 0.5, y: 150), delta: CGSize(width: 20, height: 0), steps: 10, at: 1.0)
        h.run(until: 1.3)
        #expect(h.frame(of: .red)?.width == 300)
        #expect(h.frame(of: .blue)?.width == 299)
    }

    @Test func removedSpinnerRowDoesNotStayOnScreen() {
        // R8 QA leftover (the dark settings screenshot): "Syncing…" and its
        // spinner, replaced without animation, stayed drawn over the "Sync"
        // row because the spinner's endless animation kept the removed row
        // as a removal ghost.
        @MainActor final class Flag { var b: Binding<Bool>? }
        let flag = Flag()
        struct Status: View {
            let flag: Flag
            @State var syncing = true
            var body: some View {
                flag.b = $syncing
                return Form {
                    Section("Status") {
                        if syncing {
                            HStack { ProgressView(); Text("Syncing…") }
                        } else {
                            ProgressView("Sync", value: 2, total: 4)
                        }
                    }
                }
            }
        }
        let h = Harness(size: CGSize(width: 400, height: 300)) { Status(flag: flag) }
        h.run(until: 1.0)
        flag.b?.wrappedValue = false
        h.run(until: 1.5)
        #expect(h.window.graph.ghosts.isEmpty)
        let list = h.window.graph.displayList()
        var glyphRuns = 0
        func walk(_ items: [DisplayItem]) {
            for i in items {
                switch i.content {
                case .glyphs: glyphRuns += 1
                case .group(let g): walk(g.children)
                default: break
                }
            }
        }
        walk(list.items)
        // "Status", "Sync" and nothing else.
        #expect(glyphRuns == 2)
    }
}
