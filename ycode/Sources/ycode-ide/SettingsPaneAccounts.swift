import Foundation
import SwiftUI
import YcodeIDECore

/// Settings ▸ Accounts (`specs/ide/settings.md` §Accounts) in the card
/// style, as the macOS IDE's pane: one card holding the account list
/// ("No Accounts" centred while it is empty) and, under a separator, a bar
/// with +. Ycode does not sign in: + shows a sheet that says so. Nothing is
/// read or stored; the list's rows come from an `AppStoreConnectKeyStore`,
/// which has no keys until #43.
struct AccountsSettingsPane: View {
    @Bindable var model: ShellSettingsModel
    var store: any AppStoreConnectKeyStore = NoAppStoreConnectKeys()
    @Environment(\.colorScheme) private var scheme

    /// The card: the list, then the + bar (the macOS IDE's 240 and 28).
    static let listHeight: CGFloat = 240
    static let barHeight: CGFloat = 28
    static let addSize = CGSize(width: 20, height: 20)

    var body: some View {
        let c = ShellColors(scheme)
        let p = SettingsPalette(scheme)
        let rows = AccountsPage.rows(from: store)
        SettingsForm {
            SettingsSection {
                SettingsContentRow(inset: 0) {
                    VStack(spacing: 0) {
                        list(rows, c, p)
                        Rectangle().fill(p.separator).frame(height: 1)
                        HStack(spacing: 0) {
                            addButton(c)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, SettingsLayout.labelInset)
                        .frame(height: Self.barHeight)
                    }
                    .frame(height: Self.listHeight)
                }
            }
        }
        .alert(AccountsPage.sheetTitle, isPresented: $model.isAccountsSheetShown) {
            Button("OK") {}
        } message: {
            Text(verbatim: AccountsPage.explanation)
        }
    }

    func list(_ rows: [AccountsPage.Row], _ c: ShellColors, _ p: SettingsPalette) -> some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows, id: \.self) { r in
                    HStack(spacing: 6) {
                        Text(verbatim: r.title).foregroundStyle(p.label).lineLimit(1)
                        Text(verbatim: r.detail).font(ShellFonts.small).foregroundStyle(p.help).lineLimit(1)
                    }
                    .padding(.horizontal, SettingsLayout.labelInset)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            if rows.isEmpty {
                Text(verbatim: AccountsPage.emptyText)
                    .font(SettingsFonts.label)
                    .foregroundStyle(p.help)
                    .shellTarget("settings accounts empty")
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .shellTarget("settings accounts list")
    }

    func addButton(_ c: ShellColors) -> some View {
        Button { model.isAccountsSheetShown = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(c.secondaryLabel)
                .frame(width: Self.addSize.width, height: Self.addSize.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AccountsPage.addLabel)
        .shellTarget("settings accounts add")
    }
}
