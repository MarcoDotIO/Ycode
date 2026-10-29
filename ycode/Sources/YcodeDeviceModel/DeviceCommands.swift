// The device windows' commands, their menu titles and key equivalents
// (device-hub.md §7 and "Ycode implementation"): one table for the viewer's
// menu bar and for the key handling of Ycode's hub and compact windows.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum DeviceCommand: String, Sendable, CaseIterable {
    // Controls menu (§7, in its order)
    case home, lock, appSwitcher, actionButton, rotateLeft, rotateRight, screenshot, recordScreen
    // Ycode extras in the Controls menu
    case volumeUp, volumeDown
    // View menu
    case zoomIn, zoomOut, zoomToFit, physicalSize, toggleBezels
    // Device menu
    case captureKeyboard, start, restart, shutDown, forceShutDown
    // Fold (the iPhone Duo's poses)
    case poseClosed, posePartiallyOpen, poseOpen

    /// The menu title (exact where the reference's is known, §7).
    public var title: String {
        switch self {
        case .home: "Home"
        case .lock: "Lock"
        case .appSwitcher: "App Switcher"
        case .actionButton: "Action Button"
        case .rotateLeft: "Rotate Left"
        case .rotateRight: "Rotate Right"
        case .screenshot: "Screenshot"
        case .recordScreen: "Record Screen"
        case .volumeUp: "Volume Up"
        case .volumeDown: "Volume Down"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .zoomToFit: "Zoom to Fit"
        case .physicalSize: "Physical Size"
        case .toggleBezels: "Hide Bezels"
        case .captureKeyboard: "Keyboard Capture"
        case .start: "Start"
        case .restart: "Restart"
        case .shutDown: "Shut Down"
        case .forceShutDown: "Force Shut Down"
        case .poseClosed: DevicePosture.closed.title
        case .posePartiallyOpen: DevicePosture.halfOpen.title
        case .poseOpen: DevicePosture.openFlat.title
        }
    }

    /// The key equivalent: the character and its modifiers (§7: Screenshot
    /// ⇧⌘S; the others are Ycode's, Q11).
    public var keyEquivalent: (key: String, modifiers: DeviceKeyModifiers)? {
        switch self {
        case .home: ("h", [.command, .shift])
        case .lock: ("l", [.command])
        case .rotateLeft: (DeviceKeyModifiers.leftArrow, [.command])
        case .rotateRight: (DeviceKeyModifiers.rightArrow, [.command])
        case .screenshot: ("s", [.command, .shift])
        case .recordScreen: ("r", [.command, .shift])
        case .volumeUp: (DeviceKeyModifiers.upArrow, [.command, .option])
        case .volumeDown: (DeviceKeyModifiers.downArrow, [.command, .option])
        case .zoomIn: ("+", [.command])
        case .zoomOut: ("-", [.command])
        case .zoomToFit: ("9", [.command])
        case .physicalSize: ("0", [.command])
        case .captureKeyboard: ("k", [.command, .shift])
        case .poseClosed: ("1", [.command, .option])
        case .posePartiallyOpen: ("2", [.command, .option])
        case .poseOpen: ("3", [.command, .option])
        default: nil
        }
    }

    /// The Controls menu, in order (§7), with Ycode's volume items after it.
    public static let controlsMenu: [DeviceCommand?] = [.home, .lock, .appSwitcher, .actionButton, nil, .rotateLeft, .rotateRight,
                                                        nil, .screenshot, .recordScreen, nil, .volumeUp, .volumeDown]
    /// The View menu's zoom items (§7).
    public static let zoomMenu: [DeviceCommand] = [.zoomIn, .zoomOut, .zoomToFit, .physicalSize]

    /// The command a key press is bound to (nil: none). `key` is the
    /// pressed key's character ignoring modifiers.
    public static func bound(to key: String, modifiers: DeviceKeyModifiers) -> DeviceCommand? {
        let k = key.lowercased()
        return allCases.first { c in
            guard let e = c.keyEquivalent else { return false }
            return e.modifiers == modifiers && (e.key == k || (c == .zoomIn && k == "=" ))
        }
    }
}

/// Modifier keys of a key equivalent (platform-neutral, for tests).
public struct DeviceKeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = DeviceKeyModifiers(rawValue: 1)
    public static let shift = DeviceKeyModifiers(rawValue: 2)
    public static let option = DeviceKeyModifiers(rawValue: 4)
    public static let control = DeviceKeyModifiers(rawValue: 8)

    // AppKit's function-key characters for the arrows (NSUpArrowFunctionKey …).
    public static let upArrow = String(UnicodeScalar(0xF700)!)
    public static let downArrow = String(UnicodeScalar(0xF701)!)
    public static let leftArrow = String(UnicodeScalar(0xF702)!)
    public static let rightArrow = String(UnicodeScalar(0xF703)!)
}

/// File names of screenshots and recordings (§4.4; Ycode decision for the
/// screenshot's name, the recording's follows the reference: "Screen
/// Recording" + the device name + a timestamp).
public enum DeviceCaptureNames {
    public static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: date)
    }

    public static func screenshot(device: String, at date: Date, timeZone: TimeZone = .current) -> String {
        "Screenshot \(sanitized(device)) \(timestamp(date, timeZone: timeZone)).png"
    }

    public static func recording(device: String, at date: Date, timeZone: TimeZone = .current) -> String {
        "Screen Recording \(sanitized(device)) \(timestamp(date, timeZone: timeZone)).mov"
    }

    static func sanitized(_ s: String) -> String { s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") }
}
