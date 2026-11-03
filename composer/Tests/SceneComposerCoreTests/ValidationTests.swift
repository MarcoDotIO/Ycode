import Testing
import USDCore
import USDStage
@testable import SceneComposerCore

@Suite struct ValidationTests {
    @Test func reportsStructuralProblems() throws {
        let layer = try USDAReader.read("""
        #usda 1.0
        (
            defaultPrim = "Missing"
            upAxis = "X"
        )
        def Xform "Root" (
            prepend references = @./gone.usda@
        )
        {
            rel material:binding = </Root/NoSuchMaterial>
            uniform token[] xformOpOrder = ["xformOp:translate"]

            def Mesh "Tri"
            {
                int[] faceVertexCounts = [3]
                int[] faceVertexIndices = [0, 1, 5]
                point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
            }

            def Material "Grey"
            {
                token outputs:mtlx:surface.connect = </Root/Grey/PBR.outputs:out>

                def Shader "PBR"
                {
                    uniform token info:id = "ND_realitykit_pbr_surfaceshader_v2"
                    token outputs:out
                }
            }

            def Material "Bad"
            {
                token outputs:mtlx:surface.connect = </Root/Bad/S.outputs:out>

                def Shader "S"
                {
                    uniform token info:id = "ND_standard_surface_surfaceshader"
                    float inputs:base_color = 1
                    token outputs:out
                }
            }
        }
        """, identifier: "/mem/scene.usda")
        let stage = Stage(rootLayer: layer, resolver: MemoryLayerResolver())
        let d = SceneValidator.validate(layer, stage: stage)
        let codes = Set(d.map(\.code))
        #expect(codes.isSuperset(of: ["default-prim", "up-axis", "composition", "target", "xform", "mesh", "material", "material-node"]),
                "\(d)")
        #expect(d.contains { $0.message.contains("_2_0") })
        #expect(d.first?.severity == .error)
    }

    @Test func aCleanSceneHasNoErrors() throws {
        let doc = SceneDocument.newScene()
        let cube = try doc.createPrim(named: "Cube", type: "Cube", under: "/Root")
        try doc.setTransform(cube, TRS(translation: Vec3(0, 0.5, 0)))
        try doc.addComponent("RealityKit.Collider", to: cube)
        try doc.addComponent("RealityKit.InputTarget", to: cube)
        let d = SceneValidator.validate(doc.layer, stage: doc.stage)
        #expect(!d.contains { $0.severity == .error }, "\(d)")
    }
}
