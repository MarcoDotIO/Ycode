# Debug: the Debug Adapter Protocol session

Ycode module: `YcodeDebug`. Ycode debugs through `lldb-dap`, LLVM's open
source Debug Adapter Protocol (DAP) server, never through private IDE
interfaces.

## Locating the adapter

1. `YCODE_LLDB_DAP` environment variable, if set.
2. macOS: `xcrun -f lldb-dap`.
3. `lldb-dap`, then `lldb-vscode` (older LLVM name), on `PATH`.

The adapter runs as a child process; DAP messages travel over its stdin and
stdout. Its stderr goes to Ycode's stderr.

## Wire format

Each message is `Content-Length: N\r\n\r\n` followed by N bytes of UTF-8
JSON. Header field names are case-insensitive; unknown fields are ignored.
A message is `request` (`seq`, `command`, `arguments`), `response`
(`request_seq`, `success`, `command`, `body` or `message`) or `event`
(`event`, `body`). The client numbers its requests 1, 2, 3, …

Reverse requests from the adapter (`runInTerminal`, `startDebugging`) are
answered with `success: false` for now.

## Session sequence

1. `initialize` (client `Ycode`, lines and columns start at 1, path format
   `path`); keep the returned capabilities.
2. `launch` (`program`, `args`, `env` as `NAME=value` list, `cwd`,
   `stopOnEntry`) or `attach` (`pid` or `program` + `waitFor`).
3. On the `initialized` event: one `setBreakpoints` per file that has
   breakpoints (it replaces that file's set), then `configurationDone`.
4. On `stopped`: `threads`, `stackTrace` of the stopped thread, `scopes`
   of the selected frame, `variables` of each non-expensive scope. The
   editor shows the frame's line; the variables view shows the variables.
5. Debug bar: Continue (`continue`), Step Over (`next`), Step Into
   (`stepIn`), Step Out (`stepOut`), Pause (`pause`).
6. `output` events go to the console (category `stdout`/`stderr`/`console`).
7. Stop (⌘.): `disconnect` with `terminateDebuggee: true`; `terminated` or
   `exited` ends the session.

If the adapter exits, all waiting requests fail and the event stream ends.

## Variables view and Debug navigator

- On `stopped`: `threads`, then `stackTrace` of the stopped thread; the
  top frame is selected. The variables view lists the variables of the
  selected frame's non-expensive scopes, except register scopes.
- A variable with a nonzero `variablesReference` is expandable; its
  children are fetched with `variables` on first expansion only, and are
  valid until the program resumes.
- Debug navigator (⌘7), per `reference-ui-4.md` §5.3: a process row
  "<product>  PID n" with gauge rows (CPU, Memory, Energy Impact, Disk,
  Network; sampled once a second — Energy Impact is derived from CPU and
  Network reads "Zero KB/s", Ycode's approximations); thread rows
  "Thread N  Queue: <label> (serial|concurrent)" (serial/concurrent is
  inferred from the label); the stopped thread's frames "index function",
  user frames first, then a dotted separator and the first system frame
  greyed, the rest hidden. It is selected automatically once per stop. Selecting a frame
  shows its variables and opens its source line. Frames without source are
  drawn dimmed.
- The editor tints the selected frame's line and marks it in the gutter.

## Breakpoint editing

Double-click or ⌘-click a breakpoint in the gutter opens an editor (a
popover beside the gutter): Condition, Ignore N times before stopping, one
Action (No Action | Log Message | Debugger Command, with its text), and
"Automatically continue after evaluating actions". Customized breakpoints
are drawn darker; the breakpoint navigator shows "line N [condition]".

Sent with `setBreakpoints` per file:

| Setting | DAP `SourceBreakpoint` field |
|---|---|
| condition | `condition` |
| ignore count N > 0 | `hitCondition` "N" (lldb-dap: ignore N hits) |
| One Log Message + automatically continue, no `%B`/`%H` | `logMessage` (a log point: `@expr@` is sent as `{expr}`, execution continues) |
| Any other actions, or automatically continue alone | not sent; Ycode runs them at the stop (below) |

Actions Ycode runs (B2-DEBUG2): when a `stopped` event with reason
`breakpoint` names (in `hitBreakpointIds`, else "breakpoint n.m" in its
description) a line breakpoint whose actions the adapter does not run,
Ycode runs its actions in order in the top frame before showing the stop:
**Log Message** prints the message to the console, `@expr@` and `{expr}`
evaluated with `evaluate` context `watch`, `%B` as `<file>:<line>`, `%H` as
the hit count (this stop included); **Debugger Command** is sent as
`evaluate` context `repl` and its output printed (errors as `error: …`);
**Sound** plays a sound of the computer's (freedesktop's stereo sound
theme through `pw-play`, `paplay` or `canberra-gtk-play` on Linux, the
system sounds through `afplay` on macOS; offered only when there are
sounds and a player). With "Automatically continue" Ycode then sends
`continue` and the stop is not shown (no Debug navigator, no annotation,
the hit is still counted). Stored in `ycode-breakpoints.json` as
`{"log": …}`, `{"command": …}`, `{"sound": …}`.

Debug ▸ Breakpoints holds the reference's commands (Create Breakpoint at
Current Line ⌘\, Enable / Disable Breakpoints at Current Line, Create
Column Breakpoint, …, Create Symbolic Breakpoint… ⌥⌘\, Delete All
Breakpoints; `reference-ui-5.md` §2.10, §10.2). Breakpoints persist per
user in the reference's `Breakpoints_v2.xcbkptlist` file
(`reference-ui-5.md` §10.1).

The breakpoint navigator's + menu (bottom left, shown with that navigator)
adds:

- **Exception Breakpoint** → exception filters `objc_throw`, `cpp_throw`;
- **Swift Error Breakpoint** → `swift_throw`;
- **Symbolic Breakpoint…** → a function name (and optional condition),
  sent with `setFunctionBreakpoints`.

Exception filters are sent with `setExceptionBreakpoints`, keeping only
ids the adapter lists in its `exceptionBreakpointFilters` capability.
Deactivating breakpoints (⌘Y) sends empty line, function and exception
lists. All three are re-sent on `initialized` and on every change.

## IDE mapping

| Command | Shortcut (public Xcode shortcut list) | DAP |
|---|---|---|
| Continue / Pause | ⌃⌘Y | `continue` / `pause` |
| Step Over | F6 | `next` |
| Step Into | F7 | `stepIn` |
| Step Out | F8 | `stepOut` |
| Toggle breakpoint at line | ⌘\\ | `setBreakpoints` |
| Activate/deactivate breakpoints | ⌘Y | `setBreakpoints` with empty lists |

## Debug console

- Below the console output: an `(lldb)` prompt, an input field, and a
  filter pop-up (All Output, Debugger Output, Target Output).
- Return sends the line as `evaluate` with `context: "repl"` and the
  selected frame's `frameId`: LLDB commands (`po x`, `p x`, `expr …`,
  `bt`) and expressions alike (lldb-dap decides which). The console shows
  `(lldb) <line>` then the result; the variables view reloads afterwards
  (an expression may change state). Errors print `error: …`.
- ↑ / ↓ walk the history of entered lines (oldest first); an empty line
  after the newest.
- Output sources: `output` events with category `stdout`/`stderr` are
  Target Output; other categories and entered lines are Debugger Output.

## Variables view depth

- Values and types are lldb-dap's (its formatters for Swift and
  Objective-C types).
- Context menu: Print Description (runs `po <name>` in the console),
  Copy Value (the value text to the pasteboard), Watch Variable,
  Edit Value… (also double-click), Add Expression….
- Edit Value: `setVariable` in the variable's container (the scope it was
  listed under); the view reloads.
- Watch expressions: evaluated with `context: "watch"` at each stop,
  listed first in the variables view (name = expression).

## Watchpoints

Watch Variable: `dataBreakpointInfo` (container reference + name) gives a
`dataId`; Ycode then sends `setDataBreakpoints` with every watchpoint
(access type `write` when offered). The Breakpoint navigator shows a
"Watchpoints" group (`<name> (<access>)`, "— not set" when the adapter
did not verify it). A hit stops with reason `data breakpoint`; lldb-dap
reports it as reason `breakpoint` with description `watchpoint N`
(observed), and Ycode's activity view shows "Paused <product>:
watchpoint N" (a stop whose reason is not breakpoint, step, pause, entry
or goto appends the reason to the `reference-ui-4.md` §5.1 title).

## Threads and queues; attaching

- Launch and attach pass lldb-dap's thread format, under both its names:
  `threadFormat` (older releases) and `customThreadFormat` (current LLVM
  documentation; the Swift 6.4 toolchain's lldb-dap on Linux reads only
  this one and otherwise names a thread after the process):
  `Thread ${thread.index}{ name = ${thread.name}}{ queue = ${thread.queue}}`;
  the queue is the text after ` queue = `.
- Debug ▸ Debug Workflow ▸ View Process by Queue toggles the Debug
  navigator between threads and queue groups (threads without a queue
  under "Threads").
- Debug ▸ Attach to Process by PID or Name…: digits attach by `pid`;
  otherwise `program` with `waitFor` (the name's next launch).

## Disassembly

Debug ▸ Debug Workflow ▸ Always Show Disassembly: at each stop, Ycode
sends `disassemble` (the frame's `instructionPointerReference`,
`instructionOffset` -8, 40 instructions, symbols resolved) and shows
`<address>  <instruction>    ; <symbol>` lines read-only in the editor,
with the program counter's line marked as the current line. While it is
on, Step Over / Step Into send `next` / `stepIn` with `granularity:
"instruction"`.

## Remote: apps on the Ycode simulator (SIM-DEBUG, 2026-10-30)

A run on a Ycode simulator destination (`run.md` §Remote Ycode simulator)
runs under the debugger, as a run on a Mac simulator does. ycode-simd
serves a gdb-remote stub for the launched app (`--debug-server`,
`specs/simulator/debug-stub.md`); ssh forwards its socket to a loopback
port of the Mac; lldb-dap attaches with its `gdb-remote-port` and
`gdb-remote-hostname` attach arguments and `program` = the local build of
the app's executable (so the symbols and sources are the build's). From
then on the session is the ordinary one above: `initialized` →
breakpoints → `configurationDone`, the app continued once after the
attach stop, `stopped` events, the variables view, the debug bar.

- The activity reads "Configuring Debugger Actions" from the launched line
  until the attach, then "Running <app> on <device>".
- Stop detaches (`disconnect` with `terminateDebuggee: false`): the
  launcher ends the app at its save.
- The defaults key `Ycode.remote.debugger` = false runs without the
  debugger; a Gauge profile run never attaches.
- What the stub offers (and so what LLDB can do) is in `debug-stub.md`:
  registers (general purpose and FP/SIMD), software breakpoints, single
  step, hardware watchpoints (the Watchpoints list and "Watch" on a
  variable work as on a Mac simulator), images loaded after the attach
  (breakpoints in a `dlopen`ed library resolve when it loads), and Swift,
  C and Objective-C expressions in the console (SIM-DEBUG2, 2026-10-31:
  the stub reports the runtime's OS version and the device OS type, so
  LLDB's Swift expressions get a valid `@available`, `debug-stub.md`
  §4.3). The variables view shows Swift values formatted (an `Int` as its
  digits; a struct as its type, `DebugDemo.Stats @ 0x…`, with its fields as
  children, as lldb-dap presents it); the opt-in `RemoteDebugEndToEndTests`
  checks that and a Swift expression at the breakpoint (`expression round *
  2` → `(Int) $R0 = 4`, SIM-DEBUG2).

## Environment Overrides and Simulate Location (FEAT-IMPL, 2026-10-27)

The debug bar's **Environment Overrides** and **Simulate Location**
buttons (after Step Out, `reference-ui-4.md` §1.2) act on an app running
on the Ycode simulator (`run.md` §Remote Ycode simulator). Until SIM-DEBUG
no debugger attached to such a run, so the reference's way — the debugger
running code in the app (`specs/simulator/simulator-features.md` §7.3) —
was not available, and the library below stays the way (it needs no
expression evaluation in the app). **Ycode decision:** the remote run launches the app with
`--environment-overrides`: ycode-simd inserts Ycode's overrides library
into the app (`DYLD_INSERT_LIBRARIES`) and names a directory of the device
for its overrides file; changing an override rewrites the app's file and
the library applies it inside the app at once. Only the app changes; the
device's settings and other apps stay as they are. A new run of the app
starts with no overrides (ycode-simd removes the file at the launch).

- **Environment Overrides** opens a pop-over (Ycode's layout; the
  reference's was not observed, §7.3 Q11): three sections with a switch
  each — **Appearance** (Light | Dark), **Dynamic Type** (a 12-step
  slider, X Small … Accessibility 5, with the size's name under it),
  **Accessibility** (check boxes: Increase Contrast, Reduce Transparency,
  Bold Text, Reduce Motion, On/Off Labels, Button Shapes, Grayscale, Smart
  Invert, Differentiate Without Color) — and **Disable All Overrides**. A
  section that is off is "No Override" for its items; with Accessibility
  on, each item takes its check box (checked = Enabled, Increased or
  Reduced; unchecked = Disabled or Default). Every change is sent at once
  as one control command, `overrides <bundle id> <item>=<value>…` (or
  `clear`); the line under the sections says "Applied to the running app",
  "No overrides" or the error. Without a run on the Ycode simulator the
  button shows a short note instead.
- **Simulate Location** opens a menu: Don't Simulate Location, the 14
  places of `simulator-features.md` §7.1, then City Run, City Bicycle
  Ride, Freeway Drive, Apple; the item last chosen is checked; choosing one
  sends `location set …`, `location run …` or `location clear` to the
  run's device. Without such a run the menu says "Location simulation
  needs a run on the Ycode simulator".

**The Debug menu (IDE-QUICKWINS, 2026-10-30).** The same features from the
menu bar: **Debug ▸ Simulate Location ▸** is filled with the debug bar's
menu each time it opens (the note alone without a run on the Ycode
simulator). **View Debugging ▸ Disable All Environment Overrides** sends
`overrides <id> clear` (enabled while overrides are set). **View Debugging
▸ Appearance ▸** changes the overrides (Ycode decision): System Appearance
removes the appearance and Increase Contrast overrides; Light and Dark
set the appearance and remove Increase Contrast; High Contrast Light and
High Contrast Dark set the appearance and Increase Contrast. The item
matching the overrides is checked; all are disabled without a run on the
Ycode simulator. Code: `YcodeIDECore` `DebugAppearanceMenu`, `YcodeUI`
`WorkspaceWindowController+SimulatorDebugMenu.swift`. Tests:
`IDEQuickWinsUITests.simulateLocationSubmenu`,
`appearanceAndDisableAllOverrides`.

What the library does in the app (`SimGuestAgents/overrides`):
appearance, Dynamic Type, Increase Contrast and Bold Text become trait
overrides of every window scene (UIKit's public `traitOverrides`), so the
trait collection, SwiftUI's environment and Dynamic Type fonts follow; the
accessibility switches answer UIKit's public status functions
(`UIAccessibilityIsReduceMotionEnabled` and the others, through dyld
interposing) and their public change notifications are posted. Code:
`YcodeUI` `EnvironmentOverridesPanel.swift`, `DebugBarExtras.swift`,
`WorkspaceWindowController+SimulatorDebugBar.swift`; model
`YcodeSimFeatures.EnvironmentOverrides`. Tests: `SimulatorSettingsUITests`,
`SimFeaturesTests`; verified on the Linux host with Ycode's probe app
(`simulator-features.md` "Ycode implementation" §I.8).

## The Linux IDE (B2-DEBUG, 2026-11-04)

`ycode-ide` debugs Swift packages through the same `WorkspaceSession` and
lldb-dap session as the macOS IDE; `YcodeIDEShell.ShellDebugModel` mirrors
it for the OpenViews views.

- **Adapter.** `YCODE_LLDB_DAP`; in the Flatpak the package's host-tool
  wrapper (`libexec/ycode-host/lldb-dap`, run on the host through
  `flatpak-spawn`); else `PATH`, then swiftly's folders
  (`~/.local/share/swiftly/bin`, `~/.swiftly/bin`).
- **Gutter.** A click on a line number adds a breakpoint or enables or
  disables the line's; a breakpoint dragged along the gutter moves, out of
  it (more than 24 points right of the gutter) is deleted. The breakpoint
  is the macOS shape (a tag pointing right behind the number, which turns
  white); pale when disabled or deactivated, darker when customized. The
  selected frame's line has a green band, a mark at the gutter's edge, and
  the stop's annotation at its end.
- **Navigators.** Debug (⌘7) and Breakpoints (⌘8) per `reference-ui-4.md`
  §5.3 and §6. On Linux a frame is a user frame only when its source is on
  this computer (the C library's start-up frames name absolute build
  paths). Breakpoint rows read "<function>  <line>" with an F or M badge,
  else "line <n>"; a context menu deletes one; the marker toggles it.
- **Variables.** "A"/"L" badges; lldb-dap lists arguments with the locals,
  so a name in the enclosing declaration's parameter list (read from the
  source) is an argument. Expanded aggregates stay expanded across steps
  (their children are fetched again by name).
- **Debug area and bar.** The variables view and the console side by side
  (each can be hidden from the console bar), the `(lldb)` prompt under the
  console while a session runs (↑/↓ history), the output filter. The debug
  bar: breakpoints toggle, Continue/Pause, Step Over, Step Into, Step Out,
  the path.
- **Menus.** Debug ▸ Pause/Continue, Step Over/Into/Out (F6/F7/F8),
  Deactivate Breakpoints (⌘Y), Breakpoints ▸ Create Breakpoint at Current
  Line (⌘\\), Enable/Disable Breakpoints at Current Line, Delete All
  Breakpoints, Console ▸ Clear Console; View ▸ Navigators ▸ Debug,
  Breakpoints. Deactivate Breakpoints is Ctrl+Y on Linux, with the editor
  focused too (the editor leaves Ctrl+Y to the menu bar; Redo is
  Ctrl+Shift+Z).
- **Copy items.** The variables' Copy Value and the console's rows: a
  click selects a row of the run's output; its context menu and Debug ▸
  Console ▸ Copy Row with Visible Metadata (⌥⇧C) / with All Metadata /
  without Metadata copy it (`ConsoleRows.copyText`; the Linux console
  shows no metadata columns, so "visible" is the bare row). The text goes
  to the system clipboard through OpenViews (`OpenViewsClipboard`).
- Tests: `ShellDebugTests` (a scripted adapter), `LLDBDAPLocateTests`;
  end to end on x86-64 Linux with `YCODE_IDE_DEBUG` (`DebugDriver.swift`).

### Editing (B2-DEBUG2, 2026-11-04)

- **Breakpoint editor popover.** Opened by a double-click or ⌘-click (the
  Super key) on a breakpoint in the gutter, the gutter's context menu, a
  double-click or the context menu of a Breakpoint navigator row. A card
  beside the gutter (or the row) with an arrow pointing at it; changes
  apply as they are typed; Done, Return in a field, Escape or a click
  outside close it. Line breakpoint: the title "<file>:<line>",
  Condition, Ignore [n] times before stopping, Action ("Add Action"; each
  action a kind pop-up — Log Message, Debugger Command, Sound — with "+"
  and "−", then its message field with the hint "@exp@ = expression %B =
  breakpoint name %H = hit count", its command field, or the sound pop-up),
  Options "Automatically continue after evaluating actions". Symbolic
  breakpoint: Symbol and Condition. Exception breakpoint: the language and
  Break (On Throw / On Catch, i.e. `*_throw` / `*_catch`).
- **Context menus.** A breakpoint in the gutter (the breakpoint under the
  pointer replaces the editor's Cut/Copy/Paste menu): Edit Breakpoint…,
  Disable/Enable Breakpoint, Delete Breakpoint, Reveal in Breakpoint
  Navigator. A Breakpoint navigator row: Edit Breakpoint…, Disable/Enable
  Breakpoint, Delete Breakpoint. Symbolic rows have the enabled marker.
- **The "+" menu** (the Breakpoint navigator's bottom bar) and Debug ▸
  Breakpoints: Swift Error Breakpoint (`swift_throw`; disabled while it
  exists), Exception Breakpoint… (`cpp_throw` on Linux, adding
  `objc_throw` on macOS; its editor opens), Symbolic Breakpoint… (a new row
  whose editor takes the symbol; a row left without a symbol is removed).
  Left out on Linux: Runtime Issue, Constraint Error and Test Failure
  breakpoints (Apple runtimes). A symbol is sent trimmed; empty ones are
  not sent.
- **Variables view.** Context menu: Print Description of "<expr>", Copy
  ("(Type) name = value"), Copy Value, View Memory of "<expr>", Watch
  "<expr>", Edit Value…, Add Expression…, and Delete Expression on a watch
  row (`<expr>` is the row's path, "stats.total"; array elements "a[0]").
  Watch expressions are listed first without a badge, evaluated (context
  `watch`) at every stop and frame change and after an edit, expandable,
  and kept while the workspace is open. Add Expression… is a field at the
  top of the view. Edit Value (also a double-click) turns the value into a
  field; Return sends `setVariable` in the row's container. Swift 6.4's
  lldb-dap on Linux answers `setVariable` on Swift integers with "Invalid
  encoding." (observed); Ycode then sends `evaluate` context `repl`
  `expression -- <expr> = <value>`; a failure is printed in the console.
  The clipboard: the editor's text surface, else `wl-copy` / `xclip`
  (until OpenViews has a clipboard API).
- **Debug ▸ Debug Workflow.** Navigate to Source File when Process Pauses
  (check mark, on), Always Show Disassembly (check mark; DAP `disassemble`,
  shown over the editor as "<address>  <instruction>    ; <symbol>" lines
  with the program counter's line marked, Step Over/Into by instruction),
  View Memory (enabled while paused when the adapter has
  `supportsReadMemoryRequest`). A selected frame whose source is not on
  this computer (a Swift error stops in the runtime's `swift_willThrow`)
  also shows its disassembly. Left disabled: Synchronize Insertion Point
  to Program Counter (on Linux the insertion point always follows the
  stop), Show Library Info…, Load Symbols… (dSYM loading, Apple
  platforms), Interrupt Debugger Operation.
- **View Memory.** Covers the editor: the title ("Memory of "stats""), an
  Address field (an address or an expression; its value's
  `memoryReference`), Previous / Next Page (256 bytes), and 16 bytes a line:
  the address (16 hex digits), the bytes in two groups of eight, and the
  printable ASCII; "??" for unreadable bytes. DAP `readMemory`.
- Tests: `ShellDebugEditingTests` (a scripted adapter); end to end on
  x86-64 Linux with `YCODE_IDE_DEBUG2` (`DebugEditingDriver.swift`).

### Apps on the simulator (B3-SIMDEBUG, 2026-11-05)

Product ▸ Run on a Ycode simulator destination (a device of a paired
`ycode-simhost`, `specs/simulator/sim-link.md` §10) runs the app under
the debugger when the host is this computer, as Run on a Mac simulator
does on macOS. The debug UI is the one above (gutter, Debug and Breakpoint
navigators, variables view, console, debug bar, Debug menu).

1. Run builds the app here and uploads it; the link's `run` request
   carries `debug: true`, and the host starts the app with ycode-simd's
   debug stub on `<home>/run/<device>.debug.sock` (`sim-link.md` §6,
   `specs/simulator/debug-stub.md`). The response names the socket.
2. The activity reads "Launching <app>" while the device boots or
   restores and installs the app; the IDE asks the host's log (the link's
   `log`, once a second) for "ylaunch: launched <bundle id> pid N".
3. Then "Configuring Debugger Actions": a loopback forward
   (`YcodeDebug.StubForward`, 127.0.0.1 and a port the system picks; it
   accepts one connection and closes its listener, so no other user of a
   shared host reaches the stub through it) carries lldb-dap's gdb-remote
   connection to the socket. lldb-dap attaches with `gdb-remote-port`,
   `program` = this computer's build of the executable, and the
   `preRunCommands` of `debug-stub.md` §8.3. Breakpoints are sent on
   `initialized`; the attach stop is resumed once.
4. "Running <app> on <device> (<host>)"; a breakpoint stop reads "Paused
   <app>", with the frames, the variables and the console as for a
   package. Pause, Continue, Step Over/Into/Out work.
5. Stop detaches (`disconnect` with `terminateDebuggee: false`) and closes
   the forward and the device window; the app runs on on the device, as
   after the Mac's remote run (`debug-stub.md` §8.2).

- **lldb on Linux and Darwin signal numbers.** Swift 6.4's lldb on Linux
  gives a gdb-remote process of an Apple OS (target `arm64-apple-ios`,
  platform `remote-ios`) the host's signal table: the stub's SIGSTOP
  (Darwin 17) reads as SIGCHLD, whose default is "do not stop, pass", so
  lldb resumed the process right after the attach (observed: "Process N
  stopped and restarted: thread 1 received signal: SIGCHLD"). The stub's
  signals are Darwin's 4, 5, 8, 10, 11 and 17 (`debug-stub.md` §6.1); 4,
  5, 8 and 11 mean the same on Linux. On Linux the IDE adds to the
  `preRunCommands` `process handle -s true -p false -n true SIGCHLD` (17:
  the attach and interrupt stops stop and are not passed on) and
  `process handle -s true -p true -n true SIGUSR1` (10, Darwin's SIGBUS:
  stops, and is passed on so the fault takes its course). lldb keeps
  handle settings made before the attach for the process it creates. A
  stop shown with a signal names Linux's (an interrupt reads "signal
  SIGCHLD" in lldb's own output; the IDE shows Pause's stop as paused).
  OPEN QUESTION: where lldb on Linux takes the signal table of a remote
  Darwin process from (a fix there would show the right names).
- **Symbols.** An app built on Linux (`scripts/ycode-ios-build-linux`,
  `DEBUG_INFORMATION_FORMAT=dwarf`) keeps its debug information in the
  object files its debug map names, under the derived data on this
  computer; lldb reads them there (no dSYM: the Linux toolchains have no
  `dsymutil`). The system images are read from the process's memory
  ("libobjc.A.dylib is being read from process memory"), as on a Mac.
- **Off:** `YCODE_IDE_SIM_DEBUGGER=0` runs without the debugger. A host on
  another computer runs the app without it, with the console line "The
  debugger attaches only to a simulator host on this computer; <host>
  runs <app> without it." until the link carries the stub (#50).
- Tests: `ShellSimulatorDebugTests` (host detection, the launch line, a
  scripted lldb-dap attach: activities, the attach arguments, the stop,
  Continue, the detach), `StubForwardTests`, `SimLinkTests` (the `debug`
  field, the stub's socket); end to end on the arm64 Linux host with
  `SimulatorDebugEndToEndTests` (gated by `YCODE_SIM_DEBUG_E2E`) and the
  `YCODE_IDE_SIMDEBUG` walk (`SimDebugDriver.swift`).
- **Results** (2026-11-05; the arm64 Linux host loaded by other agents,
  load 30-100; iPhone Duo, iOS 27.1; TapCounter built on the x86-64 PC
  with `ycode-ios-build-linux` into the same derived-data path, since the
  host has no user SDK or Apple-capable `ld64.lld`; Swift 6.4's lldb-dap):
  Run → "Launching TapCounter" (cold boot, home screen at 226 s) →
  "Configuring Debugger Actions" (the attach: about 70 s, lldb reading the
  system images from memory) → "Running TapCounter on tc (b3-simdebug)";
  a tap on the button stopped the app at TapCounter.swift:72 ("Thread 1:
  breakpoint 1.1 (1)", frames `CounterController.buttonTapped(_:)`, `@objc
  CounterController.buttonTapped(_:)`, `-[UIApplication
  sendAction:to:from:forEvent:]`, … `UIApplicationMain`), variables
  `sender: UIButton`, `self: TapCounter.CounterController`; Step Over to
  line 73 showed `step: Int = 1`; Continue ran it again; the next tap
  stopped again with "(2)" and `step` 2 after a step; Stop detached
  ("Finished running TapCounter on tc (b3-simdebug)") and the app ran on.
  `SimulatorDebugEndToEndTests` passed the same steps without a window.
- **Not done (lldb on Linux).** The members of a Swift class whose
  superclass is an Objective-C class (`self` of a `UIViewController`
  subclass) do not show: lldb answers "Could not compute start field
  offset for typeref" (it needs the superclass's instance size, which
  lldb on Linux does not read from the Objective-C runtime), so `self`
  expands to nothing. Swift structs, arguments and locals show. Swift
  expressions (`p`, `po`) fail: lldb cannot load the app's Swift module
  ("failed to open explicit Swift module … prebuilt-modules", "Error
  while searching for SDK: HostInfoError"), also with `target.sdk-path`
  set to the user's SDK; C and Objective-C expressions work (`expression
  -l c -- (int)getpid()` → the guest pid). OPEN QUESTION: whether a later
  lldb on Linux reads Objective-C class layouts of a remote Darwin process.

## Evidence

- Debug menu items and the breakpoint file format: `reference-ui-5.md`
  §2.10 (level 3) and §10.1 (level 2, a file the reference wrote).
- DAP framing, messages and requests: the Debug Adapter Protocol
  specification (Microsoft, open) and LLVM's `lldb-dap` documentation and
  source (level 1).
- `xcrun -f` tool lookup: `man xcrun` (level 1).
- Shortcuts: Apple's published Xcode keyboard-shortcut reference (level 1).
- End-to-end (level 3, black-box run of the public `lldb-dap` tool): a C
  program built with `clang -g`; `launch` may not be answered until
  `configurationDone`, so the client sends launch, then configures on
  `initialized`. Verified: breakpoint stop reason `breakpoint`, frame lines,
  local values, struct children via `variablesReference`, `next` stop reason
  `step`, `exited` with exit code 0. lldb-dap reports register scopes as
  not expensive.
- Registers are not shown by default; they appear in the "All Variables,
  Registers, Globals and Statics" scope: `specs/ide/reference-ui-2.md` §9
  (level 3).
- OPEN QUESTION: Xcode's thread row text.
- Linux IDE editing (B2-DEBUG2): lldb-dap's capabilities, `hitBreakpointIds`,
  `memoryReference` on variables and evaluate results, `readMemory`, the
  `swift_throw` stop (reason `exception`, description "Swift Throw", top
  frame `swift_willThrow`) and the `setVariable` refusal, observed with
  Swift 6.4.2's lldb-dap (LLDB 21) on x86-64 Linux (level 3). The log
  message tokens and action kinds: Apple's public Xcode Help (level 1).
  Watch rows without a badge, the editor's field order and the memory
  browser's layout are Ycode design (OPEN QUESTION: the reference's).
- Breakpoint editing (condition, ignore, actions, auto-continue,
  exception/symbolic from the + menu): Apple's public Xcode Help (level 1);
  DAP fields from the DAP specification (level 1); verified against
  lldb-dap: a conditional line breakpoint stopped only at `a == 3`, a log
  point printed each loop value without stopping, a conditional symbolic
  breakpoint stopped at `a == 4` (level 3).
- Debug area layout and bars (50/50 split; variables bar with the "Auto"
  scope pop-up, two toggles and a filter; console bar with two output
  toggles, filter, clear and show/hide buttons; "Line: N Col: N" in the
  debug bar): `specs/ide/reference-ui.md` §5 (level 3). Ycode's scopes:
  Auto (everything the adapter returns), Local Variables (hides `$`
  names), All Variables (with the registers toggle).
- OPEN QUESTION: how Xcode's Auto scope maps to lldb-dap's Locals/Globals/
  Registers scopes.
- Bars per reference-ui-2.md §9: registers appear only with "All
  Variables, Registers, Globals and Statics"; Quick Look and info buttons
  (Quick Look shows the value in a popover). Console bar: Quick Look, an
  output-options popover (Metadata switch on; Type, Timestamp, Library,
  PID:TID, Subsystem, Category off — Ycode records Type and Timestamp,
  prefixing "[Target]"/"[Debugger]" and "HH:mm:ss.SSS"; the others are
  disabled), the output filter (All / Debugger / Target Output), the text
  filter, clear, and the two halves' toggles. "Program ended with exit
  code: N" is printed as its own paragraph. Removing a file's last
  breakpoint sends an empty `setBreakpoints` for it; exception filters are
  sent only when the adapter lists them. Debug navigator rows read
  "Thread <index> — <name and queue>".
- Console, setVariable, watch expressions, data breakpoints, disassemble,
  instruction granularity, attach, threadFormat: the DAP specification and
  lldb-dap's documented launch/attach arguments (level 1). Checked by
  `DebuggerProtocolTests` against a scripted adapter that answers in the
  specification's shapes; `DebuggerDepthTests` runs the same flows against
  the real lldb-dap on a C program (level 3) where the machine can launch
  under the debugger.
- Console bar and its metadata popover (Type, Timestamp, Library, PID:TID,
  Subsystem, Category): `specs/ide/reference-ui-2.md` §9 (level 3).
- OPEN QUESTION: Xcode's console prompt styling; whether its Edit Value is inline in the row; which
  access type Watch uses by default; the disassembly window size and
  format; queue grouping details (Xcode shows queue labels and thread
  counts).
- Remote debugging (SIM-DEBUG): lldb-dap's `gdb-remote-port` /
  `gdb-remote-hostname` attach arguments (LLVM's lldb-dap documentation,
  level 1); the stub and its evidence: `specs/simulator/debug-stub.md`.
- Environment Overrides and Simulate Location (FEAT-IMPL): items, values
  and categories from `specs/simulator/simulator-features.md` §7.3 (level
  4 there); the pop-over layout and the in-app library are Ycode design
  (public UIKit trait overrides and status functions, level 1).
- Simulator apps in the Linux IDE (B3-SIMDEBUG): lldb's signal handling
  of a remote Darwin process on Linux, the attach stop restarted as
  SIGCHLD and the `process handle` settings kept from before the attach,
  observed with Swift 6.4's lldb and lldb-dap on arm64 Linux against
  ycode-simd's stub (level 3); `process handle` and lldb-dap's
  `preRunCommands`: LLDB's documentation (level 1). The rest is Ycode
  design.
