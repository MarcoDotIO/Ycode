import Testing
@testable import YcodeXPC

@Suite struct XPCObjectTests {
    @Test func placeholder() { #expect(XPCObject.null == .null) }
}
