import AppKit
import QuartzCore
import YcodeIDECore

/// P-199: selecting another file in the navigator cross-fades the editor's
/// text area from the old file to the new one on `Motion.fileSelectionEase`
/// (≈ 95 ms, from ≈ +93 ms after the click). Core Animation plays the fade
/// in the render server, so the parser pass that follows the open (it runs
/// after the first frame, `resetSyntax(deferringParse:)`) does not hold it.
/// The old file stays until the fade's start; when the open's work ends
/// after that start, the fade begins with the first frame of the new file.
extension WorkspaceWindowController {
    /// The transition's key on the text area's layer (Core Animation keeps
    /// every transition under this one key).
    static let fileSelectionEaseKey = kCATransition

    /// For an open that replaces `editor`'s file with `path`: what adds the
    /// cross-fade once the open has changed the text (in the same
    /// transaction, so the fade runs from the frame last shown to the new
    /// one). Nil when the editor shows that file or none, or with Reduce
    /// Motion (`fileSelectionEaseSkipReason`). `press`: the
    /// click's time on the system uptime clock (the current event's by
    /// default).
    func fileSelectionEase(to path: String, in editor: SourceEditorController,
                           press: TimeInterval? = NSApp.currentEvent?.timestamp) -> (() -> Void)? {
        guard fileSelectionEaseSkipReason(to: path, in: editor) == nil else { return nil }
        return { [weak editor] in
            guard let layer = editor?.scrollView.layer else { return }
            layer.add(Self.fileSelectionFade(for: layer, press: press), forKey: Self.fileSelectionEaseKey)
        }
    }

    /// Reduce Motion for the ease: the system's Accessibility setting,
    /// unless set (tests: CI's macOS runner images turn Reduce Motion on).
    static var fileSelectionEaseReducesMotion: Bool?

    /// Why an open to `path` has no ease, nil when it has one: the editor
    /// shows no file, shows that file already, or Reduce Motion is on.
    func fileSelectionEaseSkipReason(to path: String, in editor: SourceEditorController) -> String? {
        guard let old = editor.fileURL?.path else { return "the editor shows no file" }
        if old == path { return "the editor shows \(path) already" }
        if Self.fileSelectionEaseReducesMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return "Reduce Motion is on" }
        return nil
    }

    /// The fade on the motion catalogue's curve, starting `Motion
    /// .fileSelectionEase.delay` after `press` or now, whichever is later.
    static func fileSelectionFade(for layer: CALayer, press: TimeInterval?) -> CATransition {
        let curve = Motion.fileSelectionEase
        let fade = CATransition()
        fade.type = .fade
        fade.duration = curve.duration
        let b = curve.bezier
        fade.timingFunction = CAMediaTimingFunction(controlPoints: Float(b.x1), Float(b.y1), Float(b.x2), Float(b.y2))
        // The event's timestamp and CACurrentMediaTime both count from boot;
        // the layer has its own time space.
        let since = press.map { max(0, ProcessInfo.processInfo.systemUptime - $0) } ?? 0
        let wait = max(0, curve.delay - since)
        if wait > 0 {
            fade.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + wait
            fade.fillMode = .backwards   // the old file until the fade starts
        }
        return fade
    }
}
