import Testing
import USDCore
import USDStage
@testable import USDShade

@Suite struct ShadeTests {
    static let text = """
    #usda 1.0
    def Scope "Looks"
    {
        def Material "Red"
        {
            token outputs:mtlx:surface.connect = </Looks/Red/Surface.outputs:out>

            def Shader "Surface"
            {
                uniform token info:id = "ND_standard_surface_surfaceshader"
                color3f inputs:base_color.connect = </Looks/Red/Graph/Tint.outputs:out>
                float inputs:metalness = 0.25
                token outputs:out
            }

            def NodeGraph "Graph"
            {
                def Shader "Tint"
                {
                    uniform token info:id = "ND_multiply_color3"
                    color3f inputs:in1 = (1, 1, 1)
                    color3f inputs:in2 = (0.9, 0.1, 0.1)
                    color3f outputs:out
                }
            }
        }

        def Material "Preview"
        {
            token outputs:surface.connect = </Looks/Preview/PBR.outputs:surface>

            def Shader "PBR"
            {
                uniform token info:id = "UsdPreviewSurface"
                color3f inputs:diffuseColor = (0.2, 0.4, 0.8)
                float inputs:roughness = 0.5
                token outputs:surface
            }
        }
    }
    """

    @Test func bundledLibrary() throws {
        let lib = MaterialXLibrary.standard
        #expect(lib.definitions.count > 700)
        let ss = try #require(lib["ND_standard_surface_surfaceshader"])
        #expect(ss.node == "standard_surface")
        #expect(ss.input("base_color")?.type == "color3")
        #expect(ss.input("base_color")?.value == "0.8, 0.8, 0.8")
        #expect(ss.output("out")?.type == "surfaceshader")
        let image = try #require(lib["ND_image_color3"])
        #expect(image.input("file")?.isUniform == true)
        #expect(image.input("uaddressmode")?.enumValues == ["constant", "clamp", "periodic", "mirror"])
        #expect(image.input("texcoord")?.defaultGeomProp == "UV0")
        #expect(lib["ND_UsdPreviewSurface_surfaceshader"]?.input("diffuseColor")?.type == "color3")
        #expect(lib.definitions(ofNode: "multiply").count >= 10)
    }

    @Test func typeMapping() {
        #expect(MaterialXLibrary.usdType(forMaterialXType: "color3")?.description == "color3f")
        #expect(MaterialXLibrary.usdType(forMaterialXType: "filename")?.description == "asset")
        #expect(MaterialXLibrary.usdType(forMaterialXType: "surfaceshader")?.description == "token")
        #expect(MaterialXLibrary.usdValue("0.8, 0.8, 0.8", materialXType: "color3") == .scalar(.vec3f, .floats([0.8, 0.8, 0.8])))
        #expect(MaterialXLibrary.usdValue("true", materialXType: "boolean") == .bool(true))
        #expect(MaterialXLibrary.usdValue("1, 2", materialXType: "color3") == nil)
    }

    @Test func readsNetworks() throws {
        let layer = try USDAReader.read(Self.text)
        let net = try ShadeNetwork(layer: layer, material: "/Looks/Red")
        #expect(net.outputs.map(\.name) == ["mtlx:surface"])
        #expect(net.outputs.first?.source == .init(node: "Surface", port: "outputs:out"))
        #expect(net.nodes.map(\.name) == ["Surface", "Graph", "Graph/Tint"])
        #expect(net.node("Graph")?.kind == .nodeGraph)
        let surface = try #require(net.node("Surface"))
        #expect(surface.id == "ND_standard_surface_surfaceshader")
        #expect(surface.input("base_color")?.source == .init(node: "Graph/Tint", port: "outputs:out"))
        #expect(surface.input("metalness")?.value == .float(0.25))
        #expect(net.validate().isEmpty, "\(net.validate())")
        let preview = try ShadeNetwork(layer: layer, material: "/Looks/Preview")
        #expect(preview.validate().isEmpty, "\(preview.validate())")
        // The composed reader sees the same network.
        let stage = Stage(rootLayer: layer, resolver: MemoryLayerResolver())
        #expect(try ShadeNetwork(stage: stage, material: "/Looks/Red") == net)
    }

    @Test func writesNetworks() throws {
        let lib = MaterialXLibrary.standard
        var net = ShadeNetwork(material: "/Mat")
        var noise = ShadeNetwork.Node.make("Noise", definition: try #require(lib["ND_noise2d_float"]))
        noise.inputs = [.init(name: "amplitude", type: TypeName("float")!, value: .float(0.5))]
        var surface = ShadeNetwork.Node.make("Surface", definition: try #require(lib["ND_standard_surface_surfaceshader"]))
        surface.inputs = [.init(name: "specular_roughness", type: TypeName("float")!, source: .init(node: "Noise", port: "outputs:out"))]
        net.nodes = [noise, surface]
        net.outputs = [.init(name: "mtlx:surface", type: TypeName("token")!, source: .init(node: "Surface", port: "outputs:out"))]
        #expect(net.validate(library: lib).isEmpty, "\(net.validate(library: lib))")
        var layer = Layer()
        try net.write(into: &layer)
        let text = USDAWriter.write(layer)
        #expect(text.contains("uniform token info:id = \"ND_noise2d_float\""))
        #expect(text.contains("float inputs:specular_roughness.connect = </Mat/Noise.outputs:out>"))
        let back = try ShadeNetwork(layer: try USDAReader.read(text), material: "/Mat")
        #expect(back == net)
    }

    @Test func reportsProblems() throws {
        var net = ShadeNetwork(material: "/M")
        net.nodes = [
            .init(name: "A", id: "ND_standard_surface_surfaceshader", inputs: [
                .init(name: "base_color", type: TypeName("float")!),
                .init(name: "no_such_input", type: TypeName("float")!),
                .init(name: "metalness", type: TypeName("float")!, source: .init(node: "Missing", port: "outputs:out")),
            ], outputs: [.init(name: "out", type: TypeName("token")!)]),
            .init(name: "B", id: "ND_not_a_node"),
            .init(name: "C", id: "SomeRendererShader"),
        ]
        let problems = net.validate()
        #expect(problems.filter { $0.severity == .error }.count == 4)
        #expect(problems.filter { $0.severity == .warning }.count == 1)
        #expect(problems.contains { $0.message.contains("declares color3") })
    }
}
