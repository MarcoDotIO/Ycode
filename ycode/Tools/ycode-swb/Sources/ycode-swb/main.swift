import Foundation
import SwiftBuild

// ycode-swb: Ycode's bridge to swift-build's build service (open source,
// used as a library). See specs/xcodebuild/show-build-settings.md §3 and
// specs/xcodebuild/build-actions.md §3.
//
//   ycode-swb settings <request.json>
//     { "pif": path, "parameters": <SWBBuildParameters>,
//       "levels": [ {"target": guid} | {"project": guid} | {} ] }
//     → stdout: { "settings": [ {NAME: value} per level ], "diagnostics": [...] }
//
//   ycode-swb build <request.json>
//     { "pif": path, "parameters": <SWBBuildParameters>, "targets": [guid],
//       "containerPath": path, "parallel": bool, "implicitDependencies": bool,
//       "hideShellScriptEnvironment": bool, "continueAfterErrors": bool,
//       "command": "build" | "cleanBuildFolder", "locationStyle": "regular" | "legacy" }
//     → stdout: one swift-build message (SwiftBuildMessage JSON) per line.
//       Exit status 0 when the build succeeded, 1 when it failed.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ycode-swb: \(message)\n".utf8))
    exit(2)
}

struct SettingsRequest: Decodable {
    var pif: String
    var parameters: SWBBuildParameters
    var levels: [[String: String]]
}

struct BuildRequestFile: Decodable {
    var pif: String
    var parameters: SWBBuildParameters
    var targets: [String]
    var containerPath: String?
    var parallel: Bool?
    var implicitDependencies: Bool?
    var hideShellScriptEnvironment: Bool?
    var continueAfterErrors: Bool?
    /// "build" (default) or "cleanBuildFolder".
    var command: String?
    /// "regular" (DerivedData) or "legacy" (per-project build directory).
    var locationStyle: String?
    /// The scheme command ("launch", "test", "profile", "archive"); archive
    /// turns on its validations (swift-build's SWBSchemeCommand).
    var schemeCommand: String?
    /// Add `com.apple.security.get-task-allow` to ad hoc signatures
    /// (default true; false for archives, which are not debuggable).
    var debuggable: Bool?
}

func decode<T: Decodable>(_ type: T.Type, _ path: String) -> T {
    do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: URL(fileURLWithPath: path))) } catch {
        fail("cannot read request \(path): \(error)")
    }
}

/// Opens a session with the PIF loaded and host system/user info set.
func withSession<R>(pif: String, _ body: (SWBBuildServiceSession, [String]) async throws -> R) async -> R {
    let service: SWBBuildService
    do { service = try await SWBBuildService() } catch { fail("cannot start the build service: \(error)") }
    let (result, sessionDiagnostics) = await service.createSession(name: pif, cachePath: nil, inferiorProductsPath: nil, environment: nil)
    let session: SWBBuildServiceSession
    switch result {
    case .success(let s): session = s
    case .failure(let e): fail("cannot create a session: \(e)")
    }
    do {
        // The workspace must be loaded before system and user info are set.
        try await session.loadWorkspace(containerPath: pif)
        _ = try await session.workspaceInfo()
        try await session.setSystemInfo(.default())
        try await session.setUserInfo(.default)
        let r = try await body(session, sessionDiagnostics.map { "\($0.kind): \($0.message)" })
        try? await session.close()
        await service.close()
        return r
    } catch {
        try? await session.close()
        fail("\(error)")
    }
}

func settings(_ path: String) async {
    let request = decode(SettingsRequest.self, path)
    await withSession(pif: request.pif) { session, initial in
        var diagnostics = initial
        var out: [[String: String]] = []
        for level in request.levels {
            let l: SWBMacroEvaluationLevel
            if let g = level["target"] { l = .target(g) } else if let g = level["project"] { l = .project(g) } else { l = .defaults }
            do {
                out.append(try await session.allExportedMacroNamesAndValues(level: l, buildParameters: request.parameters))
            } catch {
                diagnostics.append("error: \(error)")
                out.append([:])
            }
        }
        let reply: [String: Any] = ["settings": out, "diagnostics": diagnostics]
        let data = try JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys, .withoutEscapingSlashes])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

/// Provisioning for local builds: identity `-` (Sign to Run Locally) signs
/// ad hoc with the project's own entitlements; no profiles, no teams.
final class LocalSigningDelegate: SWBPlanningOperationDelegate, Sendable {
    let debuggable: Bool
    init(debuggable: Bool = true) { self.debuggable = debuggable }

    func provisioningTaskInputs(targetGUID: String, provisioningSourceData: SWBProvisioningTaskInputsSourceData) async -> SWBProvisioningTaskInputs {
        let identity = provisioningSourceData.signingCertificateIdentifier
        if identity.isEmpty { return SWBProvisioningTaskInputs() }
        var entitlements = provisioningSourceData.projectEntitlements ?? [:]
        // Local development builds are debuggable; products that take no
        // entitlements (test bundles, libraries) get none.
        if debuggable && provisioningSourceData.supportsEntitlements { entitlements["com.apple.security.get-task-allow"] = .plBool(true) }
        if identity == "-" {
            return SWBProvisioningTaskInputs(identityHash: "-", identityName: "Sign to Run Locally", signedEntitlements: entitlements, simulatedEntitlements: [:])
        }
        return SWBProvisioningTaskInputs(identityHash: "-", errors: [["description": "ycodebuild signs only ad hoc (CODE_SIGN_IDENTITY=-); \"\(identity)\" needs provisioning, which is not supported"]])
    }

    func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String: String]) async throws -> SWBExternalToolResult {
        .deferred
    }
}

func build(_ path: String) async -> Int32 {
    let file = decode(BuildRequestFile.self, path)
    return await withSession(pif: file.pif) { session, _ in
        var request = SWBBuildRequest()
        request.parameters = file.parameters
        request.configuredTargets = file.targets.map { SWBConfiguredTarget(guid: $0, parameters: file.parameters) }
        request.useParallelTargets = file.parallel ?? true
        request.useImplicitDependencies = file.implicitDependencies ?? true
        request.hideShellScriptEnvironment = file.hideShellScriptEnvironment ?? false
        request.continueBuildingAfterErrors = file.continueAfterErrors ?? false
        request.showNonLoggedProgress = true
        request.containerPath = file.containerPath
        if let c = file.schemeCommand { request.schemeCommand = SWBSchemeCommand(rawValue: c) ?? .launch }
        if file.command == "cleanBuildFolder" {
            request.buildCommand = .cleanBuildFolder(style: file.locationStyle == "legacy" ? .legacy : .regular)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let operation = try await session.createBuildOperation(request: request, delegate: LocalSigningDelegate(debuggable: file.debuggable ?? true))
        var ok = false
        for try await event in try await operation.start() {
            if case .buildCompleted(let info) = event { ok = info.result == .ok }
            var line = try encoder.encode(event)
            line.append(0x0A)
            FileHandle.standardOutput.write(line)
        }
        await operation.waitForCompletion()
        return ok ? 0 : 1
    }
}

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: ycode-swb settings|build <request.json>\n".utf8))
    exit(2)
}
switch args[1] {
case "settings": await settings(args[2])
case "build": exit(await build(args[2]))
default:
    FileHandle.standardError.write(Data("usage: ycode-swb settings|build <request.json>\n".utf8))
    exit(2)
}
