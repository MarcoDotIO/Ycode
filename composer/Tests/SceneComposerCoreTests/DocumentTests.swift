import Testing
import USDCore
import USDStage
@testable import SceneComposerCore

@Suite struct DocumentTests {
    @Test func newSceneConventions() {
        let doc = SceneDocument.newScene()
        let text = USDAWriter.write(doc.layer)
        #expect(text == """
        #usda 1.0
        (
            customLayerData = {
                string creator = "Ycode Scene Composer"
            }
            defaultPrim = "Root"
            metersPerUnit = 1
            upAxis = "Y"
        )

        def Xform "Root"
        {
        }


        """)
    }

    @Test func editsUndoAndRedo() throws {
        let doc = SceneDocument.newScene()
        let cube = try doc.createPrim(named: "Cube", type: "Cube", under: "/Root")
        let cube2 = try doc.createPrim(named: "Cube", type: "Cube", under: "/Root")
        #expect(cube2 == "/Root/Cube_1")
        try doc.setAttribute(cube.appendingProperty("size"), .double(0.5), type: TypeName("double"))
        try doc.setTransform(cube, TRS(translation: Vec3(0, 1, 0)))
        #expect(doc.worldTransform(cube).translation == Vec3(0, 1, 0))
        #expect(doc.isDirty)
        #expect(doc.history.undoName == "Transform Cube")
        doc.undo()
        #expect(doc.worldTransform(cube).translation == .zero)
        doc.undo()
        #expect(doc.prim(cube)?.attribute("size") == nil)
        doc.redo()
        #expect(doc.prim(cube)?.attribute("size")?.value() == .double(0.5))
        #expect(throws: USDError.self) { try doc.setAttribute(cube.appendingProperty("size"), .float(1)) }
        // Undo everything returns the original layer.
        while doc.history.canUndo { doc.undo() }
        #expect(doc.layer == SceneDocument.newScene().layer)
    }

    @Test func renameRetargetsAndKeepsOrder() throws {
        let doc = SceneDocument.newScene()
        let a = try doc.createPrim(named: "A", type: "Xform", under: "/Root")
        _ = try doc.createPrim(named: "B", type: "Xform", under: "/Root")
        let child = try doc.createPrim(named: "Mesh", type: "Mesh", under: a)
        try doc.perform("rel") { layer in try layer.createRelationship(at: "/Root/B.look", targets: [child]) }
        doc.selection.select(child)
        try doc.rename(a, to: "Arm")
        #expect(doc.layer.primChildren(of: "/Root") == ["Arm", "B"])
        #expect(doc.prim("/Root/B")?.relationship("look")?.targets == ["/Root/Arm/Mesh"])
        #expect(doc.selection.primary == "/Root/Arm/Mesh")
        #expect(throws: USDError.self) { try doc.rename("/Root/B", to: "Arm") }
        #expect(throws: USDError.self) { try doc.rename("/Root/B", to: "not valid") }
        try doc.reparent("/Root/B", to: "/Root/Arm", index: 0)
        #expect(doc.layer.primChildren(of: "/Root/Arm") == ["B", "Mesh"])
        doc.undo()
        #expect(doc.layer.primChildren(of: "/Root") == ["Arm", "B"])
    }

    @Test func deleteRemovesOrDeactivates() throws {
        let props = try USDAReader.read("""
        #usda 1.0
        (
            defaultPrim = "Crate"
        )
        def Xform "Crate"
        {
            def Cube "Box"
            {
            }
        }
        """, identifier: "/mem/props.usda")
        var scene = SceneDocument.newScene(identifier: "/mem/scene.usda").layer
        scene.setField(FieldKey.references, .referenceListOp(.prepended([Reference(assetPath: "./props.usda")])), at: "/Root")
        let doc = SceneDocument(layer: scene, resolver: MemoryLayerResolver(layers: [props]))
        #expect(doc.prim("/Root/Box") != nil)
        try doc.delete(["/Root/Box"])
        #expect(doc.prim("/Root/Box")?.isActive == false)
        let own = try doc.createPrim(named: "Own", under: "/Root")
        try doc.delete([own])
        #expect(doc.prim(own) == nil)
    }

    @Test func copyPasteAndDuplicate() throws {
        let doc = SceneDocument.newScene()
        let a = try doc.createPrim(named: "A", type: "Xform", under: "/Root")
        let m = try doc.createPrim(named: "Mesh", type: "Mesh", under: a)
        try doc.perform("rel") { layer in try layer.createRelationship(at: a.appendingProperty("focus"), targets: [m]) }
        let clip = try doc.copy([a, m])
        #expect(clip.rootNames == ["A"])
        let text = clip.text
        let pasted = try doc.paste(try Clipboard(text: text), under: "/Root")
        #expect(pasted == ["/Root/A_1"])
        #expect(doc.prim("/Root/A_1/Mesh")?.typeName == "Mesh")
        #expect(doc.prim("/Root/A_1")?.relationship("focus")?.targets == ["/Root/A_1/Mesh"])
        let dup = try doc.duplicate([a])
        #expect(dup == ["/Root/A_2"])
        doc.undo()
        #expect(doc.prim("/Root/A_2") == nil)
    }

    @Test func groupingMakesOneUndoStep() throws {
        let doc = SceneDocument.newScene()
        try doc.group("Build") {
            let a = try doc.createPrim(named: "A", under: "/Root")
            _ = try doc.createPrim(named: "B", under: a)
        }
        #expect(doc.history.undoEntries.count == 1)
        doc.undo()
        #expect(doc.layer.primChildren(of: "/Root").isEmpty)
    }

    @Test func materialBindingAndVariants() throws {
        let doc = SceneDocument.newScene()
        let cube = try doc.createPrim(named: "Cube", type: "Cube", under: "/Root")
        let mat = try doc.createPrim(named: "Red", type: "Material", under: "/Root")
        try doc.bindMaterial(cube, to: mat)
        let text = USDAWriter.write(doc.layer)
        #expect(text.contains("prepend apiSchemas = [\"MaterialBindingAPI\"]"))
        #expect(text.contains("rel material:binding = </Root/Red> (\n            bindMaterialAs = \"weakerThanDescendants\"\n        )"))
        try doc.setVariantSelection("/Root", set: "look", variant: "red")
        #expect(doc.layer.field(FieldKey.variantSelection, at: "/Root") == .variantSelectionMap(["look": "red"]))
    }

    @Test func tree() throws {
        let doc = SceneDocument.newScene()
        let a = try doc.createPrim(named: "A", type: "Xform", under: "/Root")
        try doc.addComponent("RealityKit.InputTarget", to: a)
        let nodes = doc.tree()
        #expect(nodes.map(\.name) == ["Root"])
        #expect(nodes[0].children[0].children.first?.isComponent == true)
    }
}
