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

// Focus, hardware-keyboard text input and key commands (06 §5): programmatic
// focus through `@FocusState`, a tap focusing a field, typed keys inserted
// (with the reference's auto-capitalisation on the headless host: "Hi"),
// Return running `onSubmit` and removing focus, Tab order, editing keys,
// clipboard paste, input-method composition, keyboard shortcuts.

enum FormField: Hashable { case name, email }

struct FormView: View {
    let log: EventLog
    var autocapitalization: TextInputAutocapitalization?
    @State private var name = ""
    @State private var email = ""
    @FocusState private var focus: FormField?

    var body: some View {
        VStack(spacing: 10) {
            TextField("Name", text: $name)
                .focused($focus, equals: .name)
                .onSubmit { log.add("submit \(name)") }
                .frame(width: 200)
            TextField("Email", text: $email)
                .focused($focus, equals: .email)
                .frame(width: 200)
            Button { focus = .email } label: { Color.red.frame(width: 40, height: 20) }
            Button { log.add("save") } label: { Color.blue.frame(width: 40, height: 20) }
                .keyboardShortcut("s")
            Button { log.add("disabled") } label: { Color.green.frame(width: 40, height: 20) }
                .keyboardShortcut("d")
                .disabled(true)
        }
        .textInputAutocapitalization(autocapitalization)
        .onChange(of: focus) { _, f in log.add("focus \(f.map { "\($0)" } ?? "nil")") }
        .onChange(of: name) { _, n in log.add("name \(n)") }
        .onChange(of: email) { _, n in log.add("email \(n)") }
    }
}

@MainActor
@Suite("R7 focus and keyboard")
struct FocusKeyboardTests {
    private func fieldState(_ h: Harness, _ index: Int) -> TextFieldState? {
        var found: [TextFieldState] = []
        h.window.graph.root?.forEachNode { n in if let s = n.primitiveState as? TextFieldState { found.append(s) } }
        return found.indices.contains(index) ? found[index] : nil
    }

    private func fieldFrame(_ h: Harness, _ index: Int) -> CGRect? {
        var frames: [CGRect] = []
        h.window.graph.root?.forEachNode { n in
            if n.primitiveState is TextFieldState, let f = HitTesting.frame(of: n, mirrorWidth: nil) { frames.append(f) }
        }
        return frames.indices.contains(index) ? frames[index] : nil
    }

    private var platformWindow: (Harness) -> HeadlessWindow? { { $0.window.platform as? HeadlessWindow } }

    @Test func programmaticFocusAndTextInputState() {
        let log = EventLog()
        let h = Harness { FormView(log: log) }
        #expect(platformWindow(h)?.isTextInputActive == false)
        guard let red = h.frame(of: .red) else {
            Issue.record("frame")
            return
        }
        h.tap(red.center, at: 1.0)
        h.run(until: 1.1)
        #expect(log.entries == ["focus email"])
        #expect(fieldState(h, 1)?.isFocused == true)
        #expect(platformWindow(h)?.isTextInputActive == true)
    }

    @Test func tapTypeAndSubmit() {
        let log = EventLog()
        let h = Harness { FormView(log: log) }
        guard let f = fieldFrame(h, 0) else {
            Issue.record("frame")
            return
        }
        h.tap(f.center, at: 1.0)
        h.run(until: 1.1)
        #expect(log.entries == ["focus name"])
        // Keys h, i → "H", "Hi" (06 §5, with the reference's capitalisation).
        h.type("hi", at: 1.2)
        h.run(until: 1.4)
        #expect(log.entries == ["focus name", "name H", "name Hi"])
        h.key(.return, at: 1.5)
        h.run(until: 1.6)
        #expect(log.entries == ["focus name", "name H", "name Hi", "submit Hi", "focus nil"])
        #expect(platformWindow(h)?.isTextInputActive == false)
    }

    @Test func desktopTextInputDoesNotCapitalise() {
        let log = EventLog()
        let h = Harness { FormView(log: log, autocapitalization: .never) }
        guard let f = fieldFrame(h, 0) else {
            Issue.record("frame")
            return
        }
        h.tap(f.center, at: 1.0)
        h.type("hi there", at: 1.2)
        h.run(until: 2.0)
        #expect(log.entries.last == "name hi there")
    }

    @Test func tabOrderAndEditingKeys() {
        let log = EventLog()
        let h = Harness { FormView(log: log, autocapitalization: .never) }
        guard let f = fieldFrame(h, 0) else {
            Issue.record("frame")
            return
        }
        h.tap(f.center, at: 1.0)
        h.type("abc", at: 1.1)
        h.key(.backspace, at: 1.4)
        h.key(.leftArrow, at: 1.45)
        h.type("x", at: 1.5)
        h.run(until: 1.7)
        #expect(log.entries.last == "name axb")
        h.key(.tab, at: 1.8)
        h.run(until: 1.9)
        #expect(log.entries.last == "focus email")
        h.key(.tab, modifiers: .shift, at: 2.0)
        h.run(until: 2.1)
        #expect(log.entries.last == "focus name")
        h.key(.escape, at: 2.2)
        h.run(until: 2.3)
        #expect(log.entries.last == "focus nil")
    }

    @Test func pasteAndComposition() {
        let log = EventLog()
        let h = Harness { FormView(log: log, autocapitalization: .never) }
        guard let f = fieldFrame(h, 0) else {
            Issue.record("frame")
            return
        }
        h.tap(f.center, at: 1.0)
        h.backend.clipboard.text = "pasted"
        h.key(.character("v"), modifiers: .control, at: 1.2)
        h.run(until: 1.3)
        #expect(log.entries.last == "name pasted")
        // An input method's marked text shows in the field without changing
        // the bound string; the committed text replaces it.
        h.backend.post(.textEditing(TextEditingEvent(window: h.windowID, text: "にほ", cursor: 2, timestamp: 1.4)), at: 1.4)
        h.run(until: 1.45)
        #expect(fieldState(h, 0)?.marked == "にほ")
        #expect(log.entries.last == "name pasted")
        h.backend.post(.textInput(TextInputEvent(window: h.windowID, text: "日本", timestamp: 1.5)), at: 1.5)
        h.run(until: 1.6)
        #expect(fieldState(h, 0)?.marked == "")
        #expect(log.entries.last == "name pasted日本")
        // Ctrl+C copies the selection (R8; select all first).
        h.backend.clipboard.text = ""
        h.key(.character("a"), modifiers: .control, at: 1.65)
        h.key(.character("c"), modifiers: .control, at: 1.7)
        #expect(h.backend.clipboard.text == "pasted日本")
    }

    @Test func keyboardShortcuts() {
        let log = EventLog()
        let h = Harness { FormView(log: log, autocapitalization: .never) }
        // Ctrl+S (`.command` maps to Ctrl on Linux) runs the button; a
        // disabled button's shortcut does nothing.
        h.key(.character("s"), modifiers: .control, at: 1.0)
        h.key(.character("d"), modifiers: .control, at: 1.1)
        h.run(until: 1.2)
        #expect(log.entries == ["save"])
        // Typing "s" into a focused field is text, not the shortcut.
        guard let f = fieldFrame(h, 0) else {
            Issue.record("frame")
            return
        }
        h.tap(f.center, at: 2.0)
        h.type("s", at: 2.1)
        h.run(until: 2.3)
        #expect(log.entries == ["save", "focus name", "name s"])
        h.key(.character("s"), modifiers: .control, at: 2.4)
        #expect(log.entries.last == "save")
    }

    @Test func shortcutMatching() {
        let cmdS = KeyboardShortcut("s")
        #expect(cmdS.matches(key: "s", modifiers: .control))
        #expect(cmdS.matches(key: "s", modifiers: .command))
        #expect(!cmdS.matches(key: "s", modifiers: []))
        #expect(!cmdS.matches(key: "s", modifiers: [.control, .shift]))
        let shiftCmdS = KeyboardShortcut("s", modifiers: [.command, .shift])
        #expect(shiftCmdS.matches(key: "S", modifiers: [.control, .shift]))
        #expect(KeyboardShortcut.defaultAction.matches(key: .return, modifiers: []))
        #expect(KeyboardShortcut("k", modifiers: .control).matches(key: "k", modifiers: .control))
        #expect(!KeyboardShortcut("k", modifiers: .control).matches(key: "k", modifiers: .command))
        #expect(KeyEquivalent(platformKey: .backspace) == .delete)
        #expect(KeyEquivalent(platformKey: .character("A")) == "a")
    }
}
