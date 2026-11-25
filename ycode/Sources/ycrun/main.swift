// ycrun: Ycode's xcrun-style front end for its own simulators
// (specs/ide/ycrun.md, docs/YCRUN.md).

import Foundation
import YcodeRelease
import YcodeSimControl

YcodeRelease.handleVersionFlag(tool: "ycrun")
YcodeRelease.adoptBundledHelpers()
signal(SIGPIPE, SIG_IGN)
let interactive = isatty(0) == 1 && isatty(1) == 1
let env = YcrunEnvironment(ask: interactive ? { prompt in
    FileHandle.standardOutput.write(Data(prompt.utf8))
    return readLine()
} : nil)
exit(Ycrun.main(Array(CommandLine.arguments.dropFirst()), env: env))
