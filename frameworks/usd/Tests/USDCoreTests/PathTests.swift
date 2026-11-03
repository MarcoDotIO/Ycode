import Testing
@testable import USDCore

@Suite struct PathTests {
    @Test func parsesAndPrints() {
        for text in ["/", "/World", "/World/Robot", "/World.xformOp:translate", "/A{look=red}", "/A{look=red}B/C.attr",
                     "/A{look=}", "../Sibling", "Child/Grand", "/A.rel[/T]", "."] {
            #expect(Path(text)?.description == text, "\(text)")
        }
        #expect(Path(parsing: "")?.isEmpty == true)
        #expect(Path(parsing: "/A/") == nil)
        #expect(Path(parsing: "/A//B") == nil)
        #expect(Path(parsing: "/1A") == nil)
    }

    @Test func structure() {
        let p: Path = "/World/Robot{paint=red}Body.primvars:displayColor"
        #expect(p.isPropertyPath)
        #expect(p.isPrimPropertyPath)
        #expect(p.name == "primvars:displayColor")
        #expect(p.primPath.description == "/World/Robot{paint=red}Body")
        #expect(p.primPath.parent.description == "/World/Robot{paint=red}")
        #expect(p.primPath.parent.isVariantSelectionPath)
        #expect(p.strippingVariantSelections.description == "/World/Robot/Body.primvars:displayColor")
        #expect(Path.root.appendingChild("A").appendingProperty("x").description == "/A.x")
        #expect(Path(parsing: "/A")!.parent == .root)
        #expect(Path.root.parent == .empty)
    }

    @Test func prefixesAndRelativePaths() {
        let p: Path = "/World/Robot/Arm"
        #expect(p.hasPrefix("/World"))
        #expect(!p.hasPrefix("/Wor"))
        #expect(p.replacingPrefix("/World/Robot", with: "/Copy").description == "/Copy/Arm")
        #expect(Path(parsing: "../Looks/Red")!.makingAbsolute(anchor: "/World/Robot").description == "/World/Looks/Red")
        #expect(Path(parsing: "/World/Looks/Red")!.makingRelative(anchor: "/World/Robot").description == "../Looks/Red")
        #expect(Path(parsing: "Child")!.makingAbsolute(anchor: "/A").description == "/A/Child")
    }

    @Test func elementText() {
        #expect(Path(parsing: "/A")!.appendingElementText("{v=x}", isProperty: false).description == "/A{v=x}")
        #expect(Path(parsing: "/A")!.appendingElementText("b:c", isProperty: true).description == "/A.b:c")
    }
}
