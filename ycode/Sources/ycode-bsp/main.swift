import Foundation
import YcodeBuildServer
import YcodeRelease

// ycode-bsp: Ycode's build server for sourcekit-lsp (Build Server Protocol
// over stdin/stdout), plus commands that show what it answers. See
// specs/ide/language.md §Build server.
YcodeRelease.handleVersionFlag(tool: "ycode-bsp")
YcodeRelease.adoptBundledHelpers()
exit(BuildServerMain.run(Array(CommandLine.arguments.dropFirst())))
