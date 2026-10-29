import YcodeDarwinABI

// Sandbox extensions (specs/simulator/sandbox-extensions.md): the Sandbox
// policy's __mac_syscall calls that the runtime's libsystem_sandbox makes
// for sandbox_extension_issue_file (5), sandbox_extension_consume (6) and
// sandbox_extension_release (7). Ycode has no sandbox, so the answer is
// permissive, shaped as the Mac's simulator answers (level 3):
// - issue writes a NUL-terminated token into the output buffer (argument
//   word 4) and succeeds; the token has the Mac's field layout;
// - consume accepts a well-formed token (EINVAL otherwise), writes handle 0
//   to the 64-bit location word 2 points at, and succeeds;
// - release always succeeds.
enum SandboxCall {
    static let issueFile: Int32 = 5, consume: Int32 = 6, release: Int32 = 7
}

extension DarwinKernel {
    /// One Sandbox-policy call; nil when Ycode does not answer `op` (the
    /// caller then reports ENOPOLICY).
    func sandboxExtensionCall(_ op: Int32, arg: UInt64, _ mem: any KernelGuestMemory) throws -> UInt64? {
        switch op {
        case SandboxCall.issueFile:
            let raw = try mem.read(va: arg, count: 40)
            let extensionClass = try readString(raw.readLE(UInt64.self, at: 0), length: 1024, mem)
            let kind = raw.readLE(UInt64.self, at: 8)
            let pathPointer = raw.readLE(UInt64.self, at: 16)
            let out = raw.readLE(UInt64.self, at: 32)
            guard !extensionClass.isEmpty, out != 0 else { throw Failure(errno: Errno.EINVAL) }
            let token: String
            if kind != 0, pathPointer == 0 {
                // An issue of another kind with no path (word 1 nonzero;
                // tccd's kTCCServiceCamera extension has kind 3): a token
                // naming the class with an empty path (sandbox-extensions.md §4).
                token = Self.sandboxToken(extensionClass: extensionClass, path: nil, fileSystem: fileSystem)
            } else {
                guard pathPointer != 0 else { throw Failure(errno: Errno.EINVAL) }
                let path = try readString(pathPointer, length: 1024, mem)
                guard !path.isEmpty else { throw Failure(errno: Errno.EINVAL) }
                token = Self.sandboxToken(extensionClass: extensionClass, path: path, fileSystem: fileSystem)
            }
            guard token.utf8.count < 2048 else { throw Failure(errno: 63) }  // ENAMETOOLONG
            try mem.write(va: out, bytes: Array(token.utf8) + [0])
            return 0
        case SandboxCall.consume:
            let raw = try mem.read(va: arg, count: 24)
            let length = Int(min(raw.readLE(UInt64.self, at: 8), 4096))
            let token = try readString(raw.readLE(UInt64.self, at: 0), length: max(length, 1), mem)
            guard Self.isWellFormedSandboxToken(token) else { throw Failure(errno: Errno.EINVAL) }
            let handleOut = raw.readLE(UInt64.self, at: 16)
            if handleOut != 0 { try mem.write(va: handleOut, bytes: le64(0)) }
            return 0
        case SandboxCall.release:
            return 0
        default:
            return nil
        }
    }

    /// `<64 hex>;00;00000000;00000000;00000000;<16 hex class length>;<class>;
    /// <01 exists | 00>;<8 hex device>;<16 hex inode>;01;<path>`, the field
    /// layout of the Mac's tokens. The first field is a Ycode digest of the
    /// rest (nothing checks it: consume only checks the form).
    /// With no path (an extension that is not for a file): `00`, 0, 0 and
    /// an empty last field.
    static func sandboxToken(extensionClass: String, path: String?, fileSystem: DarwinFileSystem) -> String {
        func hex(_ v: UInt64, _ width: Int) -> String {
            let s = String(v, radix: 16)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        let resolved = path.map { (try? fileSystem.realpath($0)) ?? $0 } ?? ""
        let st = path == nil ? nil : try? fileSystem.stat(resolved, followSymlinks: true)
        let body = ["00", "00000000", "00000000", "00000000", hex(UInt64(extensionClass.utf8.count), 16), extensionClass,
                    st != nil ? "01" : "00", hex(UInt64(st?.dev ?? 0), 8), hex(st?.ino ?? 0, 16), "01", resolved]
            .joined(separator: ";")
        var digest = ""
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for round in 0..<4 {
            for b in body.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
            h ^= UInt64(round)
            digest += hex(h, 16)
        }
        return digest + ";" + body
    }

    /// At least 12 `;`-separated fields, the first 64 hex digits.
    static func isWellFormedSandboxToken(_ token: String) -> Bool {
        let fields = token.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 12, fields[0].utf8.count == 64 else { return false }
        return fields[0].utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
