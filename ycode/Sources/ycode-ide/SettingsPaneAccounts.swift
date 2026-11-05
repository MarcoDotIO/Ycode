import Foundation
import SwiftUI
import YcodeIDECore

/// Settings ▸ Accounts (`specs/ide/settings.md` §Accounts), laid out as the
/// macOS IDE's pane: a bordered 220 × 240 account list with "No Accounts"
/// beside it while it is empty, and + under it, 10 points apart, 20 / 28
/// points from the edges. Ycode does not sign in: + shows a sheet that says
/// so. Nothing is read or stored; the list's rows come from an
/// `AppStoreConnectKeyStore`, which has no keys until #43.
struct AccountsSettingsPane: View {
    @Bindable var model: ShellSettingsModel
    var store: any AppStoreConnectKeyStore = NoAppStoreConnectKeys()
    @Environment(\.colorScheme) private var scheme

    static let listSize = CGSize(width: 220, height: 240)
    static let addSize = CGSize(width: 16, height: 14)

    var body: some View {
        let c = ShellColors(scheme)
        let rows = AccountsPage.rows(from: store)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                list(rows, c)
                if rows.isEmpty {
                    Text(verbatim: AccountsPage.emptyText)
                        .foregroundStyle(c.secondaryLabel)
                        .shellTarget("settings accounts empty")
                }
            }
            addButton(c)
            Spacer(minLength: 0)
        }
        .padding(.top, 20)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert(AccountsPage.sheetTitle, isPresented: $model.isAccountsSheetShown) {
            Button("OK") {}
        } message: {
            Text(verbatim: AccountsPage.explanation)
        }
    }

    func list(_ rows: [AccountsPage.Row], _ c: ShellColors) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows, id: \.self) { r in
                HStack(spacing: 6) {
                    Text(verbatim: r.title).foregroundStyle(c.label).lineLimit(1)
                    Text(verbatim: r.detail).font(ShellFonts.small).foregroundStyle(c.secondaryLabel).lineLimit(1)
                }
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .frame(width: Self.listSize.width, height: Self.listSize.height)
        .background(c.fieldFill)
        .overlay(Rectangle().stroke(c.fieldStroke, lineWidth: 1))
        .shellTarget("settings accounts list")
    }

    func addButton(_ c: ShellColors) -> some View {
        Button { model.isAccountsSheetShown = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(c.label)
                .frame(width: Self.addSize.width, height: Self.addSize.height)
                .background(c.fieldFill)
                .overlay(Rectangle().stroke(c.fieldStroke, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AccountsPage.addLabel)
        .shellTarget("settings accounts add")
    }
}
