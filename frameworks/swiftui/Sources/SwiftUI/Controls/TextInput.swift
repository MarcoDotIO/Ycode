import Foundation
import OVPlatform
import OVRender
import OVText
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Text input controls (round R8): `TextField`, `SecureField`, `TextEditor`.
// Editing is OVText's `TextEditingModel` (selection, word and line movement,
// undo, marked text), shared with the IDE's future EditorKit; this file is
// the view side: layout, drawing (selection, text, marked-text underline, a
// blinking caret), pointer selection, keys, focus and the binding.
//
// Sizes (golden-layout.md): a plain field is its content's width unproposed
// and the proposed width otherwise, one line pitch high (22 at body: ascent +
// descent + leading on the pixel grid), the text centred in it (baseline
// 17.33); `.roundedBorder` adds 14 + 14 and 6 + 6 points (118 × 34, baseline
// 23.33); a plain `SecureField` is a point lower (21, measured). 06 §5: a tap
// focuses a field, typed keys are inserted, Return runs `onSubmit` and
// removes focus.
//
// Ycode choices (no reference measurements): a click places the caret, a
// double click selects a word, a triple click the paragraph (the field in a
// single-line field); shift-click and drags extend; Tab focus selects all;
// the caret blinks 0.53 s on, 0.53 s off and stops (shown) after 10 s
// without activity; copy and cut act on the selection; secure fields do not
// copy or cut. Keys use the Linux desktop conventions: Ctrl+arrows by word,
// Ctrl+A/C/X/V/Z, Ctrl+Shift+Z and Ctrl+Y redo (Ctrl+Y only when no
// shortcut of the window takes it).

// MARK: - Styles

/// How a text field looks.
@MainActor @preconcurrency
public protocol TextFieldStyle {
    /// Ycode's style identifier (the reference API has no public requirement).
    var _ovStyleKind: Int { get }
}

public struct DefaultTextFieldStyle: TextFieldStyle {
    public init() {}
    public var _ovStyleKind: Int { 0 }
}

public struct PlainTextFieldStyle: TextFieldStyle {
    public init() {}
    public var _ovStyleKind: Int { 1 }
}

public struct RoundedBorderTextFieldStyle: TextFieldStyle {
    public init() {}
    public var _ovStyleKind: Int { 2 }
}

extension TextFieldStyle where Self == DefaultTextFieldStyle {
    public static var automatic: DefaultTextFieldStyle { DefaultTextFieldStyle() }
}

extension TextFieldStyle where Self == PlainTextFieldStyle {
    public static var plain: PlainTextFieldStyle { PlainTextFieldStyle() }
}

extension TextFieldStyle where Self == RoundedBorderTextFieldStyle {
    public static var roundedBorder: RoundedBorderTextFieldStyle { RoundedBorderTextFieldStyle() }
}

private enum TextFieldStyleKey: EnvironmentKey { static let defaultValue = 0 }

extension EnvironmentValues {
    var _textFieldStyle: Int {
        get { self[TextFieldStyleKey.self] }
        set { self[TextFieldStyleKey.self] = newValue }
    }
}

extension View {
    public func textFieldStyle<S: TextFieldStyle>(_ style: S) -> some View {
        environment(\._textFieldStyle, style._ovStyleKind)
    }
}

/// Field insets per style (golden `textfield.rounded`: 118 − 90 = 28 and
/// 34 − 22 = 12).
func fieldInsets(style: Int, multiline: Bool, desktop: Bool = false) -> EdgeInsets {
    // B5-OPENVIEWS: the macOS IDE's bezeled field, 23 tall for 13-point
    // text, its text 6 in.
    if style == 2 && desktop && !multiline { return EdgeInsets(top: 3.5, leading: 6, bottom: 3.5, trailing: 6) }
    if style == 2 { return EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14) }
    return multiline ? EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4) : EdgeInsets()
}

// MARK: - Views

/// A control that edits a string on one line.
public struct TextField<Label: View>: View {
    let text: Binding<String>
    let label: Label
    let prompt: Text?
    let axis: Axis

    public init(text: Binding<String>, prompt: Text? = nil, @ViewBuilder label: () -> Label) {
        self.text = text
        self.prompt = prompt
        self.label = label()
        axis = .horizontal
    }

    public init(text: Binding<String>, prompt: Text? = nil, axis: Axis, @ViewBuilder label: () -> Label) {
        self.text = text
        self.prompt = prompt
        self.label = label()
        self.axis = axis
    }

    public var body: some View {
        let text = text
        EditableText(text: text, placeholder: prompt ?? (label as? Text), kind: axis == .vertical ? .growing : .field)
            .accessibilityControl(.textField, value: { text.wrappedValue }, children: .ignore)
    }
}

extension TextField where Label == Text {
    public init(_ titleKey: LocalizedStringKey, text: Binding<String>) {
        self.init(text: text, prompt: nil) { Text(titleKey) }
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, text: Binding<String>) {
        self.init(text: text, prompt: nil) { Text(title) }
    }

    public init(_ titleKey: LocalizedStringKey, text: Binding<String>, prompt: Text?) {
        self.init(text: text, prompt: prompt) { Text(titleKey) }
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, text: Binding<String>, prompt: Text?) {
        self.init(text: text, prompt: prompt) { Text(title) }
    }

    public init(_ titleKey: LocalizedStringKey, text: Binding<String>, axis: Axis) {
        self.init(text: text, prompt: nil, axis: axis) { Text(titleKey) }
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, text: Binding<String>, axis: Axis) {
        self.init(text: text, prompt: nil, axis: axis) { Text(title) }
    }
}

/// A text field that hides what is typed.
public struct SecureField<Label: View>: View {
    let text: Binding<String>
    let label: Label
    let prompt: Text?

    public init(text: Binding<String>, prompt: Text? = nil, @ViewBuilder label: () -> Label) {
        self.text = text
        self.prompt = prompt
        self.label = label()
    }

    public var body: some View {
        EditableText(text: text, placeholder: prompt ?? (label as? Text), kind: .secure)
            .accessibilityControl(.secureTextField, children: .ignore)
    }
}

extension SecureField where Label == Text {
    public init(_ titleKey: LocalizedStringKey, text: Binding<String>) {
        self.init(text: text, prompt: nil) { Text(titleKey) }
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, text: Binding<String>) {
        self.init(text: text, prompt: nil) { Text(title) }
    }

    public init(_ titleKey: LocalizedStringKey, text: Binding<String>, prompt: Text?) {
        self.init(text: text, prompt: prompt) { Text(titleKey) }
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, text: Binding<String>, prompt: Text?) {
        self.init(text: text, prompt: prompt) { Text(title) }
    }
}

/// A multi-line text editing area (basic: wrapping, vertical scrolling to
/// the caret; not a code editor).
public struct TextEditor: View {
    let text: Binding<String>

    public init(text: Binding<String>) { self.text = text }

    public var body: some View {
        let text = text
        EditableText(text: text, placeholder: nil, kind: .editor)
            .accessibilityControl(.textField, value: { text.wrappedValue }, children: .ignore)
    }
}

// MARK: - The editable text primitive

/// The view every text input control lowers to.
struct EditableText: View {
    enum Kind { case field, secure, growing, editor }
    let text: Binding<String>
    let placeholder: Text?
    let kind: Kind
    typealias Body = Never
}

/// The editing state of a text input; the focus system's text client.
final class TextFieldState: TextInputClient, GeometryObserving {
    weak var node: ViewNode?
    let model = TextEditingModel()
    var text: Binding<String> = .constant("")
    var kind: EditableText.Kind = .field
    var isFocused = false
    var autocapitalization = TextInputAutocapitalization.never
    var submitActions: [() -> Void] = []
    var services: WindowServices?
    /// Layout inputs of the last lowering.
    var insets = EdgeInsets()
    var textTop: CGFloat = 0
    var display = ResolvedText("")
    var measurer: TypesetTextMeasurer?
    var emptyLine: (height: CGFloat, ascent: CGFloat) = (20, 16)
    /// Geometry of the last layout (field size, window frame).
    var size = CGSize.zero
    var frame = CGRect.zero
    var scroll = CGPoint.zero
    // Caret blink.
    var caretVisible = true
    private var lastActivity: TimeInterval = 0
    // Pointer selection.
    private var lastClick: (time: TimeInterval, point: CGPoint, count: Int)?
    private var dragAnchor: Range<Int>?
    private var focusFromClick = false

    var isSecure: Bool { kind == .secure }
    var multiline: Bool { kind == .editor || kind == .growing }
    /// The input method's uncommitted text (R7 tests).
    var marked: String { model.markedText }
    var caret: Int { model.caret }

    @MainActor private var now: TimeInterval { node?.graph.timeSource.now ?? 0 }

    @MainActor func invalidate() { node?.invalidate(transaction: Transaction()) }

    /// Writes the model's text to the binding when it changed, redraws and
    /// restarts the blink.
    @MainActor func commit() {
        if text.wrappedValue != model.text { text.wrappedValue = model.text }
        activity()
        invalidate()
    }

    // MARK: Blink

    @MainActor func activity() {
        lastActivity = now
        caretVisible = true
        scheduleBlink()
    }

    @MainActor private func scheduleBlink() {
        guard let services else { return }
        guard isFocused else {
            services.setTimer(self, at: nil) { _ in }
            return
        }
        services.setTimer(self, at: now + 0.53) { [weak self] t in self?.blink(at: t) }
    }

    @MainActor private func blink(at t: TimeInterval) {
        guard isFocused else { return }
        if t - lastActivity >= 10 {
            if !caretVisible {
                caretVisible = true
                invalidate()
            }
            return
        }
        caretVisible.toggle()
        invalidate()
        scheduleBlink()
    }

    // MARK: Geometry

    /// The display characters: bullets for secure fields.
    var displayString: String {
        let c = model.displayCharacters
        return isSecure ? String(repeating: "\u{2022}", count: c.count) : String(c)
    }

    /// The layout of the display text in its own coordinates.
    func geometry() -> TextLayoutGeometry? {
        guard let measurer else { return nil }
        let contentWidth = max(0, size.width - insets.leading - insets.trailing)
        var text = display
        if text.runs.isEmpty || text.string.isEmpty { return nil }
        let width: CGFloat? = multiline ? contentWidth : nil
        text.paragraph.lineLimit = multiline ? nil : 1
        let m = measurer.measure(text, proposal: ProposedViewSize(width: width, height: nil))
        let (layout, lines) = measurer.placedLayout(text, size: CGSize(width: width ?? max(m.size.width, 1), height: m.size.height))
        return TextLayoutGeometry(layout: layout, lineOrigins: lines.map { Double($0.origin.x) },
                                  baselines: lines.map { Double($0.origin.y) },
                                  emptyLineHeight: Double(emptyLine.height), emptyAscent: Double(emptyLine.ascent))
    }

    /// Keeps the caret inside the visible part (scrolls the text).
    func updateScroll(_ g: TextLayoutGeometry) {
        let contentWidth = max(0, size.width - insets.leading - insets.trailing)
        let contentHeight = max(0, size.height - insets.top - insets.bottom - textTop)
        let c = g.caret(at: model.displayCaret)
        if multiline {
            let bottom = CGFloat(c.top + c.height)
            if bottom - scroll.y > contentHeight { scroll.y = bottom - contentHeight }
            if CGFloat(c.top) - scroll.y < 0 { scroll.y = CGFloat(c.top) }
            scroll.x = 0
        } else {
            let x = CGFloat(c.x)
            if x - scroll.x > contentWidth - 2 { scroll.x = x - contentWidth + 2 }
            if x - scroll.x < 0 { scroll.x = x }
            let textWidth = CGFloat(g.lines.map { $0.x + ($0.edges.last ?? 0) }.max() ?? 0)
            scroll.x = max(0, min(scroll.x, max(0, textWidth - contentWidth + 2)))
            scroll.y = 0
        }
    }

    /// A point in the field's local coordinates → a text offset.
    @MainActor func offset(at p: CGPoint) -> Int {
        guard let g = geometry() else { return model.count }
        let x = Double(p.x - insets.leading + scroll.x)
        let y = Double(p.y - insets.top - textTop + scroll.y)
        let o = g.offset(atX: x, y: y)
        // Offsets in the display text include the marked text.
        if let r = model.displayMarkedRange, o > r.lowerBound { return max(r.lowerBound, o - r.count) }
        return min(o, model.count)
    }

    func geometryChanged(_ geometry: NodeGeometry, node: ViewNode) {
        size = geometry.size
        frame = geometry.frame
    }

    // MARK: TextInputClient

    /// Capitalisation of `s` typed after `before` (06 §5: "h" at the start of
    /// an empty field became "H").
    private func capitalised(_ s: String, after before: ArraySlice<Character>) -> String {
        switch autocapitalization.kind {
        case .never: return s
        case .characters: return s.uppercased()
        case .words:
            guard before.isEmpty || before.last?.isWhitespace == true, let f = s.first else { return s }
            return f.uppercased() + s.dropFirst()
        case .sentences:
            let trimmed = before.reversed().drop { $0 == " " }
            let atStart = trimmed.isEmpty || [".", "!", "?", "\n"].contains(trimmed.first!)
            guard atStart, before.isEmpty || before.last == " " || before.last == "\n", let f = s.first else { return s }
            return f.uppercased() + s.dropFirst()
        }
    }

    @MainActor func insertText(_ s: String) {
        let before = model.characters[..<model.selectedRange.lowerBound]
        model.insert(isSecure ? s : capitalised(s, after: before))
        commit()
    }

    @MainActor func setMarkedText(_ s: String, cursor: Int) {
        model.setMarkedText(s, cursor: cursor)
        commit()
    }

    private var primaryShortcutModifiers: KeyModifiers { [.control, .command] }

    @MainActor func handleKey(_ event: KeyEvent) -> Bool {
        guard event.isDown else { return false }
        let m = event.modifiers
        let primary = m.contains(.control) || m.contains(.command)
        // While an input method composes, its keys are its own: Backspace,
        // arrows, Return and Escape edit the composition, not the field (no
        // submit, no focus change). Shortcuts still reach the app.
        if model.hasMarkedText { return !primary }
        let shift = m.contains(.shift)
        if multiline, let g = geometry() { model.layout = g } else { model.layout = nil }
        if primary {
            switch event.key {
            case .character(let c):
                switch c {
                case "a": model.selectAll()
                case "c":
                    if !isSecure, let s = model.copy() { services?.clipboard?.text = s }
                    return true
                case "x":
                    guard !isSecure, let s = model.cut() else { return true }
                    services?.clipboard?.text = s
                case "v":
                    if let s = services?.clipboard?.text, !s.isEmpty { model.paste(s) }
                case "z":
                    if shift { model.redo() } else { model.undo() }
                case "y":
                    // Ctrl+Y redoes unless the app gives the keystroke a
                    // command (the Linux IDE's ⌘Y, Deactivate Breakpoints);
                    // Ctrl+Shift+Z always redoes.
                    if services?.shortcuts.hasEnabledShortcut(key: event.key, modifiers: m) == true { return false }
                    model.redo()
                default: return false
                }
            case .leftArrow: model.move(isSecure ? .document : .word, forward: false, extending: shift)
            case .rightArrow: model.move(isSecure ? .document : .word, forward: true, extending: shift)
            case .home, .upArrow: model.move(.document, forward: false, extending: shift)
            case .end, .downArrow: model.move(.document, forward: true, extending: shift)
            case .backspace: model.deleteBackward(isSecure ? .document : .word)
            case .deleteForward: model.deleteForward(isSecure ? .document : .word)
            case .tab: return false
            default: return false
            }
            commit()
            return true
        }
        switch event.key {
        case .backspace: model.deleteBackward()
        case .deleteForward: model.deleteForward()
        case .leftArrow: model.move(.character, forward: false, extending: shift)
        case .rightArrow: model.move(.character, forward: true, extending: shift)
        case .upArrow:
            if multiline { model.moveVertically(lines: -1, extending: shift) } else { model.move(.document, forward: false, extending: shift) }
        case .downArrow:
            if multiline { model.moveVertically(lines: 1, extending: shift) } else { model.move(.document, forward: true, extending: shift) }
        case .home: model.move(multiline ? .line : .document, forward: false, extending: shift)
        case .end: model.move(multiline ? .line : .document, forward: true, extending: shift)
        case .pageUp: model.move(.document, forward: false, extending: shift)
        case .pageDown: model.move(.document, forward: true, extending: shift)
        case .return:
            if kind == .editor {
                model.insert("\n")
            } else {
                submit()
                return true
            }
        case .tab:
            guard kind == .editor, !shift else { return false }
            model.insert("\t")
        case .escape:
            return false
        case .character, .space:
            // The text arrives as a text input event.
            return true
        default:
            return false
        }
        commit()
        return true
    }

    // MARK: Edit menu (R11)

    @MainActor func canPerform(_ command: StandardEditCommand, clipboard: (any PlatformClipboard)?) -> Bool {
        let hasSelection = !model.selection.isEmpty
        switch command {
        case .undo: return model.canUndo
        case .redo: return model.canRedo
        case .cut, .copy: return hasSelection && !isSecure
        case .delete: return hasSelection
        case .paste: return clipboard?.hasText ?? false
        case .selectAll: return !model.text.isEmpty
        }
    }

    @MainActor func perform(_ command: StandardEditCommand, clipboard: (any PlatformClipboard)?) {
        guard canPerform(command, clipboard: clipboard) else { return }
        switch command {
        case .undo: model.undo()
        case .redo: model.redo()
        case .cut: if let s = model.cut() { clipboard?.text = s }
        case .copy:
            if let s = model.copy() { clipboard?.text = s }
            return
        case .paste: if let s = clipboard?.text, !s.isEmpty { model.paste(s) }
        case .delete: model.deleteBackward(.character)
        case .selectAll: model.selectAll()
        }
        commit()
    }

    /// Return: `onSubmit` actions, then focus goes away (06 §5).
    @MainActor func submit() {
        for a in submitActions { a() }
        if let node, services?.focus.isFocused(node) == true { services?.focus.focus(nil) }
    }

    @MainActor var caretRect: CGRect {
        guard let g = geometry() else { return CGRect(x: frame.minX + insets.leading, y: frame.minY, width: 2, height: frame.height) }
        let c = g.caret(at: model.displayCaret)
        return CGRect(x: frame.minX + insets.leading + CGFloat(c.x) - scroll.x,
                      y: frame.minY + insets.top + textTop + CGFloat(c.top) - scroll.y, width: 2, height: CGFloat(c.height))
    }

    @MainActor func focusChanged(_ focused: Bool) {
        isFocused = focused
        model.unmarkText()
        if focused {
            // Keyboard focus selects everything (desktop convention); a click
            // places the caret itself.
            if !focusFromClick { model.selectAll() }
            activity()
        } else {
            services?.setTimer(self, at: nil) { _ in }
            model.setCaret(model.caret)
        }
        focusFromClick = false
        invalidate()
    }

    // MARK: Pointer selection

    @MainActor func pointer(_ e: PointerTrackRecognizer.Event) {
        switch e {
        case .down(let p, let t):
            if let node, services?.focus.isFocused(node) != true {
                focusFromClick = true
                services?.focus.focus(node)
                focusFromClick = false
            }
            let o = offset(at: p)
            var count = 1
            if let last = lastClick, t - last.time < 0.35, hypot(p.x - last.point.x, p.y - last.point.y) < 5 {
                count = last.count % 3 + 1
            }
            lastClick = (t, p, count)
            model.unmarkText()
            if services?.pointerModifiers.contains(.shift) == true && count == 1 {
                model.extendSelection(to: o)
                dragAnchor = nil
            } else {
                switch count {
                case 2:
                    model.selectWord(at: o)
                case 3:
                    if multiline { model.selectParagraph(at: o) } else { model.selectAll() }
                default:
                    model.setCaret(o)
                }
                dragAnchor = count == 1 ? nil : model.selectedRange
            }
            commit()
        case .moved(let p, _):
            let o = offset(at: p)
            if let anchor = dragAnchor {
                let w = model.wordRange(at: o)
                let lo = min(anchor.lowerBound, w.lowerBound), hi = max(anchor.upperBound, w.upperBound)
                model.setSelection(o < anchor.lowerBound ? TextSelectionRange(anchor: hi, head: lo)
                                                         : TextSelectionRange(anchor: lo, head: hi))
            } else {
                model.extendSelection(to: o)
            }
            commit()
        case .up, .cancelled:
            dragAnchor = nil
        }
    }
}

extension EditableText: PrimitiveView {
    private func build(_ node: ViewNode, _ transaction: Transaction) {
        let state = (node.primitiveState as? TextFieldState) ?? TextFieldState()
        node.primitiveState = state
        state.node = node
        state.text = text
        state.kind = kind
        state.model.allowsNewlines = kind == .editor || kind == .growing
        let env = node.environment
        state.autocapitalization = kind == .secure ? .never : (env._textInputAutocapitalization ?? env._defaultAutocapitalization)
        state.submitActions = env._submitActions
        if let services = env._windowServices {
            if env.isEnabled {
                services.focus.register(node, bindings: env._focusBindings, client: state)
            } else {
                services.focus.unregister(node)
            }
            state.services = services
        }
        // Read under tracking: a change of the bound string rebuilds the field.
        let value = node.trackContent { text.wrappedValue }
        if value != state.model.text { state.model.setText(value) }
        let style = env._textFieldStyle
        let leaf = EditableTextLeaf(state: state, placeholder: placeholder, kind: kind, revision: state.model.revision,
                                    focused: state.isFocused)
        let gesture = ControlTrackGesture { [weak state] e in state?.pointer(e) }
        let child: AnyView
        if style == 2 || kind == .editor {
            let desktop = env._desktopChrome
            let shape = RoundedRectangle(cornerRadius: kind == .editor || desktop ? 6 : 8)
            let palette = ControlPalette(env.colorScheme)
            let dark = env.colorScheme == .dark
            // B5-OPENVIEWS: the macOS IDE's field: white (#171717) with a
            // hairline (#EBEBEB, #282929 on it).
            let fill = desktop ? (dark ? Color(ycodeHex: 0x171717) : Color.white) : palette.fieldBackground
            let rim = desktop ? (dark ? Color.white.opacity(0.07) : Color.black.opacity(0.08)) : palette.outline
            child = AnyView(leaf
                .background(fill, in: shape)
                .overlay {
                    if state.isFocused {
                        shape.strokeBorder(.tint, lineWidth: 2)
                    } else {
                        shape.strokeBorder(rim, lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
                .gesture(gesture))
        } else {
            child = AnyView(leaf.contentShape(Rectangle()).gesture(gesture))
        }
        node.reconcileChildren([(AnyHashable(0), child)], transaction: transaction)
    }

    package func _makeChildren(node: ViewNode, old: EditableText?, transaction: Transaction) { build(node, transaction) }

    package func _refresh(node: ViewNode, environmentChanged: Bool, transaction: Transaction) {
        if node.updateWasDirty || environmentChanged {
            build(node, transaction)
        } else {
            node.refreshChildren(transaction: transaction)
        }
    }

    package func _removed(node: ViewNode) {
        guard let state = node.primitiveState as? TextFieldState else { return }
        state.services?.focus.unregister(node)
        state.services?.setTimer(state, at: nil) { _ in }
    }
}

/// Forwards the leaf's layout geometry to the field state.
final class EditableGeometryForwarder: GeometryObserving {
    weak var state: TextFieldState?
    func geometryChanged(_ geometry: NodeGeometry, node: ViewNode) { state?.geometryChanged(geometry, node: node) }
}

/// The drawn and measured part of a text input.
struct EditableTextLeaf: View {
    let state: TextFieldState
    let placeholder: Text?
    let kind: EditableText.Kind
    /// Inputs that change when the text or the focus does (so the leaf is
    /// lowered again).
    let revision: Int
    let focused: Bool
    typealias Body = Never
}

extension EditableTextLeaf: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: EditableTextLeaf?, transaction: Transaction) {
        let f = (node.primitiveState as? EditableGeometryForwarder) ?? EditableGeometryForwarder()
        f.state = state
        node.primitiveState = f
    }

    package func _lower(node: ViewNode) -> [LayoutNode] {
        let env = node.environment
        let style = env._textFieldStyle
        let multiline = kind == .editor || kind == .growing
        let insets = fieldInsets(style: style, multiline: kind == .editor, desktop: env._desktopChrome)
        let palette = ControlPalette(env.colorScheme)
        let display = Text(verbatim: state.displayString).resolve(in: env)
        let placeholderText = (placeholder ?? Text(verbatim: "")).foregroundColor(palette.placeholder).resolve(in: env)
        state.display = display
        state.insets = insets
        let behavior = EditableTextBehavior(state: state, display: display, placeholder: placeholderText,
                                            insets: insets, multiline: multiline, fillsHeight: kind == .editor,
                                            heightAdjustment: kind == .secure && style != 2 ? -1 : 0)
        let leaf = LayoutNode(behavior, children: [])
        leaf.owner = node
        leaf.draw = editableTextDraw(state: state, placeholder: placeholderText, environment: env)
        return [leaf]
    }
}

extension EnvironmentValues {
    /// The control tint as a resolved colour (the accent unless `tint` set a
    /// colour).
    var tintColorForControls: Color.Resolved {
        if let t = tintStyle?.base as? Color { return t.resolve(in: self) }
        if let t = tintStyle?.base as? Color.Resolved { return t }
        return Color.accentColor.resolve(in: self)
    }
}

/// Measures an editable text: golden `textfield.*` and `secureField`.
struct EditableTextBehavior: NodeBehavior {
    let state: TextFieldState
    let display: ResolvedText
    let placeholder: ResolvedText
    let insets: EdgeInsets
    let multiline: Bool
    let fillsHeight: Bool
    let heightAdjustment: CGFloat

    private func ceilPx(_ v: CGFloat, _ scale: CGFloat) -> CGFloat { ((v * scale) - 1e-4).rounded(.up) / scale }

    /// The line box (pitch), the height of one text line and its baseline.
    private func lineMetrics(_ node: LayoutNode) -> (pitch: CGFloat, text: CGFloat, baseline: CGFloat) {
        let scale = node.context.environment.displayScale
        var sample = display
        sample.runs = [ResolvedText.Run(string: "Ag", font: display.firstFont, tracking: 0, kerning: 0, baselineOffset: 0, color: nil)]
        sample.paragraph.lineLimit = 1
        let m = node.context.textMeasurer.measure(sample, proposal: .unspecified)
        let baseline = m.firstBaseline ?? m.size.height * 0.8
        if let tm = node.context.textMeasurer as? TypesetTextMeasurer, let line = tm.layout(sample, width: nil, height: nil).lines.first {
            return (ceilPx(CGFloat(line.ascent + line.descent + line.leading), scale), m.size.height, baseline)
        }
        return (m.size.height + 2, m.size.height, baseline)
    }

    private func measure(_ t: ResolvedText, _ p: ProposedViewSize, _ node: LayoutNode) -> CGSize {
        guard !t.string.isEmpty else { return .zero }
        let m = node.context.textMeasurer.measure(t, proposal: p)
        node.context.uncertain(m.unknown)
        return m.size
    }

    func sizeThatFits(_ p: ProposedViewSize, node: LayoutNode) -> CGSize {
        let lm = lineMetrics(node)
        let scale = node.context.environment.displayScale
        let top = ceilPx(max(0, lm.pitch + heightAdjustment - lm.text) / 2, scale)
        let measurer = node.context.textMeasurer as? TypesetTextMeasurer
        let state = state
        MainActor.assumeIsolated {
            state.textTop = top
            state.emptyLine = (lm.text, lm.baseline)
            state.measurer = measurer
        }
        let h = insets.leading + insets.trailing, v = insets.top + insets.bottom
        if !multiline {
            var single = display
            single.paragraph.lineLimit = 1
            var ph = placeholder
            ph.paragraph.lineLimit = 1
            let ideal = max(measure(single, .unspecified, node).width, measure(ph, .unspecified, node).width)
            return CGSize(width: max(0, p.width ?? (ideal + h)), height: lm.pitch + heightAdjustment + v)
        }
        let width = p.width ?? (max(measure(display, .unspecified, node).width, measure(placeholder, .unspecified, node).width) + h)
        let contentWidth = width.isFinite ? max(0, width - h) : nil
        let content = max(measure(display, ProposedViewSize(width: contentWidth, height: nil), node).height, lm.pitch)
        if fillsHeight, let ph = p.height { return CGSize(width: width, height: ph) }
        return CGSize(width: width, height: content + v)
    }

    func explicitAlignment(_ key: AlignmentKey, size: CGSize, proposal: ProposedViewSize, node: LayoutNode) -> CGFloat? {
        guard key == VerticalAlignment.firstTextBaseline.key || key == VerticalAlignment.lastTextBaseline.key else { return nil }
        let lm = lineMetrics(node)
        let scale = node.context.environment.displayScale
        let top = ceilPx(max(0, lm.pitch + heightAdjustment - lm.text) / 2, scale)
        return insets.top + top + lm.baseline
    }

    func spacing(node: LayoutNode) -> ViewSpacing { ViewSpacing() }
}

/// Draws selection, text (or the placeholder), the marked-text underline and
/// the caret, clipped to the content area.
@MainActor
func editableTextDraw(state: TextFieldState, placeholder: ResolvedText, environment env: EnvironmentValues) -> NodeDraw {
    { rec, size in
        state.size = size
        let insets = state.insets
        let content = CGRect(x: insets.leading, y: insets.top, width: max(0, size.width - insets.leading - insets.trailing),
                             height: max(0, size.height - insets.top - insets.bottom))
        let origin = CGPoint(x: insets.leading, y: insets.top + state.textTop)
        var items: [DisplayItem] = []
        var sub = DrawRecorder(id: rec.nextID(), textMeasurer: rec.textMeasurer, symbols: rec.symbols, mirrored: false)
        let empty = state.model.displayCharacters.isEmpty
        let geometry = empty ? nil : state.geometry()
        if let geometry { state.updateScroll(geometry) } else { state.scroll = .zero }
        let dx = Double(origin.x - state.scroll.x), dy = Double(origin.y - state.scroll.y)
        let tint = env.tintColorForControls
        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ c: Color.Resolved) {
            sub.add(.fill(RenderPath(rect: CGRect(x: x + dx, y: y + dy, width: w, height: h)), .color(c.renderColor), .nonZero))
        }
        // Selection.
        if let geometry, state.isFocused, !state.model.selection.isEmpty {
            var sel = tint
            sel.opacity = env.colorScheme == .dark ? 0.45 : 0.28
            for r in geometry.selectionRects(state.model.selectedRange) { rect(r.x, r.top, r.width, r.height, sel) }
        }
        // Text.
        let shown = empty ? placeholder : state.display
        if !shown.string.isEmpty, let tm = rec.textMeasurer {
            var t = shown
            if !state.multiline { t.paragraph.lineLimit = 1 }
            let m = tm.measure(t, proposal: ProposedViewSize(width: state.multiline ? content.width : nil, height: nil))
            var textRec = DrawRecorder(id: sub.nextID(), textMeasurer: rec.textMeasurer, symbols: rec.symbols, mirrored: false)
            textDraw(t, environment: env)(&textRec, CGSize(width: state.multiline ? content.width : m.size.width, height: m.size.height))
            sub.add(.group(DisplayGroup(transform: .translation(dx, dy), children: textRec.items)))
        }
        // Marked text.
        if let geometry, let r = state.model.displayMarkedRange {
            for box in geometry.selectionRects(r) {
                rect(box.x, box.top + box.height - 1.5, box.width, 1.5, Color.primary.resolve(in: env))
            }
        }
        // Caret.
        if state.isFocused && state.caretVisible && state.model.selection.isEmpty {
            if let geometry {
                let c = geometry.caret(at: state.model.displayCaret)
                rect(c.x, c.top, 2, c.height, tint)
            } else {
                rect(0, 0, 2, Double(state.emptyLine.height), tint)
            }
        }
        items = sub.items
        rec.add(.group(DisplayGroup(clips: [RenderClip(path: RenderPath(rect: content.insetBy(dx: -2, dy: 0)))], children: items)))
    }
}
