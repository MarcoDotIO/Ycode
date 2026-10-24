import Testing
@testable import YcodeUI

@Suite struct LaunchArgumentsTests {
    @Test func skipsArgumentDomainPairs() {
        #expect(LaunchArguments.documentPaths(["-ApplePersistenceIgnoreState", "YES", "/a/P.xcodeproj"]) == ["/a/P.xcodeproj"])
        #expect(LaunchArguments.documentPaths(["/x", "-NSDocumentRevisionsDebugMode", "NO", "/y"]) == ["/x", "/y"])
    }
    @Test func flagWithoutValue() {
        #expect(LaunchArguments.documentPaths(["-a", "-b", "1", "/p"]) == ["/p"])
        #expect(LaunchArguments.documentPaths(["/p", "-trailing"]) == ["/p"])
    }
    @Test func doubleDashEndsOptions() {
        #expect(LaunchArguments.documentPaths(["-k", "v", "--", "-odd", "/p"]) == ["-odd", "/p"])
        #expect(LaunchArguments.documentPaths([]) == [])
    }
}
