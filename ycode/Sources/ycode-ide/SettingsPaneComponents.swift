import Foundation
import SwiftUI
import YcodeCompletion
import YcodeIDECore
import YcodeIDEShell

/// Settings ▸ Components, as the macOS IDE's (`specs/ide/settings.md`
/// R5.2): "Platform Support" (this computer, then one row per simulator
/// platform with its newest runtime, size, "Last used" and an info button
/// listing its runtimes), then "Other Components" (predictive code
/// completion, and the simulator host at the end, R5.5, whose info button
/// opens the host page). The runtimes are the runtime wizard's checks, read
/// in the background.
struct ComponentsSettingsPane: View {
    var model: ShellSettingsModel
    @State private var inventory: ComponentsInventory?
    @State private var info: ComponentsRow?

    /// A fixed inventory and date (the parity walk shows the macOS IDE's).
    nonisolated(unsafe) static var inventoryOverride: ComponentsInventory?
    nonisolated(unsafe) static var nowOverride: Date?

    var body: some View {
        let _ = ShellPreferences.shared.revision
        let inv = Self.inventoryOverride ?? inventory ?? ComponentsInventory()
        let pc = Preferences.shared.predictiveCompletion
        let platforms = ComponentsPage.platformRows(inv, isMac: false, now: Self.nowOverride ?? Date())
        let other = ComponentsPage.otherRows(predictiveEnabled: pc.enabled, predictiveBackend: pc.backend.displayName, predictiveModel: pc.model,
                                             hostDestination: SimulatorHostPage.destination(ShellApp.model.runtimeDefaults))
        SettingsForm(firstHeaderCapTop: SettingsComponentsLayout.firstHeaderCapTop) {
            SettingsSection(ComponentsPage.platformHeader) {
                ForEach(platforms) { row in rowView(row) }
            }
            SettingsSection(ComponentsPage.otherHeader) {
                ForEach(other) { row in rowView(row) }
            }
        }
        .task {
            guard Self.inventoryOverride == nil, inventory == nil else { return }
            inventory = await ComponentsInventory.read(choices: RuntimeSetupChoices.load(ShellApp.model.runtimeDefaults))
        }
    }

    func rowView(_ row: ComponentsRow) -> some View {
        ComponentsRowView(row: row) { open(row) }
            .popover(isPresented: Binding(get: { info?.id == row.id }, set: { if !$0 { info = nil } })) { infoView(row) }
            .shellTarget("settings components row \(row.glyph.rawValue)")
    }

    /// The info button: the host page, Editing ▸ Completion, or the row's lines.
    func open(_ row: ComponentsRow) {
        switch row.kind {
        case .simulatorHost: model.showHostPage()
        case .predictiveCompletion:
            model.editingPage = .completion
            model.select(.editing)
        case .thisComputer, .platform: info = row
        }
    }

    func infoView(_ row: ComponentsRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: row.title).font(SettingsFonts.header)
            ForEach(row.details, id: \.self) { SettingsHelpText(text: $0).frame(maxWidth: 280, alignment: .leading) }
            if case .platform = row.kind {
                SettingsPushButton(title: SimulatorHostPage.runtimesButton, target: "settings components runtimes") {
                    info = nil
                    ShellApp.model.showRuntimeSetup(step: .runtimes)
                }
            }
        }
        .padding(14)
    }
}

/// Settings ▸ Components ▸ Simulator Host, as the macOS IDE's (R5.5): a
/// header card (the host's icon, its name or "Not set up", what it is),
/// then Host, Runtimes, Boot and Advanced in the settings anatomy. The Host
/// and Data folder rows are the runtime wizard's host and the run settings'
/// at once; the camera, a per-device setting, is in the device window.
struct SimulatorHostSettingsPane: View {
    var model: ShellSettingsModel
    @State private var values: [SimulatorHostPage.Field: String] = [:]

    var defaults: UserDefaults { ShellApp.model.runtimeDefaults }

    var body: some View {
        let _ = ShellPreferences.shared.revision
        SettingsForm(startsWithCard: true) {
            BackRow(title: "Components", target: "settings host back") { model.hideHostPage() }
            SettingsSection(nil, cardFollows: false) {
                SettingsContentRow(inset: 0) { hero }
            }
            ForEach(SimulatorHostPage.Section.allCases, id: \.self) { section in
                SettingsSection(section.rawValue) {
                    ForEach(section.fields, id: \.self) { f in
                        SettingsRow(f.title, help: f.help) {
                            SettingsTextField(placeholder: f.placeholder, text: binding(f), target: "settings host \(f.rawValue)") { commit(f) }
                        }
                    }
                    ForEach(section.switches, id: \.self) { sw in
                        CheckRow(title: sw.title, isOn: Binding(get: { SimulatorHostPage.isOn(sw, defaults) }, set: {
                            SimulatorHostPage.set(sw, $0, defaults)
                            ShellPreferences.shared.touch()
                        }), target: "settings host \(sw.rawValue)", help: sw.help)
                    }
                    if section == .runtimes {
                        SettingsRow("Runtimes on the host", help: SimulatorHostPage.runtimesHelp) {
                            SettingsPushButton(title: SimulatorHostPage.runtimesButton, target: "settings host runtimes") {
                                ShellApp.model.showRuntimeSetup(step: .runtimes)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { load() }
    }

    /// The header card: the icon, "Simulator Host" with "Experimental", the
    /// host, and what it is.
    var hero: some View {
        let P = SimulatorHostPage.self
        return HeroCard(destination: SimulatorHostPage.destination(defaults))
            .padding(P.heroInset)
    }

    func load() {
        for f in SimulatorHostPage.Field.allCases { values[f] = SimulatorHostPage.value(f, defaults) }
    }

    func binding(_ f: SimulatorHostPage.Field) -> Binding<String> {
        Binding(get: { values[f] ?? "" }, set: { values[f] = $0 })
    }

    func commit(_ f: SimulatorHostPage.Field) {
        SimulatorHostPage.set(f, values[f] ?? "", defaults)
        values[f] = SimulatorHostPage.value(f, defaults)
        ShellPreferences.shared.touch()
    }
}

/// The host page's header card contents.
private struct HeroCard: View {
    var destination: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = SettingsPalette(scheme)
        let P = SimulatorHostPage.self
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                SimulatorHostIcon()
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: P.title).font(SettingsFonts.header).foregroundStyle(p.label)
                        Text(verbatim: ExperimentalNotice.label).font(.system(size: SettingsLayout.helpFontSize, weight: .medium)).foregroundStyle(p.subtitle)
                    }
                    .padding(.top, 2)
                    Text(verbatim: P.subtitle(destination: destination)).font(SettingsFonts.help).foregroundStyle(p.subtitle)
                        .shellTarget("settings host status")
                }
                Spacer(minLength: 0)
            }
            SettingsHelpText(text: P.summary + " " + ExperimentalNotice.simulator)
                .frame(maxWidth: SettingsLayout.cardWidth - 2 * P.heroInset - P.heroIconSize - 12, alignment: .leading)
                .padding(.leading, P.heroIconSize + 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
