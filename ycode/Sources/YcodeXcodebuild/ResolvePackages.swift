import Foundation
import YcodeBuild
import YcodeProject

/// `-resolvePackageDependencies [-clonedSourcePackagesDirPath <dir>]`.
/// Projects and workspaces: remote references (`XCRemoteSwiftPackageReference`)
/// are resolved with Ycode's `PackageResolver` (git and SwiftPM's public
/// command line) into `<dir>/checkouts`, and `Package.resolved` is written
/// next to the project or workspace; local references are reported as is.
/// Package folders: SwiftPM's own `swift package resolve` with `<dir>` as
/// its scratch path. See `specs/xcodebuild/packages.md` §4.
enum ResolvePackages {
    /// `-clonedSourcePackagesDirPath`, else `<DerivedData folder>/SourcePackages`.
    static func sourcePackagesDirectory(_ inv: Invocation, name: String, path: String, context ctx: XcodebuildContext) -> String {
        if let d = inv.value("-clonedSourcePackagesDirPath") {
            return URL(fileURLWithPath: d.hasPrefix("/") ? d : ctx.cwd + "/" + d).standardizedFileURL.path
        }
        let base = inv.derivedDataPath.map { $0.hasPrefix("/") ? $0 : ctx.cwd + "/" + $0 }
            ?? ctx.derivedDataRoot + "/" + DerivedDataName.folder(name: name, path: path)
        return base + "/SourcePackages"
    }

    static func run(_ inv: Invocation, container: Container, context ctx: XcodebuildContext) throws(XcodebuildFailure) -> Int32 {
        let console = ctx.console
        let dir = sourcePackagesDirectory(inv, name: container.name, path: container.url.path, context: ctx)
        let resolver = PackageResolver(checkoutsDirectory: URL(fileURLWithPath: dir + "/checkouts"))
        var roots: [(url: String, requirement: SwiftPackageRequirement)] = []
        for p in container.projects {
            for r in PackageResolver.roots(of: p.proj) where !roots.contains(where: { $0.url == r.url }) { roots.append(r) }
        }
        if !roots.isEmpty {
            let pins: [PackageResolver.Pin]
            do { pins = try resolver.resolveGraph(roots) } catch {
                throw XcodebuildFailure("Could not resolve package dependencies:\n  \(error)", exitCode: ExitCode.dataError)
            }
            let resolved = container.workspacePath.appendingPathComponent("xcshareddata/swiftpm/Package.resolved")
            do {
                try FileManager.default.createDirectory(at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
                let hash = PackageResolver.originHash(rootLocations: roots.map(\.url))
                try PackageResolver.resolvedFileV3(pins, originHash: hash).write(to: resolved, options: .atomic)
            } catch {
                throw XcodebuildFailure("cannot write \(resolved.path): \(error)", exitCode: ExitCode.software)
            }
        }
        let entries = PackageReport.entries(container, derivedDataRoot: ctx.derivedDataRoot, checkouts: dir + "/checkouts")
        if !inv.quiet { PackageReport.print(entries, console: console) }
        console.out("resolved source packages: " + entries.map(\.name).joined(separator: ", "))
        return 0
    }

    /// A package folder: SwiftPM resolves (and writes the folder's
    /// `Package.resolved` when it has remote dependencies).
    static func run(_ inv: Invocation, package pkg: SwiftPackage, context ctx: XcodebuildContext) throws(XcodebuildFailure) -> Int32 {
        let dir = sourcePackagesDirectory(inv, name: pkg.name, path: pkg.directory, context: ctx)
        let r = TestActions.run(pkg.swift, ["package", "--package-path", pkg.directory, "--scratch-path", dir, "resolve"], environment: ctx.environment)
        guard r.status == 0 else {
            throw XcodebuildFailure("Could not resolve package dependencies of \(pkg.name).", exitCode: ExitCode.dataError)
        }
        let names = [pkg.name] + pkg.dependencies.map(\.name)
        ctx.console.out("resolved source packages: " + names.joined(separator: ", "))
        return 0
    }
}
