import Foundation
import YcodeBuild
import YcodeSubprocess

/// A preview problem the canvas shows as a banner, with the source position
/// it links to when there is one.
public struct PreviewIssue: Equatable, Sendable, CustomStringConvertible {
    public var file: URL?
    public var line: Int
    public var column: Int
    public var message: String
    public init(file: URL?, line: Int = 0, column: Int = 0, message: String) {
        self.file = file
        self.line = line
        self.column = column
        self.message = message
    }

    /// `File.swift:6: message`, or the message alone.
    public var description: String {
        guard let file else { return message }
        return "\(file.lastPathComponent):\(line): \(message)"
    }
}

/// Why a preview could not be shown.
public enum PreviewFailure: Error, Equatable, Sendable, CustomStringConvertible {
    /// The payload (or the host) did not compile; the first errors first.
    case compile([PreviewIssue])
    /// The module or the target cannot be previewed.
    case unsupported(String)
    /// The preview host or the device failed.
    case host(String)

    public var description: String {
        switch self {
        case .compile(let issues): issues.first?.description ?? "Compiling the preview failed"
        case .unsupported(let m): "Unsupported target kind: \(m)"
        case .host(let m): m
        }
    }

    public var issues: [PreviewIssue] {
        if case .compile(let i) = self { return i }
        return []
    }
}

/// Compiles preview payloads and hosts with the installed toolchain
/// (`xcrun --sdk <sdk> swiftc`). See `specs/ide/previews.md` §Fast updates.
public struct PreviewCompiler: Sendable {
    public var platform: PreviewPlatform
    public var deploymentTarget: String
    /// The Swift module name the previewed code is compiled under.
    public var moduleName: String
    /// The clang module cache (an absolute path; kept warm between compiles).
    public var moduleCache: URL
    /// `xcrun`; tests may substitute a script.
    public var xcrun = "/usr/bin/xcrun"
    /// Extra compiler flags (`-D` conditions, `-swift-version`).
    public var extraFlags: [String] = []

    public init(platform: PreviewPlatform, deploymentTarget: String, moduleName: String, moduleCache: URL) {
        self.platform = platform
        self.deploymentTarget = deploymentTarget
        self.moduleName = moduleName
        self.moduleCache = moduleCache.standardizedFileURL
    }

    /// The payload's arguments to `xcrun`: one whole-module, unoptimized
    /// frontend job (the fastest for the small modules previews compile),
    /// a dynamic library with its own install name (each generation is a
    /// new image the host can load next to the old ones), `DEBUG` set as
    /// in a debug build, Swift 5 language mode unless `extraFlags` say otherwise.
    public func payloadArguments(sources: [URL], output: URL) -> [String] {
        ["--sdk", platform.sdk, "swiftc",
         "-target", platform.targetTriple(deploymentTarget: deploymentTarget),
         "-emit-library", "-module-name", moduleName, "-parse-as-library", "-wmo", "-Onone", "-gnone",
         "-D", "DEBUG", "-D", "YCODE_PREVIEW",
         "-module-cache-path", moduleCache.path,
         "-Xlinker", "-install_name", "-Xlinker", "@rpath/\(output.lastPathComponent)",
         "-o", output.path]
            + (extraFlags.contains("-swift-version") ? [] : ["-swift-version", "5"])
            + extraFlags + sources.map(\.path)
    }

    /// Compiles a payload. Errors map back to the user's files and lines.
    public func compilePayload(_ sources: PreviewPayloadGenerator.Sources, output: URL) throws(PreviewFailure) {
        PreviewModuleCache.prepare(moduleCache)
        try? FileManager.default.removeItem(at: output)
        let out: Subprocess.Output
        do {
            out = try PreviewModuleCache.retryingAfterCrash(moduleCache) {
                try? FileManager.default.removeItem(at: output)
                return try Subprocess.run(xcrun, payloadArguments(sources: sources.files, output: output))
            } crashed: { $0.status != 0 && PreviewModuleCache.looksLikeCompilerCrash($0.stdoutText + "\n" + $0.stderrText) }
        } catch {
            throw .host("could not run xcrun: \(error)")
        }
        guard out.status == 0, FileManager.default.fileExists(atPath: output.path) else {
            throw .compile(Self.issues(from: out.stdoutText + "\n" + out.stderrText, lineMaps: sources.lineMaps))
        }
    }

    /// The errors of a compiler log, mapped through the copies' line maps
    /// (an error in a generated support file names no source).
    public static func issues(from log: String, lineMaps: [String: PreviewPayloadGenerator.LineMap]) -> [PreviewIssue] {
        let errors = DiagnosticParser.parse(log).filter { $0.severity == .error }
        var out: [PreviewIssue] = []
        for d in errors {
            if let l = d.location, let map = lineMaps[l.file] ?? lineMaps[URL(fileURLWithPath: l.file).standardizedFileURL.path] {
                out.append(PreviewIssue(file: map.original, line: map.fileLine(l.line), column: l.column, message: d.message))
            } else {
                out.append(PreviewIssue(file: nil, message: d.message))
            }
        }
        if out.isEmpty {
            let last = log.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map(String.init)
            out.append(PreviewIssue(file: nil, message: last ?? "Compiling the preview failed"))
        }
        // Errors with a position in the user's files first.
        return out.filter { $0.file != nil } + out.filter { $0.file == nil }
    }
}
