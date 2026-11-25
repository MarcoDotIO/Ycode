// Where a simulator device runs (specs/ide/ycrun.md §3): one decision, made
// in one place. ycrun, and anything else that drives Ycode's simulator from
// a command line, asks `SimPlacementPolicy.decide` and nothing else.
//
//   arm64 Linux with a usable /dev/kvm   this machine
//   x86-64 Linux                          the configured simulator host (ssh)
//   macOS                                 the configured simulator host, until
//                                         Ycode's simulator runs on Apple-silicon
//                                         Macs (the MACHOST track): then
//                                         `macOSRunsLocally` turns true
//   --local, --remote, --host <name>      override the choice

import Foundation

/// The machine ycrun runs on, as far as the placement cares.
public struct SimMachine: Equatable, Sendable {
    public enum OS: String, Sendable { case macOS, linux, other }

    /// What this user can do with `/dev/kvm` (Linux).
    public enum KVM: String, Sendable {
        case usable, denied, absent
        /// Not a Linux machine.
        case notApplicable = "n/a"
    }

    public var os: OS
    /// `uname -m`: "arm64", "aarch64", "x86_64".
    public var architecture: String
    public var kvm: KVM

    public init(os: OS, architecture: String, kvm: KVM) {
        self.os = os
        self.architecture = architecture
        self.kvm = kvm
    }

    public var isARM64: Bool { architecture == "arm64" || architecture == "aarch64" }

    /// "arm64 Linux", "x86-64 Linux", "an Apple-silicon Mac", "an Intel Mac".
    public var title: String {
        switch os {
        case .linux: return (isARM64 ? "arm64" : architecture == "x86_64" ? "x86-64" : architecture) + " Linux"
        case .macOS: return isARM64 ? "an Apple-silicon Mac" : "an Intel Mac"
        case .other: return architecture
        }
    }

    /// This machine.
    public static func current(fileManager fm: FileManager = .default) -> SimMachine {
        var u = utsname()
        uname(&u)
        let arch = withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        #if os(macOS)
        return SimMachine(os: .macOS, architecture: arch, kvm: .notApplicable)
        #elseif os(Linux)
        let kvm: KVM
        if !fm.fileExists(atPath: "/dev/kvm") {
            kvm = .absent
        } else {
            kvm = fm.isReadableFile(atPath: "/dev/kvm") && fm.isWritableFile(atPath: "/dev/kvm") ? .usable : .denied
        }
        return SimMachine(os: .linux, architecture: arch, kvm: kvm)
        #else
        return SimMachine(os: .other, architecture: arch, kvm: .notApplicable)
        #endif
    }
}

/// Where a command's device lives.
public enum SimPlacement: Equatable, Sendable {
    /// This machine (`ycode-simd` under KVM here).
    case local
    /// A simulator host reached with ssh; nil: the default host.
    case remote(host: String?)

    public var isLocal: Bool { self == .local }
}

/// The command line's say in the matter: `--local`, `--remote`, `--host <name>`.
public struct SimPlacementRequest: Equatable, Sendable {
    public var local = false
    public var remote = false
    public var host: String?

    public init(local: Bool = false, remote: Bool = false, host: String? = nil) {
        self.local = local
        self.remote = remote
        self.host = host
    }

    public var isEmpty: Bool { !local && !remote && host == nil }
}

/// The placement and why, for `ycrun simctl list` and `ycrun remote status`.
public struct SimPlacementDecision: Equatable, Sendable {
    public var placement: SimPlacement
    public var reason: String
}

public struct SimPlacementError: Error, Equatable, CustomStringConvertible {
    public var description: String
    public init(_ d: String) { description = d }
}

public enum SimPlacementPolicy {
    /// The MACHOST switch (specs/ide/ycrun.md §3.2): true once Ycode's
    /// simulator runs on Apple-silicon Macs. It is the only line to change
    /// for the Mac to say "local"; everything else follows from it.
    public static let macOSRunsLocally = false

    /// Whether devices can run on this machine, and if not, why (with the
    /// fix the user applies themselves; ycrun never changes permissions).
    public static func localSupport(_ m: SimMachine, macOSRunsLocally: Bool = macOSRunsLocally) -> (supported: Bool, reason: String) {
        switch m.os {
        case .macOS:
            if macOSRunsLocally && m.isARM64 { return (true, "Ycode's simulator runs on this Mac.") }
            return (false, "Ycode's simulator does not run on \(m.title) yet; this Mac uses a remote simulator host (ycrun remote setup).")
        case .linux:
            guard m.isARM64 else {
                return (false, "Ycode's simulator needs arm64 Linux; this is \(m.title), so it uses a remote simulator host (ycrun remote setup).")
            }
            switch m.kvm {
            case .usable: return (true, "arm64 Linux with /dev/kvm: devices run on this machine.")
            case .denied: return (false, "/dev/kvm is here but this user cannot open it. " + kvmFix)
            case .absent: return (false, "This machine has no /dev/kvm: turn on virtualization and load the kvm module (Ycode does not change the kernel).")
            case .notApplicable: return (false, "KVM state unknown.")
            }
        case .other:
            return (false, "Ycode's simulator runs on arm64 Linux; this machine uses a remote simulator host.")
        }
    }

    /// The fix for KVM access, for the user to run themselves (ycrun never runs sudo).
    public static let kvmFix = "Run `sudo usermod -aG kvm $USER` yourself, then log out and in again (or ask the machine's administrator)."

    /// The decision. `--host` implies `--remote`; `--local` and `--remote`
    /// together are an error, and so is `--local` where devices cannot run.
    public static func decide(machine: SimMachine, request: SimPlacementRequest,
                              macOSRunsLocally: Bool = macOSRunsLocally) throws -> SimPlacementDecision {
        let support = localSupport(machine, macOSRunsLocally: macOSRunsLocally)
        if request.local && (request.remote || request.host != nil) {
            throw SimPlacementError("--local cannot be combined with --remote or --host")
        }
        if request.local {
            guard support.supported else { throw SimPlacementError("--local: " + support.reason) }
            return SimPlacementDecision(placement: .local, reason: "--local: " + support.reason)
        }
        if let host = request.host {
            return SimPlacementDecision(placement: .remote(host: host), reason: "--host \(host)")
        }
        if request.remote {
            return SimPlacementDecision(placement: .remote(host: nil), reason: "--remote: the default simulator host")
        }
        if support.supported { return SimPlacementDecision(placement: .local, reason: support.reason) }
        return SimPlacementDecision(placement: .remote(host: nil), reason: support.reason)
    }
}
