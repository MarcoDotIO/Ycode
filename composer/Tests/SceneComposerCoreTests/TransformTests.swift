import Testing
import USDCore
import USDStage
@testable import SceneComposerCore

/// Expected matrices were computed by OpenUSD (usd-core 26.11,
/// UsdGeomXformable/XformCache) for the same layer.
@Suite struct TransformTests {
    static let text = """
    #usda 1.0
    def Xform "A"
    {
        double3 xformOp:translate = (1, 2, 3)
        float3 xformOp:rotateXYZ = (10, 20, 30)
        float3 xformOp:scale = (2, 3, 4)
        uniform token[] xformOpOrder = ["xformOp:translate", "xformOp:rotateXYZ", "xformOp:scale"]

        def Xform "B"
        {
            quatf xformOp:orient = (0.9238795, 0, 0.3826834, 0)
            double3 xformOp:translate = (0, 1, 0)
            double3 xformOp:translate:pivot = (0.5, 0, 0)
            float xformOp:rotateZ = 90
            uniform token[] xformOpOrder = ["xformOp:translate", "xformOp:translate:pivot", "xformOp:orient", "xformOp:rotateZ", "!invert!xformOp:translate:pivot"]
        }

        def Xform "C"
        {
            float3 xformOp:rotateZYX = (10, 20, 30)
            uniform token[] xformOpOrder = ["!resetXformStack!", "xformOp:rotateZYX"]
        }
    }
    """

    static let golden: [String: (local: [Double], world: [Double])] = [
        "/A": ([1.627595363, 0.939692621, -0.684040287, 0, -1.322908832, 2.647692358, 0.489527733, 0, 1.514089225, 0.072113245, 3.701666314, 0, 1, 2, 3, 1],
               [1.627595363, 0.939692621, -0.684040287, 0, -1.322908832, 2.647692358, 0.489527733, 0, 1.514089225, 0.072113245, 3.701666314, 0, 1, 2, 3, 1]),
        "/A/B": ([0, 1, 0, 0, -0.707106677, 0, 0.707106886, 0, 0.707106886, 0, 0.707106677, 0, 0.5, 0.5, 0, 1],
                 [-1.322908832, 2.647692358, 0.489527733, 0, -0.080260631, -0.613471154, 3.101163193, 0, 2.221506489, 0.71545488, 2.133783368, 0,
                  1.152343266, 3.793692489, 2.902743723, 1]),
        "/A/C": ([0.813797681, 0.543838142, -0.204874129, 0, -0.46984631, 0.823172945, 0.318795778, 0, 0.342020143, -0.163175911, 0.925416578, 0, 0, 0, 0, 1],
                 [0.813797681, 0.543838142, -0.204874129, 0, -0.46984631, 0.823172945, 0.318795778, 0, 0.342020143, -0.163175911, 0.925416578, 0, 0, 0, 0, 1]),
    ]

    @Test func matchesOpenUSD() throws {
        let stage = Stage(rootLayer: try USDAReader.read(Self.text), resolver: MemoryLayerResolver())
        for (path, expected) in Self.golden {
            let prim = try #require(stage.prim(at: Path(parsing: path)!))
            let local = Xform.localTransform(prim).matrix
            let world = Xform.worldTransform(prim)
            #expect(local.isClose(to: Matrix4(expected.local), tolerance: 1e-6), "\(path) local \(local)")
            #expect(world.isClose(to: Matrix4(expected.world), tolerance: 1e-6), "\(path) world \(world)")
        }
    }

    @Test func trsRoundTrip() {
        let trs = TRS(translation: Vec3(1, -2, 3), rotation: Quat(axis: Vec3(0, 1, 0), degrees: 30) * Quat(axis: Vec3(1, 0, 0), degrees: 10),
                      scale: Vec3(2, 0.5, 1.5))
        let back = TRS(matrix: trs.matrix)
        #expect(back.translation.isClose(to: trs.translation, tolerance: 1e-9))
        #expect(back.scale.isClose(to: trs.scale, tolerance: 1e-9))
        #expect(back.rotation.isClose(to: trs.rotation.normalized, tolerance: 1e-9))
        #expect((trs.matrix.inverse! * trs.matrix).isClose(to: .identity, tolerance: 1e-9))
        let e = Xform.eulerXYZ(Quat(axis: Vec3(0, 1, 0), degrees: 45))
        #expect(e.isClose(to: Vec3(0, 45, 0), tolerance: 1e-9))
    }

    @Test func writesCanonicalOps() throws {
        var layer = try USDAReader.read(Self.text)
        let trs = TRS(translation: Vec3(5, 0, 0), rotation: Quat(axis: Vec3(0, 0, 1), degrees: 90), scale: Vec3(1, 1, 1))
        try Xform.setTRS(trs, at: "/A", in: &layer)
        #expect(layer.field(FieldKey.defaultValue, at: "/A.xformOpOrder") == .tokens(Xform.canonicalOrder))
        #expect(!layer.hasSpec(at: "/A.xformOp:rotateXYZ"))
        #expect(layer.field(FieldKey.typeName, at: "/A.xformOp:orient") == .token("quatf"))
        let stage = Stage(rootLayer: layer, resolver: MemoryLayerResolver())
        #expect(Xform.localTransform(stage.prim(at: "/A")!).matrix.isClose(to: trs.matrix, tolerance: 1e-6))
        // Animated: time samples.
        try Xform.setTRS(TRS(translation: Vec3(0, 1, 0)), at: "/A", in: &layer, time: 24)
        if case .timeSamples(let s)? = layer.field(FieldKey.timeSamples, at: "/A.xformOp:translate") {
            #expect(s.map(\.time) == [24])
        } else {
            Issue.record("expected time samples")
        }
    }
}
