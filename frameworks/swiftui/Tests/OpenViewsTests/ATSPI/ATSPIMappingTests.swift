import Foundation
@testable import OVAccessibilityATSPI
import OVPlatform
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// OV-ATSPI: OpenViews roles and traits onto AT-SPI roles, states,
// interfaces and actions (the README's table), and the bridge's requests
// (actions, focus, text edits, values, selection) on a headless app.

struct ProbeFile: Identifiable, Hashable {
    let id: String
    var children: [ProbeFile]?
}

@MainActor
final class ATSPIProbeLog {
    static let shared = ATSPIProbeLog()
    var builds = 0
}

struct ATSPIProbeView: View {
    @State var selection: String?
    @State var wifi = true
    @State var volume = 0.3
    @State var count = 2
    @State var name = "Ycode"
    @State var source = "let x = 1"
    let tree = [ProbeFile(id: "Sources", children: [ProbeFile(id: "App.swift", children: nil)]), ProbeFile(id: "README.md", children: nil)]

    var body: some View {
        HStack(spacing: 0) {
            List(tree, children: \.children, selection: $selection) { item in Text(item.id) }
                .frame(width: 200)
            VStack(spacing: 4) {
                Text("Settings").font(.title).accessibilityHeading(.h1)
                Button("Build") { ATSPIProbeLog.shared.builds += 1 }.accessibilityHint("Builds the project")
                Toggle("Wi-Fi", isOn: $wifi)
                Slider(value: $volume)
                Stepper("Count", value: $count)
                TextField("Name", text: $name)
                SecureField("Password", text: .constant("pw"))
                TextEditor(text: $source).frame(height: 80)
                ProgressView(value: 0.4)
                Link("Docs", destination: URL(string: "https://example.org")!)
                Image(systemName: "trash").accessibilityLabel("Delete").accessibilityIdentifier("trash.icon")
            }
        }
    }
}

@MainActor
@Suite("OV-ATSPI role and state mapping")
struct ATSPIMappingTests {
    func setUp() -> (CommandsHarness, AccessibilityExport, String) {
        let h = CommandsHarness(menuBar: true) { ATSPIProbeView() }
        let e = AccessibilityExport(host: h.host)
        return (h, e, e.key(of: h.main))
    }

    func nodes(_ e: AccessibilityExport, _ w: String) -> [ATSPINode] {
        guard let s = e.snapshot(ofWindow: w) else { return [] }
        return s.orderedKeys.compactMap { s.nodes[$0] }
    }

    func find(_ n: [ATSPINode], _ role: ATSPIRole, _ name: String? = nil) -> ATSPINode? {
        n.first { $0.role == role && (name == nil || $0.name == name) }
    }

    @Test func rolesFollowTheTable() {
        let (h, e, w) = setUp()
        let n = nodes(e, w)
        let window = n.first!
        #expect(window.key == w && window.role == .frame && window.name == "Main")
        #expect(window.states.contains(.active) && window.states.contains(.resizable) && window.states.contains(.showing))
        #expect(find(n, .menuBar) != nil)
        #expect(find(n, .menu, "File") != nil && find(n, .menu, "Edit") != nil)
        #expect(find(n, .heading, "Settings")?.attributes["level"] == "1")
        let build = find(n, .pushButton, "Build")
        #expect(build?.description == "Builds the project")
        #expect(build?.actions.map(\.name) == ["click"])
        #expect(build?.states.contains(.focusable) == true && build?.states.contains(.enabled) == true)
        let toggle = find(n, .toggleButton, "Wi-Fi")
        #expect(toggle?.states.contains(.checkable) == true && toggle?.states.contains(.checked) == true)
        let slider = find(n, .slider)
        #expect(slider?.value?.current == 0.3 && slider?.value?.maximum == 1 && slider?.value?.isSettable == true)
        #expect(slider?.actions.map(\.name) == ["increment", "decrement"])
        #expect(find(n, .spinButton, "Count")?.actions.map(\.name) == ["increment", "decrement"])
        let field = find(n, .entry)
        #expect(field?.text?.string == "Ycode" && field?.text?.isEditable == true)
        #expect(field?.states.contains(.singleLine) == true && field?.states.contains(.editable) == true)
        #expect(field?.interfaces.contains(ATSPI.editableText) == true)
        #expect(find(n, .passwordText)?.text?.string == "\u{2022}\u{2022}")
        let editor = find(n, .text)
        #expect(editor?.text?.string == "let x = 1" && editor?.states.contains(.multiLine) == true)
        let progress = find(n, .progressBar)
        #expect(progress?.value?.current == 40 && progress?.value?.isSettable == false)
        #expect(find(n, .link, "Docs")?.actions.map(\.name) == ["click"])
        let image = find(n, .image, "Delete")
        #expect(image?.identifier == "trash.icon")
        // The outline is a tree of tree items; folders expand.
        let tree = find(n, .tree)
        #expect(tree?.isSelectionContainer == true)
        #expect(tree?.interfaces.contains(ATSPI.selection) == true)
        let folder = find(n, .treeItem, "Sources")
        #expect(folder?.states.contains(.expandable) == true && folder?.states.contains(.collapsed) == true)
        #expect(folder?.actions.map(\.name) == ["activate", "expand or collapse"])
        #expect(find(n, .treeItem, "README.md")?.states.contains(.expandable) == false)
        // Parents and indices are filled in; every key belongs to the window.
        let s = e.snapshot(ofWindow: w)!
        for k in s.orderedKeys where k != w {
            #expect(k.hasPrefix(w + "_"))
            #expect(s.nodes[k]?.parent != nil)
        }
        _ = h
    }

    @Test func requestsRunOnTheElements() {
        let (h, e, w) = setUp()
        var n = nodes(e, w)
        // Click Build.
        let build = find(n, .pushButton, "Build")!
        ATSPIProbeLog.shared.builds = 0
        #expect(e.performAction(0, on: build.key))
        #expect(ATSPIProbeLog.shared.builds == 1)
        // Toggle Wi-Fi off.
        #expect(e.performAction(0, on: find(n, .toggleButton, "Wi-Fi")!.key))
        n = nodes(e, w)
        #expect(find(n, .toggleButton, "Wi-Fi")?.states.contains(.checked) == false)
        // Set the slider; increment the stepper.
        #expect(e.setValue(0.75, on: find(n, .slider)!.key))
        #expect(e.performAction(0, on: find(n, .spinButton)!.key))
        n = nodes(e, w)
        #expect(find(n, .slider)?.value?.current == 0.75)
        // Focus the text field, edit it, move the caret.
        let field = find(n, .entry)!
        #expect(e.grabFocus(field.key))
        n = nodes(e, w)
        let focused = n.filter { $0.states.contains(.focused) }
        #expect(focused.map(\.key) == [field.key])
        #expect(e.replaceText(in: 5..<5, with: " IDE", on: field.key))
        #expect(e.setSelection(2..<2, on: field.key))
        n = nodes(e, w)
        #expect(find(n, .entry)?.text?.string == "Ycode IDE")
        #expect(find(n, .entry)?.text?.caret == 2)
        #expect(e.setText("Open", on: field.key))
        #expect(find(nodes(e, w), .entry)?.text?.string == "Open")
        // Select a tree row through the Selection interface; expand a folder.
        let tree = find(n, .tree)!
        let names = Dictionary(uniqueKeysWithValues: n.map { ($0.key, $0.name) })
        let readme = tree.children.firstIndex { names[$0] == "README.md" }!
        #expect(e.selectChild(readme, of: tree.key))
        n = nodes(e, w)
        #expect(find(n, .treeItem, "README.md")?.states.contains(.selected) == true)
        #expect(e.performAction(1, on: find(n, .treeItem, "Sources")!.key))
        h.run(until: h.now + 0.5)
        n = nodes(e, w)
        #expect(find(n, .treeItem, "Sources")?.states.contains(.expanded) == true)
        #expect(find(n, .treeItem, "App.swift") != nil)
    }

    @Test func revisionsChangeOnlyWithTheTree() {
        let (h, e, w) = setUp()
        let r0 = e.revision(ofWindow: w)
        h.run(until: h.now + 0.5)
        #expect(e.revision(ofWindow: w) == r0)
        let n = nodes(e, w)
        _ = e.performAction(0, on: find(n, .toggleButton, "Wi-Fi")!.key)
        h.run(until: h.now + 0.5)
        #expect(e.revision(ofWindow: w) != r0)
        #expect(e.windowKeys() == [w])
        #expect(e.revision(ofWindow: "w99") == -1)
    }

    @Test func stateSetsUseTwoWords() {
        var s = ATSPIStateSet([.enabled, .focused, .showing, .visible, .readOnly])
        #expect(s.words == [1 << 8 | 1 << 12 | 1 << 25 | 1 << 30, 1 << (43 - 32)])
        #expect(ATSPIStateSet(words: s.words) == s)
        s.remove(.focused)
        #expect(!s.contains(.focused))
        #expect(ATSPIState.multiLine.eventName == "multi-line" && ATSPIState.focused.eventName == "focused")
        #expect(ATSPIState.readOnly.rawValue == 43 && ATSPIState.selectableText.rawValue == 38)
        #expect(ATSPIRole.pushButton.rawValue == 43 && ATSPIRole.frame.rawValue == 23 && ATSPIRole.entry.rawValue == 79)
        #expect(ATSPIRole.application.rawValue == 75 && ATSPIRole.treeItem.rawValue == 91)
    }

    @Test func textSegments() {
        let s = Array("Hello brave world\nsecond line".unicodeScalars)
        #expect(TextSegments.range(s, at: 7, boundary: .wordStart) == 6..<12)
        #expect(TextSegments.range(s, at: 0, boundary: .wordStart) == 0..<6)
        #expect(TextSegments.range(s, at: 3, boundary: .lineStart) == 0..<18)
        #expect(TextSegments.range(s, at: 20, boundary: .lineStart) == 18..<29)
        #expect(TextSegments.range(s, at: 4, boundary: .character) == 4..<5)
        #expect(TextSegments.range(s, at: 29, boundary: .character) == 29..<29)
    }
}
