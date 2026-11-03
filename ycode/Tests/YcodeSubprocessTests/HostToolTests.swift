import Foundation
import Testing
import YcodeSubprocess

@Suite struct HostToolTests {
    private let flatpak = ["FLATPAK_ID": "io.github.MarcoDotIO.Ycode"]

    @Test func aToolIsInUsrBinOutsideTheFlatpak() {
        #expect(HostTool.path("git", environment: [:], toolDirectory: "/p/libexec/ycode-host") == "/usr/bin/git")
        #expect(!HostTool.isInFlatpak(environment: ["FLATPAK_ID": ""]))
    }

    @Test func aToolIsTheWrapperInTheFlatpak() {
        #expect(HostTool.path("git", environment: flatpak, toolDirectory: "/p/libexec/ycode-host") == "/p/libexec/ycode-host/git")
        #expect(HostTool.path("git", environment: flatpak, toolDirectory: nil) == "/usr/bin/git")
    }

    @Test func theWrappersAreFoundFromTheExecutableWhereverThePackageIs() {
        let exe = URL(fileURLWithPath: "/anywhere/Ycode-x/bin/ycode-ide")
        #expect(HostTool.packagedToolDirectory(executable: exe) { $0 == "/anywhere/Ycode-x/libexec/ycode-host" } == "/anywhere/Ycode-x/libexec/ycode-host")
        #expect(HostTool.packagedToolDirectory(executable: exe) { _ in false } == nil)
    }

    @Test func aHostProcessRunsAnOwnToolDirectlyOutsideTheFlatpak() {
        #expect(HostTool.commandOnHost(tool: "/x/ycode-bsp", arguments: ["serve"], environment: [:]) == ["/x/ycode-bsp", "serve"])
    }

    @Test func aHostProcessRunsAnOwnToolThroughFlatpakRun() {
        #expect(HostTool.commandOnHost(tool: "/app/bin/ycode-bsp", arguments: ["serve", "/p"], environment: flatpak)
            == ["flatpak", "run", "--command=ycode-bsp", "io.github.MarcoDotIO.Ycode", "serve", "/p"])
    }
}
