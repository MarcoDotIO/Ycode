import Foundation

/// A `.xcscheme` document: which targets to build and how to run, test,
/// profile, analyze, and archive them. See `specs/formats/xcscheme.md`.
public struct Scheme: Sendable {
    public enum Action: String, CaseIterable, Sendable {
        case testing = "Testing", running = "Running", profiling = "Profiling"
        case archiving = "Archiving", analyzing = "Analyzing"
    }

    /// A pointer from a scheme to a target in some project.
    public struct BuildableReference: Equatable, Sendable {
        public var buildableIdentifier: String
        public var blueprintIdentifier: String
        public var buildableName: String
        public var blueprintName: String
        public var referencedContainer: String

        init(_ node: XMLNode) {
            buildableIdentifier = node["BuildableIdentifier"] ?? "primary"
            blueprintIdentifier = node["BlueprintIdentifier"] ?? ""
            buildableName = node["BuildableName"] ?? ""
            blueprintName = node["BlueprintName"] ?? ""
            referencedContainer = node["ReferencedContainer"] ?? ""
        }

        public init(blueprintIdentifier: String, buildableName: String, blueprintName: String, referencedContainer: String) {
            buildableIdentifier = "primary"
            self.blueprintIdentifier = blueprintIdentifier
            self.buildableName = buildableName
            self.blueprintName = blueprintName
            self.referencedContainer = referencedContainer
        }

        var node: XMLNode {
            XMLNode("BuildableReference", attributes: [
                ("BuildableIdentifier", buildableIdentifier),
                ("BlueprintIdentifier", blueprintIdentifier),
                ("BuildableName", buildableName),
                ("BlueprintName", blueprintName),
                ("ReferencedContainer", referencedContainer),
            ])
        }
    }

    public struct BuildEntry: Equatable, Sendable {
        public var reference: BuildableReference
        public var actions: Set<Action>
    }

    public struct Testable: Equatable, Sendable {
        public var reference: BuildableReference
        public var skipped: Bool
    }

    public struct Argument: Equatable, Sendable {
        public var value: String
        public var isEnabled: Bool
    }

    public struct EnvironmentVariable: Equatable, Sendable {
        public var key: String
        public var value: String
        public var isEnabled: Bool
    }

    public var name: String
    public var isShared: Bool
    public var url: URL?
    public var document: XMLNode

    public init(parsing text: String, name: String, isShared: Bool = true, url: URL? = nil) throws {
        document = try XcodeXML.parse(text)
        guard document.name == "Scheme" else { throw XMLReadError(message: "root element is not <Scheme>", offset: 0) }
        self.name = name
        self.isShared = isShared
        self.url = url
    }

    public init(contentsOf url: URL, isShared: Bool = true) throws {
        try self.init(parsing: try String(contentsOf: url, encoding: .utf8),
                      name: url.deletingPathExtension().lastPathComponent, isShared: isShared, url: url)
    }

    public func serialized() -> String { XcodeXML.write(document) }

    // MARK: - Views

    public var buildEntries: [BuildEntry] {
        (document.child("BuildAction")?.child("BuildActionEntries")?.children("BuildActionEntry") ?? []).compactMap { e in
            guard let ref = e.child("BuildableReference") else { return nil }
            let actions = Set(Action.allCases.filter { e["buildFor\($0.rawValue)"] == "YES" })
            return BuildEntry(reference: BuildableReference(ref), actions: actions)
        }
    }

    public var parallelizeBuildables: Bool { document.child("BuildAction")?["parallelizeBuildables"] != "NO" }
    public var buildImplicitDependencies: Bool { document.child("BuildAction")?["buildImplicitDependencies"] != "NO" }

    public var testables: [Testable] {
        (document.child("TestAction")?.child("Testables")?.children("TestableReference") ?? []).compactMap { t in
            guard let ref = t.child("BuildableReference") else { return nil }
            return Testable(reference: BuildableReference(ref), skipped: t["skipped"] == "YES")
        }
    }

    /// Test plans referenced by the test action (`container:`-relative paths).
    public var testPlans: [(reference: String, isDefault: Bool)] {
        (document.child("TestAction")?.child("TestPlans")?.children("TestPlanReference") ?? []).map {
            ($0["reference"] ?? "", $0["default"] == "YES")
        }
    }

    /// The build configuration an action uses (`"Debug"` for run/test/analyze
    /// and `"Release"` for profile/archive when unspecified).
    public func configuration(for action: String) -> String {
        if let c = document.child(action)?["buildConfiguration"] { return c }
        return ["ProfileAction", "ArchiveAction"].contains(action) ? "Release" : "Debug"
    }

    /// The target the launch action runs.
    public var launchTarget: BuildableReference? {
        guard let launch = document.child("LaunchAction") else { return nil }
        let runnable = launch.child("BuildableProductRunnable") ?? launch.child("MacroExpansion")
        return runnable?.child("BuildableReference").map(BuildableReference.init)
            ?? launch.child("MacroExpansion")?.child("BuildableReference").map(BuildableReference.init)
    }

    public var launchArguments: [Argument] {
        (document.child("LaunchAction")?.child("CommandLineArguments")?.children("CommandLineArgument") ?? []).map {
            Argument(value: $0["argument"] ?? "", isEnabled: $0["isEnabled"] == "YES")
        }
    }

    public var launchEnvironment: [EnvironmentVariable] {
        (document.child("LaunchAction")?.child("EnvironmentVariables")?.children("EnvironmentVariable") ?? []).map {
            EnvironmentVariable(key: $0["key"] ?? "", value: $0["value"] ?? "", isEnabled: $0["isEnabled"] == "YES")
        }
    }

    // MARK: - Discovery

    /// Schemes stored in a project or workspace bundle. Shared schemes come
    /// from `xcshareddata/xcschemes`. User schemes come from
    /// `xcuserdata/<user>.xcuserdatad/xcschemes`. Sorted by name.
    public static func discover(in container: URL, user: String = NSUserName()) -> [Scheme] {
        let fm = FileManager.default
        func load(_ dir: URL, shared: Bool) -> [Scheme] {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
            return names.filter { $0.hasSuffix(".xcscheme") }.compactMap {
                try? Scheme(contentsOf: dir.appendingPathComponent($0), isShared: shared)
            }
        }
        let shared = load(container.appendingPathComponent("xcshareddata/xcschemes"), shared: true)
        let mine = load(container.appendingPathComponent("xcuserdata/\(user).xcuserdatad/xcschemes"), shared: false)
        return (shared + mine).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The scheme Xcode generates for a target when a project has none.
    /// Only the build and launch structure is produced. Attribute defaults
    /// beyond those that select targets are not modeled yet.
    public static func autocreated(for target: BuildableReference, isTestBundle: Bool, isRunnable: Bool) -> Scheme {
        let entry = XMLNode("BuildActionEntry", attributes: [
            ("buildForTesting", "YES"), ("buildForRunning", isTestBundle ? "NO" : "YES"),
            ("buildForProfiling", isTestBundle ? "NO" : "YES"), ("buildForArchiving", isTestBundle ? "NO" : "YES"),
            ("buildForAnalyzing", "YES"),
        ], children: [target.node])
        var children = [
            XMLNode("BuildAction", attributes: [("parallelizeBuildables", "YES"), ("buildImplicitDependencies", "YES")],
                    children: [XMLNode("BuildActionEntries", children: [entry])]),
        ]
        var test = XMLNode("TestAction", attributes: [("buildConfiguration", "Debug")])
        if isTestBundle {
            test.children = [XMLNode("Testables", children: [
                XMLNode("TestableReference", attributes: [("skipped", "NO")], children: [target.node]),
            ])]
        }
        children.append(test)
        var launch = XMLNode("LaunchAction", attributes: [("buildConfiguration", "Debug")])
        if isRunnable {
            launch.children = [XMLNode("BuildableProductRunnable", attributes: [("runnableDebuggingMode", "0")], children: [target.node])]
        }
        children.append(launch)
        children.append(XMLNode("ProfileAction", attributes: [("buildConfiguration", "Release")]))
        children.append(XMLNode("AnalyzeAction", attributes: [("buildConfiguration", "Debug")]))
        children.append(XMLNode("ArchiveAction", attributes: [("buildConfiguration", "Release"), ("revealArchiveInOrganizer", "YES")]))
        let doc = XMLNode("Scheme", attributes: [("version", "1.7")], children: children)
        // swiftlint:disable:next force_try - parses XML this function just wrote
        var s = try! Scheme(parsing: XcodeXML.write(doc), name: target.blueprintName, isShared: false)
        s.url = nil
        return s
    }
}
