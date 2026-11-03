import Foundation
import Testing
import YcodeDebug
import YcodeLanguage
@testable import YcodeIDECore

@Suite struct QuickHelpFormatterTests {
    @Test func markdownToPlain() {
        let md = "```swift\nstruct Greeter\n```\n\n---\n\n\n A `greeting` printer.\n"
        #expect(QuickHelpFormatter.plain(md) == "struct Greeter\n\n A greeting printer.")
    }
}
