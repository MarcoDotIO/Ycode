import Foundation
import Testing
@testable import YcodeBuild

/// The build hook that puts `ycode strings` in front of swift-build as its
/// `xcstringstool` (specs/ide/string-catalog.md, "Ycode implementation").
struct StringsCompilerHookTests {
    func tool() throws -> (dir: URL, tool: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-strings-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let t = dir.appendingPathComponent("ycode")
        try Data("#!/bin/sh\n".utf8).write(to: t)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: t.path)
        return (dir, t.path)
    }

    @Test func defaultsAndSettings() throws {
        let (dir, _) = try tool()
        defer { try? FileManager.default.removeItem(at: dir) }
        // An Xcode without the tool (a DEVELOPER_DIR that has none) means Ycode's.
        #expect(StringsCompilerHook.choice(settings: [], environment: ["DEVELOPER_DIR": dir.path]) == .ycode)
        #if os(macOS)
        let dev = dir.appendingPathComponent("Developer/usr/bin")
        try FileManager.default.createDirectory(at: dev, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: dev.appendingPathComponent("xcstringstool"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dev.appendingPathComponent("xcstringstool").path)
        let env = ["DEVELOPER_DIR": dir.appendingPathComponent("Developer").path]
        #expect(StringsCompilerHook.choice(settings: [], environment: env) == .xcstringstool)
        #expect(StringsCompilerHook.choice(settings: [("YCODE_STRINGS_COMPILER", "ycode")], environment: env) == .ycode)
        #else
        #expect(StringsCompilerHook.choice(settings: [], environment: [:]) == .ycode)
        #endif
        #expect(StringsCompilerHook.choice(settings: [("YCODE_STRINGS_COMPILER", "xcstringstool")], environment: ["YCODE_STRINGS_COMPILER": "ycode"]) == .xcstringstool)
    }

    @Test func writesTheWrapperAndTheSearchPath() throws {
        let (dir, ycode) = try tool()
        defer { try? FileManager.default.removeItem(at: dir) }
        let w = dir.appendingPathComponent("w")
        let env = try #require(StringsCompilerHook.environment(settings: [("YCODE_STRINGS_COMPILER", "ycode"), ("YCODE_STRINGS_TOOL", ycode)],
                                                               directory: w, base: ["PATH": "/usr/bin", "__XCODE_BUILT_PRODUCTS_DIR_PATHS": "/p"]))
        #expect(env["PATH"] == "/usr/bin")
        #expect(env["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] == w.path + ":/p")
        let text = try String(contentsOfFile: w.appendingPathComponent("xcstringstool").path, encoding: .utf8)
        #expect(FileManager.default.isExecutableFile(atPath: w.appendingPathComponent("xcstringstool").path))
        #expect(text.hasPrefix("#!/bin/sh\n") && text.hasSuffix("exec '\(ycode)' strings \"$@\"\n"))
        // Xcode's tool, or no ycode: the environment is left alone.
        #expect(StringsCompilerHook.environment(settings: [("YCODE_STRINGS_COMPILER", "xcstringstool"), ("YCODE_STRINGS_TOOL", ycode)], directory: w, base: [:]) == nil)
        #expect(StringsCompilerHook.environment(settings: [("YCODE_STRINGS_COMPILER", "ycode"), ("YCODE_STRINGS_TOOL", "/no/ycode")], directory: w, base: [:]) == nil)
    }

    @Test func encodingOverrideOffMacOS() {
        let o = StringsCompilerHook.overrides(settings: [("YCODE_STRINGS_COMPILER", "ycode")], environment: [:])
        #if os(macOS)
        #expect(o.isEmpty)
        #else
        #expect(o.map(\.0) == ["STRINGS_FILE_INPUT_ENCODING"] && o.map(\.1) == ["$(InputFileTextEncoding:default=utf-8)"])
        #expect(StringsCompilerHook.overrides(settings: [("STRINGS_FILE_INPUT_ENCODING", "utf-16")], environment: [:]).isEmpty)
        #endif
    }
}
