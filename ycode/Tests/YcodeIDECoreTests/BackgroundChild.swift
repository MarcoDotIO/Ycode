import Foundation

/// Ends the background child whose process id a test's shell script wrote
/// to `file` (`sleep 60 & echo $! > file`), and removes the file.
func killChild(in file: URL) {
    if let text = try? String(contentsOf: file, encoding: .utf8),
       let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
        kill(pid, SIGKILL)
    }
    try? FileManager.default.removeItem(at: file)
}
