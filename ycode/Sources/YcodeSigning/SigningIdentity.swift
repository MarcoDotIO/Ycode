import Foundation

/// A code-signing identity (a certificate with its private key) in the
/// user's keychain. Ycode reads identities only; it never creates, imports
/// or exports them, and never shows more than the name and hash.
public struct SigningIdentity: Equatable, Sendable {
    /// SHA-1 of the certificate, upper-case hexadecimal (what `codesign --sign` takes).
    public var hash: String
    /// The certificate's common name, e.g. `Apple Development: <person> (<id>)`.
    public var name: String
    /// The team: the certificate subject's organizational unit.
    public var team: String?
    public var expires: Date?

    public init(hash: String, name: String, team: String? = nil, expires: Date? = nil) {
        self.hash = hash.uppercased()
        self.name = name
        self.team = team
        self.expires = expires
    }

    /// The certificate kind: the common name before `:` ("Apple Development").
    public var kind: String {
        name.firstIndex(of: ":").map { String(name[..<$0]) } ?? name
    }
}

/// Matches `CODE_SIGN_IDENTITY` values against identities.
public enum IdentitySelector {
    /// Names that select the same certificates: the current kinds and the
    /// older names of the same certificate types.
    static let families: [[String]] = [
        ["Apple Development", "iPhone Developer", "Mac Developer"],
        ["Apple Distribution", "iPhone Distribution", "3rd Party Mac Developer Application", "Mac App Distribution"],
    ]

    /// Whether the value is a SHA-1 hash (40 hexadecimal digits).
    public static func isHash(_ s: String) -> Bool {
        s.count == 40 && s.allSatisfy(\.isHexDigit)
    }

    /// Whether `selector` (a hash, a full name, or a kind such as
    /// `Apple Development`) selects `identity`.
    public static func matches(_ selector: String, _ identity: SigningIdentity) -> Bool {
        if isHash(selector) { return selector.uppercased() == identity.hash }
        if selector == identity.name { return true }
        let kinds = families.first { $0.contains(selector) } ?? [selector]
        return kinds.contains(identity.kind)
    }

    /// The identities a selector picks, of the team when one is given,
    /// valid at `now`, latest-expiring first.
    public static func candidates(_ selector: String, team: String?, in identities: [SigningIdentity], now: Date) -> [SigningIdentity] {
        identities
            .filter { matches(selector, $0) && (team == nil || $0.team == team) && ($0.expires.map { $0 > now } ?? true) }
            .sorted { ($0.expires ?? .distantFuture) > ($1.expires ?? .distantFuture) }
    }

    /// Whether the selector names a distribution certificate kind.
    public static func isDistribution(_ selector: String) -> Bool {
        families[1].contains(selector) || selector.hasPrefix("Developer ID")
    }
}

/// Runs a command and returns its status and standard output. Tests replace it.
public struct CommandRunner: Sendable {
    public var run: @Sendable (_ executable: String, _ arguments: [String]) -> (status: Int32, output: Data)

    public init(run: @escaping @Sendable (String, [String]) -> (status: Int32, output: Data)) { self.run = run }

    /// Runs the program with standard error discarded and no standard input.
    public static let system = CommandRunner { executable, arguments in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, Data()) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }
}

/// The user's keychain, read through `/usr/bin/security` (macOS only).
public enum Keychain {
    public static let security = "/usr/bin/security"

    /// `security find-identity -v -p codesigning`: lines `  1) <hash> "<name>"`.
    public static func parseFindIdentity(_ text: String) -> [(hash: String, name: String)] {
        var out: [(String, String)] = []
        var seen = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let paren = t.firstIndex(of: ")"), Int(t[..<paren]) != nil else { continue }
            let rest = t[t.index(after: paren)...].trimmingCharacters(in: .whitespaces)
            guard let space = rest.firstIndex(of: " ") else { continue }
            let hash = String(rest[..<space])
            var name = rest[space...].trimmingCharacters(in: .whitespaces)
            guard IdentitySelector.isHash(hash), name.hasPrefix("\"") else { continue }
            name.removeFirst()
            // An invalid identity carries a reason after the closing quote.
            guard let close = name.lastIndex(of: "\"") else { continue }
            // Without -v the listing repeats the valid identities.
            if seen.insert(hash.uppercased()).inserted { out.append((hash.uppercased(), String(name[..<close]))) }
        }
        return out
    }

    /// The valid code-signing identities, with team and expiry read from
    /// their certificates. Empty when `security` is unavailable.
    public static func identities(runner: CommandRunner = .system) -> [SigningIdentity] {
        guard FileManager.default.isExecutableFile(atPath: security) else { return [] }
        let found = runner.run(security, ["find-identity", "-v", "-p", "codesigning"])
        guard found.status == 0 else { return [] }
        let listed = parseFindIdentity(String(decoding: found.output, as: UTF8.self))
        guard !listed.isEmpty else { return [] }
        // The certificates (public parts only), keyed by their SHA-1.
        let certs = runner.run(security, ["find-certificate", "-a", "-Z", "-p"])
        var summaries: [String: CertificateSummary] = [:]
        for block in CertificateSummary.pemBlocks(String(decoding: certs.output, as: UTF8.self)) {
            let hash = block.sha1 ?? SHA1.hex(block.der)
            if let s = CertificateSummary(der: block.der) { summaries[hash] = s }
        }
        return listed.map { item in
            let s = summaries[item.hash]
            return SigningIdentity(hash: item.hash, name: item.name, team: s?.organizationalUnit, expires: s?.notAfter)
        }
    }
}
