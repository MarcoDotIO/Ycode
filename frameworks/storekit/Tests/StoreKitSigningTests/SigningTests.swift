// C-FORMATS (plan.md §4) part 1: DER, the per-device identity, JWS and its
// verification (formats.md §2.1; plan.md §3.2 "JWS header", "simulated invalid signature").
import Crypto
import Foundation
import Testing
import StoreKitConfiguration
import StoreKitEngine
@testable import StoreKitSigning

@Suite("DER (X.690)")
struct DERTests {
    @Test("Integers, OIDs, lengths, times and named bits encode as DER")
    func encodings() throws {
        #expect(DER.integer(0) == [0x02, 0x01, 0x00])
        #expect(DER.integer(127) == [0x02, 0x01, 0x7F])
        #expect(DER.integer(128) == [0x02, 0x02, 0x00, 0x80])
        #expect(DER.integer(256) == [0x02, 0x02, 0x01, 0x00])
        #expect(DER.integer(-1) == [0x02, 0x01, 0xFF])
        #expect(DER.integer(1701) == [0x02, 0x02, 0x06, 0xA5])
        #expect(DER.oid("1.2.840.10045.4.3.2") == [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
        #expect(DER.octetString([UInt8](repeating: 0, count: 200)).prefix(3) == [0x04, 0x81, 0xC8])
        #expect(DER.octetString([UInt8](repeating: 0, count: 300)).prefix(4) == [0x04, 0x82, 0x01, 0x2C])
        #expect(DER.time(referenceStart) == DER.tlv(0x17, Array("261019120000Z".utf8)))
        #expect(DER.time(Date(timeIntervalSince1970: 2_524_608_000)) == DER.tlv(0x18, Array("20500101000000Z".utf8)))
        #expect(DER.namedBits([0]) == [0x03, 0x02, 0x07, 0x80])
        #expect(DER.namedBits([0, 5, 6]) == [0x03, 0x02, 0x01, 0x86])
        let parsed = try DERElement.parse(DER.sequence([DER.integer(1701), DER.oid("2.5.4.3"), DER.utf8String("é")]))
        let kids = try parsed.children()
        #expect(kids[0].intValue == 1701 && kids[1].oidValue == "2.5.4.3" && kids[2].stringValue == "é")
        #expect(try DERElement.parse(DER.time(referenceStart)).dateValue == referenceStart)
        #expect(throws: DERError.self) { try DERElement.parse([0x30, 0x05, 0x01]) }
    }
}

@Suite("Signing identity (formats.md §2.1)")
struct IdentityTests {
    @Test("A self-signed P-256 certificate 'StoreKit Testing in Xcode', valid one year, with the three extensions")
    func deviceCertificate() throws {
        let id = try SigningIdentity.generate(now: referenceStart.addingTimeInterval(0.75))
        let c = id.certificate
        #expect(c.subject.description == "CN=StoreKit Testing in Xcode, O=StoreKit Testing in Xcode")
        #expect(c.issuer == c.subject)
        #expect(c.notBefore == referenceStart)
        #expect(c.notAfter == Date(timeIntervalSince1970: 1_823_947_200))  // 2027-10-19 12:00:00 UTC
        #expect(c.signatureAlgorithm == "1.2.840.10045.4.3.2")
        #expect(c.isSigned(by: c.publicKey))
        #expect(c.isCA == false)
        #expect(c.extensions == ["2.5.29.19", "2.5.29.17", "2.5.29.15", "2.5.29.14"])
        #expect(c.criticalExtensions == ["2.5.29.19", "2.5.29.15"])
        #expect(c.publicKeyDER == Array(id.privateKey.publicKey.derRepresentation))
        #expect(id.certificates.count == 1)
        #expect(c.pem.hasPrefix("-----BEGIN CERTIFICATE-----\n"))
    }

    @Test("simulator-baseline.md §5: the identity is created once per device and shared by every app")
    func persistence() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try SigningIdentity.deviceJWSIdentity(directory: dir, now: referenceStart)
        let b = try SigningIdentity.deviceJWSIdentity(directory: dir, now: referenceStart.addingTimeInterval(86_400))
        #expect(a.certificate.der == b.certificate.der)
        #expect(a.privateKey.rawRepresentation == b.privateKey.rawRepresentation)
        let other = try SigningIdentity.deviceJWSIdentity(directory: temporaryDirectory(), now: referenceStart)
        #expect(other.certificate.der != a.certificate.der)
    }

    @Test("OpenSSL reads the certificate (subject, self-signature, extensions)", .enabled(if: hasOpenSSL3))
    func openSSLCertificate() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try SigningIdentity.generate(now: referenceStart)
        let pem = dir.appendingPathComponent("cert.pem")
        try id.certificate.pem.write(to: pem, atomically: true, encoding: .utf8)
        let text = try #require(openssl(["x509", "-in", pem.path, "-noout", "-subject", "-issuer", "-text"]))
        #expect(text.status == 0)
        #expect(text.output.contains("subject=CN=StoreKit Testing in Xcode, O=StoreKit Testing in Xcode"))
        #expect(text.output.contains("X509v3 Basic Constraints: critical"))
        #expect(text.output.contains("X509v3 Key Usage: critical"))
        #expect(text.output.contains("DNS:storekit-testing.invalid"))
        #expect(text.output.contains("ASN1 OID: prime256v1"))
        let verify = try #require(openssl(["verify", "-CAfile", pem.path, "-attime", "1792500000", pem.path]))
        #expect(verify.output.contains(": OK"))
    }
}

@Suite("JWS (formats.md §2.1; RFC 7515/7518)")
struct JWSTests {
    let identity: SigningIdentity

    init() throws { identity = try SigningIdentity.generate(now: referenceStart) }

    @Test("Header: ES256, kid Apple_Xcode_Key, typ JWT, one certificate; 64-byte r‖s signature that verifies")
    func header() throws {
        let jws = try JWS.sign(.object(["a": .int(1)]), identity: identity)
        let d = try JWSVerifier().verify(jws)
        #expect(d.header == .object([
            "alg": .string("ES256"), "kid": .string("Apple_Xcode_Key"), "typ": .string("JWT"),
            "x5c": .array([.string(Data(identity.certificate.der).base64EncodedString())]),
        ]))
        #expect(d.signature.count == 64)
        #expect(d.certificates.map(\.der) == [identity.certificate.der])
        #expect(String(decoding: d.payloadData, as: UTF8.self) == "{\"a\":1}")
        // Three base64url parts without padding.
        let parts = jws.split(separator: ".")
        #expect(parts.count == 3 && !jws.contains("=") && !jws.contains("+") && !jws.contains("/"))
        #expect(String(decoding: Base64URL.decode(parts[0])!, as: UTF8.self).hasPrefix("{\"alg\":\"ES256\",\"kid\":\"Apple_Xcode_Key\",\"typ\":\"JWT\",\"x5c\":["))
    }

    @Test("testing-session.md §9: a corrupted signature really fails; tampering is detected; malformed input is an encoding error")
    func failures() throws {
        let bad = try JWS.sign(.object(["a": .int(1)]), identity: identity, corruptSignature: true)
        #expect(failureReason { _ = try JWSVerifier().verify(bad) } == .invalidSignature)
        let good = try JWS.sign(.object(["a": .int(1)]), identity: identity)
        var parts = good.split(separator: ".").map(String.init)
        parts[1] = Base64URL.encode(Data("{\"a\":2}".utf8))
        #expect(failureReason { _ = try JWSVerifier().verify(parts.joined(separator: ".")) } == .invalidSignature)
        #expect(failureReason { _ = try JWSVerifier().verify("abc.def") } == .invalidEncoding)
        let noX5c = Base64URL.encode(Data("{\"alg\":\"ES256\"}".utf8)) + "." + Base64URL.encode(Data("{}".utf8)) + "."
            + Base64URL.encode(Data(repeating: 1, count: 64))
        #expect(failureReason { _ = try JWSVerifier().verify(noX5c) } == .missingRequiredProperties)
        #expect(failureReason { _ = try JWSVerifier(requiredPayloadKeys: ["transactionId"]).verify(good) } == .missingRequiredProperties)
    }

    @Test("A chain issued by a Ycode test CA verifies against that root only, and only inside the validity period")
    func chains() throws {
        let ca = try SigningIdentity.generate(subject: DistinguishedName([(.commonName, "Ycode Test CA")]), now: referenceStart,
                                              validityYears: 5, isCA: true)
        #expect(ca.certificate.isCA == true)
        let leaf = try SigningIdentity.generate(now: referenceStart, issuer: ca)
        #expect(leaf.certificates.count == 2 && leaf.certificate.issuer.description == "CN=Ycode Test CA")
        #expect(leaf.certificate.isSigned(by: ca.certificate.publicKey))
        let jws = try JWS.sign(.object(["x": .bool(true)]), identity: leaf)
        _ = try JWSVerifier(trustedRoots: [ca.certificate], date: referenceStart.addingTimeInterval(3600)).verify(jws)
        let otherCA = try SigningIdentity.generate(subject: DistinguishedName([(.commonName, "Other CA")]), now: referenceStart, isCA: true)
        #expect(failureReason { _ = try JWSVerifier(trustedRoots: [otherCA.certificate]).verify(jws) } == .invalidCertificateChain)
        #expect(failureReason { _ = try JWSVerifier(trustedRoots: [ca.certificate], date: referenceStart.addingTimeInterval(2 * 366 * 86_400)).verify(jws) } == .invalidCertificateChain)
        // The self-signed device certificate verifies when it is itself trusted.
        let selfSigned = try JWS.sign(.object([:]), identity: identity)
        _ = try JWSVerifier(trustedRoots: [identity.certificate]).verify(selfSigned)
        #expect(failureReason { _ = try JWSVerifier(trustedRoots: [ca.certificate]).verify(selfSigned) } == .invalidCertificateChain)
    }

    @Test("plan.md R8: the JWS signature verifies with OpenSSL; the corrupted one does not", .enabled(if: hasOpenSSL3))
    func openSSL() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, corrupt) in [("good", false), ("bad", true)] {
            let jws = try JWS.sign(.object(["transactionId": .string("0")]), identity: identity, corruptSignature: corrupt)
            let d = try JWS.decode(jws)
            let input = dir.appendingPathComponent("\(name).input")
            let sig = dir.appendingPathComponent("\(name).sig")
            let pub = dir.appendingPathComponent("pub.pem")
            let cert = dir.appendingPathComponent("cert.pem")
            try d.signingInput.write(to: input)
            try P256.Signing.ECDSASignature(rawRepresentation: d.signature).derRepresentation.write(to: sig)
            try d.certificates[0].pem.write(to: cert, atomically: true, encoding: .utf8)
            _ = openssl(["x509", "-in", cert.path, "-pubkey", "-noout", "-out", pub.path])
            let r = try #require(openssl(["dgst", "-sha256", "-verify", pub.path, "-signature", sig.path, input.path]))
            #expect(r.output.contains(corrupt ? "Verification failure" : "Verified OK"))
        }
    }
}
