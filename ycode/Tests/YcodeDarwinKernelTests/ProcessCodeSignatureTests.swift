import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// `executable_cdhash=` / `executable_boothash=` (`darwin-process-start.md` §1.4).
@Suite struct ProcessCodeSignatureTests {
    @Test func digests() {
        func hex(_ b: [UInt8]) -> String { CodeSignature.hexString(b) }
        #expect(hex(SHA256Digest.hash(Array("abc".utf8))) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(hex(SHA256Digest.hash([])) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        let long = Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)
        #expect(hex(SHA256Digest.hash(long)) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        #expect(hex(SHA1Digest.hash(Array("abc".utf8))) == "a9993e364706816aba3e25717850c26c9cd0d89d")
    }

    /// A thin arm64 MH_EXECUTE with LC_CODE_SIGNATURE → a SuperBlob holding
    /// a SHA-1 CodeDirectory (slot 0) and a SHA-256 one (slot 0x1000).
    static func signedImage() -> (file: [UInt8], sha256CD: [UInt8]) {
        func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func cd(hashType: UInt8, fill: UInt8) -> [UInt8] {
            var b = [UInt8](repeating: fill, count: 88)
            b.replaceSubrange(0..<4, with: be(0xFADE_0C02))
            b.replaceSubrange(4..<8, with: be(88))
            b[37] = hashType
            return b
        }
        let cd1 = cd(hashType: 1, fill: 0x11), cd2 = cd(hashType: 2, fill: 0x22)
        var blob = be(0xFADE_0CC0) + be(UInt32(12 + 16 + cd1.count + cd2.count)) + be(2)
        blob += be(0) + be(28) + be(0x1000) + be(UInt32(28 + cd1.count))
        blob += cd1 + cd2
        var file: [UInt8] = []
        for v: UInt32 in [0xFEED_FACF, 0x0100_000C, 0, 2, 1, 16, 0, 0] { file.appendLE(v) }
        for v: UInt32 in [0x1D, 16, 0x100, UInt32(blob.count)] { file.appendLE(v) }
        file += [UInt8](repeating: 0, count: 0x100 - file.count)
        return (file + blob, cd2)
    }

    @Test func cdHashAndBoothash() throws {
        let (bytes, cd) = Self.signedImage()
        let path = NSTemporaryDirectory() + "ycode-cdhash-\(UUID().uuidString)"
        try Data(bytes).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let hash = try #require(CodeSignature.cdHash(ofExecutableAt: path))
        #expect(hash == Array(SHA256Digest.hash(cd).prefix(20)))  // the SHA-256 CodeDirectory wins
        let strings = CodeSignature.appleStrings(hostPath: path, bootSalt: 7, bootSessionUUID: "00000000-0000-0000-0000-000000000000")
        #expect(strings.count == 2)
        #expect(strings[0] == "executable_cdhash=" + CodeSignature.hexString(hash))
        #expect(strings[1].hasPrefix("executable_boothash=") && strings[1].count == "executable_boothash=".count + 40)
        // An unsigned image gets neither string.
        let plain = NSTemporaryDirectory() + "ycode-cdhash-\(UUID().uuidString)"
        try Data(ProcEnv.machO()).write(to: URL(fileURLWithPath: plain))
        defer { try? FileManager.default.removeItem(atPath: plain) }
        #expect(CodeSignature.appleStrings(hostPath: plain, bootSalt: 7, bootSessionUUID: "x").isEmpty)
    }

    @Test func spawnedImagesCarryTheHashes() throws {
        let env = try ProcEnv()
        try Data(Self.signedImage().file).write(to: URL(fileURLWithPath: env.root + "/signed"))
        let pid = env.spawn(from: env.rootKernel, path: env.root + "/signed").pid
        #expect(pid > 0)
        let apple = try #require(env.launcher.launches.last?.request.apple)
        #expect(apple.contains { $0.hasPrefix("executable_boothash=") })
        #expect(apple.contains { $0.hasPrefix("executable_cdhash=") })
    }
}
