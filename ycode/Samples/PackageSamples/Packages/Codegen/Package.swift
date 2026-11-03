// swift-tools-version: 6.0
// A build-tool plug-in for the package samples. `CodegenPlugin` runs
// `codegen-tool` (built for the host) on every `.codegen` file of a target and
// compiles the Swift it writes. The package's own `Codegen` library uses it,
// and project targets can apply it too (`XcodeBuildToolPlugin`).
import PackageDescription

let package = Package(
    name: "Codegen",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Codegen", targets: ["Codegen"]),
        .plugin(name: "CodegenPlugin", targets: ["CodegenPlugin"]),
    ],
    targets: [
        .executableTarget(name: "codegen-tool"),
        .plugin(name: "CodegenPlugin", capability: .buildTool(), dependencies: ["codegen-tool"]),
        .target(name: "Codegen", plugins: ["CodegenPlugin"]),
    ]
)
