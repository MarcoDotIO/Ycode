import Foundation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Hardware keyboard: key equivalents and keyboard shortcuts (06 §5; names per
// api-inventory.md "Gestures, input" and "Controls"). Shortcuts registered by
// controls (`Button`) in a window are matched against key presses that the
// focused text field did not use.
//
// Linux mapping (our rule): `.command` in a shortcut is the desktop's primary
// modifier, so it matches Ctrl (and the Super key); `.control` matches Ctrl,
// `.option` Alt.

/// A key used in a keyboard shortcut.
public struct KeyEquivalent: Sendable, Hashable, ExpressibleByExtendedGraphemeClusterLiteral {
    public var character: Character

    public init(_ character: Character) { self.character = character }
    public init(extendedGraphemeClusterLiteral value: Character) { character = value }

    public static let upArrow = KeyEquivalent("\u{F700}")
    public static let downArrow = KeyEquivalent("\u{F701}")
    public static let leftArrow = KeyEquivalent("\u{F702}")
    public static let rightArrow = KeyEquivalent("\u{F703}")
    public static let escape = KeyEquivalent("\u{1B}")
    public static let delete = KeyEquivalent("\u{8}")
    public static let deleteForward = KeyEquivalent("\u{F728}")
    public static let home = KeyEquivalent("\u{F729}")
    public static let end = KeyEquivalent("\u{F72B}")
    public static let pageUp = KeyEquivalent("\u{F72C}")
    public static let pageDown = KeyEquivalent("\u{F72D}")
    public static let clear = KeyEquivalent("\u{F739}")
    public static let tab = KeyEquivalent("\t")
    public static let space = KeyEquivalent(" ")
    public static let `return` = KeyEquivalent("\r")

    /// The equivalent of a platform key (character keys in lower case).
    package init?(platformKey key: Key) {
        switch key {
        case .character(let c): self.init(Character(c.lowercased()))
        case .return: self = .return
        case .escape: self = .escape
        case .backspace: self = .delete
        case .tab: self = .tab
        case .space: self = .space
        case .deleteForward: self = .deleteForward
        case .leftArrow: self = .leftArrow
        case .rightArrow: self = .rightArrow
        case .upArrow: self = .upArrow
        case .downArrow: self = .downArrow
        case .home: self = .home
        case .end: self = .end
        case .pageUp: self = .pageUp
        case .pageDown: self = .pageDown
        case .clear: self = .clear
        case .function, .other: return nil
        }
    }
}

/// A key and modifiers that trigger a control.
public struct KeyboardShortcut: Sendable, Hashable {
    public struct Localization: Sendable, Hashable {
        let kind: Int
        public static let automatic = Localization(kind: 0)
        public static let withoutMirroring = Localization(kind: 1)
        public static let custom = Localization(kind: 2)
    }

    public var key: KeyEquivalent
    public var modifiers: EventModifiers
    public var localization: Localization

    public init(_ key: KeyEquivalent, modifiers: EventModifiers = .command) {
        self.init(key, modifiers: modifiers, localization: .automatic)
    }

    public init(_ key: KeyEquivalent, modifiers: EventModifiers = .command, localization: Localization) {
        self.key = key
        self.modifiers = modifiers
        self.localization = localization
    }

    /// Return, no modifiers: the default button of a window or dialog.
    public static let defaultAction = KeyboardShortcut(.return, modifiers: [])
    /// Escape, no modifiers.
    public static let cancelAction = KeyboardShortcut(.escape, modifiers: [])

    /// Whether a key press triggers this shortcut (Linux mapping above).
    package func matches(key: KeyEquivalent, modifiers m: KeyModifiers) -> Bool {
        guard key.character.lowercased() == self.key.character.lowercased() else { return false }
        let wantShift = modifiers.contains(.shift), wantOption = modifiers.contains(.option)
        let wantCommand = modifiers.contains(.command), wantControl = modifiers.contains(.control)
        guard m.contains(.shift) == wantShift, m.contains(.option) == wantOption else { return false }
        let ctrl = m.contains(.control), superKey = m.contains(.command)
        if wantCommand && wantControl { return ctrl && superKey }
        if wantCommand { return ctrl != superKey }
        if wantControl { return ctrl && !superKey }
        return !ctrl && !superKey
    }
}

private enum KeyboardShortcutKey: EnvironmentKey { static let defaultValue: KeyboardShortcut? = nil }

extension EnvironmentValues {
    /// The shortcut a `keyboardShortcut` modifier gave the controls below it.
    package var _keyboardShortcut: KeyboardShortcut? {
        get { self[KeyboardShortcutKey.self] }
        set { self[KeyboardShortcutKey.self] = newValue }
    }
}

extension View {
    /// Gives the controls in this view a keyboard shortcut.
    public func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> some View {
        environment(\._keyboardShortcut, KeyboardShortcut(key, modifiers: modifiers))
    }

    public func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command,
                                 localization: KeyboardShortcut.Localization) -> some View {
        environment(\._keyboardShortcut, KeyboardShortcut(key, modifiers: modifiers, localization: localization))
    }

    public func keyboardShortcut(_ shortcut: KeyboardShortcut) -> some View {
        environment(\._keyboardShortcut, shortcut)
    }

    /// A nil shortcut removes the shortcut of the controls below.
    public func keyboardShortcut(_ shortcut: KeyboardShortcut?) -> some View {
        environment(\._keyboardShortcut, shortcut)
    }
}

/// The shortcuts of one window's controls.
@MainActor
package final class ShortcutRegistry {
    package struct Entry {
        package let shortcut: KeyboardShortcut
        package let action: () -> Void
        package let isEnabled: () -> Bool
        /// A menu command's shortcut (R11): tried after the shortcuts of the
        /// window's own views.
        package var isCommand = false
        package init(shortcut: KeyboardShortcut, action: @escaping () -> Void, isEnabled: @escaping () -> Bool,
                     isCommand: Bool = false) {
            self.shortcut = shortcut
            self.action = action
            self.isEnabled = isEnabled
            self.isCommand = isCommand
        }
    }

    private var entries: [(owner: ObjectIdentifier, order: Int, entry: Entry)] = []
    private var counter = 0

    package init() {}

    package func register(_ owner: AnyObject, _ entry: Entry?) {
        let id = ObjectIdentifier(owner)
        let order = entries.first { $0.owner == id }?.order
        entries.removeAll { $0.owner == id }
        guard let entry else { return }
        counter += 1
        entries.append((id, order ?? counter, entry))
        entries.sort { $0.order < $1.order }
    }

    package func unregister(_ owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        entries.removeAll { $0.owner == id }
    }

    package var count: Int { entries.count }

    /// The registered shortcuts (tests).
    package var registered: [Entry] { entries.map(\.entry) }

    /// Runs the first enabled shortcut matching the key press; true if one ran.
    package func perform(key: Key, modifiers: KeyModifiers) -> Bool {
        guard let k = KeyEquivalent(platformKey: key) else { return false }
        // Views first, then menu commands (R11: the focused window's views,
        // then its menu bar, as desktop key equivalents go).
        for pass in [false, true] {
            for e in entries where e.entry.isCommand == pass && e.entry.shortcut.matches(key: k, modifiers: modifiers)
                && e.entry.isEnabled() {
                e.entry.action()
                return true
            }
        }
        return false
    }
}

/// How text input capitalises typed letters.
public struct TextInputAutocapitalization: Sendable, Equatable {
    package enum Kind: Sendable, Equatable { case never, words, sentences, characters }
    package let kind: Kind

    public static let never = TextInputAutocapitalization(kind: .never)
    public static let words = TextInputAutocapitalization(kind: .words)
    public static let sentences = TextInputAutocapitalization(kind: .sentences)
    public static let characters = TextInputAutocapitalization(kind: .characters)
}

private enum AutocapitalizationKey: EnvironmentKey { static let defaultValue: TextInputAutocapitalization? = nil }
/// The platform's default when no modifier sets one: sentences, as measured
/// on the reference device (06 §5: "Hi" from the keys h, i). The Linux
/// desktop host sets `.never` (desktop text fields do not capitalise).
private enum DefaultAutocapitalizationKey: EnvironmentKey {
    static let defaultValue = TextInputAutocapitalization.sentences
}

extension EnvironmentValues {
    package var _textInputAutocapitalization: TextInputAutocapitalization? {
        get { self[AutocapitalizationKey.self] }
        set { self[AutocapitalizationKey.self] = newValue }
    }

    package var _defaultAutocapitalization: TextInputAutocapitalization {
        get { self[DefaultAutocapitalizationKey.self] }
        set { self[DefaultAutocapitalizationKey.self] = newValue }
    }
}

extension View {
    /// How text fields below capitalise typed letters.
    public func textInputAutocapitalization(_ autocapitalization: TextInputAutocapitalization?) -> some View {
        environment(\._textInputAutocapitalization, autocapitalization)
    }

    /// Accepted for source compatibility; there is no autocorrection.
    public func autocorrectionDisabled(_ disable: Bool = true) -> some View { self }
}
