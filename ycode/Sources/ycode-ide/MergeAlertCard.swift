import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// The merge confirmation (`specs/ide/merge-sheet.md` §1.2), as the AppKit
/// `MergeAlertView` draws it: 420 × 133 centred on the window, Ycode's icon
/// 55 × 55 at (28.5, 22), the bold title and the message from x 106, then
/// Cancel (58 × 20, Escape) and **Merge** (79 × 20, accent, the default:
/// Return), 14.5 apart, Merge 20.5 from the right edge and both 18 above
/// the bottom. Integrate ▸ Merge… adds a pop-up of the branches (30 taller).
struct MergeAlertCard: View {
    var scm: SourceControlShellModel
    var alert: MergeAlertState
    /// The alert has finished appearing: Merge is drawn accent.
    var isReady: Bool
    /// Merge or Cancel was clicked: it fades out and takes no more keys.
    var isLeaving: Bool
    @Environment(\.colorScheme) private var scheme

    typealias M = MergeSheetMetrics

    var body: some View {
        let p = MergeSheetPalette.forDark(scheme == .dark)
        let w = CGFloat(M.alertWidth), h = CGFloat(M.alertHeight + (alert.hasChooser ? M.alertChooserHeight : 0))
        let textX = CGFloat(M.alertTextX), textWidth = w - textX - 20
        let mergeX = w - CGFloat(M.alertButtonTrailing + M.alertMergeWidth)
        let cancelX = mergeX - CGFloat(M.alertButtonSpacing + M.alertCancelWidth)
        let buttonY = h - CGFloat(M.alertButtonBottom + M.alertButtonHeight)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: CGFloat(M.cornerRadius), style: .continuous)
                .fill(Color(mergeHex: p.sheet))
                .shadow(color: Color.black.opacity(scheme == .dark ? 0.5 : 0.25), radius: 14, x: 0, y: 6)
            YcodeMark(size: CGFloat(M.alertIcon))
                .offset(x: CGFloat(M.alertIconOrigin.x), y: CGFloat(M.alertIconOrigin.y))
            // The title's first cap top 20 below the alert's top.
            Text(verbatim: alert.title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(mergeHex: p.label))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: textWidth, alignment: .topLeading)
                .offset(x: textX, y: CGFloat(M.alertTitleTop) - 4)
                .shellTarget("merge alert title")
            Text(verbatim: alert.message)
                .font(.system(size: 11))
                .foregroundStyle(Color(mergeHex: scheme == .dark ? p.label : 0x000000))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: textWidth, alignment: .topLeading)
                .offset(x: textX, y: CGFloat(M.alertMessageTop) - 2)
                .shellTarget("merge alert message")
            if let choices = alert.choices, !choices.isEmpty {
                Menu {
                    ForEach(choices, id: \.self) { b in
                        Button(b) { scm.chooseMergeBranch(b) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(verbatim: alert.branch).font(.system(size: 12)).foregroundStyle(Color(mergeHex: p.label)).lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Color(mergeHex: p.secondaryLabel))
                    }
                    .padding(.horizontal, 8)
                    .frame(width: textWidth, height: 22)
                    .background { RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(mergeHex: p.button)) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .offset(x: textX, y: CGFloat(M.alertMessageTop) + 30)
                .shellTarget("merge alert branch")
            }
            Button(role: .cancel) { if !isLeaving { scm.cancelMergeAlert() } } label: {
                MergeButtonLabel(title: MergeSheetText.cancel, isDefault: false, palette: p,
                                 width: CGFloat(M.alertCancelWidth), height: CGFloat(M.alertButtonHeight))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(MergeSheetText.cancel)
            .accessibilityHint("Cancel button (Escape)")
            .offset(x: cancelX, y: buttonY)
            .shellTarget("merge alert cancel")
            Button { if !isLeaving { scm.confirmMergeAlert() } } label: {
                MergeButtonLabel(title: MergeSheetText.merge, isDefault: isReady, palette: p,
                                 width: CGFloat(M.alertMergeWidth), height: CGFloat(M.alertButtonHeight))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(MergeSheetText.merge)
            .accessibilityHint("Default button (Return)")
            .offset(x: mergeX, y: buttonY)
            .shellTarget("merge alert merge")
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .contentShape(Rectangle())
        // A modal container (§13.2): the title and message are static texts,
        // Cancel and Merge buttons with their titles and press actions.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(alert.title)
        .accessibilityAddTraits(.isModal)
        .shellTarget("merge alert")
    }
}
