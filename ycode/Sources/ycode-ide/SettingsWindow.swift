import Foundation
import Observation
import SwiftUI
import YcodeCompletion
import YcodeIDECore
import YcodeIDEShell

/// Follows `Preferences` for the views that draw with it: editors redraw with
/// a new font, theme or tab width, open buffers take the typing settings,
/// the menus take changed shortcuts and the windows the appearance.
@MainActor
@Observable
final class ShellPreferences {
    static let shared = ShellPreferences()
    /// Bumped on every change of the preferences.
    private(set) var revision = 0
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ShellPreferences.shared.changed() }
        }
    }

    private func changed() {
        revision &+= 1
        ShellApp.model.workspace?.preferencesChanged()
        Self.persist()
    }

    /// A setting stored outside `Preferences` changed (the build system,
    /// predictive completion, completion while typing): redraw and save.
    func touch() {
        revision &+= 1
        Self.persist()
    }

    /// Writes the user defaults now: swift-corelibs-foundation keeps them
    /// in memory until asked, and an app that is quit or killed would
    /// lose the change.
    static func persist() { UserDefaults.standard.synchronize() }

    /// Completions open by themselves after a "." (off by default for the
    /// beta; Ctrl+Space and Escape always ask).
    static var completionWhileTyping: Bool {
        UserDefaults.standard.object(forKey: completionKey) as? Bool ?? false
    }
    static let completionKey = "Ycode.linuxCompletionWhileTyping"

    /// The source font's size: the user's, else the theme's.
    static var fontSize: Double { Preferences.shared.sourceFontSize ?? Preferences.shared.theme.fontSize }
}

/// The panes of the Settings window, in the macOS IDE's order
/// (`specs/ide/settings.md` §Window) without the panes the Linux IDE has
/// nothing for yet (Accounts, Coding Assistant, Components, Simulators).
enum ShellSettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, behaviors, navigation, notifications, editing, shortcuts, sourceControl, locations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .behaviors: "Behaviors"
        case .navigation: "Navigation"
        case .notifications: "Notifications"
        case .editing: "Editing"
        case .shortcuts: "Shortcuts"
        case .sourceControl: "Source Control"
        case .locations: "Locations"
        }
    }

    /// The sidebar icon (names OpenViews draws).
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "sun.max"
        case .behaviors: "gearshape.2"
        case .navigation: "arrow.left.arrow.right"
        case .notifications: "bell"
        case .editing: "doc.text"
        case .shortcuts: "square.grid.2x2"
        case .sourceControl: "arrow.triangle.branch"
        case .locations: "folder"
        }
    }
}

/// Which pane shows, the back/forward history and each pane's sub-page.
@MainActor
@Observable
final class ShellSettingsModel {
    static let shared = ShellSettingsModel()

    private(set) var pane: ShellSettingsPane = .general
    private(set) var back: [ShellSettingsPane] = []
    private(set) var forward: [ShellSettingsPane] = []
    /// Editing's sub-page.
    var editingPage: EditingSettingsPane.Page = .main
    /// Behaviors' open event (nil: the event list).
    var behaviorEvent: Preferences.Event?

    /// Shows a pane (recorded for back/forward).
    func select(_ p: ShellSettingsPane) {
        guard p != pane else { return }
        back.append(pane)
        forward = []
        pane = p
    }

    func goBack() {
        guard let p = back.popLast() else { return }
        forward.append(pane)
        pane = p
    }

    func goForward() {
        guard let p = forward.popLast() else { return }
        back.append(pane)
        pane = p
    }
}

/// The Settings window (Ctrl+,): the pane list at the left, the selected
/// pane as a grouped form at the right under its title and back/forward
/// buttons, as the macOS IDE's (`specs/ide/settings.md`). The settings are
/// the portable `Preferences` (user defaults under `Ycode.` keys) both
/// IDEs and `ycode complete` read; every change applies at once.
struct ShellSettingsView: View {
    @Bindable var model = ShellSettingsModel.shared
    @Environment(\.colorScheme) private var scheme

    /// The window's size (the macOS IDE's 860 × 560, plus room for the
    /// title row).
    static let size = CGSize(width: 860, height: 600)
    static let sidebarWidth: CGFloat = 200

    var body: some View {
        let c = ShellColors(scheme)
        HStack(spacing: 0) {
            sidebar(c)
                .frame(width: Self.sidebarWidth)
                .frame(maxHeight: .infinity)
                .background(c.sidebar)
            Hairline(color: c.sidebarDivider, vertical: true)
            VStack(spacing: 0) {
                titleRow(c)
                pane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Self.formBackground(c))
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .shellTarget("settings")
    }

    /// The title row's height.
    static let titleHeight: CGFloat = 48

    /// Behind the panes: the grouped form's own background (OpenViews draws
    /// its grouped forms on the system grouped background), so the title
    /// row, the form and the space under a short form are one surface.
    static func formBackground(_ c: ShellColors) -> Color {
        #if os(Linux)
        let v: (Double, Double) = c.dark ? (0, 0) : (242 / 255, 247 / 255)
        return Color(.sRGB, red: v.0, green: v.0, blue: v.1)
        #else
        c.content
        #endif
    }

    func sidebar(_ c: ShellColors) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(ShellSettingsPane.allCases) { p in
                let on = p == model.pane
                Button { model.select(p) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: p.symbol)
                            .font(.system(size: 13))
                            .foregroundStyle(on ? c.accent : c.secondaryLabel)
                            .frame(width: 20)
                        Text(verbatim: p.title).font(ShellFonts.row).foregroundStyle(c.label)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background { if on { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(c.rowSelection) } }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(p.title)
                .shellTarget("settings pane \(p.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
    }

    func titleRow(_ c: ShellColors) -> some View {
        HStack(spacing: 6) {
            GlassSegments(segments: [
                .init(symbol: "chevron.left", help: "Back", isEnabled: !model.back.isEmpty, target: "settings back") { model.goBack() },
                .init(symbol: "chevron.right", help: "Forward", isEnabled: !model.forward.isEmpty, target: "settings forward") { model.goForward() },
            ], segmentWidth: 22, symbolSize: 12)
            Text(verbatim: model.pane.title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(c.label)
                .padding(.leading, 4)
                .shellTarget("settings title")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: Self.titleHeight)
    }

    @ViewBuilder var pane: some View {
        switch model.pane {
        case .general: GeneralSettingsPane()
        case .appearance: AppearanceSettingsPane()
        case .behaviors: BehaviorsSettingsPane(model: model)
        case .navigation: NavigationSettingsPane()
        case .notifications: NotificationsSettingsPane()
        case .editing: EditingSettingsPane(model: model)
        case .shortcuts: ShortcutsSettingsPane()
        case .sourceControl: SourceControlSettingsPane()
        case .locations: LocationsSettingsPane()
        }
    }
}

// MARK: Shared pieces of the panes

/// A pane's grouped form. OpenViews' `Form` does not scroll yet, so on
/// Linux it sits in a scroll view.
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        #if os(Linux)
        ScrollView {
            Form { content }
                .formStyle(.grouped)
                .environment(\.defaultMinListRowHeight, 34)
        }
        #else
        Form { content }.formStyle(.grouped)
        #endif
    }
}

/// A binding to one setting of `Preferences.shared`; setting it posts
/// `Preferences.didChange`.
@MainActor
func setting<T>(_ key: ReferenceWritableKeyPath<Preferences, T>) -> Binding<T> {
    Binding(get: { Preferences.shared[keyPath: key] }, set: { Preferences.shared[keyPath: key] = $0 })
}

/// A pop-up of an enumeration's cases, titled by their raw values.
struct CasePicker<T: RawRepresentable & CaseIterable & Hashable>: View where T.RawValue == String {
    var title: String
    var selection: Binding<T>
    var target: String

    var body: some View {
        Picker(title, selection: selection) {
            ForEach(Array(T.allCases), id: \.self) { Text(verbatim: $0.rawValue).tag($0) }
        }
        .shellTarget(target)
    }
}

/// A checkbox row.
struct CheckRow: View {
    var title: String
    var isOn: Binding<Bool>
    var target: String

    var body: some View {
        Toggle(title, isOn: isOn).toggleStyle(.checkbox).shellTarget(target)
    }
}

/// A row that opens a sub-page: its title, an optional value and a chevron.
struct DrillRow: View {
    var title: String
    var detail = ""
    var target: String
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        Button(action: action) {
            HStack(spacing: 6) {
                Text(verbatim: title).foregroundStyle(c.label)
                Spacer(minLength: 8)
                if !detail.isEmpty { Text(verbatim: detail).font(ShellFonts.small).foregroundStyle(c.secondaryLabel).lineLimit(1) }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(c.tertiaryLabel)
            }
            .frame(maxWidth: .infinity, minHeight: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .shellTarget(target)
    }
}

/// A sub-page's way back ("‹ Editing").
struct BackRow: View {
    var title: String
    var target: String
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                Text(verbatim: title)
            }
            .foregroundStyle(c.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .shellTarget(target)
    }
}

/// A small note under a section (the form's footer style).
struct FootNote: View {
    var text: String
    var body: some View { Text(verbatim: text).font(ShellFonts.small) }
}

extension View {
    /// Applies Settings ▸ Appearance (System, Light or Dark) to a window's
    /// content; System leaves the desktop's choice.
    func shellAppearance() -> some View { modifier(ShellAppearanceModifier()) }
}

struct ShellAppearanceModifier: ViewModifier {
    @Environment(\.colorScheme) private var desktop

    func body(content: Content) -> some View {
        // swiftlint:disable:next redundant_discardable_let - a view builder (observes the revision)
        let _ = ShellPreferences.shared.revision
        let a = Preferences.shared.appearance
        #if os(Linux)
        content.environment(\.colorScheme, a == .system ? desktop : (a == .dark ? .dark : .light))
        #else
        content.preferredColorScheme(a == .system ? nil : (a == .dark ? .dark : .light))
        #endif
    }
}
