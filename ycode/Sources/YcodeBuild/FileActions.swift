import Foundation

/// Product ▸ Perform Action ▸ Compile / Analyze / Preprocess / Assemble
/// “<file>” (`specs/ide/reference-ui-5.md` §2.9): one source file is
/// processed in the context of the module that compiles it, without
/// building the rest of the scheme. Ycode runs the open-source compilers
/// directly: `swiftc -frontend` with the file as the primary file and the
/// module's other Swift files as secondary inputs, or `clang` for C-family
/// files. The diagnostics are reported like a build's.
public enum FileAction: String, Sendable, CaseIterable {
    case compile, analyze, preprocess, assemble

    /// The verb of the menu title ("Compile “main.swift”").
    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// Whether the toolchain can perform the action on a file of this
    /// language: Swift files compile and assemble; the static analyzer and
    /// the preprocessor are clang's, for C-family files only.
    public func supports(_ language: SourceLanguage) -> Bool {
        switch self {
        case .compile, .assemble: return true
        case .analyze, .preprocess: return language != .swift
        }
    }

    /// The output file's extension (nil: the action writes no file to show).
    var outputExtension: String {
        switch self {
        case .compile: "o"
        case .analyze: "plist"
        case .preprocess: "i"
        case .assemble: "s"
        }
    }
}

/// The languages Perform Action handles, from the file extension.
public enum SourceLanguage: String, Sendable {
    case swift, c, objc, cxx, objcxx

    public init?(path: String) {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "swift": self = .swift
        case "c": self = .c
        case "m": self = .objc
        case "cc", "cpp", "cxx", "c++": self = .cxx
        case "mm": self = .objcxx
        default: return nil
        }
    }

    /// clang's `-x` language name.
    var clangName: String {
        switch self {
        case .swift: "swift"
        case .c: "c"
        case .objc: "objective-c"
        case .cxx: "c++"
        case .objcxx: "objective-c++"
        }
    }
}

/// What a single-file action needs to know about the module the file
/// belongs to. The IDE fills it from the project's build settings (or the
/// package layout); the defaults suit a plain host build.
public struct FileBuildContext: Equatable, Sendable {
    /// The module the file compiles into (`PRODUCT_MODULE_NAME`).
    public var moduleName: String
    /// The module's other Swift files (secondary inputs for type checking).
    public var moduleSources: [String] = []
    /// The SDK to compile against (`-sdk` / `-isysroot`); nil = the host's.
    public var sdkPath: String?
    /// The target triple (`-target`); nil = the host's.
    public var targetTriple: String?
    /// `SWIFT_VERSION` ("5.0", "6"); passed as `-swift-version` (major
    /// version, or "4.2").
    public var swiftVersion: String?
    /// Module and header search paths (`-I`): headers, and the build
    /// products of the module's dependencies.
    public var includePaths: [String] = []
    /// Framework search paths (`-F`).
    public var frameworkPaths: [String] = []
    /// Compilation conditions / preprocessor macros (`-D`).
    public var defines: [String] = []
    /// Where outputs are written.
    public var outputDirectory: String

    public init(moduleName: String, moduleSources: [String] = [], sdkPath: String? = nil, targetTriple: String? = nil,
                swiftVersion: String? = nil, includePaths: [String] = [], frameworkPaths: [String] = [], defines: [String] = [],
                outputDirectory: String) {
        self.moduleName = moduleName
        self.moduleSources = moduleSources
        self.sdkPath = sdkPath
        self.targetTriple = targetTriple
        self.swiftVersion = swiftVersion
        self.includePaths = includePaths
        self.frameworkPaths = frameworkPaths
        self.defines = defines
        self.outputDirectory = outputDirectory
    }

    /// The `-swift-version` value for a `SWIFT_VERSION` setting: "5.0" →
    /// "5", "4.2" stays, "6" stays.
    public static func swiftLanguageMode(_ setting: String) -> String {
        let parts = setting.split(separator: ".")
        if parts.count >= 2, parts[0] == "4", parts[1] == "2" { return "4.2" }
        return parts.first.map(String.init) ?? setting
    }

    /// A C99 identifier for a module name ("My App" → "My_App"), as the
    /// build system derives `PRODUCT_MODULE_NAME` from the product name.
    public static func moduleIdentifier(_ name: String) -> String {
        var out = String(name.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
        if let f = out.first, f.isNumber { out = "_" + out }
        return out.isEmpty ? "main" : out
    }
}

/// Builds and runs the command of a single-file action.
public struct FileActionRunner: Sendable {
    /// The Swift compiler driver (its `-frontend` mode compiles one
    /// primary file).
    public var swiftc: [String]
    public var clang: [String]

    public init(swiftc: [String]? = nil, clang: [String]? = nil) {
        #if os(macOS)
        self.swiftc = swiftc ?? ["/usr/bin/xcrun", "swiftc"]
        self.clang = clang ?? ["/usr/bin/xcrun", "clang"]
        #else
        self.swiftc = swiftc ?? ["/usr/bin/env", "swiftc"]
        self.clang = clang ?? ["/usr/bin/env", "clang"]
        #endif
    }

    /// The output file of an action on `file`, or nil when the action is
    /// not supported for the file.
    public static func outputPath(_ action: FileAction, file: String, context: FileBuildContext) -> String? {
        guard let lang = SourceLanguage(path: file), action.supports(lang) else { return nil }
        let base = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        return URL(fileURLWithPath: context.outputDirectory).appendingPathComponent("\(base).\(action.outputExtension)").path
    }

    /// The command line (tool first), or nil when the action is not
    /// supported for the file's language.
    public func command(_ action: FileAction, file: String, context c: FileBuildContext) -> [String]? {
        guard let lang = SourceLanguage(path: file), action.supports(lang),
              let out = Self.outputPath(action, file: file, context: c) else { return nil }
        if lang == .swift {
            var a = swiftc + ["-frontend", action == .assemble ? "-S" : "-c", "-primary-file", file]
            let others = c.moduleSources.filter { URL(fileURLWithPath: $0).standardizedFileURL != URL(fileURLWithPath: file).standardizedFileURL }
            a += others
            // A module without a main.swift has no top-level code: every
            // file, the only one included, is parsed as a library file (as
            // SwiftPM and the build system do), so `@main` works.
            if !([file] + others).contains(where: { URL(fileURLWithPath: $0).lastPathComponent == "main.swift" }) {
                a.append("-parse-as-library")
            }
            a += ["-module-name", c.moduleName]
            if let sdk = c.sdkPath { a += ["-sdk", sdk] }
            if let t = c.targetTriple { a += ["-target", t] }
            if let v = c.swiftVersion, !v.isEmpty { a += ["-swift-version", FileBuildContext.swiftLanguageMode(v)] }
            for i in c.includePaths { a += ["-I", i] }
            for f in c.frameworkPaths { a += ["-F", f] }
            for d in c.defines { a += ["-D", d] }
            return a + ["-o", out]
        }
        var a = clang + ["-x", lang.clangName]
        switch action {
        case .compile: a.append("-c")
        case .analyze: a += ["--analyze", "-Xclang", "-analyzer-output=text"]
        case .preprocess: a.append("-E")
        case .assemble: a.append("-S")
        }
        a.append(file)
        if let sdk = c.sdkPath { a += ["-isysroot", sdk] }
        if let t = c.targetTriple { a += ["-target", t] }
        if lang == .objc || lang == .objcxx { a.append("-fobjc-arc") }
        for i in c.includePaths { a += ["-I", i] }
        for f in c.frameworkPaths { a += ["-F", f] }
        for d in c.defines { a += ["-D\(d)"] }
        return a + ["-o", out]
    }

    /// Runs the action. The stream reports the compiler's diagnostics; the
    /// output file is at `outputPath(_:file:context:)` when it succeeds.
    public func start(_ action: FileAction, file: String, context: FileBuildContext) -> BuildOperation {
        guard let args = command(action, file: file, context: context) else {
            let message = "\(action.title) is not available for \(URL(fileURLWithPath: file).lastPathComponent)"
            let d = Diagnostic(severity: .error, message: message)
            return BuildOperation(events: AsyncStream { c in
                c.yield(.issue(d))
                c.yield(.finished(BuildResult(status: .failed, exitCode: -1, issues: [d])))
                c.finish()
            }, cancel: {})
        }
        try? FileManager.default.createDirectory(atPath: context.outputDirectory, withIntermediateDirectories: true)
        let name = URL(fileURLWithPath: file).lastPathComponent
        let verb = action == .compile ? "Compiling" : action == .analyze ? "Analyzing" : action == .preprocess ? "Preprocessing" : "Assembling"
        let op = ProcessBuild.start(args, currentDirectory: URL(fileURLWithPath: file).deletingLastPathComponent().path)
        // The progress text names the file once, at the start.
        let (stream, continuation) = AsyncStream<BuildEvent>.makeStream()
        continuation.yield(.activity("\(verb) \(name)"))
        let events = op.events
        Task {
            for await e in events { continuation.yield(e) }
            continuation.finish()
        }
        return BuildOperation(events: stream, cancel: op.cancel)
    }
}
