import Foundation
import YcodeDarwinABI

// The kernel ↔ VMM seam of stage 4b (`specs/simulator/stage4b-contract.md`
// §3.3). Contract-pinned: change only through the contract.

/// What the VMM needs to start one image of a process.
public struct ProcessImageRequest {
    /// The normalized guest path of the executable.
    public var executablePath: String
    /// The host path that serves it (resolved through the guest VFS).
    public var hostExecutablePath: String
    public var argv: [String]
    public var envp: [String]
    /// Extra `apple[]` strings the kernel adds (the VMM adds its own,
    /// such as `executable_path=`, first).
    public var apple: [String]
    /// Do not run the main thread until `LaunchedImage.resume()`.
    public var startSuspended: Bool

    public init(executablePath: String, hostExecutablePath: String, argv: [String], envp: [String],
                apple: [String] = [], startSuspended: Bool = false) {
        self.executablePath = executablePath
        self.hostExecutablePath = hostExecutablePath
        self.argv = argv
        self.envp = envp
        self.apple = apple
        self.startSuspended = startSuspended
    }
}

/// A started (or suspended) image.
public protocol LaunchedImage: AnyObject {
    /// Starts the main thread of an image launched suspended. No effect otherwise.
    func resume()
}

/// Implemented by the VMM (agent V).
public protocol ProcessLauncher: AnyObject {
    /// Builds a new VM for `request`, maps the image, `dyld_sim`, the host
    /// page, commpage and stack, wires `kernel` to it (thread host, counter,
    /// log, image info addresses), and starts its main thread (unless
    /// `startSuspended`). `kernel` was made by the process layer with the
    /// right pid, file system, and Mach state.
    ///
    /// Called with the kernel lock held. Must not call into any kernel; the
    /// new main thread's first trap simply waits for the lock.
    /// Throws `DarwinErrnoError` (ENOENT, EACCES, ENOEXEC, EBADARCH, ENOMEM).
    func launch(_ request: ProcessImageRequest, kernel: DarwinKernel) throws -> any LaunchedImage
}
