import Foundation

/// Edits to a scheme's XML tree for the scheme editor. Untouched parts of
/// the document keep their exact layout. See `specs/ide/schemes.md`.
extension Scheme {
    /// Action elements in the order Xcode writes them.
    public static let actionElements = ["BuildAction", "TestAction", "LaunchAction", "ProfileAction", "AnalyzeAction", "ArchiveAction"]

    /// Applies `edit` to the action element, creating it in canonical order
    /// if missing.
    mutating func editAction(_ name: String, _ edit: (inout XMLNode) -> Void) {
        if let i = document.children.firstIndex(where: { $0.name == name }) {
            edit(&document.children[i])
            return
        }
        var node = XMLNode(name)
        edit(&node)
        let rank = Self.actionElements.firstIndex(of: name) ?? Self.actionElements.count
        let at = document.children.firstIndex { (Self.actionElements.firstIndex(of: $0.name) ?? 99) > rank } ?? document.children.count
        document.children.insert(node, at: at)
    }

    /// Build ▸ Build Options ▸ Find Implicit Dependencies.
    public mutating func setBuildImplicitDependencies(_ on: Bool) {
        editAction("BuildAction") { $0["buildImplicitDependencies"] = on ? "YES" : "NO" }
    }

    /// Build ▸ Targets table: one `buildFor<Action>` flag of the entry whose
    /// `BuildableReference` has `blueprintIdentifier`.
    public mutating func setBuild(_ action: Action, _ on: Bool, blueprintIdentifier: String) {
        editAction("BuildAction") { b in
            guard let ei = b.children.firstIndex(where: { $0.name == "BuildActionEntries" }) else { return }
            for i in b.children[ei].children.indices where b.children[ei].children[i].name == "BuildActionEntry" {
                guard b.children[ei].children[i].child("BuildableReference")?["BlueprintIdentifier"] == blueprintIdentifier else { continue }
                b.children[ei].children[i]["buildFor\(action.rawValue)"] = on ? "YES" : "NO"
            }
        }
    }

    /// Sets `buildConfiguration` on the action element named `action` (for
    /// example `"LaunchAction"`), creating the element if missing.
    public mutating func setConfiguration(_ configuration: String, for action: String) {
        editAction(action) { $0["buildConfiguration"] = configuration }
    }

    /// Replaces the launch arguments (empty removes the element).
    public mutating func setLaunchArguments(_ args: [Argument]) {
        editAction("LaunchAction") { launch in
            let items = args.map { XMLNode("CommandLineArgument", attributes: [("argument", $0.value), ("isEnabled", $0.isEnabled ? "YES" : "NO")]) }
            Self.replace(&launch, element: "CommandLineArguments", children: items,
                         after: ["BuildableProductRunnable", "MacroExpansion", "PathRunnable", "RemoteRunnable"])
        }
    }

    /// Replaces the launch environment (empty removes the element).
    public mutating func setLaunchEnvironment(_ vars: [EnvironmentVariable]) {
        editAction("LaunchAction") { launch in
            let items = vars.map {
                XMLNode("EnvironmentVariable", attributes: [("key", $0.key), ("value", $0.value), ("isEnabled", $0.isEnabled ? "YES" : "NO")])
            }
            Self.replace(&launch, element: "EnvironmentVariables", children: items,
                         after: ["CommandLineArguments", "BuildableProductRunnable", "MacroExpansion", "PathRunnable", "RemoteRunnable"])
        }
    }

    /// The Run ▸ Options working directory (nil when not customized).
    public var customWorkingDirectory: String? {
        guard let l = document.child("LaunchAction"), l["useCustomWorkingDirectory"] == "YES" else { return nil }
        return l["customWorkingDirectory"] ?? ""
    }

    /// Sets the Run ▸ Options working directory; nil turns the option off
    /// and removes both attributes. See `specs/ide/schemes.md`.
    public mutating func setCustomWorkingDirectory(_ path: String?) {
        editAction("LaunchAction") { l in
            if let path {
                l["useCustomWorkingDirectory"] = "YES"
                l["customWorkingDirectory"] = path
            } else {
                l["customWorkingDirectory"] = nil
                l["useCustomWorkingDirectory"] = nil
            }
        }
    }

    /// Sets, replaces or removes one child element of `parent`; a new one
    /// goes after the last present element named in `after`, else first.
    static func replace(_ parent: inout XMLNode, element: String, children: [XMLNode], after: [String]) {
        if let i = parent.children.firstIndex(where: { $0.name == element }) {
            if children.isEmpty { parent.children.remove(at: i) } else { parent.children[i].children = children }
            return
        }
        guard !children.isEmpty else { return }
        let node = XMLNode(element, children: children)
        let anchor = after.compactMap { name in parent.children.lastIndex { $0.name == name } }.max()
        parent.children.insert(node, at: anchor.map { $0 + 1 } ?? 0)
    }

    // MARK: Files

    /// Where a scheme of `container` lives when shared or per user.
    public static func fileURL(container: URL, name: String, shared: Bool, user: String = NSUserName()) -> URL {
        let dir = shared ? "xcshareddata/xcschemes" : "xcuserdata/\(user).xcuserdatad/xcschemes"
        return container.appendingPathComponent(dir).appendingPathComponent("\(name).xcscheme")
    }

    /// Writes the scheme to `url` (default: its own file) only if the text
    /// changed. Returns true when it wrote.
    @discardableResult
    public func save(to target: URL? = nil) throws -> Bool {
        guard let url = target ?? self.url else { return false }
        let text = serialized()
        if (try? String(contentsOf: url, encoding: .utf8)) == text { return false }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    /// Moves the scheme file between the shared and user locations of its
    /// container (the `.xcodeproj`/`.xcworkspace` that holds it).
    public mutating func setShared(_ shared: Bool, user: String = NSUserName()) throws {
        guard shared != isShared, let url else { return }
        // …/<container>/xcshareddata/xcschemes/X.xcscheme or
        // …/<container>/xcuserdata/<u>.xcuserdatad/xcschemes/X.xcscheme
        var container = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if !isShared { container.deleteLastPathComponent() }
        let target = Self.fileURL(container: container, name: name, shared: shared, user: user)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: target)
        self.url = target
        isShared = shared
    }
}

extension Scheme.Argument {
    /// A launch argument with its enabled checkbox.
    public init(_ value: String, enabled isEnabled: Bool) {
        self.value = value
        self.isEnabled = isEnabled
    }
}

extension Scheme.EnvironmentVariable {
    /// An environment variable `key=value` with its enabled checkbox.
    public init(_ key: String, _ value: String, enabled isEnabled: Bool) {
        self.key = key
        self.value = value
        self.isEnabled = isEnabled
    }
}

extension Scheme {
    /// The scheme generated for a target of a project without scheme files,
    /// with the test bundles it hosts as testables and (optionally) an
    /// automatic test plan (`shouldAutocreateTestPlan = YES`). A test bundle
    /// tests itself. See `specs/formats/xcode-xml.md` and
    /// `specs/xcodebuild/info-commands.md` §2.1.
    public static func autocreated(for target: BuildableReference, isTestBundle: Bool, isRunnable: Bool,
                                   hostedTests: [BuildableReference], autocreateTestPlan: Bool) -> Scheme {
        var s = autocreated(for: target, isTestBundle: isTestBundle, isRunnable: isRunnable)
        guard let i = s.document.children.firstIndex(where: { $0.name == "TestAction" }) else { return s }
        var test = s.document.children[i]
        if autocreateTestPlan { test["shouldAutocreateTestPlan"] = "YES" }
        let testables = isTestBundle ? [target] : hostedTests
        test.children = testables.isEmpty ? [] : [XMLNode("Testables", children: testables.map {
            XMLNode("TestableReference", attributes: [("skipped", "NO")], children: [$0.node])
        })]
        s.document.children[i] = test
        return s
    }
}
