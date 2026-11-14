// The previews' module cache after its folder moves (specs/ide/previews.md
// §Fast updates, "Module cache location"): a cache stamped for another
// place, or without a stamp, is emptied before use; a compile that crashes
// runs once more with an empty cache. Stand-in compilers are shell scripts,
// so these run on Linux too.

import Foundation
import Testing
@testable import YcodePreviews

@Suite struct PreviewModuleCacheTests {
    let fm = FileManager.default

    func scratch() throws -> URL {
        let d = fm.temporaryDirectory.appendingPathComponent("ycode-pmc-\(UUID().uuidString)")
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func stamp(_ cache: URL) -> String? {
        (try? String(contentsOf: PreviewModuleCache.stampURL(for: cache), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func warm(_ cache: URL) throws {
        PreviewModuleCache.prepare(cache)
        try Data("pcm".utf8).write(to: cache.appendingPathComponent("Old.pcm"))
    }

    func has(_ cache: URL) -> Bool { fm.fileExists(atPath: cache.appendingPathComponent("Old.pcm").path) }

    @Test func aNewCacheIsStampedWithItsRealPath() throws {
        let root = try scratch(); defer { try? fm.removeItem(at: root) }
        let cache = root.appendingPathComponent("work/ModuleCache")
        PreviewModuleCache.prepare(cache)
        #expect(fm.fileExists(atPath: cache.path))
        #expect(stamp(cache) == cache.resolvingSymlinksInPath().path)
    }

    @Test func aWarmCacheInTheSamePlaceIsKept() throws {
        let root = try scratch(); defer { try? fm.removeItem(at: root) }
        let cache = root.appendingPathComponent("work/ModuleCache")
        try warm(cache)
        PreviewModuleCache.prepare(cache)
        #expect(has(cache))
    }

    @Test func aProjectMovedToANewFolderGetsAnEmptyCache() throws {
        let root = try scratch(); defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent("drive-a/project"), new = root.appendingPathComponent("drive-b/project")
        try warm(old.appendingPathComponent(".build-ide/previews/work-canvas/ModuleCache"))
        try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: old, to: new)
        let cache = new.appendingPathComponent(".build-ide/previews/work-canvas/ModuleCache")
        #expect(has(cache))
        PreviewModuleCache.prepare(cache)
        #expect(!has(cache))
        #expect(stamp(cache) == cache.resolvingSymlinksInPath().path)
    }

    @Test func aCacheWithoutAStampIsEmptied() throws {
        let root = try scratch(); defer { try? fm.removeItem(at: root) }
        let cache = root.appendingPathComponent("ModuleCache")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("pcm".utf8).write(to: cache.appendingPathComponent("Old.pcm"))
        PreviewModuleCache.prepare(cache)
        #expect(!has(cache))
    }

    @Test func aSymlinkToTheSameFolderKeepsTheCache() throws {
        let root = try scratch(); defer { try? fm.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        try warm(real.appendingPathComponent("ModuleCache"))
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        PreviewModuleCache.prepare(link.appendingPathComponent("ModuleCache"))
        #expect(has(real.appendingPathComponent("ModuleCache")))
    }

    @Test func aSymlinkPointedAtACopyGetsAnEmptyCache() throws {
        // The 2026-11-07 case: the same path, now a symlink to a copy on another drive.
        let root = try scratch(); defer { try? fm.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b"), link = root.appendingPathComponent("Active")
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: a)
        let cache = link.appendingPathComponent("work/ModuleCache")
        try warm(cache)
        try fm.copyItem(at: a, to: b)
        try fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: b)
        #expect(has(cache))
        PreviewModuleCache.prepare(cache)
        #expect(!has(cache))
        #expect(has(a.appendingPathComponent("work/ModuleCache")), "the old copy is left alone")
    }

    @Test func compilerCrashesAreToldFromCodeErrors() {
        #expect(PreviewModuleCache.looksLikeCompilerCrash("error: compile command failed due to signal 11 (use -v to see invocation)"))
        #expect(PreviewModuleCache.looksLikeCompilerCrash("Stack dump:\n0. Program arguments: swift-frontend"))
        #expect(PreviewModuleCache.looksLikeCompilerCrash("PLEASE submit a bug report to https://example.org"))
        #expect(!PreviewModuleCache.looksLikeCompilerCrash("/w/0_View.swift:3:5: error: cannot find 'greting' in scope"))
    }

    /// A stand-in compiler: the first run leaves a file in the cache and
    /// crashes (if `crashFirst`); a run that finds that file fails with a
    /// code error; otherwise it writes the output. It counts its runs.
    func standIn(in dir: URL, crashFirst: Bool, alwaysCodeError: Bool = false) throws -> (script: URL, count: URL) {
        let count = dir.appendingPathComponent("count")
        let script = dir.appendingPathComponent("compiler.sh")
        try """
        #!/bin/sh
        out=""; cache=""
        while [ $# -gt 0 ]; do
          case "$1" in -o) out="$2"; shift ;; -module-cache-path) cache="$2"; shift ;; esac
          shift
        done
        n=$(cat '\(count.path)' 2>/dev/null || echo 0); n=$((n + 1)); echo $n > '\(count.path)'
        if [ \(alwaysCodeError ? 1 : 0) = 1 ]; then echo "/w/0_View.swift:3:5: error: cannot find 'greting' in scope" >&2; exit 1; fi
        if [ \(crashFirst ? 1 : 0) = 1 ] && [ $n = 1 ]; then
          [ -n "$cache" ] && mkdir -p "$cache" && : > "$cache/Stale.pcm"
          echo "error: compile command failed due to signal 11 (use -v to see invocation)" >&2; exit 1
        fi
        if [ -n "$cache" ] && [ -e "$cache/Stale.pcm" ]; then echo "error: the stale cache was reused" >&2; exit 1; fi
        : > "$out"
        """.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, count)
    }

    func runs(_ count: URL) -> Int { Int((try? String(contentsOf: count, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0 }

    func sources(_ dir: URL) throws -> PreviewPayloadGenerator.Sources {
        let f = dir.appendingPathComponent("0_View.swift")
        try "struct V {}\n".write(to: f, atomically: true, encoding: .utf8)
        return .init(files: [f], lineMaps: [:], previews: [], previewFiles: [], changed: [])
    }

    @Test func aPayloadCompileThatCrashesRunsOnceMoreWithAnEmptyCache() throws {
        let root = try scratch(); defer { try? fm.removeItem(at: root) }
        let s = try standIn(in: root, crashFirst: true)
        var c = PreviewCompiler(platform: .iOS, deploymentTarget: "27.0", moduleName: "App", moduleCache: root.appendingPathComponent("ModuleCache"))
        c.xcrun = s.script.path
        let out = root.appendingPathComponent("payload-1.dylib")
        try c.compilePayload(try sources(root), output: out)
        #expect(fm.fileExists(atPath: out.path))
        #expect(runs(s.count) == 2)
    }

    @Test func aCodeErrorIsNotRetried() throws {
        let root = try scratch(); defer { try? fm.removeItem(at: root) }
        let s = try standIn(in: root, crashFirst: false, alwaysCodeError: true)
        var c = PreviewCompiler(platform: .iOS, deploymentTarget: "27.0", moduleName: "App", moduleCache: root.appendingPathComponent("ModuleCache"))
        c.xcrun = s.script.path
        #expect(throws: PreviewFailure.self) { try c.compilePayload(try sources(root), output: root.appendingPathComponent("p.dylib")) }
        #expect(runs(s.count) == 1)
    }

    @Test func theLinuxPayloadCompileRetriesACrashWithItsOwnEmptyCache() throws {
        let root = try scratch(); defer { try? fm.removeItem(at: root) }
        let s = try standIn(in: root, crashFirst: true)
        let out = root.appendingPathComponent("Live/payload-1.so")
        try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The first run has no cache path of its own, so the crash leaves
        // nothing behind; the retry names an empty cache beside the output.
        try warm(out.deletingLastPathComponent().appendingPathComponent("ModuleCache"))
        try PreviewOpenViewsHost.compilePayload(try sources(root), output: out, moduleName: "Views",
                                                built: .init(executable: root, moduleFlags: []), swiftc: ["/bin/sh", s.script.path])
        #expect(fm.fileExists(atPath: out.path))
        #expect(runs(s.count) == 2)
        #expect(!has(out.deletingLastPathComponent().appendingPathComponent("ModuleCache")))
    }
}
