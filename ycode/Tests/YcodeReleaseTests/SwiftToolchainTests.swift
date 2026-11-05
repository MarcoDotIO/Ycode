import Foundation
import Testing
import YcodeRelease

/// The Swift toolchain the `ycode-swb` helper names to swift-build on Linux
/// (`specs/xcodebuild/show-build-settings.md` §3). The file system and the
/// compiler are stand-ins, so every case runs on every host.
@Suite struct SwiftToolchainTests {
    static let swiftlyRoot = "/home/u/.local/share/swiftly/toolchains/6.4.2"

    static func targetInfo(runtime: String) -> Data {
        Data(#"{"target":{"triple":"x86_64-unknown-linux-gnu"},"paths":{"runtimeResourcePath":"\#(runtime)"}}"#.utf8)
    }

    @Test func aToolchainInAUsrFolderIsItsRoot() {
        #expect(SwiftToolchain.root(ofExecutable: "/opt/swift-6.4/usr/bin/swift") == "/opt/swift-6.4")
        #expect(SwiftToolchain.root(ofExecutable: "/usr/bin/swift") == "/")
        #expect(SwiftToolchain.root(ofExecutable: "/usr/local/bin/swift") == "/")
        #expect(SwiftToolchain.root(ofExecutable: "/home/u/.local/share/swiftly/bin/swift") == nil)
        #expect(SwiftToolchain.root(ofExecutable: "/app/libexec/ycode-host/swift") == nil)
    }

    @Test func theTargetInfoNamesTheRuntimesToolchain() {
        #expect(SwiftToolchain.root(fromTargetInfo: Self.targetInfo(runtime: Self.swiftlyRoot + "/usr/lib/swift")) == Self.swiftlyRoot)
        #expect(SwiftToolchain.root(fromTargetInfo: Self.targetInfo(runtime: "/usr/lib/swift/")) == "/")
        #expect(SwiftToolchain.root(fromTargetInfo: Self.targetInfo(runtime: "/somewhere/else")) == nil)
        #expect(SwiftToolchain.root(fromTargetInfo: Data("not json".utf8)) == nil)
    }

    @Test func theEnvironmentVariableWins() {
        let files: Set = ["/tc/usr/bin/swift", "/usr/bin/swift"]
        let found = SwiftToolchain.locate(environment: ["YCODE_SWIFT_TOOLCHAIN": "/tc", "PATH": "/usr/bin"],
                                          isExecutable: files.contains, realPath: { $0 }, targetInfo: { _ in nil })
        #expect(found == "/tc")
        // A folder without the compiler is ignored.
        let ignored = SwiftToolchain.locate(environment: ["YCODE_SWIFT_TOOLCHAIN": "/empty", "PATH": "/usr/bin"],
                                            isExecutable: files.contains, realPath: { $0 }, targetInfo: { _ in nil })
        #expect(ignored == "/")
    }

    @Test func aLinkOnPathIsFollowedToItsToolchain() {
        let files: Set = ["/usr/local/bin/swift", "/opt/swift/usr/bin/swift"]
        let found = SwiftToolchain.locate(environment: ["PATH": "/usr/local/sbin:/usr/local/bin"], isExecutable: files.contains,
                                          realPath: { $0 == "/usr/local/bin/swift" ? "/opt/swift/usr/bin/swift" : $0 },
                                          targetInfo: { _ in nil })
        #expect(found == "/opt/swift")
    }

    /// swiftly's proxy, and the Flatpak's wrapper for the host's swiftly
    /// toolchain in the home folder: the compiler says where it is.
    @Test func aProxyIsAskedForItsRuntime() {
        for proxy in ["/home/u/.local/share/swiftly/bin", "/app/libexec/ycode-host"] {
            var asked: [String] = []
            let files: Set = [proxy + "/swift", Self.swiftlyRoot + "/usr/bin/swift"]
            let found = SwiftToolchain.locate(environment: ["PATH": proxy + ":/usr/bin"], isExecutable: files.contains, realPath: { $0 },
                                              targetInfo: { asked.append($0); return Self.targetInfo(runtime: Self.swiftlyRoot + "/usr/lib/swift") })
            #expect(found == Self.swiftlyRoot)
            #expect(asked == [proxy + "/swift"])
        }
    }

    /// A host toolchain this process cannot see (the Flatpak and a toolchain
    /// in the host's `/usr`), and no compiler at all.
    @Test func nothingIsFoundWithoutAVisibleCompiler() {
        let wrapper = "/app/libexec/ycode-host"
        let unseen = SwiftToolchain.locate(environment: ["PATH": wrapper], isExecutable: [wrapper + "/swift"].contains, realPath: { $0 },
                                           targetInfo: { _ in Self.targetInfo(runtime: "/opt/hidden/usr/lib/swift") })
        #expect(unseen == nil)
        let none = SwiftToolchain.locate(environment: ["PATH": "/usr/bin:/bin"], isExecutable: { _ in false }, realPath: { $0 },
                                         targetInfo: { _ in Issue.record("no compiler to ask"); return nil })
        #expect(none == nil)
    }
}
