import Foundation
import Testing
import YcodeBuild
import YcodeProject
@testable import YcodeIDECore

@MainActor
@Suite(.serialized, .heavyIntegration, .timeLimit(.minutes(5))) struct TemplateTests {
    @Test func fileTemplateContents() {
        #expect(FileTemplate.swiftClass.files(named: "Widget").map(\.0) == ["Widget.swift"])
        #expect(FileTemplate.objcClass.files(named: "Widget").map(\.0) == ["Widget.h", "Widget.m"])
        #expect(FileTemplate.propertyList.files(named: "Config")[0].1.contains("<dict/>"))
        #expect(FileTemplate.empty.files(named: "README").first?.1 == "")
    }
}
