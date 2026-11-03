import Testing
import USDCore
import USDStage
@testable import SceneComposerCore

@Suite struct ComponentTests {
    @Test func catalogueLoads() throws {
        let cat = ComponentCatalogue.realityKit
        #expect(cat.components.count >= 25)
        let collider = try #require(cat.kind("RealityKit.Collider"))
        #expect(collider.fieldsByKey["Shape.pose.position"]?.type == "float3")
        #expect(collider.structKeys.contains("Shape.pose"))
        #expect(cat.kind("RealityKit.PointLight")?.fieldsByKey["intensity"]?.verified == true)
    }

    @Test func writesTheEncodingOfSceneUSD() throws {
        let doc = SceneDocument.newScene()
        let cube = try doc.createPrim(named: "Cube", type: "Cube", under: "/Root")
        var collider = try doc.addComponent("RealityKit.Collider", to: cube)
        collider.set("Shape.shapeType", .token("Sphere"), type: TypeName("token")!)
        try doc.setComponent(collider, on: cube)
        var receiver = Component(primName: "ImageBasedLightReceiver", id: "RealityKit.ImageBasedLightReceiver")
        receiver.relationships["iblEntity"] = ["/Root"]
        try doc.setComponent(receiver, on: cube)
        let text = USDAWriter.write(doc.layer)
        #expect(text.contains("""
                def RealityKitComponent "Collider"
                {
                    uniform token info:id = "RealityKit.Collider"
                    uint group = 1
                    uint mask = 4294967295
                    token type = "Default"

                    def RealityKitStruct "Shape"
                    {
                        float3 extent = (0.2, 0.2, 0.2)
                        float radius = 0.1
                        token shapeType = "Sphere"
                    }
                }
        """))
        #expect(text.contains("rel iblEntity = </Root>"))
        let back = doc.componentsOf(cube)
        #expect(back.map(\.id) == ["RealityKit.Collider", "RealityKit.ImageBasedLightReceiver"])
        #expect(back[0].values["Shape.shapeType"] == .token("Sphere"))
        #expect(back[1].relationships["iblEntity"] == ["/Root"])
        #expect(ComponentCatalogue.realityKit.validate(doc.layer).isEmpty)
        try doc.removeComponent("Collider", from: cube)
        #expect(doc.componentsOf(cube).count == 1)
    }

    @Test func flagsWhatTheRuntimeWouldDrop() throws {
        let layer = try USDAReader.read("""
        #usda 1.0
        def Xform "Root"
        {
            def RealityKitComponent "Collider"
            {
                uniform token info:id = "RealityKit.Collider"
                token mask = "all"
                float bogus = 1
            }

            def RealityKitComponent "Mine"
            {
                uniform token info:id = "MyGame.Health"
            }

            def RealityKitComponent "Future"
            {
                uniform token info:id = "RealityKit.SomethingNew"
            }

            def RealityKitCustomComponent "MyGame_Health"
            {
                uniform token info:id = "MyGame.Health"
                float value = 3
            }

            def RealityKitComponent "Body"
            {
                uniform token info:id = "RealityKit.RigidBody"
                token motionType = "Floating"
            }
        }
        """)
        let d = ComponentCatalogue.realityKit.validate(layer)
        #expect(d.contains { $0.severity == .error && $0.message.contains("'mask' is token, expected uint") })
        #expect(d.contains { $0.severity == .warning && $0.message.contains("no field 'bogus'") })
        #expect(d.contains { $0.severity == .error && $0.message.contains("custom component id on a RealityKitComponent") })
        #expect(d.contains { $0.severity == .warning && $0.message.contains("RealityKit.SomethingNew") })
        #expect(d.contains { $0.message.contains("\"Floating\" is not one of") })
        #expect(!d.contains { $0.path.description.contains("MyGame_Health") })
    }
}
