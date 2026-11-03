import Foundation

/// The code inside a bundle, in the order it must be signed: a signature
/// seals the nested code's signatures, so each nested item is signed before
/// the bundle that contains it (Apple TN2206 "macOS Code Signing In Depth",
/// "Placing content in a bundle"). swift-build already orders the signing
/// tasks of a build this way (frameworks and plug-ins are signed when they
/// are copied, the product last); Ycode uses this order when it re-signs a
/// finished bundle (`-exportArchive`).
public enum NestedCode {
    /// Folders, relative to a bundle's contents folder, that hold code.
    static let codeFolders = [
        "Frameworks", "SharedFrameworks", "PlugIns", "Extensions", "XPCServices", "Library/LoginItems",
        "Library/SystemExtensions", "Library/QuickLook", "Library/Spotlight", "Helpers", "MacOS", "Watch", "AppClips",
    ]
    /// Extensions of nested bundles that carry their own signature.
    static let bundleExtensions: Set<String> = ["app", "appex", "framework", "xpc", "bundle", "systemextension", "qlgenerator", "mdimporter", "plugin"]

    /// Whether a file starts with a Mach-O or universal magic number.
    public static func isMachO(_ path: String) -> Bool {
        guard let h = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? h.close() }
        let d = h.readData(ofLength: 4)
        guard d.count == 4 else { return false }
        let m = d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return [0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE, 0xCAFEBABE, 0xBEBAFECA].contains(m)
    }

    /// The folder that holds a bundle's contents: `Contents` (Mac apps and
    /// plug-ins), `Versions/Current` (Mac frameworks) or the bundle itself
    /// (iOS-style bundles).
    static func contentsFolder(_ bundle: URL) -> URL {
        let fm = FileManager.default
        let contents = bundle.appendingPathComponent("Contents")
        if fm.fileExists(atPath: contents.path) { return contents }
        // The version Current points at, named as such (not resolved to a
        // real path) so the items keep paths inside the bundle.
        let versions = bundle.appendingPathComponent("Versions")
        if let current = try? fm.destinationOfSymbolicLink(atPath: versions.appendingPathComponent("Current").path), !current.hasPrefix("/") {
            return versions.appendingPathComponent(current)
        }
        return bundle
    }

    /// The bundle's main executable name (`CFBundleExecutable`), when it has one.
    static func mainExecutable(_ contents: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: contents.appendingPathComponent("Info.plist").path),
              let info = try? Entitlements.fromPropertyList(data) else { return nil }
        return info["CFBundleExecutable"]?.stringValue
    }

    /// Every item to sign, innermost first, ending with `bundle` itself.
    /// Items at one level come in path order.
    public static func signingOrder(bundle: URL) -> [URL] {
        var out: [URL] = []
        visit(bundle.standardizedFileURL, into: &out)
        return out
    }

    static func visit(_ bundle: URL, into out: inout [URL]) {
        let fm = FileManager.default
        let contents = contentsFolder(bundle)
        // Without an Info.plist the executable is named like the bundle.
        let main = mainExecutable(contents) ?? bundle.deletingPathExtension().lastPathComponent
        for folder in codeFolders {
            let dir = contents.appendingPathComponent(folder)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            for n in names {
                let item = dir.appendingPathComponent(n)
                let ext = item.pathExtension
                var itemIsDir: ObjCBool = false
                _ = fm.fileExists(atPath: item.path, isDirectory: &itemIsDir)
                if itemIsDir.boolValue {
                    if bundleExtensions.contains(ext) { visit(item, into: &out) }
                } else if folder == "MacOS" && n == main {
                    continue // the bundle's own executable is signed with the bundle
                } else if ext == "dylib" || isMachO(item.path) {
                    out.append(item)
                }
            }
        }
        out.append(bundle)
    }
}

/// Command lines for the signing tools.
public enum CodesignCommand {
    public static let codesign = "/usr/bin/codesign"

    /// `codesign` arguments to sign one item. `entitlements` is a file to
    /// sign in; `preserve` keeps the item's identifier, entitlements and
    /// flags (re-signing finished code).
    public static func codesign(item: String, identity: String, entitlements: String? = nil, preserve: Bool = false,
                                options: [String] = [], timestamp: Bool = false) -> [String] {
        var a = ["--force", "--sign", identity]
        if let entitlements { a += ["--entitlements", entitlements] }
        if preserve && entitlements == nil { a.append("--preserve-metadata=identifier,entitlements,flags") }
        if !options.isEmpty { a += ["--options", options.joined(separator: ",")] }
        // Ad hoc signatures never take a time stamp.
        a.append(timestamp && identity != "-" ? "--timestamp" : "--timestamp=none")
        a.append(item)
        return a
    }

    /// `rcodesign` (apple-codesign, MPL-2.0, run as a separate program) on
    /// Linux: an ad hoc signature, with an entitlements file when given.
    /// Signing with an identity needs the certificate and key as files
    /// (`--p12-file`, `--pem-file`), which Ycode does not handle yet.
    public static func rcodesignAdHoc(item: String, entitlements: String? = nil) -> [String] {
        var a = ["sign"]
        if let entitlements { a += ["--entitlements-xml-file", entitlements] }
        a.append(item)
        return a
    }

    /// Re-signs a bundle, nested code first, keeping each item's metadata.
    /// Returns the first failure's message, or nil.
    public static func resign(bundle: URL, identity: String, runner: CommandRunner = .system) -> String? {
        for item in NestedCode.signingOrder(bundle: bundle) {
            let r = runner.run(codesign, codesign(item: item.path, identity: identity, preserve: true))
            if r.status != 0 { return "codesign failed for \(item.path) (exit \(r.status))" }
        }
        return nil
    }
}
