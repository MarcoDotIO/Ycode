import Foundation
import SwiftUI
import YcodeAssistant
import YcodeIDECore
import YcodeIDEShell

// The transcript of the Coding Assistant pane (coding-assistant.md §4,
// §5.3): who wrote each message, its attachments, an agent's activity,
// the text (prose with inline Markdown, code blocks with Copy), and each
// proposed change as a diff with Accept and Reject (and Review… for the
// side-by-side sheet); Accept All and Reject All when a response proposes
// more than one change. Nothing is written until the user accepts.

struct TranscriptView: View {
    var model: WorkspaceShellModel
    var assistant: ShellAssistantModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let conv = assistant.selected
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let conv, !conv.messages.isEmpty {
                        ForEach(conv.messages) { m in
                            MessageView(model: model, assistant: assistant, message: m, conversation: conv.id, colors: c)
                        }
                    } else {
                        EmptyTranscript(colors: c)
                    }
                    Color.clear.frame(height: 1).id("assistant end")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            // Follows a new message and a streaming answer to the end (not
            // an Accept or Reject further up).
            .task(id: followKey(conv)) {
                try? await Task.sleep(nanoseconds: 40_000_000)
                proxy.scrollTo("assistant end", anchor: .bottom)
            }
        }
        .shellTarget("assistant transcript")
    }

    func followKey(_ conv: Conversation?) -> String {
        guard let conv else { return "" }
        let last = conv.messages.last
        return "\(conv.id) \(conv.messages.count) \(last?.isComplete == false ? last?.text.count ?? 0 : -1)"
    }
}

/// What an empty conversation shows.
struct EmptyTranscript: View {
    var colors: ShellColors

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "text.bubble").font(.system(size: 22)).foregroundStyle(colors.tertiaryLabel)
            Text(verbatim: "Ask about your code").font(Font.system(size: 13, weight: .semibold)).foregroundStyle(colors.secondaryLabel)
            Text(verbatim: "The open file, the selection and the issues go with your message. Proposed changes are applied only when you accept them.")
                .font(ShellFonts.small).foregroundStyle(colors.tertiaryLabel).multilineTextAlignment(.center)
        }
        .padding(.top, 30)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
    }
}

/// One message.
struct MessageView: View {
    var model: WorkspaceShellModel
    var assistant: ShellAssistantModel
    var message: ConversationMessage
    var conversation: UUID
    var colors: ShellColors

    /// The message's place in the conversation (driver names: "assistant
    /// accept <file> <block> <ordinal>").
    var ordinal: Int { assistant.selected?.messages.firstIndex { $0.id == message.id } ?? 0 }

    var body: some View {
        let c = colors
        let proposals = assistant.proposals(in: message)
        let undecided = proposals.filter { message.resolvedProposals[$0.blockIndex] == nil }
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: message.role == .user ? "You" : (message.source ?? "Assistant"))
                .font(ShellFonts.smallBold).foregroundStyle(c.secondaryLabel)
            if !message.attachments.isEmpty {
                Text(verbatim: "Attached: " + message.attachments.map(\.label).joined(separator: ", "))
                    .font(ShellFonts.mini).foregroundStyle(c.secondaryLabel)
            }
            ForEach(Array(message.activity.suffix(6).enumerated()), id: \.offset) { pair in
                Text(verbatim: "› " + pair.element).font(ShellFonts.mini).foregroundStyle(c.tertiaryLabel).lineLimit(1)
            }
            if message.role == .user {
                Text(verbatim: message.text).font(ShellFonts.row).foregroundStyle(c.label).fixedSize(horizontal: false, vertical: true)
            } else {
                blocks(proposals, c)
                if !message.isComplete && message.text.isEmpty {
                    ProgressView().controlSize(.small).shellTarget("assistant spinner")
                }
            }
            if message.isCutOff == true {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "The reply was cut off at the output limit (Settings ▸ Coding Assistant ▸ Most output tokens).")
                        .font(ShellFonts.small).foregroundStyle(c.secondaryLabel).fixedSize(horizontal: false, vertical: true)
                    Button("Continue") { assistant.continueReply(in: conversation) }
                        .controlSize(.small).disabled(!message.isComplete)
                }
            }
            if let e = message.error {
                Text(verbatim: e).font(ShellFonts.small).foregroundStyle(e == "Stopped." ? c.secondaryLabel : c.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .shellTarget("assistant error")
            }
            if message.isComplete, undecided.count > 1 {
                HStack(spacing: 6) {
                    Text(verbatim: "\(undecided.count) changes").font(ShellFonts.small).foregroundStyle(c.secondaryLabel).lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Reject All") { assistant.rejectAll(in: message, conversation: conversation) }
                        .controlSize(.small).buttonStyle(.bordered).shellTarget("assistant reject all \(ordinal)")
                    Button("Accept All") { assistant.acceptAll(in: message, conversation: conversation) }
                        .controlSize(.small).buttonStyle(.borderedProminent).shellTarget("assistant accept all \(ordinal)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder func blocks(_ proposals: [ChangeProposal], _ c: ShellColors) -> some View {
        let parsed = MarkdownBlocks.parse(message.text)
        let codeIndexes = Self.codeIndexes(parsed)
        ForEach(Array(parsed.enumerated()), id: \.offset) { pair in
            switch pair.element {
            case .prose(let p):
                InlineMarkdownText(text: p, colors: c)
            case .code(let info, let text, _):
                let index = codeIndexes[pair.offset] ?? 0
                if let p = proposals.first(where: { $0.blockIndex == index }) {
                    ProposalCard(assistant: assistant, proposal: p, message: message, conversation: conversation, ordinal: ordinal, colors: c)
                } else {
                    CodeBox(model: model, info: info, text: text, colors: c)
                }
            }
        }
    }

    /// Each code block's position among the response's code blocks.
    static func codeIndexes(_ blocks: [MarkdownBlocks.Block]) -> [Int: Int] {
        var out: [Int: Int] = [:]
        var n = 0
        for (i, b) in blocks.enumerated() {
            if case .code = b {
                out[i] = n
                n += 1
            }
        }
        return out
    }
}

/// Prose with code spans and emphasis.
struct InlineMarkdownText: View {
    var text: String
    var colors: ShellColors

    var body: some View {
        let runs = AssistantInline.runs(text)
        runs.reduce(Text(verbatim: "")) { t, r in
            var piece = Text(verbatim: r.text)
            if r.code { piece = piece.font(.system(size: 12, design: .monospaced)) }
            if r.bold { piece = piece.bold() }
            if r.italic { piece = piece.italic() }
            return t + piece
        }
        .font(ShellFonts.row)
        .foregroundStyle(colors.label)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A code block that is an example: its language and Copy, the code in a
/// monospaced box.
struct CodeBox: View {
    var model: WorkspaceShellModel
    var info: String
    var text: String
    var colors: ShellColors

    var body: some View {
        let c = colors
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(verbatim: info.split(separator: " ").first.map(String.init) ?? "").font(ShellFonts.mini).foregroundStyle(c.secondaryLabel)
                Spacer(minLength: 4)
                Button("Copy") { ShellPasteboard.copy(text) }.controlSize(.small)
            }
            .padding(.horizontal, 6)
            .frame(height: 20)
            Hairline(color: c.separator)
            Text(verbatim: text).font(.system(size: 11, design: .monospaced)).foregroundStyle(c.label)
                .fixedSize(horizontal: false, vertical: true)
                .padding(6)
        }
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(c.content)
                .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(c.separator, lineWidth: 1) }
        }
    }
}

/// A proposed change: "Proposed: …", its size, Review…, Reject and
/// Accept (or Applied / Rejected once decided), and the change as a diff.
struct ProposalCard: View {
    var assistant: ShellAssistantModel
    var proposal: ChangeProposal
    var message: ConversationMessage
    var conversation: UUID
    var ordinal: Int
    var colors: ShellColors

    /// Lines shown in the pane; Review… shows all of them.
    static let lineLimit = 40

    var body: some View {
        let c = colors
        let decided = message.resolvedProposals[proposal.blockIndex]
        // A decided change shows the diff it was decided on (the file has
        // moved on since); after a relaunch only its header.
        let preview: AssistantChangePreview? = decided == nil
            ? assistant.preview(proposal, in: message) : assistant.decidedDiff(proposal, in: message).map { .ready($0) }
        let name = (proposal.path as NSString).lastPathComponent
        let tag = "\(name) \(proposal.blockIndex) \(ordinal)"
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(c.accent)
                Text(verbatim: ShellAssistantModel.proposalTitle(proposal)).font(ShellFonts.smallBold).foregroundStyle(c.label).lineLimit(1)
                Spacer(minLength: 4)
                if case .ready(let d)? = preview {
                    Text(verbatim: d.isNewFile ? "new file" : "+\(d.added) \u{2212}\(d.removed)")
                        .font(ShellFonts.mini.monospacedDigit()).foregroundStyle(c.secondaryLabel)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            Hairline(color: c.separator)
            switch preview {
            case .ready(let d)?:
                AssistantDiffLines(lines: d.lines, limit: Self.lineLimit, isNewFile: d.isNewFile, colors: c)
                    .padding(.vertical, 3)
                    .opacity(decided == nil ? 1 : 0.6)
                Hairline(color: c.separator)
            case .failed(let why)?:
                Text(verbatim: why).font(ShellFonts.small).foregroundStyle(c.error).padding(8)
                    .fixedSize(horizontal: false, vertical: true)
                Hairline(color: c.separator)
            case nil:
                EmptyView()
            }
            HStack(spacing: 6) {
                if let decided {
                    Image(systemName: decided == .accepted ? "checkmark.circle.fill" : "xmark.circle")
                        .font(.system(size: 11)).foregroundStyle(decided == .accepted ? c.success : c.secondaryLabel)
                    Text(verbatim: decided == .accepted ? "Applied" : "Rejected").font(ShellFonts.smallBold)
                        .foregroundStyle(decided == .accepted ? c.success : c.secondaryLabel)
                        .shellTarget("assistant decided \(tag)")
                }
                Spacer(minLength: 4)
                if decided == nil || preview != nil {
                    Button("Review…") { assistant.openReview(proposal, message: message, conversation: conversation) }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .help("Compare the proposed change with the file side by side")
                        .shellTarget("assistant review \(tag)")
                }
                if decided == nil {
                    Button("Reject") { assistant.reject(proposal, message: message, conversation: conversation) }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .help("Leave the file as it is")
                        .shellTarget("assistant reject \(tag)")
                    let isNew: Bool = { if case .ready(let d)? = preview { return d.isNewFile }; return false }()
                    Button(isNew ? "Create File" : "Accept") { assistant.accept(proposal, message: message, conversation: conversation) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .disabled({
                            if case .failed? = preview { return true }
                            if case .ready(let d)? = preview { return d.lines.isEmpty && !d.isNewFile }
                            return false
                        }())
                        .help("Apply the change in the editor (unsaved; Undo takes it back)")
                        .shellTarget("assistant accept \(tag)")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
        }
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(c.content)
                .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(c.separator, lineWidth: 1) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .shellTarget("assistant proposal \(tag)")
    }
}

/// A compact unified diff: the line number, a bar beside added and removed
/// lines on a tinted band, a dotted line between the change's parts.
struct AssistantDiffLines: View {
    var lines: [AssistantDiffLine]
    var limit: Int
    var isNewFile: Bool
    var colors: ShellColors

    var body: some View {
        let c = colors
        let shown = lines.prefix(limit)
        VStack(alignment: .leading, spacing: 0) {
            if lines.isEmpty {
                Text(verbatim: "No changes to the file.").font(ShellFonts.small).foregroundStyle(c.secondaryLabel)
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { pair in row(pair.element, c) }
            if lines.count > shown.count {
                Text(verbatim: "\(lines.count - shown.count) more lines — Review… shows them all").font(ShellFonts.mini).foregroundStyle(c.secondaryLabel)
                    .padding(.horizontal, 8).padding(.vertical, 3)
            }
        }
    }

    func row(_ l: AssistantDiffLine, _ c: ShellColors) -> some View {
        let mono = Font.system(size: 11, design: .monospaced)
        let (tint, bar): (Color, Color) = switch l.kind {
        case .added: (c.success.opacity(0.14), c.success)
        case .removed: (c.error.opacity(0.13), c.error)
        default: (Color.clear, Color.clear)
        }
        return HStack(spacing: 0) {
            if l.kind == .gap {
                Text(verbatim: "\u{2504}\u{2504}\u{2504}").font(mono).foregroundStyle(c.tertiaryLabel).padding(.leading, 8)
            } else {
                Text(verbatim: (l.new ?? l.old).map(String.init) ?? "").font(mono).foregroundStyle(c.tertiaryLabel)
                    .frame(width: 30, alignment: .trailing)
                Rectangle().fill(bar).frame(width: 2).padding(.horizontal, 5)
                Text(verbatim: l.text.replacingOccurrences(of: "\t", with: "    ")).font(mono).foregroundStyle(c.label).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 15)
        .background(tint)
    }
}
