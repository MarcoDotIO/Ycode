import Testing
@testable import USDCore

@Suite struct LayerTests {
    @Test func createsPrimsWithAncestors() throws {
        var layer = Layer()
        try layer.createPrim(at: "/A/B/C", typeName: "Xform")
        #expect(layer.field(FieldKey.specifier, at: "/A") == .specifier(.over))
        #expect(layer.field(FieldKey.specifier, at: "/A/B/C") == .specifier(.def))
        #expect(layer.primChildren(of: "/A") == ["B"])
        #expect(layer.primPaths() == ["/A", "/A/B", "/A/B/C"])
        #expect(throws: USDError.self) { try layer.createPrim(at: "/A.x") }
    }

    @Test func removesMovesAndCopies() throws {
        var layer = Layer()
        try layer.createPrim(at: "/World/A", typeName: "Xform")
        try layer.createPrim(at: "/World/B", typeName: "Xform")
        try layer.createPrim(at: "/World/A/Child")
        try layer.createRelationship(at: "/World/A.target", targets: ["/World/A/Child", "/World/B"])
        try layer.moveSpec(at: "/World/A", to: "/World/Renamed")
        #expect(layer.primChildren(of: "/World") == ["Renamed", "B"])
        #expect(layer.field(FieldKey.targetPaths, at: "/World/Renamed.target") == .pathListOp(.explicit(["/World/Renamed/Child", "/World/B"])))
        try layer.copySpec(from: layer, at: "/World/Renamed", to: "/World/B/Copy")
        #expect(layer.hasSpec(at: "/World/B/Copy/Child"))
        #expect(layer.primChildren(of: "/World/B") == ["Copy"])
        let removed = layer.removeSpec(at: "/World/Renamed")
        #expect(removed.count == 3)
        #expect(layer.primChildren(of: "/World") == ["B"])
        #expect(throws: USDError.self) { try layer.moveSpec(at: "/World/B", to: "/World/B/Inner") }
    }

    @Test func variants() throws {
        var layer = Layer()
        try layer.createPrim(at: "/P")
        let red = try layer.createVariant("red", inSet: "look", on: "/P")
        try layer.createPrim(at: red.appendingChild("Mesh"))
        #expect(layer.variantSetNames(of: "/P") == ["look"])
        #expect(layer.variantNames(of: "/P", set: "look") == ["red"])
        #expect(layer.field(FieldKey.variantSetNames, at: "/P") == .stringListOp(.prepended(["look"])))
        #expect(layer.primPaths() == ["/P", "/P{look=red}Mesh"])
        let text = USDAWriter.write(layer)
        #expect(text.contains("variantSet \"look\" = {"))
        #expect(differences(layer, try USDAReader.read(text)).isEmpty)
    }

    @Test func listOps() {
        let weaker = ["a", "b", "c"]
        #expect(ListOp<String>.explicit(["x"]).applied(to: weaker) == ["x"])
        #expect(ListOp<String>.prepended(["c", "z"]).applied(to: weaker) == ["c", "z", "a", "b"])
        #expect(ListOp<String>.appended(["a"]).applied(to: weaker) == ["b", "c", "a"])
        #expect(ListOp<String>(deletedItems: ["b"]).applied(to: weaker) == ["a", "c"])
        #expect(ListOp<String>(orderedItems: ["c", "a"]).applied(to: weaker) == ["c", "b", "a"])
    }

    @Test func dependencies() throws {
        let deps = LayerIO.assetDependencies(of: try Fixture.layer("scene.usda"))
        #expect(deps.contains("./props.usda"))
        #expect(deps.contains("textures/albedo.png"))
        #expect(deps.contains("odd@name.png"))
    }

    @Test func formats() {
        #expect(LayerFormat(path: "a/b.USDA") == .usda)
        #expect(LayerFormat(path: "x.usd") == .usdc)
        #expect(LayerFormat(path: "x.usdz") == .usdz)
        #expect(LayerFormat(path: "x.obj") == nil)
    }
}
