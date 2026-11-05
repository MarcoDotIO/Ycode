import Foundation

/// The editing command a key means, in toolkit-free terms.
public enum EditorKeyCommand: Equatable, Sendable {
    case move(EditorMovement, forward: Bool, extending: Bool)
    case moveVertically(lines: Int, extending: Bool)
    case page(down: Bool, extending: Bool)
    case deleteBackward(EditorMovement)
    case deleteForward(EditorMovement)
    case newline
    case tab(backward: Bool)
    case selectAll, copy, cut, paste, undo, redo
    case escape
    /// Ask for completions (Ctrl+Space).
    case complete
}

/// A key in toolkit-free terms.
public enum EditorKey: Equatable, Sendable {
    case left, right, up, down, home, end, pageUp, pageDown
    case backspace, delete, enter, tab, escape, insert
    case character(Character)
}

/// Modifiers in toolkit-free terms: `primary` is Ctrl on Linux and ⌘ on macOS.
public struct EditorKeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = EditorKeyModifiers(rawValue: 1)
    public static let primary = EditorKeyModifiers(rawValue: 2)
    public static let alt = EditorKeyModifiers(rawValue: 4)
}

/// The Linux desktop's text editing keys (OpenViews' text fields use the same):
/// Ctrl+arrows by word, Ctrl+Home and End for the document, Ctrl+Backspace and
/// Delete by word, Ctrl+A/C/X/V/Z, Ctrl+Shift+Z redo, and the older
/// Ctrl+Insert, Shift+Insert and Shift+Delete. Ctrl+Y is not the editor's:
/// it is ⌘Y, Debug ▸ Deactivate Breakpoints, so it goes on to the menu bar.
public enum EditorKeyBindings {
    public static func command(_ key: EditorKey, _ m: EditorKeyModifiers) -> EditorKeyCommand? {
        let shift = m.contains(.shift), primary = m.contains(.primary)
        switch key {
        case .left: return .move(primary ? .word : .character, forward: false, extending: shift)
        case .right: return .move(primary ? .word : .character, forward: true, extending: shift)
        case .up: return primary ? nil : .moveVertically(lines: -1, extending: shift)
        case .down: return primary ? nil : .moveVertically(lines: 1, extending: shift)
        case .home: return .move(primary ? .document : .line, forward: false, extending: shift)
        case .end: return .move(primary ? .document : .line, forward: true, extending: shift)
        case .pageUp: return .page(down: false, extending: shift)
        case .pageDown: return .page(down: true, extending: shift)
        case .backspace: return .deleteBackward(primary ? .word : .character)
        case .delete:
            if shift, !primary { return .cut }
            return .deleteForward(primary ? .word : .character)
        case .enter: return primary ? nil : .newline
        case .tab: return primary ? nil : .tab(backward: shift)
        case .escape: return .escape
        case .insert:
            if primary { return .copy }
            if shift { return .paste }
            return nil
        case .character(" ") where primary && !shift:
            return .complete
        case .character(let c):
            guard primary, !m.contains(.alt) else { return nil }
            switch String(c).lowercased() {
            case "a" where !shift: return .selectAll
            case "c" where !shift: return .copy
            case "x" where !shift: return .cut
            case "v" where !shift: return .paste
            case "z": return shift ? .redo : .undo
            default: return nil
            }
        }
    }
}
