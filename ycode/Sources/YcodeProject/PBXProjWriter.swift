import YcodePlist

/// Writes a `PBXProj` in the exact layout Xcode produces, so that saving an
/// untouched project is a no-op diff. See `specs/formats/pbxproj.md`.
public struct PBXProjWriter {
    /// Classes written on a single line.
    static let singleLineClasses: Set<String> = ["PBXBuildFile", "PBXFileReference"]

    /// Keys whose values are object IDs but never get a reference comment.
    static let uncommentedKeys: Set<String> = ["remoteGlobalIDString", "TestTargetID"]

    static let defaultPhaseNames: [String: String] = [
        "PBXSourcesBuildPhase": "Sources",
        "PBXFrameworksBuildPhase": "Frameworks",
        "PBXResourcesBuildPhase": "Resources",
        "PBXHeadersBuildPhase": "Headers",
        "PBXCopyFilesBuildPhase": "CopyFiles",
        "PBXShellScriptBuildPhase": "ShellScript",
        "PBXRezBuildPhase": "Rez",
        "PBXAppleScriptBuildPhase": "AppleScript",
    ]

    let proj: PBXProj
    let projectName: String
    private var phaseOfBuildFile: [String: String] = [:]
    private var ownerOfConfigList: [String: String] = [:]
    private var groupOfExceptionSet: [String: String] = [:]
    private var listOfConfiguration: [String: String] = [:]
    private var commentCache: [String: String?] = [:]

    /// Prepares a writer for `proj`. `projectName` is the `.xcodeproj` name
    /// without the extension; it appears only in the project's
    /// configuration-list comments.
    public init(_ proj: PBXProj, projectName: String) {
        self.proj = proj
        self.projectName = projectName
        for obj in proj.objects.values {
            if obj.attributes["buildActionMask"] != nil || Self.defaultPhaseNames[obj.isa] != nil {
                for f in obj.references("files") { phaseOfBuildFile[f] = obj.id }
            }
            if let list = obj.string("buildConfigurationList") { ownerOfConfigList[list] = obj.id }
            for e in obj.references("exceptions") { groupOfExceptionSet[e] = obj.id }
            if obj.isa == "XCConfigurationList" {
                for c in obj.references("buildConfigurations") { listOfConfiguration[c] = obj.id }
            }
        }
    }

    /// Serializes `proj` in Xcode's layout. See `init(_:projectName:)`.
    public static func write(_ proj: PBXProj, projectName: String) -> String {
        var w = PBXProjWriter(proj, projectName: projectName)
        return w.write()
    }

    /// Returns the whole file text, starting with the `// !$*UTF8*$!` header.
    public mutating func write() -> String {
        var out = "// !$*UTF8*$!\n{\n"
        var top = proj.extraTopLevel
        top["archiveVersion"] = .string(proj.archiveVersion)
        top["classes"] = .dictionary(proj.classes)
        top["objectVersion"] = .string(proj.objectVersion)
        top["objects"] = .string("")  // placeholder, written specially below
        top["rootObject"] = .string(proj.rootObject)
        for key in top.keys.sorted(by: Self.keyOrder) {
            if key == "objects" {
                writeObjects(into: &out)
                continue
            }
            out += "\t" + OpenStepWriter.quote(key) + " = "
            writeValue(top[key]!, key: key, indent: 1, into: &out)
            out += ";\n"
        }
        out += "}\n"
        return out
    }

    // MARK: - Objects table

    private mutating func writeObjects(into out: inout String) {
        out += "\tobjects = {\n"
        let byClass = Dictionary(grouping: proj.objects.values, by: \.isa)
        for isa in byClass.keys.sorted(by: Self.keyOrder) {
            out += "\n/* Begin \(isa) section */\n"
            for obj in byClass[isa]!.sorted(by: { Self.keyOrder($0.id, $1.id) }) {
                out += "\t\t" + reference(obj.id) + " = "
                if Self.singleLineClasses.contains(isa)
                    || (proj.style.singleLineSynchronizedGroups && isa == "PBXFileSystemSynchronizedRootGroup") {
                    writeInlineDictionary(obj.attributes, isObject: true, into: &out)
                } else {
                    writeDictionary(obj.attributes, isObject: true, indent: 2, into: &out)
                }
                out += ";\n"
            }
            out += "/* End \(isa) section */\n"
        }
        out += "\t};\n"
    }

    // MARK: - Multi-line values

    private mutating func writeValue(_ value: PlistValue, key: String?, indent: Int, into out: inout String) {
        switch value {
        case .string(let s):
            out += scalar(s, key: key)
        case .data(let bytes):
            out += "<" + bytes.map(OpenStepWriter.hex).joined() + ">"
        case .array(let items):
            out += "(\n"
            for item in items {
                out += OpenStepWriter.tabs(indent + 1)
                writeValue(item, key: key, indent: indent + 1, into: &out)
                out += ",\n"
            }
            out += OpenStepWriter.tabs(indent) + ")"
        case .dictionary(let dict):
            writeDictionary(dict, isObject: false, indent: indent, into: &out)
        }
    }

    private mutating func writeDictionary(_ dict: PlistDictionary, isObject: Bool, indent: Int, into out: inout String) {
        out += "{\n"
        for k in orderedKeys(dict, isObject: isObject) {
            out += OpenStepWriter.tabs(indent + 1) + OpenStepWriter.quote(k) + " = "
            writeValue(dict[k]!, key: k, indent: indent + 1, into: &out)
            out += ";\n"
        }
        out += OpenStepWriter.tabs(indent) + "}"
    }

    // MARK: - Single-line values

    private mutating func writeInline(_ value: PlistValue, key: String?, into out: inout String) {
        switch value {
        case .string(let s):
            out += scalar(s, key: key)
        case .data(let bytes):
            out += "<" + bytes.map(OpenStepWriter.hex).joined() + ">"
        case .array(let items):
            out += "("
            for item in items {
                writeInline(item, key: key, into: &out)
                out += ", "
            }
            out += ")"
        case .dictionary(let dict):
            writeInlineDictionary(dict, isObject: false, into: &out)
        }
    }

    private mutating func writeInlineDictionary(_ dict: PlistDictionary, isObject: Bool, into out: inout String) {
        out += "{"
        for k in orderedKeys(dict, isObject: isObject) {
            out += OpenStepWriter.quote(k) + " = "
            writeInline(dict[k]!, key: k, into: &out)
            out += "; "
        }
        out += "}"
    }

    // MARK: - Scalars and reference comments

    private mutating func scalar(_ s: String, key: String?) -> String {
        if let key, Self.uncommentedKeys.contains(key) { return OpenStepWriter.quote(s) }
        if proj.objects[s] != nil { return reference(s) }
        return OpenStepWriter.quote(s)
    }

    /// `ID /* comment */`, or the bare ID when the object has no comment.
    private mutating func reference(_ id: String) -> String {
        if let c = comment(for: id) { return id + " /* " + c + " */" }
        return id
    }

    /// The reference comment written after object `id`, or nil when the
    /// object has none (for example the main group). Results are cached.
    /// See `specs/formats/pbxproj.md` (Reference comments).
    public mutating func comment(for id: String) -> String? {
        if let cached = commentCache[id] { return cached }
        let c = computeComment(for: id)
        commentCache[id] = c
        return c
    }

    private mutating func computeComment(for id: String) -> String? {
        guard let obj = proj.objects[id] else { return nil }
        let isa = obj.isa
        switch isa {
        case "PBXProject":
            return "Project object"
        case "PBXBuildFile":
            var name: String?
            if let ref = obj.string("fileRef") { name = comment(for: ref) }
            if name == nil, let ref = obj.string("productRef") { name = comment(for: ref) }
            let phase = phaseOfBuildFile[id].flatMap { comment(for: $0) }
            return "\(name ?? "(null)") in \(phase ?? "(null)")"
        case "XCConfigurationList":
            return "Build configuration list for " + ownerDescription(ofList: id)
        case "XCBuildConfiguration":
            let name = obj.string("name") ?? ""
            guard proj.style.qualifiedConfigurationComments, let list = listOfConfiguration[id] else { return name }
            return name + " configuration for " + ownerDescription(ofList: list)
        case "PBXContainerItemProxy", "PBXTargetDependency":
            return isa
        case "XCSwiftPackageProductDependency":
            return obj.string("productName")
        case "XCRemoteSwiftPackageReference":
            return "XCRemoteSwiftPackageReference \"\(Self.repositoryName(obj.string("repositoryURL") ?? ""))\""
        case "XCLocalSwiftPackageReference":
            return "XCLocalSwiftPackageReference \"\(obj.string("relativePath") ?? "")\""
        case "PBXFileSystemSynchronizedBuildFileExceptionSet":
            guard proj.style.descriptiveExceptionSetComments else { return isa }
            let folder = groupOfExceptionSet[id].flatMap { comment(for: $0) } ?? ""
            let target = obj.string("target").flatMap { comment(for: $0) } ?? ""
            return "Exceptions for \"\(folder)\" folder in \"\(target)\" target"
        case "PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet":
            let folder = groupOfExceptionSet[id].flatMap { comment(for: $0) } ?? ""
            let phase = obj.string("buildPhase").flatMap { comment(for: $0) } ?? ""
            return "Exceptions for \"\(folder)\" folder in \"\(phase)\" phase"
        default:
            if let def = Self.defaultPhaseNames[isa] { return obj.string("name") ?? def }
            return obj.string("name") ?? obj.string("path")
        }
    }

    /// `PBXNativeTarget "App"`: the class and name of a list's owner.
    private func ownerDescription(ofList id: String) -> String {
        guard let ownerID = ownerOfConfigList[id], let owner = proj.objects[ownerID] else { return "(null)" }
        let ownerName = owner.isa == "PBXProject" ? projectName : (owner.string("name") ?? "")
        return "\(owner.isa) \"\(ownerName)\""
    }

    /// `https://github.com/owner/Repo.git` → `Repo`.
    static func repositoryName(_ url: String) -> String {
        var last = url.split(separator: "/").last.map(String.init) ?? url
        if last.hasSuffix(".git") { last.removeLast(4) }
        return last
    }

    // MARK: - Ordering

    private func orderedKeys(_ dict: PlistDictionary, isObject: Bool) -> [String] {
        let sorted = dict.keys.filter { !(isObject && $0 == "isa") }.sorted(by: Self.keyOrder)
        return isObject && dict["isa"] != nil ? ["isa"] + sorted : sorted
    }

    /// Literal (code-unit) ordering, matching a non-localized string compare.
    static func keyOrder(_ a: String, _ b: String) -> Bool {
        a.utf16.lexicographicallyPrecedes(b.utf16)
    }
}

extension PBXProj {
    /// Serializes in Xcode's layout. `projectName` is the `.xcodeproj` name
    /// without extension; Xcode uses it in one comment but never stores it.
    public func serialized(projectName: String) -> String {
        PBXProjWriter.write(self, projectName: projectName)
    }
}
