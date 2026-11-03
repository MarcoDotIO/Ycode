import Testing
@testable import USDCore

@Suite struct USDATests {
    @Test func readsTheSceneFixture() throws {
        let layer = try Fixture.layer("scene.usda")
        #expect(layer.defaultPrim == "World")
        #expect(layer.upAxis == "Y")
        #expect(layer.metersPerUnit == 1)
        #expect(layer.timeCodesPerSecond == 24)
        #expect(layer.documentation == "A scene that exercises\nthe USDA grammar.")
        #expect(layer.primChildren(of: .root) == ["World", "Values", "_Base", "_Special"])
        #expect(layer.primChildren(of: "/World") == ["Robot", "Looks", "Props", "Lazy", "Child"])
        #expect(layer.field(FieldKey.typeName, at: "/World/Robot/Body") == .token("Mesh"))
        #expect(layer.field(FieldKey.specifier, at: "/_Base") == .specifier(.class))
        #expect(layer.field(FieldKey.kind, at: "/World") == .token("assembly"))
        #expect(layer.variantNames(of: "/World/Robot", set: "paint") == ["blue", "red"])
        #expect(layer.field(FieldKey.variantSelection, at: "/World/Robot") == .variantSelectionMap(["paint": "red"]))
        #expect(layer.hasSpec(at: "/World/Robot{paint=blue}Body.primvars:displayColor"))
        #expect(layer.field(FieldKey.apiSchemas, at: "/World/Robot") == .tokenListOp(.prepended(["MaterialBindingAPI"])))
        #expect(layer.field(FieldKey.targetPaths, at: "/World/Robot.material:binding") == .pathListOp(.explicit(["/World/Looks/Red"])))
        #expect(layer.field(FieldKey.connectionPaths, at: "/World/Looks/Red.outputs:mtlx:surface")
            == .pathListOp(.explicit(["/World/Looks/Red/Surface.outputs:out"])))
        let refs = layer.field(FieldKey.references, at: "/World/Props")
        #expect(refs == .referenceListOp(.prepended([
            Reference(assetPath: "./props.usda", primPath: "/Crate", layerOffset: LayerOffset(offset: 10, scale: 2)),
            Reference(primPath: "/World/Robot/Head"),
        ])))
        #expect(layer.field(FieldKey.payload, at: "/World/Lazy") == .payloadListOp(.prepended([Payload(assetPath: "./props.usda", primPath: "/Crate")])))
        #expect(layer.field(FieldKey.inheritPaths, at: "/World/Child") == .pathListOp(.prepended(["/_Base"])))
    }

    @Test func valueTypes() throws {
        let layer = try Fixture.layer("scene.usda")
        func value(_ name: String) -> Value? { layer.field(FieldKey.defaultValue, at: Path(parsing: "/Values")!.appendingProperty(name)) }
        #expect(value("boolValue") == .bool(true))
        #expect(value("intValue") == .int(-42))
        #expect(value("int64Value") == .int64(9_000_000_000))
        #expect(value("uint64Value") == .scalar(.uint64, .integers([Int64(bitPattern: 18_000_000_000_000_000_000)])))
        #expect(value("ucharValue") == .scalar(.uchar, .integers([200])))
        #expect(value("halfValue") == .half(0.333))
        #expect(value("floatValue") == .float(3.25))
        #expect(value("doubleValue") == .double(0.1))
        #expect(value("time") == .timecode(12.5))
        #expect(value("stringValue") == .string("tab\there \"quoted\""))
        #expect(value("assetValue") == .asset("textures/albedo.png"))
        #expect(value("assets") == .array(.asset, .strings(["a.png", "odd@name.png"])))
        #expect(value("quathValue")?.components == .floats([Half.round(0.707), 0, Half.round(0.707), 0]))
        #expect(value("frame") == .matrix4d([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 5, 6, 7, 1]))
        #expect(value("doubles") == .doubles([1e-7, 2.5e22, -0.0, 1, 1.5]))
        #expect(value("blocked") == .valueBlock)
        #expect(layer.field(FieldKey.typeName, at: "/Values.direction") == .token("vector3d"))
        let samples = layer.field(FieldKey.timeSamples, at: "/Values.sampled")
        #expect(samples == .timeSamples([
            TimeSample(time: 0, value: .float(1)), TimeSample(time: 5, value: .valueBlock), TimeSample(time: 10, value: .float(3)),
        ]))
        #expect(layer.field(FieldKey.targetPaths, at: "/Values.extra") == .pathListOp(.prepended(["/World"])))
        #expect(layer.field(FieldKey.custom, at: "/Values.extra") == nil)
    }

    /// Our writer, with OpenUSD's ordering, reproduces OpenUSD's own text
    /// output byte for byte (`scene.canonical.usda` was written by usd-core).
    @Test func canonicalOutputMatchesOpenUSD() throws {
        let layer = try Fixture.layer("scene.usda")
        let text = USDAWriter.write(layer, options: .init(sortPropertiesAndVariants: true))
        let expected = try Fixture.text("scene.canonical.usda")
        let a = text.split(separator: "\n", omittingEmptySubsequences: false)
        let b = expected.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, (x, y)) in zip(a, b).enumerated() where x != y {
            Issue.record("line \(i + 1): \(x) != \(y)")
            break
        }
        #expect(text == expected)
    }

    @Test func roundTripIsExactAndStable() throws {
        let layer = try Fixture.layer("scene.usda")
        let text = USDAWriter.write(layer)
        let again = try USDAReader.read(text, identifier: layer.identifier)
        #expect(differences(layer, again).isEmpty)
        #expect(USDAWriter.write(again) == text)
    }

    @Test func commentsSeparatorsAndQuoting() throws {
        let text = """
        #usda 1.0
        ( upAxis = "Z"; metersPerUnit = 0.01 ) // trailing comment
        /* block
           comment */ def Xform "A" ( kind = "group" ; active = false ) { float x = 1; custom token y = 'single' }
        def "B" { string s = '''multi
        line "quoted"''' }
        """
        let layer = try USDAReader.read(text)
        #expect(layer.upAxis == "Z")
        #expect(layer.metersPerUnit == 0.01)
        #expect(layer.field(FieldKey.active, at: "/A") == .bool(false))
        #expect(layer.field(FieldKey.defaultValue, at: "/A.y") == .token("single"))
        #expect(layer.field(FieldKey.defaultValue, at: "/B.s") == .string("multi\nline \"quoted\""))
        let out = USDAWriter.write(layer)
        #expect(out.contains("string s = '''multi\nline \"quoted\"'''"))
        #expect(out.contains("active = false"))
        #expect(differences(layer, try USDAReader.read(out)).isEmpty)
    }

    @Test func reportsErrorsWithLocations() {
        #expect(throws: USDError.self) { try USDAReader.read("def \"A\" {}") }
        do {
            _ = try USDAReader.read("#usda 1.0\ndef Xform \"A\" {\n    float x = (1, 2)\n}\n")
            Issue.record("expected an error")
        } catch let error as USDError {
            #expect(error.message.hasPrefix("usda:3:"))
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(throws: USDError.self) {
            try USDAReader.read("#usda 1.0\ndef \"A\" {\n double x = 1\n float x.timeSamples = { 0: 1 }\n}\n")
        }
        #expect(throws: USDError.self) { try USDAReader.read("#usda 1.0\ndef \"A\" {\n  bogus3f x = 1\n}\n") }
    }

    @Test func numberFormatting() {
        #expect(NumberFormat.format(1.0) == "1")
        #expect(NumberFormat.format(0.1) == "0.1")
        #expect(NumberFormat.format(-2.5) == "-2.5")
        #expect(NumberFormat.format(1e-7) == "1e-7")
        #expect(NumberFormat.format(1e-6) == "0.000001")
        #expect(NumberFormat.format(Float(1.5e22)) == "1.5e22")
        #expect(NumberFormat.format(1e21) == "1e21")
        #expect(NumberFormat.format(123456789012.0) == "123456789012")
        #expect(NumberFormat.format(Float(0.1)) == "0.1")
        #expect(NumberFormat.format(Double.infinity) == "inf")
        #expect(NumberFormat.format(-Double.infinity) == "-inf")
        #expect(NumberFormat.formatHalf(Half.round(0.333)) == "0.333008")
        #expect(NumberFormat.formatHalf(Half.toFloat(1)) == "5.96046e-08")
    }

    @Test func quoting() {
        #expect(USDAWriter.quote("plain") == "\"plain\"")
        #expect(USDAWriter.quote("say \"hi\"") == "'say \"hi\"'")
        #expect(USDAWriter.quote("both \" and '") == "\"both \\\" and '\"")
        #expect(USDAWriter.quote("back\\slash") == "\"back\\\\slash\"")
        #expect(USDAWriter.assetText("a@b.png") == "@@@a@b.png@@@")
    }

    @Test func dictionaryOrdering() {
        let names = ["xformOp:translate", "Zeta", "alpha", "item10", "item2", "Alpha"]
        #expect(names.sorted(by: dictionaryLessThan) == ["Alpha", "alpha", "item2", "item10", "xformOp:translate", "Zeta"])
    }
}
