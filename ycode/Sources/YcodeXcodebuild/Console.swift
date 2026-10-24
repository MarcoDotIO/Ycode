import Foundation

/// Where ycodebuild writes. Tests capture both streams.
public final class Console: @unchecked Sendable {
    private let lock = NSLock()
    private let writeOut: (String) -> Void
    private let writeErr: (String) -> Void

    /// stdout is a terminal (some lines then appear where they are
    /// printed, not at exit; see `outDeferred`).
    public let outputIsTerminal: Bool
    private var deferred: [String] = []

    public init(out: @escaping (String) -> Void, err: @escaping (String) -> Void, outputIsTerminal: Bool = false) {
        writeOut = out
        writeErr = err
        self.outputIsTerminal = outputIsTerminal
    }

    /// The process's stdout and stderr.
    public static func standard() -> Console {
        Console(out: { FileHandle.standardOutput.write(Data($0.utf8)) },
                err: { FileHandle.standardError.write(Data($0.utf8)) },
                outputIsTerminal: isatty(STDOUT_FILENO) != 0)
    }

    /// A line the reference tool writes through a buffered stream: on a
    /// terminal it appears at once, otherwise at exit, after everything
    /// else (`Testing started`; `specs/xcodebuild/test-actions.md` §2).
    public func outDeferred(_ text: String) {
        if outputIsTerminal { out(text) } else { lock.withLock { deferred.append(text) } }
    }

    /// Prints the deferred lines (at exit).
    public func flushDeferred() {
        let lines = lock.withLock { () -> [String] in defer { deferred = [] }; return deferred }
        for l in lines { out(l) }
    }

    /// Writes `text` followed by a newline.
    public func out(_ text: String = "") { lock.withLock { writeOut(text + "\n") } }
    public func err(_ text: String = "") { lock.withLock { writeErr(text + "\n") } }
    public func rawOut(_ text: String) { lock.withLock { writeOut(text) } }

    /// `xcodebuild: error: …` lines on stderr, plus usage text if asked.
    func report(_ f: XcodebuildFailure) {
        for m in f.messages { err("xcodebuild: error: \(m)") }
        if f.trailingBlank { err() }
        if f.withUsage {
            err()
            err(HelpText.usageAndOptions)
        }
    }

    func warning(_ text: String) { err("--- xcodebuild: WARNING: \(text)") }
}

/// A test console that records everything.
public final class CapturingConsole: @unchecked Sendable {
    private let lock = NSLock()
    private var _out = ""
    private var _err = ""
    public init() {}
    public var stdout: String { lock.withLock { _out } }
    public var stderr: String { lock.withLock { _err } }
    public var console: Console {
        Console(out: { [self] s in lock.withLock { _out += s } }, err: { [self] s in lock.withLock { _err += s } })
    }
}

/// JSON the way xcodebuild prints it: pretty-printed with `"key" : value`,
/// keys sorted, slashes not escaped, one trailing newline.
enum JSONText {
    static func render(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// `-usage` / `-help` text. See `specs/xcodebuild/cli.md` §2.
public enum HelpText {
    static let usageForms = [
        "xcodebuild [-project <projectname>] [[-target <targetname>]...|-alltargets] [-configuration <configurationname>] [-arch <architecture>]... [-sdk [<sdkname>|<sdkpath>]] [-showBuildSettings [-json]] [<buildsetting>=<value>]... [<buildaction>]...",
        "xcodebuild [-project <projectname>] -scheme <schemeName> [-destination <destinationspecifier>]... [-configuration <configurationname>] [-arch <architecture>]... [-sdk [<sdkname>|<sdkpath>]] [-showBuildSettings [-json]] [-showdestinations] [<buildsetting>=<value>]... [<buildaction>]...",
        "xcodebuild -workspace <workspacename> -scheme <schemeName> [-destination <destinationspecifier>]... [-configuration <configurationname>] [-arch <architecture>]... [-sdk [<sdkname>|<sdkpath>]] [-showBuildSettings] [-showdestinations] [<buildsetting>=<value>]... [<buildaction>]...",
        "xcodebuild -version [-sdk [<sdkfullpath>|<sdkname>] [-json] [<infoitem>] ]",
        "xcodebuild -list [[-project <projectname>]|[-workspace <workspacename>]] [-json]",
        "xcodebuild -showsdks [-json]",
        "xcodebuild -exportArchive -archivePath <xcarchivepath> [-exportPath <destinationpath>] -exportOptionsPlist <plistpath>",
        "xcodebuild -exportNotarizedApp -archivePath <xcarchivepath> -exportPath <destinationpath>",
        "xcodebuild -exportLocalizations -localizationPath <path> -project <projectname> [-defaultLanguage <language>] [-exportLanguage <targetlanguage>... [-includeScreenshots]]",
        "xcodebuild -importLocalizations -localizationPath <path> -project <projectname> [-mergeImport]",
        "xcodebuild -resolvePackageDependencies [-project <projectname>|-workspace <workspacename>] -clonedSourcePackagesDirPath <path>",
        "xcodebuild -create-xcframework [-help] [-framework <path>] [-library <path> [-headers <path>]] -output <path>",
        "xcodebuild -downloadPlatform <iOS|watchOS|tvOS|visionOS>  [-exportPath <destinationpath> -buildVersion <osversion> -architectureVariant <universal|arm64>]",
        "xcodebuild -downloadAllPlatforms [-exportPath <destinationpath> -architectureVariant <universal|arm64>]",
        "xcodebuild -importPlatform <simruntimedmgpath>",
        "xcodebuild -downloadComponent <componenttype> [-exportPath <destinationpath> -buildVersion <assetversion>]",
        "xcodebuild -importComponent <componenttype> -importPath <bundlepath>",
        "xcodebuild -deleteComponent <componenttype>",
        "xcodebuild -showComponent <componenttype> [-json]",
    ]

    public static var usage: String {
        usageForms.enumerated().map { ($0.offset == 0 ? "Usage: " : "       ") + $0.element }.joined(separator: "\n")
    }

    /// Options hidden from `-help` (sub-options of other commands).
    static let hidden: Set<String> = ["-framework", "-library", "-headers", "-debug-symbols", "-output", "-dumpPIF",
                                      "-checkForNewerComponents", "-includeScreenshots", "-mergeImport", "-buildVersion",
                                      "-architectureVariant"]

    public static var options: String {
        var lines = ["Options:"]
        for o in ArgumentParser.options where !hidden.contains(o.name) {
            let head = "    " + o.name + (o.placeholder.isEmpty ? "" : " " + o.placeholder)
            lines.append(head.padding(toLength: max(61, head.count + 1), withPad: " ", startingAt: 0) + o.summary)
        }
        return lines.joined(separator: "\n")
    }

    /// The text after a usage error.
    public static var usageAndOptions: String { usage + "\n\n" + options }

    /// `-help`: usage, options, and the export-options key names.
    public static var help: String {
        let keys = ["destination", "distributionBundleIdentifier", "embedOnDemandResourcesAssetPacksInBundle",
                    "generateAppStoreInformation", "iCloudContainerEnvironment", "installerSigningCertificate",
                    "manageAppVersionAndBuildNumber", "manifest", "method", "onDemandResourcesAssetPacksBaseURL",
                    "provisioningProfiles", "signingCertificate", "signingStyle", "stripSwiftSymbols", "teamID",
                    "testFlightInternalTestingOnly", "thinning", "uploadSymbols"]
        return usageAndOptions + "\n\nAvailable keys for -exportOptionsPlist:\n\n" + keys.map { "\t" + $0 }.joined(separator: "\n") + "\n"
    }
}
