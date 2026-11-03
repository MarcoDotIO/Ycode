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

// Round R8, suite T-CTL (interaction rules; the sizes are the golden cases
// in GoldenViewLayoutTests): 06 §4 — a toggle tap flips its value, a button
// acts on release inside, a tap on a slider's track does nothing (only the
// thumb drags), a stepper's "+" adds 1 — plus Ycode's rules for pickers,
// menus and their pop-up windows, keyboard focus and text editing. Headless
// application hosts on the virtual clock (R7Support.swift).

@MainActor
final class Box<T> {
    var value: T
    init(_ v: T) { value = v }
}

struct ControlsProbe: View {
    let log: EventLog
    @State var on = false
    @State var value = 0.5
    @State var count = 1
    @State var choice = 0
    @State var menuChoice = "a"
    @State var name = ""

    var body: some View {
        VStack(spacing: 12) {
            Toggle("Wi-Fi", isOn: $on).frame(width: 300)
            Slider(value: $value, in: 0...1, step: 0.1).frame(width: 300)
            Stepper("Count", value: $count, in: 0...3).frame(width: 300)
            Picker("Mode", selection: $choice) {
                Text("One").tag(0)
                Text("Two").tag(1)
                Text("Three").tag(2)
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
            Picker("Letter", selection: $menuChoice) {
                Text("Alpha").tag("a")
                Text("Beta").tag("b")
            }
            .pickerStyle(.menu)
            Button("Go") { log.add("go") }.buttonStyle(.bordered)
            Button("Off") { log.add("off") }.disabled(true)
        }
        .onChange(of: on) { _, v in log.add("on \(v)") }
        .onChange(of: value) { _, v in log.add(String(format: "value %.2f", v)) }
        .onChange(of: count) { _, v in log.add("count \(v)") }
        .onChange(of: choice) { _, v in log.add("choice \(v)") }
        .onChange(of: menuChoice) { _, v in log.add("menu \(v)") }
    }
}

@MainActor
@Suite("R8 controls (T-CTL interaction)")
struct ControlTests {
    func frame<V: View>(_ h: Harness, _ type: V.Type) -> CGRect? { h.frame { $0 is V } }

    func popupCount(_ h: Harness) -> Int { h.host.windows.filter(\.isPopup).count }

    func frames<V: View>(_ h: Harness, _ type: V.Type) -> [CGRect] {
        var out: [CGRect] = []
        h.window.graph.root?.forEachNode { n in
            if n.view is V, let f = HitTesting.frame(of: n, mirrorWidth: nil) { out.append(f) }
        }
        return out
    }

    @Test func toggleTapFlipsAndAnimates() {
        let log = EventLog()
        let h = Harness(size: CGSize(width: 400, height: 500)) { ControlsProbe(log: log) }
        guard let t = frame(h, Toggle<Text>.self) else { Issue.record("toggle"); return }
        // The switch is at the trailing end (61 × 28); a tap on it flips.
        let sw = CGPoint(x: t.maxX - 30, y: t.midY)
        h.tap(sw, at: 1.0)
        h.run(until: 1.05)
        #expect(log.entries == ["on true"])
        #expect(h.window.graph.isAnimating)       // the thumb slides (06 §4)
        h.tap(sw, at: 2.0)
        #expect(log.entries == ["on true", "on false"])
        // A tap on the label does nothing (the reference's switch rule).
        h.tap(CGPoint(x: t.minX + 10, y: t.midY), at: 3.0)
        #expect(log.entries.count == 2)
    }

    @Test func sliderTrackTapDoesNothingThumbDrags() {
        let log = EventLog()
        let h = Harness(size: CGSize(width: 400, height: 500)) { ControlsProbe(log: log) }
        guard let s = frame(h, SliderBody.self) else { Issue.record("slider"); return }
        #expect(abs(s.height - 31) < 0.01)
        // 06 §4: a tap on the track does not change the value.
        h.tap(CGPoint(x: s.minX + 40, y: s.midY), at: 1.0)
        h.tap(CGPoint(x: s.maxX - 20, y: s.midY), at: 1.2)
        #expect(log.entries.isEmpty)
        // Dragging the thumb does (step 0.1).
        let usable = s.width - SliderMetrics.thumb
        let thumb = CGPoint(x: s.minX + SliderMetrics.thumb / 2 + 0.5 * usable, y: s.midY)
        h.drag(from: thumb, delta: CGSize(width: usable * 0.2 / 10, height: 0), steps: 10, at: 2.0)
        h.run(until: 2.5)
        #expect(log.entries.last == "value 0.70")
        let sawStart = log.entries.contains { $0.hasPrefix("value 0.5") }
        #expect(!sawStart)
    }

    @Test func stepperIncrementsByOneWithinBounds() {
        let log = EventLog()
        let h = Harness(size: CGSize(width: 400, height: 500)) { ControlsProbe(log: log) }
        guard let s = frame(h, StepperControl.self) else { Issue.record("stepper"); return }
        #expect(abs(s.width - 94) < 0.01 && abs(s.height - 32) < 0.01)
        let plus = CGPoint(x: s.maxX - 20, y: s.midY), minus = CGPoint(x: s.minX + 20, y: s.midY)
        h.tap(plus, at: 1.0)
        #expect(log.entries == ["count 2"])
        h.tap(plus, at: 1.5)
        h.tap(plus, at: 2.0)
        h.tap(plus, at: 2.5)                      // 3 is the upper bound
        #expect(log.entries == ["count 2", "count 3"])
        h.tap(minus, at: 3.0)
        #expect(log.entries.last == "count 2")
    }

    @Test func segmentedPickerSelectsBySegment() {
        let log = EventLog()
        let h = Harness(size: CGSize(width: 400, height: 500)) { ControlsProbe(log: log) }
        guard let p = frame(h, SegmentedPicker.self) else { Issue.record("picker"); return }
        #expect(abs(p.height - 31) < 0.01)
        h.tap(CGPoint(x: p.minX + p.width * 5 / 6, y: p.midY), at: 1.0)
        #expect(log.entries == ["choice 2"])
        h.tap(CGPoint(x: p.minX + p.width / 2, y: p.midY), at: 1.5)
        #expect(log.entries == ["choice 2", "choice 1"])
    }

    @Test func buttonsActOnReleaseAndDisabledOnesDoNot() {
        let log = EventLog()
        let h = Harness(size: CGSize(width: 400, height: 500)) { ControlsProbe(log: log) }
        let buttons = frames(h, Button<Text>.self)
        guard buttons.count >= 2 else { Issue.record("buttons"); return }
        let go = buttons[buttons.count - 2], off = buttons[buttons.count - 1]
        h.pointer(.down, go.center, at: 1.0)
        h.run(until: 1.1)
        #expect(log.entries.isEmpty)              // nothing on touch-down
        h.pointer(.up, go.center, at: 1.2)
        h.run(until: 1.3)
        #expect(log.entries == ["go"])
        // Released outside (beyond the slop): no action.
        h.pointer(.down, go.center, at: 2.0)
        h.pointer(.moved, CGPoint(x: go.maxX + 40, y: go.midY), at: 2.1)
        h.pointer(.up, CGPoint(x: go.maxX + 40, y: go.midY), at: 2.2)
        h.run(until: 2.3)
        #expect(log.entries == ["go"])
        h.tap(off.center, at: 3.0)
        #expect(log.entries == ["go"])
    }

    @Test func customButtonStyleSeesThePressedState() {
        struct Probe: ButtonStyle {
            let log: EventLog
            func makeBody(configuration: Configuration) -> some View {
                log.add("pressed \(configuration.isPressed)")
                return configuration.label.padding(4)
            }
        }
        let log = EventLog()
        let h = Harness { Button("X") { log.add("action") }.buttonStyle(Probe(log: log)) }
        guard let b = frame(h, Button<Text>.self) else { Issue.record("button"); return }
        log.clear()
        h.pointer(.down, b.center, at: 1.0)
        h.run(until: 1.1)
        #expect(log.entries.last == "pressed true")
        h.pointer(.up, b.center, at: 1.2)
        h.run(until: 1.3)
        #expect(log.entries.contains("action"))
        #expect(log.entries.last == "pressed false")
    }

    @Test func tabFocusAndKeysActivateControls() {
        let log = EventLog()
        let h = Harness(size: CGSize(width: 400, height: 500)) { ControlsProbe(log: log) }
        // Tab order is tree order: toggle, slider, stepper, segmented picker,
        // menu picker, the enabled button (the disabled one is skipped).
        h.key(.tab, at: 1.0)
        h.key(.space, at: 1.1)
        #expect(log.entries == ["on true"])
        h.key(.tab, at: 1.2)
        h.key(.rightArrow, at: 1.3)
        #expect(log.entries.last == "value 0.60")
        h.key(.tab, at: 1.4)
        h.key(.upArrow, at: 1.5)
        #expect(log.entries.last == "count 2")
        h.key(.tab, at: 1.6)
        h.key(.rightArrow, at: 1.7)
        #expect(log.entries.last == "choice 1")
        h.key(.tab, at: 1.8)
        h.key(.tab, at: 1.9)
        h.key(.return, at: 2.0)
        #expect(log.entries.last == "go")
        h.key(.tab, modifiers: .shift, at: 2.1)  // back to the menu picker
        h.key(.tab, at: 2.2)
        h.key(.tab, at: 2.3)                      // wraps to the toggle
        h.key(.return, at: 2.4)
        #expect(log.entries.last == "on false")
    }

    // MARK: Menus and pop-up windows

    @Test func menuPickerOpensAPopUpWindowAndChooses() {
        let log = EventLog()
        let h = Harness(size: CGSize(width: 400, height: 500)) { ControlsProbe(log: log) }
        guard let b = frame(h, MenuPickerButton.self) else { Issue.record("menu picker"); return }
        h.tap(b.center, at: 1.0)
        h.run(until: 1.1)
        let popups = h.host.windows.filter(\.isPopup)
        #expect(popups.count == 1)
        guard let popup = popups.first, let pw = popup.platform as? HeadlessWindow else { return }
        #expect(pw.popupParent == h.windowID)
        #expect(abs(pw.popupOrigin.x - b.minX) < 0.01 && abs(pw.popupOrigin.y - (b.maxY + 4)) < 0.01)
        #expect(pw.size.width >= b.width && pw.size.height > 2 * MenuMetrics.rowHeight)
        // The second row ("Beta") chooses and closes the pop-up.
        let row = CGPoint(x: 30, y: MenuMetrics.verticalPadding + MenuMetrics.rowHeight * 1.5)
        h.backend.post(.pointer(PointerEvent(window: pw.id, kind: .mouse, phase: .down, location: row, timestamp: 1.5)), at: 1.5)
        h.backend.post(.pointer(PointerEvent(window: pw.id, kind: .mouse, phase: .up, location: row, timestamp: 1.55)), at: 1.55)
        h.run(until: 1.7)
        #expect(log.entries == ["menu b"])
        #expect(popupCount(h) == 0)
        #expect(pw.isClosed)
    }

    @Test func popUpClosesOnEscapeAndOnAPressOutside() {
        let log = EventLog()
        let h = Harness(size: CGSize(width: 400, height: 500)) { ControlsProbe(log: log) }
        guard let b = frame(h, MenuPickerButton.self) else { Issue.record("menu picker"); return }
        h.tap(b.center, at: 1.0)
        guard let p = h.host.windows.first(where: \.isPopup) else { Issue.record("popup"); return }
        h.backend.post(.key(KeyEvent(window: p.platform.id, key: .escape, timestamp: 1.2)), at: 1.2)
        h.run(until: 1.3)
        #expect(popupCount(h) == 0)
        // Open again; a press in the main window closes it and is not
        // delivered (the toggle under it does not flip).
        h.tap(b.center, at: 2.0)
        #expect(h.host.windows.filter(\.isPopup).count == 1)
        guard let t = frame(h, Toggle<Text>.self) else { return }
        h.tap(CGPoint(x: t.maxX - 30, y: t.midY), at: 2.5)
        #expect(popupCount(h) == 0)
        let flipped = log.entries.contains("on true")
        #expect(!flipped)
        // Keyboard: Down moves to the first row, Return chooses it.
        h.tap(b.center, at: 3.0)
        guard let q = h.host.windows.first(where: \.isPopup) else { Issue.record("popup"); return }
        h.backend.post(.key(KeyEvent(window: q.platform.id, key: .downArrow, timestamp: 3.2)), at: 3.2)
        h.backend.post(.key(KeyEvent(window: q.platform.id, key: .downArrow, timestamp: 3.3)), at: 3.3)
        h.backend.post(.key(KeyEvent(window: q.platform.id, key: .return, timestamp: 3.4)), at: 3.4)
        h.run(until: 3.5)
        #expect(log.entries.last == "menu b")
        #expect(popupCount(h) == 0)
    }

    @Test func menuWithSubmenuClosesTheWholeChain() {
        let log = EventLog()
        let h = Harness {
            Menu("Actions") {
                Button("Copy") { log.add("copy") }
                Divider()
                Menu("More") {
                    Button("Deep") { log.add("deep") }
                }
            }
        }
        guard let m = frame(h, Menu<Text, TupleView<(Button<Text>, Divider, Menu<Text, Button<Text>>)>>.self) else {
            Issue.record("menu")
            return
        }
        h.tap(m.center, at: 1.0)
        guard let first = h.host.windows.first(where: \.isPopup) else { Issue.record("popup"); return }
        // Rows: Copy, the divider, More.
        let moreY = MenuMetrics.verticalPadding + MenuMetrics.rowHeight * 1.5 + 1
        h.backend.post(.pointer(PointerEvent(window: first.platform.id, phase: .down, location: CGPoint(x: 30, y: moreY), timestamp: 1.5)), at: 1.5)
        h.backend.post(.pointer(PointerEvent(window: first.platform.id, phase: .up, location: CGPoint(x: 30, y: moreY), timestamp: 1.55)), at: 1.55)
        h.run(until: 1.6)
        let popups = h.host.windows.filter(\.isPopup)
        #expect(popups.count == 2)
        guard popups.count == 2 else { return }
        let sub = popups[1]
        #expect(sub.popupOwner === first)
        let row = CGPoint(x: 30, y: MenuMetrics.verticalPadding + MenuMetrics.rowHeight / 2)
        h.backend.post(.pointer(PointerEvent(window: sub.platform.id, phase: .down, location: row, timestamp: 2.0)), at: 2.0)
        h.backend.post(.pointer(PointerEvent(window: sub.platform.id, phase: .up, location: row, timestamp: 2.05)), at: 2.05)
        h.run(until: 2.2)
        #expect(log.entries == ["deep"])
        #expect(popupCount(h) == 0)
    }

    @Test func refusedPopUpWindowsBecomeOverlays() {
        let log = EventLog()
        let backend = HeadlessBackend(scale: 1)
        backend.refusesPopups = true
        HarnessApp.content = { AnyView(ControlsProbe(log: log)) }
        HarnessApp.size = CGSize(width: 400, height: 500)
        let host = AppHost(HarnessApp.self, backend: backend)
        host.makePresenter = { _ in nil }
        host.launch()
        host.run(until: 0.5)
        let w = host.windows[0]
        var button: CGRect?
        w.graph.root?.forEachNode { n in
            if button == nil, n.view is MenuPickerButton { button = HitTesting.frame(of: n, mirrorWidth: nil) }
        }
        guard let b = button else { Issue.record("button"); return }
        func tap(_ p: CGPoint, _ t: TimeInterval) {
            backend.post(.pointer(PointerEvent(window: w.platform.id, kind: .touch, phase: .down, location: p, timestamp: t)), at: t)
            backend.post(.pointer(PointerEvent(window: w.platform.id, kind: .touch, phase: .up, location: p, timestamp: t + 0.05)), at: t + 0.05)
            host.run(until: t + 0.1)
        }
        tap(b.center, 1.0)
        #expect(host.windows.count == 1)
        #expect(w.overlayPopups.count == 1)
        // The overlay's second row chooses.
        tap(CGPoint(x: b.minX + 30, y: b.maxY + 4 + MenuMetrics.verticalPadding + MenuMetrics.rowHeight * 1.5), 2.0)
        #expect(log.entries == ["menu b"])
        #expect(w.overlayPopups.isEmpty)
    }

    // MARK: Text editing in fields

    struct FieldProbe: View {
        let log: EventLog
        var secure = false
        @State var text = "hello world"
        @State var notes = "one\ntwo"

        var body: some View {
            VStack(spacing: 10) {
                if secure {
                    SecureField("Password", text: $text).frame(width: 300)
                } else {
                    TextField("Name", text: $text).textFieldStyle(.roundedBorder).frame(width: 300)
                }
                TextEditor(text: $notes).frame(width: 300, height: 100)
            }
            .textInputAutocapitalization(.never)
            .onChange(of: text) { _, t in log.add("text \(t)") }
            .onChange(of: notes) { _, t in log.add("notes \(t.replacingOccurrences(of: "\n", with: "|"))") }
        }
    }

    func states(_ h: Harness) -> [TextFieldState] {
        var out: [TextFieldState] = []
        h.window.graph.root?.forEachNode { n in if let s = n.primitiveState as? TextFieldState { out.append(s) } }
        return out
    }

    func stateFrame(_ h: Harness, _ i: Int) -> CGRect? {
        var out: [CGRect] = []
        h.window.graph.root?.forEachNode { n in
            if n.primitiveState is TextFieldState, let f = HitTesting.frame(of: n, mirrorWidth: nil) { out.append(f) }
        }
        return out.indices.contains(i) ? out[i] : nil
    }

    @Test func clickSelectAndUndoInAField() {
        let log = EventLog()
        let h = Harness { FieldProbe(log: log) }
        guard let f = stateFrame(h, 0), let s = states(h).first else { Issue.record("field"); return }
        // A click at the far right puts the caret at the end; shift-arrows
        // select; typing replaces the selection.
        h.tap(CGPoint(x: f.maxX - 5, y: f.midY), at: 1.0)
        #expect(s.isFocused && s.model.caret == 11 && s.model.selection.isEmpty)
        h.key(.leftArrow, modifiers: [.shift, .control], at: 1.1)
        #expect(s.model.selectedText == "world")
        h.type("there", at: 1.2)
        #expect(log.entries.last == "text hello there")
        // Undo restores the selection's text in one step; redo again.
        h.key(.character("z"), modifiers: .control, at: 1.6)
        #expect(log.entries.last == "text hello world")
        h.key(.character("z"), modifiers: [.control, .shift], at: 1.7)
        #expect(log.entries.last == "text hello there")
        // A double click selects a word; Ctrl+X cuts it; Ctrl+V pastes.
        let x = f.minX + 14 + 10
        h.tap(CGPoint(x: x, y: f.midY), at: 2.0)
        h.tap(CGPoint(x: x, y: f.midY), at: 2.1)
        #expect(s.model.selectedText == "hello")
        h.key(.character("x"), modifiers: .control, at: 2.2)
        #expect(h.backend.clipboard.text == "hello")
        #expect(log.entries.last == "text  there")
        h.key(.end, at: 2.3)
        h.key(.character("v"), modifiers: .control, at: 2.4)
        #expect(log.entries.last == "text  therehello")
    }

    @Test func dragSelectsAndShiftClickExtends() {
        let log = EventLog()
        let h = Harness { FieldProbe(log: log) }
        guard let f = stateFrame(h, 0), let s = states(h).first else { Issue.record("field"); return }
        let start = CGPoint(x: f.minX + 14 + 1, y: f.midY)
        h.drag(from: start, delta: CGSize(width: 6, height: 0), steps: 10, at: 1.0)
        #expect(s.model.selection.anchor == 0 && s.model.selection.head > 3)
        h.tap(CGPoint(x: f.minX + 14 + 1, y: f.midY), at: 2.0)
        #expect(s.model.selection.isEmpty && s.model.caret == 0)
        h.backend.post(.pointer(PointerEvent(window: h.windowID, kind: .mouse, phase: .down, location: CGPoint(x: f.maxX - 5, y: f.midY),
                                             modifiers: .shift, timestamp: 3.0)), at: 3.0)
        h.backend.post(.pointer(PointerEvent(window: h.windowID, kind: .mouse, phase: .up, location: CGPoint(x: f.maxX - 5, y: f.midY),
                                             modifiers: .shift, timestamp: 3.05)), at: 3.05)
        h.run(until: 3.1)
        #expect(s.model.selectedRange == 0..<11)
    }

    @Test func caretBlinksAndRests() {
        let log = EventLog()
        let h = Harness { FieldProbe(log: log) }
        guard let f = stateFrame(h, 0), let s = states(h).first else { Issue.record("field"); return }
        h.tap(f.center, at: 1.0)
        #expect(s.caretVisible)
        h.run(until: 1.05 + 0.6)
        #expect(!s.caretVisible)
        h.run(until: 1.05 + 1.1)
        #expect(s.caretVisible)
        // Typing shows it again and restarts the cycle.
        h.run(until: 2.2)
        h.type("x", at: 2.25)
        #expect(s.caretVisible)
        // After 10 s without activity it stays on and the timer stops.
        h.run(until: 14)
        #expect(s.caretVisible)
        #expect(h.window.services.nextTimerDeadline == nil)
    }

    @Test func secureFieldHidesAndDoesNotCopy() {
        let log = EventLog()
        let h = Harness { FieldProbe(log: log, secure: true) }
        guard let f = stateFrame(h, 0), let s = states(h).first else { Issue.record("field"); return }
        #expect(s.displayString == String(repeating: "\u{2022}", count: 11))
        h.tap(f.center, at: 1.0)
        h.key(.character("a"), modifiers: .control, at: 1.1)
        h.backend.clipboard.text = "keep"
        h.key(.character("c"), modifiers: .control, at: 1.2)
        h.key(.character("x"), modifiers: .control, at: 1.3)
        #expect(h.backend.clipboard.text == "keep")
        #expect(log.entries.isEmpty)
    }

    @Test func textEditorReturnAndVerticalMovement() {
        let log = EventLog()
        let h = Harness { FieldProbe(log: log) }
        guard let e = stateFrame(h, 1), let s = states(h).last else { Issue.record("editor"); return }
        h.tap(CGPoint(x: e.minX + 5, y: e.minY + 8), at: 1.0)
        #expect(s.model.caret == 0)
        h.key(.downArrow, at: 1.1)
        #expect(s.model.caret == 4)
        h.key(.end, at: 1.2)
        h.key(.return, at: 1.3)
        h.type("three", at: 1.4)
        #expect(log.entries.last == "notes one|two|three")
        h.key(.upArrow, at: 2.0)
        h.key(.upArrow, at: 2.1)
        #expect(s.model.caret <= 3)
        // Tab inserts a tab in the editor.
        h.key(.tab, at: 2.2)
        let hasTab = log.entries.last?.contains("\t") == true
        #expect(hasTab)
    }

    // MARK: Layout of forms and the background overloads

    @Test func formRowsAreInsetAndTall() {
        let h = Harness(size: CGSize(width: 400, height: 400)) {
            Form {
                Section("General") {
                    Toggle("On", isOn: .constant(true))
                    Text("Row")
                }
                LabeledContent("Version", value: "1.0")
            }
        }
        guard let t = h.frame(where: { $0 is Toggle<Text> }) else { Issue.record("toggle"); return }
        #expect(abs(t.minX - 40) < 0.01 && abs(t.width - 320) < 0.01)
        guard let r = h.frame(where: { ($0 as? Text).map { _ in true } ?? false }) else { return }
        #expect(r.minX >= 40)
        guard let l = h.frame(where: { $0 is LabeledContent<Text, Text> }) else { Issue.record("labeled"); return }
        #expect(abs(l.minX - 40) < 0.01 && l.maxX <= 360.01)
    }

    @Test func colorBackgroundUsesTheShapeStyleOverload() {
        // `.background(Color.x)` resolves to the ShapeStyle form (the view
        // form is disfavoured, as in the reference API), which fills a
        // rectangle in the view's bounds.
        let v = Color.red.frame(width: 10, height: 10).background(Color.blue)
        #expect(String(describing: type(of: v)).contains("Rectangle"))
        let o = Text("A").overlay(Color.green.opacity(0.5))
        #expect(String(describing: type(of: o)).contains("Rectangle"))
        // The view form still serves non-style views.
        let w = Text("A").background(Text("B"))
        #expect(!String(describing: type(of: w)).contains("Rectangle"))
    }
}
