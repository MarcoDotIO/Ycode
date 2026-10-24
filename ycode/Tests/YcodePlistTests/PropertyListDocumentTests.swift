import Foundation
import Testing
@testable import YcodePlist

@Suite struct PropertyListDocumentTests {
    let sample: [String: Any] = [
        "CFBundleName": "Demo & <Co>",
        "Count": 3,
        "Ratio": 1.5,
        "Enabled": true,
        "Off": false,
        "List": ["a", 2, ["k": "v"]] as [Any],
        "Empty": [String: Any](),
        "None": [Any](),
        "Blob": Data([0, 1, 2, 250]),
        "When": Date(timeIntervalSince1970: 1_700_000_000),
    ]

    /// XML written by Foundation reads and writes back byte for byte.
    @Test func foundationXMLRoundTrips() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: sample, format: .xml, options: 0)
        let doc = try PropertyListDocument(data: data)
        #expect(doc.format == .xml)
        #expect(doc.xml() == String(decoding: data, as: UTF8.self))
    }

    @Test func keyOrderIsKept() throws {
        let text = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Zebra</key>
        \t<string>z</string>
        \t<key>Apple</key>
        \t<integer>-4</integer>
        </dict>
        </plist>

        """
        let doc = try PropertyListDocument(data: Data(text.utf8))
        #expect(doc.xml() == text)
        guard case .dictionary(let d) = doc.root else { Issue.record("not a dictionary"); return }
        #expect(d.map(\.key) == ["Zebra", "Apple"] && d[1].value == .integer(-4))
    }

    @Test func binaryPlists() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: sample, format: .binary, options: 0)
        let doc = try PropertyListDocument(data: data)
        #expect(doc.format == .binary)
        let back = try PropertyListSerialization.propertyList(from: try doc.data(), options: [], format: nil) as? NSDictionary
        #expect(back == sample as NSDictionary)
        #expect(throws: PropertyListDocument.ParseError.self) { try PropertyListDocument(data: Data("<plist><dict><bogus/></dict></plist>".utf8)) }
    }
}
