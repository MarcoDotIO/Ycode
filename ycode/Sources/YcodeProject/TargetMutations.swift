import Foundation
import YcodePlist

/// Adding and deleting targets (the project editor's target list "+" and
/// "−", reference-ui-5.md §11.1.2). Objects are laid out as
/// `specs/formats/pbxproj.md` describes; untouched objects keep their bytes.
extension PBXProj {
    /// What a new native target is made of.
    public struct NewTarget: Sendable {
        public var name: String
        public var productType: String
        /// The product file name ("App.app") and its `explicitFileType`.
        public var productPath: String
        public var productFileType: String
        /// Settings written into every configuration of the new list.
        public var settings: [(String, PlistValue)]
        /// Build phase `isa`s, in order.
        public var phases: [String]
        /// A target this one depends on (by object ID), e.g. a test host.
        public var dependency: String?
        /// Folder of sources, as a synchronized root folder the target owns
        /// (object version 77 and later; older projects get none here: the
        /// caller adds a group with `addSourceGroup`, which outlives the
        /// target as the files do). Nil = none.
        public var sourceFolder: String?

        public init(name: String, productType: String, productPath: String, productFileType: String,
                    settings: [(String, PlistValue)], phases: [String], dependency: String? = nil, sourceFolder: String? = nil) {
            self.name = name
            self.productType = productType
            self.productPath = productPath
            self.productFileType = productFileType
            self.settings = settings
            self.phases = phases
            self.dependency = dependency
            self.sourceFolder = sourceFolder
        }
    }

    /// Adds a `PBXNativeTarget` with its configuration list (one
    /// configuration per project configuration), empty build phases, a
    /// product reference in the products group, an optional dependency
    /// and source folder. Returns the target's ID.
    @discardableResult
    public mutating func addTarget(_ t: NewTarget) -> String {
        func add(_ attrs: [(String, PlistValue)]) -> String {
            let id = makeObjectID()
            self[id] = PBXObject(id: id, attributes: PlistDictionary(attrs))
            return id
        }
        func strings(_ ids: [String]) -> PlistValue { .array(ids.map(PlistValue.string)) }
        let projectList = project?.string("buildConfigurationList")
        let names = buildConfigurations(listID: projectList).compactMap { $0.string("name") }
        let configs = (names.isEmpty ? ["Debug", "Release"] : names).map { n in
            add([("isa", "XCBuildConfiguration"), ("buildSettings", .dictionary(PlistDictionary(t.settings))), ("name", .string(n))])
        }
        let list = add([("isa", "XCConfigurationList"), ("buildConfigurations", strings(configs)), ("defaultConfigurationIsVisible", "0"),
                        ("defaultConfigurationName", .string(self[projectList ?? ""]?.string("defaultConfigurationName") ?? names.last ?? "Release"))])
        let phases = t.phases.map { isa in
            add([("isa", .string(isa)), ("buildActionMask", "2147483647"), ("files", .array([])), ("runOnlyForDeploymentPostprocessing", "0")])
        }
        let product = add([("isa", "PBXFileReference"), ("explicitFileType", .string(t.productFileType)), ("includeInIndex", "0"),
                           ("path", .string(t.productPath)), ("sourceTree", "BUILT_PRODUCTS_DIR")])
        if let g = project?.string("productRefGroup"), var group = self[g] {
            group["children"] = strings(group.references("children") + [product])
            self[g] = group
        }
        var deps: [String] = []
        if let host = t.dependency, let hostName = self[host]?.string("name") {
            let proxy = add([("isa", "PBXContainerItemProxy"), ("containerPortal", .string(rootObject)), ("proxyType", "1"),
                             ("remoteGlobalIDString", .string(host)), ("remoteInfo", .string(hostName))])
            deps.append(add([("isa", "PBXTargetDependency"), ("target", .string(host)), ("targetProxy", .string(proxy))]))
        }
        var attrs: [(String, PlistValue)] = [("isa", "PBXNativeTarget"), ("buildConfigurationList", .string(list)), ("buildPhases", strings(phases)),
                                             ("buildRules", .array([])), ("dependencies", strings(deps))]
        if let folder = t.sourceFolder, (Int(objectVersion) ?? 0) >= 77 {
            let g = add([("isa", "PBXFileSystemSynchronizedRootGroup"), ("path", .string(folder)), ("sourceTree", "<group>")])
            insertInMainGroup(g)
            attrs.append(("fileSystemSynchronizedGroups", strings([g])))
        }
        attrs += [("name", .string(t.name)), ("productName", .string(t.name)), ("productReference", .string(product)),
                  ("productType", .string(t.productType))]
        let target = add(attrs)
        if var p = project {
            p["targets"] = strings(p.references("targets") + [target])
            self[p.id] = p
        }
        return target
    }

    /// Puts a group or folder in the main group, before the products
    /// group (as new projects lay it out).
    mutating func insertInMainGroup(_ id: String) {
        guard let main = project?.string("mainGroup"), var mainGroup = self[main] else { return }
        var children = mainGroup.references("children")
        let at = project?.string("productRefGroup").flatMap { children.firstIndex(of: $0) } ?? children.count
        children.insert(id, at: at)
        mainGroup["children"] = .array(children.map(PlistValue.string))
        self[main] = mainGroup
    }

    /// A `PBXGroup` for a folder of sources in the main group (projects
    /// before object version 77). Returns its ID.
    @discardableResult
    public mutating func addSourceGroup(path: String) -> String {
        let id = makeObjectID()
        self[id] = PBXObject(id: id, attributes: PlistDictionary([("isa", "PBXGroup"), ("children", .array([])), ("path", .string(path)),
                                                                  ("sourceTree", "<group>")]))
        insertInMainGroup(id)
        return id
    }

    /// Deletes a target: its configuration list and configurations, build
    /// phases and their build files, rules, product reference, the
    /// dependencies other targets have on it (with their proxies), its
    /// package product dependencies no other target uses, its synchronized
    /// folders no other target uses, and its `TargetAttributes` entry.
    public mutating func removeTarget(_ id: String) {
        guard let t = self[id], t.isa.hasSuffix("Target") else { return }
        if let list = t.string("buildConfigurationList") {
            for c in self[list]?.references("buildConfigurations") ?? [] { self[c] = nil }
            self[list] = nil
        }
        for p in t.references("buildPhases") {
            for bf in self[p]?.references("files") ?? [] { self[bf] = nil }
            self[p] = nil
        }
        for r in t.references("buildRules") { self[r] = nil }
        for d in t.references("dependencies") {
            if let proxy = self[d]?.string("targetProxy") { self[proxy] = nil }
            self[d] = nil
        }
        let others = targets.filter { $0.id != id }
        // Dependencies of other targets on this one.
        for var o in others {
            let gone = o.references("dependencies").filter { self[$0]?.string("target") == id }
            guard !gone.isEmpty else { continue }
            for d in gone {
                if let proxy = self[d]?.string("targetProxy") { self[proxy] = nil }
                self[d] = nil
            }
            o["dependencies"] = .array(o.references("dependencies").filter { !gone.contains($0) }.map(PlistValue.string))
            self[o.id] = o
        }
        let usedProducts = Set(others.flatMap { $0.references("packageProductDependencies") })
        for pd in t.references("packageProductDependencies") where !usedProducts.contains(pd) { self[pd] = nil }
        let usedFolders = Set(others.flatMap { $0.references("fileSystemSynchronizedGroups") })
        for g in t.references("fileSystemSynchronizedGroups") where !usedFolders.contains(g) {
            for (gid, var group) in objects where group.references("children").contains(g) {
                group["children"] = .array(group.references("children").filter { $0 != g }.map(PlistValue.string))
                self[gid] = group
            }
            for e in self[g]?.references("exceptions") ?? [] { self[e] = nil }
            self[g] = nil
        }
        // Exception sets of shared folders that name this target.
        for e in objects.values where e.isa.hasSuffix("ExceptionSet") && e.string("target") == id {
            for (gid, var group) in objects where group.references("exceptions").contains(e.id) {
                let left = group.references("exceptions").filter { $0 != e.id }
                group["exceptions"] = left.isEmpty ? nil : .array(left.map(PlistValue.string))
                self[gid] = group
            }
            self[e.id] = nil
        }
        if let product = t.string("productReference") { removeFileReference(product) }
        if var p = project {
            p["targets"] = .array(p.references("targets").filter { $0 != id }.map(PlistValue.string))
            if var attrs = p["attributes"]?.dictionary, var ta = attrs["TargetAttributes"]?.dictionary, ta[id] != nil {
                ta[id] = nil
                // A test target names the target it tests.
                for k in ta.keys {
                    if var entry = ta[k]?.dictionary, entry["TestTargetID"]?.string == id { entry["TestTargetID"] = nil; ta[k] = .dictionary(entry) }
                }
                attrs["TargetAttributes"] = .dictionary(ta)
                p["attributes"] = .dictionary(attrs)
            }
            self[p.id] = p
        }
        self[id] = nil
    }
}
