import Testing
import USDCore
@testable import USDStage

@Suite struct StageTests {
    @Test func traversalMatchesOpenUSD() throws {
        let stage = try Scene.stage()
        #expect(stage.errors.isEmpty, "\(stage.errors)")
        #expect(stage.traverse().map(\.path.description) == [
            "/World", "/World/Robot", "/World/Robot/BlueOnly", "/World/Robot/Arm", "/World/FromSub", "/World/Lamp",
            "/World/Instance", "/World/Instance/ClassChild", "/World/Special", "/World/Internal", "/World/Internal/BlueOnly",
            "/World/Internal/Arm",
        ])
        #expect(stage.traverse(.all).map(\.path.description).suffix(3) == ["/_Class", "/_Class/ClassChild", "/_Spec"])
        #expect(stage.childNames(of: "/World") == ["Robot", "FromSub", "Lamp", "Instance", "Special", "Internal"])
    }

    @Test func valuesMatchOpenUSD() throws {
        let stage = try Scene.stage()
        let robot = try #require(stage.prim(at: "/World/Robot"))
        #expect(robot.typeName == "Xform")
        #expect(robot.attribute("weight")?.value() == .float(10))
        #expect(robot.attribute("hue")?.value() == .float(240))
        #expect(robot.relationship("target")?.targets == ["/World/Robot/Arm"])
        #expect(robot.attribute("anim")?.timeSamples.map(\.time) == [5, 15])
        #expect(robot.attribute("anim")?.value(at: 7.5) == .float(2.5))
        #expect(robot.attribute("anim")?.value() == nil)
        #expect(Set(robot.propertyNames) == ["anim", "hue", "target", "weight"])
        #expect(stage.prim(at: "/World/Robot/Arm")?.attribute("length")?.value() == .float(3))
        #expect(stage.prim(at: "/World/Lamp")?.attribute("intensity")?.value() == .float(5))
        #expect(stage.prim(at: "/World/Instance")?.attribute("note")?.value() == .string("from class"))
        #expect(stage.prim(at: "/World/Special")?.attribute("s")?.value() == .float(1))
        #expect(stage.prim(at: "/World/Special")?.attribute("t")?.value() == .float(8))
        let internalPrim = try #require(stage.prim(at: "/World/Internal"))
        #expect(internalPrim.typeName == "Xform")
        #expect(internalPrim.children.map(\.name) == ["BlueOnly", "Arm"])
        #expect(internalPrim.attribute("hue")?.value() == .float(240))
        #expect(internalPrim.attribute("weight")?.value() == .float(10))
        #expect(internalPrim.relationship("target")?.targets == ["/World/Internal/Arm"])
        let sets = robot.variantSets
        #expect(sets.count == 1)
        #expect(sets.first?.name == "color")
        #expect(sets.first?.variants.sorted() == ["blue", "red"])
        #expect(sets.first?.selection == "blue")
    }

    @Test func arcsAreStrengthOrdered() throws {
        let stage = try Scene.stage()
        let arcs = try #require(stage.prim(at: "/World/Robot")).arcs
        #expect(arcs.map(\.arc) == [.root, .reference, .variant])
        #expect(arcs.map(\.path.description) == ["/World/Robot", "/Robot", "/Robot{color=blue}"])
    }

    @Test func directArcsBeatAncestralArcs() throws {
        // OpenUSD: a reference authored on /A/B is stronger than /A's reference
        // reaching /X/B; child names compose weakest first.
        let text = """
        #usda 1.0
        def "X" {
            def "B" {
                float v = 1
                def "FromX" {
                }
            }
        }
        def "Y" {
            float v = 2
            def "FromY" {
            }
        }
        def "A" ( references = </X> ) {
            def "B" ( references = </Y> ) {
                def "Local" {
                }
            }
        }
        """
        let stage = Stage(rootLayer: try USDAReader.read(text, identifier: "/mem/a.usda"), resolver: MemoryLayerResolver())
        let b = try #require(stage.prim(at: "/A/B"))
        #expect(b.attribute("v")?.value() == .float(2))
        #expect(b.children.map(\.name) == ["FromX", "FromY", "Local"])
        #expect(b.arcs.map(\.path.description) == ["/A/B", "/Y", "/X/B"])
    }

    @Test func variantFallbacksAndPayloadLoading() throws {
        let stage = try Scene.stage()
        stage.loadPayloads = false
        #expect(stage.prim(at: "/World/Lamp")?.attribute("intensity") == nil)
        let robotOnly = try USDAReader.read(Scene.robot, identifier: "/mem/robot.usda")
        var noSelection = robotOnly
        noSelection.setField(FieldKey.variantSelection, nil, at: "/Robot")
        let plain = Stage(rootLayer: noSelection, resolver: MemoryLayerResolver())
        #expect(plain.prim(at: "/Robot")?.attribute("hue") == nil)
        plain.variantFallbacks = ["color": ["blue"]]
        #expect(plain.prim(at: "/Robot")?.attribute("hue")?.value() == .float(240))
    }

    @Test func reportsMissingLayersAndTargets() throws {
        let text = """
        #usda 1.0
        def "A" ( prepend references = @./missing.usda@ ) {
        }
        def "B" ( prepend references = </Nowhere> ) {
        }
        """
        let stage = Stage(rootLayer: try USDAReader.read(text, identifier: "/mem/a.usda"), resolver: MemoryLayerResolver())
        #expect(stage.traverse().map(\.name) == ["A", "B"])
        #expect(stage.errors.count == 2)
    }

    @Test func detectsCycles() throws {
        let text = """
        #usda 1.0
        def "A" ( prepend references = </B> ) {
        }
        def "B" ( prepend references = </A> ) {
        }
        """
        let stage = Stage(rootLayer: try USDAReader.read(text, identifier: "/mem/a.usda"), resolver: MemoryLayerResolver())
        #expect(stage.traverse().count == 2)
        #expect(!stage.errors.isEmpty)
    }

    @Test func flattenBakesComposition() throws {
        let stage = try Scene.stage()
        let flat = stage.flatten()
        #expect(flat.field(FieldKey.references, at: "/World/Robot") == nil)
        #expect(flat.field(FieldKey.defaultValue, at: "/World/Robot.hue") == .float(240))
        #expect(flat.field(FieldKey.defaultValue, at: "/World/Robot/Arm.length") == .float(3))
        #expect(flat.field(FieldKey.targetPaths, at: "/World/Internal.target") == .pathListOp(.explicit(["/World/Internal/Arm"])))
        #expect(flat.field(FieldKey.timeSamples, at: "/World/Robot.anim")
            == .timeSamples([TimeSample(time: 5, value: .float(0)), TimeSample(time: 15, value: .float(10))]))
        let again = Stage(rootLayer: flat, resolver: MemoryLayerResolver())
        #expect(again.traverse().map(\.path) == stage.traverse().map(\.path))
    }

    @Test func assetPaths() {
        #expect(AssetPaths.join("/a/b", "./c.usda") == "/a/b/c.usda")
        #expect(AssetPaths.join("/a/b", "../c.usda") == "/a/c.usda")
        #expect(AssetPaths.join("", "x/./y.usda") == "x/y.usda")
        #expect(AssetPaths.join("/a", "/abs.usda") == "/abs.usda")
        #expect(AssetPaths.splitPackage("/p/x.usdz[a/b.usdc]")! == ("/p/x.usdz", "a/b.usdc"))
    }
}
