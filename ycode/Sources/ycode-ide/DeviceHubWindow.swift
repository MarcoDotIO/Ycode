#if os(Linux)
import Foundation
import SwiftUI
import YcodeDeviceModel
import YcodeDeviceViews
import YcodeIDECore
import YcodeIDEShell
import YcodeRemoteViewer
import YcodeSimFeatures
import YcodeSimLink
import YcodeSubprocess

/// Device Hub on Linux (Product ▸ Destination ▸ Manage Devices… and Ycode ▸
/// Open Developer Tool ▸ Device Hub; `specs/ide/device-hub.md` §2.1, "Ycode
/// decisions (2026-11-17)"), laid out as the macOS hub: a 52-point toolbar
/// with the device's name and OS, [Open in New Window · More Actions] and the
/// inspector's tabs; the sidebar (240) with Search and the Available /
/// Unavailable sections; the canvas (`DeviceHubCanvas`); the inspector
/// (280) with Settings, Reports and Info. The model is
/// `DeviceHubShellModel`: Ycode's simulators on the paired simulator hosts.
struct DeviceHubWindowView: View {
    var model: DeviceHubShellModel
    @Environment(\.colorScheme) private var scheme

    static let contentSize = CGSize(width: 1100, height: 748)
    static let toolbarHeight: CGFloat = 52
    static let sidebarWidth: CGFloat = 240
    static let inspectorWidth: CGFloat = 280
    static var windowSize: CGSize {
        CGSize(width: contentSize.width, height: contentSize.height + toolbarHeight + ShellMetrics.menuBarHeight)
    }

    var body: some View {
        let dark = scheme == .dark
        VStack(spacing: 0) {
            DeviceHubToolbar(model: model, dark: dark)
            HStack(spacing: 0) {
                if model.sidebarShown {
                    DeviceHubSidebar(model: model, dark: dark).frame(width: Self.sidebarWidth)
                    Hairline(color: Color(chromeHex: DeviceChromePalette.separator(dark: dark).hex,
                                          opacity: DeviceChromePalette.separator(dark: dark).alpha), vertical: true)
                }
                DeviceHubCanvas(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.inspectorShown {
                    Hairline(color: Color(chromeHex: DeviceChromePalette.separator(dark: dark).hex,
                                          opacity: DeviceChromePalette.separator(dark: dark).alpha), vertical: true)
                    DeviceHubInspector(model: model, dark: dark).frame(width: Self.inspectorWidth)
                }
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .background(Color(chromeHex: DeviceChromePalette.toolbar(dark: dark)))
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
        .shellTarget("hub")
    }

    /// Open in New Window: the device window (`ycode-sim-viewer --link`, as
    /// Run opens it). The stream takes one viewer at a time, so the canvas
    /// then says another viewer has the device, with Take Back.
    static func openDeviceWindow(_ d: DeviceHubDevice) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: SimRemoteCLI.viewerPath())
        p.arguments = SimRemoteCLI.viewerArguments(host: d.host, device: d.name, extra: [])
        try? p.runWithSignalsUnblocked()
    }
}

/// The toolbar band (§3): the sidebar toggle, the title and subtitle, the
/// device capsule and the inspector's tabs.
struct DeviceHubToolbar: View {
    var model: DeviceHubShellModel
    var dark: Bool
    typealias P = DeviceChromePalette

    var body: some View {
        HStack(spacing: 10) {
            capsule {
                segment("sidebar.left", help: model.sidebarShown ? "Hide Sidebar" : "Show Sidebar", target: "hub sidebar toggle") {
                    model.sidebarShown.toggle()
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: model.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(chromeHex: P.label(dark: dark)))
                    .lineLimit(1).shellTarget("hub title")
                Text(verbatim: model.subtitle).font(.system(size: 11)).foregroundStyle(Color(chromeHex: P.secondaryLabel(dark: dark)))
                    .lineLimit(1).shellTarget("hub subtitle")
            }
            Spacer(minLength: 8)
            capsule {
                segment("arrow.down.right.and.arrow.up.left", help: "Switch to compact window", target: "hub compact") {
                    if let d = model.selected, d.isRunning { model.openDeviceWindow(d) } else { model.start() }
                }
                DeviceHubMoreMenu(model: model, dark: dark)
            }
            capsule {
                ForEach(DeviceHubShellModel.InspectorTab.allCases, id: \.self) { t in
                    let on = model.inspectorShown && model.inspectorTab == t
                    ZStack {
                        if on { Capsule(style: .continuous).fill(Color(chromeHex: P.selected(dark: dark))).frame(width: 32, height: 28) }
                        segment(t.symbol, help: t.title, target: "hub tab \(t.rawValue)") {
                            if model.inspectorShown && model.inspectorTab == t { model.inspectorShown = false } else {
                                model.inspectorTab = t
                                model.inspectorShown = true
                            }
                        }
                    }
                    .frame(width: 36, height: 36)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: DeviceHubWindowView.toolbarHeight)
    }

    func capsule<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 0) { content() }
            .frame(height: 36)
            .background(Capsule(style: .continuous).fill(Color(chromeHex: P.capsule(dark: dark))))
            .overlay(Capsule(style: .continuous).strokeBorder(Color(chromeHex: P.capsuleRim(dark: dark)), lineWidth: 0.5))
    }

    func segment(_ symbol: String, help: String, target: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DeviceHubToolbarGlyph(name: symbol, color: Color(chromeHex: P.glyph(dark: dark)))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .help(help)
        .shellTarget(target)
    }
}

/// A toolbar glyph: OpenViews' own artwork for the names it draws, else
/// Ycode's drawing (`ChromeGlyph`).
struct DeviceHubToolbarGlyph: View {
    var name: String
    var color: Color
    static let openViewsNames: Set<String> = ["sidebar.left", "info.circle", "arrow.down.right.and.arrow.up.left", "doc.text", "slider.horizontal.3",
                                              "ellipsis"]

    var body: some View {
        if Self.openViewsNames.contains(name) {
            Image(systemName: name).font(.system(size: 14)).foregroundStyle(color)
        } else {
            ChromeGlyph(name: name, color: color, size: 16)
        }
    }
}

/// More Actions (Q6): Start, or Shut Down and Restart; Open in New Window.
struct DeviceHubMoreMenu: View {
    var model: DeviceHubShellModel
    var dark: Bool

    var body: some View {
        Menu {
            DeviceHubLifecycleItems(model: model, device: model.selected)
        } label: {
            DeviceHubToolbarGlyph(name: "ellipsis", color: Color(chromeHex: DeviceChromePalette.glyph(dark: dark)))
                .frame(width: 36, height: 36)
        }
        .menuStyle(.borderlessButton)
        .help("More Actions")
        .shellTarget("hub more")
    }
}

/// The lifecycle items of a device (More Actions and the row's menu).
struct DeviceHubLifecycleItems: View {
    var model: DeviceHubShellModel
    var device: DeviceHubDevice?

    var body: some View {
        if let d = device {
            if d.isRunning {
                Button("Shut Down") { model.shutDown(d) }.disabled(!model.canShutDown(d))
                Button("Restart") { model.restart(d) }.disabled(!model.canShutDown(d))
            } else {
                Button("Start") { model.start(d) }.disabled(!model.canStart(d))
            }
            Divider()
            Button("Open in New Window") { model.openDeviceWindow(d) }.disabled(!d.isRunning)
        }
    }
}

/// The sidebar (§5): Search, then the sections and their 46-point rows.
struct DeviceHubSidebar: View {
    var model: DeviceHubShellModel
    var dark: Bool
    @State private var search = ""
    typealias P = DeviceChromePalette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .onChange(of: search) { _, v in model.setSearch(v) }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .shellTarget("hub search")
            if model.sidebar.showsNoResults {
                VStack(spacing: 6) {
                    Text(verbatim: model.sidebar.noResultsTitle).font(.system(size: 13, weight: .semibold))
                    Text(verbatim: HubSidebarModel.noResultsMessage).font(.system(size: 11)).foregroundStyle(Color(chromeHex: P.secondaryLabel(dark: dark)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.rows.enumerated()), id: \.offset) { pair in
                            switch pair.element {
                            case .header(let title, let collapsed):
                                header(title, collapsed: collapsed)
                            case .device(let d):
                                row(d)
                            }
                        }
                        ForEach(model.offlineHosts, id: \.self) { h in
                            Text(verbatim: "\(h) is offline").font(.system(size: 11)).foregroundStyle(Color(chromeHex: P.secondaryLabel(dark: dark)))
                                .padding(.leading, 18).frame(height: 28)
                                .help(ShellRemoteRun.offlineMessage(host: h))
                        }
                    }
                }
            }
        }
        .background(Color(chromeHex: P.inspector(dark: dark)))
        .shellTarget("hub sidebar")
    }

    func header(_ title: String, collapsed: Bool) -> some View {
        Button { model.toggleSection(title) } label: {
            HStack(spacing: 4) {
                Text(verbatim: title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(chromeHex: P.secondaryLabel(dark: dark)))
                Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(chromeHex: P.secondaryLabel(dark: dark)))
                Spacer(minLength: 0)
            }
            .padding(.leading, 18)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .shellTarget("hub section \(title)")
    }

    func row(_ d: HubDevice) -> some View {
        let selected = model.selectedID == d.id
        let device = model.devices.first { $0.id == d.id }
        let ink = selected ? Color.white : Color(chromeHex: P.label(dark: dark))
        let sub = selected ? Color.white.opacity(0.8) : Color(chromeHex: P.secondaryLabel(dark: dark))
        return HStack(spacing: 8) {
            ZStack {
                Circle().fill(d.isRunning ? Color.white : Color(chromeHex: dark ? 0x48484A : 0xD8D8DA))
                ChromeGlyph(name: "iphone", color: d.isRunning ? Color(chromeHex: 0x007AFF) : Color(chromeHex: P.secondaryLabel(dark: dark)), size: 18)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: d.name).font(.system(size: 13)).foregroundStyle(ink).lineLimit(1)
                Text(verbatim: d.subtitle).font(.system(size: 11)).foregroundStyle(sub).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(verbatim: d.shortVersion).font(.system(size: 11)).foregroundStyle(sub)
        }
        .padding(.leading, 10)
        .padding(.trailing, 16)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Color(chromeHex: 0x007AFF) : Color.clear).padding(.horizontal, 6))
        .contentShape(Rectangle())
        .onTapGesture { model.select(d.id) }
        .contextMenu { DeviceHubLifecycleItems(model: model, device: device) }
        .shellTarget("hub row \(d.name)")
    }
}

/// The inspector (§6, §11.3): Settings' cards, Reports' empty state, Info's rows.
struct DeviceHubInspector: View {
    var model: DeviceHubShellModel
    var dark: Bool
    typealias P = DeviceChromePalette
    typealias C = DeviceInspectorContent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CGFloat(C.cardGap)) {
                switch model.inspectorTab {
                case .settings: settings
                case .reports: note(model.selected == nil ? "No Selection" : "No Diagnostic Reports")
                case .info: info
                }
            }
            .padding(.horizontal, CGFloat(C.cardInset))
            .padding(.top, CGFloat(C.cardTop))
        }
        .background(Color(chromeHex: P.inspector(dark: dark)))
        .shellTarget("hub inspector")
    }

    func note(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 11)).foregroundStyle(Color(chromeHex: P.secondaryLabel(dark: dark)))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .shellTarget("hub inspector note")
    }

    @ViewBuilder
    var settings: some View {
        if model.selected == nil {
            note("No Selection")
        } else {
            let on = model.settingsEnabled
            let st = model.settings?.state
            card {
                row("circle.lefthalf.filled", "Appearance", enabled: on) {
                    Menu {
                        Button("Light") { model.setAppearance(dark: false) }
                        Button("Dark") { model.setAppearance(dark: true) }
                    } label: {
                        Text(verbatim: st?.appearance == .dark ? "Dark" : "Light").font(.system(size: 13))
                            .foregroundStyle(Color(chromeHex: P.secondaryLabel(dark: dark)))
                    }
                    .menuStyle(.borderlessButton)
                    .disabled(!on)
                    .shellTarget("hub setting appearance")
                }
                ForEach(AccessibilitySwitch.allCases, id: \.self) { s in
                    separator
                    row(Self.symbol(s), s.title, enabled: on) {
                        Toggle("", isOn: Binding(get: { st?.switches[s] ?? false }, set: { model.setSwitch(s, on: $0) }))
                            .toggleStyle(.switch).labelsHidden().disabled(!on)
                            .shellTarget("hub setting \(s.rawValue)")
                    }
                }
            }
            if !on { note(DeviceHubShellModel.noSettingsMessage) }
            if let f = model.settingsFailure { note("\(f.title): \(f.message)") }
        }
    }

    static func symbol(_ s: AccessibilitySwitch) -> String {
        switch s {
        case .reduceMotion: "circle.dotted.and.circle"
        case .increaseContrast: "circle.righthalf.filled"
        case .showBorders: "square.dashed"
        case .reduceTransparency: "square.on.square.intersection.dashed"
        case .voiceOver: "speaker.wave.2.bubble"
        }
    }

    var separator: some View {
        Rectangle().fill(Color(chromeHex: P.separator(dark: dark).hex, opacity: P.separator(dark: dark).alpha))
            .frame(height: CGFloat(C.separator)).padding(.leading, CGFloat(C.labelX))
    }

    func card<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: CGFloat(C.cardRadius), style: .continuous).fill(Color(chromeHex: P.card(dark: dark))))
    }

    func row<V: View>(_ symbol: String, _ label: String, enabled: Bool, @ViewBuilder control: () -> V) -> some View {
        let ink = Color(chromeHex: P.label(dark: dark)).opacity(enabled ? 1 : 0.45)
        return HStack(spacing: 0) {
            ChromeGlyph(name: symbol, color: ink, size: 13).frame(width: CGFloat(C.labelX - C.symbolX), alignment: .leading)
            Text(verbatim: label).font(.system(size: 13)).foregroundStyle(ink).lineLimit(1)
            Spacer(minLength: 4)
            control().opacity(enabled ? 1 : 0.45)
        }
        .padding(.leading, CGFloat(C.symbolX))
        .padding(.trailing, CGFloat(C.trailing))
        .frame(height: CGFloat(C.rowHeight))
    }

    @ViewBuilder
    var info: some View {
        let rows = model.infoRows
        if rows.isEmpty {
            note("No Selection")
        } else {
            card {
                ForEach(Array(rows.enumerated()), id: \.offset) { pair in
                    if pair.offset > 0 { separator }
                    HStack {
                        Text(verbatim: pair.element.0).font(.system(size: 12)).foregroundStyle(Color(chromeHex: P.label(dark: dark)))
                        Spacer(minLength: 6)
                        Text(verbatim: pair.element.1).font(.system(size: 12)).foregroundStyle(Color(chromeHex: P.secondaryLabel(dark: dark)))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .shellTarget("hub info \(pair.element.0)")
                }
            }
        }
    }
}
#endif
