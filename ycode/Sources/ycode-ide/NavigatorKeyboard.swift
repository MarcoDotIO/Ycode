import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// The keyboard of a navigator outline that draws its own rows (Tests,
/// Reports, Debug, Breakpoints, Symbols; P-051): a click gives it the
/// keyboard, Up and Down move the selection, Right and Left expand and
/// collapse, typed letters select the next row starting with them, and the
/// selection scrolls into view. Put it on the outline's `ScrollView`.
struct NavigatorKeyboard: ViewModifier {
    /// The rows in order, as the keyboard sees them.
    var rows: [OutlineRow]
    var selection: String?
    var select: (String) -> Void
    var toggle: ((String, Bool) -> Void)?
    @FocusState private var hasKeyboard: Bool
    @State private var typed = ""
    @State private var typedAt = Date.distantPast

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .onChange(of: selection) { _, id in if let id { proxy.scrollTo(id) } }
        }
        .focusable()
        .focused($hasKeyboard)
        .onChange(of: hasKeyboard) { _, on in ShellFocus.outlineHasKeyboard = on }
        .simultaneousGesture(TapGesture().onEnded { hasKeyboard = true })
        .onKeyPress(keys: [.downArrow, .upArrow, .rightArrow, .leftArrow], phases: [.down, .repeat]) { press in
            switch press.key {
            case .downArrow: move(1)
            case .upArrow: move(-1)
            default:
                guard let s = selection, let r = rows.first(where: { $0.id == s }), r.isExpandable else { break }
                let on = press.key == .rightArrow
                if r.isExpanded != on { toggle?(s, on) }
            }
            return .handled
        }
        .onKeyPress(phases: .down) { press in
            guard press.modifiers.subtracting([.shift, .capsLock]).isEmpty, press.characters.count == 1,
                  let ch = press.characters.first, ch.isLetter || ch.isNumber else { return .ignored }
            let now = Date()
            typed = now.timeIntervalSince(typedAt) < 1 ? typed + press.characters : press.characters
            typedAt = now
            if let id = OutlineRows.typeSelect(rows, current: selection, prefix: typed) { select(id) }
            return .handled
        }
    }

    func move(_ d: Int) {
        guard !rows.isEmpty else { return }
        let i = selection.flatMap { s in rows.firstIndex { $0.id == s } } ?? (d > 0 ? -1 : rows.count)
        select(rows[min(max(i + d, 0), rows.count - 1)].id)
    }
}

extension View {
    /// The outline's keyboard (`NavigatorKeyboard`).
    func navigatorKeyboard(rows: [OutlineRow], selection: String?, select: @escaping (String) -> Void,
                           toggle: ((String, Bool) -> Void)? = nil) -> some View {
        modifier(NavigatorKeyboard(rows: rows, selection: selection, select: select, toggle: toggle))
    }
}
