import Crypto
import Foundation
import Testing
@testable import YcodeIDECore

/// B2-DOWNLOAD (#55, `specs/simulator/runtime-downloads.md`): the index and
/// the selection rule, the asset query's body (no Mac model fields on
/// Linux), the signed answer's chain, key scrubbing, the resumable download
/// and its checks, the archive reader (asset parts, pbzx, SHA-256), the
/// decryptor's key handling, route C's command and progress, and the
/// installer. Every fixture is made up here: no Apple index, key, hash list
/// or runtime is in the repository, and nothing is fetched from Apple.
@Suite struct RuntimeDownloadTests {
    // MARK: Fixtures

    static func temp() -> String {
        let p = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-dl-tests-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    static func entry(_ platform: String, _ version: String, _ build: String, beta: Int = 0, archs: [String]? = ["arm64"],
                      method: String? = "mobileAsset", size: Int = 3_700_000_000, host: [String: Any]? = nil) -> [String: Any] {
        var d: [String: Any] = ["category": "simulator", "platform": "com.apple.platform.\(platform)", "identifier": UUID().uuidString,
                                "name": "Made-up \(version)", "version": "\(version).0.\(beta)", "contentType": "cryptexDiskImage",
                                "simulatorVersion": ["version": version, "buildUpdate": build], "fileSize": size]
        if let archs { d["architectures"] = archs }
        if let method { d["downloadMethod"] = method } else { d["source"] = "https://example.invalid/x.dmg"; d["authentication"] = "virtual" }
        if let host { d["hostRequirements"] = host }
        return d
    }

    /// A small made-up index.
    static let indexData: Data = {
        let d: [String: Any] = [
            "version": "1", "refreshInterval": 86400,
            "downloadables": [
                entry("appletvos", "40.0", "90J100"),
                entry("appletvos", "40.1", "90J200", beta: 2),
                entry("appletvos", "40.1", "90J210"),
                entry("appletvos", "40.1", "90J209"),
                entry("appletvos", "40.1", "90J210", archs: ["arm64", "x86_64"]),
                entry("appletvos", "40.2", "90J300", archs: nil),
                entry("appletvos", "40.3", "90J400", host: ["minXcodeVersion": "99.0"]),
                entry("appletvos", "39.0", "89J1", method: nil),
                entry("watchos", "40.0", "90R100", size: 3_800_000_000),
            ],
            "sdkToSimulatorMappings": [
                ["sdkIdentifier": "appletvos40.0", "sdkBuildUpdate": "90J50", "simulatorBuildUpdate": "90J200", "affinity": "available"],
                ["sdkIdentifier": "appletvos40.0", "sdkBuildUpdate": "90J50", "simulatorBuildUpdate": "90J100", "affinity": "preferred"],
                ["sdkIdentifier": "appletvos40.0", "sdkBuildUpdate": "90J60", "simulatorBuildUpdate": "90J209", "affinity": "unavailable"],
                ["sdkIdentifier": "appletvos40.0", "sdkBuildUpdate": "90J60", "simulatorBuildUpdate": "90J200"],
            ],
            "otherDownloadables": [
                ["assetType": "metalToolchain", "identifier": "made.up.toolchain", "name": "Toolchain A", "assetBuildUpdate": "70A1",
                 "contentType": "cryptexDiskImage", "downloadMethod": "mobileAsset", "fileSizeBytes": 800],
                ["assetType": "metalToolchain", "identifier": "made.up.toolchain2", "name": "Toolchain B", "assetBuildUpdate": "70B1",
                 "contentType": "cryptexDiskImage", "downloadMethod": "mobileAsset", "fileSizeBytes": 900],
            ],
            "xcodeToOtherDownloadablesMappings": [["assetType": "metalToolchain", "assetBuildUpdate": "70A1", "xcodeBuildUpdate": "60X1"]],
        ]
        return try! PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0)
    }()

    static let linux = RuntimeHostDescription(isMac: false, productName: "Linux", productVersion: "7.0.0-1-generic", buildVersion: "ubuntu 26.04",
                                              architecture: "x86_64", macModel: nil, client: "Ycode/9.9.9")
    static let mac = RuntimeHostDescription(isMac: true, productName: "macOS", productVersion: "40.0", buildVersion: "50A1",
                                            architecture: "arm64", macModel: "Mac99,1", client: "Ycode/9.9.9")

    // MARK: Index and selection (§2, §3)

    @Test func indexParses() throws {
        let i = try RuntimeIndex.parse(Self.indexData)
        #expect(i.runtimes.count == 9)
        #expect(i.runtimes.first?.platform == .tvOS)
        #expect(i.runtimes.contains { $0.needsSignIn && $0.build == "89J1" })
        #expect(i.metalToolchain(xcodeBuild: "60X1")?.build == "70A1")
        #expect(i.metalToolchain(build: "70B1")?.mobileAssetType == "com.apple.MobileAsset.MetalToolchain")
        #expect(throws: RuntimeDownloadError.self) { try RuntimeIndex.parse(Data("[1,2]".utf8)) }
    }

    @Test func selectionFollowsTheRule() throws {
        let i = try RuntimeIndex.parse(Self.indexData)
        let host = RuntimeSelectionHost(xcodeVersion: "50.0", macOSVersion: nil, architecture: "x86_64")
        // No build, version or SDK: the highest release, ties to the highest build; arm64-only.
        #expect(try RuntimeSelection.select(i, RuntimeRequest(platform: .tvOS), host: host).build == "90J210")
        #expect(try RuntimeSelection.select(i, RuntimeRequest(platform: .tvOS), host: host).architectures == ["arm64"])
        // A build; a version (release before beta).
        #expect(try RuntimeSelection.select(i, RuntimeRequest(platform: .tvOS, build: "90J200"), host: host).betaNumber == 2)
        #expect(try RuntimeSelection.select(i, RuntimeRequest(platform: .tvOS, version: "40.1"), host: host).build == "90J210")
        // An SDK: preferred, then available; never unavailable.
        #expect(try RuntimeSelection.select(i, RuntimeRequest(platform: .tvOS, sdkBuild: "90J50"), host: host).build == "90J100")
        #expect(try RuntimeSelection.select(i, RuntimeRequest(platform: .tvOS, sdkBuild: "90J60"), host: host).build == "90J200")
        // Entries without architectures and ones the Xcode version excludes are not offered.
        let builds = RuntimeSelection.candidates(i, platform: .tvOS, host: host).map(\.build)
        #expect(!builds.contains("90J300") && !builds.contains("90J400") && !builds.contains("89J1"))
        #expect(builds.first == "90J210")
        // A sign-in-only build is named as such; an unknown one is not offered.
        #expect(throws: RuntimeDownloadError.needsSignIn("tvOS 89J1")) { try RuntimeSelection.select(i, RuntimeRequest(platform: .tvOS, build: "89J1"), host: host) }
        #expect(throws: RuntimeDownloadError.self) { try RuntimeSelection.select(i, RuntimeRequest(platform: .visionOS), host: host) }
        // With a newer Xcode, the entry that needs it is offered.
        #expect(RuntimeSelection.candidates(i, platform: .tvOS, host: RuntimeSelectionHost(xcodeVersion: "99.1")).first?.build == "90J400")
    }

    @Test func indexCacheUsesTheETag() async throws {
        let folder = Self.temp()
        let t = StubTransport()
        t.index = Self.indexData
        t.etag = "\"abc\""
        let cache = RuntimeIndexCache(folder: folder)
        _ = try await cache.load(transport: t, now: Date(timeIntervalSince1970: 1000))
        // Fresh: no request. Stale: a conditional GET; 304 keeps the copy.
        _ = try await cache.load(transport: t, now: Date(timeIntervalSince1970: 2000))
        #expect(t.gets.count == 1)
        t.notModified = true
        let i = try await cache.load(transport: t, now: Date(timeIntervalSince1970: 1000 + 86400 * 2))
        #expect(t.gets.count == 2 && t.gets.last?.etag == "\"abc\"")
        #expect(i.runtimes.count == 9)
    }

    // MARK: The query (§4.1, owner decision O1)

    @Test func linuxQueryHasNoMacModelFields() throws {
        let body = RuntimeAssetQuery.body(assetType: SimPlatform.tvOS.assetType, build: "90J210", host: Self.linux)
        let d = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(d["AssetType"] as? String == "com.apple.MobileAsset.appleTVOSSimulatorRuntime")
        #expect(d["AssetAudience"] as? String == RuntimeAssetQuery.audience)
        #expect(d["RequestedBuild"] as? String == "90J210")
        #expect(d["ProductName"] as? String == "Linux")
        #expect(d["HardwarePlatform"] as? String == "x86_64")
        #expect((d["ClientData"] as? [String: String])?["DeviceAccessClient"] == "Ycode/9.9.9")
        for macOnly in ["ProductType", "HWModelStr", "DeviceClass", "DeviceName", "DeviceOSData"] { #expect(d[macOnly] == nil, "\(macOnly)") }
        let text = String(decoding: body, as: UTF8.self)
        #expect(!text.contains("Mac") && !text.contains("macOS"))
    }

    @Test func macQueryUsesTheMacsOwnValues() throws {
        let d = try #require(try JSONSerialization.jsonObject(with: RuntimeAssetQuery.body(assetType: "t", build: "b", host: Self.mac)) as? [String: Any])
        #expect(d["ProductType"] as? String == "Mac99,1" && d["HWModelStr"] as? String == "Mac99,1" && d["ProductName"] as? String == "macOS")
        #expect(Self.mac.summary.contains("Mac99,1") && !Self.linux.summary.contains("Mac"))
    }

    @Test func linuxDescriptionReadsOSRelease() {
        #expect(RuntimeHostDescription.osRelease("NAME=\"Ubuntu\"\nID=ubuntu\nVERSION_ID=\"26.04\"\n") == "ubuntu 26.04")
        #expect(RuntimeHostDescription.current().client.hasPrefix("Ycode/"))
        #if os(Linux)
        #expect(RuntimeHostDescription.current().macModel == nil)
        #endif
    }

    static let key = RuntimeArchiveKey(bytes: (0..<32).map { UInt8(($0 * 37 + 11) & 0xFF) })

    static func payload(key: RuntimeArchiveKey? = key, hash: [UInt8] = [UInt8](repeating: 7, count: 32), size: Int = 1000) -> Data {
        var a: [String: Any] = ["Build": "90J210", "AssetType": "com.apple.MobileAsset.appleTVOSSimulatorRuntime", "_DownloadSize": size,
                                "_UnarchivedSize": 2000, "_Measurement-SHA256": Data(hash).base64EncodedString(),
                                "__BaseURL": "https://cdn.example.invalid/assets/", "__RelativePath": "x/y.aar", "AssetFormat": "AppleArchive"]
        if let key { a["ArchiveDecryptionKey"] = Data(key.bytes).base64EncodedString() }
        return try! JSONSerialization.data(withJSONObject: ["Assets": [a], "AssetSetId": "x"])
    }

    @Test func assetRecordParses() throws {
        let r = try RuntimeAssetQuery.parse(payload: Self.payload(), assetType: "t", build: "90J210")
        #expect(r.url.absoluteString == "https://cdn.example.invalid/assets/x/y.aar")
        #expect(r.downloadSize == 1000 && r.unarchivedSize == 2000 && r.sha256 == [UInt8](repeating: 7, count: 32))
        #expect(r.key == Self.key)
        #expect(throws: RuntimeDownloadError.self) { try RuntimeAssetQuery.parse(payload: Data("{\"Assets\":[]}".utf8), assetType: "t", build: "b") }
    }

    // MARK: Keys never shown (§6.4)

    @Test func keysAreScrubbed() throws {
        let k = Self.key
        let b64 = Data(k.bytes).base64EncodedString()
        #expect("\(k)" == "<redacted>" && String(reflecting: k) == "<redacted>")
        let r = try RuntimeAssetQuery.parse(payload: Self.payload(), assetType: "t", build: "90J210")
        for text in [String(describing: r), String(reflecting: r), "\(Mirror(reflecting: r).children.map { "\($0.value)" })"] {
            #expect(!text.contains(b64) && !text.contains(k.hexForStandardInput))
        }
        let hex = k.hexForStandardInput
        let url = b64.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let leaked = "error: bad key \(b64) / \(hex) / \(hex.uppercased()) / \(url) and {\"ArchiveDecryptionKey\":\"anything\"}"
        let clean = RuntimeSecrets.scrub(leaked, extra: [k])
        #expect(!clean.contains(b64) && !clean.contains(hex) && !clean.contains(hex.uppercased()) && !clean.contains(url) && !clean.contains("anything"))
        #expect(clean.contains("<redacted>"))
        // A registered key is scrubbed without being named.
        RuntimeSecrets.register(k)
        #expect(!RuntimeSecrets.scrub("x \(b64) y").contains(b64))
        RuntimeSecrets.forget(k)
        #expect(!RuntimeDownloadError.refused("HTTP 403").description.isEmpty)
    }

    // MARK: Download, resume, checks (§4.3)

    static func asset(_ data: [UInt8], hash: [UInt8]? = nil) -> RuntimeAssetRecord {
        RuntimeAssetRecord(assetType: "t", build: "90J210", downloadSize: Int64(data.count), unarchivedSize: nil,
                           sha256: hash ?? Array(SHA256.hash(data: data)), url: URL(string: "https://cdn.example.invalid/a.aar")!, key: nil)
    }

    @Test func downloadResumesAfterADroppedConnection() async throws {
        let data = (0..<300_000).map { UInt8($0 % 251) }
        let t = StubTransport()
        t.payload = data
        t.dropAfter = [100_000, 230_000]
        let file = Self.temp() + "/a.aar"
        let events = EventBox()
        try await RuntimeDownloader(transport: t).fetch(Self.asset(data), to: file, cancel: RuntimeCancellation()) { events.add($0) }
        #expect(t.offsets == [0, 100_000, 230_000])
        #expect(FileManager.default.contents(atPath: file) == Data(data))
        #expect(events.all.contains(.resuming(from: 100_000)) && events.all.contains(.resuming(from: 230_000)))
        #expect(events.all.contains { if case .verifying = $0 { true } else { false } })
    }

    @Test func downloadResumesFromAPartialFileOnDisk() async throws {
        let data = (0..<50_000).map { UInt8($0 % 13) }
        let file = Self.temp() + "/a.aar"
        FileManager.default.createFile(atPath: file, contents: Data(data[0..<20_000]))
        let t = StubTransport()
        t.payload = data
        try await RuntimeDownloader(transport: t).fetch(Self.asset(data), to: file, cancel: RuntimeCancellation()) { _ in }
        #expect(t.offsets == [20_000])
        #expect(FileManager.default.contents(atPath: file) == Data(data))
    }

    @Test func aBadChecksumRemovesTheFile() async throws {
        let data = [UInt8](repeating: 1, count: 4096)
        let t = StubTransport()
        t.payload = data
        let file = Self.temp() + "/a.aar"
        await #expect(throws: RuntimeDownloadError.self) {
            try await RuntimeDownloader(transport: t).fetch(Self.asset(data, hash: [UInt8](repeating: 0, count: 32)), to: file, cancel: RuntimeCancellation()) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: file))
        do {
            try await RuntimeDownloader(transport: t).fetch(Self.asset(data, hash: [UInt8](repeating: 0, count: 32)), to: file, cancel: RuntimeCancellation()) { _ in }
        } catch let e as RuntimeDownloadError {
            if case .verificationFailed = e {} else { Issue.record("expected verificationFailed, got \(e)") }
            #expect(e.isRetryable)
        }
    }

    @Test func aShortServerIsASizeMismatch() async throws {
        let data = [UInt8](repeating: 2, count: 1000)
        let t = StubTransport()
        t.payload = Array(data[0..<600])
        let file = Self.temp() + "/a.aar"
        await #expect(throws: RuntimeDownloadError.sizeMismatch(expected: 1000, actual: 600)) {
            try await RuntimeDownloader(transport: t, attempts: 2).fetch(Self.asset(data), to: file, cancel: RuntimeCancellation()) { _ in }
        }
    }

    @Test func cancelStopsAndKeepsThePartialFile() async throws {
        let data = [UInt8](repeating: 3, count: 10_000)
        let t = StubTransport()
        t.payload = data
        t.dropAfter = [4_000]
        let cancel = RuntimeCancellation()
        t.onDrop = { cancel.cancel() }
        let file = Self.temp() + "/a.aar"
        await #expect(throws: RuntimeDownloadError.cancelled) {
            try await RuntimeDownloader(transport: t).fetch(Self.asset(data), to: file, cancel: cancel) { _ in }
        }
        #expect(RuntimeDownloader.fileSize(file) == 4_000)
    }

    // MARK: The signed answer (§4.1)

    @Test func signedAnswerChecksItsChain() throws {
        let root = P384.Signing.PrivateKey(), mid = P256.Signing.PrivateKey(), leaf = P256.Signing.PrivateKey()
        let rootCert = TestCert.make(subject: "Test Root", issuer: "Test Root", key: root.publicKey.x963Representation, curve: .p384, ca: true) { tbs in
            Array(try! root.signature(for: SHA384.hash(data: tbs)).derRepresentation)
        }
        let midCert = TestCert.make(subject: "Test CA", issuer: "Test Root", key: mid.publicKey.x963Representation, curve: .p256, ca: true, hash384: true) { tbs in
            Array(try! root.signature(for: SHA384.hash(data: tbs)).derRepresentation)
        }
        let leafCert = TestCert.make(subject: "Test Signer", issuer: "Test CA", key: leaf.publicKey.x963Representation, curve: .p256, ca: false) { tbs in
            Array(try! mid.signature(for: SHA256.hash(data: tbs)).derRepresentation)
        }
        func jws(_ payload: String, signer: P256.Signing.PrivateKey = leaf) -> String {
            let h = try! JSONSerialization.data(withJSONObject: ["alg": "ES256", "x5c": [Data(leafCert).base64EncodedString(), Data(midCert).base64EncodedString()]])
            let b64 = { (d: Data) in d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
            let input = b64(h) + "." + b64(Data(payload.utf8))
            let sig = try! signer.signature(for: SHA256.hash(data: Data(input.utf8))).derRepresentation
            return input + "." + b64(sig)
        }
        let doc = try RuntimeSignedDocument(jws("{\"Assets\":[]}"))
        #expect(try doc.verify(root: rootCert) == "Test Signer")
        #expect(String(decoding: doc.payload, as: UTF8.self) == "{\"Assets\":[]}")
        // Another signer, another root, a changed payload: refused.
        #expect(throws: RuntimeDownloadError.self) { try RuntimeSignedDocument(jws("{}", signer: P256.Signing.PrivateKey())).verify(root: rootCert) }
        let otherRoot = P384.Signing.PrivateKey()
        let otherCert = TestCert.make(subject: "Test Root", issuer: "Test Root", key: otherRoot.publicKey.x963Representation, curve: .p384, ca: true) { tbs in
            Array(try! otherRoot.signature(for: SHA384.hash(data: tbs)).derRepresentation)
        }
        #expect(throws: RuntimeDownloadError.self) { try doc.verify(root: otherCert) }
        var parts = jws("{\"a\":1}").split(separator: ".").map(String.init)
        parts[1] = "eyJhIjoyfQ"
        #expect(throws: RuntimeDownloadError.self) { try RuntimeSignedDocument(parts.joined(separator: ".")).verify(root: rootCert) }
        #expect(throws: RuntimeDownloadError.self) { try RuntimeSignedDocument("not a document") }
    }

    // MARK: The archive reader

    @Test func readerExtractsFilesDirectoriesAndLinks() throws {
        let dest = Self.temp() + "/out"
        var w = AAWriter()
        w.dir("AssetData")
        w.file("AssetData/Restore/a.dmg", Array("disk".utf8), mode: 0o644)
        w.link("AssetData/latest", to: "Restore/a.dmg")
        w.file("Info.plist", Array("<plist/>".utf8), mode: 0o444, extraBlob: [9, 9, 9])
        let r = AppleArchiveReader(destination: dest, read: w.source())
        let s = try r.extract()
        #expect(s.files == 2 && s.directories == 1 && s.links == 1 && s.bytes == 12)
        #expect(FileManager.default.contents(atPath: dest + "/AssetData/Restore/a.dmg") == Data("disk".utf8))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: dest + "/AssetData/latest")) == "Restore/a.dmg")
        #expect(FileManager.default.contents(atPath: dest + "/Info.plist") == Data("<plist/>".utf8))
    }

    @Test func readerHandlesAssetPartsAndChecksSHA256() throws {
        let content = Array("the disk image".utf8)
        var files = AAWriter()
        files.file("AssetData/Restore/x.dmg", content, extraBlob: [1, 2, 3, 4])
        var attrs = AAWriter()
        attrs.attributes("AssetData/Restore/x.dmg", mode: 0o444, sha256: Array(SHA256.hash(data: content)))
        var outer = AAWriter()
        outer.part("M", AAWriter.manifest())
        outer.part("E", PBZX.stored(files.bytes, chunk: 7))
        outer.part("O", PBZX.stored(attrs.bytes, chunk: 1 << 20))
        let dest = Self.temp() + "/out"
        let s = try AppleArchiveReader(destination: dest, read: outer.source()).extract()
        #expect(s.files == 1 && s.verified == 1)
        #expect(FileManager.default.contents(atPath: dest + "/AssetData/Restore/x.dmg") == Data(content))
        // A hash that does not match is refused.
        var bad = AAWriter()
        bad.attributes("AssetData/Restore/x.dmg", mode: 0o444, sha256: [UInt8](repeating: 0, count: 32))
        var outer2 = AAWriter()
        outer2.part("E", PBZX.stored(files.bytes, chunk: 4096))
        outer2.part("O", PBZX.stored(bad.bytes, chunk: 4096))
        #expect(throws: RuntimeDownloadError.self) { try AppleArchiveReader(destination: Self.temp(), read: outer2.source()).extract() }
    }

    @Test func readerDecodesXZChunks() throws {
        guard let encoded = XZTestEncoder.encode(Array(repeating: Array("abcdefgh".utf8), count: 4000).flatMap { $0 }) else { return }
        var files = AAWriter()
        let content = Array(repeating: Array("abcdefgh".utf8), count: 4000).flatMap { $0 }
        files.file("big.bin", content)
        let packed = files.bytes
        // One XZ chunk holding the whole inner archive.
        guard let xz = XZTestEncoder.encode(packed) else { return }
        #expect(encoded.count < content.count)
        var pb = Array("pbzx".utf8) + PBZX.be(1 << 22)
        pb += PBZX.be(UInt64(packed.count)) + PBZX.be(UInt64(xz.count)) + xz
        var outer = AAWriter()
        outer.part("E", pb)
        let dest = Self.temp()
        _ = try AppleArchiveReader(destination: dest, read: outer.source()).extract()
        #expect(FileManager.default.contents(atPath: dest + "/big.bin") == Data(content))
    }

    @Test func readerRefusesPathsOutsideTheDestination() throws {
        for path in ["../escape", "/etc/escape", "a/../../escape"] {
            var w = AAWriter()
            w.file(path, [1])
            #expect(throws: RuntimeDownloadError.self, "\(path)") { try AppleArchiveReader(destination: Self.temp(), read: w.source()).extract() }
        }
        // Through a link the archive made.
        let outside = Self.temp()
        var w = AAWriter()
        w.link("hop", to: outside)
        w.file("hop/planted", [1])
        #expect(throws: RuntimeDownloadError.self) { try AppleArchiveReader(destination: Self.temp(), read: w.source()).extract() }
        #expect(!FileManager.default.fileExists(atPath: outside + "/planted"))
        var cut = AAWriter()
        cut.file("x", [1, 2, 3])
        let truncated = Array(cut.bytes.dropLast(2))
        var at = 0
        #expect(throws: RuntimeDownloadError.self) {
            try AppleArchiveReader(destination: Self.temp()) { n in
                let k = min(n, truncated.count - at); defer { at += k }; return Array(truncated[at..<at + k])
            }.extract()
        }
    }

    // MARK: The decryptor (owner decision O2)

    @Test func decryptorGetsTheKeyOnStandardInputOnly() async throws {
        let dir = Self.temp()
        var w = AAWriter()
        w.file("Info.plist", Array("hello".utf8))
        let plain = dir + "/plain.aa"
        FileManager.default.createFile(atPath: plain, contents: Data(w.bytes))
        // A stand-in for the environment's python: records its arguments and
        // what arrived on standard input, then writes the plain archive.
        let python = dir + "/python3"
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > \(dir)/argv
        env > \(dir)/env
        read key
        printf '%s' "$key" > \(dir)/stdin
        cat \(plain)
        """.write(toFile: python, atomically: true, encoding: .utf8)
        chmod(python, 0o755)
        let archive = dir + "/a.aar"
        FileManager.default.createFile(atPath: archive, contents: Data([0x41, 0x45, 0x41, 0x31]))
        let stats = try await PythonAEAExpander(python: python).expand(archive, key: Self.key, into: dir + "/out", cancel: RuntimeCancellation()) { _ in }
        #expect(stats.files == 1)
        #expect(FileManager.default.contents(atPath: dir + "/out/Info.plist") == Data("hello".utf8))
        let hex = Self.key.hexForStandardInput, b64 = Data(Self.key.bytes).base64EncodedString()
        #expect((try? String(contentsOfFile: dir + "/stdin", encoding: .utf8)) == hex)
        let argv = try String(contentsOfFile: dir + "/argv", encoding: .utf8), env = try String(contentsOfFile: dir + "/env", encoding: .utf8)
        #expect(!argv.contains(hex) && !argv.contains(b64) && !env.contains(hex) && !env.contains(b64))
        #expect(argv.contains("-I") && argv.contains(archive) && argv.contains("aea.decode_stream"))
    }

    @Test func decryptorErrorsAreScrubbed() async throws {
        let dir = Self.temp()
        let python = dir + "/python3"
        let b64 = Data(Self.key.bytes).base64EncodedString()
        try "#!/bin/sh\nread key\necho \"ValueError: bad key $key \(b64)\" >&2\nexit 2\n".write(toFile: python, atomically: true, encoding: .utf8)
        chmod(python, 0o755)
        FileManager.default.createFile(atPath: dir + "/a.aar", contents: Data([1]))
        do {
            try await PythonAEAExpander(python: python).expand(dir + "/a.aar", key: Self.key, into: dir + "/out", cancel: RuntimeCancellation()) { _ in }
            Issue.record("expected an error")
        } catch {
            let text = String(describing: error)
            #expect(text.contains("ValueError") && text.contains("<redacted>"))
            #expect(!text.contains(Self.key.hexForStandardInput) && !text.contains(b64))
        }
        #expect(PythonAEAExpander.installCommand(folder: "/data/rt").contains("python-aea==1.1.0"))
        #expect(PythonAEAExpander.environmentFolder("/data/rt") == "/data/rt/.tools/python-aea")
    }

    /// With a real python-aea (`YCODE_TEST_AEA_PYTHON`, or Ycode's own
    /// environment under `$YCODE_DATA`), a round trip: python-aea encrypts a
    /// made-up archive with a made-up key; Ycode's expanders decrypt it.
    @Test func realDecryptorRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let python = env["YCODE_TEST_AEA_PYTHON"], FileManager.default.isExecutableFile(atPath: python) else { return }
        let dir = Self.temp()
        var inner = AAWriter()
        inner.file("AssetData/Restore/r.dmg", Array(repeating: 0x5A, count: 3 << 20))
        var outer = AAWriter()
        outer.part("E", PBZX.stored(inner.bytes, chunk: 1 << 20))
        FileManager.default.createFile(atPath: dir + "/plain.aa", contents: Data(outer.bytes))
        let encrypt = SetupProcess([python, "-I", "-c", """
        import sys, aea
        key = bytes.fromhex(sys.stdin.readline().strip())
        open(sys.argv[2], "wb").write(aea.encode(open(sys.argv[1], "rb").read(), symmetric_key=key, compression_algorithm=aea.CompressionAlgorithm.LZFSE))
        """, dir + "/plain.aa", dir + "/a.aar"], stdin: Self.key.hexForStandardInput + "\n")
        guard await encrypt.run() == 0 else { Issue.record("python-aea could not encrypt: \(encrypt.text)"); return }
        let s = try await PythonAEAExpander(python: python).expand(dir + "/a.aar", key: Self.key, into: dir + "/py", cancel: RuntimeCancellation()) { _ in }
        #expect(s.files == 1 && s.bytes == 3 << 20)
        #if canImport(AppleArchive)
        let s2 = try await SystemAppleArchiveExpander().expand(dir + "/a.aar", key: Self.key, into: dir + "/sys", cancel: RuntimeCancellation()) { _ in }
        #expect(s2 == s)
        #endif
        await #expect(throws: RuntimeDownloadError.self) {
            try await PythonAEAExpander(python: python).expand(dir + "/a.aar", key: RuntimeArchiveKey(bytes: [UInt8](repeating: 1, count: 32)),
                                                              into: dir + "/wrong", cancel: RuntimeCancellation()) { _ in }
        }
    }

    // MARK: Route C

    @Test func xcodebuildCommandAndProgress() {
        #expect(XcodebuildDownload(platform: .visionOS).shownCommand == "xcodebuild -downloadPlatform visionOS")
        #expect(XcodebuildDownload(platform: .iOS, exportPath: "/tmp/My Runtimes").shownCommand == "xcodebuild -downloadPlatform iOS -exportPath '/tmp/My Runtimes'")
        let p = XcodebuildProgress.parse("Downloading iOS 40.0 Simulator (90A1): 12.5% (1.0 GB of 8.0 GB)\r")
        #expect(p?.fraction == 0.125 && p?.done == 1 << 30 && p?.total == 8 << 30 && p?.stage == "Downloading")
        #expect(XcodebuildProgress.parse("Installing… 512 MB / 2 GB")?.fraction == 0.25)
        #expect(XcodebuildProgress.parse("Downloading 80 %\n")?.fraction == 0.8)
        #expect(XcodebuildProgress.parse("note: nothing to see") == nil)
    }

    static func standIn(_ body: String) throws -> String {
        let path = temp() + "/xcodebuild"
        try ("#!/bin/sh\n" + body).write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
        return path
    }

    @Test func xcodebuildRunsFinishesFailsAndCancels() async throws {
        let ok = try Self.standIn("echo \"args: $*\"\nfor p in 10 50 100; do printf 'Downloading tvOS 40.0 Simulator: %s%%\\r' $p; done\necho\necho Done\nexit 0\n")
        let progress = EventBox2()
        let out = LockedText()
        let r = await XcodebuildDownloadRun(XcodebuildDownload(platform: .tvOS, exportPath: "/tmp/x"), tool: ok)
            .run(output: { out.append($0) }, progress: { progress.add($0.fraction ?? -1) })
        #expect(r == .finished)
        #expect(out.text.contains("args: -downloadPlatform tvOS -exportPath /tmp/x"))
        #expect(progress.all.contains(1.0))
        let bad = try Self.standIn("echo 'Could not find platform: tvOS' >&2\nexit 70\n")
        let f = await XcodebuildDownloadRun(XcodebuildDownload(platform: .tvOS), tool: bad).run(output: { _ in }, progress: { _ in })
        #expect(f == .failed(70, "Could not find platform: tvOS"))
        let slow = try Self.standIn("trap 'echo interrupted; exit 130' INT\ni=0\nwhile [ $i -lt 100 ]; do echo \"Downloading: $i%\"; sleep 0.2; i=$((i+1)); done\n")
        let run = XcodebuildDownloadRun(XcodebuildDownload(platform: .tvOS), tool: slow)
        Task { try? await Task.sleep(nanoseconds: 600_000_000); run.cancel() }
        #expect(await run.run(output: { _ in }, progress: { _ in }) == .cancelled)
    }

    // MARK: Install (§6.2 steps 3–7)

    /// A made-up exported bundle and the volume its disk image would hold.
    static func fakeBundle(_ dir: String, build: String = "90J210") throws -> (bundle: String, volume: String) {
        let fm = FileManager.default
        let bundle = dir + "/appletvsimulator_40.1_\(build).exportedBundle"
        try fm.createDirectory(atPath: bundle + "/Restore", withIntermediateDirectories: true)
        try Data("udif".utf8).write(to: URL(fileURLWithPath: bundle + "/Restore/000-00000-000.dmg"))
        try PropertyListSerialization.data(fromPropertyList: ["ProductBuildVersion": build, "ProductVersion": "40.1"], format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: bundle + "/Restore/Restore.plist"))
        try PropertyListSerialization.data(fromPropertyList: ["MobileAssetProperties": ["Build": build, "SimulatorVersion": "40.1", "Architectures": ["arm64"]]],
                                           format: .xml, options: 0).write(to: URL(fileURLWithPath: bundle + "/ExportedMetadata.plist"))
        let volume = dir + "/volume"
        let sim = volume + "/Library/Developer/CoreSimulator/Profiles/Runtimes/tvOS 40.1.simruntime"
        let root = sim + "/Contents/Resources/RuntimeRoot"
        try fm.createDirectory(atPath: root + "/System/Library/CoreServices", withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["ProductName": "Apple TVOS", "ProductVersion": "40.1", "ProductBuildVersion": build], format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: root + "/System/Library/CoreServices/SystemVersion.plist"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.apple.CoreSimulator.SimRuntime.tvOS-40-1"], format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: sim + "/Contents/Info.plist"))
        try PropertyListSerialization.data(fromPropertyList: ["platformIdentifier": "com.apple.platform.appletvsimulator", "supportedArchs": ["arm64"]], format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: sim + "/Contents/Resources/profile.plist"))
        try fm.createDirectory(atPath: root + "/usr/lib", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: root + "/usr/lib/libz.dylib", withDestinationPath: "libz.1.dylib")
        try Data(repeating: 1, count: 1000).write(to: URL(fileURLWithPath: root + "/usr/lib/libz.1.dylib"))
        return (bundle, volume)
    }

    @Test func installPutsTheRuntimeRootInYcodesFolder() async throws {
        let dir = Self.temp(), folder = dir + "/runtimes"
        let (bundle, volume) = try Self.fakeBundle(dir)
        let b = try RuntimeInstaller.locateBundle(dir)
        #expect(b.root == bundle && b.build == "90J210" && b.version == "40.1" && b.dmg.hasSuffix(".dmg"))
        let installer = RuntimeInstaller(folder: folder, reader: StandInImageReader(volume: volume))
        let r = try await installer.install(bundle: b, expectBuild: "90J210", marker: { rec in
            var m = RuntimeMarker(rec, source: "test")
            m.route = "download"
            m.sha256 = "ab"
            return m
        }, work: dir + "/work", cancel: RuntimeCancellation(), log: { _ in })
        let place = folder + "/tvOS-40.1-90J210"
        #expect(r.platform == .tvOS && r.build == "90J210" && r.runtimeRoot == place + "/RuntimeRoot")
        #expect(FileManager.default.fileExists(atPath: place + "/profile.plist") && FileManager.default.fileExists(atPath: place + "/runtime-Info.plist"))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: place + "/RuntimeRoot/usr/lib/libz.dylib")) == "libz.1.dylib")
        let marker = try JSONDecoder().decode(RuntimeMarker.self, from: try #require(FileManager.default.contents(atPath: place + "/" + RuntimeFolders.marker)))
        #expect(marker.route == "download" && marker.build == "90J210" && marker.sha256 == "ab")
        // Ycode's list shows it, with the identifier from runtime-Info.plist.
        let list = RuntimeBundleReader.ycodeRuntimes(in: folder)
        #expect(list.count == 1 && list[0].identifier == "com.apple.CoreSimulator.SimRuntime.tvOS-40-1" && list[0].isRemovable)
        // A second install of the same build needs --replace; a different build is refused.
        let (_, volume2) = try Self.fakeBundle(dir + "/again")
        await #expect(throws: RuntimeDownloadError.self) {
            try await RuntimeInstaller(folder: folder, reader: StandInImageReader(volume: volume2)).install(
                bundle: b, expectBuild: "90J210", marker: { RuntimeMarker($0, source: "t") }, work: dir + "/w2", cancel: RuntimeCancellation(), log: { _ in })
        }
        await #expect(throws: RuntimeDownloadError.self) {
            try await installer.install(bundle: b, expectBuild: "90J999", marker: { RuntimeMarker($0, source: "t") }, work: dir + "/w3",
                                        cancel: RuntimeCancellation(), log: { _ in })
        }
        let lines = LockedText()
        #expect(await RuntimeDownloadCLI.main(["list", "--json"], out: { lines.append($0) }, folder: folder) == 0)
        #expect(lines.text.contains("\"build\" : \"90J210\"") && lines.text.contains("\"route\" : \"download\""))
    }

    /// Route B end to end with stand-ins for Apple: index, query, download,
    /// decryption, the disk image; the archives are removed afterwards.
    @Test func routeBEndToEnd() async throws {
        let dir = Self.temp(), folder = dir + "/runtimes"
        let (_, volume) = try Self.fakeBundle(dir + "/src")
        var inner = AAWriter()
        inner.file("AssetData/Restore/000-00000-000.dmg", Array("udif".utf8))
        inner.file("AssetData/Restore/Restore.plist", Array(try PropertyListSerialization.data(
            fromPropertyList: ["ProductBuildVersion": "90J210", "ProductVersion": "40.1"], format: .xml, options: 0)))
        var outer = AAWriter()
        outer.part("E", PBZX.stored(inner.bytes, chunk: 64))
        let archive = Array(repeating: UInt8(0xAE), count: 5000)
        let t = StubTransport()
        t.index = Self.indexData
        t.payload = archive
        let d = RuntimeDirectDownload(folder: folder, transport: t, expander: StandInExpander(plain: outer.bytes),
                                      reader: StandInImageReader(volume: volume), host: Self.linux,
                                      selectionHost: RuntimeSelectionHost(xcodeVersion: "50.0", macOSVersion: nil, architecture: "x86_64"))
        let asked = LockedText()
        d.query = { type, build in
            asked.append("\(type) \(build)")
            var r = Self.asset(archive)
            r.build = build
            r.key = Self.key
            return r
        }
        let phases = PhaseBox()
        let record = try #require(try await d.run(.runtime(RuntimeRequest(platform: .tvOS)), event: { phases.add($0) }))
        #expect(asked.text == "com.apple.MobileAsset.appleTVOSSimulatorRuntime 90J210")
        #expect(record.title == "tvOS 40.1 (90J210)")
        #expect(phases.titles.contains { $0.hasPrefix("Downloading") } && phases.titles.contains { $0.hasPrefix("Decrypting") })
        #expect(phases.titles.last == "tvOS 40.1 (90J210) is ready.")
        // The archive and the unpacked tree are gone; the runtime is listed.
        let left = (try? FileManager.default.contentsOfDirectory(atPath: folder + "/.partial")) ?? []
        #expect(left.isEmpty, "\(left)")
        #expect(RuntimeBundleReader.ycodeRuntimes(in: folder).map(\.build) == ["90J210"])
        let marker = String(decoding: FileManager.default.contents(atPath: folder + "/tvOS-40.1-90J210/" + RuntimeFolders.marker) ?? Data(), as: UTF8.self)
        #expect(marker.contains("\"route\":\"download\"") && marker.contains("cdn.example.invalid") && !marker.contains(Data(Self.key.bytes).base64EncodedString()))
    }

    #if os(macOS)
    /// macOS's reader with a real (small) APFS disk image made here: attached
    /// read-only, the RuntimeRoot copied with its links, detached again.
    @Test func hdiutilReadsAnAPFSImage() async throws {
        let dir = Self.temp()
        let (_, volume) = try Self.fakeBundle(dir)
        let dmg = dir + "/made-up.dmg"
        let make = SetupProcess(["/usr/bin/hdiutil", "create", "-quiet", "-fs", "APFS", "-volname", "MadeUp", "-srcfolder", volume, "-format", "ULFO", dmg])
        guard await make.run() == 0 else { Issue.record("hdiutil create: \(make.text)"); return }
        let folder = dir + "/runtimes"
        let b = RuntimeInstaller.Bundle(root: dir, dmg: dmg, build: "90J210", version: "40.1")
        let r = try await RuntimeInstaller(folder: folder, reader: HdiutilImageReader()).install(
            bundle: b, expectBuild: "90J210", marker: { RuntimeMarker($0, source: "t") }, work: dir + "/work", cancel: RuntimeCancellation(), log: { _ in })
        #expect(r.build == "90J210")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: folder + "/tvOS-40.1-90J210/RuntimeRoot/usr/lib/libz.dylib")) == "libz.1.dylib")
        #expect(FileManager.default.contents(atPath: folder + "/tvOS-40.1-90J210/RuntimeRoot/usr/lib/libz.1.dylib")?.count == 1000)
        // Detached: the mount point is empty again.
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir + "/work/mount")) ?? []).isEmpty)
    }
    #endif

    @Test func refusedQueryOffersOtherRoutes() {
        let e = RuntimeDownloadError.refused("HTTP 403")
        #expect(!e.isRetryable && e.description.contains("xcodebuild -downloadPlatform") && e.description.contains("-exportPath"))
    }

    @Test func folderFollowsYcodeData() {
        #expect(RuntimeFolders.local(environment: ["YCODE_DATA": "/data/ycode/"], home: "/home/u") == "/data/ycode/runtimes")
        #expect(RuntimeFolders.local(environment: ["YCODE_RUNTIMES_DIR": "/r", "YCODE_DATA": "/d"], home: "/home/u") == "/r")
    }
}

// MARK: - Stand-ins

final class StubTransport: RuntimeTransport, @unchecked Sendable {
    let lock = NSLock()
    var index = Data()
    var etag: String?
    var notModified = false
    var payload: [UInt8] = []
    /// Byte counts after which a connection drops (one per call).
    var dropAfter: [Int] = []
    var onDrop: (() -> Void)?
    var gets: [(url: URL, etag: String?)] = []
    var offsets: [Int64] = []

    func get(_ url: URL, etag: String?) async throws -> RuntimeHTTPResponse {
        lock.withLock { gets.append((url, etag)) }
        if notModified, etag != nil { return RuntimeHTTPResponse(status: 304, body: Data(), etag: etag) }
        return RuntimeHTTPResponse(status: 200, body: index, etag: self.etag)
    }

    func post(_ url: URL, json: Data, headers: [String: String], caFile: String?) async throws -> RuntimeHTTPResponse {
        RuntimeHTTPResponse(status: 403, body: Data("refused".utf8))
    }

    func download(_ url: URL, to file: String, from offset: Int64, cancel: RuntimeCancellation) async throws {
        let stop: Int? = lock.withLock {
            offsets.append(offset)
            return dropAfter.isEmpty ? nil : dropAfter.removeFirst()
        }
        let end = min(stop ?? payload.count, payload.count)
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: file))
        try h.seekToEnd()
        if Int(offset) < end { try h.write(contentsOf: payload[Int(offset)..<end]) }
        try h.close()
        if stop != nil {
            onDrop?()
            try cancel.check()
            throw RuntimeDownloadError.network("dropped")
        }
    }
}

struct StandInImageReader: RuntimeImageReader {
    var volume: String
    var title: String { "stand-in" }
    func withVolume<T: Sendable>(_ dmg: String, work: String, cancel: RuntimeCancellation, log: @escaping @Sendable (String) -> Void,
                                 _ body: @Sendable (String) async throws -> T) async throws -> T {
        // A copy, as 7-Zip's extraction would make.
        let copy = work + "/volume"
        try? FileManager.default.removeItem(atPath: copy)
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: volume, toPath: copy)
        return try await body(copy)
    }
}

struct StandInExpander: RuntimeArchiveExpander {
    var plain: [UInt8]
    var title: String { "stand-in" }
    func expand(_ archive: String, key: RuntimeArchiveKey?, into folder: String, cancel: RuntimeCancellation,
                progress: @escaping @Sendable (Int64) -> Void) async throws -> AppleArchiveReader.Stats {
        guard key != nil else { throw RuntimeDownloadError.decryptor("no key") }
        var at = 0
        let bytes = plain
        let r = AppleArchiveReader(destination: folder) { n in
            let k = min(n, bytes.count - at)
            defer { at += k }
            return Array(bytes[at..<at + k])
        }
        r.progress = progress
        return try r.extract()
    }
}

final class EventBox: @unchecked Sendable {
    let lock = NSLock()
    var all: [RuntimeDownloader.Event] = []
    func add(_ e: RuntimeDownloader.Event) { lock.withLock { all.append(e) } }
}

final class EventBox2: @unchecked Sendable {
    let lock = NSLock()
    var all: [Double] = []
    func add(_ e: Double) { lock.withLock { all.append(e) } }
}

final class PhaseBox: @unchecked Sendable {
    let lock = NSLock()
    var titles: [String] = []
    func add(_ p: RuntimeDownloadPhase) { lock.withLock { titles.append(p.title) } }
}

/// Writes Apple Archive entries (the fields the reader knows).
struct AAWriter {
    var bytes: [UInt8] = []

    static func le(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }

    mutating func entry(_ fields: [UInt8], blobs: [[UInt8]] = []) {
        let size = 6 + fields.count
        bytes += Array("AA01".utf8) + Self.le(UInt64(size), 2) + fields
        for b in blobs { bytes += b }
    }

    static func typ(_ c: Character) -> [UInt8] { Array("TYP1".utf8) + [c.asciiValue!] }
    static func pat(_ s: String, key: String = "PAT") -> [UInt8] { Array("\(key)P".utf8) + le(UInt64(s.utf8.count), 2) + Array(s.utf8) }
    static func blob(_ key: String, _ n: Int) -> [UInt8] { Array("\(key)B".utf8) + le(UInt64(n), 4) }

    mutating func dir(_ path: String) { entry(Self.typ("D") + Self.pat(path) + Array("MOD2".utf8) + Self.le(0o755, 2)) }

    mutating func file(_ path: String, _ data: [UInt8], mode: UInt16 = 0o644, extraBlob: [UInt8]? = nil) {
        var f = Self.typ("F") + Self.pat(path) + Array("MOD2".utf8) + Self.le(UInt64(mode), 2) + Self.blob("DAT", data.count)
        var blobs = [data]
        if let extraBlob { f += Self.blob("YEC", extraBlob.count); blobs.append(extraBlob) }
        entry(f, blobs: blobs)
    }

    mutating func link(_ path: String, to target: String) { entry(Self.typ("L") + Self.pat(path) + Self.pat(target, key: "LNK")) }

    mutating func attributes(_ path: String, mode: UInt16, sha256: [UInt8]) {
        entry(Self.typ("F") + Self.pat(path) + Array("UID1".utf8) + [0] + Array("MOD2".utf8) + Self.le(UInt64(mode), 2) + Array("SH2H".utf8) + sha256)
    }

    /// A metadata entry whose DAT blob is a part.
    mutating func part(_ op: Character, _ data: [UInt8]) {
        entry(Self.typ("M") + Array("YOP1".utf8) + [op.asciiValue!] + Self.pat("main", key: "LBL") + Self.blob("DAT", data.count), blobs: [data])
    }

    static func manifest() -> [UInt8] {
        var m = AAWriter()
        m.entry(typ("M") + Array("YOP1".utf8) + [UInt8(ascii: "E")] + pat("main", key: "LBL") + Array("SIZ4".utf8) + le(100, 4))
        return m.bytes
    }

    /// A reader's source over the bytes, in small pieces.
    func source() -> (Int) throws -> [UInt8] {
        let all = bytes
        var at = 0
        return { n in
            let k = min(n, 977, all.count - at)
            defer { at += k }
            return Array(all[at..<at + k])
        }
    }
}

enum PBZX {
    static func be(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64(7 - $0))) } }

    /// Stored (uncompressed) chunks.
    static func stored(_ data: [UInt8], chunk: Int) -> [UInt8] {
        var out = Array("pbzx".utf8) + be(UInt64(chunk))
        var i = 0
        while i < data.count {
            let piece = data[i..<min(i + chunk, data.count)]
            out += be(UInt64(piece.count)) + be(UInt64(piece.count)) + piece
            i += piece.count
        }
        return out
    }
}

/// liblzma's encoder, loaded as the reader loads its decoder (tests only).
enum XZTestEncoder {
    typealias Encode = @convention(c) (UInt32, Int32, UnsafeRawPointer?, UnsafePointer<UInt8>, Int, UnsafeMutablePointer<UInt8>, UnsafeMutablePointer<Int>, Int) -> Int32

    static func encode(_ input: [UInt8]) -> [UInt8]? {
        #if os(macOS)
        let name = "liblzma.5.dylib"
        #else
        let name = "liblzma.so.5"
        #endif
        guard let h = dlopen(name, RTLD_NOW), let f = dlsym(h, "lzma_easy_buffer_encode") else { return nil }
        let enc = unsafeBitCast(f, to: Encode.self)
        var out = [UInt8](repeating: 0, count: input.count + 1024)
        var pos = 0
        let cap = out.count
        let r = input.withUnsafeBufferPointer { i in out.withUnsafeMutableBufferPointer { o in enc(6, 1, nil, i.baseAddress!, input.count, o.baseAddress!, &pos, cap) } }
        guard r == 0 else { return nil }
        return Array(out[0..<pos])
    }
}

/// Minimal X.509 certificates for the chain test.
enum TestCert {
    enum Curve { case p256, p384 }

    static func tlv(_ tag: UInt8, _ c: [UInt8]) -> [UInt8] {
        var len: [UInt8]
        if c.count < 0x80 { len = [UInt8(c.count)] } else if c.count < 0x100 { len = [0x81, UInt8(c.count)] } else { len = [0x82, UInt8(c.count >> 8), UInt8(c.count & 0xFF)] }
        return [tag] + len + c
    }
    static func seq(_ items: [[UInt8]]) -> [UInt8] { tlv(0x30, items.flatMap { $0 }) }
    static func oid(_ s: String) -> [UInt8] {
        let p = s.split(separator: ".").map { Int($0)! }
        var out = [UInt8(p[0] * 40 + p[1])]
        for v in p.dropFirst(2) {
            var stack = [UInt8(v & 0x7F)]
            var x = v >> 7
            while x > 0 { stack.insert(UInt8(x & 0x7F) | 0x80, at: 0); x >>= 7 }
            out += stack
        }
        return tlv(0x06, out)
    }
    static func name(_ cn: String) -> [UInt8] { seq([tlv(0x31, seq([oid("2.5.4.3"), tlv(0x0C, Array(cn.utf8))]))]) }

    static func make(subject: String, issuer: String, key: Data, curve: Curve, ca: Bool, hash384: Bool = false, sign: ([UInt8]) -> [UInt8]) -> [UInt8] {
        let sigAlg = seq([oid(hash384 || (curve == .p384 && subject == issuer) ? "1.2.840.10045.4.3.3" : "1.2.840.10045.4.3.2")])
        let spki = seq([seq([oid("1.2.840.10045.2.1"), oid(curve == .p256 ? "1.2.840.10045.3.1.7" : "1.3.132.0.34")]), tlv(0x03, [0] + Array(key))])
        let validity = seq([tlv(0x17, Array("200101000000Z".utf8)), tlv(0x18, Array("20991231000000Z".utf8))])
        let bc = seq([oid("2.5.29.19"), tlv(0x01, [0xFF]), tlv(0x04, seq(ca ? [tlv(0x01, [0xFF])] : []))])
        let tbs = seq([tlv(0xA0, tlv(0x02, [2])), tlv(0x02, [1]), sigAlg, name(issuer), validity, name(subject), spki, tlv(0xA3, seq([bc]))])
        return seq([tbs, sigAlg, tlv(0x03, [0] + sign(tbs))])
    }
}

@MainActor
@Suite struct RuntimeDownloadModelTests {
    @Test func carriageReturnsRewriteTheLine() {
        let m = RuntimeDownloadModel(machine: SetupMachine(isMac: false, architecture: "x86_64"), folder: "/nonexistent", environment: [:])
        m.append("start\nDownloading: 10%\r")
        m.append("Downloading: 50%\r")
        m.append("Downloading: 100%\r\nDone\n")
        #expect(m.log == "start\nDownloading: 100%\nDone\n")
    }

    @Test func routesAndConfirmations() async {
        let m = RuntimeDownloadModel(machine: SetupMachine(isMac: false, architecture: "x86_64"), folder: "/data/rt", environment: [:],
                                     host: RuntimeDownloadTests.linux)
        #expect(m.xcodeAction == nil)
        let c = m.confirmation(for: .installDecryptor)
        #expect(c?.command.contains("python-aea==1.1.0") == true && c?.command.contains("/data/rt/.tools/python-aea") == true)
        let d = m.confirmation(for: .downloadDirect(RuntimeRequest(platform: .watchOS, build: "90R100")))
        #expect(d?.command == "ycode runtime download watchOS --build 90R100")
        #expect(d?.message.contains("Linux 7.0.0-1-generic") == true && d?.message.contains("Mac") == false)
        let x = m.confirmation(for: .downloadWithXcode(XcodebuildDownload(platform: .iOS, exportPath: "/x")))
        #expect(x?.command == "xcodebuild -downloadPlatform iOS -exportPath /x" && x?.confirmTitle == "Download")
        #expect(m.macRouteNote(.tvOS).contains("xcodebuild -downloadPlatform tvOS -exportPath"))
    }
}
