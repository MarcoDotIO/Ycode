import Foundation

/// The scheme editor's options as attributes of the action elements
/// (parity inventory P-109; `specs/ide/schemes.md` §Options). Each option
/// is one attribute; untouched attributes and elements keep their layout.
extension Scheme {
    /// The debugger and launcher identifiers of "Debug executable" on
    /// (written by the reference in every scheme) and off.
    public static let lldbDebugger = "Xcode.DebuggerFoundation.Debugger.LLDB"
    public static let lldbLauncher = "Xcode.DebuggerFoundation.Launcher.LLDB"
    public static let posixSpawnLauncher = "Xcode.IDEFoundation.Launcher.PosixSpawn"

    /// An attribute of an action element (`"LaunchAction"` …), nil when
    /// the element or the attribute is missing.
    public func attribute(_ name: String, of action: String) -> String? {
        document.child(action)?[name]
    }

    /// Sets (nil removes) an attribute of an action element, creating the
    /// element in canonical order when missing.
    public mutating func setAttribute(_ name: String, _ value: String?, of action: String) {
        if value == nil, document.child(action) == nil { return }
        editAction(action) { $0[name] = value }
    }

    /// Whether the action runs its executable under the debugger: the
    /// debugger identifier is set (absent means on).
    public func debugsExecutable(_ action: String = "LaunchAction") -> Bool {
        attribute("selectedDebuggerIdentifier", of: action).map { !$0.isEmpty } ?? true
    }

    /// Run / Test ▸ Info ▸ Debug executable: the LLDB debugger and
    /// launcher when on; no debugger and the plain launcher when off.
    public mutating func setDebugsExecutable(_ on: Bool, action: String = "LaunchAction") {
        editAction(action) {
            $0["selectedDebuggerIdentifier"] = on ? Self.lldbDebugger : ""
            $0["selectedLauncherIdentifier"] = on ? Self.lldbLauncher : Self.posixSpawnLauncher
        }
    }

    /// Run ▸ Info ▸ Executable: the runnable target (nil removes it).
    /// "Ask on Launch" is `askForAppToLaunch`.
    public mutating func setRunnable(_ ref: BuildableReference?, action: String = "LaunchAction") {
        editAction(action) { launch in
            if let i = launch.children.firstIndex(where: { $0.name == "BuildableProductRunnable" }) {
                if let ref { launch.children[i].children = [ref.node] } else { launch.children.remove(at: i) }
            } else if let ref {
                let node = XMLNode("BuildableProductRunnable", attributes: [("runnableDebuggingMode", "0")], children: [ref.node])
                launch.children.insert(node, at: 0)
            }
        }
    }

    /// The `MacroExpansion` target of an action (Expand Variables Based On).
    public func macroExpansion(_ action: String = "LaunchAction") -> BuildableReference? {
        document.child(action)?.child("MacroExpansion")?.child("BuildableReference").map(BuildableReference.init)
    }

    /// Run ▸ Arguments ▸ Expand Variables Based On: a `MacroExpansion`
    /// element after the runnable (nil removes it).
    public mutating func setMacroExpansion(_ ref: BuildableReference?, action: String = "LaunchAction") {
        editAction(action) { a in
            Self.replace(&a, element: "MacroExpansion", children: ref.map { [$0.node] } ?? [],
                         after: ["BuildableProductRunnable", "PathRunnable", "RemoteRunnable"])
        }
    }
}
