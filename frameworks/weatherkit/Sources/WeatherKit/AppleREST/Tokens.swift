// Ycode extension, plan.md R4: developer tokens for the WeatherKit REST API
// (rest-api.md §2) and the HTTP transport the REST backend uses.
//
// Token format: a JWT signed with ES256 (ECDSA P-256, SHA-256), header
// {alg: "ES256", kid: <key ID>, id: "<team ID>.<services ID>"}, claims
// exactly {iss: <team ID>, iat, exp, sub: <services ID>} (seconds since the
// Unix epoch). The private key is the PKCS#8 PEM (`.p8`) the owner downloads
// when creating a WeatherKit key; it is read at run time and never shipped.
import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - HTTP transport

/// Sends one HTTP request. The REST backend and the remote token provider
/// use it; tests substitute their own.
public protocol WeatherHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession` transport. Transport failures surface as `URLError`.
public struct URLSessionWeatherHTTPClient: WeatherHTTPClient {
    public init() {}

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: (error as? URLError) ?? URLError(.unknown))
                } else if let response = response as? HTTPURLResponse {
                    continuation.resume(returning: (data ?? Data(), response))
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }
            task.resume()
        }
    }
}

// MARK: - Tokens

/// Supplies the developer token sent as `Authorization: Bearer <token>`.
public protocol WeatherTokenProvider: Sendable {
    func token() async throws -> String
}

/// A token obtained elsewhere (for example from the developer's own server).
public struct StaticWeatherTokenProvider: WeatherTokenProvider {
    let value: String

    public init(token: String) { self.value = token }

    public func token() async throws -> String { value }
}

/// Signs tokens locally with the developer's WeatherKit key and reuses each
/// one until shortly before it expires.
public actor SigningWeatherTokenProvider: WeatherTokenProvider {
    let teamID: String
    let serviceID: String
    let keyID: String
    let key: P256.Signing.PrivateKey
    let lifetime: TimeInterval
    let clock: @Sendable () -> Date
    private var cached: (token: String, expires: Date)?

    /// - Parameters:
    ///   - privateKeyPEM: the PKCS#8 PEM text of the `.p8` key.
    ///   - lifetime: seconds between `iat` and `exp` (Ycode default one hour).
    public init(
        teamID: String, serviceID: String, keyID: String, privateKeyPEM: String, lifetime: TimeInterval = 3600,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.teamID = teamID
        self.serviceID = serviceID
        self.keyID = keyID
        do {
            self.key = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
        } catch {
            throw WeatherBackendError.notAuthorized
        }
        self.lifetime = lifetime
        self.clock = clock
    }

    /// Reads the key from a `.p8` file.
    public init(
        teamID: String, serviceID: String, keyID: String, privateKeyFile: URL, lifetime: TimeInterval = 3600,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        let pem = try String(contentsOf: privateKeyFile, encoding: .utf8)
        try self.init(
            teamID: teamID, serviceID: serviceID, keyID: keyID, privateKeyPEM: pem, lifetime: lifetime, clock: clock)
    }

    public func token() async throws -> String {
        let now = clock()
        if let cached, now < cached.expires.addingTimeInterval(-60) { return cached.token }
        let token = try DeveloperToken.sign(
            teamID: teamID, serviceID: serviceID, keyID: keyID, key: key, issuedAt: now, lifetime: lifetime)
        cached = (token, now.addingTimeInterval(lifetime))
        return token
    }
}

/// Fetches tokens from a URL the developer controls (the way Apple advises
/// apps to obtain them). The response body is the token text, or JSON with a
/// `token` member. A token is reused until shortly before its `exp` claim.
public actor RemoteWeatherTokenProvider: WeatherTokenProvider {
    let url: URL
    let httpClient: any WeatherHTTPClient
    let clock: @Sendable () -> Date
    private var cached: (token: String, expires: Date)?

    public init(url: URL, httpClient: any WeatherHTTPClient = URLSessionWeatherHTTPClient(),
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.httpClient = httpClient
        self.clock = clock
    }

    public func token() async throws -> String {
        let now = clock()
        if let cached, now < cached.expires.addingTimeInterval(-60) { return cached.token }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await httpClient.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw WeatherBackendError.notAuthorized
        }
        var token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if token.hasPrefix("{"),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = object["token"] as? String {
            token = value
        }
        guard let claims = try? DeveloperToken.decode(token).claims, let exp = claims["exp"] as? Double else {
            throw WeatherBackendError.notAuthorized
        }
        cached = (token, Date(timeIntervalSince1970: exp))
        return token
    }
}

// MARK: - JWT

/// ES256 JSON Web Tokens in the developer-token shape of rest-api.md §2.
public enum DeveloperToken {
    /// Signs a developer token.
    public static func sign(
        teamID: String, serviceID: String, keyID: String, key: P256.Signing.PrivateKey, issuedAt: Date,
        lifetime: TimeInterval
    ) throws -> String {
        let iat = Int(issuedAt.timeIntervalSince1970.rounded(.down))
        let header: [String: Any] = ["alg": "ES256", "kid": keyID, "id": "\(teamID).\(serviceID)"]
        let claims: [String: Any] = ["iss": teamID, "iat": iat, "exp": iat + Int(lifetime), "sub": serviceID]
        let signingInput =
            base64URL(try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])) + "."
            + base64URL(try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys]))
        let signature = try key.signature(for: Data(signingInput.utf8))
        return signingInput + "." + base64URL(signature.rawRepresentation)
    }

    /// Splits a token into its decoded header, claims, signing input and
    /// raw (r‖s) signature. Does not verify.
    public static func decode(_ token: String) throws
        -> (header: [String: Any], claims: [String: Any], signingInput: Data, signature: Data)
    {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = fromBase64URL(String(parts[0])),
              let claimsData = fromBase64URL(String(parts[1])),
              let signature = fromBase64URL(String(parts[2])),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try JSONSerialization.jsonObject(with: claimsData) as? [String: Any]
        else { throw WeatherBackendError.malformedResponse("not a JWT") }
        return (header, claims, Data("\(parts[0]).\(parts[1])".utf8), signature)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func fromBase64URL(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }
}
