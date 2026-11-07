import Foundation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Automation hooks for apps built on OpenViews (not SwiftUI API): what the
// samples' drivers do with package access, offered publicly so an app in
// another package (Ycode's Linux IDE shell, `ycode-ide`) can be driven and
// photographed the same way: the running window's texts with their frames
// (menu titles, the items of open menus), screenshots read back from the
// window's presenter with open pop-ups drawn over it, synthetic input
// through the back end's queue (for compositors where no external input
// tool works, such as a headless Weston), and quitting.

/// Drivers' access to the running app's windows (OpenViews only).
@MainActor
public enum OpenViewsAutomation {
    /// One text drawn in a window, in that main window's points.
    public struct TextItem: Sendable, Equatable {
        public var text: String
        public var frame: CGRect
        /// Whether it is in a pop-up (an open menu, a picker list).
        public var inPopup: Bool
    }

    static var host: AppHost? { AppHost.current }

    /// The main (non-pop-up) windows, in creation order.
    static var mainWindows: [WindowHost] { host?.windows.filter { !$0.isPopup } ?? [] }

    /// The back end's name ("SDL x11", "headless").
    public static var backendName: String {
        guard let h = host else { return "none" }
        if let sdl = h.backend as? SDLBackend { return "\(h.backend.name) SDL \(sdl.libraryDescription)" }
        return h.backend.name
    }

    public static var windowCount: Int { mainWindows.count }

    /// A main window's size in points and pixels.
    public static func windowSize(_ index: Int = 0) -> (points: CGSize, pixels: (width: Int, height: Int))? {
        guard mainWindows.indices.contains(index) else { return nil }
        let w = mainWindows[index]
        return (w.size, w.platform.pixelSize)
    }

    /// The menu bar's titles of a main window.
    public static func menuTitles(_ index: Int = 0) -> [String] {
        guard mainWindows.indices.contains(index) else { return [] }
        return mainWindows[index].services.menuBar?.menuTitles ?? []
    }

    /// How many pop-ups (open menus, picker lists) the app shows.
    public static var openPopupCount: Int { host?.windows.filter(\.isPopup).count ?? 0 }

    /// Every `Text` drawn in a main window and in its open pop-ups, with
    /// frames in the main window's points (pop-up origins added).
    public static func texts(_ index: Int = 0) -> [TextItem] {
        guard mainWindows.indices.contains(index), let h = host else { return [] }
        let w = mainWindows[index]
        var out: [TextItem] = []
        func collect(_ win: WindowHost, origin: CGPoint, popup: Bool) {
            win.graph.root?.forEachNode { n in
                guard !n.isInSuspendedSubtree, let t = n.view as? Text, let f = HitTesting.frame(of: n, mirrorWidth: nil) else { return }
                out.append(TextItem(text: t.plainString, frame: f.offsetBy(dx: origin.x, dy: origin.y), inPopup: popup))
            }
        }
        collect(w, origin: .zero, popup: false)
        for p in h.windows where p.isPopup && owner(of: p) === w { collect(p, origin: origin(of: p), popup: true) }
        return out
    }

    /// The frames of the views marked with `accessibilityIdentifier(_:)` in
    /// a main window (its accessibility tree, R10), in points; the first
    /// view with an identifier wins.
    public static func identifiedFrames(_ index: Int = 0) -> [String: CGRect] {
        guard mainWindows.indices.contains(index) else { return [:] }
        var out: [String: CGRect] = [:]
        for e in AccessibilityTree.build(mainWindows[index]).flattened {
            if let id = e.identifier, out[id] == nil { out[id] = e.frame }
        }
        return out
    }

    /// What a main window tells the input method (issue 23): whether text
    /// input is on, the caret rectangle it was given in window points (the
    /// candidate window opens below it), and the focused text field's marked
    /// text (nil when the focused text is not a text field, such as a
    /// `TextSurface` editor).
    public static func textInput(_ index: Int = 0) -> (active: Bool, area: CGRect?, fieldMarkedText: String?) {
        guard mainWindows.indices.contains(index) else { return (false, nil, nil) }
        let w = mainWindows[index]
        let field = w.services.focus.focusedClient as? TextFieldState
        return (w.platform.isTextInputActive, w.textInputArea, field?.marked)
    }

    /// Writes a main window's image (pop-ups drawn over it) as PNG.
    @discardableResult
    public static func screenshot(_ index: Int = 0, to path: String) -> String {
        guard mainWindows.indices.contains(index), let h = host else { return "screenshot: no window" }
        let w = mainWindows[index]
        guard var image = w.presenter?.readback() ?? w.platform.readback() else { return "screenshot: no readback for \(path)" }
        let scale = Double(image.width) / max(1, w.size.width)
        for p in h.windows where p.isPopup && owner(of: p) === w {
            guard let pi = p.presenter?.readback() ?? p.platform.readback() else { continue }
            let o = origin(of: p)
            let ox = Int((o.x * scale).rounded()), oy = Int((o.y * scale).rounded())
            for y in 0..<pi.height where oy + y >= 0 && oy + y < image.height {
                for x in 0..<pi.width where ox + x >= 0 && ox + x < image.width {
                    image[ox + x, oy + y] = pi[x, y]
                }
            }
        }
        do {
            try image.writePNG(to: URL(fileURLWithPath: path))
            return "screenshot \(image.width)x\(image.height) written to \(path)"
        } catch {
            return "screenshot failed: \(error)"
        }
    }

    /// A click (press and release) at a point of a main window, through the
    /// back end's event queue; a point inside an open pop-up goes to that
    /// pop-up (the frames `texts` reports are in the main window's points).
    /// `button` 1 is primary, 3 secondary; `modifiers` are held during it
    /// (⌥-click, Ctrl-click).
    public static func click(at p: CGPoint, window index: Int = 0, button: Int = 1, modifiers: KeyModifiers = []) async {
        guard let h = host, mainWindows.indices.contains(index) else { return }
        let main = mainWindows[index]
        var target = main, local = p
        for popup in h.windows.reversed() where popup.isPopup && owner(of: popup) === main {
            let o = origin(of: popup)
            let r = CGRect(origin: o, size: popup.size)
            if r.contains(p) {
                target = popup
                local = CGPoint(x: p.x - o.x, y: p.y - o.y)
                break
            }
        }
        let id = target.platform.id
        // A back end whose pointer events carry no modifiers (SDL) takes
        // them from the keyboard's last state: a release of no key with
        // them held sets it, and one without them clears it afterwards.
        if !modifiers.isEmpty {
            h.backend.post(.key(KeyEvent(window: main.platform.id, key: .other(0), isDown: false, modifiers: modifiers, timestamp: h.backend.now)))
        }
        h.backend.post(.pointer(PointerEvent(window: id, phase: .down, location: local, button: button, isPressed: true, modifiers: modifiers,
                                             timestamp: h.backend.now)))
        try? await Task.sleep(nanoseconds: 50_000_000)
        h.backend.post(.pointer(PointerEvent(window: id, phase: .up, location: local, button: button, isPressed: false, modifiers: modifiers,
                                             timestamp: h.backend.now)))
        if !modifiers.isEmpty {
            h.backend.post(.key(KeyEvent(window: main.platform.id, key: .other(0), isDown: false, modifiers: [], timestamp: h.backend.now)))
        }
    }

    /// Moves the pointer (no button pressed) to a point of a main window, or
    /// of the open pop-up under it (R13: hover, tooltips, submenus).
    public static func move(to p: CGPoint, window index: Int = 0) {
        guard let h = host, mainWindows.indices.contains(index) else { return }
        let main = mainWindows[index]
        var target = main, local = p
        for popup in h.windows.reversed() where popup.isPopup && owner(of: popup) === main {
            let o = origin(of: popup)
            if CGRect(origin: o, size: popup.size).contains(p) {
                target = popup
                local = CGPoint(x: p.x - o.x, y: p.y - o.y)
                break
            }
        }
        h.backend.post(.pointer(PointerEvent(window: target.platform.id, kind: .mouse, phase: .moved, location: local, button: 0,
                                             isPressed: false, timestamp: h.backend.now)))
    }

    /// A key press with modifiers, through the back end's event queue.
    public static func press(_ key: Key, modifiers: KeyModifiers = [], window index: Int = 0) {
        guard let h = host, mainWindows.indices.contains(index) else { return }
        h.backend.post(.key(KeyEvent(window: mainWindows[index].platform.id, key: key, modifiers: modifiers, timestamp: h.backend.now)))
    }

    /// Typed text, through the back end's event queue.
    public static func type(_ text: String, window index: Int = 0) {
        guard let h = host, mainWindows.indices.contains(index) else { return }
        h.backend.post(.textInput(TextInputEvent(window: mainWindows[index].platform.id, text: text, timestamp: h.backend.now)))
    }

    /// A wheel step at a point, through the back end's event queue (positive y
    /// scrolls up, as `ScrollEvent`).
    public static func scroll(at p: CGPoint, delta: CGSize, window index: Int = 0) {
        guard let h = host, mainWindows.indices.contains(index) else { return }
        h.backend.post(.scroll(ScrollEvent(window: mainWindows[index].platform.id, location: p, delta: delta, timestamp: h.backend.now)))
    }

    /// Ends the app's run loop.
    public static func terminate() { host?.terminate() }

    // MARK: Windows and their chrome (B5-OPENVIEWS)

    /// The scene identifier of each main window (nil: an unnamed window
    /// group), in `mainWindows` order: drivers find Welcome or a wizard's
    /// window by its scene.
    public static var windowSceneIDs: [String?] { mainWindows.map(\.sceneID) }

    /// The index of the first main window of the scene `id`.
    public static func windowIndex(sceneID id: String) -> Int? { mainWindows.firstIndex { $0.sceneID == id } }

    /// Where a press at `p` goes in a window with a hidden title bar: the
    /// app, a window move or a resize.
    public static func hitRegion(at p: CGPoint, window index: Int = 0) -> WindowHitRegion {
        mainWindows.indices.contains(index) ? mainWindows[index].hitRegion(at: p) : .normal
    }

    /// Whether the window's on-demand menu bar is shown.
    public static func isMenuBarRevealed(_ index: Int = 0) -> Bool {
        mainWindows.indices.contains(index) ? mainWindows[index].windowChrome.menuBarRevealed : false
    }

    /// Shows or hides a window's on-demand menu bar (drivers' screenshots).
    public static func setMenuBarRevealed(_ shown: Bool, window index: Int = 0) {
        guard mainWindows.indices.contains(index) else { return }
        mainWindows[index].windowChrome.menuBarRevealed = shown
    }

    /// The window's active state as its views see it.
    public static func activeState(_ index: Int = 0) -> ControlActiveState? {
        mainWindows.indices.contains(index) ? mainWindows[index].activeState : nil
    }

    /// Fixes a window's active state (drivers' screenshots of an inactive
    /// window while it has the focus); nil follows the window system again.
    public static func setActiveState(_ state: ControlActiveState?, window index: Int = 0) {
        guard let h = host, mainWindows.indices.contains(index) else { return }
        mainWindows[index].activeStateOverride = state
        h.updateActiveStates()
    }

    /// Writes the window's accessibility tree (one element per line,
    /// indented; frames in window points), for drivers' reports.
    public static func accessibilityDump(_ index: Int = 0) -> String {
        guard mainWindows.indices.contains(index) else { return "" }
        var out: [String] = []
        func walk(_ e: AccessibilityElement, _ depth: Int) {
            let f = e.frame
            out.append(String(repeating: "  ", count: depth) + e.description
                       + String(format: " frame=%.1f,%.1f,%.1f,%.1f", f.minX, f.minY, f.width, f.height))
            for c in e.children { walk(c, depth + 1) }
        }
        walk(mainWindows[index].accessibilityTree(), 0)
        return out.joined(separator: "\n")
    }

    /// With a list set, each main window's frame adds how long it took
    /// (update, layout, drawing, presenting; seconds), for the benchmark drivers.
    public static var frameDurations: [Double]?
    /// Frames presented by the main window.
    public static func presentedFrames(window index: Int = 0) -> Int {
        mainWindows.indices.contains(index) ? mainWindows[index].presentedFrames : 0
    }

    static func owner(of p: WindowHost) -> WindowHost? {
        var w = p.popupOwner
        while let x = w, x.isPopup { w = x.popupOwner }
        return w
    }

    static func origin(of p: WindowHost) -> CGPoint {
        var o = p.popupOrigin
        var w = p.popupOwner
        while let x = w, x.isPopup {
            o.x += x.popupOrigin.x
            o.y += x.popupOrigin.y
            w = x.popupOwner
        }
        return o
    }
}
