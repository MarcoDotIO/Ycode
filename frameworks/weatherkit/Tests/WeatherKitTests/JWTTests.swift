// C-JWT (plan.md §2): developer tokens (rest-api.md §2), signed with a
// locally generated P-256 key, verified with swift-crypto and, when the
// openssl tool is installed, independently with it.
import Crypto
import Foundation
import Testing
@testable import WeatherKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("C-JWT: developer tokens (rest-api.md §2)")
struct JWTTests {
    let key = P256.Signing.PrivateKey()
    let issued = Date(timeIntervalSince1970: 1_768_478_400.75)

    func token(lifetime: TimeInterval = 3600) throws -> String {
        try DeveloperToken.sign(
            teamID: "TEAM123456", serviceID: "dev.example.weather", keyID: "KEY1234567", key: key, issuedAt: issued,
            lifetime: lifetime)
    }

    @Test("rest-api.md §2: header is exactly {alg: ES256, kid, id: team.service}")
    func header() throws {
        let decoded = try DeveloperToken.decode(try token())
        #expect(Set(decoded.header.keys) == ["alg", "kid", "id"])
        #expect(decoded.header["alg"] as? String == "ES256")
        #expect(decoded.header["kid"] as? String == "KEY1234567")
        #expect(decoded.header["id"] as? String == "TEAM123456.dev.example.weather")
    }

    @Test("rest-api.md §2: claims are exactly {iss, iat, exp, sub}, times in Unix seconds")
    func claims() throws {
        let decoded = try DeveloperToken.decode(try token(lifetime: 1800))
        #expect(Set(decoded.claims.keys) == ["iss", "iat", "exp", "sub"])
        #expect(decoded.claims["iss"] as? String == "TEAM123456")
        #expect(decoded.claims["sub"] as? String == "dev.example.weather")
        #expect(decoded.claims["iat"] as? Int == 1_768_478_400)
        #expect(decoded.claims["exp"] as? Int == 1_768_480_200)
    }

    @Test("rest-api.md §2: three base64url parts without padding")
    func encoding() throws {
        let text = try token()
        #expect(text.split(separator: ".", omittingEmptySubsequences: false).count == 3)
        #expect(!text.contains("="))
        #expect(!text.contains("+"))
        #expect(!text.contains("/"))
        #expect(try DeveloperToken.decode(text).signature.count == 64)
    }

    @Test("rest-api.md §2: the ES256 signature verifies with swift-crypto; a changed token does not")
    func verifiesWithSwiftCrypto() throws {
        let decoded = try DeveloperToken.decode(try token())
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decoded.signature)
        #expect(key.publicKey.isValidSignature(signature, for: decoded.signingInput))
        var tampered = decoded.signingInput
        tampered[tampered.startIndex] ^= 0x01
        #expect(!key.publicKey.isValidSignature(signature, for: tampered))
        #expect(!P256.Signing.PrivateKey().publicKey.isValidSignature(signature, for: decoded.signingInput))
    }

    static let openssl: String? = ["/usr/bin/openssl", "/usr/local/bin/openssl", "/opt/homebrew/bin/openssl"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    @Test("rest-api.md §2: the signature verifies with an independent tool (openssl)",
          .enabled(if: JWTTests.openssl != nil, "openssl not installed"))
    func verifiesWithOpenSSL() throws {
        let decoded = try DeveloperToken.decode(try token())
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decoded.signature)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-jwt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let publicKey = directory.appendingPathComponent("public.pem")
        let signatureFile = directory.appendingPathComponent("signature.der")
        let input = directory.appendingPathComponent("input.txt")
        try Data(key.publicKey.pemRepresentation.utf8).write(to: publicKey)
        try signature.derRepresentation.write(to: signatureFile)
        try decoded.signingInput.write(to: input)

        func verify(_ file: URL) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: JWTTests.openssl!)
            process.arguments = ["dgst", "-sha256", "-verify", publicKey.path, "-signature", signatureFile.path, file.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        let (status, output) = try verify(input)
        #expect(status == 0)
        #expect(output.contains("Verified OK"))
        let other = directory.appendingPathComponent("other.txt")
        try Data("not the token".utf8).write(to: other)
        #expect(try verify(other).0 != 0)
    }

    @Test("Signing provider: reads a PKCS#8 .p8 file and reuses a token until a minute before exp")
    func signingProvider() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-jwt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("AuthKey_KEY1234567.p8")
        try Data(key.pemRepresentation.utf8).write(to: file)
        #expect(key.pemRepresentation.hasPrefix("-----BEGIN PRIVATE KEY-----"))

        let clock = TestClock(issued)
        let provider = try SigningWeatherTokenProvider(
            teamID: "TEAM123456", serviceID: "dev.example.weather", keyID: "KEY1234567", privateKeyFile: file,
            lifetime: 600, clock: { clock.now })
        let first = try await provider.token()
        clock.advance(539)
        #expect(try await provider.token() == first)
        clock.advance(1)
        let second = try await provider.token()
        #expect(second != first)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: try DeveloperToken.decode(second).signature)
        #expect(key.publicKey.isValidSignature(signature, for: try DeveloperToken.decode(second).signingInput))
        #expect(throws: (any Error).self) {
            _ = try SigningWeatherTokenProvider(teamID: "T", serviceID: "S", keyID: "K", privateKeyPEM: "not a key")
        }
    }

    @Test("Remote provider: token from the developer's URL (text or {token}), cached until exp; failures deny")
    func remoteProvider() async throws {
        let issuedToken = try token(lifetime: 3600)
        let http = MockHTTPClient { request in
            #expect(request.url?.absoluteString == "https://tokens.example.invalid/weatherkit")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return (200, Data(#"{"token": "\#(issuedToken)"}"#.utf8))
        }
        let clock = TestClock(issued)
        let provider = RemoteWeatherTokenProvider(
            url: URL(string: "https://tokens.example.invalid/weatherkit")!, httpClient: http, clock: { clock.now })
        #expect(try await provider.token() == issuedToken)
        #expect(try await provider.token() == issuedToken)
        #expect(http.requests.count == 1)
        clock.advance(3600)
        _ = try await provider.token()
        #expect(http.requests.count == 2)

        let plain = MockHTTPClient { _ in (200, Data((issuedToken + "\n").utf8)) }
        #expect(try await RemoteWeatherTokenProvider(url: URL(string: "https://t.invalid")!, httpClient: plain, clock: { clock.now }).token() == issuedToken)

        let refused = MockHTTPClient { _ in (403, Data()) }
        let backend = AppleRESTWeatherBackend(
            tokenProvider: RemoteWeatherTokenProvider(url: URL(string: "https://t.invalid")!, httpClient: refused),
            httpClient: MockHTTPClient { _ in (200, Data()) })
        let service = WeatherService(backend: backend, configuration: .init(language: "en-US"))
        await #expect(throws: WeatherError.permissionDenied) {
            _ = try await service.weather(for: fixtureLocation, including: .current)
        }
    }
}

/// A scripted HTTP transport that records requests.
final class MockHTTPClient: WeatherHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let handler: @Sendable (URLRequest) throws -> (Int, Data)

    init(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) { self.handler = handler }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        let (status, body) = try handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (body, response)
    }
}
