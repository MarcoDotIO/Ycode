// The MobileAsset query (`runtime-downloads.md` §4.1, §4.2): where one
// runtime's bytes are, their size and SHA-256, and the archive's key. Owner
// decision O1: the request describes the machine Ycode really runs on. On a
// Mac those are the Mac's own values; on Linux its real OS, architecture and
// Ycode's client name, and no Mac model fields. Ycode never presents itself
// as a Mac it is not. A refusal is reported, with routes A and C offered.

import Foundation

/// The machine, as the query describes it.
public struct RuntimeHostDescription: Sendable, Equatable {
    public var isMac: Bool
    /// "macOS" or "Linux".
    public var productName: String
    /// macOS version, or the Linux kernel release.
    public var productVersion: String
    /// macOS build, or the distribution and its version ("ubuntu 26.04").
    public var buildVersion: String
    /// `uname -m`.
    public var architecture: String
    /// The Mac's model identifier (`hw.model`); nil on Linux.
    public var macModel: String?
    /// "Ycode/<version>".
    public var client: String

    public init(isMac: Bool, productName: String, productVersion: String, buildVersion: String, architecture: String, macModel: String?, client: String) {
        self.isMac = isMac
        self.productName = productName
        self.productVersion = productVersion
        self.buildVersion = buildVersion
        self.architecture = architecture
        self.macModel = macModel
        self.client = client
    }

    public var userAgent: String { "\(client) (\(productName) \(productVersion); \(architecture))" }

    /// This machine's real values.
    public static func current() -> RuntimeHostDescription {
        let arch = SetupMachine.current.architecture
        let client = "Ycode/\(ProductIdentity.version)"
        #if os(macOS)
        let sv = FileManager.default.contents(atPath: "/System/Library/CoreServices/SystemVersion.plist")
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let version = sv["ProductVersion"] as? String ?? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        return RuntimeHostDescription(isMac: true, productName: "macOS", productVersion: version, buildVersion: sv["ProductBuildVersion"] as? String ?? "",
                                      architecture: arch, macModel: sysctlString("hw.model"), client: client)
        #else
        var u = utsname()
        uname(&u)
        let release = withUnsafePointer(to: &u.release) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
        return RuntimeHostDescription(isMac: false, productName: "Linux", productVersion: release, buildVersion: osRelease(),
                                      architecture: arch, macModel: nil, client: client)
        #endif
    }

    #if os(macOS)
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var b = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &b, &size, nil, 0) == 0 else { return nil }
        return String(cString: b)
    }
    #endif

    /// `ID VERSION_ID` from /etc/os-release ("ubuntu 26.04").
    static func osRelease(_ text: String? = try? String(contentsOfFile: "/etc/os-release", encoding: .utf8)) -> String {
        var f: [String: String] = [:]
        for line in (text ?? "").split(whereSeparator: \.isNewline) {
            let p = line.split(separator: "=", maxSplits: 1)
            if p.count == 2 { f[String(p[0])] = p[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }
        }
        return [f["ID"], f["VERSION_ID"]].compactMap { $0 }.joined(separator: " ")
    }

    /// The host fields of the request: Mac model fields only on a Mac.
    public var requestFields: [String: Any] {
        var d: [String: Any] = ["ProductName": productName, "ProductVersion": productVersion, "BuildVersion": buildVersion,
                                "HardwarePlatform": architecture]
        if isMac, let m = macModel {
            d["ProductType"] = m
            d["HWModelStr"] = m
        }
        return d
    }

    /// What the confirmation shows the user before anything is sent.
    public var summary: String {
        var s = "\(productName) \(productVersion)"
        if !buildVersion.isEmpty { s += " (\(buildVersion))" }
        s += ", \(architecture)"
        if isMac, let m = macModel { s += ", \(m)" }
        return s + ", client \(client)"
    }
}

/// One asset (§4.2).
public struct RuntimeAssetRecord: Sendable, Equatable {
    public var assetType: String
    public var build: String
    public var downloadSize: Int64
    public var unarchivedSize: Int64?
    public var sha256: [UInt8]
    public var url: URL
    public var key: RuntimeArchiveKey?
    public var format: String?
    public var simulatorVersion: String?
    public var architectures: [String]?

    public var sha256Hex: String { RuntimeTrust.hex(sha256) }

    public init(assetType: String, build: String, downloadSize: Int64, unarchivedSize: Int64?, sha256: [UInt8], url: URL, key: RuntimeArchiveKey?,
                format: String? = nil, simulatorVersion: String? = nil, architectures: [String]? = nil) {
        self.assetType = assetType
        self.build = build
        self.downloadSize = downloadSize
        self.unarchivedSize = unarchivedSize
        self.sha256 = sha256
        self.url = url
        self.key = key
        self.format = format
        self.simulatorVersion = simulatorVersion
        self.architectures = architectures
    }
}

public enum RuntimeAssetQuery {
    public static let url = URL(string: "https://gdmf.apple.com/v2/assets")!
    /// The public "macOS Mobile Asset Customer" audience (§4.1).
    public static let audience = "02d8e57e-dd1c-4090-aa50-b4ed2aef0062"

    /// The JSON body for one asset type and build.
    public static func body(assetType: String, build: String, host: RuntimeHostDescription) -> Data {
        var d = host.requestFields
        d["AssetType"] = assetType
        d["AssetAudience"] = audience
        d["RequestedBuild"] = build
        d["ClientVersion"] = 2
        d["ClientData"] = ["AllowXmlFallback": "false", "DeviceAccessClient": host.client]
        return (try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])) ?? Data()
    }

    /// Sends the query (TLS to Apple's root), checks the signed answer
    /// (chain to Apple's G3 root) and returns the asset.
    public static func run(assetType: String, build: String, host: RuntimeHostDescription, transport: any RuntimeTransport,
                           trust: RuntimeTrust, now: Date = Date()) async throws -> RuntimeAssetRecord {
        let ca = try await trust.pemFile(.appleRoot, transport: transport)
        let r = try await transport.post(url, json: body(assetType: assetType, build: build, host: host), headers: [:], caFile: ca)
        guard r.status == 200 else {
            let text = RuntimeSecrets.scrub(String(decoding: r.body.prefix(300), as: UTF8.self)).trimmed
            throw RuntimeDownloadError.refused("HTTP \(r.status)\(text.isEmpty ? "" : " (\(text))")")
        }
        let doc = try RuntimeSignedDocument(String(decoding: r.body, as: UTF8.self))
        try doc.verify(root: try await trust.certificate(.appleRootG3, transport: transport), at: now)
        return try parse(payload: doc.payload, assetType: assetType, build: build)
    }

    /// The asset from the signed document's payload.
    public static func parse(payload: Data, assetType: String, build: String) throws -> RuntimeAssetRecord {
        guard let obj = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw RuntimeDownloadError.untrusted("the answer has no body")
        }
        let assets = obj["Assets"] as? [[String: Any]] ?? []
        guard let a = assets.first(where: { $0["Build"] as? String == build }) ?? (assets.count == 1 ? assets[0] : nil) else {
            throw RuntimeDownloadError.noAsset("build \(build)")
        }
        guard let base = a["__BaseURL"] as? String, let rel = a["__RelativePath"] as? String,
              let url = URL(string: base.hasSuffix("/") || rel.hasPrefix("/") ? base + rel : base + "/" + rel),
              url.scheme == "https",
              let size = RuntimeIndex.int64(a["_DownloadSize"]),
              let hashText = a["_Measurement-SHA256"] as? String, let hash = Data(base64Encoded: hashText), hash.count == 32 else {
            throw RuntimeDownloadError.noAsset("build \(build) (the record lacks a URL, size or SHA-256)")
        }
        var key: RuntimeArchiveKey?
        if let k = a["ArchiveDecryptionKey"] as? String {
            guard let parsed = RuntimeArchiveKey(base64: k) else { throw RuntimeDownloadError.untrusted("the archive key is not base64") }
            key = parsed
            RuntimeSecrets.register(parsed)
        }
        return RuntimeAssetRecord(assetType: a["AssetType"] as? String ?? assetType, build: a["Build"] as? String ?? build, downloadSize: size,
                                  unarchivedSize: RuntimeIndex.int64(a["_UnarchivedSize"]), sha256: Array(hash), url: url, key: key,
                                  format: a["AssetFormat"] as? String, simulatorVersion: a["SimulatorVersion"] as? String,
                                  architectures: a["Architectures"] as? [String])
    }
}
