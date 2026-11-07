import Foundation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Accessibility (round R10; 08 §2, suite T-AX; public API names: the
// `accessibility…` modifiers, `AccessibilityTraits`,
// `AccessibilityChildBehavior`, `AccessibilityActionKind`,
// `AccessibilityAdjustmentDirection`, `AccessibilityHeadingLevel`,
// `AccessibilityNotification`).
//
// The tree is built on demand from a window's view graph
// (AccessibilityTree.swift), not kept up to date while nothing asks for it —
// as the reference built none without an assistive technology (08 §2). The
// modifiers below annotate their node; the builder reads the annotations,
// the texts and images, and the controls' own annotations.

/// What an accessibility element is (traits, as the public set names them).
public struct AccessibilityTraits: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let isButton = AccessibilityTraits(rawValue: 1 << 0)
    public static let isHeader = AccessibilityTraits(rawValue: 1 << 1)
    public static let isSelected = AccessibilityTraits(rawValue: 1 << 2)
    public static let isLink = AccessibilityTraits(rawValue: 1 << 3)
    public static let isSearchField = AccessibilityTraits(rawValue: 1 << 4)
    public static let isImage = AccessibilityTraits(rawValue: 1 << 5)
    public static let playsSound = AccessibilityTraits(rawValue: 1 << 6)
    public static let isKeyboardKey = AccessibilityTraits(rawValue: 1 << 7)
    public static let isStaticText = AccessibilityTraits(rawValue: 1 << 8)
    public static let isSummaryElement = AccessibilityTraits(rawValue: 1 << 9)
    public static let updatesFrequently = AccessibilityTraits(rawValue: 1 << 10)
    public static let startsMediaSession = AccessibilityTraits(rawValue: 1 << 11)
    public static let allowsDirectInteraction = AccessibilityTraits(rawValue: 1 << 12)
    public static let causesPageTurn = AccessibilityTraits(rawValue: 1 << 13)
    public static let isModal = AccessibilityTraits(rawValue: 1 << 14)
    public static let isToggle = AccessibilityTraits(rawValue: 1 << 15)
    public static let isTabBar = AccessibilityTraits(rawValue: 1 << 16)
}

/// How an element made with `accessibilityElement(children:)` treats the
/// elements inside.
public struct AccessibilityChildBehavior: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case ignore, contain, combine }
    let kind: Kind
    public static let ignore = AccessibilityChildBehavior(kind: .ignore)
    public static let contain = AccessibilityChildBehavior(kind: .contain)
    public static let combine = AccessibilityChildBehavior(kind: .combine)
}

/// The kinds of standard actions.
public struct AccessibilityActionKind: Hashable, Sendable {
    let name: String
    public static let `default` = AccessibilityActionKind(name: "default")
    public static let escape = AccessibilityActionKind(name: "escape")
    public static let magicTap = AccessibilityActionKind(name: "magicTap")
    public static let delete = AccessibilityActionKind(name: "delete")
    public static let showMenu = AccessibilityActionKind(name: "showMenu")
    public init(named name: Text) { self.name = name.plainString }
    init(name: String) { self.name = name }
}

public enum AccessibilityAdjustmentDirection: Hashable, Sendable {
    case increment
    case decrement
}

public enum AccessibilityHeadingLevel: UInt, Hashable, Sendable {
    case unspecified, h1, h2, h3, h4, h5, h6
}

/// Notifications for assistive technologies.
public enum AccessibilityNotification {
    /// An announcement (recorded; no assistive technology listens on the
    /// headless host).
    public struct Announcement: Sendable {
        public let text: String
        public init(_ text: String) { self.text = text }
        public init(_ text: Text) { self.text = text.plainString }
        @MainActor public func post() { AccessibilityAnnouncements.posted.append(text) }
    }

    public struct LayoutChanged: Sendable {
        public init() {}
        @MainActor public func post() {}
    }

    public struct ScreenChanged: Sendable {
        public init() {}
        @MainActor public func post() {}
    }
}

@MainActor
package enum AccessibilityAnnouncements {
    package static var posted: [String] = []
}

/// The role of an element (Ycode's set; it maps onto AT-SPI and AccessKit
/// roles).
package enum AccessibilityRole: String, Sendable, Hashable {
    case window, group, staticText, image, button, toggle, slider, stepper, link, textField, secureTextField,
         progressIndicator, picker, menuButton, list, row, menuBar, menuBarItem, menu, menuItem, toolbar, dialog,
         alert, tabList, tab, scrollView, splitter
}

/// A numeric value in a range (R10 export: AT-SPI's Value interface).
package struct AccessibilityRangeValue {
    package var current: Double
    package var minimum: Double
    package var maximum: Double
    package var step: Double
    /// Sets the value (nil: read-only, as a progress view).
    package var set: (@MainActor (Double) -> Void)?

    package init(current: Double, minimum: Double, maximum: Double, step: Double, set: (@MainActor (Double) -> Void)? = nil) {
        self.current = current
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
        self.set = set
    }
}

// MARK: - Annotations

/// What the modifiers of one view say (merged; the modifier nearest the
/// view wins — Ycode's rule).
package struct AccessibilityAttributes {
    package var label: String?
    package var value: String?
    package var hint: String?
    package var identifier: String?
    package var addTraits: AccessibilityTraits = []
    package var removeTraits: AccessibilityTraits = []
    package var hidden: Bool?
    package var children: AccessibilityChildBehavior?
    package var role: AccessibilityRole?
    package var sortPriority: Double?
    package var headingLevel: AccessibilityHeadingLevel?
    package var actions: [String: @MainActor () -> Void] = [:]
    package var adjust: (@MainActor (AccessibilityAdjustmentDirection) -> Void)?
    /// Controls: the label comes only from these texts (nil: from the
    /// children).
    package var isEnabled: Bool?
    /// A value read when the tree is built (controls: no body dependency).
    package var dynamicValue: (@MainActor () -> String?)?
    /// A numeric value with its range (sliders, progress; AT-SPI's Value
    /// interface), read when the tree is built.
    package var rangeValue: (@MainActor () -> AccessibilityRangeValue?)?
    /// Outline rows with children: expanded or collapsed.
    package var isExpanded: Bool?
    /// Buttons: the window's default button (Return) or cancel button
    /// (Escape) (B5-OPENVIEWS; council rows 98, 130).
    package var isDefaultButton: Bool?
    package var isCancelButton: Bool?

    package init() {}

    /// `inner` (nearer the view) over `self`.
    func merged(inner: AccessibilityAttributes) -> AccessibilityAttributes {
        var r = self
        r.label = inner.label ?? label
        r.value = inner.value ?? value
        r.hint = inner.hint ?? hint
        r.identifier = inner.identifier ?? identifier
        r.addTraits.formUnion(inner.addTraits)
        r.removeTraits.formUnion(inner.removeTraits)
        r.hidden = inner.hidden ?? hidden
        r.children = inner.children ?? children
        r.role = inner.role ?? role
        r.sortPriority = inner.sortPriority ?? sortPriority
        r.headingLevel = inner.headingLevel ?? headingLevel
        for (k, v) in inner.actions { r.actions[k] = v }
        r.adjust = inner.adjust ?? adjust
        r.isEnabled = inner.isEnabled ?? isEnabled
        r.dynamicValue = inner.dynamicValue ?? dynamicValue
        r.rangeValue = inner.rangeValue ?? rangeValue
        r.isExpanded = inner.isExpanded ?? isExpanded
        r.isDefaultButton = inner.isDefaultButton ?? isDefaultButton
        r.isCancelButton = inner.isCancelButton ?? isCancelButton
        return r
    }

    var isEmpty: Bool {
        label == nil && value == nil && hint == nil && identifier == nil && addTraits.isEmpty && removeTraits.isEmpty
            && hidden == nil && children == nil && role == nil && sortPriority == nil && headingLevel == nil
            && actions.isEmpty && adjust == nil && rangeValue == nil && isExpanded == nil && isDefaultButton == nil
            && isCancelButton == nil
    }
}

/// A view's accessibility annotation (read by the tree builder).
package struct AccessibilityModifier: PrimitiveModifier {
    package let attributes: AccessibilityAttributes
}

extension View {
    func accessibilityAttributes(_ edit: (inout AccessibilityAttributes) -> Void) -> some View {
        var a = AccessibilityAttributes()
        edit(&a)
        return modifier(AccessibilityModifier(attributes: a))
    }

    public func accessibilityLabel(_ label: Text) -> some View { accessibilityAttributes { $0.label = label.plainString } }
    public func accessibilityLabel(_ labelKey: LocalizedStringKey) -> some View { accessibilityLabel(Text(labelKey)) }
    @_disfavoredOverload
    public func accessibilityLabel<S: StringProtocol>(_ label: S) -> some View { accessibilityAttributes { $0.label = String(label) } }

    public func accessibilityValue(_ value: Text) -> some View { accessibilityAttributes { $0.value = value.plainString } }
    public func accessibilityValue(_ valueKey: LocalizedStringKey) -> some View { accessibilityValue(Text(valueKey)) }
    @_disfavoredOverload
    public func accessibilityValue<S: StringProtocol>(_ value: S) -> some View { accessibilityAttributes { $0.value = String(value) } }

    public func accessibilityHint(_ hint: Text) -> some View { accessibilityAttributes { $0.hint = hint.plainString } }
    public func accessibilityHint(_ hintKey: LocalizedStringKey) -> some View { accessibilityHint(Text(hintKey)) }
    @_disfavoredOverload
    public func accessibilityHint<S: StringProtocol>(_ hint: S) -> some View { accessibilityAttributes { $0.hint = String(hint) } }

    public func accessibilityIdentifier(_ identifier: String) -> some View {
        accessibilityAttributes { $0.identifier = identifier }
    }

    public func accessibilityAddTraits(_ traits: AccessibilityTraits) -> some View {
        accessibilityAttributes { $0.addTraits = traits }
    }

    public func accessibilityRemoveTraits(_ traits: AccessibilityTraits) -> some View {
        accessibilityAttributes { $0.removeTraits = traits }
    }

    public func accessibilityHidden(_ hidden: Bool) -> some View { accessibilityAttributes { $0.hidden = hidden } }

    /// Makes the view one element (`.ignore`: its own label only;
    /// `.combine`: the labels of the elements inside joined with ", ";
    /// `.contain`: a container of them).
    public func accessibilityElement(children: AccessibilityChildBehavior = .ignore) -> some View {
        accessibilityAttributes { $0.children = children }
    }

    public func accessibilityAction(_ actionKind: AccessibilityActionKind = .default,
                                    _ handler: @escaping @MainActor () -> Void) -> some View {
        accessibilityAttributes { $0.actions[actionKind.name] = handler }
    }

    public func accessibilityAction(named name: Text, _ handler: @escaping @MainActor () -> Void) -> some View {
        accessibilityAttributes { $0.actions[name.plainString] = handler }
    }

    public func accessibilityAction(named nameKey: LocalizedStringKey, _ handler: @escaping @MainActor () -> Void) -> some View {
        accessibilityAction(named: Text(nameKey), handler)
    }

    @_disfavoredOverload
    public func accessibilityAction<S: StringProtocol>(named name: S, _ handler: @escaping @MainActor () -> Void) -> some View {
        accessibilityAttributes { $0.actions[String(name)] = handler }
    }

    public func accessibilityAdjustableAction(_ handler: @escaping @MainActor (AccessibilityAdjustmentDirection) -> Void) -> some View {
        accessibilityAttributes { $0.adjust = handler }
    }

    public func accessibilitySortPriority(_ sortPriority: Double) -> some View {
        accessibilityAttributes { $0.sortPriority = sortPriority }
    }

    public func accessibilityHeading(_ level: AccessibilityHeadingLevel) -> some View {
        accessibilityAttributes {
            $0.headingLevel = level
            $0.addTraits = .isHeader
        }
    }

    /// Accepted (voice input is not supported).
    public func accessibilityInputLabels(_ inputLabels: [Text]) -> some View { self }
    @_disfavoredOverload
    public func accessibilityInputLabels<S: StringProtocol>(_ inputLabels: [S]) -> some View { self }

    /// Accepted (no rotor).
    public func accessibilityShowsLargeContentViewer() -> some View { self }

    /// A control's own annotation (role, value, actions).
    func accessibilityControl(_ role: AccessibilityRole, traits: AccessibilityTraits = [],
                              value: (@MainActor () -> String?)? = nil,
                              label: String? = nil, actions: [String: @MainActor () -> Void] = [:],
                              adjust: (@MainActor (AccessibilityAdjustmentDirection) -> Void)? = nil,
                              rangeValue: (@MainActor () -> AccessibilityRangeValue?)? = nil,
                              children: AccessibilityChildBehavior = .combine,
                              isDefault: Bool? = nil, isCancel: Bool? = nil) -> some View {
        accessibilityAttributes {
            $0.isDefaultButton = isDefault
            $0.isCancelButton = isCancel
            $0.rangeValue = rangeValue
            $0.role = role
            $0.children = children
            $0.addTraits = traits
            $0.dynamicValue = value
            $0.label = label
            $0.actions = actions
            $0.adjust = adjust
        }
    }
}

// MARK: - Default labels of Ycode's symbols

package enum SymbolAccessibilityLabels {
    /// Ycode's labels for its symbol set: "star.fill" is the reference's
    /// (08 §2: "Favorite"); the others are Ycode's words, or the name's first
    /// component in title case.
    static let table: [String: String] = [
        "star.fill": "Favorite", "star": "Favorite", "heart": "Love", "heart.fill": "Love",
        "magnifyingglass": "Search", "gear": "Settings", "gearshape": "Settings", "gearshape.fill": "Settings",
        "trash": "Delete", "trash.fill": "Delete", "plus": "Add", "plus.circle": "Add", "plus.circle.fill": "Add",
        "minus": "Remove", "minus.circle": "Remove", "xmark": "Close", "xmark.circle": "Close",
        "xmark.circle.fill": "Close", "checkmark": "Selected", "checkmark.circle": "Selected",
        "checkmark.circle.fill": "Selected", "chevron.left": "Back", "chevron.right": "Forward",
        "chevron.up": "Up", "chevron.down": "Down", "arrow.left": "Back", "arrow.right": "Forward",
        "arrow.up": "Up", "arrow.down": "Down", "arrow.clockwise": "Refresh", "info.circle": "Info",
        "questionmark.circle": "Help", "exclamationmark.triangle": "Warning", "exclamationmark.triangle.fill": "Warning",
        "square.and.arrow.up": "Share", "square.and.arrow.down": "Save", "doc": "Document", "doc.fill": "Document",
        "doc.text": "Document", "folder": "Folder", "folder.fill": "Folder", "house": "Home", "house.fill": "Home",
        "person": "Person", "person.fill": "Person", "person.crop.circle": "Account", "person.crop.circle.fill": "Account",
        "play": "Play", "play.fill": "Play", "pause": "Pause", "pause.fill": "Pause", "stop": "Stop", "stop.fill": "Stop",
        "bell": "Notifications", "bell.fill": "Notifications", "ellipsis": "More", "line.3.horizontal": "Menu",
        "sidebar.left": "Sidebar", "hammer": "Build", "hammer.fill": "Build",
        "rectangle.portrait.and.arrow.right": "Sign Out",
    ]

    package static func label(for name: String) -> String {
        if let l = table[name] { return l }
        let first = name.split(separator: ".").first.map(String.init) ?? name
        return first.prefix(1).uppercased() + first.dropFirst()
    }
}
