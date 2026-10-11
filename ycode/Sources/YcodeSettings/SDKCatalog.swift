import Foundation

/// The SDKs installed in a developer directory, read from each SDK's
/// `SDKSettings.json`.
public struct SDKCatalog: Sendable {
    public struct SDK: Sendable, Equatable {
        public var canonicalName: String
        public var version: String
        public var path: String
        public var platform: String
    }

    public var sdks: [SDK]

    public init(developerDirectory: String) {
        let fm = FileManager.default
        let platforms = URL(fileURLWithPath: developerDirectory).appendingPathComponent("Platforms")
        var found: [String: SDK] = [:]
        for p in (try? fm.contentsOfDirectory(atPath: platforms.path)) ?? [] where p.hasSuffix(".platform") {
            let dir = platforms.appendingPathComponent(p).appendingPathComponent("Developer/SDKs")
            for s in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where s.hasSuffix(".sdk") {
                let sdkURL = dir.appendingPathComponent(s)
                guard let data = try? Data(contentsOf: sdkURL.appendingPathComponent("SDKSettings.json")),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let name = obj["CanonicalName"] as? String else { continue }
                // Several bundle names (MacOSX.sdk, MacOSX27.0.sdk, MacOSX27.sdk)
                // can alias one SDK. Xcode reports the name that carries the
                // full version, so prefer that name.
                let version = obj["Version"] as? String ?? ""
                if let existing = found[name], existing.path.hasSuffix("\(version).sdk") { continue }
                found[name] = SDK(canonicalName: name, version: version,
                                  path: sdkURL.path, platform: String(p.dropLast(".platform".count)))
            }
        }
        sdks = found.values.sorted { $0.canonicalName < $1.canonicalName }
    }

    /// Resolves an `SDKROOT` value: a canonical name (`macosx27.0`), a base
    /// name (`macosx`, which picks the newest version), or an SDK path.
    public func lookup(_ sdkroot: String) -> SDK? {
        if sdkroot.hasPrefix("/") {
            let real = URL(fileURLWithPath: sdkroot).resolvingSymlinksInPath().path
            return sdks.first { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == real }
        }
        if let exact = sdks.first(where: { $0.canonicalName == sdkroot }) { return exact }
        return sdks.filter { $0.canonicalName.hasPrefix(sdkroot) && $0.canonicalName.dropFirst(sdkroot.count).first?.isNumber == true }
            .max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
    }
}
