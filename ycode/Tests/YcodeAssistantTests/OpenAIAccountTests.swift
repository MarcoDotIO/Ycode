import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif
import Testing
@testable import YcodeAssistant

/// Shared state between the simulated browser and the stand-in issuer.
final class AuthState: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    subscript(_ k: String) -> String? {
        get { lock.lock(); defer { lock.unlock() }; return values[k] }
        set { lock.lock(); values[k] = newValue; lock.unlock() }
    }
}

/// Signs test ID tokens: RS256 with a fresh key on macOS (verified against
/// the stand-in JWKS); unsigned elsewhere (no verifier on Linux).
struct TestSigner: @unchecked Sendable {
    #if canImport(Security)
    let key: SecKey
    let jwk: [String: Any]
    init() throws {
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        var error: Unmanaged<CFError>?
        guard let k = SecKeyCreateRandomKey(attrs as CFDictionary, &error), let pub = SecKeyCopyPublicKey(k),
              let der = SecKeyCopyExternalRepresentation(pub, nil) as Data? else { throw AssistantError.failed("no key") }
        key = k
        let (n, e) = try Self.parseRSAPublicKey(der)
        jwk = ["kty": "RSA", "kid": "test-key", "use": "sig", "alg": "RS256", "n": Base64URL.encode(n), "e": Base64URL.encode(e)]
    }

    /// The two INTEGERs of a PKCS #1 RSAPublicKey.
    static func parseRSAPublicKey(_ d: Data) throws -> (Data, Data) {
        let b = [UInt8](d)
        var i = 0
        func readLength() -> Int {
            let first = Int(b[i]); i += 1
            if first < 0x80 { return first }
            var n = 0
            for _ in 0..<(first & 0x7f) { n = n << 8 | Int(b[i]); i += 1 }
            return n
        }
        guard b[i] == 0x30 else { throw AssistantError.failed("not a sequence") }
        i += 1; _ = readLength()
        func integer() -> Data { i += 1; let l = readLength(); defer { i += l }; return Data(b[i..<(i + l)]) }
        return (integer(), integer())
    }

    func sign(_ claims: [String: Any]) -> String {
        let header = Base64URL.encode(try! JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "test-key", "typ": "JWT"], options: [.sortedKeys]))
        let payload = Base64URL.encode(try! JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys]))
        let input = header + "." + payload
        let sig = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil)! as Data
        return input + "." + Base64URL.encode(sig)
    }
    #else
    let jwk: [String: Any] = [:]
    init() throws {}
    func sign(_ claims: [String: Any]) -> String {
        let header = Base64URL.encode(try! JSONSerialization.data(withJSONObject: ["alg": "RS256"], options: []))
        let payload = Base64URL.encode(try! JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys]))
        return header + "." + payload + "." + Base64URL.encode(Data("unsigned".utf8))
    }
    #endif

    static var verifier: IDTokenSignatureVerifier? {
        #if canImport(Security)
        JWKSSignatureVerifier()
        #else
        nil
        #endif
    }
}

/// A stand-in for OpenAI's issuer: discovery, JWKS, token and revocation
/// endpoints. The authorization page is simulated by `browser`.
struct StandInIssuer {
    let server: LoopbackServer
    let state = AuthState()
    let rec = Recorder()
    let signer: TestSigner
    var config: OpenAIAuthConfiguration

    init(issued: String = "oaiapp_ycode_test", scope: String = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
         subject: String = "user-123") throws {
        let signer = try TestSigner()
        let state = self.state, rec = self.rec
        let issuerName = "https://auth.example.test"
        let server = try LoopbackServer { req in
            rec.add(req)
            let base = "http://127.0.0.1:\(req.header("host")?.split(separator: ":").last ?? "0")"
            switch req.path {
            case "/.well-known/openid-configuration":
                return .json(["issuer": issuerName, "jwks_uri": base + "/jwks", "revocation_endpoint": base + "/revoke"])
            case "/jwks":
                return .json(["keys": [signer.jwk]])
            case "/token":
                let f = req.form
                if f["grant_type"] == "authorization_code" {
                    guard f["code"] == state["code"], f["client_id"] == issued, f["redirect_uri"] == state["redirect_uri"],
                          f["resource"] == "https://api.openai.com/v1", let v = f["code_verifier"],
                          Base64URL.encode(SHA256.hash(Data(v.utf8))) == state["challenge"] else {
                        return .json(["error": "invalid_grant", "error_description": "bad exchange"], status: 400)
                    }
                    let id = signer.sign(["iss": issuerName, "aud": issued, "sub": subject, "email": "dev@example.test",
                                          "nonce": state["nonce"]!, "exp": Int(Date().timeIntervalSince1970) + 600,
                                          "iat": Int(Date().timeIntervalSince1970)])
                    return .json(["access_token": "at-1", "refresh_token": "rt-1", "id_token": id, "token_type": "Bearer",
                                  "expires_in": 3600, "scope": scope])
                }
                if f["grant_type"] == "refresh_token" {
                    if f["refresh_token"] == "rt-dead" { return .json(["error": "refresh_token_reused"], status: 400) }
                    return .json(["access_token": "at-2", "refresh_token": "rt-2", "token_type": "Bearer", "expires_in": 3600, "scope": scope])
                }
                return .json(["error": "unsupported_grant_type"], status: 400)
            case "/revoke":
                return .text("")
            default:
                return .text("", status: 404)
            }
        }
        self.server = server
        self.signer = signer
        var c = OpenAIAuthConfiguration()
        c.issuer = issuerName
        c.authorizeURL = "https://auth.example.test/authorize"
        c.tokenURL = server.baseURL + "/token"
        c.discoveryURL = server.baseURL + "/.well-known/openid-configuration"
        config = c
    }

    /// The system browser: records the authorization request and calls the
    /// loopback redirect as OpenAI would after consent.
    func browser(issued: String = "oaiapp_ycode_test", deny: Bool = false, wrongState: Bool = false) -> @Sendable (URL) -> Bool {
        let state = self.state
        return { url in
            let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            state["authorize"] = url.absoluteString
            state["nonce"] = q["nonce"]
            state["challenge"] = q["code_challenge"]
            state["redirect_uri"] = q["redirect_uri"]
            state["code"] = "code-" + UUID().uuidString
            var items = [URLQueryItem(name: "state", value: wrongState ? "forged" : q["state"])]
            if deny { items.append(.init(name: "error", value: "access_denied")) } else {
                items.append(.init(name: "code", value: state["code"]))
                if q["client_id"] == OpenAIAuthConfiguration.registrationClientID { items.append(.init(name: "client_id", value: issued)) }
            }
            var c = URLComponents(string: q["redirect_uri"]!)!
            c.queryItems = items
            let target = c.url!
            Task.detached { _ = try? await HTTP.send(URLRequest(url: target), timeout: 10) }
            return true
        }
    }
}

@Suite struct OpenAIAccountTests {
    @Test func pkceMatchesRFC7636Example() {
        let p = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(p.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(SecureRandom.token(32).count == 43)
    }

    @Test func sha256Vectors() {
        func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
        #expect(hex(SHA256.hash(Data())) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(hex(SHA256.hash(Data("abc".utf8))) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(hex(SHA256.hash(Data(String(repeating: "a", count: 1000).utf8))) == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    @Test func authorizationURLCarriesTheDocumentedParameters() throws {
        let c = OpenAIAuthConfiguration()
        let reg = OpenAIRegistration(hostID: "urn:uuid:5f1c0f4e-0000-4000-8000-000000000001")
        let a = AuthorizationAttempt(redirectURI: "http://127.0.0.1:50123/auth/callback", clientID: OpenAIAuthConfiguration.registrationClientID)
        let url = try #require(OpenAIAccount.authorizationURL(c, attempt: a, registration: reg))
        #expect(url.absoluteString.hasPrefix("https://auth.openai.com/api/accounts/authorize?"))
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        #expect(q["client_id"] == "dynamic_agent_client")
        #expect(q["agent_name_hint"] == "Ycode")
        #expect(q["ext_agent_host_id"] == reg.hostID)
        #expect(q["response_type"] == "code")
        #expect(q["redirect_uri"] == "http://127.0.0.1:50123/auth/callback")
        #expect(q["scope"] == "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
        #expect(q["resource"] == "https://api.openai.com/v1")
        #expect(q["code_challenge_method"] == "S256" && q["code_challenge"] == a.pkce.challenge)
        #expect(q["state"] == a.state && q["nonce"] == a.nonce)
        #expect(!url.absoluteString.contains(" ") && url.absoluteString.contains("scope=openid%20profile"))
        // Returning sign-in: the issued ID, no name hint, the email as login hint.
        var known = reg
        known.clientID = "oaiapp_x"
        known.email = "dev@example.test"
        let b = AuthorizationAttempt(redirectURI: a.redirectURI, clientID: "oaiapp_x")
        let q2 = URLComponents(url: OpenAIAccount.authorizationURL(c, attempt: b, registration: known)!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(!q2.contains { $0.name == "agent_name_hint" })
        #expect(q2.first { $0.name == "client_id" }?.value == "oaiapp_x")
        #expect(q2.first { $0.name == "login_hint" }?.value == "dev@example.test")
    }

    @Test func callbackValidation() throws {
        let reg = AuthorizationAttempt(redirectURI: "http://127.0.0.1:1/auth/callback", clientID: OpenAIAuthConfiguration.registrationClientID)
        #expect(try OpenAIAccount.validateCallback(["state": reg.state, "code": "c", "client_id": "oaiapp_1"], attempt: reg) == ("c", "oaiapp_1"))
        #expect(throws: AssistantError.self) { try OpenAIAccount.validateCallback(["state": "x", "code": "c", "client_id": "oaiapp_1"], attempt: reg) }
        #expect(throws: AssistantError.signIn("Sign-in was cancelled.")) { try OpenAIAccount.validateCallback(["state": reg.state, "error": "access_denied"], attempt: reg) }
        // A registration callback must carry the issued ID, never the placeholder.
        #expect(throws: AssistantError.self) { try OpenAIAccount.validateCallback(["state": reg.state, "code": "c"], attempt: reg) }
        #expect(throws: AssistantError.self) {
            try OpenAIAccount.validateCallback(["state": reg.state, "code": "c", "client_id": "dynamic_agent_client"], attempt: reg)
        }
        let again = AuthorizationAttempt(redirectURI: reg.redirectURI, clientID: "oaiapp_1")
        #expect(try OpenAIAccount.validateCallback(["state": again.state, "code": "c"], attempt: again) == ("c", "oaiapp_1"))
        #expect(throws: AssistantError.self) { try OpenAIAccount.validateCallback(["state": again.state, "code": "c", "client_id": "oaiapp_2"], attempt: again) }
    }

    @Test func idTokenClaims() throws {
        let signer = try TestSigner()
        let now = Int(Date().timeIntervalSince1970)
        let good = signer.sign(["iss": "https://i", "aud": ["c1"], "sub": "s", "nonce": "n", "exp": now + 60])
        #expect(try IDToken.validate(good, issuer: "https://i", clientID: "c1", nonce: "n").subject == "s")
        #expect(throws: AssistantError.self) { try IDToken.validate(good, issuer: "https://other", clientID: "c1", nonce: "n") }
        #expect(throws: AssistantError.self) { try IDToken.validate(good, issuer: "https://i", clientID: "c2", nonce: "n") }
        #expect(throws: AssistantError.self) { try IDToken.validate(good, issuer: "https://i", clientID: "c1", nonce: "other") }
        let expired = signer.sign(["iss": "https://i", "aud": "c1", "sub": "s", "nonce": "n", "exp": now - 3600])
        #expect(throws: AssistantError.self) { try IDToken.validate(expired, issuer: "https://i", clientID: "c1", nonce: "n") }
    }

    /// The whole flow against stand-ins: loopback redirect, PKCE exchange,
    /// ID token (signature checked on macOS), storage, refresh, sign-out.
    @Test func signInRefreshAndSignOut() async throws {
        let issuer = try StandInIssuer()
        let store = MemorySecretStore()
        let account = OpenAIAccount(configuration: issuer.config, store: store, verifier: TestSigner.verifier, openURL: issuer.browser())
        await account.setSignInTimeout(10)
        let t = try await account.signIn()
        #expect(t.clientID == "oaiapp_ycode_test" && t.subject == "user-123" && t.email == "dev@example.test")
        #expect(t.accessToken == "at-1" && t.refreshToken == "rt-1" && t.hasPlanUsage)
        #expect(await account.status == .signedIn(email: "dev@example.test", planUsage: true))
        let reg = try #require(store.readJSON(OpenAIRegistration.self, SecretAccount.openAIRegistration))
        #expect(reg.clientID == "oaiapp_ycode_test" && reg.hostID.hasPrefix("urn:uuid:"))
        // The redirect used the loopback address and the documented path.
        #expect(issuer.state["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)
        #expect(issuer.state["redirect_uri"]?.hasSuffix("/auth/callback") == true)

        #expect(try await account.accessToken() == "at-1")
        #expect(try await account.accessToken(forceRefresh: true) == "at-2")
        #expect(store.readJSON(OpenAITokens.self, SecretAccount.openAITokens)?.refreshToken == "rt-2")

        // Second sign-in reuses the issued client ID (no registration).
        let again = try await account.signIn()
        #expect(again.clientID == "oaiapp_ycode_test")
        #expect(issuer.state["authorize"]?.contains("client_id=oaiapp_ycode_test") == true)
        #expect(issuer.state["authorize"]?.contains("agent_name_hint") == false)

        #expect(await account.signOut())
        #expect(await account.status == .signedOut)
        #expect(store.readJSON(OpenAITokens.self, SecretAccount.openAITokens) == nil)
        #expect(store.readJSON(OpenAIRegistration.self, SecretAccount.openAIRegistration)?.clientID == "oaiapp_ycode_test")
        let revoke = try #require(issuer.rec.requests.last { $0.path == "/revoke" })
        #expect(revoke.form["token_type_hint"] == "refresh_token" && revoke.form["client_id"] == "oaiapp_ycode_test")
    }

    @Test func declinedAndForgedCallbacks() async throws {
        let issuer = try StandInIssuer()
        let denied = OpenAIAccount(configuration: issuer.config, store: MemorySecretStore(), openURL: issuer.browser(deny: true))
        await #expect(throws: AssistantError.signIn("Sign-in was cancelled.")) { try await denied.signIn() }
        let forged = OpenAIAccount(configuration: issuer.config, store: MemorySecretStore(), openURL: issuer.browser(wrongState: true))
        await #expect(throws: AssistantError.self) { try await forged.signIn() }
        let noBrowser = OpenAIAccount(configuration: issuer.config, store: MemorySecretStore()) { _ in false }
        await #expect(throws: AssistantError.signIn("Ycode could not open the browser.")) { try await noBrowser.signIn() }
        let silent = OpenAIAccount(configuration: issuer.config, store: MemorySecretStore()) { _ in true }
        await silent.setSignInTimeout(0.3)
        await #expect(throws: AssistantError.signIn("Sign-in timed out. Try again.")) { try await silent.signIn() }
    }

    @Test func grantWithoutPlanScopeIsReported() async throws {
        let issuer = try StandInIssuer(scope: "openid profile email offline_access")
        let store = MemorySecretStore()
        let account = OpenAIAccount(configuration: issuer.config, store: store, verifier: TestSigner.verifier, openURL: issuer.browser())
        let t = try await account.signIn()
        #expect(!t.hasPlanUsage)
        guard case .failed(let m) = await OpenAIProvider(credential: .account(account)).availability() else { Issue.record("expected failed"); return }
        #expect(m.contains("plan usage isn't enabled"))
    }

    @Test func unusableRefreshTokenSignsOut() async throws {
        let issuer = try StandInIssuer()
        let store = MemorySecretStore()
        try store.writeJSON(OpenAITokens(clientID: "oaiapp_ycode_test", subject: "s", email: nil, accessToken: "old", refreshToken: "rt-dead",
                                         idToken: nil, tokenType: "Bearer", expiresAt: Date().addingTimeInterval(-10), scopes: [], savedAt: Date()),
                            for: SecretAccount.openAITokens)
        let account = OpenAIAccount(configuration: issuer.config, store: store) { _ in false }
        await #expect(throws: AssistantError.self) { _ = try await account.accessToken() }
        #expect(store.readJSON(OpenAITokens.self, SecretAccount.openAITokens) == nil)
    }

    #if canImport(Security)
    @Test func signatureMismatchIsRejected() async throws {
        let issuer = try StandInIssuer()
        let other = try TestSigner()
        let jwt = other.sign(["iss": "x"])
        await #expect(throws: AssistantError.signIn("The ID token's signature does not verify.")) {
            try await JWKSSignatureVerifier().verify(jwt, discoveryURL: URL(string: issuer.config.discoveryURL)!)
        }
        let good = issuer.signer.sign(["iss": "x"])
        try await JWKSSignatureVerifier().verify(good, discoveryURL: URL(string: issuer.config.discoveryURL)!)
    }
    #endif
}
