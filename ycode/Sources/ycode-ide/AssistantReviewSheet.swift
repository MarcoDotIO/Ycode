import Foundation
import SwiftUI
import YcodeAssistant
import YcodeIDECore
import YcodeIDEShell

/// Review… (coding-assistant.md §5.3): "Change <file>: +a −r lines" (or
/// "Create <path>"), the file's current text on the left and the text with
/// the change on the right, both read-only, changed lines tinted and
/// paired; Reject (Esc) and Accept (Return), or Create File.
struct AssistantReviewSheet: View {
    var assistant: ShellAssistantModel
    var review: AssistantChangeReview
    @Environment(\.colorScheme) private var scheme

    static let size = CGSize(width: 900, height: 560)

    var body: some View {
        let c = ShellColors(scheme)
        let d = review.diff
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: d.title).font(.system(size: 13, weight: .bold)).foregroundStyle(c.label)
                    .shellTarget("assistant review title")
                Spacer()
                if let decided = review.decided {
                    Text(verbatim: decided == .accepted ? "Applied" : "Rejected").font(ShellFonts.smallBold).foregroundStyle(c.secondaryLabel)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            HStack(spacing: 0) {
                header(d.isNewFile ? "(new file)" : d.currentTitle, c)
                Hairline(color: c.separator, vertical: true)
                header(d.proposedTitle, c)
            }
            .frame(height: 24)
            .background(c.sidebar)
            Hairline(color: c.separator)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(d.rows.enumerated()), id: \.offset) { pair in row(pair.element, c) }
                }
            }
            .background(c.content)
            .shellTarget("assistant review comparison")
            Hairline(color: c.separator)
            HStack(spacing: 10) {
                Text(verbatim: "Accepting changes the editor's text; save the file to keep it, or undo.")
                    .font(ShellFonts.small).foregroundStyle(c.secondaryLabel)
                Spacer()
                if review.decided == nil {
                    Button("Reject") { assistant.rejectReview() }
                        .keyboardShortcut(.cancelAction).buttonStyle(.bordered).shellTarget("assistant review reject")
                    Button(review.acceptTitle) { assistant.acceptReview() }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).shellTarget("assistant review accept")
                } else {
                    Button("Close") { assistant.review = nil }
                        .keyboardShortcut(.defaultAction).buttonStyle(.bordered).shellTarget("assistant review close")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(c.sidebar)
        .shellTarget("assistant review")
    }

    func header(_ title: String, _ c: ShellColors) -> some View {
        Text(verbatim: title).font(ShellFonts.smallBold).foregroundStyle(c.secondaryLabel).lineLimit(1)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    func row(_ r: LineDiff.Row, _ c: ShellColors) -> some View {
        HStack(spacing: 0) {
            side(r.left, tint: r.kind == .same || r.left == nil ? nil : c.error, c)
            Hairline(color: c.separator, vertical: true)
            side(r.right, tint: r.kind == .same || r.right == nil ? nil : c.success, c)
        }
        .frame(height: 16)
    }

    func side(_ s: (number: Int, text: String)?, tint: Color?, _ c: ShellColors) -> some View {
        let mono = Font.system(size: 11, design: .monospaced)
        return HStack(spacing: 0) {
            Text(verbatim: s.map { String($0.number) } ?? "").font(mono).foregroundStyle(c.tertiaryLabel).frame(width: 40, alignment: .trailing)
            Rectangle().fill(tint ?? Color.clear).frame(width: 2).padding(.horizontal, 6)
            Text(verbatim: s?.text.replacingOccurrences(of: "\t", with: "    ") ?? "").font(mono).foregroundStyle(c.label).lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .background(s == nil ? c.separator.opacity(0.35) : (tint?.opacity(0.17) ?? Color.clear))
    }
}

/// The pane's sheet and alert in the workspace window.
struct AssistantPrompts: ViewModifier {
    @Bindable var assistant: ShellAssistantModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $assistant.review) { r in AssistantReviewSheet(assistant: assistant, review: r) }
            .alert("The change can't be applied", isPresented: Binding(get: { assistant.alertText != nil }, set: { if !$0 { assistant.alertText = nil } })) {
                Button("OK") { assistant.alertText = nil }
            } message: {
                Text(verbatim: assistant.alertText ?? "")
            }
    }
}
