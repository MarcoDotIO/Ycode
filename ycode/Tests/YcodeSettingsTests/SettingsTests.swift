import Foundation
import Testing
@testable import YcodeSettings

/// Each expectation here encodes a behavior observed from the reference
/// `xcodebuild` (see research/experiments/settings and specs/build-settings.md).
private func resolve(_ levels: [SettingsLevel], _ context: ConditionContext = ["config": "Debug"]) -> BuildSettings {
    BuildSettings(levels: levels, context: context)
}

private func xcconfig(_ text: String, files: [String: String] = [:]) -> [SettingAssignment] {
    let base = URL(fileURLWithPath: "/virtual/main.xcconfig")
    return XCConfig(text: text, baseURL: base) { url in
        guard let t = files[url.lastPathComponent] else { throw CocoaError(.fileReadNoSuchFile) }
        return t
    }.assignments
}

@Suite struct MacroEvaluationTests {
    @Test func levelsStackInOrder() {
        let s = resolve([
            SettingsLevel(name: "project-xcconfig", assignments: xcconfig("LV = px")),
            SettingsLevel(name: "project", buildSettings: [("LV", "$(inherited) ps")]),
            SettingsLevel(name: "target-xcconfig", assignments: xcconfig("LV = $(inherited) tx")),
            SettingsLevel(name: "target", buildSettings: [("LV", "$(inherited) ts")]),
        ])
        #expect(s["LV"] == "px ps tx ts")
    }

    @Test func inheritedChainsWithinOneFile() {
        let s = resolve([SettingsLevel(name: "x", assignments: xcconfig("E1 = one\nE1 = $(inherited) two"))])
        #expect(s["E1"] == "one two")
    }

    @Test func selfReferenceMeansInherited() {
        let s = resolve([
            SettingsLevel(name: "a", literals: ["SELF": "lower"]),
            SettingsLevel(name: "b", assignments: xcconfig("SELF = $(SELF) upper")),
        ])
        #expect(s["SELF"] == "lower upper")
    }

    @Test func lastMatchingXCConfigLineWins() {
        let s = resolve([SettingsLevel(name: "x", assignments: xcconfig("""
            E3 = plain-first
            E3[config=Debug] = cond-second
            E4[config=Debug] = cond-first
            E4 = plain-second
            """))])
        #expect(s["E3"] == "cond-second")
        #expect(s["E4"] == "plain-second")
    }

    @Test func conditionalBeatsPlainInBuildSettingsDictionary() {
        let s = resolve([SettingsLevel(name: "t", buildSettings: [("P[config=Debug]", "cond"), ("P", "plain")])])
        #expect(s["P"] == "cond")
        let r = resolve([SettingsLevel(name: "t", buildSettings: [("P[config=Debug]", "cond"), ("P", "plain")])], ["config": "Release"])
        #expect(r["P"] == "plain")
    }

    @Test func sdkConditionsGlob() {
        let level = SettingsLevel(name: "x", assignments: xcconfig("F = plain\nF[sdk=macosx*] = mac\nF[sdk=iphoneos*][arch=arm64] = ios"))
        #expect(resolve([level], ["sdk": "macosx27.0"])["F"] == "mac")
        #expect(resolve([level], ["sdk": "iphoneos27.0", "arch": "arm64"])["F"] == "ios")
        #expect(resolve([level], ["sdk": "iphoneos27.0", "arch": "x86_64"])["F"] == "plain")
    }

    @Test func referenceForms() {
        let s = resolve([SettingsLevel(name: "x", assignments: xcconfig("""
            MIXED = MiXeD
            NESTSEL = X
            NEST_X = nested-ok
            O_BARE = $MIXED-tail
            O_BRACE = ${MIXED}
            O_NEST = $(NEST_$(NESTSEL))
            O_DOLLAR = a$$b
            O_UNDEF = [$(NOPE_NOT_SET)]
            """))])
        #expect(s["O_BARE"] == "MiXeD-tail")
        #expect(s["O_BRACE"] == "MiXeD")
        #expect(s["O_NEST"] == "nested-ok")
        #expect(s["O_DOLLAR"] == "a$b")
        #expect(s["O_UNDEF"] == "[]")
    }

    @Test func lateBinding() {
        let s = resolve([
            SettingsLevel(name: "low", buildSettings: [("Y", "$(X)"), ("X", "a")]),
            SettingsLevel(name: "high", buildSettings: [("X", "c")]),
        ])
        #expect(s["Y"] == "c")
    }

    @Test func cyclesResolveToEmpty() {
        let s = resolve([SettingsLevel(name: "x", buildSettings: [("A", "$(B)"), ("B", "$(A)")])])
        #expect(s["A"] == "")
        #expect(!s.diagnostics.isEmpty)
    }
}

@Suite struct MacroOperatorTests {
    @Test(arguments: [
        ("quote", "My App-Name 2.0", #"My\ App-Name\ 2.0"#),
        ("quote", #"it's "q" $x"#, #"it\'s\ \"q\"\ $x"#),
        ("quote", "a\\b", #"a\\b"#),
        ("quote", "", ""),
        ("quote", "a!#%&()*;<>?[]{}|~`^=,@+:b", "a!#%&()*;<>?[]{}|~`^=,@+:b"),
        ("lower", "MiXeD", "mixed"),
        ("upper", "MiXeD", "MIXED"),
        ("lower", "Élan ÿ 3", "élan ÿ 3"),
        ("identifier", "My App-Name 2.0", "My_App_Name_2_0"),
        ("identifier", "9lives.x", "_lives_x"),
        ("identifier", "Élan ÿ 3", "_lan___3"),
        ("c99extidentifier", "9lives.x", "_lives_x"),
        ("c99extidentifier", "Élan ÿ 3", "Élan_ÿ_3"),
        ("rfc1034identifier", "My App-Name 2.0", "My-App-Name-2-0"),
        ("rfc1034identifier", "9lives.x", "-lives-x"),
        ("rfc1034identifier", "Élan ÿ 3", "-lan---3"),
        ("base", "/a/b/../c/./d.tar.gz", "d.tar"),
        ("base", "noext", "noext"),
        ("base", ".hidden", ""),
        ("base", "/a/b/", ""),
        ("dir", "/a/b/../c/./d.tar.gz", "/a/b/../c/./"),
        ("dir", "file", "./"),
        ("dir", "/", "/"),
        ("dir", "/a/b/", "/a/b/"),
        ("file", "/a/b/../c/./d.tar.gz", "d.tar.gz"),
        ("file", "/a/b/", ""),
        ("suffix", "/a/b/../c/./d.tar.gz", ".gz"),
        ("suffix", "noext", ""),
        ("suffix", ".hidden", ".hidden"),
        ("standardizepath", "/a/b/../c/./d.tar.gz", "/a/c/d.tar.gz"),
        ("standardizepath", "/a/b/", "/a/b"),
        ("standardizepath", "/", "/"),
        ("standardizepath", "rel/x/y", "rel/x/y"),
        ("absolutepath", "rel/x/y", "rel/x/y"),
        ("not", "YES", "NO"),
        ("not", "NO", "YES"),
        ("bogus", "MiXeD", "MiXeD"),
    ])
    func operatorMatchesReference(_ op: String, _ input: String, _ expected: String) {
        #expect(MacroOperators.apply(op, argument: nil, to: input) == expected)
    }

    @Test(arguments: [
        ("/a/b", "/a/b/c/d", "c/d"),
        ("/a/b/c/d", "/a/b", "../.."),
        ("/a/b/c/d", "/x/y", "../../../../x/y"),
        ("/a/b", "/a/b", "."),
        ("rel/x/y", "/a", "rel/x/y"),
        ("/a/b/../c/./d.tar.gz", "/a", "../.."),
    ])
    func relativeTo(_ value: String, _ arg: String, _ expected: String) {
        #expect(MacroOperators.apply("relativeto", argument: arg, to: value) == expected)
    }

    @Test func defaultOperatorAndChaining() {
        let s = resolve([SettingsLevel(name: "x", assignments: xcconfig("""
            EMPTYV =
            NAME = My App-Name 2.0
            P6 = noext
            F1 = $(EMPTYV:default=fb)
            F2 = $(EMPTYV:default=$(P6))
            F3 = $(P6:default=fb)
            CH = $(NAME:lower:rfc1034identifier)
            """))])
        #expect(s["F1"] == "fb")
        #expect(s["F2"] == "noext")
        #expect(s["F3"] == "noext")
        #expect(s["CH"] == "my-app-name-2-0")
    }
}

@Suite struct XCConfigParsingTests {
    @Test func commentsSemicolonsAndURLs() {
        let s = resolve([SettingsLevel(name: "x", assignments: xcconfig("""
            // comment line
            E5 = value // trailing comment
            E6 = semi;
            E7 = http://example.com
            E8 = http:/$()/example.com
            """))])
        #expect(s["E5"] == "value")
        #expect(s["E6"] == "semi")
        #expect(s["E7"] == "http:")
        #expect(s["E8"] == "http://example.com")
    }

    @Test func conditionBracketsMayContainEquals() {
        let a = xcconfig("ORDER_FILE[sdk=iphoneos*] = $(SDKROOT)/x.order\nOTHER[sdk=macosx*,arch=arm64] = y")
        #expect(a.count == 2)
        #expect(a[0].name == "ORDER_FILE")
        #expect(a[0].conditions.map(\.pattern) == ["iphoneos*"])
        #expect(a[1].conditions.map(\.parameter) == ["sdk", "arch"])
    }

    @Test func includesAreTextualAndOptionalOnesMayBeMissing() {
        let s = resolve([SettingsLevel(name: "x", assignments: xcconfig("""
            INC = before
            #include "inc.xcconfig"
            #include? "missing.xcconfig"
            AFTER = $(INC)
            """, files: ["inc.xcconfig": "INC = included\nINCLUDED = yes\n"]))])
        #expect(s["INC"] == "included")
        #expect(s["INCLUDED"] == "yes")
        #expect(s["AFTER"] == "included")
    }

    @Test func missingRequiredIncludeIsDiagnosed() {
        let x = XCConfig(text: "#include \"nope.xcconfig\"\n", baseURL: URL(fileURLWithPath: "/virtual/a.xcconfig")) { _ in
            throw CocoaError(.fileReadNoSuchFile)
        }
        #expect(x.diagnostics.contains { $0.contains("nope.xcconfig") })
    }
}

@Suite struct DerivedSettingsTests {
    private func derived(_ settings: [String: String], productType: String? = "com.apple.product-type.application",
                         targetClass: String? = "PBXNativeTarget", platform: String? = "MacOSX") -> [String: String] {
        let s = resolve([SettingsLevel(name: "x", literals: settings)])
        return DerivedSettings.compute(s, .init(targetClass: targetClass, productType: productType, platform: platform, sdkPath: nil))
    }

    @Test func unoptimizedBuildIsDerivedFromEitherCompiler() {
        #expect(derived(["GCC_OPTIMIZATION_LEVEL": "0"])["IS_UNOPTIMIZED_BUILD"] == "YES")
        #expect(derived(["SWIFT_OPTIMIZATION_LEVEL": "-Onone"])["IS_UNOPTIMIZED_BUILD"] == "YES")
        #expect(derived(["IS_UNOPTIMIZED_BUILD": "YES"])["IS_UNOPTIMIZED_BUILD"] == "NO")
    }

    @Test func previewsRequireUnoptimizedSwift() {
        let on = derived(["SWIFT_OPTIMIZATION_LEVEL": "-Onone", "SWIFT_VERSION": "5.0", "ENABLE_PREVIEWS": "YES",
                          "ENABLE_HARDENED_RUNTIME": "YES", "CODE_SIGN_IDENTITY": "-"])
        #expect(on["ENABLE_PREVIEWS"] == nil)
        #expect(on["ENABLE_DEBUG_DYLIB"] == nil)
        #expect(on["ENABLE_HARDENED_RUNTIME"] == "NO")
        // A real signing identity keeps the hardened runtime.
        let signed = derived(["SWIFT_OPTIMIZATION_LEVEL": "-Onone", "SWIFT_VERSION": "5.0", "ENABLE_PREVIEWS": "YES",
                              "ENABLE_HARDENED_RUNTIME": "YES", "CODE_SIGN_IDENTITY": "Apple Development"])
        #expect(signed["ENABLE_HARDENED_RUNTIME"] == nil)
        // Not requesting previews leaves the debug dylib and hardened runtime alone.
        let none = derived(["SWIFT_VERSION": "5.0", "ENABLE_DEBUG_DYLIB": "YES", "ENABLE_HARDENED_RUNTIME": "YES"])
        #expect(none["ENABLE_DEBUG_DYLIB"] == nil)
        #expect(none["ENABLE_HARDENED_RUNTIME"] == nil)
        let noSwift = derived(["SWIFT_OPTIMIZATION_LEVEL": "-Onone", "ENABLE_PREVIEWS": "YES"])
        #expect(noSwift["ENABLE_PREVIEWS"] == "NO")
        let optimized = derived(["SWIFT_VERSION": "5.0", "ENABLE_PREVIEWS": "YES"])
        #expect(optimized["ENABLE_PREVIEWS"] == "NO")
        #expect(optimized["ENABLE_DEBUG_DYLIB"] == "NO")
    }

    @Test func testBundlesGetTestingPluginAndDeviceDSYMs() {
        let t = "com.apple.product-type.bundle.unit-test"
        let mac = derived(["OTHER_SWIFT_FLAGS": "-D X", "TOOLCHAIN_DIR": "/tc", "DEBUG_INFORMATION_FORMAT": "dwarf"], productType: t)
        #expect(mac["OTHER_SWIFT_FLAGS"] == "-D X -plugin-path /tc/usr/lib/swift/host/plugins/testing")
        #expect(mac["DEBUG_INFORMATION_FORMAT"] == nil)
        #expect(derived(["DEBUG_INFORMATION_FORMAT": "dwarf"], productType: t, platform: "iPhoneOS")["DEBUG_INFORMATION_FORMAT"] == "dwarf-with-dsym")
        #expect(derived(["DEBUG_INFORMATION_FORMAT": "dwarf"], productType: t, platform: "iPhoneSimulator")["DEBUG_INFORMATION_FORMAT"] == nil)
        #expect(derived(["DEBUG_INFORMATION_FORMAT": "dwarf"], platform: "iPhoneOS")["DEBUG_INFORMATION_FORMAT"] == nil)
    }

    @Test func nativeTargetsSearchBuiltProductsInclude() {
        #expect(derived(["BUILT_PRODUCTS_DIR": "/b", "HEADER_SEARCH_PATHS": "/p"])["HEADER_SEARCH_PATHS"] == "/b/include /p")
        #expect(derived(["BUILT_PRODUCTS_DIR": "/b"], targetClass: "PBXAggregateTarget")["HEADER_SEARCH_PATHS"] == nil)
    }
}
