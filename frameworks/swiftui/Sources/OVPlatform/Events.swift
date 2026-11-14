import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Input and window events delivered by a platform back end (round R7,
// 09-open-design.md §4). Coordinates are in points of the window's content
// area, origin top-left; times are seconds of the back end's monotonic clock.

/// Identifies a window of a back end.
public typealias PlatformWindowID = UInt32

/// The device a pointer event comes from.
public enum PointerKind: Sendable, Hashable {
    case mouse
    case touch
    case pen
}

/// Where a pointer is in its press: down, moved (pressed or hovering), up,
/// or cancelled by the system.
public enum PointerPhase: Sendable, Hashable {
    case down
    case moved
    case up
    case cancelled
}

/// Keyboard modifiers held during an event.
public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    /// Alt on PC keyboards.
    public static let option = KeyModifiers(rawValue: 1 << 2)
    /// The Super/Meta ("logo") key on PC keyboards.
    public static let command = KeyModifiers(rawValue: 1 << 3)
    public static let capsLock = KeyModifiers(rawValue: 1 << 4)
    public static let numericPad = KeyModifiers(rawValue: 1 << 5)
}

/// A pointer press, motion or release (mouse buttons, touches, pens).
public struct PointerEvent: Sendable, Equatable {
    public var window: PlatformWindowID
    /// Stable for one touch or for the mouse (0).
    public var pointer: Int
    public var kind: PointerKind
    public var phase: PointerPhase
    public var location: CGPoint
    /// 1 primary, 2 middle, 3 secondary; 0 for motion without a button.
    public var button: Int
    /// True while a button (or the touch) is down; false for hover motion.
    public var isPressed: Bool
    public var modifiers: KeyModifiers
    public var timestamp: TimeInterval

    public init(window: PlatformWindowID, pointer: Int = 0, kind: PointerKind = .mouse, phase: PointerPhase,
                location: CGPoint, button: Int = 1, isPressed: Bool? = nil, modifiers: KeyModifiers = [],
                timestamp: TimeInterval) {
        self.window = window
        self.pointer = pointer
        self.kind = kind
        self.phase = phase
        self.location = location
        self.button = button
        self.isPressed = isPressed ?? (phase == .down || (phase == .moved && button != 0))
        self.modifiers = modifiers
        self.timestamp = timestamp
    }
}

/// Where a scroll event is in a touchpad gesture, or in the momentum that
/// follows one (B6-OPENVIEWS, ScrollGestureTracker.swift). A wheel notch has
/// none: `.none` in both phases.
public enum ScrollPhase: UInt8, Sendable, Hashable {
    /// Not part of a gesture (a wheel notch), or no momentum.
    case none
    /// The gesture's (or the momentum's) first event.
    case began
    case changed
    /// The fingers left the touchpad (or the momentum ran out); no delta.
    case ended
    /// Interrupted (a new gesture stops the momentum of the last one).
    case cancelled
}

/// A scroll-wheel or two-finger scroll step. `delta` is in points; positive
/// y scrolls towards the top of the content (wheel moved away from the user).
///
/// A touchpad gesture's events carry `phase` (began, changed, ended); the
/// momentum after the fingers leave carries `momentumPhase` (began, changed,
/// ended or cancelled), with `phase` none. Back ends that do not report
/// phases deliver `.none`; the application host infers them from precise
/// deltas and synthesizes the momentum (`ScrollGestureTracker`).
public struct ScrollEvent: Sendable, Equatable {
    public var window: PlatformWindowID
    public var location: CGPoint
    public var delta: CGSize
    /// True for high-resolution (trackpad) deltas, false for wheel notches.
    public var isPrecise: Bool
    public var modifiers: KeyModifiers
    public var timestamp: TimeInterval
    /// The touchpad gesture's phase (none for wheel notches and momentum).
    public var phase: ScrollPhase
    /// The momentum's phase (none during the gesture itself).
    public var momentumPhase: ScrollPhase

    public init(window: PlatformWindowID, location: CGPoint, delta: CGSize, isPrecise: Bool = false,
                modifiers: KeyModifiers = [], timestamp: TimeInterval, phase: ScrollPhase = .none,
                momentumPhase: ScrollPhase = .none) {
        self.window = window
        self.location = location
        self.delta = delta
        self.isPrecise = isPrecise
        self.modifiers = modifiers
        self.timestamp = timestamp
        self.phase = phase
        self.momentumPhase = momentumPhase
    }

    /// True when the event carries a gesture or momentum phase.
    public var hasPhase: Bool { phase != .none || momentumPhase != .none }

    /// True for the events after a gesture's first: its changes and end, and
    /// all of its momentum. They belong to the view the gesture began over.
    public var continuesGesture: Bool {
        momentumPhase != .none || phase == .changed || phase == .ended || phase == .cancelled
    }
}

/// A key, independent of layout for non-character keys; character keys carry
/// the unshifted character of the active layout (lower case for letters).
public enum Key: Sendable, Hashable {
    case character(Character)
    case `return`
    case escape
    case backspace
    case tab
    case space
    case deleteForward
    case leftArrow
    case rightArrow
    case upArrow
    case downArrow
    case home
    case end
    case pageUp
    case pageDown
    case clear
    case function(Int)
    /// A key this enumeration does not name (the back end's key code).
    case other(UInt32)
}

/// A key press, auto-repeat or release.
public struct KeyEvent: Sendable, Hashable {
    public var window: PlatformWindowID
    public var key: Key
    public var isDown: Bool
    public var isRepeat: Bool
    public var modifiers: KeyModifiers
    public var timestamp: TimeInterval

    public init(window: PlatformWindowID, key: Key, isDown: Bool = true, isRepeat: Bool = false,
                modifiers: KeyModifiers = [], timestamp: TimeInterval) {
        self.window = window
        self.key = key
        self.isDown = isDown
        self.isRepeat = isRepeat
        self.modifiers = modifiers
        self.timestamp = timestamp
    }
}

/// Committed text from the keyboard or an input method.
public struct TextInputEvent: Sendable, Hashable {
    public var window: PlatformWindowID
    public var text: String
    public var timestamp: TimeInterval

    public init(window: PlatformWindowID, text: String, timestamp: TimeInterval) {
        self.window = window
        self.text = text
        self.timestamp = timestamp
    }
}

/// An input method's uncommitted (marked) text; empty text ends composition.
public struct TextEditingEvent: Sendable, Hashable {
    public var window: PlatformWindowID
    public var text: String
    /// Cursor position within `text`, in characters.
    public var cursor: Int
    public var selectionLength: Int
    public var timestamp: TimeInterval

    public init(window: PlatformWindowID, text: String, cursor: Int = 0, selectionLength: Int = 0,
                timestamp: TimeInterval) {
        self.window = window
        self.text = text
        self.cursor = cursor
        self.selectionLength = selectionLength
        self.timestamp = timestamp
    }
}

/// Changes of a window's state.
public enum WindowEventKind: Sendable, Equatable {
    case shown
    case hidden
    case minimized
    case restored
    /// New size in points.
    case resized(CGSize)
    /// The display scale (pixels per point) changed.
    case scaleChanged(Double)
    case focusGained
    case focusLost
    /// The user asked to close the window (title-bar button, shortcut).
    case closeRequested
    /// The window's contents must be drawn again.
    case exposed
    /// The pointer left the window.
    case pointerLeft
}

/// Everything a back end delivers to the run loop.
public enum PlatformEvent: Sendable, Equatable {
    case pointer(PointerEvent)
    case scroll(ScrollEvent)
    case key(KeyEvent)
    case textInput(TextInputEvent)
    case textEditing(TextEditingEvent)
    case window(PlatformWindowID, WindowEventKind)
    /// A URL handed to the application (command line, desktop activation).
    case openURL(URL)
    /// The user or the system asked the application to quit.
    case quit
    /// The desktop settings changed (R10; the back end's `settings`).
    case settingsChanged
}
