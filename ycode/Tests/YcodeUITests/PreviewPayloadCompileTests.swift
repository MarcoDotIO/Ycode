#if os(macOS)
import Foundation
import Testing
import YcodeSubprocess
@testable import YcodeUI

/// The simulator path's payloads and hosts compile with the installed SDKs
/// (specs/ide/previews.md §Live previews): SwiftUI content, a view
/// controller body, a view body, `@Previewable` state and a provider, for
/// iOS and visionOS. Skipped for an SDK that is not installed. No device.
@Suite(.serialized, .heavyIntegration, .previewHostCheck, .timeLimit(.minutes(10))) struct PreviewPayloadCompileTests {
    static let source = """
    import SwiftUI
    import UIKit

    fileprivate let secret = "fileprivate"

    struct Card: View {
        var title: String
        var body: some View { Text(title).padding() }
    }

    final class LegacyController: UIViewController {}

    #Preview("Content") {
        Card(title: secret)
        Card(title: "two")
    }

    #Preview("Controller") {
        let c = LegacyController()
        c.title = "UIKit"
        return c
    }

    #Preview("View") {
        UILabel()
    }

    #Preview("State") {
        @Previewable @State var on = true
        Toggle("On", isOn: $on)
    }

    struct Card_Previews: PreviewProvider {
        static var previews: some View { Card(title: "provider") }
    }
    """

    static func sdkInstalled(_ sdk: String) -> Bool {
        ((try? Subprocess.run("/usr/bin/xcrun", ["--sdk", sdk, "--show-sdk-path"]))?.status ?? 1) == 0
    }

    @Test(arguments: [(PreviewPlatform.iOS, "27.0"), (PreviewPlatform.visionOS, "27.0")])
    func payloadAndHostCompile(platform: PreviewPlatform, target: String) async throws {
        guard Self.sdkInstalled(platform.sdk) else { print("skipping: no \(platform.sdk) SDK"); return }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-payload-compile-\(getpid())")
        let dir = work.appendingPathComponent(platform.rawValue)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("Card.swift")
        try Self.source.write(to: file, atomically: true, encoding: .utf8)
        let previews = PreviewDiscovery.previews(in: Self.source)
        #expect(previews.count == 5)
        let sources = try PreviewPayloadGenerator.generate(moduleFiles: [file], previewed: [PreviewedFile(url: file, previews: previews)],
                                                           platform: platform, into: dir.appendingPathComponent("src"))
        let compiler = PreviewCompiler(platform: platform, deploymentTarget: target, moduleName: "Cards", moduleCache: work.appendingPathComponent("ModuleCache"))
        let out = dir.appendingPathComponent("payload-1.dylib")
        let t0 = Date()
        try await Task.detached { try compiler.compilePayload(sources, output: out) }.value
        print(String(format: "payload compile (%@): %.2f s", platform.rawValue, Date().timeIntervalSince(t0)))
        // The two entry points are exported.
        let nm = try Subprocess.run("/usr/bin/xcrun", ["nm", "-gU", out.path]).stdoutText
        #expect(nm.contains("_ycode_preview_make") && nm.contains("_ycode_preview_count"))
        let app = try await Task.detached { try PreviewHost.build(platform: platform, deploymentTarget: target, workDirectory: work) }.value
        #expect(FileManager.default.isExecutableFile(atPath: app.appendingPathComponent(PreviewHost.executableName).path))
        // An error in a preview body maps to the #Preview's line.
        let broken = Self.source.replacingOccurrences(of: "Card(title: \"two\")", with: "Card(title: missing)")
        try broken.write(to: file, atomically: true, encoding: .utf8)
        let s2 = try PreviewPayloadGenerator.generate(moduleFiles: [file], previewed: [PreviewedFile(url: file, previews: PreviewDiscovery.previews(in: broken))],
                                                      platform: platform, into: dir.appendingPathComponent("src"))
        do {
            try await Task.detached { try compiler.compilePayload(s2, output: dir.appendingPathComponent("payload-2.dylib")) }.value
            Issue.record("expected a compile error")
        } catch let f as PreviewFailure {
            #expect(f.issues.first?.file?.lastPathComponent == "Card.swift" && f.issues.first?.line == 15, "\(f.issues)")
        }
        try? FileManager.default.removeItem(at: work)
    }
}
#endif
