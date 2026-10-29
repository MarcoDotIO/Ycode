import AppKit
import YcodeAssistant

/// The review sheet for a proposed change (coding-assistant.md §5.3): the
/// file now and with the change, side by side in the comparison view
/// (`specs/ide/comparison.md`), with Reject and Accept. Nothing is written
/// until the user accepts.
@MainActor
public final class ProposalReviewController: NSViewController {
    public let proposal: ChangeProposal
    /// The file's text now (nil: the file does not exist yet).
    public let original: String?
    public let proposed: String
    public let comparison = ComparisonView()
    public let acceptButton = NSButton(title: "Accept", target: nil, action: nil)
    public let rejectButton = NSButton(title: "Reject", target: nil, action: nil)
    /// Called once with the decision.
    public var onDecision: ((Bool) -> Void)?

    public init(proposal: ChangeProposal, original: String?, proposed: String) {
        self.proposal = proposal
        self.original = original
        self.proposed = proposed
        super.init(nibName: nil, bundle: nil)
        title = "Review Proposed Change"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public var headline: String {
        let name = (proposal.path as NSString).lastPathComponent
        if original == nil { return "Create \(proposal.path)" }
        let ops = LineDiff.diff(LineDiff.lines(original ?? ""), LineDiff.lines(proposed))
        let added = ops.filter { if case .added = $0 { true } else { false } }.count
        let removed = ops.filter { if case .removed = $0 { true } else { false } }.count
        return "Change \(name): +\(added) −\(removed) lines"
    }

    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 600))
        let label = NSTextField(labelWithString: headline)
        label.font = .boldSystemFont(ofSize: 13)
        let path = NSTextField(labelWithString: proposal.path)
        path.textColor = .secondaryLabelColor
        path.font = .systemFont(ofSize: 11)
        let name = (proposal.path as NSString).lastPathComponent
        comparison.workingCopyOnLeft = false  // current on the left, proposed on the right
        comparison.show(old: original ?? "", new: proposed, oldTitle: original == nil ? "\(name) (New File)" : "\(name) (Current)",
                        newTitle: "\(name) (Proposed)")
        acceptButton.title = original == nil ? "Create File" : "Accept"
        acceptButton.keyEquivalent = "\r"
        acceptButton.target = self
        acceptButton.action = #selector(accept)
        rejectButton.keyEquivalent = "\u{1b}"
        rejectButton.target = self
        rejectButton.action = #selector(reject)
        let note = NSTextField(labelWithString: original == nil ? "Creates the file on disk."
                                                               : "Accepting changes the open document; save it to keep the change. Undo reverts it.")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        let buttons = NSStackView(views: [note, NSView(), rejectButton, acceptButton])
        buttons.orientation = .horizontal
        for v in [label, path, comparison, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            path.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
            path.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            comparison.topAnchor.constraint(equalTo: path.bottomAnchor, constant: 10),
            comparison.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            comparison.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            buttons.topAnchor.constraint(equalTo: comparison.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])
        view = root
    }

    private var decided = false

    @objc public func accept() { decide(true) }
    @objc public func reject() { decide(false) }

    private func decide(_ ok: Bool) {
        guard !decided else { return }
        decided = true
        if presentingViewController != nil { dismiss(nil) }
        onDecision?(ok)
    }
}
