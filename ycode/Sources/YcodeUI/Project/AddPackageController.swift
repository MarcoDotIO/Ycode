import AppKit
import YcodeProject

/// File ▸ Add Package Dependencies…: a URL or path field, a dependency
/// rule with its version fields, then (after the package is fetched) a
/// product list with the target each is added to. See
/// `specs/ide/package-dependencies.md` §Add Package sheet.
@MainActor
public final class AddPackageController: NSViewController {
    public enum Rule: Int, CaseIterable {
        case upToNextMajor, upToNextMinor, range, exact, branch, revision
        public var title: String {
            switch self {
            case .upToNextMajor: "Up to Next Major Version"
            case .upToNextMinor: "Up to Next Minor Version"
            case .range: "Range of Versions"
            case .exact: "Exact Version"
            case .branch: "Branch"
            case .revision: "Commit"
            }
        }
    }

    public let locationField = NSSearchField()
    public let rulePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    public let valueField = NSTextField(string: "1.0.0")
    public let upperField = NSTextField(string: "2.0.0")
    public let targetPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    public let errorLabel = NSTextField(labelWithString: "")
    public let addButton = NSButton(title: "Add Package", target: nil, action: nil)
    public private(set) var productChecks: [NSButton] = []
    private let productStack = NSStackView()
    private let upperLabel = NSTextField(labelWithString: "to")
    private let targets: [String]

    /// (location, rule) → the package's products, or an error text.
    /// Fetching may clone: the window runs it off the main thread.
    public var onFetch: ((String, SwiftPackageRequirement) async -> Result<[String], Error>)?
    /// (chosen products, target) after the package is fetched.
    public var onLink: (([String], String) -> Void)?
    public private(set) var fetchedProducts: [String]?

    public init(targets: [String]) {
        self.targets = targets
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
        let root = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: 620, height: 380))
        let title = NSTextField(labelWithString: "Add Package Dependency")
        title.font = .boldSystemFont(ofSize: 13)
        locationField.placeholderString = "Package URL or local path"
        locationField.widthAnchor.constraint(equalToConstant: 440).isActive = true
        for r in Rule.allCases { rulePopUp.addItem(withTitle: r.title) }
        rulePopUp.target = self
        rulePopUp.action = #selector(ruleChanged)
        valueField.widthAnchor.constraint(equalToConstant: 120).isActive = true
        upperField.widthAnchor.constraint(equalToConstant: 120).isActive = true
        targetPopUp.addItems(withTitles: targets)
        errorLabel.textColor = .systemRed
        productStack.orientation = .vertical
        productStack.alignment = .leading
        addButton.target = self
        addButton.action = #selector(addClicked)
        addButton.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let rule = NSStackView(views: [NSTextField(labelWithString: "Dependency Rule:"), rulePopUp, valueField, upperLabel, upperField])
        let target = NSStackView(views: [NSTextField(labelWithString: "Add to Target:"), targetPopUp])
        let buttons = NSStackView(views: [errorLabel, cancel, addButton])
        let stack = NSStackView(views: [title, locationField, rule, productStack, target, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor), stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        view = root
        ruleChanged()
    }

    public var rule: Rule {
        get { Rule(rawValue: rulePopUp.indexOfSelectedItem) ?? .upToNextMajor }
        set { loadViewIfNeeded(); rulePopUp.selectItem(at: newValue.rawValue); ruleChanged() }
    }

    @objc private func ruleChanged() {
        upperLabel.isHidden = rule != .range
        upperField.isHidden = rule != .range
        switch rule {
        case .branch: if Version.isVersion(valueField.stringValue) { valueField.stringValue = "main" }
        case .revision: if Version.isVersion(valueField.stringValue) { valueField.stringValue = "" }
        default: if !Version.isVersion(valueField.stringValue) { valueField.stringValue = "1.0.0" }
        }
    }

    private enum Version { static func isVersion(_ s: String) -> Bool { s.first?.isNumber == true } }

    /// The requirement the rule and fields describe.
    public var requirement: SwiftPackageRequirement {
        let v = valueField.stringValue.trimmingCharacters(in: .whitespaces)
        switch rule {
        case .upToNextMajor: return .upToNextMajor(from: v)
        case .upToNextMinor: return .upToNextMinor(from: v)
        case .range: return .range(from: v, to: upperField.stringValue.trimmingCharacters(in: .whitespaces))
        case .exact: return .exact(v)
        case .branch: return .branch(v)
        case .revision: return .revision(v)
        }
    }

    /// First click fetches the package and lists its products (all
    /// checked); the second links the checked ones and closes.
    @objc public func addClicked() {
        guard adding == nil else { return }
        adding = Task { [weak self] in
            await self?.add()
            self?.adding = nil
        }
    }

    /// The fetch started by Add Package, while it runs.
    public private(set) var adding: Task<Void, Never>?

    /// Add Package's step: fetch (first) or link (second).
    public func add() async {
        loadViewIfNeeded()
        if fetchedProducts == nil {
            addButton.isEnabled = false
            defer { addButton.isEnabled = true }
            switch await onFetch?(locationField.stringValue, requirement) ?? .success([]) {
            case .success(let products):
                fetchedProducts = products
                errorLabel.stringValue = ""
                productStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
                productStack.addArrangedSubview(NSTextField(labelWithString: "Choose package products:"))
                productChecks = products.map { NSButton(checkboxWithTitle: $0, target: nil, action: nil) }
                productChecks.forEach { $0.state = .on; productStack.addArrangedSubview($0) }
                locationField.isEnabled = false
                rulePopUp.isEnabled = false
            case .failure(let e):
                errorLabel.stringValue = "\(e)"
            }
            return
        }
        let chosen = productChecks.filter { $0.state == .on }.map(\.title)
        onLink?(chosen, targetPopUp.titleOfSelectedItem ?? targets.first ?? "")
        if presentingViewController != nil { dismiss(nil) }
    }

    @objc private func cancelClicked() { if presentingViewController != nil { dismiss(nil) } }
}
