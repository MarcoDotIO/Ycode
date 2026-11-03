# Gauge: Ycode's performance profiler

**Status:** Ycode's own design (clean room), round 1 (agent PROFILER,
2026-10-29). Round 1 builds the time profiler, signposts, hangs, frames and
GPU tracks, the trace format, the analysis core, `ycode profile` and the IDE
window; §9 lists what later rounds add. Implementation status per part:
§10.

**Name.** The profiler is **Gauge**. Its recordings are **Gauge traces**
(`.gaugetrace`). What it records are **probes** (Time Sampler, Signposts,
Hangs, Frames, GPU); each probe draws one or more **tracks** on the
timeline. Gauge is a feature of Ycode, not a separate application: it opens
in a window of Ycode (§6) and from the command line (`ycode profile`, §7).

Sources: Ycode's existing profiling machinery (`specs/simulator/
boot-profile.md` §1.3 and §5, the guest PC samples with frame-pointer call
chains; `frame-profile.md`, presents; `stage8-contract.md` §14, the Metal
trace), the IDE specs (`schemes.md` Profile action, `menus.md` ⌘I,
`run.md` remote runs, `liquid-glass-ycode.md`), public documentation (the
`os_signpost` and `os_log` headers of the iOS SDK; the Linux
`perf_event_open(2)` man page and `linux/perf_event.h`; the ELF and DWARF 5
standards; the Mach-O `nlist_64` layout in the SDK's `mach-o/nlist.h`),
and the public descriptions of what a time profiler shows (call tree,
inverted tree, flame graph). Nothing here describes another profiler's
implementation; the feature set is the common one of sampling profilers.

## 1. Recording targets

| Target | Where it runs | Back end | Round 1 |
|---|---|---|---|
| **App on a Ycode simulator** (the main target) | the simulator host (arm64 Linux, KVM) | `ycode-simd --profile` (§3.1): the VMM samples the guest's vCPUs | built |
| **Linux process** (SwiftPM executables and tests) | any Linux host | `perf_event_open` sampling (§3.2) | built |
| **macOS process** launched by Ycode | the Mac | debugserver-based sampler (§3.3) | design only |
| Mac simulator (`simctl`) apps | the Mac | as macOS processes (simulator apps are host processes) | later, with §3.3 |

A recording has one **target process** (the app; for Linux, the launched
command and its threads). The simulator back end can add more processes by
name (`--profile-process`), so a trace can show, for example, the app and
the render server side by side.

Start and stop:

- **Launch** (the default): the target is launched under recording. The
  simulator back end starts sampling when the launched app's image starts
  (its first guest instruction), so the app's start is in the trace.
- **Attach**: an already running process (Linux `--pid`; simulator
  `--profile-process <name>`).
- **Stop**: the target exits; the user stops (IDE Stop, SIGINT); or a time
  limit (`--profile-seconds`). The trace is written at the stop in each case.

## 2. Probes and tracks

| Probe | What it records | Tracks |
|---|---|---|
| **Time Sampler** | every thread of the target, `rate` times a second (default 1000 Hz): time, thread, state, call chain | *CPU* (samples per interval, user and kernel stacked), one lane per thread |
| **Signposts** | `os_signpost` intervals (begin/end with the same id, log and name) and events, with subsystem, category, name and the unformatted message | *Signposts*, one row per name |
| **Hangs** | intervals where the main thread did not wait for events for at least the hang threshold (default 250 ms) | *Hangs* |
| **Frames** | every display present (the frame record, `simframebuffer.md`) | *Frames*: one tick per present, intervals over 1.5 × the display period marked long |
| **GPU** | every Metal command buffer: client process, host submit and completion times, GPU duration | *GPU*: one bar per command buffer, by process |
| Allocations, Leaks | later rounds (§9) | — |

### 2.1 Sample states

Each sample of a thread has one state:

| State | Meaning (simulator back end) | CPU? |
|---|---|---|
| `user` | the vCPU was running guest code at EL0 | yes |
| `kernel` | the thread was in a trap: in Ycode's kernel (the VMM's trap handler) or in the EL1 shim; the stack is the user stack at the trap with a leaf frame naming the trap | yes |
| `blocked` | the thread slept in a kernel wait (a `WaitQueue`), other than an idle wait | no |
| `idle` | the thread slept waiting for messages (`mach_msg` receive: Mach traps −31 and −47): a run loop with nothing to do | no |

The call tree counts CPU samples only by default; "All States" adds the
others (useful to see where threads wait). On Linux only `user` and
`kernel` occur (perf samples only running threads).

### 2.2 Hangs

A **hang** is a maximal interval in which every sample of the main thread
is `user`, `kernel` or `blocked` (never `idle`), at least the threshold
long. The interval runs from the first such sample to the last one plus
one sample interval. Severity: *hang* from the threshold, *severe hang* from
4 × the threshold (default 1 s). Hangs are computed from samples (so any
trace with main-thread samples has them) and also written into the trace.
A gap between two samples of the main thread longer than max(4 sample
intervals, threshold / 4) ends a run (the thread did not exist, or the
recorder paused); a shorter gap does not, because under emulation a
delayed sampler or a kicked vCPU that did not answer in time skips a few
samples of a thread that kept running (§10.2: gaps of 5–36 ms in 1000 Hz
recordings).

### 2.3 Signposts

Intervals are matched by (log handle's subsystem, category, signpost id,
name): a begin opens an interval, the next end with the same key closes
it. An end without a begin is an event marked `unmatched`; a begin without
an end lasts to the end of the recording and is marked `open`.
`OS_SIGNPOST_ID_EXCLUSIVE` intervals match by name and log only.

## 3. Back ends

### 3.1 Apps on a Ycode simulator (`ycode-simd --profile`)

`ycode-simd` options (device mode, with `--launch`):

| Option | Default | Meaning |
|---|---|---|
| `--profile <path>` | off | record a Gauge trace of the launched app to `<path>` (a host path) |
| `--profile-rate <hz>` | 1000 | samples per second per thread (10–10000) |
| `--profile-hang-ms <ms>` | 250 | hang threshold written into the trace |
| `--profile-seconds <s>` | none | stop recording after this many seconds of the target's life |
| `--profile-process <name>` | none | also record every process whose program name is `<name>` (repeatable) |
| `--profile-no-signposts` | off | do not insert the signpost agent |

These are app options: the warm-boot launcher (`run.md` §Warm boot) passes
them to `ycode-simd` and leaves them out of the snapshot's fingerprint.

**Sampler.** One host thread (`ycode gauge sampler`) wakes every
1/`rate` s (absolute deadlines, so the rate does not drift) and, for every
live thread of every recorded process:

- **running guest code**: the existing diagnostic kick (`boot-profile.md`
  §1.3): the vCPU's host thread is signalled out of `KVM_RUN`, records PC,
  LR, FP and PSTATE, reads the frame-pointer chain (AAPCS64 frame records:
  `[fp]` = caller's fp, `[fp + 8]` = return address; up to 128 frames, each
  16 bytes read through the address space, stopping at a non-increasing or
  unaligned fp) while its guest is stopped, and re-enters the guest. PSTATE
  at EL1 (the shim) makes the sample `kernel`;
- **in a trap handler**: no kick; the user registers saved at the trap's
  entry (`ThreadContext.entryFrame`: ELR, x29, x30) give the stack, and a
  leaf frame names the trap (`TrapNames`); state `kernel`;
- **blocked in a kernel wait**: the saved user registers again; state
  `idle` for `mach_msg` receives (traps −31, −47), else `blocked`. Only the
  main thread's blocked stacks are read (hangs need them); other blocked
  threads record state only.

Sample times are the guest's counter (`DarwinKernel.counter`, the
`mach_absolute_time` timebase), converted to nanoseconds since the
recording began; the same clock stamps signposts, so the two line up
without correction. Host-clock events (presents, GPU) are converted
through one (host ns, guest counter) pair taken at the start.

**Thread names.** The guest thread's id (`thread_selfid`), its kind
(main, pthread, workqueue) and, when the thread named itself through
`proc_info`'s thread-name call or `pthread_setname_np`, that name.

**Images and symbols.** At the stop the recorder lists every image a sample
touched and resolves what it can on the host:

| Address range | Image | Symbols from |
|---|---|---|
| the main executable and `dyld_sim` | `ImageMap.fixed` | their Mach-O symbol tables (host path of the installed app; runtime root) |
| a shared-cache image | the cache's image list (`ImageMap`) | the image's `LC_SYMTAB` inside the cache (§4.2) |
| a file-backed mapping (app frameworks, inserted libraries, Ycode's host libraries) | the address space's file regions; the image base is the region's address minus its file offset | the file's Mach-O symbol table (host path) |
| the trap leaf | `Ycode kernel` (kind `kernel`) | trap names |
| anything else | `?` (absolute address kept) | — |

Each image carries its UUID (from its `LC_UUID`), so the IDE can find the
matching dSYM and add source lines (§4.3).

**Signposts.** Unless `--profile-no-signposts`, the app is launched with
Ycode's signpost agent, `libYcodeGauge.dylib` (`SimGuestAgents/gauge/`,
original Ycode code, built with the iOS simulator SDK's public headers),
inserted with `DYLD_INSERT_LIBRARIES` (after any other inserted library).
The agent interposes, through dyld's public interposing section, three
public functions of `<os/log.h>` and `<os/signpost.h>`:

- `os_log_create`: calls the original and remembers (handle → subsystem,
  category);
- `os_signpost_enabled`: true while the agent records (so the emit macros
  do not skip the call), else the original's answer;
- `_os_signpost_emit_with_name_impl`: writes one record (below) and calls
  the original.

Records go to the file named by `YCODE_GAUGE_SIGNPOSTS` (a guest path the
recorder chooses in the device's data volume, `O_APPEND`, one `write` per
record, so a killed app loses nothing written). Record: magic `YGS1`,
u16 record length, u8 type (0 event, 1 begin, 2 end), u8 0, u64
`mach_absolute_time`, u64 signpost id, u64 thread id (`pthread_threadid_np`),
then four NUL-terminated strings: subsystem, category, name, format. The
message is the format string; argument values are not decoded (the
argument buffer's encoding is not public). Limitation: calls that bind to
`_os_signpost_emit_with_name_impl` inside the shared cache (for example
the Swift overlay's `os_signpost` wrapper) are not interposed; the C
macros and any call bound from the app's own image are.

**Frames and GPU.** With `--profile` the recorder polls the device's frame
record every 1 ms while the target lives (a present = a new frame counter)
and sets `YCODE_METAL_TRACE` (unless already set) to a file next to the
trace, whose command-buffer lines (`stage8-contract.md` §14.1) become the
GPU track (`pid`, submit = `submitted_ns`, end = `done_ns`, GPU duration =
`gpu_end_ns − gpu_begin_ns` scaled by the timestamp period).

**Cost.** Measured in §10.2: the sampler's time per sample and the
profiled app's slowdown at 1000 Hz.

### 3.2 Linux processes (`ycode profile record --linux`)

Two back ends; `--backend auto` (the default) picks perf when
`/proc/sys/kernel/perf_event_paranoid` is 2 or less, else the agent (and
falls back to the agent when the open is refused). Ubuntu's default (4)
forbids `perf_event_open` to unprivileged users entirely, so on such a host
only the agent works without changing a system setting.

**perf back end:**

- `perf_event_open(2)`, `PERF_TYPE_SOFTWARE`/`PERF_COUNT_SW_TASK_CLOCK`
  (CPU time of the task, so a sample is taken only while a thread runs),
  `sample_period` = 10⁹ / rate ns, `sample_type` = `IP | TID | TIME |
  CALLCHAIN`, `exclude_kernel` when `/proc/sys/kernel/perf_event_paranoid`
  is above 1 (then kernel time shows as a gap, not as frames), `inherit` and
  `enable_on_exec` for a launched command (every thread it creates is
  sampled into the same ring), `sample_id_all`, `comm`, `mmap` records for
  image tracking.
- **Launch**: Ycode forks, the child waits on a pipe; the parent opens the
  event for the child's pid, maps its ring (`mmap`, 1 + 2ⁿ pages), then lets
  the child `execvp`. **Attach** (`--pid`): one event per thread in
  `/proc/<pid>/task`, rescanned every 100 ms.
- The kernel's call chain uses frame pointers (`PERF_CONTEXT_USER` /
  `PERF_CONTEXT_KERNEL` markers split it). Swift on Linux keeps frame
  pointers by default; C code built with `-fomit-frame-pointer` shows short
  chains. DWARF unwinding (`PERF_SAMPLE_STACK_USER` + `.eh_frame`) is a later
  round (§9).
- **Images**: `PERF_RECORD_MMAP`/`MMAP2` records and `/proc/<pid>/maps` at
  the stop give executable mappings (path, start, end, file offset).
- **Symbols**: each mapped ELF file's `.symtab` (else `.dynsym`), function
  symbols (`STT_FUNC`) with their sizes; an address maps to `vaddr =
  address − mapping start + mapping offset − (segment offset − segment vaddr)`
  of the `PT_LOAD` that contains the file offset. Source lines from
  `.debug_line` when present (§4.3). Swift names are demangled by
  `swift-demangle` when it is on the path.
- Every sample is `user` or `kernel` (a call chain with kernel frames).

**Agent back end** (`libYcodeGaugeAgent.so`, built by SwiftPM next to
`ycode`, original Ycode C): the command is launched with `LD_PRELOAD` and
`YCODE_GAUGE_SAMPLES=<file>`. Its constructor arms `ITIMER_PROF` (process
CPU time) at the rate; the kernel sends `SIGPROF` to the thread that was
running, whose handler takes PC and frame pointer from the signal context,
walks the frame records reading memory with `process_vm_readv` on its own
process (a bad frame pointer ends the walk instead of faulting), and appends
one record with `write(2)`: `"YGA1"`, u16 size, u16 frame count, u32 pid,
u32 tid, u64 `CLOCK_MONOTONIC` ns, u64 PC, u64 return addresses. Only
async-signal-safe calls run in the handler. Kernel time is not seen
(`user` samples only). Swift on Linux keeps frame pointers in functions
that call others but not in leaves, so a sample in a leaf misses the leaf's
caller (the leaf's own frame is correct); `perf` has the same limit.

### 3.3 macOS processes (design; later round)

Public mechanisms only. The choice: **LLDB's open-source `debugserver`**
(Apache 2.0 with LLVM exceptions, shipped with the Command Line Tools as
part of LLDB) driven over the GDB remote serial protocol, which Ycode's
debugger support already speaks to through lldb-dap. Per sample: interrupt
(`\x03`), `jThreadsInfo` (every thread's registers in one reply), read the
frame-pointer chains with `x`/`m` packets, continue (`vCont;c`). Each sample
stops the process (≈ 100 µs–1 ms per stop), so the default rate would be
100 Hz and the slowdown must be measured. Alternatives considered: the
Mach `task_for_pid` + `thread_get_state` path (needs the debugger
entitlement, which Ycode as an unsigned developer tool does not have);
`dtrace` (needs root and SIP changes). Not built in round 1: no clean
mechanism is cheap enough to meet a 1000 Hz default without a signed
helper.

## 4. The Gauge trace (`.gaugetrace`)

### 4.1 Format, version 1

One UTF-8 JSON document. Open and versioned (a gzip-compressed file is
refused with a message; compression is a later minor addition): `format` must be `"ycode-gauge-trace"`;
`version` is an integer, readers accept equal or lower versions and refuse
higher major versions with a message. Unknown keys are ignored (later minor
additions). Times are integer nanoseconds since the recording began.

```text
{
  "format": "ycode-gauge-trace", "version": 1,
  "recording": {
    "target": "ycode-simulator" | "linux" | "macos",
    "recorder": "<tool and version>", "host": "<os> <arch>",
    "command": "<what was launched>", "device": "<device type and runtime, simulator only>",
    "startDate": "<ISO 8601>", "durationNs": N,
    "sampleIntervalNs": N, "hangThresholdNs": N,
    "clock": "guest-counter" | "monotonic",
    "notes": ["…"]                       // recorder warnings (samples lost, …)
  },
  "processes": [{"pid": N, "name": "…", "path": "…", "target": true}],
  "threads":   [{"id": N, "pid": N, "name": "…", "main": true, "kind": "main|pthread|workqueue|thread"}],
  "images":    [{"id": N, "name": "…", "path": "…", "uuid": "…",
                 "kind": "app|system|runtime|ycode|kernel|unknown",
                 "base": N, "size": N,
                 "symbols": [[start, end, "name"], …],      // offsets from base, sorted
                 "files": ["…"], "lines": [[offset, fileIndex, line], …]}],
  "frames":    [[imageId, offset], …],      // imageId −1: offset is an absolute address
  "stacks":    [[prefixStackId, frameId], …],// −1: no prefix (outermost frame)
  "samples":   {"time": [N…], "thread": [N…], "stack": [N…], "state": ["user"|"kernel"|"blocked"|"idle"…]},
  "signposts": [{"name": "…", "subsystem": "…", "category": "…", "id": N,
                 "thread": N, "begin": N, "end": N|null,
                 "kind": "interval|event", "message": "…", "flags": ["open"|"unmatched"]}],
  "hangs":     [{"thread": N, "begin": N, "end": N}],
  "presents":  [N, …],
  "gpu":       [{"pid": N, "process": "…", "submit": N, "end": N, "gpuNs": N}]
}
```

- **Stacks** form a prefix tree (each stack = a shorter stack + one frame),
  so a sample stores one integer and shared call chains are stored once.
  Frames of a stack go from outermost (`prefix −1`) to the leaf. A sample
  with no stack has `stack −1`.
- **Frames** are (image, offset). The leaf frame's offset is the sampled
  PC; others are return addresses (an analysis that maps a frame to a line
  uses offset − 1 for non-leaf frames).
- **Symbols** hold only functions a frame falls in: `[start, end, name]`
  (end = start of the next symbol when the symbol table gives no size).
  A frame resolves to the symbol with `start ≤ offset < end`.
- **kind** drives "Hide System Libraries": `system` and `runtime` (the
  simulator runtime's and the OS's libraries), `ycode` (Ycode's host
  libraries and agents) and `kernel` are system; `app` (the app's
  executable and anything inside its bundle or build folder) is not.
- `samples.state` is stored as strings in version 1 for readability; a
  later version may move to integers (version bump).

### 4.2 Symbol tables (`YcodeMachO.SymbolTable`)

From `LC_SYMTAB` (`symoff`, `nsyms`, `stroff`, `strsize`) and `nlist_64`
entries (`n_strx` u32, `n_type` u8, `n_sect` u8, `n_desc` u16, `n_value`
u64): defined section symbols (`n_type & N_TYPE == N_SECT`, no `N_STAB`
bits) in executable sections become functions; sizes come from the next
symbol's start (or the section's end). The table's bytes are found through
`__LINKEDIT`: VM address = `linkedit.vmaddr + symoff − linkedit.fileoff`.
For a file that is the file offset `symoff`; for an image in a shared
cache the VM address is located in the cache's mappings. Leading `_` is
removed from C names. Cache images keep only their non-local symbols, so
a static function is reported under the preceding exported one (a later
round can read the cache's separate local-symbols file, §9).

### 4.3 Source lines

DWARF line programs (`.debug_line`, DWARF 2–5; standard, special and
extended opcodes; DWARF 5 directory and file tables with `DW_FORM_string`,
`line_strp`, `strp`, `udata`, `data1/2/4/8/16`, `block`) from a dSYM
(`<App>.app.dSYM/Contents/Resources/DWARF/<exe>`, matched by UUID) or from
the binary itself (ELF `.debug_line`, Mach-O `__DWARF,__debug_line`). The
rows give address → (file, line); a lookup takes the row with the largest
address ≤ the query within one sequence.

### 4.4 Analysis (`YcodeProfiler`)

Every view is computed from the trace by pure functions (tested with
synthetic traces):

- **Filter**: time range [begin, end), threads (set), states (CPU only by
  default).
- **Call tree**: nodes keyed by function (image + symbol, or image +
  offset when unresolved); each node has *self* (samples whose leaf is this
  node) and *total* (samples through it). Options:
  - **Invert** (bottom-up): paths are read leaf first.
  - **Separate by Thread**: a top level per thread.
  - **Hide System Libraries**: frames of system images are removed, so
    their cost goes to the nearest app caller; a sample with no app frame
    is charged to a node `<system>` (per thread when separated).
  - **Flatten Recursion**: a function that already appears on the path is
    dropped (direct and indirect recursion collapse into the first call).
  - **Charge to Callers**: a set of images or functions removed from every
    path (their cost goes to their callers).
  - **Top Functions** (a flat list): each function's self and total, a
    function counted once per sample in total even if it recurs.
- **Heaviest stack** of a node: from the node, repeatedly the child with
  the most total samples.
- **Flame graph**: the top-down tree laid out as rectangles (depth,
  start, width in samples), children ordered by name so equal trees draw
  equally; the SVG writer draws 16-point rows, names that fit, a tooltip
  (`<title>`) with samples and percentage, and a color per image kind.
- **Source annotation** of a function: per line, *self* (samples whose
  leaf address is in the function, at that line) and *total* (self plus
  samples whose frame in this function is a call at that line).
- **Hangs** (§2.2), **signpost intervals** (§2.3) and their summaries
  (count, total, mean, max per name).

## 5. The IDE: Product ▸ Profile (⌘I)

- **Profile** (⌘I) builds the scheme with its Profile action's
  configuration (`ProfileAction buildConfiguration`, default Release;
  `WorkspaceSession.configuration(for:)`), then launches the product on the
  chosen destination under recording and opens the profiler window when
  recording starts. Product ▸ Perform Action ▸ Profile Without Building
  (⌃⌘I) does the same without building.
- **Destinations**:
  - a **Ycode simulator** row (`run.md` §Remote Ycode simulator): the run's
    remote command plus `--profile '<data>/profiles/<App>-<time>.gaugetrace'`
    and the scheme's `--profile-rate` (Settings ▸ Profiling, below); Stop
    (⌘. or the window's Stop button) stops the run like a Run's Stop; when
    the run ends, the trace is copied back (`rsync` over the same
    BatchMode ssh) to `~/Library/Developer/Ycode/Gauge/` and opened;
  - **My Mac** and Mac simulators: not available in round 1 (the window
    says "Profiling this destination needs the macOS sampler, which is not
    built yet"; §3.3).
- The profiler window's toolbar has Record/Stop, the target ("<App> on
  <device>"), the elapsed time, and the sample rate.
- The run's console still gets the app's output.

## 6. The profiler window

A document window per trace (title: the trace's file name; opening a
`.gaugetrace` from File ▸ Open or the command line opens it). Liquid
Glass as `liquid-glass-ycode.md` §1–§3: unified toolbar, no custom fills.

```text
┌ toolbar: ● Record/■ Stop │ <App> on <device> │ 00:12.4 │ 1 kHz ───────── Inspector ┐
├──────────────────────────────────────────────────────────────────────────────────┤
│ track headers │ timeline: CPU (stacked user/kernel), Signposts, Hangs, Frames, GPU │
│               │ (a drag selects a time range; the range filters every view below) │
├──────────────────────────────────────────────────────────────────────────────────┤
│ [Call Tree | Flame Graph | Source] [options ▾] [thread ▾] [search]  │ inspector:  │
│ Weight   Self  Symbol                                              │ heaviest    │
│ 12.0 ms  …     ▸ main thread                                       │ stack, the  │
│                                                                    │ node's image│
└────────────────────────────────────────────────────────────────────┴─────────────┘
```

- **Timeline**: a ruler (seconds), then one track per probe: *CPU* (a bar
  per pixel column: CPU samples of all threads in that column's time, user
  and kernel in two shades), *Signposts* (one row per name, intervals as
  capsules with the name, events as diamonds; up to six rows: names whose
  subsystem is the target's own (the recorded command, an app's bundle
  identifier) first, then intervals before events, then by count), *Hangs* (red/orange
  bars), *Frames* (a tick per present; long frames marked), *GPU* (bars per
  command buffer). Drag selects a range; double-click clears it. The
  selected call-tree node's samples are highlighted on the CPU track.
- **Call Tree** (`NSOutlineView`): Weight (ms and %), Self Weight, Symbol
  (with the image in secondary text). Options menu: Separate by Thread,
  Invert Call Tree, Hide System Libraries, Flatten Recursion, All States
  (include blocked and idle samples), and Charge to Callers (the selected
  node's image or function). Search filters to nodes whose symbol
  contains the text, with their ancestors. Double-click a node with a
  source line opens Source.
- **Flame Graph**: the call tree's flame graph; click selects (the same
  node in the call tree), hover shows samples and percentage.
- **Source**: the selected function's file with a left column of self and
  total samples per line, hot lines tinted; from the dSYM's lines (§4.3).
- **Inspector**: the heaviest stack of the selection (frames with image),
  and for the selection: samples, weight, self, image path, UUID.

## 7. The command line: `ycode profile`

```text
ycode profile record --linux [--rate HZ] [--seconds S] -o out.gaugetrace -- <command> [args…]
ycode profile record --linux --pid N [--rate HZ] [--seconds S] -o out.gaugetrace
ycode profile record --simd <ycode-simd> -o out.gaugetrace -- <ycode-simd device-mode args…>
ycode profile summary <trace> [--top N]
ycode profile tree <trace> [--invert] [--threads] [--hide-system] [--flatten] [--charge LIB|FUNC]…
                           [--range BEGIN_MS:END_MS] [--all-states] [--depth N] [--min-percent P]
ycode profile flame <trace> -o out.svg [same filters]
ycode profile annotate <trace> <function> [--dsym PATH]
ycode profile symbolicate <trace> [--dsym PATH]… [--binary PATH]… -o out.gaugetrace
```

`record --simd` runs a local `ycode-simd` with `--profile` added (on the
simulator host). `symbolicate` adds names and lines from local dSYMs and
binaries (matched by UUID, else by file name), which is what the IDE does
after copying a trace from the simulator host.

## 8. Allocations and leaks (design for a later round)

- **Allocations** (simulator): the signpost agent grows into Gauge's
  in-app agent and interposes `malloc_zone_*` of the default zone through
  the public malloc zone API (`malloc_default_zone` and the zone's function
  pointers are public in `<malloc/malloc.h>`), recording (time, address,
  size, thread, stack id) into a shared ring the VMM drains; stacks by
  frame-pointer walk in the agent. Tracks: *Allocations* (live bytes over
  time), *Allocation rate*; views: by size and stack, generations (marks).
- **Leaks**: at a mark the VMM pauses the target (every vCPU parked at the
  thread gate), scans the target's writable memory (stacks, data
  segments, registers) conservatively for pointers into live allocations
  from the allocation table, and reports unreachable blocks with their
  allocation stack. No guest code runs during the scan.
- **Linux**: `LD_PRELOAD` of the same agent (ELF), same format.

## 9. Later rounds and open questions

- Allocations and leaks (§8); energy (host power counters per core, not
  meaningful under emulation: needs a model); network (the VMM's socket
  traps already see every connection: a *Network* probe with bytes per
  connection over time); disk I/O (file traps: bytes and latency per path).
- macOS sampler (§3.3); Mac simulator apps through it.
- DWARF unwinding for Linux code without frame pointers
  (`PERF_SAMPLE_STACK_USER`, `.eh_frame` CFI).
- The shared cache's local symbols (the cache's `.symbols` file, whose
  layout is in Apple's open-source dyld, `dyld_cache_format.h`).
- Decoding signpost message arguments (the `os_log` argument buffer is not
  publicly documented; a dirty-room spec would be needed).
- **OPEN QUESTION (dirty room):** importing the reference IDE's trace
  documents (`.trace` bundles) into Gauge: their on-disk structure (bundle
  layout, the run and track stores, sample and symbol tables) is not
  publicly documented. A dirty-room spec of the bundle format would let
  `ycode profile import <x.trace>` convert one to a Gauge trace. Gauge
  needs no reference behavior otherwise.
- **OPEN QUESTION:** the reference's default hang threshold and its
  definition of a hang on the main thread (Gauge uses 250 ms and §2.2).
- **OPEN QUESTION:** how the reference names and lays out the Profile
  action's "Instrument" choice in the scheme editor's Profile ▸ Info tab
  (`schemes.md`); Gauge keeps one recording template (all probes) in round
  1, so the pop-up shows "Gauge (Time Sampler, Signposts, Hangs, Frames, GPU)".

## 10. Implementation (round 1)

### 10.1 Where the parts are

| Part | Code |
|---|---|
| Trace model, JSON codec, builder | `YcodeProfiler/Trace.swift`, `TraceCodec.swift` |
| Call tree, top functions, flame graph (+ SVG), source annotation, hangs, signpost matching, text reports | `CallTree.swift`, `FlameGraph.swift`, `SourceAnnotation.swift`, `Timeline.swift`, `Report.swift` |
| Mach-O symbol tables (files and cache images) | `YcodeMachO/SymbolTable.swift` (`MachOImage.symtab`, `functionStarts`) |
| DWARF line programs, ELF files, `/proc` maps, UUID matching, `swift-demangle` | `DWARFLines.swift`, `ELFFile.swift`, `Symbolicate.swift` |
| Linux recording (perf, agent) | `LinuxRecorder.swift`, C targets `CYcodeGauge` (spawn held, perf ring) and `CYcodeGaugeAgent` (`libYcodeGaugeAgent.so`) |
| Command line | `YcodeProfiler/CLI.swift` (`GaugeCLI`), `ycode profile` |
| Simulator recorder | `ycode-simd/GaugeRecorder.swift`; `VCPUPool.activeWorkers()`/`kickForSample(_:)`; options in `main.swift`; staging and environment in `SettingsAgentStaging.swift`/`ExecHost.swift`; the trace is written before a stop's save (`SnapshotSupport`) and at the run's end |
| In-app signpost agent | `SimGuestAgents/gauge/YcodeGauge.c` → `libYcodeGauge.dylib` (`SimGuestAgents/build.sh`; copy it into the host's guest tools next to `ylaunch`) |
| Launcher | `scripts/ycode-sim.sh`: `--profile*` are app options |
| IDE | `YcodeUI/Gauge/` (`GaugeModel`, `GaugeTimelineView`, `GaugeFlameView`, `GaugeWindowController`); `profileProduct:`, `profileProductEditingScheme:`, `profileWithoutBuilding:` (`WorkspaceWindowController+Product.swift`); `RemoteProfile` and the trace copy in `RemoteRun.swift`; `GaugeSettings` (`Ycode.gauge.sampleRate`) |
| Samples | `Tools/gauge-samples/HotLoop` (SwiftPM, Linux), `Tools/gauge-samples/GaugeDemo` (UIKit app: `Work.c` deliberate work with signposts) |

Settings ▸ Profiling (§5) is not a pane yet: the rate is the user default
`Ycode.gauge.sampleRate` (1000 when unset).

### 10.2 Measurements (2026-10-29; shared hosts, load averages noted)

**Linux, ground truth from the program.** `HotLoop` times its own parts.
x86-64 host (Ubuntu, `perf_event_paranoid` 4, so the agent): the profile
gives `collatzSteps` 85.2 % of the main thread against 85.1 % measured.
arm64 host (`perf_event_paranoid` 2): perf 84.7 % against 84.7 %.

**Linux cost** (HotLoop rounds in 3 s, 5 pairs each, single thread):

| Host, back end | Unprofiled | Profiled | Slowdown | Per sample (derived) |
|---|---|---|---|---|
| x86-64, agent (1000 Hz) | 1268.6 | 1258.2 | 0.8 % | ≈ 8 µs |
| arm64, perf (1000 Hz) | 972.6 | 970.0 | 0.3 % | ≈ 3 µs |
| arm64, agent (1000 Hz) | 972.6 | 967.2 | 0.6 % | ≈ 6 µs |

**Simulator** (GaugeDemo on the iPhone 18 Pro, iOS 27.0; 1000 Hz; every
thread of the app; 25–40 s per run):

- A 25 s recording: 95,465 samples over 9 threads, 172 signposts (the
  app's Crunch/Sieve/Matrix/Background/Tick and UIKit's own), 102 presents,
  681 GPU command buffers; 3.1 MB trace, written in about 1 s.
- Call tree after symbolication with the build's dSYM: `start_sim` →
  `main` → `UIApplicationMain` → … → `__NSFireTimer` →
  `-[GaugeDemoController tick:]` → `gauge_demo_round` → `sieve_primes`
  (47.8 % of the main thread's CPU; the deliberate work), `multiply_matrices`
  next among the app's functions.
- Recorder cost: the sampler thread 18–91 µs per sample (higher with host
  load, which delays the kicked vCPUs' answers; 0.1–0.2 % of kicks did not
  answer within 3 ms and were dropped); on the profiled app's side,
  33 µs of the vCPU's own thread per sample of a running thread (register
  reads and the frame-pointer walk, stack read in 4 KiB blocks) plus one
  VM exit, about 3–4 % of a running thread's time at 1000 Hz.
- App slowdown, round times of GaugeDemo's main-thread work (ms), paired
  cold-boot runs on the shared host: fastest round +6 % (26.1 against
  24.6), first quartile +18 % (40.2 against 34.0); medians move by more than
  the effect between runs (host load 17–43), so they do not measure it.

**Round 1, second pass (2026-10-30, after the main line's 512 vCPU slots).**

- **From the IDE**: Product ▸ Profile on GaugeDemo (`ProfileEndToEndTests`,
  which drives `profileScheme(building:)` of a workspace window: build with
  the Profile configuration, upload, the warm-boot launcher with
  `--profile`, Stop from the profiler window, `rsync` back, symbolication
  with the build's dSYM). Cold boot: launched 148 s after Profile; warm
  boot: 14 s. A 26 s warm recording: 98,287 samples, 11 threads, 135
  signposts, 108 presents; the call tree's hot path is `main` →
  `UIApplicationMain` → … → `-[GaugeDemoController tick:]` →
  `gauge_demo_round` → `sieve_primes` (28 % of the app's CPU, the top
  function by self time), `multiply_matrices` beside it; Crunch, Sieve,
  Matrix, Background and Tick are the timeline's first signpost rows. On a
  cold boot the same work is 10× slower (Crunch mean 249 ms against 24 ms):
  the first rounds fault in the sieve's pages.
- **Fixed by that run**: an iOS product's executable is `<App>.app/<exe>`
  (the run took the executable for the bundle); a remote run that ended
  before the simulator started left the window recording forever; hangs
  ended at any sample gap over 4 ms (now §2.2's rule: the cold run's 948 ms
  round was no hang before, and its trace has 12 hangs after); the timeline
  drew 14 of 28 s.
- **Recorder cost** (three 40 s warm recordings at 1000 Hz, host load
  6–33): the sampler thread 6.7–14.7 µs per sample (24–61 µs per tick of
  all threads); on the profiled side 22.6–25.6 µs of the vCPU's own thread
  per kicked sample, so about 2.3–2.6 % of a running thread's time at 1000
  Hz plus one VM exit per sample.
- **App slowdown** (three alternating pairs of warm-boot runs, 40 s of app
  each, rounds 3 onward, 75 and 76 rounds): fastest round +4 % (23.6
  against 22.6 ms), first quartile +5 % (25.7 against 24.4 ms); medians
  (25.6–35.2 ms in both groups) follow the host's load more than the
  recorder.
- **Linux, x86-64** (agent back end, `perf_event_paranoid` 4; HotLoop 3 s,
  five pairs, release builds): 1268.6 against 1259.8 rounds, 0.7 % slower,
  ≈ 7 µs per sample; `collatzSteps` 83.8–84.5 % of the main thread against
  85.1 % measured by the program.

## Evidence

| Claim | Level | Source |
|---|---|---|
| `_os_signpost_emit_with_name_impl`, `os_signpost_enabled`, `os_log_create` signatures; signpost types 0/1/2 | 1 | iOS simulator SDK public headers `os/signpost.h`, `os/log.h` |
| Interposing through dyld's `__DATA,__interpose` section | 1 | Apple open-source dyld (`dyld-interposing.h`) |
| `nlist_64`, `LC_SYMTAB` layout | 1 | SDK `mach-o/nlist.h`, `mach-o/loader.h`; `specs/formats/macho-and-dyld-cache.md` |
| Linkedit address of `symoff` | 1 | Apple open-source dyld (`MachOLoaded::getLinkEditPointers`) |
| `perf_event_open` attributes, ring buffer, record types, call-chain markers | 1 | Linux man page `perf_event_open(2)`, uapi `linux/perf_event.h` |
| ELF symbol tables and program headers | 1 | System V ABI / ELF specification |
| DWARF line programs | 1 | DWARF Debugging Information Format, version 5 (and 4 for older tables) |
| Guest kick, frame-pointer reads, trap-entry registers | 3 | Ycode's own VMM (`boot-profile.md` §1.3, §5.1; `VCPUPool`, `ThreadContext`) |
| Presents, Metal trace fields | 3 | `frame-profile.md` §1, `stage8-contract.md` §14.1 |
| debugserver and the GDB remote protocol packets | 1 | LLVM/LLDB open source (`docs/lldb-gdb-remote.txt`) |
| What a sampling profiler shows (call tree, inverted tree, flame graph, source annotation, hangs) | 1 | public profiler documentation; Ycode's own design |
