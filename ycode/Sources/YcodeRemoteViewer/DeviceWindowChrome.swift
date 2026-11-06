// The Linux device window's chrome (specs/ide/device-hub.md §4.4, §11.1,
// §11.2; council round 3 checklist rows 65 and 67), without a toolkit so it
// is tested everywhere: the floating control capsules at the bottom of the
// window (DeviceControlsLayout, shared with the macOS canvas), the controls'
// state and help, the More Actions circle and its menu (the commands that
// had push buttons before: Lock, the volume, the sound, the scale, bezels,
// the frame rate, Refresh Display), the light and dark palettes, and where
// a tooltip goes. The SDL window draws it.
//
// Ycode decisions: the device window on Linux has no toolbar, so More
// Actions is a glass circle at the canvas's top right (as the compact
// window's capsule sits at the top right); Record is shown disabled with
// "Record Screen is not in this beta" (the Linux viewer cannot record yet).

import Foundation
import YcodeDeviceModel
import YcodeDisplayStream

/// An RGBA colour, 0…1.
public struct ViewerColor: Equatable, Sendable {
    public var r, g, b, a: Float
    public init(_ hex: UInt32, alpha: Float = 1) {
        r = Float((hex >> 16) & 0xFF) / 255
        g = Float((hex >> 8) & 0xFF) / 255
        b = Float(hex & 0xFF) / 255
        a = alpha
    }
    public func with(alpha: Float) -> ViewerColor { var c = self; c.a = alpha; return c }
    public var bytes: (UInt8, UInt8, UInt8, UInt8) {
        (UInt8((r * 255).rounded()), UInt8((g * 255).rounded()), UInt8((b * 255).rounded()), UInt8((a * 255).rounded()))
    }
}

/// Light or dark: `--appearance`, then OpenViews' sources (OV_COLOR_SCHEME,
/// its settings file's `color-scheme`), then the desktop's (SDL's system
/// theme, which follows the freedesktop portal), else light.
public enum ViewerAppearance: String, Sendable, CaseIterable {
    case light, dark

    public static func resolve(argument: String?, environment env: [String: String], settingsFileText: String?,
                               systemDark: Bool?) -> ViewerAppearance {
        func parse(_ v: String?) -> ViewerAppearance? {
            switch v?.trimmingCharacters(in: .whitespaces).lowercased() {
            case "dark", "prefer-dark": .dark
            case "light", "default", "prefer-light": .light
            default: nil
            }
        }
        if let a = parse(argument) { return a }
        if let a = parse(env["OV_COLOR_SCHEME"]) { return a }
        if let text = settingsFileText {
            for line in text.split(whereSeparator: \.isNewline) {
                let l = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                guard let eq = l.firstIndex(of: "=") else { continue }
                let k = l[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                if k == "color-scheme" || k == "appearance", let a = parse(String(l[l.index(after: eq)...])) { return a }
            }
        }
        if let d = systemDark { return d ? .dark : .light }
        return .light
    }

    /// OpenViews' settings file: $OV_SETTINGS_FILE, else $XDG_CONFIG_HOME (~/.config)/openviews/settings.conf.
    public static func settingsFilePath(environment env: [String: String]) -> String {
        if let f = env["OV_SETTINGS_FILE"], !f.isEmpty { return f }
        let config = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (NSHomeDirectory() + "/.config")
        return config + "/openviews/settings.conf"
    }
}

/// The window's colours (§11.1 for the light glass: fill #FAFAFA–#FDFCFC,
/// rim #EBEBEB at the top and #E7E7E7 at the bottom, black glyphs, the
/// divider #E9E9E9, the current pose #007AFF on #BFDDFE, the other poses
/// filled #BEBEBE; dark: Ycode's equivalents).
public struct ViewerPalette: Equatable, Sendable {
    public var canvas: ViewerColor
    public var glassTop: ViewerColor, glassBottom: ViewerColor
    public var rimTop: ViewerColor, rimBottom: ViewerColor
    public var shadow: ViewerColor
    public var glyph: ViewerColor
    public var accent: ViewerColor, accentFill: ViewerColor, poseFill: ViewerColor
    public var divider: ViewerColor
    public var text: ViewerColor, secondaryText: ViewerColor
    public var menuFill: ViewerColor, menuRim: ViewerColor, menuHighlight: ViewerColor, menuHighlightText: ViewerColor
    public var disabledAlpha: Float

    public static let light = ViewerPalette(
        canvas: ViewerColor(0xFFFFFF), glassTop: ViewerColor(0xFDFCFC), glassBottom: ViewerColor(0xFAFAFA),
        rimTop: ViewerColor(0xEBEBEB), rimBottom: ViewerColor(0xE7E7E7), shadow: ViewerColor(0x000000, alpha: 0.05),
        glyph: ViewerColor(0x000000), accent: ViewerColor(0x007AFF), accentFill: ViewerColor(0xBFDDFE), poseFill: ViewerColor(0xBEBEBE),
        divider: ViewerColor(0xE9E9E9), text: ViewerColor(0x000000), secondaryText: ViewerColor(0x6E6E73),
        menuFill: ViewerColor(0xF6F6F6, alpha: 0.98), menuRim: ViewerColor(0xD4D4D6), menuHighlight: ViewerColor(0x007AFF),
        menuHighlightText: ViewerColor(0xFFFFFF), disabledAlpha: 0.3)

    public static let dark = ViewerPalette(
        canvas: ViewerColor(0x1E1E1E), glassTop: ViewerColor(0x3A3A3C), glassBottom: ViewerColor(0x333335),
        rimTop: ViewerColor(0x545456), rimBottom: ViewerColor(0x29292B), shadow: ViewerColor(0x000000, alpha: 0.22),
        glyph: ViewerColor(0xFFFFFF), accent: ViewerColor(0x0A84FF), accentFill: ViewerColor(0x0A3D73), poseFill: ViewerColor(0x6E6E73),
        divider: ViewerColor(0x545456), text: ViewerColor(0xFFFFFF), secondaryText: ViewerColor(0x98989D),
        menuFill: ViewerColor(0x2C2C2E, alpha: 0.98), menuRim: ViewerColor(0x48484A), menuHighlight: ViewerColor(0x0A84FF),
        menuHighlightText: ViewerColor(0xFFFFFF), disabledAlpha: 0.3)

    public static func of(_ a: ViewerAppearance) -> ViewerPalette { a == .dark ? .dark : .light }
}

/// One control in the capsules.
public struct ViewerControl: Equatable, Sendable {
    public var command: DeviceCommand
    /// Its hit area (window units).
    public var rect: ViewerRect
    public var enabled: Bool
    /// The current pose (drawn in the accent colour).
    public var highlighted: Bool
    public var help: String
}

/// An item of the More Actions menu.
public struct ViewerMenuItem: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case command(DeviceCommand)
        case mute
        case scale(ViewerScaleMode)
        case statusLine
        case refresh
    }
    public var title: String
    public var shortcut: String
    public var action: Action?
    public var checked = false
    public var enabled = true
    public var isSeparator: Bool { action == nil && title.isEmpty }
    public static let separator = ViewerMenuItem(title: "", shortcut: "", action: nil)
}

public enum DeviceWindowChrome {
    /// The More Actions circle: 30 across, 8 from the top and right edges.
    public static let moreSize: Double = 30
    public static let moreInset: Double = 8
    public static let menuWidth: Double = 236
    public static let menuRowHeight: Double = 22
    public static let separatorHeight: Double = 9
    public static let tooltipDelay: Double = 0.6

    /// The help text of a control (tooltips).
    public static func help(_ c: DeviceCommand, recordingAvailable: Bool = false) -> String {
        switch c {
        case .home: "Home"
        case .screenshot: "Screenshot (Ctrl+Shift+S)"
        case .recordScreen: recordingAvailable ? "Record Screen" : "Record Screen is not in this beta"
        case .rotateLeft: "Rotate (Alt-click to rotate right)"
        case .resetCamera: "Reset Camera"
        case .poseClosed: "Closed"
        case .posePartiallyOpen: "Partially Open"
        case .poseOpen: "Open"
        default: c.title
        }
    }

    public static func moreButton(windowWidth: Double) -> ViewerRect {
        ViewerRect(x: windowWidth - moreInset - moreSize, y: moreInset, width: moreSize, height: moreSize)
    }

    /// The menu's rectangle (under the circle, right-aligned with it).
    public static func menuRect(items: [ViewerMenuItem], windowWidth: Double) -> ViewerRect {
        let h = items.reduce(8.0) { $0 + ($1.isSeparator ? separatorHeight : menuRowHeight) }
        let m = moreButton(windowWidth: windowWidth)
        return ViewerRect(x: max(4, m.x + m.width - menuWidth), y: m.y + m.height + 6, width: menuWidth, height: h)
    }

    /// The item under a window point (nil: none or a separator).
    public static func menuItem(at x: Double, _ y: Double, items: [ViewerMenuItem], windowWidth: Double) -> Int? {
        let r = menuRect(items: items, windowWidth: windowWidth)
        guard r.contains(x, y) else { return nil }
        var top = r.y + 4
        for (i, item) in items.enumerated() {
            let h = item.isSeparator ? separatorHeight : menuRowHeight
            if y >= top, y < top + h { return item.isSeparator || !item.enabled ? nil : i }
            top += h
        }
        return nil
    }

    /// Where a tooltip for `rect` goes: above it, centred, inside the window.
    public static func tooltipRect(for rect: ViewerRect, text: String, windowWidth: Double, charWidth: Double = 8) -> ViewerRect {
        let w = Double(text.count) * charWidth + 16, h = 22.0
        let x = min(max(4, rect.x + rect.width / 2 - w / 2), max(4, windowWidth - 4 - w))
        return ViewerRect(x: x, y: rect.y - h - 6, width: w, height: h)
    }
}

extension RemoteDeviceSession {
    /// What the capsules hold for this device (a Vision Pro by its hello).
    public var controlDevice: DeviceControlsLayout.Device {
        DeviceControlsLayout.Device(spec: spec, foldable: spec.isFoldable || hello?.foldable == true,
                                    spatial: isSpatial || spec.family == .vision)
    }

    /// The controls by capsule, left to right.
    public var controlGroups: [[DeviceCommand]] { DeviceControlsLayout.groups(controlDevice) }

    /// The capsules' rectangles in the window.
    public var controlCapsules: [ViewerRect] {
        DeviceControlsLayout.capsuleRects(controlGroups, canvasWidth: windowWidth, canvasHeight: windowHeight).map(ViewerRect.init)
    }

    /// The dividers' x positions in the window (Rotate │ the poses).
    public var controlDividers: [Double] {
        zip(controlGroups, controlCapsules).compactMap { g, r in DeviceControlsLayout.dividerCentre(of: g).map { r.x + $0 } }
    }

    /// The pose the hinge is at (a foldable).
    public var posture: DevicePosture? {
        guard controlDevice.foldable else { return nil }
        return panel.flatMap { DevicePosture(rawValue: $0.posture) } ?? .closed
    }

    /// The display shows the device and takes input.
    public var isLive: Bool { phase == "live" }

    /// Each control with its state (Record disabled: not in this beta).
    public var controls: [ViewerControl] {
        DeviceControlsLayout.controlRects(controlGroups, canvasWidth: windowWidth, canvasHeight: windowHeight).map { c, r in
            let enabled: Bool = switch c {
            case .recordScreen: false
            case .rotateLeft: isLive && canRotate
            case .poseClosed, .posePartiallyOpen, .poseOpen: isLive && controlDevice.foldable
            default: isLive
            }
            let current: Bool = switch (c, posture) {
            case (.poseClosed, .closed?), (.posePartiallyOpen, .halfOpen?), (.poseOpen, .openFlat?): true
            default: false
            }
            return ViewerControl(command: c, rect: ViewerRect(r), enabled: enabled, highlighted: current,
                                 help: DeviceWindowChrome.help(c))
        }
    }

    /// The control under a window point.
    public func control(at x: Double, _ y: Double) -> ViewerControl? { controls.first { $0.rect.contains(x, y) } }

    /// Moves the hinge to `angle` (the pose buttons; foldable.md §8.3).
    public func fold(to angle: Int) {
        guard controlDevice.foldable else { return }
        client.send(.fold(angle: UInt16(min(180, max(0, angle))), instant: false))
    }

    /// The More Actions menu (Ycode decision, see the file's comment).
    public func moreItems(muted: Bool?, statusLine: Bool) -> [ViewerMenuItem] {
        var out: [ViewerMenuItem] = [ViewerMenuItem(title: "Lock", shortcut: "Ctrl+L", action: .command(.lock), enabled: isLive)]
        if spec.hasVolumeButtons {
            out += [ViewerMenuItem(title: "Volume Up", shortcut: "Ctrl+Up", action: .command(.volumeUp), enabled: isLive),
                    ViewerMenuItem(title: "Volume Down", shortcut: "Ctrl+Down", action: .command(.volumeDown), enabled: isLive)]
        }
        if controlDevice.rotates, !controlDevice.spatial {
            out.append(ViewerMenuItem(title: "Rotate Right", shortcut: "Ctrl+Right", action: .command(.rotateRight), enabled: isLive && canRotate))
        }
        if let muted {
            out += [.separator, ViewerMenuItem(title: muted ? "Unmute Sound" : "Mute Sound", shortcut: "Ctrl+M", action: .mute)]
        }
        out += [.separator,
                ViewerMenuItem(title: "Zoom to Fit", shortcut: "Ctrl+1", action: .scale(.fit), checked: scaleMode == .fit),
                ViewerMenuItem(title: "Point Accurate", shortcut: "Ctrl+2", action: .scale(.point), checked: scaleMode == .point),
                ViewerMenuItem(title: "Pixel Accurate", shortcut: "Ctrl+3", action: .scale(.pixel), checked: scaleMode == .pixel),
                .separator]
        if spec.hasFrame {
            out.append(ViewerMenuItem(title: bezels ? "Hide Bezels" : "Show Bezels", shortcut: "Ctrl+B", action: .command(.toggleBezels)))
        }
        out += [ViewerMenuItem(title: "Show Frame Rate", shortcut: "Ctrl+F", action: .statusLine, checked: statusLine),
                ViewerMenuItem(title: "Refresh Display", shortcut: "Ctrl+R", action: .refresh)]
        return out
    }
}

extension ViewerRect {
    init(_ r: CGRect) { self.init(x: Double(r.minX), y: Double(r.minY), width: Double(r.width), height: Double(r.height)) }
}
