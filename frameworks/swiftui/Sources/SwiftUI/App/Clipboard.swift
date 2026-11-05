import Foundation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// The system clipboard for views (OpenViews only, not SwiftUI API). Apps on
// Apple platforms reach the pasteboard through AppKit or UIKit; a view on
// OpenViews has no such object, and until now the clipboard was only the
// text controls' (Ctrl+C in a field). `OpenViewsClipboard` is the same
// clipboard the text controls use: the running app's back end (SDL's
// clipboard on a desktop, the headless back end's memory in tests). With no
// app running (a view rendered on its own) it keeps the text in memory.
//
//     Button("Copy") { OpenViewsClipboard.copy(command) }

/// The system clipboard's text, for views (OpenViews only).
@MainActor
public enum OpenViewsClipboard {
    /// Used when no app host runs (tests that render views alone).
    private static let fallback = MemoryClipboard()

    static var platform: any PlatformClipboard { (AppHost.current ?? AppHost.lastLaunched)?.backend.clipboard ?? fallback }

    /// The clipboard's text (nil when it holds none). Setting it replaces
    /// the clipboard's contents; nil empties it.
    public static var string: String? {
        get { platform.text }
        set { platform.text = newValue }
    }

    /// Whether the clipboard holds text.
    public static var hasString: Bool { platform.hasText }

    /// Puts `text` on the clipboard, as a Copy command does.
    public static func copy(_ text: String) { platform.text = text }
}
