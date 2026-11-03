import Foundation
import Testing
@testable import YcodeBuildServer
import YcodeXcodebuild

/// Argument generation, one setting at a time (no SDK or compiler needed).
@Suite struct CompilerArgumentsTests {
    static let base: [String: String] = [
        "PRODUCT_MODULE_NAME": "App",
        "BUILT_PRODUCTS_DIR": "/dd/Products/Debug-iphonesimulator",
        "OBJECT_FILE_DIR_normal": "/dd/Obj/App.build/Objects-normal",
        "SDKROOT": "/SDKs/iPhoneSimulator.sdk",
        "PLATFORM_NAME": "iphonesimulator",
        "IPHONEOS_DEPLOYMENT_TARGET": "18.0",
        "CURRENT_ARCH": "arm64",
    ]

    static func target(_ type: String = "com.apple.product-type.application", sources: [String] = ["/p/App/A.swift", "/p/App/B.swift"],
                       headers: [BuildGraph.Header] = [], flags: [String: String] = [:]) -> BuildGraph.Target {
        BuildGraph.Target(id: "ycode-target:/p/P.xcodeproj/1?name=App", name: "App", objectID: "1", projectIndex: 0, productType: type,
                          sources: sources.map { .init(path: $0, language: SourceLanguage(path: $0)!, flags: flags[$0]) },
                          headers: headers, dependencies: [], packageProducts: [])
    }

    static func ctx(_ extra: [String: String] = [:], target t: BuildGraph.Target = target(), linux: Bool = false,
                    headerDirs: [String] = []) -> TargetCompileContext {
        TargetCompileContext(target: t, settings: base.merging(extra) { $1 }, projectDirectory: "/p",
                             projectHeaderDirectories: headerDirs, isLinuxHost: linux, hostArchitecture: "arm64")
    }

    static func swift(_ extra: [String: String] = [:], target t: BuildGraph.Target = target(), linux: Bool = false) -> [String] {
        CompilerArguments.swift(for: "/p/App/A.swift", in: ctx(extra, target: t, linux: linux))
    }

    /// True if `needle` appears in `args` as consecutive elements.
    static func has(_ args: [String], _ needle: String...) -> Bool {
        guard needle.count <= args.count else { return false }
        return (0...(args.count - needle.count)).contains { Array(args[$0..<($0 + needle.count)]) == needle }
    }

    // MARK: Swift

    @Test func moduleSourcesSDKAndTriple() {
        let a = Self.swift()
        #expect(Array(a.prefix(4)) == ["-module-name", "App", "/p/App/A.swift", "/p/App/B.swift"])
        #expect(Self.has(a, "-sdk", "/SDKs/iPhoneSimulator.sdk"))
        #expect(Self.has(a, "-target", "arm64-apple-ios18.0-simulator"))
        #expect(Self.has(a, "-index-unit-output-path", "/dd/Obj/App.build/Objects-normal/arm64/A.o"))
        #expect(Self.has(a, "-I", "/dd/Products/Debug-iphonesimulator"))
        #expect(Self.has(a, "-F", "/dd/Products/Debug-iphonesimulator"))
        #expect(Self.has(a, "-Xcc", "-I", "-Xcc", "/dd/Products/Debug-iphonesimulator/include"))
    }

    @Test func triplesPerPlatform() {
        func triple(_ s: [String: String], linux: Bool = false) -> String { Self.ctx(s, linux: linux).triple }
        #expect(triple(["PLATFORM_NAME": "iphoneos"]) == "arm64-apple-ios18.0")
        #expect(triple(["PLATFORM_NAME": "macosx", "MACOSX_DEPLOYMENT_TARGET": "15.0"]) == "arm64-apple-macos15.0")
        #expect(triple(["PLATFORM_NAME": "xrsimulator", "XROS_DEPLOYMENT_TARGET": "26.0"]) == "arm64-apple-xros26.0-simulator")
        #expect(triple(["PLATFORM_NAME": "watchsimulator", "WATCHOS_DEPLOYMENT_TARGET": "11.0"]) == "arm64-apple-watchos11.0-simulator")
        #expect(triple(["PLATFORM_NAME": "appletvos", "TVOS_DEPLOYMENT_TARGET": "18.0"]) == "arm64-apple-tvos18.0")
        // No deployment target: the SDK's version.
        #expect(triple(["IPHONEOS_DEPLOYMENT_TARGET": "", "SDK_VERSION": "27.0"]) == "arm64-apple-ios27.0-simulator")
        // swift-build's exported pieces win.
        #expect(triple(["LLVM_TARGET_TRIPLE_OS_VERSION": "ios17.0", "LLVM_TARGET_TRIPLE_SUFFIX": "-simulator", "LLVM_TARGET_TRIPLE_VENDOR": "apple"])
            == "arm64-apple-ios17.0-simulator")
        // Linux: the host triple, no SDK or frameworks.
        #expect(triple(["CURRENT_ARCH": "x86_64"], linux: true) == "x86_64-unknown-linux-gnu")
        #expect(triple([:], linux: true) == "aarch64-unknown-linux-gnu")
        let linux = Self.swift(linux: true)
        #expect(!linux.contains("-sdk") && !linux.contains("-F"))
    }

    @Test func swiftVersionAndOptimization() {
        #expect(Self.has(Self.swift(["SWIFT_VERSION": "5.0"]), "-swift-version", "5"))
        #expect(Self.has(Self.swift(["SWIFT_VERSION": "6.0"]), "-swift-version", "6"))
        #expect(Self.has(Self.swift(["SWIFT_VERSION": "4.2"]), "-swift-version", "4.2"))
        #expect(!Self.swift().contains("-swift-version"))
        #expect(Self.swift(["SWIFT_OPTIMIZATION_LEVEL": "-Onone"]).contains("-Onone"))
        #expect(Self.swift(["SWIFT_OPTIMIZATION_LEVEL": "-Owholemodule"]).contains("-O"))
    }

    @Test func conditionsAndDefinitions() {
        let a = Self.swift(["SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG FEATURE_X", "GCC_PREPROCESSOR_DEFINITIONS": "DEBUG=1 \"NAME=a b\""])
        #expect(Self.has(a, "-D", "DEBUG") && Self.has(a, "-D", "FEATURE_X"))
        #expect(Self.has(a, "-Xcc", "-DDEBUG=1") && Self.has(a, "-Xcc", "-DNAME=a b"))
    }

    @Test func searchPaths() throws {
        let a = Self.swift(["SWIFT_INCLUDE_PATHS": "Modules /abs/mods", "FRAMEWORK_SEARCH_PATHS": "Vendor",
                            "HEADER_SEARCH_PATHS": "include", "USER_HEADER_SEARCH_PATHS": "quoted",
                            "SYSTEM_HEADER_SEARCH_PATHS": "/sys/include", "SYSTEM_FRAMEWORK_SEARCH_PATHS": "/sys/fw"])
        #expect(Self.has(a, "-I", "/p/Modules") && Self.has(a, "-I", "/abs/mods"))
        #expect(Self.has(a, "-F", "/p/Vendor"))
        #expect(Self.has(a, "-Xcc", "-I", "-Xcc", "/p/include"))
        #expect(Self.has(a, "-Xcc", "-iquote", "-Xcc", "/p/quoted"))
        #expect(Self.has(a, "-Xcc", "-isystem", "-Xcc", "/sys/include"))
        #expect(Self.has(a, "-Fsystem", "/sys/fw"))

        // `dir/**` adds the folders below `dir`.
        let dir = try freshScratch("recursive")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        let paths = Self.ctx(["HEADER_SEARCH_PATHS": dir.path + "/**"]).searchPaths("HEADER_SEARCH_PATHS")
        #expect(paths == [dir.path, dir.path + "/a", dir.path + "/a/b"])
    }

    @Test func bridgingHeaderAndUnderlyingModule() {
        let a = Self.swift(["SWIFT_OBJC_BRIDGING_HEADER": "App/App-Bridging-Header.h"])
        #expect(Self.has(a, "-import-objc-header", "/p/App/App-Bridging-Header.h"))
        #expect(!a.contains("-import-underlying-module"))
        // A framework with public headers imports its own Clang module.
        let fw = Self.target("com.apple.product-type.framework", sources: ["/p/Kit/K.swift", "/p/Kit/L.m"],
                             headers: [.init(path: "/p/Kit/Kit.h", visibility: .public)])
        let k = Self.ctx(["PRODUCT_MODULE_NAME": "Kit"], target: fw)
        #expect(k.exportsClangModule)
        #expect(CompilerArguments.swift(for: "/p/Kit/K.swift", in: k).contains("-import-underlying-module"))
        #expect(CompilerArguments.clang(for: "/p/Kit/L.m", language: .objectiveC, in: k.with(["CLANG_ENABLE_MODULES": "YES"]))
            .contains("-fmodule-name=Kit"))
        // Project headers only: no module.
        let app = Self.target(headers: [.init(path: "/p/App/H.h", visibility: .project)])
        #expect(!Self.ctx(target: app).exportsClangModule)
    }

    @Test func testabilityExtensionsAndLibraries() {
        #expect(Self.swift(["ENABLE_TESTABILITY": "YES"]).contains("-enable-testing"))
        #expect(!Self.swift(["ENABLE_TESTABILITY": "YES", "SWIFT_ENABLE_TESTABILITY": "NO"]).contains("-enable-testing"))
        #expect(Self.swift(["APPLICATION_EXTENSION_API_ONLY": "YES"]).contains("-application-extension"))
        #expect(Self.swift(["SWIFT_LIBRARIES_ONLY": "YES"]).contains("-parse-as-library"))
        #expect(!Self.swift().contains("-parse-as-library"))
        // One file: a library unless it is main.swift.
        #expect(Self.swift(target: Self.target(sources: ["/p/App/A.swift"])).contains("-parse-as-library"))
        #expect(!Self.swift(target: Self.target(sources: ["/p/App/main.swift"])).contains("-parse-as-library"))
        #expect(!Self.swift(["SWIFT_DISABLE_PARSE_AS_LIBRARY": "YES"], target: Self.target(sources: ["/p/App/A.swift"]))
            .contains("-parse-as-library"))
        #expect(Self.swift(["SWIFT_OBJC_INTEROP_MODE": "objcxx"]).contains("-cxx-interoperability-mode=default"))
    }

    @Test func concurrencyAndUpcomingFeatures() {
        #expect(Self.has(Self.swift(["SWIFT_STRICT_CONCURRENCY": "complete"]), "-enable-upcoming-feature", "StrictConcurrency"))
        #expect(Self.swift(["SWIFT_STRICT_CONCURRENCY": "targeted"]).contains("-strict-concurrency=targeted"))
        #expect(!Self.swift(["SWIFT_STRICT_CONCURRENCY": "minimal"]).contains("-enable-upcoming-feature"))
        #expect(Self.swift(["SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor"]).contains("-default-isolation=MainActor"))
        #expect(!Self.swift(["SWIFT_DEFAULT_ACTOR_ISOLATION": "nonisolated"]).contains("-default-isolation=MainActor"))
        #expect(Self.has(Self.swift(["SWIFT_UPCOMING_FEATURE_EXISTENTIAL_ANY": "YES"]), "-enable-upcoming-feature", "ExistentialAny"))

        func features(_ s: [String: String]) -> [String] {
            let a = Self.swift(s)
            return a.indices.filter { a[$0] == "-enable-upcoming-feature" }.map { a[$0 + 1] }
        }
        // Approachable Concurrency: five features in Swift 5 mode, two in Swift 6.
        #expect(features(["SWIFT_APPROACHABLE_CONCURRENCY": "YES", "SWIFT_VERSION": "5.0"]).count == 5)
        #expect(features(["SWIFT_APPROACHABLE_CONCURRENCY": "YES", "SWIFT_VERSION": "6.0"])
            == ["InferIsolatedConformances", "NonisolatedNonsendingByDefault"])
        // Bare slash regex: on (Swift 5) unless turned off; implied by Swift 6.
        #expect(Self.swift(["SWIFT_VERSION": "5.0"]).contains("-enable-bare-slash-regex"))
        #expect(!Self.swift(["SWIFT_VERSION": "5.0", "SWIFT_ENABLE_BARE_SLASH_REGEX": "NO"]).contains("-enable-bare-slash-regex"))
        #expect(!Self.swift(["SWIFT_VERSION": "6.0"]).contains("-enable-bare-slash-regex"))
    }

    @Test func otherFlagsAndPerFileFlags() {
        let t = Self.target(flags: ["/p/App/A.swift": "-Xfrontend -warn-long-expression-type-checking=100"])
        let a = Self.swift(["OTHER_SWIFT_FLAGS": "-Xfrontend \"-enable-x y\" -DEXTRA"], target: t)
        #expect(Self.has(a, "-Xfrontend", "-enable-x y", "-DEXTRA"))
        #expect(Self.has(a, "-Xfrontend", "-warn-long-expression-type-checking=100"))
    }

    @Test func testBundlesFindTheTestFrameworks() {
        let t = Self.target("com.apple.product-type.bundle.unit-test")
        let a = Self.swift(["PLATFORM_DIR": "/Dev/Platforms/iPhoneSimulator.platform"], target: t)
        #expect(Self.has(a, "-F", "/Dev/Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks"))
        #expect(Self.has(a, "-I", "/Dev/Platforms/iPhoneSimulator.platform/Developer/usr/lib"))
        #expect(!Self.swift(["PLATFORM_DIR": "/Dev/Platforms/iPhoneSimulator.platform"]).contains { $0.contains("Developer/Library/Frameworks") })
    }

    // MARK: Clang

    @Test func clangObjectiveC() {
        let t = Self.target(sources: ["/p/App/A.swift", "/p/App/H.m"])
        let c = Self.ctx(["CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES", "CLANG_ENABLE_OBJC_WEAK": "YES",
                          "GCC_C_LANGUAGE_STANDARD": "gnu17", "GCC_PREPROCESSOR_DEFINITIONS": "DEBUG=1", "GCC_OPTIMIZATION_LEVEL": "0",
                          "WARNING_CFLAGS": "-Wall", "OTHER_CFLAGS": "-DOTHER", "GCC_PREFIX_HEADER": "App/Prefix.pch",
                          "ENABLE_NS_ASSERTIONS": "NO"],
                         target: t, headerDirs: ["/p/App"])
        let a = CompilerArguments.clang(for: "/p/App/H.m", language: .objectiveC, in: c)
        #expect(Array(a.prefix(4)) == ["-x", "objective-c", "-target", "arm64-apple-ios18.0-simulator"])
        #expect(Self.has(a, "-isysroot", "/SDKs/iPhoneSimulator.sdk"))
        for flag in ["-fmodules", "-fobjc-arc", "-fobjc-weak", "-std=gnu17", "-O0", "-DDEBUG=1", "-Wall", "-DOTHER", "-DNS_BLOCK_ASSERTIONS=1"] {
            #expect(a.contains(flag), "missing \(flag)")
        }
        #expect(!a.contains("-fmodule-name=App"))
        #expect(Self.has(a, "-iquote", "/p/App"))
        #expect(Self.has(a, "-iquote", "/dd/Products/Debug-iphonesimulator/include/App"))
        #expect(Self.has(a, "-I", "/dd/Products/Debug-iphonesimulator/include"))
        #expect(Self.has(a, "-F", "/dd/Products/Debug-iphonesimulator"))
        #expect(Self.has(a, "-include", "/p/App/Prefix.pch"))
        #expect(Array(a.suffix(4)) == ["-c", "/p/App/H.m", "-o", "/dd/Obj/App.build/Objects-normal/arm64/H.o"])
        // A header gets the target's arguments, no output.
        let h = CompilerArguments.arguments(for: "/p/App/H.h", language: .objectiveC, in: c)
        #expect(h.last == "/p/App/H.h" && !h.contains("-c"))
    }

    @Test func clangCxx() {
        let t = Self.target(sources: ["/p/App/X.cpp", "/p/App/Y.mm"])
        let c = Self.ctx(["CLANG_CXX_LANGUAGE_STANDARD": "gnu++20", "CLANG_CXX_LIBRARY": "libc++", "GCC_C_LANGUAGE_STANDARD": "gnu17",
                          "OTHER_CFLAGS": "-DC_ONLY", "OTHER_CPLUSPLUSFLAGS": "-DCXX_ONLY", "CLANG_ENABLE_OBJC_ARC": "YES"], target: t)
        let a = CompilerArguments.clang(for: "/p/App/X.cpp", language: .cpp, in: c)
        #expect(Self.has(a, "-x", "c++") && a.contains("-std=gnu++20") && a.contains("-stdlib=libc++"))
        #expect(a.contains("-DCXX_ONLY") && !a.contains("-DC_ONLY") && !a.contains("-std=gnu17") && !a.contains("-fobjc-arc"))
        let m = CompilerArguments.clang(for: "/p/App/Y.mm", language: .objectiveCpp, in: c)
        #expect(Self.has(m, "-x", "objective-c++") && m.contains("-fobjc-arc"))
        #expect(CompilerArguments.languageStandard("c++0x") == ["-std=c++11"])
        #expect(CompilerArguments.languageStandard("compiler-default").isEmpty)
    }

    // MARK: Helpers

    @Test func settingWords() {
        #expect(SettingWords.split("a  b\t\"c d\" 'e f' g\\ h") == ["a", "b", "c d", "e f", "g h"])
        #expect(SettingWords.split("") == [])
        #expect(SettingWords.split("\"\"") == [""])
    }

    @Test func platformChoice() {
        #expect(PlatformChoice.baseName("iPhoneOS18.0.sdk") == "iphoneos")
        #expect(PlatformChoice.baseName("/X/MacOSX27.2.sdk") == "macosx")
        #expect(PlatformChoice.baseName("iphonesimulator27.0") == "iphonesimulator")
        // Device SDKs index as simulators; the destination wins on its family.
        #expect(PlatformChoice.sdk(sdkroot: "iphoneos", supportedPlatforms: "", destinationSDK: nil) == "iphonesimulator")
        #expect(PlatformChoice.sdk(sdkroot: "iphoneos", supportedPlatforms: "", destinationSDK: "iphoneos") == "iphoneos")
        #expect(PlatformChoice.sdk(sdkroot: "macosx", supportedPlatforms: "", destinationSDK: "iphonesimulator") == "macosx")
        #expect(PlatformChoice.sdk(sdkroot: "auto", supportedPlatforms: "iphoneos iphonesimulator macosx", destinationSDK: nil)
            == "iphonesimulator")
        #expect(PlatformChoice.sdk(sdkroot: "auto", supportedPlatforms: "iphoneos iphonesimulator macosx", destinationSDK: "macosx")
            == "macosx")
        #expect(PlatformChoice.sdk(sdkroot: "", supportedPlatforms: "", destinationSDK: nil) == "macosx")
        #expect(PlatformChoice.sdk(forDestination: "platform=iOS Simulator,name=iPhone 18 Pro") == "iphonesimulator")
        #expect(PlatformChoice.sdk(forDestination: "generic/platform=visionOS Simulator") == "xrsimulator")
        #expect(PlatformChoice.sdk(forDestination: "platform=macOS,arch=x86_64") == "macosx")
        #expect(PlatformChoice.architecture(forDestination: "platform=macOS,arch=x86_64") == "x86_64")
        #expect(PlatformChoice.sdk(forDestination: "id=1234") == nil)
    }

    @Test func moduleMaps() {
        #expect(ModulePreparer.moduleMap(module: "Kit", publicHeaders: ["KitLegacy.h", "Kit.h"])
            == "module Kit {\n  umbrella header \"Kit.h\"\n  export *\n  module * { export * }\n}\n")
        #expect(ModulePreparer.moduleMap(module: "Kit", publicHeaders: ["Kit.h"], excluding: ["Kit-Swift.h"])
            == "module Kit {\n  umbrella header \"Kit.h\"\n  exclude header \"Kit-Swift.h\"\n  export *\n  module * { export * }\n}\n")
        #expect(ModulePreparer.moduleMap(module: "Lib", publicHeaders: ["b.h", "a.h"])
            == "module Lib {\n  header \"a.h\"\n  header \"b.h\"\n  export *\n}\n")
    }

    @Test func emitModuleArguments() {
        let a = ModulePreparer.emitModuleArguments(Self.ctx(["PRODUCT_MODULE_NAME": "App"]))
        #expect(Self.has(a, "-emit-module", "-emit-module-path", "/dd/Products/Debug-iphonesimulator/App.swiftmodule"))
        #expect(Self.has(a, "-emit-objc-header-path", "/dd/Products/Debug-iphonesimulator/include/App/App-Swift.h"))
        #expect(!a.contains("-index-unit-output-path"))
        #expect(!ModulePreparer.emitModuleArguments(Self.ctx(linux: true)).contains("-emit-objc-header"))
    }
}

extension TargetCompileContext {
    func with(_ extra: [String: String]) -> TargetCompileContext {
        var c = self
        c.settings.merge(extra) { $1 }
        return c
    }
}
