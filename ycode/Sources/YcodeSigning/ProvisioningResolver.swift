import Foundation

/// What the build system knows about one target when it asks how to sign
/// it (swift-build's provisioning source data, open source).
public struct SigningRequest: Equatable, Sendable {
    public enum Style: Sendable { case automatic, manual }
    public enum ProfileSupport: Sendable { case unsupported, optional, required }

    public var targetName: String
    /// `CODE_SIGN_IDENTITY` (swift-build sends `-` for every simulator build).
    public var identity: String
    public var style: Style
    /// `DEVELOPMENT_TEAM`, nil when empty.
    public var team: String?
    public var bundleIdentifier: String
    /// `PROVISIONING_PROFILE_SPECIFIER`: a profile name or UUID, optionally `<team>/` first.
    public var profileSpecifier: String
    /// `PROVISIONING_PROFILE`: a profile UUID.
    public var profileUUID: String
    public var profileSupport: ProfileSupport
    /// Entitlements the product type adds (swift-build's product-type specs).
    public var productTypeEntitlements: Entitlements
    /// The `CODE_SIGN_ENTITLEMENTS` file (and `CODE_SIGN_ENTITLEMENTS_CONTENTS`),
    /// with build settings already expanded by swift-build except
    /// `$(AppIdentifierPrefix)`, which it fills in from the answer.
    public var projectEntitlements: Entitlements?
    /// SDK canonical name and variant.
    public var sdk: String
    public var sdkVariant: String?
    /// Whether the product takes entitlements (swift-build: an executable,
    /// `MACH_O_TYPE` `mh_execute`). Libraries and test bundles take none.
    public var supportsEntitlements: Bool
    /// The product type (`com.apple.product-type.…`), empty when unknown.
    public var productType: String
    public var signingRequiresTeam: Bool
    /// Local development builds are debuggable; archives are not.
    public var debuggable: Bool

    public init(targetName: String, identity: String, style: Style = .automatic, team: String? = nil, bundleIdentifier: String,
                profileSpecifier: String = "", profileUUID: String = "", profileSupport: ProfileSupport = .optional,
                productTypeEntitlements: Entitlements = [:], projectEntitlements: Entitlements? = nil,
                sdk: String, sdkVariant: String? = nil, supportsEntitlements: Bool = true, productType: String = "",
                signingRequiresTeam: Bool = false, debuggable: Bool = true) {
        self.targetName = targetName
        self.identity = identity
        self.style = style
        self.team = team.flatMap { $0.isEmpty ? nil : $0 }
        self.bundleIdentifier = bundleIdentifier
        self.profileSpecifier = profileSpecifier
        self.profileUUID = profileUUID
        self.profileSupport = profileSupport
        self.productTypeEntitlements = productTypeEntitlements
        self.projectEntitlements = projectEntitlements
        self.sdk = sdk
        self.sdkVariant = sdkVariant
        self.supportsEntitlements = supportsEntitlements
        self.productType = productType
        self.signingRequiresTeam = signingRequiresTeam
        self.debuggable = debuggable
    }

    public var platform: SigningPlatform { SigningPlatform(sdk: sdk, variant: sdkVariant) }

    /// Product types swift-build signs only with entitlements
    /// (`ENTITLEMENTS_REQUIRED`): UI test bundles, which run in a runner
    /// app (open-source swift-build, `XCTestBundleProductTypeSpec`).
    public static let entitlementsRequiredProductTypes: Set<String> = ["com.apple.product-type.bundle.ui-testing"]

    /// Whether entitlements are composed for the product: executables, and
    /// the product types that require them although they are bundles.
    public var takesEntitlements: Bool { supportsEntitlements || Self.entitlementsRequiredProductTypes.contains(productType) }
}

/// The answer: what to sign with and which entitlements go where.
public struct SigningResolution: Equatable, Sendable {
    /// `-` for ad hoc, a SHA-1 hash for an identity, nil for no signing.
    public var identityHash: String?
    public var identityName: String?
    public var profile: ProvisioningProfile?
    /// Entitlements signed into the code signature.
    public var signedEntitlements: Entitlements = [:]
    /// Entitlements linked into the executable's `__TEXT,__entitlements`
    /// section (simulator builds).
    public var simulatedEntitlements: Entitlements = [:]
    /// The values of `$(AppIdentifierPrefix)` and `$(TeamIdentifierPrefix)`.
    public var appIdentifierPrefix: String?
    public var teamIdentifierPrefix: String?
    public var errors: [String] = []
    public var warnings: [String] = []

    public init(identityHash: String? = nil, identityName: String? = nil) {
        self.identityHash = identityHash
        self.identityName = identityName
    }

    static func failure(_ message: String) -> SigningResolution {
        var r = SigningResolution(identityHash: "-")
        r.errors = [message]
        return r
    }
}

/// Identities and profiles to choose from. Loaded on first use, so ad hoc
/// builds never touch the keychain.
public struct SigningEnvironment: Sendable {
    public var identities: @Sendable () -> [SigningIdentity]
    public var profiles: @Sendable () -> [ProvisioningProfile]
    public var now: Date

    public init(identities: @escaping @Sendable () -> [SigningIdentity], profiles: @escaping @Sendable () -> [ProvisioningProfile], now: Date = Date()) {
        self.identities = identities
        self.profiles = profiles
        self.now = now
    }

    /// The user's keychain and installed profiles (read-only).
    public static func user(environment: [String: String] = ProcessInfo.processInfo.environment) -> SigningEnvironment {
        let dirs = ProfileStore.directories(environment: environment)
        return SigningEnvironment(identities: { Keychain.identities() }, profiles: { ProfileStore.load(directories: dirs) })
    }
}

/// Chooses the identity and profile for a target and composes its
/// entitlements. See specs/ide/signing.md §2–§4.
public enum ProvisioningResolver {
    public static let adHocName = "Sign to Run Locally"

    public static func resolve(_ r: SigningRequest, environment env: SigningEnvironment) -> SigningResolution {
        // No identity: the product is not signed.
        if r.identity.isEmpty { return SigningResolution() }
        let platform = r.platform
        let teamPrefix = r.team.map { $0 + "." }
        if r.identity == "-" || platform.isSimulator {
            return adHoc(r, platform: platform, teamPrefix: teamPrefix)
        }
        // A team is needed to sign with an identity, except on the Mac,
        // where automatic signing without one signs to run locally.
        guard let team = r.team else {
            if platform.isMac && r.style == .automatic && !r.signingRequiresTeam {
                return adHoc(r, platform: platform, teamPrefix: nil)
            }
            if platform.isMac && r.style == .manual && !r.signingRequiresTeam && r.profileSpecifier.isEmpty && r.profileUUID.isEmpty {
                return withIdentity(r, team: nil, platform: platform, environment: env)
            }
            return .failure("Signing for \"\(r.targetName)\" requires a development team. Select a development team in the Signing & Capabilities editor.")
        }
        return withIdentity(r, team: team, platform: platform, environment: env)
    }

    /// The project's entitlements over the product type's.
    static func base(_ r: SigningRequest) -> Entitlements {
        r.productTypeEntitlements.overlaid(with: r.projectEntitlements ?? [:])
    }

    /// Sign to Run Locally. On the Mac and devices the project's
    /// entitlements go into the ad hoc signature, with the debugging
    /// entitlement for debuggable builds. Simulator builds keep the
    /// signature to the debugging entitlement and link the rest, with the
    /// application identifier and keychain group Ycode derives, into the
    /// executable's entitlements section.
    static func adHoc(_ r: SigningRequest, platform: SigningPlatform, teamPrefix: String?) -> SigningResolution {
        var out = SigningResolution(identityHash: "-", identityName: adHocName)
        out.appIdentifierPrefix = teamPrefix
        out.teamIdentifierPrefix = teamPrefix
        guard r.takesEntitlements else { return out }
        let base = base(r)
        if platform.isSimulator {
            let appID = (teamPrefix ?? "") + r.bundleIdentifier
            var derived: Entitlements = [
                "application-identifier": .string(appID),
                "keychain-access-groups": .array([.string(appID)]),
            ]
            if let team = r.team { derived["com.apple.developer.team-identifier"] = .string(team) }
            out.simulatedEntitlements = derived.overlaid(with: base)
            if r.debuggable { out.signedEntitlements = ["get-task-allow": .bool(true)] }
            return out
        }
        var signed = base
        if r.debuggable { signed[platform.getTaskAllowKey] = .bool(true) }
        out.signedEntitlements = signed
        let restricted = EntitlementPolicy.restrictedKeys(base, on: platform)
        if platform.isMac && !restricted.isEmpty {
            out.warnings.append("\"\(r.targetName)\" is signed to run locally, but \(restricted.map { "\"\($0)\"" }.joined(separator: ", ")) \(restricted.count == 1 ? "needs" : "need") a provisioning profile; macOS may refuse to launch it. Select a development team to sign with a profile.")
        }
        return out
    }

    /// The profile a manual specifier names, if any.
    static func named(_ r: SigningRequest, in profiles: [ProvisioningProfile]) -> (profile: ProvisioningProfile?, specifier: String?) {
        if !r.profileUUID.isEmpty { return (profiles.first { $0.uuid.caseInsensitiveCompare(r.profileUUID) == .orderedSame }, r.profileUUID) }
        guard !r.profileSpecifier.isEmpty else { return (nil, nil) }
        var spec = r.profileSpecifier
        var team = r.team
        if let slash = spec.firstIndex(of: "/") {
            team = String(spec[..<slash])
            spec = String(spec[spec.index(after: slash)...])
        }
        let match = profiles.first { p in
            (p.uuid.caseInsensitiveCompare(spec) == .orderedSame || p.name == spec) && (team.map(p.teamIdentifiers.contains) ?? true)
        }
        return (match, r.profileSpecifier)
    }

    /// Why a profile cannot sign the request, or nil when it can.
    static func problem(with p: ProvisioningProfile, _ r: SigningRequest, team: String?, platform: SigningPlatform,
                        identities: [SigningIdentity], now: Date) -> String? {
        if p.isExpired(at: now) {
            let f = ISO8601DateFormatter()
            return "Provisioning profile \"\(p.name)\" expired on \(p.expirationDate.map { f.string(from: $0) } ?? "an earlier date")."
        }
        if let team, !p.teamIdentifiers.contains(team) {
            return "Provisioning profile \"\(p.name)\" belongs to team \(p.teamIdentifiers.joined(separator: ", ")), not to the development team \(team)."
        }
        if !p.platforms.isEmpty && !p.platforms.contains(where: platform.profilePlatforms.contains) {
            return "Provisioning profile \"\(p.name)\" is for \(p.platforms.joined(separator: ", ")), not for \(platform.profilePlatforms[0])."
        }
        if !p.covers(bundleIdentifier: r.bundleIdentifier) {
            return "Provisioning profile \"\(p.name)\" has app ID \"\(p.applicationIdentifier ?? "")\", which does not match the bundle ID \"\(r.bundleIdentifier)\"."
        }
        if !identities.contains(where: { p.certificateHashes.contains($0.hash) }) {
            return "Provisioning profile \"\(p.name)\" doesn't include a signing certificate \"\(r.identity)\" from the keychain."
        }
        if r.debuggable && platform.isMac == false && p.kind != .development {
            // A device build that is debugged needs a development profile.
            return "Provisioning profile \"\(p.name)\" is a \(p.kind.rawValue) profile; debugging needs a development profile."
        }
        for m in EntitlementPolicy.mismatches(base(r), profile: p, platform: platform) {
            switch m {
            case .missing(let k): return "Provisioning profile \"\(p.name)\" doesn't include the \(k) entitlement."
            case .value(let k): return "Provisioning profile \"\(p.name)\" doesn't match the entitlements file's value for the \(k) entitlement."
            }
        }
        return nil
    }

    /// Ranks usable profiles: an explicit app ID before a wildcard, the
    /// kind that fits the build, then the latest expiry.
    static func better(_ a: ProvisioningProfile, _ b: ProvisioningProfile, debuggable: Bool) -> Bool {
        if a.isWildcard != b.isWildcard { return !a.isWildcard }
        let want: ProvisioningProfile.Kind = debuggable ? .development : .distribution
        if (a.kind == want) != (b.kind == want) { return a.kind == want }
        let ea = a.expirationDate ?? .distantPast, eb = b.expirationDate ?? .distantPast
        if ea != eb { return ea > eb }
        return a.uuid < b.uuid
    }

    static func withIdentity(_ r: SigningRequest, team: String?, platform: SigningPlatform, environment env: SigningEnvironment) -> SigningResolution {
        let candidates = IdentitySelector.candidates(r.identity, team: team, in: env.identities(), now: env.now)
        guard !candidates.isEmpty else {
            let teamText = team.map { " matching team ID \"\($0)\"" } ?? ""
            return .failure("No signing certificate \"\(r.identity)\" found: No \"\(r.identity)\" signing certificate\(teamText) with a private key was found in the keychain. Ycode does not create certificates; add one to the keychain, or sign to run locally.")
        }
        let base = base(r)
        let restricted = r.takesEntitlements ? EntitlementPolicy.restrictedKeys(base, on: platform) : []
        let specified = !r.profileSpecifier.isEmpty || !r.profileUUID.isEmpty
        // Automatic signing uses a matching profile when there is one; it
        // needs one for restricted entitlements and where profiles are required.
        let needsProfile = r.profileSupport == .required || !restricted.isEmpty
        var profile: ProvisioningProfile?
        if r.profileSupport != .unsupported && (specified || r.style == .automatic || needsProfile) {
            let profiles = env.profiles()
            if r.style == .manual || specified {
                let (named, spec) = named(r, in: profiles)
                if let spec, named == nil {
                    return .failure("No profile for team '\(team ?? "")' matching '\(spec)' found: Ycode found no installed provisioning profile matching '\(spec)'. Install the profile, or choose another one in the Signing & Capabilities editor.")
                }
                if let named {
                    if let why = problem(with: named, r, team: team, platform: platform, identities: candidates, now: env.now) { return .failure(why) }
                    profile = named
                } else if needsProfile {
                    return .failure("\"\(r.targetName)\" requires a provisioning profile. Select a provisioning profile in the Signing & Capabilities editor.")
                }
            } else {
                let usable = profiles.filter { problem(with: $0, r, team: team, platform: platform, identities: candidates, now: env.now) == nil }
                profile = usable.min { better($0, $1, debuggable: r.debuggable) }
                if profile == nil && needsProfile {
                    return .failure("No profiles for '\(r.bundleIdentifier)' were found: Ycode found no installed provisioning profile for team '\(team ?? "")' matching '\(r.bundleIdentifier)'\(restricted.isEmpty ? "" : " with the entitlements the target needs"). Ycode does not create or download profiles (automatic provisioning through Apple's developer services is not supported); install a matching profile, or sign to run locally.")
                }
            }
        }
        // The identity: one the profile lists, else the latest-expiring.
        let identity = profile.flatMap { p in candidates.first { p.certificateHashes.contains($0.hash) } } ?? candidates[0]
        var out = SigningResolution(identityHash: identity.hash, identityName: identity.name)
        out.profile = profile
        let prefix = (profile?.applicationIdentifierPrefix ?? team).map { $0 + "." }
        out.appIdentifierPrefix = prefix
        out.teamIdentifierPrefix = (team ?? identity.team).map { $0 + "." }
        guard r.takesEntitlements else { return out }
        var signed: Entitlements = [:]
        if let profile {
            signed[platform.applicationIdentifierKey] = .string((prefix ?? "") + r.bundleIdentifier)
            if let t = team ?? profile.teamIdentifiers.first { signed["com.apple.developer.team-identifier"] = .string(t) }
            // The debugging entitlement: unrestricted on the Mac; on devices
            // only as a development profile allows it.
            if r.debuggable && (platform.isMac || profile.entitlements[platform.getTaskAllowKey]?.boolValue == true) {
                signed[platform.getTaskAllowKey] = .bool(true)
            }
            // Devices: the app's own keychain group, as the profile allows it.
            if !platform.isMac && base["keychain-access-groups"] == nil, let allowed = profile.entitlements["keychain-access-groups"] {
                let own = EntitlementValue.array([.string((prefix ?? "") + r.bundleIdentifier)])
                if EntitlementPolicy.allows(allowed, own) { signed["keychain-access-groups"] = own }
            }
            // The project cannot replace the identifiers derived from the profile.
            signed = base.overlaid(with: signed)
        } else {
            signed = base
            if r.debuggable { signed[platform.getTaskAllowKey] = .bool(true) }
        }
        out.signedEntitlements = signed
        return out
    }
}
