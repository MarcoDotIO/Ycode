import Foundation
import YcodeSubprocess

/// Renders one `#Preview` of a file to a PNG headlessly: writes the
/// `PreviewRenderHost` package, builds it against OpenViews and runs it
/// (`ycode preview --render`, the MCP server's `preview_render`). See
/// specs/ide/previews.md §Linux.
public enum PreviewRenderRunner {
    public struct Failure: Error, CustomStringConvertible, Sendable {
        public var description: String
        /// The build's or the host's output, when there is one.
        public var log: String
        /// 1: the preview did not build or render; 3: it cannot be rendered.
        public var status: Int32
        public init(_ description: String, log: String = "", status: Int32 = 3) {
            self.description = description
            self.log = log
            self.status = status
        }
    }

    /// Renders `name` (or the first preview) of `file` to `output`. `starts`
    /// are folders the OpenViews package is looked for above; `progress`
    /// gets status lines. Blocks: call it off the main thread.
    public static func render(file: String, name: String?, output: String, starts: [URL],
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              progress: (String) -> Void = { _ in }) -> Result<URL, Failure> {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return .failure(Failure("cannot read \(file)")) }
        let previews = PreviewDiscovery.previews(in: text)
        guard let chosen = name.map({ n in previews.first { $0.name == n } }) ?? previews.first else {
            return .failure(Failure("\(file) declares no preview\(name.map { " named \($0)" } ?? "")", status: 1))
        }
        guard case .macro = chosen.kind else {
            return .failure(Failure("cannot render \"\(chosen.name)\": headless rendering supports #Preview macros (PreviewProvider types are listed only)"))
        }
        let fm = FileManager.default
        guard let openViews = PreviewRenderHost.locateOpenViews(environment: environment, starts: starts + [URL(fileURLWithPath: file).deletingLastPathComponent()]) else {
            return .failure(Failure("cannot find the open SwiftUI port (frameworks/swiftui); set YCODE_OPENVIEWS to its directory"))
        }
        #if os(macOS)
        let appleHost = true
        #else
        let appleHost = false
        #endif
        let cacheRoot = environment["XDG_CACHE_HOME"].map { URL(fileURLWithPath: $0) } ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        let dir = cacheRoot.appendingPathComponent("ycode/preview-render")
        let files = PreviewRenderHost.files(source: text, preview: chosen, all: previews, openViewsPath: openViews.path, appleHost: appleHost)
        do {
            for (path, contents) in files {
                let url = dir.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Unchanged files keep their dates, so rebuilds stay incremental.
                if (try? String(contentsOf: url, encoding: .utf8)) != contents { try contents.write(to: url, atomically: true, encoding: .utf8) }
            }
        } catch {
            return .failure(Failure("cannot write the preview package in \(dir.path): \(error)"))
        }
        progress("building the preview host against \(openViews.path)")
        let (status, log) = run(["swift", "build", "--package-path", dir.path, "--product", "PreviewHost"])
        guard status == 0 else { return .failure(Failure("the preview did not build (lines in Preview.swift are the file's lines)", log: log, status: 1)) }
        let (_, binPath) = run(["swift", "build", "--package-path", dir.path, "--show-bin-path"])
        let binary = URL(fileURLWithPath: binPath.trimmingCharacters(in: .whitespacesAndNewlines)).appendingPathComponent("PreviewHost")
        let out = URL(fileURLWithPath: output, relativeTo: URL(fileURLWithPath: fm.currentDirectoryPath)).standardizedFileURL
        let (rs, rlog) = run([binary.path, out.path])
        guard rs == 0 else { return .failure(Failure("rendering \"\(chosen.name)\" failed (status \(rs))", log: rlog, status: 1)) }
        return .success(out)
    }

    static func run(_ arguments: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = arguments
        let pipe: SpawnPipe
        do { pipe = try SpawnPipe(childReads: false) } catch { return (127, "\(error)") }
        p.standardOutput = pipe.childEnd
        p.standardError = pipe.childEnd
        p.standardInput = FileHandle.nullDevice
        do { try p.runWithSignalsUnblocked(closingChildEndsOf: pipe) } catch { return (127, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
