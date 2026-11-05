import Foundation
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// `preferredColorScheme(_:)`: a view asks for light or dark for its whole
// window (nil: the desktop's). The request travels up as a preference; the
// window applies it to its root environment, so the window's own chrome (the
// in-window menu bar, the toolbar, presentations and the pop-ups the window
// opens) follows it, not only the view's subtree. The first non-nil request
// in the window wins, as the reference resolves sibling requests.

struct PreferredColorSchemeKey: PreferenceKey {
    static var defaultValue: ColorScheme? { nil }
    static func reduce(value: inout ColorScheme?, nextValue: () -> ColorScheme?) {
        if value == nil { value = nextValue() }
    }
}

extension View {
    /// Sets the color scheme of the window that shows this view (nil: the
    /// desktop's).
    public func preferredColorScheme(_ colorScheme: ColorScheme?) -> some View {
        preference(key: PreferredColorSchemeKey.self, value: colorScheme)
    }
}

extension WindowHost {
    /// The scheme a view of the window asks for (nil: none).
    var requestedColorScheme: ColorScheme? {
        graph.rootPreferences[PreferredColorSchemeKey.self].flatMap { $0 }
    }
}
