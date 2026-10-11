import Foundation
import YcodePlist

/// One entry of the `objects` table of a project file.
public struct PBXObject: Equatable, Sendable {
    public var id: String
    /// Every key of the object, including `isa`.
    public var attributes: PlistDictionary

    public init(id: String, attributes: PlistDictionary) {
        self.id = id
        self.attributes = attributes
    }

    public var isa: String { attributes["isa"]?.string ?? "" }

    public subscript(key: String) -> PlistValue? {
        get { attributes[key] }
        set { attributes[key] = newValue }
    }

    public func string(_ key: String) -> String? { attributes[key]?.string }
    public func references(_ key: String) -> [String] { attributes[key]?.array?.compactMap(\.string) ?? [] }
}

/// The contents of a `project.pbxproj` file: an object graph rooted at a
/// `PBXProject`. See `specs/formats/pbxproj.md`.
public struct PBXProj: Sendable {
    public enum LoadError: Error, CustomStringConvertible {
        case syntax(OpenStepParser.Error)
        case structure(String)

        public var description: String {
            switch self {
            case .syntax(let e): "syntax error at \(e)"
            case .structure(let m): "malformed project: \(m)"
            }
        }
    }

    public var archiveVersion: String
    public var classes: PlistDictionary
    public var objectVersion: String
    public var objects: [String: PBXObject]
    public var rootObject: String
    /// Top-level keys this model does not know about, kept for round-tripping.
    public var extraTopLevel: PlistDictionary
    /// Comment conventions to write with. Detected from the file on load so
    /// that saving keeps whichever Xcode release last wrote it.
    public var style: FormatStyle = .current

    /// Reference-comment conventions that changed between Xcode releases.
    /// Neither is recorded in the file's version fields.
    public struct FormatStyle: Equatable, Sendable {
        /// `Debug configuration for PBXNativeTarget "App"` instead of `Debug`.
        public var qualifiedConfigurationComments: Bool
        /// `Exceptions for "Dir" folder in "App" target` instead of the class name.
        public var descriptiveExceptionSetComments: Bool

        /// `PBXFileSystemSynchronizedRootGroup` written on one line (Xcode 16 era).
        public var singleLineSynchronizedGroups: Bool

        /// What the reference Xcode (27.x) writes.
        public static let current = FormatStyle(
            qualifiedConfigurationComments: true,
            descriptiveExceptionSetComments: true,
            singleLineSynchronizedGroups: false)

        public static func detect(in text: String) -> FormatStyle {
            FormatStyle(
                qualifiedConfigurationComments: text.contains(" configuration for PBX")
                    || !text.contains("isa = XCBuildConfiguration"),
                descriptiveExceptionSetComments: !text.contains("/* PBXFileSystemSynchronizedBuildFileExceptionSet */"),
                singleLineSynchronizedGroups: text.contains("{isa = PBXFileSystemSynchronizedRootGroup;"))
        }
    }

    public init(parsing text: String) throws(LoadError) {
        let root: PlistValue
        do { root = try OpenStepParser.parse(text) } catch { throw .syntax(error) }
        guard case .dictionary(var top) = root else { throw .structure("top level is not a dictionary") }
        guard case .dictionary(let objs)? = top["objects"] else { throw .structure("missing objects table") }
        guard let rootID = top["rootObject"]?.string else { throw .structure("missing rootObject") }
        archiveVersion = top["archiveVersion"]?.string ?? "1"
        classes = top["classes"]?.dictionary ?? PlistDictionary()
        objectVersion = top["objectVersion"]?.string ?? "46"
        rootObject = rootID
        var table: [String: PBXObject] = [:]
        for (id, value) in objs {
            guard case .dictionary(let attrs) = value else { throw .structure("object \(id) is not a dictionary") }
            table[id] = PBXObject(id: id, attributes: attrs)
        }
        objects = table
        for k in ["archiveVersion", "classes", "objectVersion", "objects", "rootObject"] { top[k] = nil }
        extraTopLevel = top
        style = .detect(in: text)
    }

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url.pathExtension == "xcodeproj" ? url.appendingPathComponent("project.pbxproj") : url)
        try self.init(parsing: String(decoding: data, as: UTF8.self))
    }

    public subscript(id: String) -> PBXObject? {
        get { objects[id] }
        set { objects[id] = newValue }
    }

    public var project: PBXObject? { objects[rootObject] }

    /// Objects of the given class, in ID order.
    public func objects(isa: String) -> [PBXObject] {
        objects.values.filter { $0.isa == isa }.sorted { $0.id < $1.id }
    }

    /// Targets in the order the project lists them.
    public var targets: [PBXObject] {
        (project?.references("targets") ?? []).compactMap { objects[$0] }
    }

    /// Build configurations of a configuration list, by name.
    public func buildConfigurations(listID: String?) -> [PBXObject] {
        guard let listID, let list = objects[listID] else { return [] }
        return list.references("buildConfigurations").compactMap { objects[$0] }
    }

    /// Generates a fresh 24-hex-digit object identifier not already in use.
    public func makeObjectID<G: RandomNumberGenerator>(using rng: inout G) -> String {
        while true {
            var s = ""
            for _ in 0..<12 { s += String(format: "%02X", UInt8.random(in: 0...255, using: &rng)) }
            if objects[s] == nil { return s }
        }
    }

    public func makeObjectID() -> String {
        var g = SystemRandomNumberGenerator()
        return makeObjectID(using: &g)
    }
}
