// The device's system UI among Metal clients (metal-sim-protocol.md §8.8):
// the render server and SpringBoard never lose GPU access, however often
// their work hangs; the watchdog still ends each stuck submission.

/// Recognises the render server (backboardd) and SpringBoard by their
/// launchd job label or their executable's path, never by a pid.
public enum MetalSystemUI {
    /// launchd job labels of the system UI (the runtime's launchd plists).
    public static let labels: Set<String> = ["com.apple.backboardd", "com.apple.SpringBoard"]
    /// Executable paths, matched at the end (a host path keeps the runtime
    /// root in front of the guest path).
    public static let executableSuffixes = ["/usr/libexec/backboardd", "/System/Library/CoreServices/SpringBoard.app/SpringBoard"]

    /// True for the render server or SpringBoard. Either fact is enough: the
    /// label is missing for a process launchd did not start through its
    /// proxy (and after a snapshot restore), the path is the fallback.
    public static func isSystemUI(label: String?, executablePath: String?) -> Bool {
        if let label, labels.contains(label) { return true }
        guard let path = executablePath else { return false }
        return executableSuffixes.contains { path.hasSuffix($0) }
    }
}
