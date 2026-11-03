import Foundation
import Observation
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

// Round R13 (docs/PARITY.md §5.8, "What OpenViews lacked"): the gaps the
// Linux IDE shell found. Custom toolbar content, submenu shortcuts in
// `commands`, `task(id:)` on a view that appears with the new ID, selection
// IDs of outline rows and initial expansion, identifiers inside list rows,
// the symbols the shell uses.

// MARK: - 1. Custom ToolbarContent

struct RunStopItems: ToolbarContent {
    let log: CommandLog
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Run") { log.add("run") }
            Button("Stop") { log.add("stop") }
        }
    }
}

struct WindowItems: ToolbarContent {
    var showsStatus: Bool
    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) { Text("Nav") }
        RunStopItems(log: CommandLog.shared)
        if showsStatus {
            ToolbarItem(placement: .principal) { Text("Status") }
        }
    }
}

// MARK: - 2. Submenus in commands

struct SubmenuCommands: Commands {
    var body: some Commands {
        CommandMenu("Tools") {
            Menu("Navigators") {
                Button("Project") { CommandLog.shared.add("project") }
                    .keyboardShortcut("1")
                Button("Find") { CommandLog.shared.add("find") }
                    .keyboardShortcut("4")
                    .disabled(true)
                Menu("Deeper") {
                    Button("Deep") { CommandLog.shared.add("deep") }
                        .keyboardShortcut("9", modifiers: [.command, .shift])
                }
            }
        }
    }
}

struct SubmenuApp: App {
    static var content: () -> AnyView = { AnyView(EmptyView()) }
    var body: some Scene {
        WindowGroup("Main") { Self.content() }
            .defaultSize(width: 800, height: 500)
            .commands { SubmenuCommands() }
    }
}

// MARK: - 3. task(id:)

@MainActor
@Observable
final class ShellLikeModel {
    var navigator = 0
    var focusRequests = 0
}

struct TaskOnAppearingView: View {
    let model: ShellLikeModel
    let log: Log

    var body: some View {
        switch model.navigator {
        case 0: Text("Project")
        default:
            Text("Find")
                .task(id: model.focusRequests) { log("task \(model.focusRequests)") }
        }
    }
}

struct FocusOnTaskView: View {
    let model: ShellLikeModel
    @FocusState private var focused: Bool
    @State private var text = ""

    var body: some View {
        VStack {
            if model.navigator == 1 {
                TextField("Query", text: $text)
                    .focused($focused)
                    .task(id: model.focusRequests) { if model.focusRequests > 0 { focused = true } }
            }
        }
    }
}

// MARK: - 4. Outline rows

struct TreeItem: Identifiable, Hashable {
    let id: String
    var children: [TreeItem]?
}

let shellTree: [TreeItem] = [
    TreeItem(id: "Greeter", children: [
        TreeItem(id: "Package.swift"),
        TreeItem(id: "Sources", children: [TreeItem(id: "main.swift"), TreeItem(id: "Greeting.swift")]),
    ]),
    TreeItem(id: "README.md"),
]

/// The shell's pattern: a `ForEach` whose rows are a `DisclosureGroup` or a
/// leaf, with no tags.
struct UntaggedOutline: View {
    let box: SelectionBox<String?>
    @State private var selection: String?
    @State private var expanded: Set<String> = ["Greeter", "Sources"]

    var body: some View {
        box.binding = $selection
        return List(selection: $selection) {
            rows(shellTree)
        }
        .listStyle(.sidebar)
    }

    func rows(_ items: [TreeItem]) -> AnyView {
        AnyView(ForEach(items) { item in
            if let kids = item.children {
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(item.id) },
                                                    set: { if $0 { expanded.insert(item.id) } else { expanded.remove(item.id) } })) {
                    rows(kids)
                } label: {
                    Text(item.id).accessibilityIdentifier("row \(item.id)")
                }
            } else {
                Text(item.id).accessibilityIdentifier("row \(item.id)")
            }
        })
    }
}

struct InitiallyExpandedOutline: View {
    let box: SelectionBox<String?>
    @State private var selection: String?
    var body: some View {
        box.binding = $selection
        return List(shellTree, children: \.children, selection: $selection) { Text($0.id) }
            .listStyle(.sidebar)
            .outlineInitialExpansion(["Greeter"] as Set<String>)
    }
}

@MainActor
@Suite("R13 shell gaps")
struct ShellGapTests {
    // 1
    @Test func customToolbarContentTypesShowTheirBodies() {
        let h = CommandsHarness(menuBar: false) {
            Text("Content")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar { WindowItems(showsStatus: true) }
        }
        guard let nav = h.textFrame("Nav"), let run = h.textFrame("Run"), let status = h.textFrame("Status") else {
            Issue.record("toolbar items")
            return
        }
        #expect(nav.minX < 60)
        #expect(abs(status.midX - 400) < 1)
        #expect(run.minX > 600)
        h.click(CGPoint(x: run.midX, y: run.midY), at: 1)
        #expect(CommandLog.shared.entries == ["run"])
        #expect(h.main.services.toolbar.entries.count == 3)
    }

    @Test func toolbarLabelsShowTheirIconsInTheWindowToolbar() {
        let h = CommandsHarness(menuBar: false) {
            Text("Content")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { CommandLog.shared.add("inspector") } label: { Label("Inspector", systemImage: "sidebar.right") }
                    }
                }
        }
        // The title stays in the accessibility tree, not on screen.
        #expect(h.textFrame("Inspector") == nil)
        let tree = AccessibilityTree.build(h.main)
        #expect(tree.flattened.contains { $0.role == .button && $0.label == "Inspector" })
    }

    // 2
    @Test func submenuShortcutsWorkBeforeTheMenuIsOpened() {
        let backend = HeadlessBackend(scale: 1)
        CommandLog.shared.entries = []
        SubmenuApp.content = { AnyView(Text("Main")) }
        let host = AppHost(SubmenuApp.self, backend: backend)
        host.makePresenter = { _ in nil }
        host.showsMenuBar = true
        host.launch()
        host.run(until: 0.5)
        let w = host.windows.first { !$0.isPopup }!
        func key(_ k: Key, _ m: KeyModifiers, _ t: TimeInterval) {
            backend.post(.key(KeyEvent(window: w.platform.id, key: k, modifiers: m, timestamp: t)), at: t)
            host.run(until: t + 0.01)
        }
        key(.character("1"), .control, 1)
        key(.character("4"), .control, 1.1)          // disabled: nothing
        key(.character("9"), [.control, .shift], 1.2) // two levels down
        #expect(CommandLog.shared.entries == ["project", "deep"])
        // No menu was opened for that.
        let anyPopup = host.windows.contains { $0.isPopup }
        #expect(!anyPopup)
    }

    @Test func theViewMenuPopupFitsItsItems() {
        // DocumentCommands adds SidebarCommands; the toolbar adds Hide
        // Toolbar: both depend on the main window, and the pop-up must be
        // measured with them (it was cut off before R13).
        let h = CommandsHarness {
            NavigationSplitView { Text("Side") } detail: { Text("Detail") }
                .toolbar { ToolbarItem(placement: .primaryAction) { Text("Item") } }
        }
        h.openMenu("View", at: 1)
        guard let p = h.popups.last else { Issue.record("no pop-up"); return }
        let items = ["Hide Toolbar", "Hide Sidebar"]
        for title in items {
            guard let f = h.textFrame(title, in: p) else { Issue.record("no \(title)"); continue }
            #expect(f.minY >= 0 && f.maxY <= p.size.height && f.maxX <= p.size.width, "\(title) \(f) in \(p.size)")
        }
    }

    // 3
    @Test func taskWithIDRunsOnAViewThatAppearsInTheSameUpdate() async {
        let log = Log()
        let model = ShellLikeModel()
        let g = ViewGraph.rendered(TaskOnAppearingView(model: model, log: log))
        #expect(log.take().isEmpty)
        // One update switches the navigator and bumps the request, as the
        // shell's Find in Workspace does.
        model.navigator = 1
        model.focusRequests = 1
        g.update()
        await waitUntil { !log.entries.isEmpty }
        #expect(log.take() == ["task 1"])
        model.focusRequests = 2
        g.update()
        await waitUntil { !log.entries.isEmpty }
        #expect(log.take() == ["task 2"])
    }

    @Test func aTaskCanFocusAFieldThatAppearedWithIt() async {
        let model = ShellLikeModel()
        let h = Harness { FocusOnTaskView(model: model) }
        model.navigator = 1
        model.focusRequests = 1
        h.run(until: 1)
        for _ in 0..<50 where h.window.services.focus.focusedClient == nil {
            try? await Task.sleep(nanoseconds: 2_000_000)
            h.run(until: h.now + 0.02)
        }
        #expect(h.window.services.focus.focusedClient != nil)
    }

    // 4
    @Test func untaggedOutlineRowsAndFoldersAreSelectable() {
        let box = SelectionBox<String?>()
        let h = Harness(size: CGSize(width: 300, height: 400)) { UntaggedOutline(box: box) }
        guard let main = frameOfText("main.swift", h.window.graph), let sources = frameOfText("Sources", h.window.graph)
        else { Issue.record("rows"); return }
        h.tap(main.center, at: 1.0)
        #expect(box.value == "main.swift")
        h.tap(sources.center, at: 1.3)
        #expect(box.value == "Sources")
        // The keyboard walks every row, folders included.
        h.key(.downArrow, at: 1.5)
        #expect(box.value == "main.swift")
        h.key(.upArrow, at: 1.6)
        h.key(.upArrow, at: 1.7)
        #expect(box.value == "Package.swift")
        h.key(.upArrow, at: 1.8)
        #expect(box.value == "Greeter")
    }

    @Test func outlinesStartExpandedWhereTheHookSays() {
        let box = SelectionBox<String?>()
        let h = Harness(size: CGSize(width: 300, height: 400)) { InitiallyExpandedOutline(box: box) }
        #expect(frameOfText("Package.swift", h.window.graph) != nil)
        #expect(frameOfText("main.swift", h.window.graph) == nil)
        // The user's choice wins afterwards.
        guard let greeter = frameOfText("Greeter", h.window.graph) else { Issue.record("Greeter"); return }
        h.tap(CGPoint(x: greeter.minX - 10, y: greeter.midY), at: 1.0)
        h.run(until: 1.3)
        #expect(frameOfText("Package.swift", h.window.graph) == nil)
    }

    // 5
    @Test func identifiersInsideListRowsReachTheTreeAndTheATSPIExport() {
        let box = SelectionBox<String?>()
        let h = CommandsHarness(menuBar: false) { UntaggedOutline(box: box) }
        let tree = AccessibilityTree.build(h.main)
        let rows = tree.flattened.filter { $0.role == .row }
        let ids = Set(rows.compactMap(\.identifier))
        #expect(ids.isSuperset(of: ["row Greeter", "row Package.swift", "row Sources", "row main.swift", "row README.md"]))
        // The identified element is the whole row.
        if let row = rows.first(where: { $0.identifier == "row main.swift" }), let text = h.textFrame("main.swift") {
            #expect(row.frame.contains(CGPoint(x: text.midX, y: text.midY)) && row.frame.width > text.width)
        }
        let export = AccessibilityExport(host: h.host)
        let key = export.key(of: h.main)
        let nodes = export.snapshot(ofWindow: key).map { s in s.orderedKeys.compactMap { s.nodes[$0] } } ?? []
        #expect(nodes.contains { $0.identifier == "row main.swift" })
    }

    // 7
    @Test func theShellsSymbolsAreDrawn() {
        for name in ["chevron.left.forwardslash.chevron.right", "folder.badge.gearshape", "square.stack.3d.up",
                     "sidebar.right", "gearshape.2", "list.bullet.rectangle"] {
            let art = SymbolArtwork.all[name]
            #expect(art != nil, "\(name)")
            #expect(art.map { !$0.operations.isEmpty } == true)
        }
    }
}
