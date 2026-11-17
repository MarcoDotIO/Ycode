import Foundation
import SwiftUI
import YcodeIDECore

// Quick Help's rendered Markup (P-083), as the macOS `QuickHelpView`
// draws it: inline emphasis, strong text and code voice; Discussion
// headings, numbered and bulleted items with a hanging marker, and code
// blocks with their line breaks in a tinted box.

/// Runs as one `Text`: emphasis italic, strong bold, code voice monospaced.
enum QuickHelpText {
    static func text(_ runs: [QuickHelpRun]) -> Text {
        runs.reduce(Text(verbatim: "")) { t, r in
            switch r.style {
            case .plain: t + Text(verbatim: r.text)
            case .emphasis: t + Text(verbatim: r.text).italic()
            case .strong: t + Text(verbatim: r.text).bold()
            case .code: t + Text(verbatim: r.text).monospaced()
            }
        }
    }
}

/// One Discussion block.
struct QuickHelpBlockView: View {
    var block: QuickHelpBlock
    var colors: ShellColors

    var body: some View {
        switch block {
        case .paragraph(let r):
            styled(r)
        case .heading(let r):
            QuickHelpText.text(r).font(Font.system(size: 13, weight: .bold)).foregroundStyle(colors.label)
                .fixedSize(horizontal: false, vertical: true)
                .shellTarget("quickhelp heading")
        case .code(let code):
            Text(verbatim: code).font(Font.system(size: 11, design: .monospaced)).foregroundStyle(colors.label)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { RoundedRectangle(cornerRadius: 5, style: .continuous).fill(colors.tertiaryLabel.opacity(0.12)) }
                .shellTarget("quickhelp code")
        case .listItem(let marker, let r):
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: marker).font(ShellFonts.small).foregroundStyle(colors.label)
                styled(r)
            }
            .shellTarget("quickhelp list item")
        }
    }

    func styled(_ r: [QuickHelpRun]) -> some View {
        QuickHelpText.text(r).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(colors.label)
            .fixedSize(horizontal: false, vertical: true)
    }
}
