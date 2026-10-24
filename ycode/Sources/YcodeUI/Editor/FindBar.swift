import AppKit

/// Find and replace inside one text. See `specs/ide/source-editor.md`
/// §Find bar.
public struct EditorFind: Equatable {
    public var query = ""
    public var replacement = ""
    public var options = WorkspaceSearch.Options()
    public private(set) var matches: [NSRange] = []
    /// Index of the current match, if any.
    public private(set) var current: Int?

    public init() {}

    /// Recomputes matches; the current match becomes the first one at or
    /// after `from`.
    public mutating func update(text: String, from: Int = 0) {
        guard !query.isEmpty, let regex = options.expression(for: query) else {
            matches = []
            current = nil
            return
        }
        matches = WorkspaceSearch.search(regex, inText: text).map(\.range)
        current = matches.isEmpty ? nil : (matches.firstIndex { $0.location >= from } ?? 0)
    }

    /// Moves to the next (or previous) match, wrapping around.
    public mutating func step(_ forward: Bool) {
        guard !matches.isEmpty else { return }
        let c = current ?? (forward ? -1 : 0)
        current = ((c + (forward ? 1 : -1)) % matches.count + matches.count) % matches.count
    }

    public var currentRange: NSRange? { current.map { matches[$0] } }

    /// The text that replaces `range` (regex templates expand `$1` …).
    public func replacementText(in text: String, range: NSRange) -> String {
        guard options.regularExpression, let regex = options.expression(for: query),
              let m = regex.firstMatch(in: text, range: range) else { return replacement }
        return regex.replacementString(for: m, in: text, offset: 0, template: replacement)
    }

    /// The whole text with every match replaced.
    public func replacingAll(in text: String) -> (String, Int) {
        guard !query.isEmpty, let regex = options.expression(for: query) else { return (text, 0) }
        let ns = text as NSString
        let count = regex.numberOfMatches(in: text, range: NSRange(location: 0, length: ns.length))
        let template = options.regularExpression ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        return (regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: template), count)
    }
}

/// The bar above the editor: query (and replacement) fields, option
/// pop-ups, match count, previous/next and Done.
@MainActor
final class FindBarView: NSView {
    let queryField = NSSearchField()
    let replaceField = NSTextField()
    let countLabel = NSTextField(labelWithString: "")
    let style = NSPopUpButton(frame: .zero, pullsDown: false)
    let match = NSPopUpButton(frame: .zero, pullsDown: false)
    let caseMode = NSPopUpButton(frame: .zero, pullsDown: false)
    let replaceRow = NSStackView()
    var onChange: (() -> Void)?
    var onStep: ((Bool) -> Void)?
    var onReplace: ((Bool) -> Void)?
    var onDone: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        queryField.placeholderString = "Find"
        queryField.target = self
        queryField.action = #selector(changed)
        replaceField.placeholderString = "Replace"
        for (p, titles) in [(style, ["Text", "Regular Expression"]), (match, ["Containing", "Matching Word"]),
                            (caseMode, ["Ignoring Case", "Matching Case"])] {
            p.addItems(withTitles: titles)
            p.controlSize = .small
            p.target = self
            p.action = #selector(changed)
        }
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: 11)
        let prev = NSButton(image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous")!, target: self, action: #selector(previous))
        let next = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next")!, target: self, action: #selector(nextMatch))
        let done = NSButton(title: "Done", target: self, action: #selector(doneClicked))
        for b in [prev, next] { b.bezelStyle = .texturedRounded }
        done.controlSize = .small
        let top = NSStackView(views: [style, match, caseMode, queryField, countLabel, prev, next, done])
        top.spacing = 6
        let replaceOne = NSButton(title: "Replace", target: self, action: #selector(replaceOneClicked))
        let replaceAll = NSButton(title: "All", target: self, action: #selector(replaceAllClicked))
        for b in [replaceOne, replaceAll] { b.controlSize = .small }
        replaceRow.setViews([replaceField, replaceOne, replaceAll], in: .leading)
        replaceRow.spacing = 6
        let stack = NSStackView(views: [top, replaceRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // Narrow editors (splits) clip the bar instead of growing.
        let fit = stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        fit.priority = .defaultLow
        clipsToBounds = true
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.leadingAnchor.constraint(equalTo: leadingAnchor), fit,
            queryField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            replaceField.widthAnchor.constraint(equalTo: queryField.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    var options: WorkspaceSearch.Options {
        WorkspaceSearch.Options(regularExpression: style.indexOfSelectedItem == 1, wholeWord: match.indexOfSelectedItem == 1,
                                ignoreCase: caseMode.indexOfSelectedItem != 1)
    }

    @objc func changed() { onChange?() }
    @objc func previous() { onStep?(false) }
    @objc func nextMatch() { onStep?(true) }
    @objc func doneClicked() { onDone?() }
    @objc func replaceOneClicked() { onReplace?(false) }
    @objc func replaceAllClicked() { onReplace?(true) }
}
