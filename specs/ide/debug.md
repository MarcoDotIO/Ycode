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
| Log Message + automatically continue | `logMessage` (a log point: `{expr}` is interpolated, execution continues) |
| Log Message without continue | not sent (DAP cannot log and stop); OPEN QUESTION |
| Debugger Command | kept, not sent: DAP has no per-breakpoint command (OPEN QUESTION: lldb-dap's own extensions) |

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

- Launch and attach pass lldb-dap's `threadFormat`:
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
