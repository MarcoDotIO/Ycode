import Foundation
import YcodeBuild
import YcodeXcodebuild

/// Swift package products used by targets of Xcode projects. See
/// `specs/ide/language.md` §Build server, "Package products".
///
/// The PIF swift-build builds the container with
/// (`XcodePIFSource().makePIF(for:)`, which loads the package graph through
/// SwiftPM) names each target's package products. The settings their
/// package targets impart to clients (`impartedBuildProperties`) give the
/// client's search paths and module arguments, and preparation builds the
/// products with swift-build into the index arena, where the client's
/// `-I <products>` finds their modules.
public struct PackageProducts: @unchecked Sendable {
    public let pif: XcodePIF
    /// Product target GUIDs per build target identifier.
    public let products: [String: [String]]
    /// Package targets (PIF `contents`) by GUID.
    let targets: [String: [String: Any]]

    /// The imparted settings the index arguments take.
    public static let impartedSettings = ["FRAMEWORK_SEARCH_PATHS", "HEADER_SEARCH_PATHS", "SWIFT_INCLUDE_PATHS", "OTHER_CFLAGS", "OTHER_SWIFT_FLAGS"]

    public init(pif: XcodePIF, products: [String: [String]]) {
        self.pif = pif
        self.products = products
        var targets: [String: [String: Any]] = [:]
        for o in pif.packages?.objects ?? [] where o["type"] as? String == "target" {
            if let c = o["contents"] as? [String: Any], let g = c["guid"] as? String { targets[g] = c }
        }
        self.targets = targets
    }

    /// The products of every target that uses one; nil when none does.
    public static func load(_ graph: BuildGraph, source: XcodePIFSource = XcodePIFSource()) throws -> PackageProducts? {
        guard graph.targets.contains(where: { !$0.packageProducts.isEmpty }) else { return nil }
        let c = graph.container
        let pif = try source.makePIF(for: BuildRequest(container: c.kind == .workspace ? .workspace(c.url.path) : .project(c.url.path)))
        var products: [String: [String]] = [:]
        for t in graph.targets where !t.packageProducts.isEmpty {
            let p = graph.project(of: t)
            guard let object = p.proj[t.objectID] else { continue }
            let guids = pif.packageProducts(p, object).map(\.guid)
            if !guids.isEmpty { products[t.id] = guids }
        }
        return PackageProducts(pif: pif, products: products)
    }

    /// The settings a target's products impart (their package targets,
    /// transitively, products first), for one configuration: setting name →
    /// words, without `$(inherited)`. Search paths are listed once each.
    public func imparted(for targetID: String, configuration: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for g in groups(for: targetID, configuration: configuration) {
            if g.name.hasSuffix("_PATHS") {
                for w in g.words where !(out[g.name] ?? []).contains(w) { out[g.name, default: []].append(w) }
            } else {
                out[g.name, default: []] += g.words
            }
        }
        return out
    }

    /// The imparted settings one package target at a time. A macro (a
    /// host-built tool with `SWIFT_IMPLEMENTS_MACROS_FOR_MODULE_NAMES`) is
    /// `-load-plugin-executable` of its product, which swift-build builds
    /// into `$(BUILD_DIR)/$(CONFIGURATION)`; host-built tools impart nothing
    /// else (their settings are for the host).
    func groups(for targetID: String, configuration: String) -> [(name: String, words: [String])] {
        var out: [(name: String, words: [String])] = []
        var seen = Set<String>(), added = Set<String>()
        var queue = products[targetID] ?? []
        var i = 0
        func add(_ name: String, _ words: [String]) {
            // Flags keep their order and pairs (`-Xcc -I -Xcc <dir>`); a
            // target's list is added once.
            if added.insert(name + "\u{0}" + words.joined(separator: "\u{0}")).inserted { out.append((name, words)) }
        }
        while i < queue.count {
            let g = queue[i]
            i += 1
            guard seen.insert(g).inserted, let t = targets[g] else { continue }
            let configs = t["buildConfigurations"] as? [[String: Any]] ?? []
            let config = configs.first { $0["name"] as? String == configuration } ?? configs.first
            if t["productTypeIdentifier"] as? String == "com.apple.product-type.tool.host-build" {
                let own = config?["buildSettings"] as? [String: Any] ?? [:]
                let modules = own["SWIFT_IMPLEMENTS_MACROS_FOR_MODULE_NAMES"] as? [String] ?? []
                if !modules.isEmpty, let name = t["name"] as? String {
                    add("OTHER_SWIFT_FLAGS", ["-load-plugin-executable", "$(BUILD_DIR)/$(CONFIGURATION)/\(name)#\(modules.joined(separator: ","))"])
                }
                continue
            }
            let settings = (config?["impartedBuildProperties"] as? [String: Any])?["buildSettings"] as? [String: Any] ?? [:]
            for name in Self.impartedSettings {
                let words = (settings[name] as? [String] ?? (settings[name] as? String).map(SettingWords.split) ?? []).filter { $0 != "$(inherited)" }
                if !words.isEmpty { add(name, words) }
            }
            for d in t["dependencies"] as? [[String: Any]] ?? [] {
                if let dg = d["guid"] as? String { queue.append(dg) }
            }
        }
        return out
    }

    /// A target's settings with its products' imparted settings added
    /// (expanded with the target's own settings; a flag list with a setting
    /// that cannot be expanded is left out whole, a search path alone).
    public func merged(_ settings: [String: String], targetID: String) -> [String: String] {
        guard products[targetID] != nil else { return settings }
        var s = settings
        var paths: [String: Set<String>] = [:]
        for g in groups(for: targetID, configuration: settings["CONFIGURATION"] ?? "Debug") {
            var expanded = g.words.compactMap { Self.expand($0, settings) }
            if g.name.hasSuffix("_PATHS") {
                expanded = expanded.filter { paths[g.name, default: []].insert($0).inserted }
            } else if expanded.count != g.words.count {
                continue
            }
            guard !expanded.isEmpty else { continue }
            s[g.name] = ([s[g.name] ?? ""] + expanded.map(Self.quoted)).filter { !$0.isEmpty }.joined(separator: " ")
        }
        return s
    }

    /// Expands `$(NAME)` and `${NAME}` from `settings`; nil when a setting
    /// is unknown. `GENERATED_MODULEMAP_DIR` defaults to swift-build's
    /// `$(OBJROOT)/GeneratedModuleMaps$(EFFECTIVE_PLATFORM_NAME)`.
    public static func expand(_ word: String, _ settings: [String: String]) -> String? {
        var out = ""
        var rest = Substring(word)
        while let open = rest.range(of: "$(") ?? rest.range(of: "${") {
            let close: Character = rest[open].hasSuffix("(") ? ")" : "}"
            guard let end = rest[open.upperBound...].firstIndex(of: close) else { return nil }
            out += rest[..<open.lowerBound]
            let name = String(rest[open.upperBound..<end])
            guard let value = settings[name] ?? defaultValue(name, settings) else { return nil }
            out += value
            rest = rest[rest.index(after: end)...]
        }
        return out + rest
    }

    static func defaultValue(_ name: String, _ settings: [String: String]) -> String? {
        guard name == "GENERATED_MODULEMAP_DIR", let objroot = settings["OBJROOT"] else { return nil }
        return objroot + "/GeneratedModuleMaps" + (settings["EFFECTIVE_PLATFORM_NAME"] ?? "")
    }

    static func quoted(_ word: String) -> String {
        word.contains(where: { $0 == " " || $0 == "\t" || $0 == "\"" || $0 == "'" || $0 == "\\" })
            ? "'" + word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'" : word
    }
}
