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

/// The panes of the Settings window, in the reference's order
/// (`specs/ide/settings.md` R3.2, `SettingsPaneOrder.linux`): the macOS
/// IDE's without Simulators (Ycode's own pane, macOS only). Components
/// shows its empty state.
enum ShellSettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, accounts, codingAssistant, behaviors, navigation, notifications, editing, shortcuts, sourceControl, components, locations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .accounts: AccountsPage.title
        case .codingAssistant: "Coding Assistant"
        case .behaviors: "Behaviors"
        case .navigation: "Navigation"
        case .notifications: "Notifications"
        case .editing: "Editing"
        case .shortcuts: "Shortcuts"
        case .sourceControl: "Source Control"
        case .components: "Components"
        case .locations: "Locations"
        }
    }

    /// The sidebar icon (names OpenViews draws).
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "circle.lefthalf.filled"
        case .accounts: "person.crop.circle"
        case .codingAssistant: "sparkles"
        case .behaviors: "rectangle.on.rectangle"
        case .navigation: "arrow.triangle.turn.up.right.diamond"
        case .notifications: "bell"
        case .editing: "square.and.pencil"
        case .shortcuts: "keyboard"
        case .sourceControl: "arrow.triangle.branch"
        case .components: "square.stack.3d.up"
        case .locations: "externaldrive"
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
    /// Accounts' sheet (+ shows it).
    var isAccountsSheetShown = false

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

/// The Settings window (Ctrl+,), as the macOS IDE's (`specs/ide/settings.md`
/// R3.1–R3.3): 710 × 452, the pane list flush at the left (179.5 wide,
/// 32-point rows, accent-tinted symbols, labels aligned), a 0.5-point
/// divider, and the selected pane's grouped cards under the back/forward
/// capsule and the pane's title. The settings are the portable
/// `Preferences` (user defaults under `Ycode.` keys) both IDEs and
/// `ycode complete` read; every change applies at once.
struct ShellSettingsView: View {
    @Bindable var model = ShellSettingsModel.shared
    @Environment(\.colorScheme) private var scheme

    /// The window's size (the macOS IDE's).
    static let size = SettingsLayout.windowSize
    static let sidebarWidth = SettingsLayout.sidebarWidth

    var body: some View {
        let p = SettingsPalette(scheme)
        HStack(spacing: 0) {
            sidebar(p)
                .frame(width: SettingsLayout.sidebarWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(p.sidebar)
            Rectangle().fill(p.divider).frame(width: SettingsLayout.dividerWidth)
            VStack(spacing: 0) {
                titleRow(p)
                pane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(p.detail)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .shellTarget("settings")
    }

    /// The title area's height.
    static let titleHeight = SettingsLayout.titleAreaHeight

    func sidebar(_ p: SettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ShellSettingsPane.allCases) { pane in
                let on = pane == model.pane
                Button { model.select(pane) } label: {
                    ZStack(alignment: .leading) {
                        if on {
                            RoundedRectangle(cornerRadius: SettingsLayout.selectionRadius, style: .continuous)
                                .fill(p.selection)
                                .padding(.horizontal, SettingsLayout.selectionInset)
                        }
                        // The symbol centred on x 29, the label at x 47 on every row.
                        SettingsSidebarSymbol(pane: pane, color: on ? Color.white : p.symbol)
                            .frame(width: 2 * SettingsLayout.symbolCenterX, alignment: .center)
                        Text(verbatim: pane.title)
                            .font(SettingsFonts.label)
                            .foregroundStyle(on ? Color.white : p.label)
                            .lineLimit(1)
                            .padding(.leading, SettingsLayout.sidebarLabelX)
                            .padding(.trailing, SettingsLayout.selectionInset + 4)
                    }
                    .frame(width: SettingsLayout.sidebarWidth, height: SettingsLayout.sidebarRowHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pane.title)
                .shellTarget("settings pane \(pane.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .padding(.top, SettingsLayout.sidebarTop)
    }

    /// The title area: the back/forward capsule at x 187.5 (7.5 into the
    /// detail pane) and the pane's title 12.5 after it, centred on y 26.
    func titleRow(_ p: SettingsPalette) -> some View {
        let cap = SettingsLayout.capsuleFrame
        return HStack(spacing: 0) {
            SettingsNavigationCapsule(model: model)
                .frame(width: cap.width, height: cap.height)
                .padding(.leading, cap.minX - SettingsLayout.detailX)
            Text(verbatim: model.pane.title)
                .font(SettingsFonts.title)
                .foregroundStyle(p.title)
                .lineLimit(1)
                .padding(.leading, SettingsLayout.titleX - cap.maxX)
                .shellTarget("settings title")
            Spacer(minLength: 0)
        }
        // The capsule's centre (y 25.75) on the title's line (y 26).
        .padding(.top, cap.minY)
        .frame(height: Self.titleHeight, alignment: .top)
    }

    @ViewBuilder var pane: some View {
        switch model.pane {
        case .general: GeneralSettingsPane()
        case .appearance: AppearanceSettingsPane()
        case .accounts: AccountsSettingsPane(model: model)   // SettingsPaneAccounts.swift
        case .codingAssistant: CodingAssistantSettingsPane()   // SettingsPaneCodingAssistant.swift
        case .behaviors: BehaviorsSettingsPane(model: model)
        case .navigation: NavigationSettingsPane()
        case .notifications: NotificationsSettingsPane()
        case .editing: EditingSettingsPane(model: model)
        case .shortcuts: ShortcutsSettingsPane()
        case .sourceControl: SourceControlSettingsPane()
        case .components: ComponentsSettingsPane()
        case .locations: LocationsSettingsPane()
        }
    }
}

/// A pane's sidebar symbol: OpenViews' artwork where it has one, else
/// Ycode's own drawing of the spec's description (a circle half light, half
/// dark; a diamond sign with a turning arrow; a keyboard; a drive).
struct SettingsSidebarSymbol: View {
    var pane: ShellSettingsPane
    var color: Color

    var body: some View {
        let line = StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
        switch pane {
        case .appearance:
            ZStack {
                Circle().stroke(color, style: line)
                SettingsHalfDisc().fill(color)
            }
            .frame(width: 15, height: 15)
        case .navigation:
            ZStack {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous).stroke(color, style: line)
                    .frame(width: 12, height: 12)
                    .rotationEffect(.degrees(45))
                SettingsTurnArrow().stroke(color, style: line).frame(width: 7, height: 7)
            }
            .frame(width: 17, height: 17)
        case .shortcuts:
            ZStack {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous).stroke(color, style: line)
                SettingsKeyboardKeys().fill(color)
            }
            .frame(width: 19, height: 13)
        case .locations:
            ZStack(alignment: .trailing) {
                RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(color, style: line)
                Circle().fill(color).frame(width: 2.5, height: 2.5).padding(.trailing, 3.5)
            }
            .frame(width: 18, height: 11)
        default:
            Image(systemName: pane.symbol)
                .font(.system(size: SettingsLayout.symbolPointSize))
                .foregroundStyle(color)
        }
    }
}

/// The left half of a disc.
struct SettingsHalfDisc: Shape {
    nonisolated func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addArc(center: CGPoint(x: r.midX, y: r.midY), radius: r.width / 2, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true)
        p.closeSubpath()
        return p
    }
}

/// An arrow going up, then turning right.
struct SettingsTurnArrow: Shape {
    nonisolated func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.move(to: CGPoint(x: r.maxX - 2.5, y: r.midY - 2.5))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX - 2.5, y: r.midY + 2.5))
        return p
    }
}

/// A keyboard's keys: two rows of small keys and a space bar.
struct SettingsKeyboardKeys: Shape {
    nonisolated func path(in r: CGRect) -> Path {
        var p = Path()
        let key: CGFloat = 1.8
        for row in 0..<2 {
            for i in 0..<5 {
                p.addRect(CGRect(x: r.minX + 3 + CGFloat(i) * 3, y: r.minY + 2.6 + CGFloat(row) * 3, width: key, height: key))
            }
        }
        p.addRect(CGRect(x: r.minX + 5.5, y: r.maxY - 3.6, width: r.width - 11, height: 1.5))
        return p
    }
}

/// The back/forward capsule: a near-white capsule with a faint rim and a
/// soft shadow, a divider at its centre, a chevron in each half (#AEAEAE
/// when there is no history).
struct SettingsNavigationCapsule: View {
    var model: ShellSettingsModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = SettingsPalette(scheme)
        HStack(spacing: 0) {
            half(left: true, enabled: !model.back.isEmpty, p) { model.goBack() }
            Rectangle().fill(p.capsuleDivider).frame(width: 1, height: 20)
            half(left: false, enabled: !model.forward.isEmpty, p) { model.goForward() }
        }
        .background {
            Capsule(style: .continuous)
                .fill(p.capsuleFill)
                .overlay { Capsule(style: .continuous).stroke(p.capsuleRim, lineWidth: 0.5) }
                .shadow(color: Color.black.opacity(0.12), radius: 3, y: 1)
        }
    }

    func half(left: Bool, enabled: Bool, _ p: SettingsPalette, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SettingsChevron(left: left)
                .stroke(enabled ? p.chevron : p.chevronDisabled, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 8, height: 14.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(left ? "Back" : "Forward")
        .accessibilityLabel(left ? "Back" : "Forward")
        .shellTarget(left ? "settings back" : "settings forward")
    }
}

/// A chevron, 8 × 14.5, pointing left or right.
struct SettingsChevron: Shape {
    var left: Bool

    nonisolated func path(in r: CGRect) -> Path {
        var p = Path()
        if left {
            p.move(to: CGPoint(x: r.maxX - 1, y: r.minY + 1))
            p.addLine(to: CGPoint(x: r.minX + 1, y: r.midY))
            p.addLine(to: CGPoint(x: r.maxX - 1, y: r.maxY - 1))
        } else {
            p.move(to: CGPoint(x: r.minX + 1, y: r.minY + 1))
            p.addLine(to: CGPoint(x: r.maxX - 1, y: r.midY))
            p.addLine(to: CGPoint(x: r.minX + 1, y: r.maxY - 1))
        }
        return p
    }
}

// MARK: Shared pieces of the panes (the cards: SettingsCards.swift)

/// A binding to one setting of `Preferences.shared`; setting it posts
/// `Preferences.didChange`.
@MainActor
func setting<T>(_ key: ReferenceWritableKeyPath<Preferences, T>) -> Binding<T> {
    Binding(get: { Preferences.shared[keyPath: key] }, set: { Preferences.shared[keyPath: key] = $0 })
}

extension View {
    /// Applies Settings ▸ Appearance (System, Light or Dark) to a window's
    /// content; System leaves the desktop's choice.
    func shellAppearance() -> some View { modifier(ShellAppearanceModifier()) }
}

struct ShellAppearanceModifier: ViewModifier {
    func body(content: Content) -> some View {
        // swiftlint:disable:next redundant_discardable_let - a view builder (observes the revision)
        let _ = ShellPreferences.shared.revision
        let a = Preferences.shared.appearance
        // The whole window follows it: on Linux OpenViews applies the
        // request to the window's root, so the in-window menu bar, the
        // toolbar and the pop-ups take the forced appearance too.
        content.preferredColorScheme(a == .system ? nil : (a == .dark ? .dark : .light))
    }
}
