import Foundation
import Testing
@testable import YcodeIDECore

@MainActor
@Suite(.serialized) struct AssetCatalogTests {
    @Test func contentsJSONLayout() throws {
        let text = "{\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }\n}\n"
        let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        #expect(String(decoding: try AssetCatalog.json(obj), as: UTF8.self) == text)
        // 8-bit and float components both read as 0…1.
        #expect(AssetCatalog.component("0x33") == 0.2 && AssetCatalog.component("51") == 0.2 && AssetCatalog.component("0.200") == 0.2)
    }
}
