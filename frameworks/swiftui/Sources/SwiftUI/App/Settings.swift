import Foundation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// The Settings scene (round R11; public API: `Settings`, `OpenSettingsAction`
// / `EnvironmentValues.openSettings`, `SettingsLink`).
//
// Ycode's rules: a `Settings` scene is not opened at launch; the application
// menu's "Settings…" item (Ctrl+,), `openSettings()` and `SettingsLink` open
// it as a window of its own, or raise it when it is open (one window). The
// window is titled "Settings", takes its content's ideal size (at least
// 360 × 200 points; `defaultSize` overrides) and is not resizable; it has no
// menu bar of its own on Linux (the app's commands stay in the main windows).

/// A scene for the application's settings, shown in a window of its own.
public struct Settings<Content: View>: Scene {
    let content: @MainActor () -> Content

    public init(@ViewBuilder content: @escaping @MainActor () -> Content) {
        self.content = content
    }

    public typealias Body = Never
}

extension Settings: PrimitiveScene {
    package func _collect(into scenes: inout [SceneDescription]) {
        let content = content
        scenes.append(SceneDescription(kind: .settings, id: "openviews.settings", title: "Settings", content: { content() }))
    }
}

/// Opens the Settings window (`@Environment(\.openSettings)`).
public struct OpenSettingsAction: Sendable {
    package let action: @MainActor @Sendable () -> Void
    package init(action: @escaping @MainActor @Sendable () -> Void) { self.action = action }
    @MainActor public func callAsFunction() { action() }
}

private enum OpenSettingsKey: EnvironmentKey {
    static let defaultValue = OpenSettingsAction(action: {})
}

extension EnvironmentValues {
    public var openSettings: OpenSettingsAction {
        get { self[OpenSettingsKey.self] }
        set { self[OpenSettingsKey.self] = newValue }
    }
}

/// A button that opens the Settings window.
public struct SettingsLink<Label: View>: View {
    let label: Label
    @Environment(\.openSettings) private var openSettings

    public init(@ViewBuilder label: () -> Label) { self.label = label() }

    public var body: some View {
        let open = openSettings
        Button(action: { open() }) { label }
    }
}

extension SettingsLink where Label == Text {
    public init() { self.init { Text("Settings…") } }
}
