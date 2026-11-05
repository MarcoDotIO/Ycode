// The Linux canvas's OpenViews host and payloads (specs/ide/previews.md
// §Linux, "The Linux canvas"). The end-to-end render needs a toolchain and
// OpenViews built in release (minutes the first time): it runs on Linux when
// YCODE_PREVIEW_OPENVIEWS_TESTS=1.

import Foundation
import Testing
@testable import YcodePreviews

@Suite(.timeLimit(.minutes(2))) struct OpenViewsPayloadTests {
    let card = """
    import SwiftUI

    fileprivate struct Card: View {
        var title: String
        var body: some View { Text(title) }
    }

    #Preview {
        Card(title: "One")
    }

    #Preview("Counter") {
        @Previewable @State var n = 1
        Text("\\(n)")
    }

    """

    @Test func openViewsPayloadsMakeViewsAndRenderThemThemselves() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-ovpayload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("Card.swift")
        try card.write(to: file, atomically: true, encoding: .utf8)
        let previews = PreviewDiscovery.previews(in: card)
        let s = try PreviewPayloadGenerator.generate(moduleFiles: [file], previewed: [PreviewedFile(url: file, previews: previews)],
                                                     kit: .openViews, into: dir.appendingPathComponent("src"))
        let copy = try String(contentsOf: s.files[0], encoding: .utf8)
        // Wrappers return views, appended to the file's copy (fileprivate types stay visible); no UIKit or AppKit.
        #expect(copy.contains("@MainActor func __ycodePreview_0() -> AnyView { __ycodeHost {"))
        #expect(copy.contains("struct __YcodePreviewView_1: View {\n    @State var n = 1"))
        #expect(!copy.contains("UIKit") && !copy.contains("AppKit") && !copy.contains("#Preview"))
        let support = try String(contentsOf: s.files.last!, encoding: .utf8)
        #expect(support.contains("@_cdecl(\"ycode_preview_render\")"))
        #expect(support.contains("case 1: return __ycodePreview_1()"))
        #expect(support.contains("DynamicTypeSize.allCases") && support.contains("ImageRenderer"))
        // Lines still map back into the #Preview body.
        let map = try #require(s.lineMaps[s.files[0].path])
        #expect(map.fileLine(map.bodies[0].copyLine) == previews[0].bodyLine)
        // The UIKit and AppKit kits are unchanged.
        #expect(PreviewPayloadGenerator.supportFile(platform: .iOS, count: 1).contains("UIHostingController"))
        #expect(PreviewPayloadGenerator.supportFile(kit: .appKit, count: 1).contains("NSHostingController"))
    }

    @Test func theHostPackageExportsOpenViewsAndPayloadsCompileAgainstIt() {
        let m = PreviewOpenViewsHost.manifest(openViewsPath: "/src/frameworks/swiftui")
        #expect(m.contains(".package(path: \"/src/frameworks/swiftui\")"))
        #expect(m.contains("\"--export-dynamic\""))
        #expect(m.contains(".product(name: \"SwiftUI\", package: \"swiftui\")"))
        #expect(PreviewOpenViewsHost.source.contains("dlopen(r.payload, RTLD_NOW | RTLD_LOCAL)"))
        #expect(PreviewOpenViewsHost.source.contains("getppid() != parent"))
        let args = PreviewOpenViewsHost.payloadArguments(sources: [URL(fileURLWithPath: "/w/src/0_Card.swift")], output: URL(fileURLWithPath: "/w/payload-3.so"),
                                                         moduleName: "Cards", moduleFlags: ["-I", "/b"])
        #expect(Array(args.prefix(9)) == ["-emit-library", "-module-name", "Cards", "-parse-as-library", "-wmo", "-Onone", "-gnone", "-D", "DEBUG"])
        #expect(args.contains("-I") && args.suffix(3) == ["-o", "/w/payload-3.so", "/w/src/0_Card.swift"])
        // One folder per OpenViews checkout and host version.
        let a = PreviewOpenViewsHost.packageDirectory(cacheRoot: URL(fileURLWithPath: "/c"), openViews: URL(fileURLWithPath: "/x/swiftui"))
        let b = PreviewOpenViewsHost.packageDirectory(cacheRoot: URL(fileURLWithPath: "/c"), openViews: URL(fileURLWithPath: "/y/swiftui"))
        #expect(a != b && a.path.hasPrefix("/c/ycode/preview-host/v\(PreviewOpenViewsHost.sourceVersion)-"))
    }

    @Test func moduleFlagsFindTheBuildsModulesAndTheCTargetsHeaders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-ovflags-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let pkg = root.appendingPathComponent("host"), ov = root.appendingPathComponent("swiftui")
        let bin = pkg.appendingPathComponent(".build/release")
        let maps = pkg.appendingPathComponent(".build/out/Intermediates.noindex/GeneratedModuleMaps-linux-x86_64")
        for d in [bin.appendingPathComponent("CThorVG.build"), maps, ov.appendingPathComponent("Sources/COVSDL/include"), ov.appendingPathComponent("Sources/OVText")] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        try "module CThorVG {}".write(to: bin.appendingPathComponent("CThorVG.build/module.modulemap"), atomically: true, encoding: .utf8)
        try "module OVRender {}".write(to: maps.appendingPathComponent("OVRender.modulemap"), atomically: true, encoding: .utf8)
        try "module COVSDL {}".write(to: ov.appendingPathComponent("Sources/COVSDL/include/module.modulemap"), atomically: true, encoding: .utf8)
        let flags = PreviewOpenViewsHost.moduleFlags(binPath: bin, packageDirectory: pkg, openViews: ov)
        #expect(Array(flags.prefix(2)) == ["-I", bin.path])
        let joined = flags.joined(separator: " ")
        #expect(joined.contains("-fmodule-map-file=") && joined.contains("CThorVG.build/module.modulemap") && joined.contains("OVRender.modulemap"))
        #expect(joined.contains("-I" + ov.appendingPathComponent("Sources/COVSDL/include").path))
        #expect(!joined.contains("OVText"))   // no include folder: nothing
    }

    /// A host stand-in: a shell script that answers each request line.
    func scriptHost(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-fakehost-\(UUID().uuidString).sh")
        try "#!/bin/sh\necho 'YCODE-PREVIEW started'\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func theHostProcessAnswersRequestsAndAHostThatHangsIsStopped() throws {
        let ok = try scriptHost("while read line; do g=$(echo \"$line\" | sed 's/.*\"generation\":\\([0-9]*\\).*/\\1/'); echo \"YCODE-PREVIEW ready $g 7\"; done")
        defer { try? FileManager.default.removeItem(at: ok) }
        let h = try PreviewHostProcess(executable: ok)
        let r = h.send(PreviewOpenViewsHost.Request(generation: 4, payload: "/p.so", items: []), newPayload: true)
        #expect(r == .ready(generation: 4, milliseconds: 7))
        #expect(h.loads == 1)
        h.stop()
        #expect(!h.isRunning)

        let hang = try scriptHost("while read line; do :; done")
        defer { try? FileManager.default.removeItem(at: hang) }
        let saved = PreviewHostProcess.requestTimeout
        PreviewHostProcess.requestTimeout = 1
        defer { PreviewHostProcess.requestTimeout = saved }
        let h2 = try PreviewHostProcess(executable: hang)
        #expect(h2.send(PreviewOpenViewsHost.Request(generation: 1, payload: "/p.so", items: []), newPayload: true) == nil)
        #expect(!h2.isRunning)
        // A host that is gone answers nothing (and does not end the test with SIGPIPE).
        #expect(h2.send(PreviewOpenViewsHost.Request(generation: 2, payload: "/p.so", items: []), newPayload: false) == nil)
    }

    @Test func uikitPreviewsAreFoundByTheirImportOrTheirBody() {
        #expect(PreviewDiscovery.needsUIKit(text: "import UIKit\n#Preview { UILabel() }\n"))
        #expect(PreviewDiscovery.needsUIKit(text: "@preconcurrency import UIKit\n"))
        #expect(PreviewDiscovery.needsUIKit(text: "import SwiftUI\n#Preview { let c = UIViewController(); return c }\n"))
        #expect(!PreviewDiscovery.needsUIKit(text: "import SwiftUI\n#Preview { Text(\"UILabel\") }\n"))   // a string, not code
        #expect(!PreviewDiscovery.needsUIKit(text: "// import UIKit\nimport SwiftUI\n#Preview { Text(\"x\") }\n"))
        #expect(!PreviewDiscovery.needsUIKit(text: "import SwiftUI\nstruct UIThing {}\n#Preview { Text(\"x\") }\n"))
    }

    @Test func requestsCarryEachPicturesTraitsAndFile() throws {
        let r = PreviewOpenViewsHost.Request(generation: 2, payload: "/w/payload-2.so",
                                             items: [.init(index: 1, width: 402, height: 874, dark: true, dynamicType: "accessibility3", file: "/w/R/0@2x.png")])
        let line = r.line()
        #expect(line.hasSuffix("\n"))
        let back = try JSONDecoder().decode(PreviewOpenViewsHost.Request.self, from: Data(line.utf8))
        #expect(back == r)
        #expect(line.contains("\"dynamicType\":\"accessibility3\""))
    }
}

#if os(Linux)
/// Builds the real host against the repository's OpenViews and renders a
/// payload: the first run builds OpenViews in release (minutes).
@Suite(.timeLimit(.minutes(60)), .enabled(if: ProcessInfo.processInfo.environment["YCODE_PREVIEW_OPENVIEWS_TESTS"] == "1"))
struct OpenViewsHostEndToEndTests {
    @Test func aPayloadRendersLightAndDarkPicturesAndAnEditReloads() throws {
        let here = URL(fileURLWithPath: #filePath)
        guard let ov = PreviewRenderHost.locateOpenViews(environment: ProcessInfo.processInfo.environment, starts: [here]) else {
            Issue.record("no frameworks/swiftui above \(here.path)"); return
        }
        let cache = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        let built = try PreviewOpenViewsHost.build(openViews: ov, cacheRoot: cache)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-ove2e-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let file = work.appendingPathComponent("Card.swift")
        let host = try PreviewHostProcess(executable: built.executable)
        defer { host.stop() }
        var times: [Double] = []
        for (g, title) in ["One", "Two", "Three"].enumerated() {
            let text = "import SwiftUI\nstruct Card: View {\n    var body: some View { Text(\"\(title)\").padding() }\n}\n#Preview { Card() }\n"
            try text.write(to: file, atomically: true, encoding: .utf8)
            let previews = PreviewDiscovery.previews(in: text)
            let t0 = Date()
            let s = try PreviewPayloadGenerator.generate(moduleFiles: [file], previewed: [PreviewedFile(url: file, previews: previews)],
                                                         kit: .openViews, into: work.appendingPathComponent("src"))
            let payload = work.appendingPathComponent("payload-\(g).so")
            try PreviewOpenViewsHost.compilePayload(s, output: payload, moduleName: "Cards", built: built)
            let items = [false, true].map { dark in
                PreviewOpenViewsHost.Request.Item(index: 0, width: 393, height: 852, dark: dark, file: work.appendingPathComponent("\(g)-\(dark)@2x.png").path)
            }
            let r = host.send(PreviewOpenViewsHost.Request(generation: g + 1, payload: payload.path, items: items), newPayload: true)
            times.append(Date().timeIntervalSince(t0))
            guard case .ready? = r else { Issue.record("\(String(describing: r))"); return }
            for i in items {
                let d = try Data(contentsOf: URL(fileURLWithPath: i.file))
                #expect(d.starts(with: [0x89, 0x50, 0x4e, 0x47]))
            }
        }
        print("OpenViews preview: compile + render light and dark: \(times.map { String(format: "%.2f", $0) }) s")
        // An edit's payload: well under the 2 s budget on an idle machine.
        #expect(times.dropFirst().allSatisfy { $0 < 10 })
        // A compile error maps back to the file's line.
        let bad = "import SwiftUI\n#Preview { Text(nope) }\n"
        try bad.write(to: file, atomically: true, encoding: .utf8)
        let s = try PreviewPayloadGenerator.generate(moduleFiles: [file], previewed: [PreviewedFile(url: file, previews: PreviewDiscovery.previews(in: bad))],
                                                     kit: .openViews, into: work.appendingPathComponent("src"))
        #expect(throws: PreviewFailure.self) { try PreviewOpenViewsHost.compilePayload(s, output: work.appendingPathComponent("bad.so"), moduleName: "Cards", built: built) }
        do throws(PreviewFailure) {
            try PreviewOpenViewsHost.compilePayload(s, output: work.appendingPathComponent("bad.so"), moduleName: "Cards", built: built)
        } catch {
            #expect(error.issues.first?.file?.lastPathComponent == "Card.swift")
            #expect(error.issues.first?.line == 2)
        }
    }
}
#endif

/// UIKit previews from Linux: the SDK copy and the bundled-plan host (issue #84).
@Suite(.timeLimit(.minutes(2))) struct IOSToolchainTests {
    @Test func theToolchainIsFoundInTheUsersSDKCopyOrSaysWhatIsMissing() throws {
        let fm = FileManager.default
        guard case .failure(let none) = PreviewIOSToolchain.locate(environment: [:]) else { Issue.record("found without YCODE_USER_SDK"); return }
        #expect(none.description.contains("YCODE_USER_SDK"))
        let dev = fm.temporaryDirectory.appendingPathComponent("ycode-usersdk-\(UUID().uuidString)/Developer")
        defer { try? fm.removeItem(at: dev.deletingLastPathComponent()) }
        let sdk = dev.appendingPathComponent("Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator27.1.sdk")
        let rt = dev.appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/21.0.0/lib/darwin")
        for d in [sdk, rt, dev.appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/lib/swift"),
                  dev.appendingPathComponent("Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk")] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        try Data().write(to: rt.appendingPathComponent("libclang_rt.iossim.a"))
        let ld = dev.appendingPathComponent("ld64.lld")
        try "#!/bin/sh\n".write(to: ld, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ld.path)
        let found = PreviewIOSToolchain.locate(environment: ["YCODE_USER_SDK": dev.path, "YCODE_LD64": ld.path])
        guard case .success(let tc) = found else { Issue.record("\(found)"); return }
        #expect(tc.sdk.lastPathComponent == "iPhoneSimulator27.1.sdk" && tc.sdkVersion == "27.1")
        let args = tc.arguments(sources: [URL(fileURLWithPath: "/w/0_Badge.swift")], output: URL(fileURLWithPath: "/w/app/Previews/payload.dylib"),
                                moduleName: "Views", library: true, moduleCache: URL(fileURLWithPath: "/w/ModuleCache"))
        #expect(Array(args.prefix(2)) == ["-target", "arm64-apple-ios27.1-simulator"])
        #expect(args.contains("-use-ld=lld") && args.contains("-ld-path=" + ld.path) && args.contains("-emit-library"))
        #expect(args.contains("@rpath/payload.dylib") && args.last == "/w/0_Badge.swift")
        let host = tc.arguments(sources: [URL(fileURLWithPath: "/w/main.swift")], output: URL(fileURLWithPath: "/w/YcodePreviewHost"),
                                moduleName: "YcodePreviewHost", library: false, moduleCache: URL(fileURLWithPath: "/w/mc"))
        #expect(!host.contains("-emit-library"))
    }

    @Test func theBundledHostReadsItsPlanAndPayloadFromTheApp() {
        let s = PreviewHost.bundledPlanSource
        #expect(s.contains(#"?? (Bundle.main.bundlePath + "/Previews")"#))
        #expect(s.contains(#"dlopen(payload.hasPrefix("/") ? payload : previewDirectory + "/" + payload"#))
        #expect(!s.contains(#"?? "/tmp/ycode-previews""#))
    }
}
