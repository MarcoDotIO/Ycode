import Foundation
import YcodeSubprocess

/// Supplies exported build settings without running xcodebuild (e.g.
/// `YcodeXcodebuild.SwiftBuildSettingsSource`, through the `ycode-swb`
/// helper and swift-build).
public protocol BuildSettingsSource: Sendable {
    func buildSettings(for request: BuildRequest) throws -> [(target: String, settings: [String: String])]
}

extension XcodebuildEngine {
    /// Build settings per target: from `settingsSource` when set, else from
    /// `xcodebuild -showBuildSettings -json`. Used to find the product to
    /// run (`TARGET_BUILD_DIR`/`EXECUTABLE_PATH`).
    public func buildSettings(for request: BuildRequest) throws -> [(target: String, settings: [String: String])] {
        if let settingsSource { return try settingsSource.buildSettings(for: request) }
        var r = request
        r.action = .build
        let overrides = r.settings.map { "\($0)=\($1)" }
        r.settings = []
        MainThreadGuard.blockingCall("xcodebuild -showBuildSettings")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst()) + Self.arguments(for: r).dropLast() + ["-showBuildSettings", "-json"] + overrides
        if case .package(let dir) = request.container { process.currentDirectoryURL = URL(fileURLWithPath: dir) }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.map { entry in
            let s = (entry["buildSettings"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
            return (entry["target"] as? String ?? "", s)
        }
    }

    /// The executable a scheme's build produces: the first application or
    /// command-line tool target.
    public func executablePath(for request: BuildRequest) -> String? {
        guard let all = try? buildSettings(for: request) else { return nil }
        let runnable: Set<String> = ["com.apple.product-type.application", "com.apple.product-type.tool"]
        for (_, s) in all {
            guard let dir = s["TARGET_BUILD_DIR"], let exe = s["EXECUTABLE_PATH"] else { continue }
            // Package executables report no product type; accept them too.
            if runnable.contains(s["PRODUCT_TYPE"] ?? "") || s["PRODUCT_TYPE"] == nil || s["MACH_O_TYPE"] == "mh_execute" {
                return dir + "/" + exe
            }
        }
        return nil
    }
}
