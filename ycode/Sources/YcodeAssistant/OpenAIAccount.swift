import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OpenAI's documented sign-in for open-source and locally hosted apps:
/// "Sign in with ChatGPT" with ChatGPT plan usage (developers.openai.com,
/// /siwc/token-sharing-open-source). Authorization Code + PKCE (S256) in the
/// system browser, a loopback redirect on 127.0.0.1, dynamic client
/// registration (`client_id=dynamic_agent_client` on the first sign-in;
/// OpenAI issues Ycode a client ID bound to the user), no client secret.
/// Ycode never uses another application's client ID.
public struct OpenAIAuthConfiguration: Sendable, Equatable {
    public var issuer = "https://auth.openai.com"
    public var authorizeURL = "https://auth.openai.com/api/accounts/authorize"
    public var tokenURL = "https://auth.openai.com/api/accounts/oauth/token"
    /// OpenID discovery: `jwks_uri` and `revocation_endpoint`.
    public var discoveryURL = "https://auth.openai.com/.well-known/openid-configuration"
    /// The `resource` parameter: the API the tokens are for.
    public var resource = "https://api.openai.com/v1"
    /// `agent_name_hint`: the same on every installation.
    public var agentName = "Ycode"
    public var scopes = ["openid", "profile", "email", "offline_access", "resource.invoke", Self.planScope]
    public var callbackPath = "/auth/callback"

    /// The client ID that asks OpenAI to register a new client.
    public static let registrationClientID = "dynamic_agent_client"
    /// The scope that allows inference on the user's ChatGPT plan.
    public static let planScope = "chatgpt.tokens.use.direct"

    public init() {}
}

/// The client registration for this host: kept after sign-out, so a later
/// sign-in reuses the issued client ID.
public struct OpenAIRegistration: Codable, Sendable, Equatable {
    /// `ext_agent_host_id`: an opaque UUID URN made once per host.
    public var hostID: String
    /// The client ID OpenAI issued at the first sign-in.
    public var clientID: String?
    /// The verified `sub` and the email of the account it belongs to.
    public var subject: String?
    public var email: String?

    public static func newHost() -> OpenAIRegistration {
        OpenAIRegistration(hostID: "urn:uuid:" + UUID().uuidString.lowercased())
    }
}

/// The tokens of a signed-in account (stored in the secret store only).
public struct OpenAITokens: Codable, Sendable, Equatable {
    public var clientID: String
    public var subject: String
    public var email: String?
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    public var tokenType: String
    public var expiresAt: Date
    public var scopes: [String]
    public var savedAt: Date

    /// The grant allows inference on the user's plan.
    public var hasPlanUsage: Bool { scopes.contains(OpenAIAuthConfiguration.planScope) }
}

/// Checks an ID token's signature (RS256 against the issuer's JWKS).
public protocol IDTokenSignatureVerifier: Sendable {
    func verify(_ jwt: String, discoveryURL: URL) async throws
}

/// The pieces of one authorization attempt.
public struct AuthorizationAttempt: Sendable, Equatable {
    public var state: String
    public var nonce: String
    public var pkce: PKCE
    public var redirectURI: String
    /// The client ID sent: the issued one, or `dynamic_agent_client`.
    public var clientID: String
    public var isRegistration: Bool { clientID == OpenAIAuthConfiguration.registrationClientID }

    public init(redirectURI: String, clientID: String) {
        state = SecureRandom.token(24)
        nonce = SecureRandom.token(24)
        pkce = PKCE()
        self.redirectURI = redirectURI
        self.clientID = clientID
    }
}

public actor OpenAIAccount {
    public enum Status: Sendable, Equatable {
        case signedOut
        case signedIn(email: String?, planUsage: Bool)
    }

    public let configuration: OpenAIAuthConfiguration
    let store: SecretStore
    let openURL: @Sendable (URL) -> Bool
    let verifier: IDTokenSignatureVerifier?
    private var refreshing: Task<OpenAITokens, Error>?
    /// How long a sign-in waits for the browser.
    public var signInTimeout: TimeInterval = 300

    /// `openURL` opens the authorization page in the system browser and
    /// returns false when it cannot. `verifier` checks ID-token signatures
    /// (nil: the ID token is accepted on the strength of the TLS connection
    /// it came over, OpenID Connect Core §3.1.3.7 step 6).
    public init(configuration: OpenAIAuthConfiguration = .init(), store: SecretStore, verifier: IDTokenSignatureVerifier? = nil,
                openURL: @escaping @Sendable (URL) -> Bool) {
        self.configuration = configuration
        self.store = store
        self.verifier = verifier
        self.openURL = openURL
    }

    public func setSignInTimeout(_ t: TimeInterval) { signInTimeout = t }

    public var tokens: OpenAITokens? { store.readJSON(OpenAITokens.self, SecretAccount.openAITokens) }
    public var registration: OpenAIRegistration? { store.readJSON(OpenAIRegistration.self, SecretAccount.openAIRegistration) }

    public var status: Status {
        guard let t = tokens else { return .signedOut }
        return .signedIn(email: t.email, planUsage: t.hasPlanUsage)
    }

    // MARK: Authorization

    /// The authorization URL for `attempt` (sign-in guide §1).
    public static func authorizationURL(_ c: OpenAIAuthConfiguration, attempt a: AuthorizationAttempt, registration r: OpenAIRegistration,
                                        idTokenHint: String? = nil) -> URL? {
        var items: [URLQueryItem] = [.init(name: "client_id", value: a.clientID)]
        if a.isRegistration { items.append(.init(name: "agent_name_hint", value: c.agentName)) }
        items.append(.init(name: "ext_agent_host_id", value: r.hostID))
        if !a.isRegistration {
            if let idTokenHint { items.append(.init(name: "id_token_hint", value: idTokenHint)) }
            if let email = r.email { items.append(.init(name: "login_hint", value: email)) }
        }
        items += [
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: a.redirectURI),
            .init(name: "scope", value: c.scopes.joined(separator: " ")),
            .init(name: "resource", value: c.resource),
            .init(name: "state", value: a.state),
            .init(name: "nonce", value: a.nonce),
            .init(name: "code_challenge_method", value: PKCE.method),
            .init(name: "code_challenge", value: a.pkce.challenge),
        ]
        guard var u = URLComponents(string: c.authorizeURL) else { return nil }
        // Encode every value strictly (spaces as %20, '+', ':', '/' escaped).
        u.percentEncodedQuery = items.map { "\(HTTP.formEscape($0.name))=\(HTTP.formEscape($0.value ?? ""))" }.joined(separator: "&")
        return u.url
    }

    /// The callback's result, checked against the attempt (sign-in guide
    /// §2). Returns the code and the client ID to exchange it with.
    public static func validateCallback(_ query: [String: String], attempt a: AuthorizationAttempt) throws -> (code: String, clientID: String) {
        guard query["state"] == a.state else { throw AssistantError.signIn("The sign-in response did not match this request. Try again.") }
        if let e = query["error"] {
            if e == "access_denied" { throw AssistantError.signIn("Sign-in was cancelled.") }
            throw AssistantError.signIn("Sign-in failed: \(query["error_description"] ?? e).")
        }
        guard let code = query["code"], !code.isEmpty else { throw AssistantError.signIn("The sign-in response had no authorization code.") }
        let issued = query["client_id"]
        if a.isRegistration {
            guard let issued, !issued.isEmpty, issued != OpenAIAuthConfiguration.registrationClientID else {
                throw AssistantError.signIn("OpenAI did not finish registering Ycode. Try again.")
            }
            return (code, issued)
        }
        if let issued, !issued.isEmpty, issued != a.clientID {
            throw AssistantError.signIn("The sign-in response named a different client. Try again.")
        }
        return (code, a.clientID)
    }

    /// Signs in through the browser and stores the tokens. Starts the
    /// loopback listener before opening the browser.
    @discardableResult
    public func signIn() async throws -> OpenAITokens {
        var reg = registration ?? .newHost()
        if registration == nil { try store.writeJSON(reg, for: SecretAccount.openAIRegistration) }
        let box = CallbackBox()
        let path = configuration.callbackPath
        let server = try LoopbackServer { req in
            guard req.path == path else { return .text("Not found", status: 404) }
            box.deliver(req.query)
            return .text(Self.callbackPage(error: req.query["error"]), contentType: "text/html; charset=utf-8")
        }
        defer { server.stop() }
        let attempt = AuthorizationAttempt(redirectURI: "http://127.0.0.1:\(server.port)\(path)",
                                           clientID: reg.clientID ?? OpenAIAuthConfiguration.registrationClientID)
        guard let url = Self.authorizationURL(configuration, attempt: attempt, registration: reg) else {
            throw AssistantError.signIn("The sign-in address is not valid.")
        }
        guard openURL(url) else { throw AssistantError.signIn("Ycode could not open the browser.") }
        let query = try await box.wait(timeout: signInTimeout)
        let (code, clientID) = try Self.validateCallback(query, attempt: attempt)
        let response = try await exchange([
            ("grant_type", "authorization_code"), ("client_id", clientID), ("code", code),
            ("code_verifier", attempt.pkce.verifier), ("redirect_uri", attempt.redirectURI), ("resource", configuration.resource),
        ])
        guard let idToken = response.idToken else { throw AssistantError.signIn("OpenAI returned no ID token.") }
        let claims = try IDToken.validate(idToken, issuer: configuration.issuer, clientID: clientID, nonce: attempt.nonce)
        if let verifier, let d = URL(string: configuration.discoveryURL) { try await verifier.verify(idToken, discoveryURL: d) }
        if let known = reg.subject, reg.clientID == clientID, known != claims.subject {
            throw AssistantError.signIn("That is a different account than the one this registration belongs to. Sign out first.")
        }
        reg.clientID = clientID
        reg.subject = claims.subject
        reg.email = claims.email
        try store.writeJSON(reg, for: SecretAccount.openAIRegistration)
        let t = OpenAITokens(clientID: clientID, subject: claims.subject, email: claims.email, accessToken: response.accessToken,
                             refreshToken: response.refreshToken, idToken: idToken, tokenType: response.tokenType,
                             expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn ?? 3600)),
                             scopes: response.scopes, savedAt: Date())
        try store.writeJSON(t, for: SecretAccount.openAITokens)
        return t
    }

    static func callbackPage(error: String?) -> String {
        let message = error == nil ? "Sign-in complete. You can close this window and return to Ycode."
                                   : "Sign-in did not complete. You can close this window and return to Ycode."
        return "<!doctype html><html><head><meta charset=\"utf-8\"><title>Ycode</title></head>"
            + "<body style=\"font-family: -apple-system, sans-serif; margin: 3em\"><p>\(message)</p></body></html>"
    }

    // MARK: Tokens

    struct TokenResponse {
        var accessToken: String
        var refreshToken: String?
        var idToken: String?
        var tokenType: String
        var expiresIn: Int?
        var scopes: [String]
    }

    enum TokenEndpointError: Error { case oauth(String, String?), status(Int) }

    /// POSTs to the token endpoint and parses the response (token reference).
    func exchange(_ fields: [(String, String)]) async throws -> TokenResponse {
        guard let url = URL(string: configuration.tokenURL) else { throw AssistantError.signIn("The token address is not valid.") }
        let r: HTTP.Response
        do {
            r = try await HTTP.send(HTTP.formRequest(url, fields: fields), timeout: 30)
        } catch {
            throw AssistantError.temporarilyUnavailable("OpenAI's sign-in service did not answer: \(error.localizedDescription)")
        }
        let o = JSON.object(r.body) ?? [:]
        guard r.status == 200 else {
            if let e = o["error"] as? String { throw TokenEndpointError.oauth(e, o["error_description"] as? String) }
            throw TokenEndpointError.status(r.status)
        }
        guard let access = o["access_token"] as? String else { throw AssistantError.signIn("OpenAI returned no access token.") }
        return TokenResponse(accessToken: access, refreshToken: o["refresh_token"] as? String, idToken: o["id_token"] as? String,
                             tokenType: (o["token_type"] as? String) ?? "Bearer", expiresIn: JSON.int(o["expires_in"]),
                             scopes: ((o["scope"] as? String) ?? "").split(separator: " ").map(String.init))
    }

    /// A current access token, refreshed when it expires within two
    /// minutes (or when `forceRefresh`). Refreshes are serialized, so the
    /// rotating refresh token is never used twice.
    public func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let t = tokens else { throw AssistantError.notSignedIn(hint: Self.signInHint) }
        if !forceRefresh && t.expiresAt.timeIntervalSinceNow > 120 { return t.accessToken }
        if let refreshing { return try await refreshing.value.accessToken }
        let task = Task { try await self.refresh(t) }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value.accessToken
    }

    static let signInHint = "Sign in with ChatGPT in Settings ▸ Coding Assistant."
    static let unusableRefreshErrors: Set<String> = ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                                                    "refresh_token_invalidated", "refresh_token_reused"]

    private func refresh(_ t: OpenAITokens) async throws -> OpenAITokens {
        guard let rt = t.refreshToken else {
            try? store.delete(SecretAccount.openAITokens)
            throw AssistantError.notSignedIn(hint: "Your ChatGPT session has expired. " + Self.signInHint)
        }
        let response: TokenResponse
        do {
            response = try await exchange([("grant_type", "refresh_token"), ("client_id", t.clientID), ("refresh_token", rt),
                                           ("resource", configuration.resource)])
        } catch TokenEndpointError.oauth(let code, _) where Self.unusableRefreshErrors.contains(code) {
            try? store.delete(SecretAccount.openAITokens)
            throw AssistantError.notSignedIn(hint: "Your ChatGPT session needs to be renewed. " + Self.signInHint)
        } catch TokenEndpointError.oauth(let code, let description) {
            throw AssistantError.signIn("Refreshing the session failed (\(code))\(description.map { ": \($0)" } ?? "").")
        } catch TokenEndpointError.status(let s) {
            throw AssistantError.temporarilyUnavailable("OpenAI's sign-in service answered HTTP \(s).")
        }
        var n = t
        n.accessToken = response.accessToken
        n.refreshToken = response.refreshToken ?? t.refreshToken
        if let id = response.idToken { n.idToken = id }
        n.expiresAt = Date().addingTimeInterval(TimeInterval(response.expiresIn ?? 3600))
        if !response.scopes.isEmpty { n.scopes = response.scopes }
        n.savedAt = Date()
        try store.writeJSON(n, for: SecretAccount.openAITokens)
        return n
    }

    /// Revokes the refresh token at the issuer's `revocation_endpoint`, then
    /// forgets the tokens (the registration and host ID stay). Returns
    /// whether the revocation was confirmed.
    @discardableResult
    public func signOut() async -> Bool {
        guard let t = tokens else { return true }
        var confirmed = false
        if let rt = t.refreshToken, let endpoint = await revocationEndpoint() {
            for attempt in 0..<3 {
                if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000) }
                guard let r = try? await HTTP.send(HTTP.formRequest(endpoint, fields: [("token", rt), ("token_type_hint", "refresh_token"),
                                                                                    ("client_id", t.clientID)]), timeout: 15) else { continue }
                if r.status == 200 { confirmed = true; break }
                if r.status < 500 { break }
            }
        }
        try? store.delete(SecretAccount.openAITokens)
        return confirmed
    }

    func revocationEndpoint() async -> URL? {
        guard let d = URL(string: configuration.discoveryURL), let r = try? await HTTP.send(URLRequest(url: d), timeout: 10), r.status == 200,
              let s = JSON.object(r.body)?["revocation_endpoint"] as? String else { return nil }
        return URL(string: s)
    }
}

/// Holds the one callback a sign-in waits for.
final class CallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String: String]?
    private var waiter: CheckedContinuation<[String: String], Error>?

    func deliver(_ q: [String: String]) {
        lock.lock()
        guard value == nil else { lock.unlock(); return }
        value = q
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(returning: q)
    }

    private func fail(_ e: Error) {
        lock.lock()
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(throwing: e)
    }

    func wait(timeout: TimeInterval) async throws -> [String: String] {
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if !Task.isCancelled { self?.fail(AssistantError.signIn("Sign-in timed out. Try again.")) }
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<[String: String], Error>) in
                lock.lock()
                if let v = value { lock.unlock(); c.resume(returning: v); return }
                waiter = c
                lock.unlock()
            }
        } onCancel: { [weak self] in
            self?.fail(CancellationError())
        }
    }
}

/// ID-token claim checks (OpenID Connect Core §3.1.3.7; the sign-in guide
/// §4: issuer, audience = the issued client ID, expiry, nonce, subject).
public enum IDToken {
    public struct Claims: Sendable, Equatable {
        public var subject: String
        public var email: String?
    }

    /// The decoded header and payload of a compact JWT.
    public static func decode(_ jwt: String) -> (header: [String: Any], payload: [String: Any], signingInput: String, signature: Data)? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let h = Base64URL.decode(parts[0]), let p = Base64URL.decode(parts[1]), let s = Base64URL.decode(parts[2]),
              let header = JSON.object(h), let payload = JSON.object(p) else { return nil }
        return (header, payload, parts[0] + "." + parts[1], s)
    }

    public static func validate(_ jwt: String, issuer: String, clientID: String, nonce: String, now: Date = Date(), leeway: TimeInterval = 120) throws -> Claims {
        guard let (_, p, _, _) = decode(jwt) else { throw AssistantError.signIn("The ID token is malformed.") }
        guard (p["iss"] as? String) == issuer else { throw AssistantError.signIn("The ID token comes from an unexpected issuer.") }
        let audiences: [String] = (p["aud"] as? String).map { [$0] } ?? (p["aud"] as? [String]) ?? []
        guard audiences.contains(clientID) else { throw AssistantError.signIn("The ID token is not meant for this client.") }
        guard let exp = JSON.int(p["exp"]), Date(timeIntervalSince1970: TimeInterval(exp)).addingTimeInterval(leeway) > now else {
            throw AssistantError.signIn("The ID token has expired.")
        }
        guard (p["nonce"] as? String) == nonce else { throw AssistantError.signIn("The ID token does not belong to this sign-in.") }
        guard let sub = p["sub"] as? String, !sub.isEmpty else { throw AssistantError.signIn("The ID token names no account.") }
        return Claims(subject: sub, email: p["email"] as? String)
    }
}
