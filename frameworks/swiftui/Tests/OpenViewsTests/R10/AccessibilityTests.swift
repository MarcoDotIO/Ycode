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

// T-AX (10-plan.md §3.2): the element list of the reference's `a11y` screen
// (08 §2): labels, values, hints and traits; decorative and hidden elements
// left out; `.combine` joins labels with ", ". Then actions, containers,
// controls and the menu bar.

@MainActor
final class AXLog {
    static let shared = AXLog()
    var entries: [String] = []
}

/// The `a11y` screen of 08 §2 (our reconstruction from the table).
struct A11yScreen: View {
    @State var wifi = true
    @State var volume = 0.3
    @State var count = 2
    @State var text = "typed"

    var body: some View {
        VStack(spacing: 4) {
            Text("Heading").font(.title).accessibilityAddTraits(.isHeader)
            Button("Save") { AXLog.shared.entries.append("save") }.accessibilityHint("Saves the document")
            Image(systemName: "star.fill")
            Image(systemName: "trash").accessibilityLabel("Delete")
            Image(decorative: "ornament")
            Toggle("Wi-Fi", isOn: $wifi)
            Slider(value: $volume)
            Stepper("Count", value: $count)
            HStack {
                Text("Combined")
                Text("children")
            }
            .accessibilityElement(children: .combine)
            Text("Hidden").accessibilityHidden(true)
            Text("Identified").accessibilityIdentifier("probe.id")
            Link("Link", destination: URL(string: "https://example.org")!)
            TextField("Field", text: $text)
            ProgressView(value: 0.4)
        }
    }
}

@MainActor
@Suite("R10 accessibility tree (T-AX)")
struct AccessibilityTests {
    func tree(_ h: Harness) -> AccessibilityElement { h.window.accessibilityTree(title: "Probe") }

    @Test func theReferenceScreen() {
        let h = Harness(size: CGSize(width: 400, height: 800)) { A11yScreen() }
        let root = tree(h)
        #expect(root.role == .window && root.label == "Probe")
        let e = root.exposedElements
        let summary = e.map { el -> String in
            var s = el.label ?? "-"
            if let v = el.value { s += "=\(v)" }
            return s + " [" + AccessibilityTree.traitNames(el.traits).joined(separator: "+") + "]"
        }
        // 08 §2's rows in order (the stepper is Ycode's, open question 6).
        #expect(summary == [
            "Heading [header+staticText]",
            "Save [button]",
            "Favorite [image]",
            "Delete [image]",
            "Wi-Fi=1 [button+toggle]",
            "-=30% []",
            "Count []",
            "Combined, children [staticText]",
            "Identified [staticText]",
            "Link [link]",
            "-=typed []",
            "-=40% [updatesFrequently]",
        ])
        #expect(e[1].hint == "Saves the document")
        #expect(e[8].identifier == "probe.id")
        #expect(e.map(\.role) == [.staticText, .button, .image, .image, .toggle, .slider, .stepper, .staticText, .staticText,
                                  .link, .textField, .progressIndicator])
        #expect(e[5].actionNames == ["increment", "decrement"])
        #expect(e[1].actionNames == ["default"])
        // Frames are window points of the laid-out views.
        let heading = h.frame { ($0 as? Text)?.plainString == "Heading" }
        #expect(heading == e[0].frame)
    }

    @Test func actionsRunTheControls() {
        let h = Harness(size: CGSize(width: 400, height: 800)) { A11yScreen() }
        AXLog.shared.entries = []
        let e = tree(h).exposedElements
        #expect(AccessibilityTree.perform("default", on: e[1].id, in: h.window))
        #expect(AXLog.shared.entries == ["save"])
        #expect(AccessibilityTree.perform("default", on: e[4].id, in: h.window))
        #expect(AccessibilityTree.perform("increment", on: e[5].id, in: h.window))
        #expect(AccessibilityTree.perform("increment", on: e[6].id, in: h.window))
        let after = tree(h).exposedElements
        #expect(after[4].value == "0")
        #expect(after[5].value == "40%")
        #expect(!AccessibilityTree.perform("nothing", on: e[1].id, in: h.window))
    }

    @Test func ignoreContainSortAndLabels() {
        let h = Harness {
            VStack {
                HStack { Text("A"); Text("B") }
                    .accessibilityElement()
                    .accessibilityLabel("Pair")
                    .accessibilityValue("2")
                VStack {
                    Text("Low").accessibilitySortPriority(-1)
                    Text("High").accessibilitySortPriority(1)
                    Text("Mid")
                }
                .accessibilityElement(children: .contain)
                Label("Files", systemImage: "folder")
                Image(systemName: "gear")
                Button { } label: { Image(systemName: "plus") }
                Text("Custom").accessibilityAction(named: "Pin") { AXLog.shared.entries.append("pin") }
            }
        }
        let root = tree(h)
        let top = root.children.flatMap { $0.role == .group && $0.label == nil ? $0.children : [$0] }
        let pair = root.flattened.first { $0.label == "Pair" }
        #expect(pair?.value == "2" && pair?.children.isEmpty == true)
        let group = root.flattened.first { $0.role == .group && $0.children.count == 3 }
        #expect(group?.children.map(\.label) == ["High", "Mid", "Low"])
        let labels = root.exposedElements.compactMap(\.label)
        // A label reads its title only; symbols have Ycode's default labels;
        // an image-only button takes the image's label.
        #expect(labels.contains("Files") && !labels.contains("Folder"))
        #expect(labels.contains("Settings") && labels.contains("Add"))
        let custom = root.flattened.first { $0.label == "Custom" }
        #expect(custom?.actionNames == ["Pin"])
        AXLog.shared.entries = []
        if let id = custom?.id { AccessibilityTree.perform("Pin", on: id, in: h.window) }
        #expect(AXLog.shared.entries == ["pin"])
        _ = top
    }

    @Test func listsAndSelectionAndSuspendedPages() {
        let h = Harness {
            NavigationStack {
                List(["One", "Two"], id: \.self, selection: .constant(Set(["Two"]))) { Text($0) }
            }
        }
        let root = tree(h)
        guard let list = root.flattened.first(where: { $0.role == .list }) else { Issue.record("list"); return }
        #expect(list.children.map(\.role) == [.row, .row])
        #expect(list.children.map(\.label) == ["One", "Two"])
        #expect(list.children.map { $0.traits.contains(.isSelected) } == [false, true])
    }

    @Test func theMenuBarAndToolbarAreElements() {
        let h = CommandsHarness { Text("Doc").toolbar { ToolbarItem { Button("Run") {} } } }
        let root = h.main.accessibilityTree(title: "Main")
        let labels = root.exposedElements.compactMap(\.label)
        #expect(labels.starts(with: ["Demo", "File", "Edit", "View", "Build", "Window", "Help"]), "\(labels)")
        #expect(labels.contains("Run") && labels.contains("Doc"))
        let bar = root.flattened.first { $0.role == .menuBar }
        #expect(bar?.children.count == 7)
        #expect(bar?.children.first?.role == .menuBarItem)
        // Opening a menu through its element's default action.
        if let file = bar?.children[1] { AccessibilityTree.perform("default", on: file.id, in: h.main) }
        #expect(h.popups.count == 1)
    }

    @Test func announcementsAreRecorded() {
        AccessibilityAnnouncements.posted = []
        AccessibilityNotification.Announcement("Saved").post()
        #expect(AccessibilityAnnouncements.posted == ["Saved"])
    }
}
