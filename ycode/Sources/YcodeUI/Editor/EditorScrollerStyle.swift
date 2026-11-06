import AppKit

/// The scroll bar style the editor lays out with from its first frame
/// (`editor-area.md` E.7 item 3, checklist row 76). With "Show scroll
/// bars: Automatically", AppKit answers "overlay" until it has seen the
/// input devices and only then switches to the style that takes a lane,
/// so the first layout wrapped against a container one lane wider than
/// every later one. Ycode remembers the settled style and starts with it;
/// once AppKit has settled (its change notification, or a few seconds
/// after launch) its own answer is used.
@MainActor
enum EditorScrollerStyle {
    static let defaultsKey = "YcodeEditorScrollerStyle"
    /// How long after the first use AppKit's answer may still change.
    static let settleTime: TimeInterval = 3
    private static var settled = false
    private static var observer: NSObjectProtocol?
    private static var firstUse: Date?

    /// The style to start an editor with (AppKit's, once settled).
    static var initial: NSScroller.Style {
        watch()
        let preferred = NSScroller.preferredScrollerStyle
        if settled { return preferred }
        guard let raw = UserDefaults.standard.object(forKey: defaultsKey) as? Int, let remembered = NSScroller.Style(rawValue: raw) else {
            return preferred
        }
        return remembered
    }

    /// Editors that started with the remembered style.
    private static let followers = NSHashTable<NSScrollView>.weakObjects()

    /// Records the settled style; editors that started with the
    /// remembered one take AppKit's.
    static func noteSettled(_ style: NSScroller.Style) {
        settled = true
        UserDefaults.standard.set(style.rawValue, forKey: defaultsKey)
        for scrollView in followers.allObjects where scrollView.scrollerStyle != style {
            scrollView.scrollerStyle = style
            scrollView.superview?.needsLayout = true
        }
        followers.removeAllObjects()
    }

    /// Keeps `scrollView` on the settled style.
    static func follow(_ scrollView: NSScrollView) {
        guard !settled else { return }
        followers.add(scrollView)
    }

    private static func watch() {
        guard firstUse == nil else { return }
        firstUse = Date()
        observer = NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil,
                                                          queue: .main) { _ in
            MainActor.assumeIsolated { noteSettled(NSScroller.preferredScrollerStyle) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + settleTime) {
            MainActor.assumeIsolated {
                guard !settled else { return }
                noteSettled(NSScroller.preferredScrollerStyle)
            }
        }
    }
}
