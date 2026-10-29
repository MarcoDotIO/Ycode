// Ycode's own guest images on a runtime of another platform (visionos.md
// §7.2 R1). The host libraries, the headless framebuffer library and the HID
// bundle are linked for the iOS simulator (platform 7; host-libraries.md,
// SimGuestFrameworks/build.sh). dyld_sim loads an image into a process only
// when the image is built for the process platform (host-library-loading.md
// §2.1; an iOS-simulator process may also load visionOS-simulator images,
// not the reverse), so on a visionOS runtime (platform 12) each of them
// needs a copy whose `LC_BUILD_VERSION` names visionOS simulator. The code is
// the same: the visionOS runtime's libraries are separate builds with the
// same exported names (visionos.md §3.4), and Ycode's images import nothing
// platform-specific. The linker in use (LLD 21) cannot write the visionOS
// simulator platform, so the copy is made here, by rewriting the one load
// command; the images carry no code signature that would cover it.
//
// Format facts (public <mach-o/loader.h>): mach_header_64 is 32 bytes (magic
// 0xFEEDFACF, ncmds at 16, sizeofcmds at 20); a load command starts with
// cmd, cmdsize; LC_BUILD_VERSION (0x32) has platform, minos, sdk at 8, 12,
// 16 (versions packed as xxxx.yy.zz); LC_CODE_SIGNATURE is 0x1D.

import Foundation

enum GuestImagePlatform {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// A packed Mach-O version (major << 16 | minor << 8 | patch) from "27.0" or "27.0.1".
    static func packedVersion(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".").map { UInt32($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        let p = parts.map { $0! } + Array(repeating: 0, count: 3 - parts.count)
        guard p[0] <= 0xFFFF, p[1] <= 0xFF, p[2] <= 0xFF else { return nil }
        return p[0] << 16 | p[1] << 8 | p[2]
    }

    /// The image with its `LC_BUILD_VERSION` naming `platform`, `minOS` and
    /// `sdk`. A thin little-endian 64-bit image with exactly one build-version
    /// command and no code signature; anything else is refused.
    static func retagged(_ image: Data, platform: UInt32, minOS: UInt32, sdk: UInt32) throws -> Data {
        var bytes = [UInt8](image)
        func u32(_ at: Int) -> UInt32 {
            UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        func put(_ v: UInt32, _ at: Int) { for i in 0..<4 { bytes[at + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) } }
        guard bytes.count >= 32, u32(0) == 0xFEED_FACF else { throw Failure(description: "not a thin 64-bit Mach-O image") }
        let ncmds = Int(u32(16)), sizeofcmds = Int(u32(20))
        guard 32 + sizeofcmds <= bytes.count else { throw Failure(description: "load commands run past the end") }
        var at = 32, found: Int?
        for _ in 0..<ncmds {
            guard at + 8 <= 32 + sizeofcmds else { throw Failure(description: "truncated load command") }
            let cmd = u32(at), size = Int(u32(at + 4))
            guard size >= 8, at + size <= 32 + sizeofcmds else { throw Failure(description: "bad load command size") }
            if cmd == 0x1D { throw Failure(description: "the image is signed; its signature would no longer match") }
            if cmd == 0x32 {
                guard found == nil else { throw Failure(description: "more than one LC_BUILD_VERSION") }
                guard size >= 24 else { throw Failure(description: "short LC_BUILD_VERSION") }
                found = at
            }
            at += size
        }
        guard let command = found else { throw Failure(description: "no LC_BUILD_VERSION") }
        put(platform, command + 8)
        put(minOS, command + 12)
        put(sdk, command + 16)
        return Data(bytes)
    }

    /// The platform of a thin 64-bit image (its LC_BUILD_VERSION), or nil.
    static func platform(of image: Data) -> UInt32? {
        let b = [UInt8](image)
        func u32(_ at: Int) -> UInt32 {
            UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
        }
        guard b.count >= 32, u32(0) == 0xFEED_FACF else { return nil }
        var at = 32
        for _ in 0..<Int(u32(16)) {
            guard at + 12 <= b.count else { return nil }
            let size = Int(u32(at + 4))
            if u32(at) == 0x32 { return u32(at + 8) }
            guard size >= 8 else { return nil }
            at += size
        }
        return nil
    }

    /// Rewrites the file at `path` in place for `runtime` (nothing for iOS).
    /// The file is written only when its bytes change, so a restored device
    /// whose processes have it open keeps the same file.
    static func adapt(fileAt path: String, for runtime: RuntimePlatform, version: String) throws {
        guard runtime != .iOS else { return }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw Failure(description: "cannot read \(path)")
        }
        let v = packedVersion(version) ?? 27 << 16
        let out = try retagged(data, platform: runtime.machOPlatform, minOS: v, sdk: v)
        if out != data { try out.write(to: URL(fileURLWithPath: path), options: .atomic) }
    }

    /// A copy of `source` adapted for `runtime` at `target` (made or
    /// refreshed only when its bytes differ); the target path.
    static func adaptedCopy(of source: String, to target: String, for runtime: RuntimePlatform, version: String) throws -> String {
        guard let data = FileManager.default.contents(atPath: source) else {
            throw Failure(description: "cannot read \(source)")
        }
        let v = packedVersion(version) ?? 27 << 16
        let out = try retagged(data, platform: runtime.machOPlatform, minOS: v, sdk: v)
        let fm = FileManager.default
        if fm.contents(atPath: target) != out {
            try fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try out.write(to: URL(fileURLWithPath: target), options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target)
        }
        return target
    }
}
