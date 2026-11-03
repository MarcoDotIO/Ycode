import Foundation
import Testing
import USDCore
@testable import SceneComposerCLI
@testable import SceneComposerCore

struct Captured: TextOutputStream {
    var text = ""
    mutating func write(_ string: String) { text += string }
}

/// A scratch directory with a scene and a referenced file.
final class Workspace {
    let dir: String

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-scene-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir + "/textures", withIntermediateDirectories: true)
        try """
        #usda 1.0
        (
            defaultPrim = "Root"
            metersPerUnit = 1
            upAxis = "Y"
        )

        def Xform "Root"
        {
            def "Crate" (
                prepend references = @./crate.usda@
            )
            {
            }

            def Material "Wood"
            {
                token outputs:mtlx:surface.connect = </Root/Wood/Surface.outputs:out>

                def Shader "Surface"
                {
                    uniform token info:id = "ND_standard_surface_surfaceshader"
                    color3f inputs:base_color.connect = </Root/Wood/Image.outputs:out>
                    token outputs:out
                }

                def Shader "Image"
                {
                    uniform token info:id = "ND_image_color3"
                    asset inputs:file = @textures/wood.png@
                    color3f outputs:out
                }
            }
        }

        """.appending("\n").write(toFile: dir + "/scene.usda", atomically: true, encoding: .utf8)
        try """
        #usda 1.0
        (
            defaultPrim = "Crate"
        )

        def Xform "Crate"
        {
            def Cube "Box"
            {
                double size = 0.5
            }
        }
        """.write(toFile: dir + "/crate.usda", atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]).write(to: URL(fileURLWithPath: dir + "/textures/wood.png"))
    }

    deinit { try? FileManager.default.removeItem(atPath: dir) }

    func run(_ args: String...) -> (status: Int32, out: String, err: String) {
        var out = Captured()
        var err = Captured()
        let status = SceneComposerCLI.run(args, out: &out, err: &err)
        return (status, out.text, err.text)
    }
}

@Suite struct CLITests {
    @Test func infoAndTree() throws {
        let w = try Workspace()
        let info = w.run("info", w.dir + "/scene.usda")
        #expect(info.status == 0)
        #expect(info.out.contains("defaultPrim: Root"))
        #expect(info.out.contains("  ./crate.usda"))
        let tree = w.run("tree", w.dir + "/scene.usda")
        #expect(tree.out.contains("  def Xform \"Crate\"  [reference]\n    def Cube \"Box\""))
        let layerTree = w.run("tree", "--layer", w.dir + "/scene.usda")
        #expect(!layerTree.out.contains("Box"))
    }

    @Test func catAndConvertRoundTrip() throws {
        let w = try Workspace()
        let original = try String(contentsOfFile: w.dir + "/scene.usda", encoding: .utf8)
        #expect(w.run("cat", w.dir + "/scene.usda").out == original)
        #expect(w.run("convert", w.dir + "/scene.usda", w.dir + "/scene.usdc").status == 0)
        #expect(w.run("convert", w.dir + "/scene.usdc", w.dir + "/back.usda").status == 0)
        #expect(try String(contentsOfFile: w.dir + "/back.usda", encoding: .utf8) == original)
        let flat = w.run("cat", "--flatten", w.dir + "/scene.usda").out
        #expect(flat.contains("double size = 0.5"))
        #expect(!flat.contains("references"))
    }

    @Test func packagesDependencies() throws {
        let w = try Workspace()
        let r = w.run("convert", w.dir + "/scene.usda", w.dir + "/scene.usdz")
        #expect(r.status == 0, "\(r)")
        let archive = try USDZArchive.read([UInt8](try Data(contentsOf: URL(fileURLWithPath: w.dir + "/scene.usdz"))))
        #expect(archive.entries.map(\.name) == ["scene.usdc", "crate.usda", "textures/wood.png"])
        let info = w.run("info", w.dir + "/scene.usdz")
        #expect(info.out.contains("format: usdz"))
        #expect(!info.out.contains("not 64-byte aligned"))
        #expect(w.run("validate", w.dir + "/scene.usdz").status == 0)
        // The packaged scene still composes the referenced crate.
        #expect(w.run("tree", w.dir + "/scene.usdz").out.contains("def Cube \"Box\""))
    }

    @Test func validateReportsAndFails() throws {
        let w = try Workspace()
        let ok = w.run("validate", w.dir + "/scene.usda")
        #expect(ok.status == 0, "\(ok.out)")
        try FileManager.default.removeItem(atPath: w.dir + "/crate.usda")
        let broken = w.run("validate", w.dir + "/scene.usda")
        #expect(broken.status == 1)
        #expect(broken.out.contains("[composition]"))
        try "#usda 1.0\ndef \"A\" {\n  float x = (1\n}\n".write(toFile: w.dir + "/bad.usda", atomically: true, encoding: .utf8)
        let syntax = w.run("validate", w.dir + "/bad.usda")
        #expect(syntax.status == 1)
        #expect(syntax.out.contains("[load]"))
    }

    @Test func editsScripts() throws {
        let w = try Workspace()
        let r = w.run("edit", w.dir + "/scene.usda", "-o", w.dir + "/edited.usda",
                      "--add-prim", "/Root/Ball", "Sphere",
                      "--set", "/Root/Ball.radius", "double", "0.25",
                      "--set-sample", "/Root/Ball.radius", "double", "10", "0.5",
                      "--translate", "/Root/Ball", "0", "1", "0",
                      "--add-component", "/Root/Ball", "RealityKit.Collider",
                      "--meta", "/Root/Ball", "kind", "\"component\"",
                      "--bind", "/Root/Ball", "/Root/Wood",
                      "--rename", "/Root/Crate", "Box",
                      "--reference", "/Root", "Another", "./crate.usda")
        #expect(r.status == 0, "\(r.err)")
        let text = try String(contentsOfFile: w.dir + "/edited.usda", encoding: .utf8)
        #expect(text.contains("def Sphere \"Ball\""))
        #expect(text.contains("double radius = 0.25"))
        #expect(text.contains("10: 0.5,"))
        #expect(text.contains("uniform token[] xformOpOrder = [\"xformOp:translate\", \"xformOp:orient\", \"xformOp:scale\"]"))
        #expect(text.contains("def RealityKitComponent \"Collider\""))
        #expect(text.contains("kind = \"component\""))
        #expect(text.contains("def \"Box\" ("))
        #expect(text.contains("def \"Another\" ("))
        #expect(w.run("validate", w.dir + "/edited.usda").status == 0)
        let bad = w.run("edit", w.dir + "/scene.usda", "--set", "/Root.x", "nonsense", "1")
        #expect(bad.status == 2)
        #expect(bad.err.contains("unknown type"))
    }

    @Test func usageErrors() {
        #expect(SceneComposerCLI.run([], out: &Captured.dummy, err: &Captured.dummyErr) == 2)
        var out = Captured()
        var err = Captured()
        #expect(SceneComposerCLI.run(["frobnicate"], out: &out, err: &err) == 2)
        #expect(SceneComposerCLI.run(["components"], out: &out, err: &err) == 0)
        #expect(out.text.contains("RealityKit.Collider\tCollisionComponent"))
    }
}

extension Captured {
    nonisolated(unsafe) static var dummy = Captured()
    nonisolated(unsafe) static var dummyErr = Captured()
}
