import Foundation
import Testing
@testable import YcodeSigning

// Every identity, certificate and profile here is synthetic: made-up
// teams, names and certificate bytes. No real signing material is used.

/// A minimal DER writer for synthetic certificates.
enum DER {
    static func tlv(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
        let n = body.count
        let len: [UInt8] = n < 0x80 ? [UInt8(n)] : n < 0x100 ? [0x81, UInt8(n)] : [0x82, UInt8(n >> 8), UInt8(n & 0xFF)]
        return [tag] + len + body
    }
    static func seq(_ parts: [UInt8]...) -> [UInt8] { tlv(0x30, parts.flatMap { $0 }) }
    static func name(cn: String, ou: String) -> [UInt8] {
        seq(tlv(0x31, seq(tlv(0x06, [0x55, 0x04, 0x0B]), tlv(0x0C, Array(ou.utf8)))),
            tlv(0x31, seq(tlv(0x06, [0x55, 0x04, 0x03]), tlv(0x0C, Array(cn.utf8)))))
    }
    /// A certificate-shaped structure: version, serial, algorithm, issuer,
    /// validity (UTCTime), subject; no key or signature.
    static func certificate(cn: String, ou: String, notAfter: String) -> [UInt8] {
        let tbs = seq(tlv(0xA0, tlv(0x02, [2])), tlv(0x02, [1]), seq(tlv(0x06, [0x2A])),
                      name(cn: "Example CA", ou: "CA"),
                      seq(tlv(0x17, Array("260101000000Z".utf8)), tlv(0x17, Array(notAfter.utf8))),
                      name(cn: cn, ou: ou))
        return seq(tbs, seq(tlv(0x06, [0x2A])), tlv(0x03, [0]))
    }
}

/// Synthetic signing material.
enum Fixture {
    static let devCert = Array("synthetic development certificate".utf8)
    static let otherCert = Array("synthetic certificate of another team".utf8)
    static let devIdentity = SigningIdentity(hash: SHA1.hex(devCert), name: "Apple Development: Test Person (P1)", team: "TEAMAAAAAA",
                                             expires: date("2030-01-01T00:00:00Z"))
    static let otherIdentity = SigningIdentity(hash: SHA1.hex(otherCert), name: "Apple Development: Test Person (P2)", team: "TEAMBBBBBB",
                                               expires: date("2030-01-01T00:00:00Z"))
    static let now = date("2026-10-30T00:00:00Z")

    static func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    static func profile(uuid: String, name: String, team: String = "TEAMAAAAAA", appID: String, platform: String = "iOS",
                        expires: String = "2027-10-30T00:00:00Z", extra: Entitlements = [:], getTaskAllow: Bool = true,
                        certs: [[UInt8]] = [devCert], mac: Bool = false) -> ProvisioningProfile {
        var e: Entitlements = [
            mac ? "com.apple.application-identifier" : "application-identifier": .string(team + "." + appID),
            "com.apple.developer.team-identifier": .string(team),
            "keychain-access-groups": .array([.string(team + ".*")]),
        ]
        if getTaskAllow { e[mac ? "com.apple.security.get-task-allow" : "get-task-allow"] = .bool(true) }
        return ProvisioningProfile(uuid: uuid, name: name, teamIdentifiers: [team], applicationIdentifierPrefixes: [team], platforms: [platform],
                                   creationDate: date("2026-01-01T00:00:00Z"), expirationDate: date(expires),
                                   entitlements: e.overlaid(with: extra), provisionedDevices: ["00000000-0000000000000001"],
                                   certificateHashes: certs.map(SHA1.hex))
    }

    static func environment(identities: [SigningIdentity] = [devIdentity], profiles: [ProvisioningProfile] = []) -> SigningEnvironment {
        SigningEnvironment(identities: { identities }, profiles: { profiles }, now: now)
    }
}

@Suite struct DigestAndCertificateTests {
    @Test func sha1KnownAnswers() {
        #expect(SHA1.hex(Array("abc".utf8)) == "A9993E364706816ABA3E25717850C26C9CD0D89D")
        #expect(SHA1.hex([]) == "DA39A3EE5E6B4B0D3255BFEF95601890AFD80709")
        #expect(SHA1.hex(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)) == "84983E441C3BD26EBAAE4AA1F95129E5E54670F1")
    }

    @Test func certificateSubjectAndExpiry() throws {
        let der = DER.certificate(cn: "Apple Development: Test Person (P1)", ou: "TEAMAAAAAA", notAfter: "300101000000Z")
        let s = try #require(CertificateSummary(der: der))
        #expect(s.commonName == "Apple Development: Test Person (P1)")
        #expect(s.organizationalUnit == "TEAMAAAAAA")
        #expect(s.notAfter == Fixture.date("2030-01-01T00:00:00Z"))
        #expect(CertificateSummary(der: [0x01, 0x02]) == nil)
    }

    @Test func pemBlocksKeepTheirHashes() throws {
        let der = DER.certificate(cn: "x", ou: "y", notAfter: "300101000000Z")
        let text = "SHA-256 hash: 00\nSHA-1 hash: abcdef\n-----BEGIN CERTIFICATE-----\n\(Data(der).base64EncodedString(options: .lineLength64Characters))\n-----END CERTIFICATE-----\n"
        let blocks = CertificateSummary.pemBlocks(text)
        try #require(blocks.count == 1)
        #expect(blocks[0].sha1 == "ABCDEF")
        #expect(blocks[0].der == der)
    }

    @Test func findIdentityListing() {
        let text = """
          1) 1111111111111111111111111111111111111111 "Apple Development: Test Person (P1)"
          2) 2222222222222222222222222222222222222222 "Developer ID Application: Example Org (TEAMBBBBBB)" (CSSMERR_TP_CERT_REVOKED)
          1) 1111111111111111111111111111111111111111 "Apple Development: Test Person (P1)"
             2 valid identities found
        """
        let parsed = Keychain.parseFindIdentity(text)
        #expect(parsed.map(\.name) == ["Apple Development: Test Person (P1)", "Developer ID Application: Example Org (TEAMBBBBBB)"])
    }

    @Test func identitiesComeFromBothCommands() {
        let der = DER.certificate(cn: "Apple Development: Test Person (P1)", ou: "TEAMAAAAAA", notAfter: "300101000000Z")
        let hash = SHA1.hex(der)
        let runner = CommandRunner { _, args in
            if args.first == "find-identity" { return (0, Data("  1) \(hash) \"Apple Development: Test Person (P1)\"\n".utf8)) }
            let pem = "-----BEGIN CERTIFICATE-----\n\(Data(der).base64EncodedString())\n-----END CERTIFICATE-----\n"
            return (0, Data(pem.utf8))
        }
        guard FileManager.default.isExecutableFile(atPath: Keychain.security) else { return }
        let ids = Keychain.identities(runner: runner)
        #expect(ids == [SigningIdentity(hash: hash, name: "Apple Development: Test Person (P1)", team: "TEAMAAAAAA", expires: Fixture.date("2030-01-01T00:00:00Z"))])
    }

    @Test func selectorsMatchKindsNamesAndHashes() {
        let id = Fixture.devIdentity
        #expect(IdentitySelector.matches("Apple Development", id))
        #expect(IdentitySelector.matches("iPhone Developer", id))
        #expect(IdentitySelector.matches("Mac Developer", id))
        #expect(IdentitySelector.matches(id.name, id))
        #expect(IdentitySelector.matches(id.hash.lowercased(), id))
        #expect(!IdentitySelector.matches("Apple Distribution", id))
        #expect(IdentitySelector.candidates("Apple Development", team: "TEAMBBBBBB", in: [Fixture.devIdentity, Fixture.otherIdentity], now: Fixture.now) == [Fixture.otherIdentity])
        let expired = SigningIdentity(hash: String(repeating: "3", count: 40), name: "Apple Development: Old", team: "TEAMAAAAAA", expires: Fixture.date("2020-01-01T00:00:00Z"))
        #expect(IdentitySelector.candidates("Apple Development", team: nil, in: [expired], now: Fixture.now).isEmpty)
    }
}

@Suite struct ProfileTests {
    func plist(_ d: [String: Any]) -> Data { try! PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0) }

    @Test func decodesAProfilePropertyList() throws {
        let data = plist([
            "UUID": "AAAA-1111", "Name": "Synthetic Dev", "TeamIdentifier": ["TEAMAAAAAA"], "TeamName": "Example",
            "ApplicationIdentifierPrefix": ["TEAMAAAAAA"], "Platform": ["iOS", "xrOS"],
            "ExpirationDate": Fixture.date("2027-01-01T00:00:00Z"), "CreationDate": Fixture.date("2026-01-01T00:00:00Z"),
            "ProvisionedDevices": ["00000000-0000000000000001"], "IsXcodeManaged": true,
            "DeveloperCertificates": [Data(Fixture.devCert)],
            "Entitlements": ["application-identifier": "TEAMAAAAAA.com.example.*", "get-task-allow": true,
                             "keychain-access-groups": ["TEAMAAAAAA.*"], "com.apple.security.application-groups": ["group.com.example"]],
        ])
        let p = try ProvisioningProfile(propertyList: data, path: "/x.mobileprovision")
        #expect(p.uuid == "AAAA-1111")
        #expect(p.certificateHashes == [Fixture.devIdentity.hash])
        #expect(p.applicationIdentifierPrefix == "TEAMAAAAAA")
        #expect(p.bundleIdentifierPattern == "com.example.*")
        #expect(p.isWildcard)
        #expect(p.kind == .development)
        #expect(p.covers(bundleIdentifier: "com.example.app"))
        #expect(!p.covers(bundleIdentifier: "org.example.app"))
        #expect(p.entitlements["get-task-allow"] == .bool(true))
        #expect(p.isExpired(at: Fixture.date("2027-06-01T00:00:00Z")))
        #expect(throws: ProvisioningProfile.DecodingError.missingKey("UUID")) { try ProvisioningProfile(propertyList: plist(["Name": "x"])) }
    }

    @Test func kinds() {
        var p = Fixture.profile(uuid: "1", name: "a", appID: "*", getTaskAllow: false)
        #expect(p.kind == .adHoc)
        p.provisionedDevices = []
        #expect(p.kind == .distribution)
        p.provisionsAllDevices = true
        #expect(p.kind == .enterprise)
    }

    @Test func storeReadsPlainProfileFilesFromItsFolders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-profiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try plist(["UUID": "U1", "Name": "One", "Entitlements": [String: Any]()]).write(to: dir.appendingPathComponent("one.mobileprovision"))
        try plist(["UUID": "U2", "Name": "Two"]).write(to: dir.appendingPathComponent("two.provisionprofile"))
        try Data("ignored".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        let dirs = ProfileStore.directories(environment: ["YCODE_PROVISIONING_PROFILES": dir.path])
        #expect(dirs == [dir.path])
        #expect(ProfileStore.load(directories: dirs, runner: CommandRunner { _, _ in (1, Data()) }).map(\.name) == ["One", "Two"])
        #expect(ProfileStore.directories(environment: ["HOME": "/h"]) == ["/h/Library/Developer/Xcode/UserData/Provisioning Profiles",
                                                                         "/h/Library/MobileDevice/Provisioning Profiles"])
    }
}

@Suite struct EntitlementTests {
    @Test func propertyListRoundTripKeepsBooleansAndNumbers() throws {
        let e: Entitlements = ["a": .bool(true), "n": .integer(3), "s": .string("x"), "l": .array([.string("g")]), "d": .dictionary(["k": .bool(false)])]
        let back = try Entitlements.fromPropertyList(try e.xmlPropertyList())
        #expect(back == e)
        #expect(throws: PropertyListError.notADictionary) { try Entitlements.fromPropertyList(Data("<plist><array/></plist>".utf8)) }
    }

    @Test func patterns() {
        #expect(EntitlementPolicy.pattern("TEAM.*", matches: "TEAM.com.example.app"))
        #expect(EntitlementPolicy.pattern("*", matches: "anything"))
        #expect(EntitlementPolicy.pattern("com.example.app", matches: "com.example.app"))
        #expect(!EntitlementPolicy.pattern("com.example.app", matches: "com.example.app2"))
        #expect(EntitlementPolicy.pattern("group.*.shared", matches: "group.x.y.shared"))
        #expect(!EntitlementPolicy.pattern("TEAM.*", matches: "OTHER.app"))
    }

    @Test func profileValuesAllowRequests() {
        #expect(EntitlementPolicy.allows(.bool(true), .bool(false)))
        #expect(!EntitlementPolicy.allows(.bool(false), .bool(true)))
        #expect(EntitlementPolicy.allows(.array([.string("TEAM.*")]), .array([.string("TEAM.a"), .string("TEAM.b")])))
        #expect(!EntitlementPolicy.allows(.array([.string("group.a")]), .array([.string("group.a"), .string("group.b")])))
        #expect(EntitlementPolicy.allows(.string("*"), .array([.string("x")])))
        #expect(EntitlementPolicy.allows(.array([.string("development"), .string("production")]), .string("development")))
    }

    @Test func restrictionByPlatform() {
        #expect(!EntitlementPolicy.isRestricted("com.apple.security.app-sandbox", on: .macOS))
        #expect(EntitlementPolicy.isRestricted("keychain-access-groups", on: .macOS))
        #expect(EntitlementPolicy.isRestricted("com.apple.security.application-groups", on: .device("iphoneos")))
        #expect(!EntitlementPolicy.isRestricted("com.apple.developer.healthkit", on: .simulator("iphonesimulator")))
        let p = Fixture.profile(uuid: "1", name: "Dev", appID: "com.example.app")
        let m = EntitlementPolicy.mismatches(["keychain-access-groups": .array([.string("OTHER.x")]), "com.apple.developer.healthkit": .bool(true),
                                              "application-identifier": .string("ignored")], profile: p, platform: .device("iphoneos"))
        #expect(m == [.missing("com.apple.developer.healthkit"), .value("keychain-access-groups")])
    }

    @Test func platformsFromSDKs() {
        #expect(SigningPlatform(sdk: "macosx27.1", variant: "macos") == .macOS)
        #expect(SigningPlatform(sdk: "macosx27.1", variant: "iosmac") == .macCatalyst)
        #expect(SigningPlatform(sdk: "iphonesimulator27.0", variant: nil) == .simulator("iphonesimulator"))
        #expect(SigningPlatform(sdk: "xros27.0", variant: nil).profilePlatforms == ["xrOS", "visionOS"])
        #expect(SigningPlatform(sdk: "xrsimulator27.0", variant: nil).profilePlatforms == ["xrOS", "visionOS"])
        #expect(SigningPlatform.macOS.applicationIdentifierKey == "com.apple.application-identifier")
        #expect(SigningPlatform.device("iphoneos").getTaskAllowKey == "get-task-allow")
    }
}

@Suite struct ResolverTests {
    let appGroups: Entitlements = ["com.apple.security.app-sandbox": .bool(true), "com.apple.security.application-groups": .array([.string("TEAMAAAAAA.group")])]

    @Test func signToRunLocallyOnTheMacKeepsTheProjectEntitlements() {
        let r = ProvisioningResolver.resolve(SigningRequest(targetName: "App", identity: "-", bundleIdentifier: "com.example.app",
                                                            projectEntitlements: appGroups, sdk: "macosx27.1"), environment: Fixture.environment())
        #expect(r.identityHash == "-")
        #expect(r.identityName == "Sign to Run Locally")
        #expect(r.signedEntitlements == appGroups.overlaid(with: ["com.apple.security.get-task-allow": .bool(true)]))
        #expect(r.simulatedEntitlements == [:])
        #expect(r.errors == [] && r.warnings == [])
    }

    @Test func archivesAndLibrariesGetNoDebuggingEntitlement() {
        let archive = ProvisioningResolver.resolve(SigningRequest(targetName: "App", identity: "-", bundleIdentifier: "com.example.app",
                                                                  projectEntitlements: appGroups, sdk: "macosx27.1", debuggable: false), environment: Fixture.environment())
        #expect(archive.signedEntitlements == appGroups)
        let lib = ProvisioningResolver.resolve(SigningRequest(targetName: "Kit", identity: "-", bundleIdentifier: "com.example.kit",
                                                              projectEntitlements: appGroups, sdk: "macosx27.1", supportsEntitlements: false), environment: Fixture.environment())
        #expect(lib.signedEntitlements == [:])
        #expect(lib.identityHash == "-")
    }

    /// swift-build requires entitlements for UI test bundles although they
    /// are bundles (`supportsEntitlements` false): they are composed as for
    /// an executable. Unit test bundles still get none.
    @Test func uiTestBundlesGetEntitlements() {
        let runner: Entitlements = ["com.apple.security.app-sandbox": .bool(true)]
        let ui = ProvisioningResolver.resolve(SigningRequest(targetName: "AppUITests", identity: "-", bundleIdentifier: "com.example.AppUITests",
                                                             productTypeEntitlements: runner, sdk: "macosx27.1", supportsEntitlements: false,
                                                             productType: "com.apple.product-type.bundle.ui-testing"), environment: Fixture.environment())
        #expect(ui.signedEntitlements == runner.overlaid(with: ["com.apple.security.get-task-allow": .bool(true)]))
        let phone = ProvisioningResolver.resolve(SigningRequest(targetName: "AppUITests", identity: "-", bundleIdentifier: "com.example.AppUITests",
                                                                sdk: "iphonesimulator27.0", supportsEntitlements: false,
                                                                productType: "com.apple.product-type.bundle.ui-testing"), environment: Fixture.environment())
        #expect(phone.signedEntitlements == ["get-task-allow": .bool(true)])
        #expect(phone.simulatedEntitlements["application-identifier"] == .string("com.example.AppUITests"))
        let unit = ProvisioningResolver.resolve(SigningRequest(targetName: "AppTests", identity: "-", bundleIdentifier: "com.example.AppTests",
                                                               productTypeEntitlements: runner, sdk: "macosx27.1", supportsEntitlements: false,
                                                               productType: "com.apple.product-type.bundle.unit-test"), environment: Fixture.environment())
        #expect(unit.signedEntitlements == [:])
    }

    @Test func adHocWarnsAboutEntitlementsThatNeedAProfile() {
        let r = ProvisioningResolver.resolve(SigningRequest(targetName: "App", identity: "-", bundleIdentifier: "com.example.app",
                                                            projectEntitlements: ["keychain-access-groups": .array([.string("x")])], sdk: "macosx27.1"),
                                             environment: Fixture.environment())
        #expect(r.errors == [])
        #expect(r.warnings.count == 1)
        #expect(r.warnings[0].contains("\"keychain-access-groups\" needs a provisioning profile"))
    }

    @Test func simulatorBuildsLinkTheirEntitlementsIntoTheExecutable() {
        let project: Entitlements = ["com.apple.security.application-groups": .array([.string("group.com.example")]),
                                     "keychain-access-groups": .array([.string("TEAMAAAAAA.com.example.shared")])]
        // swift-build sends `-` for every simulator build, whatever CODE_SIGN_IDENTITY says.
        let r = ProvisioningResolver.resolve(SigningRequest(targetName: "App", identity: "-", team: "TEAMAAAAAA", bundleIdentifier: "com.example.app",
                                                            projectEntitlements: project, sdk: "iphonesimulator27.0"),
                                             environment: Fixture.environment(identities: []))
        #expect(r.identityHash == "-")
        #expect(r.signedEntitlements == ["get-task-allow": .bool(true)])
        #expect(r.simulatedEntitlements == [
            "application-identifier": .string("TEAMAAAAAA.com.example.app"),
            "com.apple.developer.team-identifier": .string("TEAMAAAAAA"),
            "com.apple.security.application-groups": .array([.string("group.com.example")]),
            "keychain-access-groups": .array([.string("TEAMAAAAAA.com.example.shared")]),
        ])
        #expect(r.appIdentifierPrefix == "TEAMAAAAAA.")
        // Without a team, the identifiers are the bundle identifier itself.
        let noTeam = ProvisioningResolver.resolve(SigningRequest(targetName: "App", identity: "-", bundleIdentifier: "com.example.app", sdk: "xrsimulator27.0"),
                                                  environment: Fixture.environment())
        #expect(noTeam.simulatedEntitlements == ["application-identifier": .string("com.example.app"),
                                                 "keychain-access-groups": .array([.string("com.example.app")])])
        #expect(noTeam.appIdentifierPrefix == nil)
    }

    @Test func automaticMacSigningWithoutATeamSignsToRunLocally() {
        let r = ProvisioningResolver.resolve(SigningRequest(targetName: "App", identity: "Apple Development", style: .automatic,
                                                            bundleIdentifier: "com.example.app", sdk: "macosx27.1"),
                                             environment: Fixture.environment())
        #expect(r.identityHash == "-")
        #expect(r.errors == [])
    }

    @Test func deviceSigningNeedsATeamAndACertificate() {
        let noTeam = ProvisioningResolver.resolve(SigningRequest(targetName: "App", identity: "Apple Development", bundleIdentifier: "com.example.app",
                                                                 profileSupport: .required, sdk: "iphoneos27.0"), environment: Fixture.environment())
        #expect(noTeam.errors == ["Signing for \"App\" requires a development team. Select a development team in the Signing & Capabilities editor."])
        let noCert = ProvisioningResolver.resolve(SigningRequest(targetName: "App", identity: "Apple Development", team: "TEAMCCCCCC",
                                                                 bundleIdentifier: "com.example.app", profileSupport: .required, sdk: "iphoneos27.0"),
                                                  environment: Fixture.environment())
        #expect(noCert.errors.count == 1)
        #expect(noCert.errors[0].hasPrefix("No signing certificate \"Apple Development\" found: No \"Apple Development\" signing certificate matching team ID \"TEAMCCCCCC\""))
    }

    @Test func automaticDeviceSigningChoosesTheBestProfile() throws {
        let wildcard = Fixture.profile(uuid: "W", name: "Wildcard", appID: "*", expires: "2028-01-01T00:00:00Z")
        let explicit = Fixture.profile(uuid: "E", name: "Explicit", appID: "com.example.app")
        let expired = Fixture.profile(uuid: "X", name: "Expired", appID: "com.example.app", expires: "2026-01-01T00:00:00Z")
        let otherTeam = Fixture.profile(uuid: "O", name: "Other", team: "TEAMBBBBBB", appID: "com.example.app", certs: [Fixture.otherCert])
        let tv = Fixture.profile(uuid: "T", name: "TV", appID: "com.example.app", platform: "tvOS")
        let env = Fixture.environment(identities: [Fixture.devIdentity, Fixture.otherIdentity], profiles: [wildcard, expired, otherTeam, tv, explicit])
        let req = SigningRequest(targetName: "App", identity: "Apple Development", team: "TEAMAAAAAA", bundleIdentifier: "com.example.app",
                                 profileSupport: .required, projectEntitlements: ["com.apple.security.application-groups": .array([.string("group.x")])],
                                 sdk: "iphoneos27.0")
        // The app-groups entitlement is not in the profiles yet: none is usable.
        let none = ProvisioningResolver.resolve(req, environment: env)
        #expect(none.errors.count == 1)
        #expect(none.errors[0].hasPrefix("No profiles for 'com.example.app' were found"))
        #expect(none.errors[0].contains("does not create or download profiles"))
        var withGroups = req
        withGroups.projectEntitlements = [:]
        let r = ProvisioningResolver.resolve(withGroups, environment: env)
        #expect(r.errors == [])
        #expect(r.profile?.uuid == "E")
        #expect(r.identityHash == Fixture.devIdentity.hash)
        #expect(r.appIdentifierPrefix == "TEAMAAAAAA.")
        #expect(r.signedEntitlements == [
            "application-identifier": .string("TEAMAAAAAA.com.example.app"),
            "com.apple.developer.team-identifier": .string("TEAMAAAAAA"),
            "get-task-allow": .bool(true),
            "keychain-access-groups": .array([.string("TEAMAAAAAA.com.example.app")]),
        ])
        // Without the explicit profile the wildcard one is used.
        let wildEnv = Fixture.environment(profiles: [wildcard])
        #expect(ProvisioningResolver.resolve(withGroups, environment: wildEnv).profile?.uuid == "W")
        // An archive (not debuggable) does not take the debugging entitlement.
        var archive = withGroups
        archive.debuggable = false
        let a = ProvisioningResolver.resolve(archive, environment: env)
        #expect(a.signedEntitlements["get-task-allow"] == nil)
    }

    @Test func manualProfilesAreFoundByNameUUIDOrTeamAndName() {
        let p = Fixture.profile(uuid: "1234-ABCD", name: "Example Dev", appID: "com.example.app", extra: ["aps-environment": .string("development")])
        let env = Fixture.environment(profiles: [p])
        func req(_ spec: String, uuid: String = "", ents: Entitlements = [:]) -> SigningRequest {
            SigningRequest(targetName: "App", identity: "Apple Development", style: .manual, team: "TEAMAAAAAA", bundleIdentifier: "com.example.app",
                           profileSpecifier: spec, profileUUID: uuid, profileSupport: .required, projectEntitlements: ents, sdk: "iphoneos27.0")
        }
        #expect(ProvisioningResolver.resolve(req("Example Dev"), environment: env).profile?.uuid == "1234-ABCD")
        #expect(ProvisioningResolver.resolve(req("TEAMAAAAAA/Example Dev"), environment: env).profile?.uuid == "1234-ABCD")
        #expect(ProvisioningResolver.resolve(req("", uuid: "1234-abcd"), environment: env).profile?.uuid == "1234-ABCD")
        #expect(ProvisioningResolver.resolve(req("Example Dev", ents: ["aps-environment": .string("development")]), environment: env).errors == [])
        let missing = ProvisioningResolver.resolve(req("Nope"), environment: env)
        #expect(missing.errors.count == 1)
        #expect(missing.errors[0].hasPrefix("No profile for team 'TEAMAAAAAA' matching 'Nope' found"))
        let notIncluded = ProvisioningResolver.resolve(req("Example Dev", ents: ["com.apple.developer.healthkit": .bool(true)]), environment: env)
        #expect(notIncluded.errors == ["Provisioning profile \"Example Dev\" doesn't include the com.apple.developer.healthkit entitlement."])
        let wrongValue = ProvisioningResolver.resolve(req("Example Dev", ents: ["aps-environment": .string("production")]), environment: env)
        #expect(wrongValue.errors == ["Provisioning profile \"Example Dev\" doesn't match the entitlements file's value for the aps-environment entitlement."])
        let noSpec = ProvisioningResolver.resolve(req(""), environment: env)
        #expect(noSpec.errors == ["\"App\" requires a provisioning profile. Select a provisioning profile in the Signing & Capabilities editor."])
    }

    @Test func manualProfileProblemsAreReported() {
        let expired = Fixture.profile(uuid: "1", name: "Old", appID: "com.example.app", expires: "2026-01-01T00:00:00Z")
        let wrongID = Fixture.profile(uuid: "2", name: "Wrong", appID: "com.example.other")
        let noCert = Fixture.profile(uuid: "3", name: "NoCert", appID: "com.example.app", certs: [Fixture.otherCert])
        let env = Fixture.environment(profiles: [expired, wrongID, noCert])
        func errors(_ spec: String) -> [String] {
            ProvisioningResolver.resolve(SigningRequest(targetName: "App", identity: "Apple Development", style: .manual, team: "TEAMAAAAAA",
                                                        bundleIdentifier: "com.example.app", profileSpecifier: spec, profileSupport: .required,
                                                        sdk: "iphoneos27.0"), environment: env).errors
        }
        #expect(errors("Old") == ["Provisioning profile \"Old\" expired on 2026-01-01T00:00:00Z."])
        #expect(errors("Wrong") == ["Provisioning profile \"Wrong\" has app ID \"TEAMAAAAAA.com.example.other\", which does not match the bundle ID \"com.example.app\"."])
        #expect(errors("NoCert") == ["Provisioning profile \"NoCert\" doesn't include a signing certificate \"Apple Development\" from the keychain."])
    }

    @Test func macTeamSigning() {
        // Only unrestricted entitlements: the identity alone, no profile.
        let plain = ProvisioningResolver.resolve(SigningRequest(targetName: "App", identity: "Apple Development", style: .manual, team: "TEAMAAAAAA",
                                                                bundleIdentifier: "com.example.app", projectEntitlements: appGroups, sdk: "macosx27.1"),
                                                 environment: Fixture.environment())
        #expect(plain.errors == [])
        #expect(plain.profile == nil)
        #expect(plain.identityHash == Fixture.devIdentity.hash)
        #expect(plain.signedEntitlements == appGroups.overlaid(with: ["com.apple.security.get-task-allow": .bool(true)]))
        // A restricted entitlement takes a Mac profile, which adds the macOS identifiers.
        let macProfile = Fixture.profile(uuid: "M", name: "Mac Dev", appID: "com.example.app", platform: "OSX", mac: true)
        let keychain: Entitlements = ["keychain-access-groups": .array([.string("TEAMAAAAAA.com.example.shared")])]
        let req = SigningRequest(targetName: "App", identity: "Apple Development", team: "TEAMAAAAAA", bundleIdentifier: "com.example.app",
                                 projectEntitlements: keychain, sdk: "macosx27.1")
        let r = ProvisioningResolver.resolve(req, environment: Fixture.environment(profiles: [macProfile]))
        #expect(r.errors == [])
        #expect(r.profile?.uuid == "M")
        #expect(r.signedEntitlements == keychain.overlaid(with: [
            "com.apple.application-identifier": .string("TEAMAAAAAA.com.example.app"),
            "com.apple.developer.team-identifier": .string("TEAMAAAAAA"),
            "com.apple.security.get-task-allow": .bool(true),
        ]))
        let missing = ProvisioningResolver.resolve(req, environment: Fixture.environment())
        #expect(missing.errors.first?.hasPrefix("No profiles for 'com.example.app' were found") == true)
    }

    @Test func noIdentityMeansNoSignature() {
        let r = ProvisioningResolver.resolve(SigningRequest(targetName: "App", identity: "", bundleIdentifier: "x", sdk: "macosx27.1"), environment: Fixture.environment())
        #expect(r == SigningResolution())
    }
}

@Suite struct NestedCodeTests {
    let fm = FileManager.default

    func file(_ url: URL, _ bytes: [UInt8]) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
    }

    @Test func nestedCodeIsSignedInnermostFirst() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("ycode-nested-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("Host.app")
        let macho: [UInt8] = [0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0, 0]
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Host"], format: .xml, options: 0)
        try file(app.appendingPathComponent("Contents/Info.plist"), [UInt8](info))
        try file(app.appendingPathComponent("Contents/MacOS/Host"), macho)
        try file(app.appendingPathComponent("Contents/MacOS/helper-tool"), macho)
        try file(app.appendingPathComponent("Contents/MacOS/readme.txt"), Array("text".utf8))
        // A versioned framework with an XPC service of its own.
        let kit = app.appendingPathComponent("Contents/Frameworks/Kit.framework")
        try file(kit.appendingPathComponent("Versions/A/Kit"), macho)
        try file(kit.appendingPathComponent("Versions/A/XPCServices/Svc.xpc/Contents/MacOS/Svc"), macho)
        try fm.createSymbolicLink(atPath: kit.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try file(app.appendingPathComponent("Contents/Frameworks/libz2.dylib"), macho)
        // A plug-in that embeds a framework.
        let ext = app.appendingPathComponent("Contents/PlugIns/Share.appex")
        try file(ext.appendingPathComponent("Contents/MacOS/Share"), macho)
        try file(ext.appendingPathComponent("Contents/Frameworks/Inner.framework/Versions/A/Inner"), macho)
        try fm.createSymbolicLink(atPath: ext.appendingPathComponent("Contents/Frameworks/Inner.framework/Versions/Current").path, withDestinationPath: "A")
        try file(app.appendingPathComponent("Contents/Library/LoginItems/Login.app/Contents/MacOS/Login"), macho)

        let order = NestedCode.signingOrder(bundle: app).map { String($0.path.dropFirst(app.standardizedFileURL.path.count)) }
        #expect(order == [
            "/Contents/Frameworks/Kit.framework/Versions/A/XPCServices/Svc.xpc",
            "/Contents/Frameworks/Kit.framework",
            "/Contents/Frameworks/libz2.dylib",
            "/Contents/PlugIns/Share.appex/Contents/Frameworks/Inner.framework",
            "/Contents/PlugIns/Share.appex",
            "/Contents/Library/LoginItems/Login.app",
            "/Contents/MacOS/helper-tool",
            "",
        ])

        // Re-signing runs codesign once per item, in that order.
        let calls = Calls()
        let failure = CodesignCommand.resign(bundle: app, identity: "-", runner: CommandRunner { exe, args in
            calls.append(exe + " " + args.joined(separator: " "))
            return (0, Data())
        })
        #expect(failure == nil)
        #expect(calls.items.count == order.count)
        #expect(calls.items.last == "/usr/bin/codesign --force --sign - --preserve-metadata=identifier,entitlements,flags --timestamp=none \(app.standardizedFileURL.path)")
    }

    @Test func iOSStyleBundles() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("ycode-nested-ios-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("Phone.app")
        let macho: [UInt8] = [0xCF, 0xFA, 0xED, 0xFE]
        try file(app.appendingPathComponent("Phone"), macho)
        try file(app.appendingPathComponent("Frameworks/Kit.framework/Kit"), macho)
        try file(app.appendingPathComponent("PlugIns/Widget.appex/Widget"), macho)
        try file(app.appendingPathComponent("Watch/Watch.app/Watch"), macho)
        let order = NestedCode.signingOrder(bundle: app).map(\.lastPathComponent)
        #expect(order == ["Kit.framework", "Widget.appex", "Watch.app", "Phone.app"])
    }

    @Test func commandLines() {
        #expect(CodesignCommand.codesign(item: "/a.app", identity: "ABC", entitlements: "/e.xcent", options: ["runtime"], timestamp: true)
                == ["--force", "--sign", "ABC", "--entitlements", "/e.xcent", "--options", "runtime", "--timestamp", "/a.app"])
        #expect(CodesignCommand.codesign(item: "/a.app", identity: "-", timestamp: true) == ["--force", "--sign", "-", "--timestamp=none", "/a.app"])
        #expect(CodesignCommand.rcodesignAdHoc(item: "/a.app", entitlements: "/e.plist") == ["sign", "--entitlements-xml-file", "/e.plist", "/a.app"])
    }
}

final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ s: String) { lock.lock(); stored.append(s); lock.unlock() }
    var items: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}
