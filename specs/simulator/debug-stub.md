# Spec: the debug stub (LLDB on apps in Ycode's simulator)

Status: **implemented** (agent SIM-DEBUG, 2026-10-30; SIM-DEBUG2,
2026-10-31: OS version and LLDB's newer image loader, image notifications,
launch-stopped attach, hardware watchpoints, Swift expressions). Closes gap
#3 of `docs/PARITY.md`: "no debugger attaches to apps running on Ycode's
simulator". Results are in §10.

This is Ycode's own design. The protocol is GDB's remote serial protocol
with LLDB's extensions, both publicly documented (§Evidence, level 1). The
Arm facts (BRK, software step, MDSCR_EL1, SPSR.SS, exception classes) come
from the public Arm Architecture Reference Manual. No Apple component is
involved: the debugger is the user's own `lldb` (or `lldb-dap`), which
speaks the documented protocol to a stub inside `ycode-simd`.

## 1. What it does

A **gdb-remote stub inside `ycode-simd`** serves one guest process at a time
to LLDB:

- attach to a running process by pid or name, or wait for the next launch
  of a name (held at its first instruction, §7); `--debug-launch-stopped`
  holds the launched app there until a debugger attaches;
- read and write the arm64 general-purpose registers of every thread;
- read and write guest memory, including read-only code;
- software breakpoints (`brk` instructions written into guest memory);
- hardware watchpoints (the vCPUs' DBGWVR/DBGWCR registers, §6.2);
- single step one instruction (the vCPU's software-step debug feature);
- all-stop execution control: continue, step, interrupt, detach, kill;
- stop reasons (breakpoint, trace, faults as Darwin signals);
- the thread list and LLDB's extensions LLDB needs to find the images:
  `qHostInfo` and `qProcessInfo` with the runtime's OS version,
  `jThreadsInfo`, `jGetLoadedDynamicLibrariesInfos` (each image's Mach-O
  header, segments and UUID), `jGetDyldProcessState`,
  `jGetSharedCacheInfo`, `qShlibInfoAddr` (the process's
  `dyld_all_image_infos`, which `dyld_sim` keeps);
- images loaded after the attach (`dlopen`): the image list's
  notification function, where LLDB keeps its breakpoint, is called on
  every change (§4.4).

The stub's socket is forwarded to the Mac over ssh, as the display and
pairing sockets are; the Mac's `lldb` connects with `gdb-remote`, and the
IDE's lldb-dap connects with its `gdb-remote-port` attach argument (§8).

## 2. Components

| Part | Where | Platform |
|---|---|---|
| Protocol: framing, hex, register layout, breakpoint table, the server | `ycode/Sources/YcodeDebug/GDBRemote/` | portable (macOS, Linux) |
| Images: Mach-O headers read from memory, the `jGetLoadedDynamicLibrariesInfos` request and reply, dyld's states | `GDBRemoteImages.swift` | portable |
| Host and process protocols the server drives | `GDBRemoteTarget.swift` (`GDBRemoteHost`, `GDBRemoteProcess`) | portable |
| Sockets (Unix path or loopback TCP listener) | `GDBRemoteSocket.swift` | portable |
| The simulator side: images, threads, registers, memory | `ycode/Sources/ycode-simd/DebugStub.swift` | arm64 Linux |
| Kernel hooks: debug exceptions, thread holds, watchpoint stops, the image-list notification (§4.4) | `ycode/Sources/YcodeDarwinKernel/DebugHooks.swift` | portable |
| Spawn holds (vAttachWait, `--debug-launch-stopped`) | `ycode-simd/ImageLauncher.swift` (`register`) → `SimDebugServer.imageWillStart` | arm64 Linux |
| Run-gate requests: step, flush | `ycode/Sources/YcodeDarwinABI/ThreadGate.swift` | portable |
| vCPU single step (MDSCR_EL1.SS, SPSR.SS), watchpoint registers (DBGWVR/DBGWCR, MDSCR_EL1.MDE) | `ycode/Sources/YcodeHypervisor/VCPUPool.swift` | arm64 Linux |
| IDE: run with the debugger on the Ycode simulator | `YcodeIDECore/Session/RemoteRun.swift` (`attachToRemoteSimulatorApp`), `YcodeDebug/DAPDepth.swift` (`attachRemote`) | macOS |
| Launcher: `--debug-server` is an app option | `ycode/scripts/ycode-sim.sh` | host |
| Sample app | `ycode/Tools/debug-samples/DebugDemo` | built on macOS |

## 3. Transport and framing

`ycode-simd --debug-server <address>`; `<address>` is `unix:<path>`,
`<host>:<port>` or `<port>` (loopback). One client at a time; a new client
is accepted when the previous one disconnects. `--debug-server-log` prints
every packet (`ycode-simd: debug: <- …` / `-> …`) to stderr.

- A packet is `$<body>#<cc>`; `cc` is the sum of the body bytes modulo 256,
  two lowercase hex digits. Inside a body `}` escapes the next byte (XOR
  0x20). Replies escape `$`, `#`, `}` and `*` (binary `x` replies, JSON).
- Until `QStartNoAckMode`, each good packet is answered `+` and a bad
  checksum `-`; the `OK` reply to `QStartNoAckMode` is still acknowledged.
- A lone 0x03 byte between packets is an interrupt.
- Error replies are `E<nn>`; after `QEnableErrorStrings`, `E<nn>;<hex text>`.
- A packet the stub does not know gets the empty reply (GDB's rule for
  unsupported packets).
- LLDB sends some JSON packets (`jGetSharedCacheInfo:{}`) with the closing
  `}` unescaped, right before `#`. `}#` ends the packet when the two bytes
  after `#` are the checksum of the body through the brace; otherwise
  `}#` is the escaped byte 0x03, as the protocol defines it.
- The process is attached at the **first packet** of a connection, not at
  the connection itself, so a port probe stops nothing.

## 4. Packets

### 4.1 Supported

| Packet | Reply |
|---|---|
| `qSupported:…` | `PacketSize=20000;QStartNoAckMode+;QThreadSuffixSupported+;QListThreadsInStopReply+;qEcho+;vContSupported+;qXfer:features:read-;multiprocess-` |
| `QStartNoAckMode`, `QThreadSuffixSupported`, `QListThreadsInStopReply`, `QEnableErrorStrings`, `qVAttachOrWaitSupported`, `QSetDetachOnError:…`, `QSetDisableASLR:…`, `QSetIgnoredExceptions…` | `OK` |
| `qHostInfo` | `cputype:16777228;cpusubtype:0;ostype:<os>;vendor:apple;endian:little;ptrsize:8;vm-page-size:16384;os_version:<v>;os_build:<hex>;watchpoint_exceptions_received:before;hostname:<hex>;default_packet_timeout:20;` — `<os>` is `ios`, `watchos` or `xros` from the device type (the device OS, not its simulator: §4.3); `<v>` and the build are the runtime's `ProductVersion` and `ProductBuildVersion` (`System/Library/CoreServices/SystemVersion.plist` under the runtime root) |
| `qGDBServerVersion` | `name:ycode-simd;version:1;` |
| `qProcessInfo` | `pid:<hex>;parent-pid;real-uid:1f5;real-gid:14;effective-uid;effective-gid;cputype:100000c;cpusubtype:0;ostype;vendor:apple;endian:little;ptrsize:8;os_version:<v>;` (numbers in hex; uid 501 and gid 20, the simulator's mobile user as Ycode runs it; LLDB ignores `os_version` here and takes it from `qHostInfo`) |
| `qfProcessInfo`, `qsProcessInfo`, `qProcessInfoPID:<pid>` | the guest processes: `pid:<hex>;name:<hex>;` one per reply, then `E03` |
| `qC` | `QC<tid>`: the thread of the last stop; `QC0` with no process (LLDB: connected, no process) |
| `qAttached` | `1` |
| `?` | the stop reply of the last stop's thread; the exit reply after the process ended; `E02` before any attach (as debugserver; a `W` reply there made LLDB take the connection as an exited process) |
| `qfThreadInfo` / `qsThreadInfo` | `m<tid>,<tid>…` (main thread first) / `l` |
| `qThreadStopInfo<tid>` | that thread's stop reply (§6) |
| `jThreadsInfo` | JSON array: `tid`, `qaddr`, `signal`, `reason`, `description`, `registers` (decimal register number → hex bytes of fp, lr, sp, pc, cpsr) |
| `qThreadExtraInfo,<tid>` | hex of the thread's name (none today) |
| `T<tid>` | `OK` when alive |
| `qRegisterInfo<n>` | the register's description (§4.2); `E45` past the last |
| `g`, `G<hex>`, `p<n>`, `P<n>=<hex>` (each with an optional `;thread:<tid>;` suffix) | register reads and writes (§4.2) |
| `Hg<tid>`, `Hc<tid>` | the thread for register packets and for `c`/`s` without `vCont` |
| `QSaveRegisterState[;thread:]` / `QRestoreRegisterState:<id>[;thread:]` | a save id; `OK` |
| `m<addr>,<len>` / `x<addr>,<len>` | memory as hex / binary; a read stops at the first unreadable page (a shorter reply), `E0e` when nothing is readable. Breakpoints read as the bytes they replaced |
| `M<addr>,<len>:<hex>` / `X<addr>,<len>:<binary>` | `OK`; bytes under a breakpoint update its saved bytes and the breakpoint stays |
| `Z0,<addr>,4` / `z0,<addr>,4` | software breakpoint insert / remove (§5) |
| `qMemoryRegionInfo:<addr>` | `start;size;permissions:rwx;name:<hex path>;` for a mapping; for a hole, `start;size;` up to the next mapping (no permissions = unmapped) |
| `qShlibInfoAddr` | the address of the process's `dyld_all_image_infos` (§4.3) |
| `qWatchpointSupportInfo:` | `num:<n>;`: the vCPUs' watchpoint registers (ID_AA64DFR0_EL1.WRPs + 1; 4 on the Linux host), at most 16 |
| `Z2`/`Z3`/`Z4,<addr>,<size>` / `z2`…`z4` | `OK`: a write / read / access watchpoint (§6.2); `E16` for a range the registers cannot hold, `E1c` when every register is in use |
| `_M<size>,<perms>` / `_m<addr>` | memory for the debugger's own code and data (expression evaluation, LLDB's Objective-C runtime helpers): an anonymous mapping of the image with those permissions (`rwx` allowed: SCTLR_EL1.WXN is 0), its address in hex / `OK`. Without `_M`, LLDB calls `mmap` in the process, and LLDB 2103 then recursed until its stack overflowed (its ObjC runtime asks for memory while unwinding for that call) |
| `jGetSharedCacheInfo:{}` | `{"shared_cache_base_address":N,"shared_cache_uuid":"…","no_shared_cache":false,"shared_cache_private_cache":false}` from the image list's sharedCacheUUID (160) and sharedCacheBaseAddress (176) |
| `jGetSharedCacheInfo:`, `jGetLoadedDynamicLibrariesInfos:` (no argument) | `OK`: LLDB's support probes (it uses the packets only after an `OK`) |
| `jGetLoadedDynamicLibrariesInfos:<json>` | `{"images":[…]}` (§4.3): `{"fetch_all_solibs":true}` every image of dyld's list, `{"solib_addresses":[…]}` the images at those addresses, `{"image_count","image_list_address"}` the `dyld_image_info` entries at that address; `"information-level"` (`address-only`, `address-name`, `address-name-uuid`, `full`) or `"report_load_commands":false` limit each entry |
| `jGetDyldProcessState` | `{"process_state_value":N,"process_state string":"dyld_process_state_…"}` (§4.3) |
| `qSymbol::` | `OK` (no symbol lookups) |
| `qEcho:<text>` | `<text>` |
| `vCont?` | `vCont;c;C;s;S` |
| `vCont;<action>[:<tid>]…`, `c[addr]`, `C<sig>[;addr]`, `s[addr]`, `S<sig>[;addr]` | no immediate reply; the stop reply comes when the process stops again (§6) |
| `vAttach;<pid>`, `vAttachName;<hex>`, `vAttachWait;<hex>`, `vAttachOrWait;<hex>` | the stop reply after the attach (SIGSTOP) |
| `D`, `D;<pid>` | `OK`: breakpoints removed, every thread runs on |
| `k`, `vKill` | `X09`: the process is ended with SIGKILL |

### 4.2 Registers

Ycode's order, learned by LLDB from `qRegisterInfo` (no target XML):

| Number | Name | Size | DWARF | Generic |
|---|---|---|---|---|
| 0–28 | x0–x28 | 8 | 0–28 | x0–x7: arg1–arg8 |
| 29 | fp (alt x29) | 8 | 29 | fp |
| 30 | lr (alt x30) | 8 | 30 | ra |
| 31 | sp (alt x31) | 8 | 31 | sp |
| 32 | pc | 8 | 32 | pc |
| 33 | cpsr | 4 | — | flags |
| 34–65 | v0–v31 (only when the target offers them) | 16 | 64–95 | — |
| 66, 67 | fpsr, fpcr (same) | 4 | — | — |

The `g` block is the registers in number order, little-endian, no padding
(268 bytes without FP/SIMD, 788 with). x0–x30, sp and pc are the thread's
user registers where it stopped; cpsr is NZCV of SPSR (mode bits read as
EL0t, the step bit clear). v0–v31, fpsr and fpcr are read from the thread's
vCPU (`KVM_GET_ONE_REG`, as the snapshot reads them): the shim saves no
FP/SIMD state, and a stopped thread's vCPU is never in `KVM_RUN` (parked at
its gate or inside a kernel call); a thread not on a vCPU (never started)
reads them as zeros.
A register write changes the stopped thread's registers in place (x0–x30,
sp, pc, NZCV, and the FP/SIMD registers on its vCPU); for a thread stopped
inside a kernel call the new registers
apply when the call returns, with the call's results in x0, x1 and the carry
(`threads-and-events.md` §1.6 `thread_set_state`).

Stop replies expedite fp, lr, sp, pc and cpsr.

### 4.3 Images, the OS version and the OS type

LLDB has two ways to learn a Darwin process's images: asking the stub
(`jGetLoadedDynamicLibrariesInfos`, the "new" loader plug-in
`DynamicLoaderMacOS`, chosen when `qHostInfo` reports an OS version at or
above iOS 10) or reading `dyld_all_image_infos` from memory (the "old"
plug-in, chosen without an OS version; `DynamicLoaderDarwin::UseDYLDSPI`
in LLDB's open source). The stub reports the runtime's OS version, so
LLDB uses the new plug-in. (SIM-DEBUG reported none and LLDB used the old
one; Swift expressions then failed, below.)

**The image list.** `jGetLoadedDynamicLibrariesInfos` reads the list
`dyld_sim` keeps in the host page (`dyld-sim-handoff.md` §4.5):
`infoArrayCount` (+4) entries of `dyld_image_info` {load address, path
pointer, mod date} at `infoArray` (+8), plus `dyld_sim` itself
(`dyldImageLoadAddress`, +32, its path from its mapping) when the list
lacks it. While `dyld_sim` updates the list `infoArray` is NULL; the reply
then holds `dyld_sim` alone. For each image the stub reads the Mach-O
header and load commands from guest memory (64-bit images; an image whose
header cannot be read is left out, as debugserver does) and reports, in
LLDB's names: `load_address`, `pathname`, `uuid` (`LC_UUID`), `mod_date`
0, `min_version_os_name` / `min_version_os_sdk` (`LC_BUILD_VERSION`, else
an `LC_VERSION_MIN_*`; platform 7 is `iossimulator`, 9
`watchossimulator`, 12 `xrsimulator`), `mach_header` (`magic`, `cputype`,
`cpusubtype` without the capability byte, `filetype`, `flags`,
`sizeof_mh_and_loadcmds`) and `segments` (`name`, `vmaddr`, `vmsize`,
`fileoff`, `filesize`, `maxprot`, as the load commands state them; LLDB
computes the slide from `__TEXT`). LLDB 2103 asks once for every image in
full (about 500 images, 440 KB, 20 ms in the stub), then for new images by
address after each notification (§4.4).

**`dyld_sim` is not LLDB's dyld.** In a simulator process LLDB keeps the
host's macOS dyld as "the dyld" and skips an `MH_DYLINKER` whose OS is not
macOS (`UpdateSpecialBinariesFromPreloadedModules`). Ycode has no host
dyld, so LLDB has no dyld module: it does not look for its
`lldb_image_notifier` by name and puts its notification breakpoint on the
image list's `notification` function instead (§4.4).

**dyld's state** (`jGetDyldProcessState`, libdyld's numbering): `0x50`
program running once `dyld_sim` called its "main called" helper (slot 54,
the kernel records it); else `0x30` libSystem initialized when the image
list's `libSystemInitialized` (+25) is set; else `0x10` dyld initialized
when the list holds more than the main executable; else `0x00` not
started (an image held at its first instruction, §7). LLDB runs no utility
functions (its Objective-C class scans) before libSystem is initialized
(`DynamicLoaderMacOS::IsFullyInitialized`).

**The OS type: the device OS.** For a process whose platform is a
simulator one (`ios-simulator`, …) LLDB takes the OS version not from the
stub but from the local Mac process of the same pid (its
`SIMULATOR_RUNTIME_VERSION` environment variable, or `DYLD_ROOT_PATH`'s
SystemVersion.plist: `PlatformDarwin::GetOSVersion` in LLDB's open
source), which a process on a remote simulator has not got. Swift
expressions then begin `@available(iOS 0, *)`, which the Swift compiler
rejects ("expected version number"; `SwiftExpressionSourceCode.cpp` writes
the platform's version into the wrapper). **Ycode decision:** `qHostInfo`
and `qProcessInfo` report the device OS (`ostype:ios`, `watchos`, `xros`).
LLDB's target then is `arm64-apple-ios` on its `remote-ios` platform, even
after `target create` of the simulator build (the executable's arch is
adopted from the process), and the OS version for Swift expressions is the
stub's `os_version`. What changes for the user: LLDB looks for the system
images in its iOS device-support folders, finds none, and reads them from
the process's memory, as it did before; the images keep their
`iossimulator` platform. `YCODE_DEBUG_OSTYPE=iossimulator` (diagnostics)
restores the simulator OS type.

**The image list's own address.** LLDB compares the struct's
`dyldAllImageInfosAddress` field (offset 104) with the address
`qShlibInfoAddr` gave; a difference means "dyld was slid" to the old
plug-in, and "dyld has not started" to the new one (it then sets no
notification breakpoint). Ycode's host leaves the field 0
(`stage3-contract.md` §6), so the stub shows it as dyld fills it: a read
that covers it returns the struct's address when the guest's value is 0.
Guest memory is not changed.

**Paths.** The image paths are the guest's (the runtime root's host paths
with `--runtime-paths`, the app's container path). LLDB finds the Mac's
build of the app and of its dylibs by file name in
`target.exec-search-paths` (UUIDs are checked); the system images are read
from the process's memory ("… is being read from process memory";
symbols come from their `__LINKEDIT` in the shared cache mapping).

### 4.4 Images loaded after the attach

`dyld_sim` with helpers version ≥ 18 does not call the image list's
`notification` function; it reports every image-list change to the host
through helper slot 55, `notifyMonitorOfImageListChanges(unloading, count,
mach_header* addrs[], char* paths[])` (`dyld-sim-handoff.md` §3, §6.2), a
Ycode-private trap. A host dyld would then call the debugger's notifier.
**Ycode decision:** while a debugger is attached, the kernel's slot-55
trap returns into the `notification` function (`dyld_all_image_infos`
+16, the host page's `ret` stub) as the call `notification(mode, count,
dyld_image_info info[count])` (`mach-o/dyld_images.h`: mode 0 adding, 1
removing), with the caller's return address left in x30, so the stub
returns straight to `dyld_sim`. The array (24-byte entries, mod date 0) is
written below the thread's 128-byte red zone, 16-byte aligned. LLDB's
breakpoint on that address (both loader plug-ins put one there) sees x0–x2,
reads the load addresses, asks the stub for those images and continues.
Without a debugger the trap just returns, as before.

## 5. Breakpoints and memory

- A breakpoint is `brk #0xf000` (`0xD43E0000`, the encoding LLDB uses on
  arm64) written over a 4-byte-aligned instruction; the table keeps the
  bytes it replaced. Insert of an existing one and remove of a missing one
  succeed.
- Writes go through `GuestAddressSpace.write` without EL0 checks. A page of
  a read-only file view (code shared by every process that maps the file)
  is first moved to a private copy for this process (the address space's
  existing privatization), so a breakpoint never changes another process
  or the file.
- A write may move a page, so the guest's TLB must be flushed before the
  process runs again: after any write the next resume asks every thread's
  gate for a flush, which the vCPU applies at its next return through the
  shim (resume flags bit 0, with the I-cache when the host lacks
  CTR_EL0.DIC; `guest-cpu.md` §4.2). The flush instruction is
  inner-shareable, so the first thread that returns flushes every vCPU of
  the process. A thread stopped while running EL0 code (kicked out of the
  guest, `afterTrap` not involved) re-enters without the shim; it runs with
  the old translation until any thread of the process passes the shim
  (microseconds to milliseconds in an app).
- A `brk #0xf000` that traps at an address with no breakpoint and no
  longer a `brk` in memory (the client removed it while the thread was on
  its way into its trap) is run again (`.retry`), as debuggers do.

## 6. Execution control

**All-stop.** When one thread stops, every thread of the process stops.
The kernel keeps a **debugger hold** per thread (`ThreadContext.debugHold`)
that closes the thread's run gate exactly like a suspend count
(`threads-and-events.md` §1.6), but apart from the counts the program
changes with `thread_suspend`/`task_suspend`. A thread made during a debug
stop starts held.

**A stop.** A non-SVC exception of a thread of an attached process goes to
the kernel's debug hook (`DarwinKernel.debugException`) before the fatal
path. The hook classifies it (`KernelDebugStop`), the stub decides
(`stop`, `retry`, `decline`); on `stop` the kernel records the thread's
stop, holds every thread (closing gates kicks their vCPUs) and resumes the
trap: the thread parks at its gate right after it (`afterTrap`), with ELR
at the `brk` (or after the stepped instruction). The stub's waiter waits
until every held thread is stopped (parked, inside a kernel call, or not on
a vCPU) and the reporting threads are parked, kicking vCPUs every
millisecond, then sends the stop reply.

**Resume.** `vCont` actions map to a per-thread action: `c`/`C` → run,
`s`/`S` → step, none (or `t`) → stay held; an action without a thread
applies to every thread not named. Plain `c` continues every thread, plain
`s` steps the `Hc` thread (or the last stop's) and keeps the others held.
The process's stop reasons are cleared.

**Single step** uses the Arm software-step feature: the stub sets the
thread's gate step request; when the vCPU next enters the guest it sets
MDSCR_EL1.SS (KVM `ONE_REG`, op0 2 op1 0 CRn 0 CRm 2 op2 2) and SPSR.SS
(bit 21) in the frame the shim returns with (or PSTATE.SS for a thread
stopped at EL0). The PE runs one EL0 instruction and takes a
software-step exception (EC 0x32) to the shim; the vCPU clears MDSCR_EL1.SS
at once and the kernel reports a `trace` stop. Debug exceptions are not
enabled at EL1 (MDSCR_EL1.KDE = 0), so the shim itself is never stepped.
An instruction that traps (an SVC) completes first; the step exception is
taken on its return. A fault the kernel resolves (a lazy page) re-runs the
instruction with the step still armed. A resume without a step clears any
step state left on the vCPU, as does the vCPU's next thread.

A step of a thread that has **not run yet** (made during a stop, parked
before its first instruction on a fresh vCPU) starts with the shim's boot
path, whose `eret` leaves PSTATE.SS clear: with MDSCR_EL1.SS set the PE
then takes a software-step exception before that first instruction
(the "active-pending" step state). The vCPU takes that first exception
only to arm the step (it sets SPSR.SS and returns at once, reporting
nothing), and the instruction is stepped as any other. A reused vCPU's new
thread gets its step from the slot's frame at its first entry.

**A stepped thread at a breakpoint.** When a thread the client stepped
stops on a `brk` the client inserted, the instruction there has not run:
the stop is reported as `trace`, not `breakpoint`. LLDB steps the threads
that sit on its breakpoint sites one by one before it continues (its
"step over breakpoint" plans); with a `breakpoint` reason for a thread
that stepped from one site onto the next (a new workqueue thread stepped
from `start_wqthread` onto LLDB's thread-start breakpoint) its plans ended
in a stop shown to the user, "stop reason = trace", on every new thread.
The stub logs such a step ("thread N stepped from … to the breakpoint at
…") when the stop is not the next instruction.

**The thread list** is the one of the last stop: the kernel may make a
workqueue thread while the process is stopped (it starts held), and the
client sees it at the next stop. (Before this, lldb-dap now and then moved
its stop to such a new thread, at its first instruction.)

**Interrupt** (0x03): every thread is held; the stop reply names the main
thread with SIGSTOP (17) and no reason.

**Signals on resume.** `C<sig>` for a thread whose stop was a fault with
that signal lets the fault take its normal course (the process ends with
the signal, `processes.md` §2.3.1); any other signal is dropped (Ycode
delivers no signals to handlers, `stage4b-contract.md` §2).

**End.** When the process exits during a run the reply is `W<status>`;
when a signal ends it, `X<signal>`. A client that disconnects without `D`
is detached as by `D` (breakpoints removed, the process runs on).

### 6.1 Stop reasons

| Exception (ESR_EL1.EC) | Signal | `reason` | `description` |
|---|---|---|---|
| BRK (0x3C) at a debugger breakpoint | 5 (SIGTRAP) | `breakpoint` | — |
| BRK elsewhere (`brk #1` of Swift traps, `__builtin_trap`) | 5 | `exception` | `EXC_BREAKPOINT (brk #<imm>)` |
| Software step (0x32), or a stepped thread's BRK at a debugger breakpoint | 5 | `trace` | — |
| Watchpoint (0x34) | 5 | `watchpoint` | "`<address in the watched range>` `<register>` `<FAR>`" in decimal (§6.2) |
| Data or instruction abort | 11 (SIGSEGV) or 10 (SIGBUS) by fault status | `exception` | `SIGSEGV: data abort from a lower EL at address 0x…` |
| Undefined instruction, trapped instructions | 4 (SIGILL) | `exception` | text |
| Floating-point trap | 8 (SIGFPE) | `exception` | text |
| PC/SP alignment | 10 (SIGBUS) | `exception` | text |
| Interrupt, attach | 17 (SIGSTOP) | none | — |
| Other threads of the stop | 0 | none | — |

The signal mapping is the one the kernel uses for a fatal exception
(`processes.md` §2.3.1, `DarwinKernel.faultSignal`). The stop reply also
carries `threads:`, `thread-pcs:`, `hexname:` when the thread has a name,
and `qaddr:` (the thread's libdispatch queue slot, the address
`THREAD_IDENTIFIER_INFO` reports), from which LLDB reads the queue name.

### 6.2 Hardware watchpoints

Each vCPU has the Arm debug architecture's watchpoint registers (KVM lets
the guest own them; `KVM_SET_ONE_REG`). The stub keeps the client's
watchpoints per process and the process's vCPU pool loads them into every
vCPU before its next guest entry (a generation number the run loop
compares, one relaxed load per entry):

- **DBGWVRn_EL1** (op0 2, op1 0, CRn 0, CRm n, op2 6): the address — the
  doubleword for a byte-select watchpoint, the base for a mask one.
- **DBGWCRn_EL1** (op2 7): E (bit 0) 1; PAC (2:1) 0b10, EL0 accesses only;
  LSC (4:3) 1 load, 2 store, 3 both (`Z3`, `Z2`, `Z4`); BAS (12:5) the bytes
  of the doubleword for a range within one doubleword; for an aligned power
  of two of 8 bytes or more, BAS 0xFF and MASK (28:24) its log2. Other
  ranges are refused (LLDB then splits or reports the error).
- **MDSCR_EL1.MDE** (bit 15) is set while any watchpoint is on (with SS,
  bit 0, while stepping); KDE stays 0, so EL1 (the shim) never takes a
  debug exception. KVM switches the debug registers to the guest's while
  MDE is set.
- The count is ID_AA64DFR0_EL1.WRPs + 1 of the vCPU (4 on the Linux host).

A watchpoint exception (EC 0x34, from EL0) is taken before the access
happens: ELR is the accessing instruction, FAR the accessed address, ISS
bit 6 (WnR) a write. The kernel reports it as a `watchpoint` stop
(`KernelDebugStop.Kind.watchpoint`); the stub names the watchpoint whose
range holds FAR, else the nearest one whose doublewords overlap the access
(a wide access reports its first byte), and replies `reason:watchpoint`
with the description LLDB parses (address, register, FAR).
`watchpoint_exceptions_received:before` in `qHostInfo` tells LLDB to step
the instruction with the watchpoint disabled, then report the hit with the
old and new values. Detach and kill clear the registers; a watchpoint trap
left over after a detach is ignored.

## 7. Attach, detach, kill

- **The launched app.** With `--launch`, a new connection's first packet
  attaches the stub to the app's process (the pid `ylaunch` reported).
  Without one (or before the launch), the connection has no process (`qC`
  → `QC0`, `?` → `E02`): LLDB is "connected" and attaches with `process
  attach --pid N` or `--name X [--waitfor]`.
- **Spawn holds.** The launcher calls the stub for every new image before
  its main thread starts (`ImageLauncher.register`, kernel lock held). An
  image a debugger waits for is attached there: its threads are held, so
  the main thread parks before its first instruction (the host page's
  `_ycode_launch`, before `dyld_sim` runs), and no code of the image has
  run when the debugger sees it. Only a pending wait holds anything.
- **`vAttachWait;<name>`** (and `vAttachOrWait` when no process of that
  name runs) registers a wait for the next spawn of that executable name
  (10 minutes at most) and attaches to the held image.
- **`--debug-launch-stopped`** (a ycode-simd option after
  `--debug-server`) registers a wait for the `--launch` app's executable
  (its `CFBundleExecutable`) at startup: the app is held at its first
  instruction from its spawn until a connection's first packet attaches to
  it (the "launched … pid N" line still comes, as ylaunch's launch
  returns). A run that no debugger attaches to keeps the app held.
- **Attach** sets the kernel's debug hook (one debugger per image), holds
  every thread and waits until they are stopped (10 s at most), then
  replies SIGSTOP for the main thread.
- **Detach** removes every breakpoint (restoring the bytes), drops the
  hook and the holds and any pending step; the process runs on.
- **Kill** ends the process with SIGKILL (the kernel's `postSignal`).

## 8. Using it

### 8.1 From the command line (the Mac)

On the host, the run gets `--debug-server unix:$YCODE_DATA/debug/<device>.sock`
(the launcher `ycode-sim` passes it as an app option, outside the warm-boot
fingerprint). On the Mac:

```sh
ssh -N -L 127.0.0.1:47200:$YCODE_DATA/debug/<device>.sock <user>@<arm64-linux-host> &
lldb DebugDemo.app
(lldb) settings set target.exec-search-paths <build>/DebugDemo.app
(lldb) settings set target.process.memory-cache-line-size 16384
(lldb) settings set target.enable-trampoline-support false
(lldb) gdb-remote 127.0.0.1:47200
(lldb) breakpoint set --file Work.swift --line 22
(lldb) continue
(lldb) expression n * 2
```

To stop the app before any of its code runs, either start the run with
`--debug-launch-stopped` (the first `gdb-remote` attaches to the held app,
at its first instruction), or connect before the launch and wait for it:

```sh
(lldb) gdb-remote 127.0.0.1:47200          # no process yet: "connected"
(lldb) process attach --name DebugDemo --waitfor
(lldb) breakpoint set -n main -s DebugDemo
(lldb) continue
```

### 8.3 The lldb settings

| Setting | Why |
|---|---|
| `target.exec-search-paths <app directory>` | the guest's path of the app is not the Mac's; lldb finds the build by name (UUID checked) |
| `target.process.memory-cache-line-size 16384` | the system images' load commands and symbol tables are read from memory; 16 KiB reads (one guest page) instead of 512 bytes cut the attach over ssh from 118 s to 18 s (DebugDemo, iOS 27.0, ~500 images) |
| `target.enable-trampoline-support false` | with libobjc read from memory, lldb 2103 (Xcode 27.1) crashes in its Objective-C stub-section check on the first step into a function (SIGSEGV in `AppleObjCSharedCacheStubs::ReadStubSectionsIfNeeded`, after "Could not find implementation lookup function class_getMethodImplementation"); with trampoline support off, `step` works. OPEN QUESTION: what that check needs (it is not in LLVM's open-source lldb) |

The IDE passes all three as lldb-dap `preRunCommands`
(`RemoteSimulator.debuggerSettings`).

### 8.2 The IDE

Run on a Ycode simulator destination now runs with the debugger, as Run on
a Mac simulator does (the defaults key `Ycode.remote.debugger` = false turns
it off; a Gauge profile run never attaches):

1. The run command adds `--debug-server unix:<data>/debug/<device>.sock`
   (`RemoteSimulator.debugServerArguments`).
2. At the "launched <bundle id> pid N" line the activity reads
   "Configuring Debugger Actions"; ssh forwards the socket to a free
   loopback port (`debugForwardArguments`).
3. lldb-dap starts and attaches with `gdb-remote-port`,
   `gdb-remote-hostname: 127.0.0.1` and `program` = the local build of the
   app's executable (`DAPClient.attachRemote`); breakpoints are sent on
   `initialized` as in every session (`specs/ide/debug.md`), and the app is
   continued once.
4. From there the session is an ordinary lldb-dap session: debug bar,
   variables view, breakpoint stops, stepping.
5. Stop detaches the debugger (it does not kill the app: the launcher ends
   it at its save, `run.md` §Warm boot); the forward ends with the run.

## 9. The sample app

`ycode/Tools/debug-samples/DebugDemo` (original Ycode code): a UIKit app
whose main thread runs `work(round:stats:)` once a second (`Work.swift`:
`fibonacci`, a `Stats` struct passed `inout`). In round
`DEBUGDEMO_PLUGIN_ROUND` (environment, default 40; `--app-env`) it loads
`libDemoPlugin.dylib` from its bundle with `dlopen` and from then on calls
its `demo_plugin_scale` (C, `Plugin.c`; the global `demo_plugin_calls`
counts the calls). `build.sh` builds it for the iOS simulator with `-g
-Onone` (`xcrun swiftc`, `xcrun clang` for the plugin), registers the
Swift module with the linker (`-add_ast_path`, as Xcode builds do, so
Swift expressions can import the app's module and use its types), makes
the dSYMs, and signs it ad hoc.

## 10. Results

On the Linux host (arm64, KVM; other agents' boots loading it 40–200),
iPhone 18 Pro, iOS 27.0, DebugDemo; the Mac's `lldb` (lldb-2103.0.34.103,
Xcode 27.1) and `lldb-dap` over an ssh forward:

- **CLI** (`lldb -b` with the commands of §8.1): `gdb-remote` attached to
  the launched app (SIGSTOP in `mach_msg`), the images were found (the app
  from the build with its dSYM; ~500 system images from memory);
  `breakpoint set --file Work.swift --line 22` resolved to
  `work(round:stats:) + 44` and was hit on the next timer round; `bt`
  showed `work` and `DemoController.tick()` with source lines, then
  Foundation, CoreFoundation, GraphicsServices and UIKitCore frames by name
  and `main`, `start_sim`; `frame variable` showed `round`, `stats` (a
  struct with its fields) and, after `next` (line 23), `n`; `step` entered
  `fibonacci(n:)` at line 11 with `n`; `finish` returned to line 23;
  `continue` hit the breakpoint again one round later; `register read`
  showed pc, sp, fp, lr, cpsr, and v0, fpsr, fpcr; `breakpoint delete` and
  `detach` let the app run on (its round counter kept counting between
  sessions: 14 → 79 → 80). The device kept presenting frames and
  SpringBoard ran on (only the app's process is held during a stop).
- **IDE** (`RemoteDebugEndToEndTests`, the session as Run drives it, with
  the real lldb-dap): the run boots or restores the device, launches the
  app, the activity reads "Configuring Debugger Actions", lldb-dap
  attaches, the breakpoint stop shows "Paused DebugDemo", frames
  `work(round:stats:)` Work.swift:22 / `DemoController.tick()` App.swift:24
  / … and the variables `round`, `stats`; Step Over moves to line 23 and
  shows `n`; Continue stops again at line 22; Stop detaches and the
  launcher saves the device. Three runs in a row passed (177 s with a cold
  boot; 56 s and 61 s from warm boot, Run to Stop), and again after the
  merge of the main line (162 s, cold).
- **Unit tests**: `GDBRemoteTests` (framing, checksums, escapes, hex, the
  register layout and `qRegisterInfo` text, `g`/`G`/`p`/`P` with thread
  suffixes, memory with breakpoint shadowing, `Z0`/`z0`, `vCont` parsing
  and resume actions, stop replies and `jThreadsInfo`, attach, detach,
  kill, `_M`/`_m`, `jGetSharedCacheInfo`, no-ack mode over a connection);
  `DebugHookTests` (a breakpoint stops every thread; holds are not Mach
  suspension and add to it; registers of a stopped thread; a step request
  and its trace stop; a fault stops and, resumed with its signal, ends the
  image; retry and decline; threads made during a stop start held; flush
  requests); `RemoteDebugTests` (the run command, the forward, the lldb
  settings, when the IDE attaches).

- **iOS 27.1** (iPhone Duo): the same app and stub; `breakpoint set
  --file Work.swift --line 24` stopped with the locals `round`, `stats`,
  `n`, `value`.
- **Expressions** (iOS 27.1): `expression -l c -- 6 * 7` → 42;
  `expression -l c -- (int)getpid()` → the guest pid (a function call in
  the process: LLDB's code in `_M` memory, a thread run to a breakpoint at
  the return address, the registers restored); `p stats.total` and
  `po stats` (Swift, through the variables); an Objective-C message
  expression (`[[NSProcessInfo processInfo] processName]` → "DebugDemo").
  Swift **expressions** (`expression n * 2`) fail: LLDB writes
  `@available(iOS 0, *)` into the expression, because the stub reports no
  OS version (§4.3, §11).

## 10.2 Results of SIM-DEBUG2 (2026-10-31)

On the Linux host, iPhone 18 Pro, iOS 27.0, DebugDemo (with its plugin),
the Mac's `lldb` (lldb-2103) over an ssh forward:

- **Launch-stopped attach** (`--debug-launch-stopped`): ycode-simd printed
  "pid N (DebugDemo) held at its first instruction for the debugger", the
  launch line followed; `gdb-remote` attached with SIGSTOP at pc
  0x3_1000_0000 (`_ycode_launch`, the host page) with only DebugDemo and
  `dyld_sim` loaded, and `breakpoint set -n main -s DebugDemo` + `continue`
  stopped at `main` (App.swift:67) called from `dyld_sim`'s `start_sim`;
  LLDB had added the ~500 system images on the way through its
  notification breakpoint (§4.4).
- **Wait-attach** (connected during the boot, `process attach --name
  DebugDemo --waitfor`): held at its first instruction in the same way.
  (In lldb's synchronous mode `gdb-remote` to a stub with no process waits
  for a stop that never comes; `script lldb.debugger.SetAsync(True)` before
  it and `SetAsync(False)` after, then `process attach`, as in a session
  script.)
- **Swift expressions**, at Work.swift:25: `expression n * 2` → `(Int) $R0
  = 20`; `p stats.total + value` → 55; `po stats` → the struct's fields;
  `po "round \(stats.rounds) of \(n)"` → "round 1 of 10"; `expression
  stats` → `(DebugDemo.Stats)`; C: `expression -l c -- (int)getpid()` →
  the guest pid.
- **Watchpoints**: `watchpoint set variable stats.total` (8 bytes, a
  write) stopped at the next line with "old value: 0, new value: 55";
  `watchpoint set variable demo_plugin_calls` (4 bytes, a C global in the
  plugin) "old value: 0, new value: 1". `qWatchpointSupportInfo` reported
  4.
- **An image loaded after the attach**: `breakpoint set -n
  demo_plugin_scale` (pending) resolved when the app `dlopen`ed
  libDemoPlugin.dylib in round 5 and stopped at Plugin.c:8 with `value`;
  `bt` showed the Swift closure in `DemoController.tick()`; `image list`
  showed the Mac's build of the plugin (found in the app directory by the
  search path, UUID checked).
- **IDE** (`RemoteDebugEndToEndTests`, the real lldb-dap, the session as
  Run drives it): passed (611 s with a cold boot under load): "Paused
  DebugDemo" at Work.swift:22, frames `work(round:stats:)` /
  `DemoController.tick()` / …, variables `round=2` and `stats` (its type,
  with fields as children); `expression round * 2` in the console →
  `(Int) $R0 = 4`; Step Over to line 23 with `n=12`; Continue to line 22
  again; Stop.
- After the merge of the main line (2026-10-31): the same session passed
  again (r15). In one earlier launch-stopped run on a host loaded by other
  agents (r14: the attach came before the home screen appeared) the app,
  continued from `main`, never reached its first round in the remaining
  13 minutes; it was not reproduced, and the run had no packet log.
- The whole session (attach at the first instruction to the last detach,
  ten stops) took 29 s; an attach to a running app 19–40 s (LLDB reads the
  system images' symbol tables from memory).
- Before the fixes of this agent: a `}` LLDB did not escape cost a 5 s
  timeout and LLDB's resync (`qEcho`) after it; stepped new workqueue
  threads ended in "stop reason = trace" stops (§6); a watchpoint set
  while a thread waited at its gate was loaded only at that thread's next
  trap (the vCPU now loads them after the gate); `?` → `W00` and an empty
  `qfThreadInfo` made a connection without a process look like an exited
  process or a bare-board target with pid 1.
- **Unit tests**: `GDBRemoteTests` (the probes, the image requests in all
  forms and detail levels against Mach-O images in a fake process's
  memory, the Mach-O reader, dyld's states, watchpoints and their stop
  replies, the unescaped closing brace, `?`/`qC`/`qfThreadInfo` without a
  process); `DebugHookTests` (a watchpoint stop with its address and
  direction; the image-list notification going on to `notification` with
  the array below the red zone, adding and removing; "main called");
  `DebugStubTests` (Linux arm64: the watchpoint register values, the
  runtime version).

## 10.1 Boots

SIM-DEBUG2: thirteen boots of iOS 27.0 with `--debug-server` reached the
home screen (54–170 s cold on the loaded host, other agents building) and launched the app; with
`--debug-launch-stopped` the app stayed held until the attach and then ran
normally.

With `--debug-server` on, iOS 27.0 (iPhone 18 Pro) reached the home screen
in 46–76 s cold on the loaded host (load 40–200), as without it; iOS 27.1
(iPhone Duo) in 225 s on a cold device copy under load, and the app
launched. A run that no client connects to pays nothing: the stub only
listens, and the kernel's debug hook is consulted only on a non-SVC
exception.

## 11. Not done and open questions

- The lldb settings of §8.3 are needed (the trampoline crash is lldb's).
- The OS type is the device OS (§4.3), so LLDB's target platform is
  `remote-ios`, not `ios-simulator`. The images keep their simulator
  platform; what else LLDB does differently for a device target (it looks
  for system images in its device-support folders, and finds none) has not
  shown in the runs. OPEN QUESTION (dirty room): how the reference IDE's
  LLDB gets the OS version of a simulator process when the simulator runs
  on another machine (if it ever does), and whether a simulator OS type
  with a reported version can be made to work for Swift expressions.
- Hardware breakpoints (`Z1`) are not offered; the vCPUs' DBGBVR/DBGBCR
  registers could serve them as the watchpoint registers serve `Z2`–`Z4`.
- Watchpoints: only ranges one register holds (§6.2); no
  `SupportedWatchpointTypes` in `qSupported` (LLDB then sends power-of-two
  sizes up to 8 bytes, which fit).
- The stop of a stepped thread on a breakpoint is reported as `trace`
  (§6); where a new workqueue thread's step from its entry ends on the next
  breakpoint, whether one instruction ran or several (a branch) is not
  checked further.
- `P_TRACED` is not set in the process's `kinfo_proc` while a debugger is
  attached; system daemons that check it (watchdogs of a held app) do not
  know the app is being debugged. A launch-stopped app that is held long
  may be killed by such a watchdog; none was seen in the runs.
- One launch-stopped run (§10.2, r14) did not reach the app's first round
  after `main`; open until it recurs with a packet log.
- The `added-binaries` / `detailed-binaries-info` stop-reply keys are not
  sent (LLDB reads the notification's array and asks for the images).
- The Swift REPL is not supported.
- Non-stop mode, `qXfer` libraries and target XML are not offered.
- Thread names: the kernel does not keep pthread names, so `hexname` is
  never sent.

## Evidence

| Claim | Source | Level |
|---|---|---|
| Packet framing, checksums, escapes, acks, interrupt byte, `?`, `g/G/p/P/m/M/X/c/C/s/S/vCont/vAttach/D/k/Z0/z0/H/T/qC/qfThreadInfo/qSupported/QStartNoAckMode`, the empty reply for unsupported packets | GDB's documentation, "Remote Protocol" (Overview, Packets, General Query Packets, Stop Reply Packets) | 1 |
| LLDB's extensions: `qHostInfo`, `qProcessInfo`, `qRegisterInfo`, `QThreadSuffixSupported`, `QListThreadsInStopReply`, `jThreadsInfo`, `qThreadStopInfo`, `qShlibInfoAddr`, `qMemoryRegionInfo`, `x`, `QSaveRegisterState`, `vAttachWait`/`vAttachOrWait`, the stop-reply keys (`reason`, `description`, `threads`, `thread-pcs`, `hexname`, `qaddr`) | LLDB's `lldb/docs/resources/lldbgdbremote.md` (LLVM, Apache-2.0 with LLVM exception) | 1 |
| `ostype:iossimulator` → the `simulator` environment; parsing of stop-reply keys; no OS version → the memory-reading dyld plug-in; the plug-in's reading of `dyld_all_image_infos` and of dyld's header | LLDB's open source: `GDBRemoteCommunicationClient.cpp` (`ParseOSType`), `ProcessGDBRemote.cpp`, `DynamicLoaderDarwin.cpp` (`UseDYLDSPI`), `DynamicLoaderMacOSXDYLD.cpp` (Apache-2.0 with LLVM exception) | 1 |
| `jGetLoadedDynamicLibrariesInfos` forms and keys, `jGetDyldProcessState`, the support probes (`OK` to the empty argument), the unescaped `}` before `#`, `qWatchpointSupportInfo`, `watchpoint_exceptions_received`, the `reason:watchpoint` description | `lldbgdbremote.md`; `GDBRemoteCommunicationClient.cpp` (the probes), `ProcessGDBRemote.cpp` (`GetLoadedDynamicLibrariesInfos_sender`, the watchpoint stop reply), `DynamicLoaderDarwin.cpp` (`JSONImageInformationIntoImageInfo`), LLDB's debugserver `MachProcess.mm` (`FormatDynamicLibrariesIntoJSON`, the platform names, the dyld states) and `RNBRemote.cpp` (`?` → `E02`, `qC` → `QC0` without a process) (Apache-2.0 with LLVM exception) | 1 |
| The new loader: its notification breakpoint (by name in the dyld module, else the image list's `notification` when `dyldAllImageInfosAddress` matches), its reading of x0–x2 and the 24-byte entries, `dyld_sim` skipped as the dyld module of a simulator process, `IsFullyInitialized` | `DynamicLoaderMacOS.cpp`, `DynamicLoaderDarwin.cpp` (`UpdateSpecialBinariesFromPreloadedModules`) in LLVM's and the Swift project's `llvm-project` (Apache-2.0 with LLVM exception) | 1 |
| A simulator platform's OS version from the local process's environment; the Swift expression wrapper's `@available(<platform> <version>, *)`; an empty `qfThreadInfo` list → pid 1 | `PlatformDarwin.cpp` (`GetOSVersion`), `SwiftExpressionSourceCode.cpp`, `GDBRemoteCommunicationClient.cpp` (`GetCurrentProcessAndThreadIDs`) in the Swift project's `llvm-project` (Apache-2.0 with LLVM exception) | 1 |
| `dyld_image_info`, the notify modes, `notifyMonitorOfImageListChanges` (slot 55) | `mach-o/dyld_images.h`; `dyld-sim-handoff.md` §3, §6.2 | 1 |
| Watchpoint registers (DBGWVR/DBGWCR fields, PAC, LSC, BAS, MASK), MDSCR_EL1.MDE, ID_AA64DFR0_EL1.WRPs, the watchpoint exception (EC 0x34, FAR, WnR) and the active-pending step state | Arm Architecture Reference Manual for A-profile (public) | 1 |
| The guest's debug registers set with `KVM_SET_ONE_REG` and in effect at EL0 while MDE is set | Linux KVM API documentation (`KVM_SET_ONE_REG`, arm64 system registers); observed on the Linux host (§10.2) | 1, 3 |
| Mach-O header and load commands (`LC_SEGMENT_64`, `LC_UUID`, `LC_BUILD_VERSION`, `LC_VERSION_MIN_*`, `PLATFORM_*`) | public `mach-o/loader.h` | 1 |
| lldb-dap's `gdb-remote-port`, `gdb-remote-hostname` attach arguments | LLVM's lldb-dap documentation | 1 |
| `brk #0xf000` as LLDB's arm64 breakpoint opcode | LLDB's open source (the arm64 software breakpoint opcode) | 1 |
| BRK, software step (MDSCR_EL1.SS, SPSR/PSTATE.SS, EC 0x32, the active-not-pending / active-pending states), KDE, exception classes | Arm Architecture Reference Manual for A-profile (public) | 1 |
| MDSCR_EL1 is a guest register KVM saves and restores and `KVM_SET_ONE_REG` sets | Linux KVM API documentation (`KVM_SET_ONE_REG`, arm64 system registers) | 1 |
| Exception → signal mapping | `processes.md` §2.3.1 (xnu open source) | 1 |
| `dyld_all_image_infos` layout and what `dyld_sim` writes | `dyld-sim-handoff.md` §4.5 | as there |
| `qaddr` = the thread's libdispatch slot | `ThreadInfo.swift` (THREAD_IDENTIFIER_INFO, public `mach/thread_info.h`) | 1 |
| The stub's behavior end to end | runs on the Linux host with the Mac's `lldb` and lldb-dap (§10) | 3 |
| Every other choice (one client, attach at the first packet, holds, the socket path, `--debug-server`, the IDE flow) | Ycode design | — |
