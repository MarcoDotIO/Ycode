import Foundation
import YcodeProject
import YcodeWorkspace

/// The scheme generated for a target of a project that has no scheme files
/// (info-commands.md §2.1): it builds the target, tests the target itself
/// (test bundles) or the test bundles hosted by it, and runs it when it is
/// an application or tool. Its test action asks for an automatic test plan.
enum AutocreatedScheme {
    static func reference(_ t: PBXObject, _ p: LoadedProject, _ container: String) -> YcodeWorkspace.XMLNode {
        let name = t.string("name") ?? ""
        let product = t.string("productReference").flatMap { p.proj[$0]?.string("path") } ?? name
        return YcodeWorkspace.XMLNode("BuildableReference", attributes: [
            ("BuildableIdentifier", "primary"), ("BlueprintIdentifier", t.id), ("BuildableName", product),
            ("BlueprintName", name), ("ReferencedContainer", "container:\(container)"),
        ])
    }

    static func buildable(_ t: PBXObject, _ p: LoadedProject, _ container: String) -> Scheme.BuildableReference {
        let name = t.string("name") ?? ""
        let product = t.string("productReference").flatMap { p.proj[$0]?.string("path") } ?? name
        return Scheme.BuildableReference(blueprintIdentifier: t.id, buildableName: product, blueprintName: name,
                                         referencedContainer: "container:\(container)")
    }

    /// Built by `YcodeWorkspace`'s `Scheme.autocreated(…hostedTests:autocreateTestPlan:)`.
    static func make(for t: PBXObject, in p: LoadedProject, containerName: String) -> Scheme? {
        let type = t.string("productType") ?? ""
        let isTest = Container.isTestBundle(t)
        let runnable = type.hasSuffix(".application") || type.hasSuffix(".tool")
        let hosted = p.targets.filter { other in
            Container.isTestBundle(other)
                && p.proj.project?["attributes"]?.dictionary?["TargetAttributes"]?.dictionary?[other.id]?.dictionary?["TestTargetID"]?.string == t.id
        }
        var s = Scheme.autocreated(for: buildable(t, p, containerName), isTestBundle: isTest, isRunnable: runnable,
                                   hostedTests: hosted.map { buildable($0, p, containerName) }, autocreateTestPlan: true)
        s.name = t.string("name") ?? ""
        return s
    }

    /// Code coverage is collected when the scheme's test action enables it,
    /// or when it uses an automatic test plan and has tests.
    static func collectsCoverage(_ s: Scheme) -> Bool {
        guard let test = s.document.child("TestAction") else { return false }
        if test["codeCoverageEnabled"] == "YES" { return true }
        return test["shouldAutocreateTestPlan"] == "YES" && !s.testables.isEmpty
    }
}
