import Foundation

/// Compiling iOS-simulator payloads and the preview host on Linux (UIKit
/// previews in the Linux IDE, issue #84; `specs/ide/previews.md` §Linux,
/// "UIKit previews"): the toolchain's `swiftc` with the user's own copy of
/// the iPhoneSimulator platform and toolchain resources (`YCODE_USER_SDK`,
/// the developer folder `scripts/ycode-ios-build-linux` uses; never
/// committed or redistributed) and an upstream `ld64.lld`.
public struct PreviewIOSToolchain: Equatable, Sendable {
    /// The developer folder (`Platforms/`, `Toolchains/`).
    public var developer: URL
    public var sdk: URL
    /// `Toolchains/XcodeDefault.xctoolchain/usr/lib/swift` (the SDK's Swift resources).
    public var resourceDirectory: URL
    /// `libclang_rt.iossim.a` (the simulator's compiler runtime).
    public var clangRuntime: URL
    public var linker: URL
    /// The SDK's version ("27.1"): the deployment target payloads use.
    public var sdkVersion: String

    public init(developer: URL, sdk: URL, resourceDirectory: URL, clangRuntime: URL, linker: URL, sdkVersion: String) {
        self.developer = developer
        self.sdk = sdk
        self.resourceDirectory = resourceDirectory
        self.clangRuntime = clangRuntime
        self.linker = linker
        self.sdkVersion = sdkVersion
    }

    /// The pieces from `YCODE_USER_SDK` (and `YCODE_LD64`, else the newest
    /// `/usr/lib/llvm-*/bin/ld64.lld`), or what is missing.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> Result<PreviewIOSToolchain, PreviewFailure> {
        let fm = FileManager.default
        guard let dev = environment["YCODE_USER_SDK"], !dev.isEmpty else {
            return .failure(.unsupported("UIKit previews compile with your own copy of the iOS Simulator SDK: set YCODE_USER_SDK to its developer folder "
                + "(the one Run on a simulator host uses; see scripts/ycode-ios-build-linux)."))
        }
        let developer = URL(fileURLWithPath: dev)
        let sdks = developer.appendingPathComponent("Platforms/iPhoneSimulator.platform/Developer/SDKs")
        let names = ((try? fm.contentsOfDirectory(atPath: sdks.path)) ?? []).filter { $0.hasPrefix("iPhoneSimulator") && $0.hasSuffix(".sdk") }
        // A versioned name first (iPhoneSimulator27.1.sdk), else the plain one.
        guard let name = names.filter({ $0 != "iPhoneSimulator.sdk" }).sorted().last ?? names.first else {
            return .failure(.unsupported("No iPhoneSimulator SDK in \(sdks.path)."))
        }
        let sdk = sdks.appendingPathComponent(name)
        let tc = developer.appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/lib")
        let resources = tc.appendingPathComponent("swift")
        let clang = tc.appendingPathComponent("clang")
        let runtime = ((try? fm.contentsOfDirectory(atPath: clang.path)) ?? []).sorted().reversed()
            .map { clang.appendingPathComponent("\($0)/lib/darwin/libclang_rt.iossim.a") }
            .first { fm.fileExists(atPath: $0.path) }
        guard fm.fileExists(atPath: resources.path), let runtime else {
            return .failure(.unsupported("The SDK copy in \(dev) has no XcodeDefault toolchain resources (usr/lib/swift, libclang_rt.iossim.a)."))
        }
        var ld = environment["YCODE_LD64"].map { URL(fileURLWithPath: $0) }
        if ld == nil {
            let llvm = ((try? fm.contentsOfDirectory(atPath: "/usr/lib")) ?? []).filter { $0.hasPrefix("llvm-") }
                .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
            ld = llvm.reversed().map { URL(fileURLWithPath: "/usr/lib/\($0)/bin/ld64.lld") }.first { fm.isExecutableFile(atPath: $0.path) }
        }
        guard let linker = ld, fm.isExecutableFile(atPath: linker.path) else {
            return .failure(.unsupported("UIKit previews link with an upstream ld64.lld: install LLVM's lld or set YCODE_LD64."))
        }
        return .success(PreviewIOSToolchain(developer: developer, sdk: sdk, resourceDirectory: resources, clangRuntime: runtime, linker: linker,
                                            sdkVersion: sdkVersion(sdk: sdk)))
    }

    /// The SDK's version: `SDKSettings.json`'s `Version`, else the folder's name.
    public static func sdkVersion(sdk: URL) -> String {
        if let d = FileManager.default.contents(atPath: sdk.appendingPathComponent("SDKSettings.json").path),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let v = o["Version"] as? String, !v.isEmpty {
            return v
        }
        let digits = sdk.deletingPathExtension().lastPathComponent.drop { !$0.isNumber }
        return digits.isEmpty ? "17.0" : String(digits)
    }

    /// `swiftc` arguments for the simulator: a payload (`library`, with its
    /// own install name) or the host's executable.
    public func arguments(sources: [URL], output: URL, moduleName: String, library: Bool, moduleCache: URL, extra: [String] = []) -> [String] {
        var a = ["-target", PreviewPlatform.iOS.targetTriple(deploymentTarget: sdkVersion), "-sdk", sdk.path,
                 "-resource-dir", resourceDirectory.path, "-module-cache-path", moduleCache.standardizedFileURL.path,
                 "-module-name", moduleName, "-Onone", "-gnone", "-swift-version", "5",
                 "-use-ld=lld", "-ld-path=" + linker.path, "-Xlinker", clangRuntime.path]
        if library {
            a += ["-emit-library", "-parse-as-library", "-wmo", "-D", "DEBUG", "-D", "YCODE_PREVIEW",
                  "-Xlinker", "-install_name", "-Xlinker", "@rpath/\(output.lastPathComponent)"]
        }
        return a + extra + ["-o", output.path] + sources.map(\.path)
    }
}

extension PreviewHost {
    /// The host for a bundled plan (the Linux IDE's UIKit previews): the
    /// plan and the payload travel inside the app, in `Previews/`, and a
    /// relative payload path is resolved there. The app is uploaded and
    /// launched for every update (no file delivery into the device yet).
    public static var bundledPlanSource: String {
        uikitSource
            .replacingOccurrences(of: #"?? "/tmp/ycode-previews""#, with: #"?? (Bundle.main.bundlePath + "/Previews")"#)
            .replacingOccurrences(of: "guard let h = dlopen(payload, RTLD_NOW | RTLD_LOCAL) else {",
                                  with: #"guard let h = dlopen(payload.hasPrefix("/") ? payload : previewDirectory + "/" + payload, RTLD_NOW | RTLD_LOCAL) else {"#)
    }
}
