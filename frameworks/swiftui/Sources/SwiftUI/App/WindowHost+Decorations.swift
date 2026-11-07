import Foundation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Client-side decorations of a window (B5-OPENVIEWS; WindowStyle.swift,
// WindowButtons.swift): the hit test that lets the window system move and
// resize an undecorated window, the window buttons' hover and Alt state,
// the on-demand menu bar's reveal, and the window's active state.
//
// Hit test (Ycode's rules, after the macOS IDE's window):
// - within 5 points of an edge (12 at a corner) a resizable window that is
//   neither maximised nor full screen resizes;
// - on the title-bar band (`titleBarHeight` below the content's top), a
//   point where no view takes presses or hovers (no gesture, no hover
//   handler) moves the window: the toolbar's background and its title text
//   do, its buttons and fields do not;
// - everything else is the app's.
//
// On-demand menu bar: the pointer resting within 3 points of the window's
// top edge for 0.35 s reveals it, as does F10 (which opens the first menu)
// or a tap of Alt alone; moving the pointer below it, Escape, or closing the
// last menu hides it again (unless the pointer is over it).

/// Seconds the pointer must rest at the top edge before the menu bar shows.
package let menuBarRevealDelay: TimeInterval = 0.35

private final class RevealTimerOwner {}

extension WindowHost {
    package var windowChrome: WindowChromeState { services.windowChrome }

    /// The top of the content: below an in-window menu bar.
    var chromeContentTop: CGFloat { chrome?.menuBar == true ? MenuBarMetrics.height : 0 }

    /// Where a press at `p` (window points) goes: the app, a window move or
    /// a resize.
    package func hitRegion(at p: CGPoint) -> WindowHitRegion {
        let state = services.windowChrome
        guard !isPopup, state.style == .hiddenTitleBar || state.style == .plain else { return .normal }
        let size = platform.size
        let deco = platform as? any PlatformWindowDecorations
        let full = (deco?.isMaximized ?? false) || (deco?.isFullscreen ?? false)
        if isResizable && state.behaviors.resize != .disabled && !full {
            let e: CGFloat = 5, c: CGFloat = 12
            let left = p.x < e, right = p.x > size.width - e, top = p.y < e, bottom = p.y > size.height - e
            let nearLeft = p.x < c, nearRight = p.x > size.width - c, nearTop = p.y < c, nearBottom = p.y > size.height - c
            if (top && nearLeft) || (left && nearTop) { return .resizeTopLeft }
            if (top && nearRight) || (right && nearTop) { return .resizeTopRight }
            if (bottom && nearLeft) || (left && nearBottom) { return .resizeBottomLeft }
            if (bottom && nearRight) || (right && nearBottom) { return .resizeBottomRight }
            if top { return .resizeTop }
            if bottom { return .resizeBottom }
            if left { return .resizeLeft }
            if right { return .resizeRight }
        }
        // Pop-ups shown inside the window, and a revealed menu bar, are the
        // app's.
        if !overlayPopups.isEmpty { return .normal }
        if state.menuBarOnDemand && state.menuBarRevealed && p.y < MenuBarMetrics.height { return .normal }
        let bandTop = chromeContentTop
        guard p.y >= bandTop, p.y < bandTop + state.titleBarHeight else { return .normal }
        for node in gestures.hitPath(at: p) where Self.takesPointer(node) { return .normal }
        return .draggable
    }

    /// A view that handles presses or hovers itself.
    private static func takesPointer(_ node: ViewNode) -> Bool {
        guard node.environment.isEnabled else { return false }
        return node.primitiveState is GestureAttachment || node.primitiveState is any HoverHandling
    }

    /// Keeps the buttons' Alt state and the on-demand menu bar in step with
    /// the pointer.
    func trackChromePointer(_ p: PointerEvent) {
        let state = services.windowChrome
        state.lastPointer = p.location
        guard !isPopup else { return }
        let option = p.modifiers.contains(.option)
        if state.optionHeld != option { state.optionHeld = option }
        guard state.menuBarOnDemand, p.phase == .moved else { return }
        let owner = revealTimerOwner
        if p.location.y <= 3 {
            if !state.menuBarRevealed && !services.hasTimer(owner) {
                services.setTimer(owner, at: p.timestamp + menuBarRevealDelay) { [weak self] _ in
                    guard let self else { return }
                    let st = self.services.windowChrome
                    if let lp = st.lastPointer, lp.y <= 3 { st.menuBarRevealed = true }
                }
            }
        } else {
            services.setTimer(owner, at: nil) { _ in }
            if state.menuBarRevealed, p.location.y > MenuBarMetrics.height + 8, services.menuBar?.openIndex == nil {
                state.menuBarRevealed = false
            }
        }
    }

    /// Alt tapped alone toggles the on-demand menu bar; Escape hides it.
    /// True when the key was used.
    func trackChromeKey(_ k: KeyEvent) -> Bool {
        let state = services.windowChrome
        guard state.menuBarOnDemand, !isPopup else { return false }
        let isAlt: Bool
        if case .other(let code) = k.key, code == 0x4000_00E2 || code == 0x4000_00E6 { isAlt = true } else { isAlt = false }
        if isAlt {
            if k.isDown {
                altTapPending = true
            } else if altTapPending {
                altTapPending = false
                state.menuBarRevealed.toggle()
                if !state.menuBarRevealed { services.menuBar?.close() }
            }
            return false
        }
        if k.isDown { altTapPending = false }
        if k.isDown, k.key == .escape, state.menuBarRevealed, services.menuBar?.openIndex == nil {
            state.menuBarRevealed = false
            return true
        }
        return false
    }

    /// The last menu of an on-demand menu bar closed.
    func onDemandMenuClosed() {
        let state = services.windowChrome
        guard state.menuBarOnDemand else { return }
        if let p = state.lastPointer, p.y <= MenuBarMetrics.height { return }
        state.menuBarRevealed = false
    }

    /// Sets the window's active state (the window buttons' colours,
    /// `controlActiveState`).
    func setActiveState(_ s: ControlActiveState) {
        guard s != activeState else { return }
        activeState = s
        graph.updateEnvironment { $0.controlActiveState = s }
        exposed()
    }
}

extension WindowServices {
    func hasTimer(_ owner: AnyObject) -> Bool { timerDeadline(owner) != nil }
}

extension AppHost {
    /// Configures a new window's chrome state from its scene (B5-OPENVIEWS).
    func configureDecorations(_ w: WindowHost, scene: SceneDescription, onDemandMenuBar: Bool) {
        let state = w.services.windowChrome
        state.style = scene.windowStyle
        state.titleBarHeight = scene.titleBarHeight
        state.menuBarOnDemand = onDemandMenuBar
        state.close = { [weak self, weak w] in
            guard let self, let w else { return }
            self.requestClose(w)
        }
        state.minimize = { [weak w] in w?.platform.minimize() }
        state.zoom = { [weak w] maximize in
            guard let w, let d = w.platform as? any PlatformWindowDecorations else { return }
            let b = w.services.windowChrome.behaviors
            if d.isFullscreen {
                d.setFullscreen(false)
            } else if maximize || b.fullScreen == .disabled {
                guard b.resize != .disabled else { return }
                d.setMaximized(!d.isMaximized)
            } else {
                d.setFullscreen(true)
            }
        }
        if !w.isPopup, scene.windowStyle == .hiddenTitleBar || scene.windowStyle == .plain,
           let d = w.platform as? any PlatformWindowDecorations, !d.isDecorated {
            d.setHitTest { [weak w] p in w?.hitRegion(at: p) ?? .normal }
        }
    }

    /// The window's close button, or the window system's close request:
    /// the last window asks the app first (unsaved changes).
    package func requestClose(_ w: WindowHost) {
        if w.services.windowChrome.behaviors.dismiss == .disabled { return }
        if windows.filter({ !$0.isPopup }).count == 1, ApplicationTermination.shouldTerminate?() == false { return }
        closeWindow(w)
    }

    /// Every main window's active state from the window that has keyboard
    /// focus (all `.key` until the window system has said).
    func updateActiveStates() {
        for w in windows {
            var root = w
            while root.isPopup, let o = root.popupOwner { root = o }
            let key = !windowFocusKnown || activeWindowID == root.platform.id
            w.setActiveState(root.activeStateOverride ?? (key ? .key : .inactive))
        }
    }

    /// The resolved menu-bar presentation of a scene's windows:
    /// `OV_MENU_BAR=inline|on-demand` first, then the scene's, then the
    /// style's default.
    func menuBarPresentation(for scene: SceneDescription) -> MenuBarPresentation {
        switch ProcessInfo.processInfo.environment["OV_MENU_BAR"]?.lowercased() {
        case "inline", "in-window": return .inWindow
        case "on-demand", "ondemand", "overlay": return .onDemand
        default: break
        }
        if scene.menuBarPresentation != .automatic { return scene.menuBarPresentation }
        return scene.windowStyle == .hiddenTitleBar || scene.windowStyle == .plain ? .onDemand : .inWindow
    }

    /// The scenes whose windows open at launch: every `.presented` scene;
    /// with none, the first scene that is not Settings or `.suppressed`.
    func launchScenes() -> [Int] {
        let presented = scenes.indices.filter { scenes[$0].launchBehavior == .presented && scenes[$0].kind != .settings }
        if !presented.isEmpty { return presented }
        if let first = scenes.indices.first(where: { scenes[$0].kind != .settings && scenes[$0].launchBehavior != .suppressed }) {
            return [first]
        }
        return []
    }
}
