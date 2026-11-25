import SwiftUI
import YcodeIDECore
import YcodeIDEShell
import YcodeProject

/// The "Update to recommended settings" checklist sheet (`specs/ide/
/// issues.md` §5, P-120), as the macOS IDE's `RecommendedSettingsSheet
/// Controller`, from the same `RecommendedSettingsChecklist` and measures:
/// 581 × 364, a bordered scrolling list 522 wide (group headings bold and
/// 18 tall with a checkbox; changes with a checkbox, a bold title and a grey
/// explanation), then Cancel (84 × 23) and Perform Changes (130 × 23, the
/// default button) at the bottom right.
struct RecommendedSettingsSheet: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme
    typealias M = RecommendedSettingsChecklist.Metrics

    var body: some View {
        let settings = model.recommendedSettings
        let c = ShellColors(scheme)
        VStack(alignment: .leading, spacing: 0) {
            if let list = settings.checklist {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(list.rows) { row in rowView(row, list, c) }
                    }
                    .frame(width: CGFloat(M.listWidth) - 2, alignment: .leading)
                }
                .frame(width: CGFloat(M.listWidth), height: CGFloat(M.listHeight))
                .background(c.content)
                .overlay { Rectangle().stroke(c.separator, lineWidth: 1) }
                .padding(.leading, CGFloat(M.listX))
                .padding(.top, CGFloat(M.listTop))
                .shellTarget("recommended list")
            }
            if let e = settings.lastError {
                Text(verbatim: e).font(ShellFonts.small).foregroundStyle(Color.red).padding(.leading, CGFloat(M.listX))
            }
            Spacer(minLength: 0)
            HStack(spacing: CGFloat(M.buttonGap)) {
                Spacer()
                Button(RecommendedSettingsChecklist.cancelTitle) { settings.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                    .fixedSize()   // the whole title, never cut
                    .frame(minWidth: CGFloat(M.cancelSize.width), minHeight: CGFloat(M.cancelSize.height))
                    .shellTarget("recommended cancel")
                Button(RecommendedSettingsChecklist.performTitle) { settings.perform(model.session) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .fixedSize()   // the whole title, never cut
                    .frame(minWidth: CGFloat(M.performSize.width), minHeight: CGFloat(M.performSize.height))
                    .shellTarget("recommended perform")
            }
            .padding(.trailing, CGFloat(M.buttonTrailing))
            .padding(.bottom, CGFloat(M.buttonBottom))
        }
        .frame(width: CGFloat(M.width), height: CGFloat(M.height))
        .shellTarget("recommended sheet")
    }

    @ViewBuilder
    private func rowView(_ row: RecommendedSettingsChecklist.Row, _ list: RecommendedSettingsChecklist, _ c: ShellColors) -> some View {
        let settings = model.recommendedSettings
        switch row {
        case .group(let g):
            // OpenViews' checkbox has no public mixed state: a group with
            // some rows checked shows checked (report: toolkit request).
            HStack(spacing: 0) {
                Toggle("", isOn: Binding(get: { list.state(of: g) != .off }, set: { _ in settings.toggle(rowID: row.id) }))
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .frame(width: CGFloat(M.checkboxColumn))
                    .shellTarget("recommended box \(row.id)")
                Text(verbatim: g.rawValue).font(ShellFonts.smallBold)
                Spacer(minLength: 0)
            }
            .frame(height: CGFloat(M.groupRowHeight))
        case .change(let ch):
            HStack(alignment: .top, spacing: 0) {
                Toggle("", isOn: Binding(get: { list.isChecked(ch) }, set: { _ in settings.toggle(rowID: row.id) }))
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .frame(width: CGFloat(M.checkboxColumn), height: CGFloat(M.lineHeight))
                    .padding(.top, 1)
                    .shellTarget("recommended box \(row.id)")
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: ch.title).font(ShellFonts.smallBold).lineLimit(1)
                        .frame(height: CGFloat(M.lineHeight), alignment: .leading)
                    Text(verbatim: RecommendedSettingsChecklist.detail(ch)).font(ShellFonts.small)
                        .foregroundStyle(c.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 1)
                .padding(.bottom, 1)
                Spacer(minLength: 0)
            }
        }
    }
}
