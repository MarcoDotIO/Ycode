// The debugger for an app on a Ycode simulator whose debug stub this
// computer can reach (specs/ide/debug.md, "The Linux IDE: apps on the
// simulator"): the Linux IDE's Run on a simulator host on this machine.
// A loopback forward (StubForward) carries lldb-dap's gdb-remote connection
// to the stub's Unix socket; lldb-dap attaches with the local build of the
// app, so the session is the ordinary one: breakpoints, the debug bar, the
// variables view and the console, as for a package or a Mac simulator app.
// The macOS IDE's remote run (RemoteRun.swift) reaches the stub through an
// ssh forward instead.

import Foundation
import YcodeDebug

extension WorkspaceSession {
    /// How an attach to a simulator app's stub ended.
    public enum StubAttachResult: Equatable, Sendable {
        /// lldb-dap attached and the app runs (or stopped at a breakpoint).
        case attached
        /// The run was stopped before the attach.
        case cancelled
        case failed(String)
    }

    /// Attaches lldb-dap to the app that ycode-simd's stub serves on the
    /// Unix socket `socketPath` (debug-stub.md §7: the connection's first
    /// packet attaches it to the launched app). `app` is this computer's
    /// build of the app. `waitForLaunch` returns once the device launched
    /// the app (false: it never did); the activity reads "Launching <app>"
    /// until then, "Configuring Debugger Actions" until the app runs under
    /// the debugger. `cancelled` (Stop) ends the waits early. `adapter`
    /// replaces lldb-dap (tests).
    @discardableResult
    public func attachToSimulatorStub(socketPath: String, app appURL: URL, device: String, adapter: DAPTransport? = nil,
                                      waitSeconds: Double = 60, waitForLaunch: (() async -> Bool)? = nil,
                                      cancelled: @escaping @MainActor () -> Bool = { false }) async -> StubAttachResult {
        guard let app = AppBundle(url: appURL) else { return .failed("\(appURL.lastPathComponent) has no Info.plist") }
        beginDebugSession(product: app.executable)
        runningDeviceName = device
        if let waitForLaunch {
            setActivity(.running(RunActivityText.launching(app.executable)))
            let launched = await waitForLaunch()
            guard launched, !cancelled() else {
                if !cancelled() { appendConsole("Ycode: \(app.executable) did not launch on \(device); the debugger was not attached.\n", kind: .debugger) }
                finishStubAttach(app: app.executable, device: device)
                return cancelled() ? .cancelled : .failed("not launched")
            }
        }
        setActivity(.running(RunActivityText.configuringDebugger))
        // The stub listens from ycode-simd's start; it may still be coming up.
        var ready = false
        for _ in 0..<max(1, Int(waitSeconds * 10)) where !cancelled() {
            if await Task.detached(operation: { StubForward.unixSocketAccepts(socketPath) }).value { ready = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !cancelled() else { finishStubAttach(app: app.executable, device: device); return .cancelled }
        guard ready else {
            appendConsole("Ycode: the debugger could not reach the app on \(device) (no debug stub at \(socketPath))\n", kind: .debugger)
            finishStubAttach(app: app.executable, device: device)
            return .failed("no debug stub")
        }
        let forward: StubForward
        do { forward = try StubForward(unixSocket: socketPath) } catch {
            appendConsole("Ycode: the debugger's forward did not start: \(error)\n", kind: .debugger)
            finishStubAttach(app: app.executable, device: device)
            return .failed("\(error)")
        }
        let transport: DAPTransport
        if let adapter { transport = adapter } else {
            guard let path = await Task.detached(operation: { LLDBDAP.locate() }).value else {
                appendConsole("Ycode: lldb-dap was not found.\n")
                forward.close()
                finishStubAttach(app: app.executable, device: device)
                return .failed("lldb-dap was not found")
            }
            transport = ProcessTransport(executable: path)
        }
        do {
            let client = try DAPClient(transport: transport)
            debugClient = client
            adapterInitialized = false
            stubForward = forward
            Task { [weak self] in
                for await e in client.events { await self?.handle(e) }
                forward.close()
                if self?.stubForward === forward { self?.stubForward = nil }
                self?.sessionEnded()
            }
            try await client.initialize()
            attachingSimulatorApp = true
            defer { attachingSimulatorApp = false }
            let dir = app.executableURL.deletingLastPathComponent().path
            try await client.attachRemote(port: forward.port, program: app.executableURL.path, threadFormat: DebugThread.format,
                                          preRunCommands: RemoteSimulator.debuggerSettings(appDirectory: dir) + Self.hostSignalCommands)
            // Attaching stops the app: resume it once so it runs to the
            // breakpoints. lldb reads ~500 system images from the process's
            // memory first (debug-stub.md §10: 19-40 s).
            for _ in 0..<1200 where stoppedThread == nil && debugClient === client && !cancelled() {
                try? await Task.sleep(for: .milliseconds(100))
            }
            attachingSimulatorApp = false
            if stoppedThread != nil, debugClient === client { await continueOrPause() }
        } catch {
            appendConsole("Ycode: attach failed: \(error)\n")
            forward.close()
            if let c = debugClient { c.close() }
            return .failed("\(error)")
        }
        if debugClient != nil, case .running = activity, stoppedThread == nil {
            setActivity(.running(RunActivityText.running(app.executable, on: device)))
        }
        return .attached
    }

    /// True while lldb-dap is attached through a stub forward.
    public var isDebuggingSimulatorStub: Bool { stubForward != nil && debugClient != nil }

    /// Stop for a run whose debugger is attached to a simulator stub: the
    /// debugger detaches (the app keeps running on the device, as after a
    /// Mac's remote run, debug-stub.md §8.2) and the forward closes.
    public func detachFromSimulatorStub() {
        stubForward?.close()
        stubForward = nil
        guard let c = debugClient else { return }
        Task {
            try? await c.disconnect(terminate: false)
            c.close()
        }
    }

    /// lldb on Linux gives a gdb-remote process of an Apple OS the host's
    /// signal numbers (observed with Swift 6.4's lldb: the stub's SIGSTOP,
    /// Darwin 17, read as SIGCHLD and the attach stop was passed and
    /// resumed at once). The stub sends Darwin numbers 4, 5, 8, 10, 11 and
    /// 17 (debug-stub.md §6.1); 4, 5, 8 and 11 mean the same on Linux, so
    /// Linux's 17 (SIGCHLD) and 10 (SIGUSR1) are set to stop: an attach or
    /// interrupt stop (not passed on) and a bus error (passed on, so the
    /// fault takes its course). Set before the attach, lldb keeps them for
    /// the process it creates. lldb on a Mac needs none.
    nonisolated static var hostSignalCommands: [String] {
        #if os(Linux)
        ["process handle -s true -p false -n true SIGCHLD", "process handle -s true -p true -n true SIGUSR1"]
        #else
        []
        #endif
    }

    private func finishStubAttach(app: String, device: String) {
        endDebugSession()
        setActivity(.finished(RunActivityText.finished(app, on: device)))
    }
}
