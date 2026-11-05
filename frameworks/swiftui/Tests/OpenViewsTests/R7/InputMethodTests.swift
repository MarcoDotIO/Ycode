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

// A text field under a real input method (issue 23): the caret rectangle the
// window gives the input method follows the caret as text is typed and
// composed (the candidate window opens below it), for a text field and for a
// text surface (the Linux IDE's source editor), and the keys that reach the
// field while the input method composes do not edit, submit or unfocus it.

/// A one-line text surface: the caret is 8 points per character.
@MainActor
final class CaretSurface: TextSurfaceClient {
    var text = ""
    var origin = CGPoint(x: 20, y: 30)
    func surfaceConnected(_ connection: TextSurfaceConnection?) {}
    func surfaceInsertText(_ text: String) { self.text += text }
    func surfaceSetMarkedText(_ text: String, cursor: Int) {}
    func surfaceHandleKey(_ event: KeyEvent) -> Bool { false }
    var surfaceCaretRect: CGRect { CGRect(x: origin.x + CGFloat(text.count) * 8, y: origin.y, width: 2, height: 16) }
    func surfaceFocusChanged(_ focused: Bool) {}
    func surfaceCanPerform(_ command: TextSurfaceCommand) -> Bool { false }
    func surfacePerform(_ command: TextSurfaceCommand) {}
}

struct SurfaceView: View {
    let client: CaretSurface
    @FocusState private var focused: Bool
    var body: some View {
        Color.gray.frame(width: 300, height: 100)
            .textSurface(client)
            .focused($focused)
            .onAppear { focused = true }
    }
}

@MainActor
@Suite("R7 input method")
struct InputMethodTests {
    private func field(_ h: Harness, _ index: Int) -> (state: TextFieldState, frame: CGRect)? {
        var found: [(TextFieldState, CGRect)] = []
        h.window.graph.root?.forEachNode { n in
            if let s = n.primitiveState as? TextFieldState, let f = HitTesting.frame(of: n, mirrorWidth: nil) {
                found.append((s, f))
            }
        }
        return found.indices.contains(index) ? found[index] : nil
    }

    private func platform(_ h: Harness) -> HeadlessWindow? { h.window.platform as? HeadlessWindow }

    private func compose(_ h: Harness, _ text: String, cursor: Int, at t: TimeInterval) {
        h.backend.post(.textEditing(TextEditingEvent(window: h.windowID, text: text, cursor: cursor, timestamp: t)), at: t)
        h.run(until: t + 0.05)
    }

    @Test func candidateAreaFollowsTheCaret() throws {
        let log = EventLog()
        let h = Harness { FormView(log: log, autocapitalization: .never) }
        let f = try #require(field(h, 0))
        h.tap(f.frame.center, at: 1.0)
        h.run(until: 1.1)
        let atFocus = try #require(platform(h)?.textInputCaret)
        #expect(f.frame.contains(CGPoint(x: atFocus.minX, y: atFocus.midY)))

        // Typing moves the caret, and the area with it.
        h.type("abc", at: 1.2)
        h.run(until: 1.5)
        let typed = try #require(platform(h)?.textInputCaret)
        #expect(typed.minX > atFocus.minX + 10)
        #expect(typed == f.state.caretRect)
        #expect(h.window.textInputArea == typed)

        // Composing: the area is at the composition's cursor (its end here),
        // then after the committed text.
        compose(h, "にほ", cursor: 2, at: 1.6)
        let composing = try #require(platform(h)?.textInputCaret)
        #expect(composing.minX > typed.minX + 10)
        h.backend.post(.textInput(TextInputEvent(window: h.windowID, text: "日本", timestamp: 1.7)), at: 1.7)
        h.run(until: 1.8)
        let committed = try #require(platform(h)?.textInputCaret)
        #expect(log.entries.last == "name abc日本")
        #expect(abs(committed.minX - composing.minX) < 2)

        // The caret moved by a key: the area follows (no focus change).
        h.key(.home, at: 1.9)
        h.run(until: 2.0)
        #expect(platform(h)?.textInputCaret?.minX == atFocus.minX)

        // Focus leaves: text input stops.
        h.key(.escape, at: 2.1)
        h.run(until: 2.2)
        #expect(platform(h)?.isTextInputActive == false)
        #expect(h.window.textInputArea == nil)
    }

    @Test func compositionCursorAtItsStartKeepsTheArea() throws {
        // An input method that keeps its cursor at the composition's start
        // (Fcitx 5's Pinyin) keeps the candidate window where typing began.
        let log = EventLog()
        let h = Harness { FormView(log: log, autocapitalization: .never) }
        let f = try #require(field(h, 0))
        h.tap(f.frame.center, at: 1.0)
        h.type("ab", at: 1.1)
        h.run(until: 1.3)
        let before = try #require(platform(h)?.textInputCaret)
        compose(h, "n", cursor: 0, at: 1.4)
        compose(h, "ni", cursor: 0, at: 1.5)
        #expect(platform(h)?.textInputCaret == before)
        #expect(f.state.marked == "ni")
    }

    @Test func keysWhileComposingBelongToTheInputMethod() throws {
        let log = EventLog()
        let h = Harness { FormView(log: log, autocapitalization: .never) }
        let f = try #require(field(h, 0))
        h.tap(f.frame.center, at: 1.0)
        h.type("ab", at: 1.1)
        h.run(until: 1.3)
        compose(h, "に", cursor: 1, at: 1.4)
        log.clear()
        // Backspace, arrows, Return, Escape and Tab that arrive while the
        // input method composes leave the text, the focus and onSubmit alone.
        for (i, k) in [Key.backspace, .leftArrow, .return, .escape, .tab].enumerated() {
            h.key(k, at: 1.5 + Double(i) * 0.05)
        }
        h.run(until: 1.9)
        #expect(log.entries.isEmpty)
        #expect(f.state.isFocused)
        #expect(f.state.marked == "に")
        #expect(f.state.caret == 2)
        h.backend.post(.textInput(TextInputEvent(window: h.windowID, text: "日", timestamp: 2.0)), at: 2.0)
        h.run(until: 2.1)
        #expect(log.entries == ["name ab日"])
        #expect(f.state.marked == "")
        // Composition over: the keys edit again.
        h.key(.backspace, at: 2.2)
        h.run(until: 2.3)
        #expect(log.entries.last == "name ab")
    }

    @Test func textSurfaceAreaFollowsItsCaret() throws {
        // The surface tells the window nothing when its caret moves; the
        // window reads the caret again after each frame it draws.
        let client = CaretSurface()
        let h = Harness { SurfaceView(client: client) }
        h.run(until: 1.0)
        #expect(platform(h)?.isTextInputActive == true)
        #expect(platform(h)?.textInputCaret?.minX == 20)
        h.backend.post(.textInput(TextInputEvent(window: h.windowID, text: "abc", timestamp: 1.1)), at: 1.1)
        h.run(until: 1.2)
        #expect(client.text == "abc")
        // The insert asked for no redraw: the area moves with the next frame.
        client.origin.y = 50
        h.window.services.requestDisplay()
        h.run(until: 1.3)
        #expect(platform(h)?.textInputCaret == CGRect(x: 44, y: 50, width: 2, height: 16))
    }
}
