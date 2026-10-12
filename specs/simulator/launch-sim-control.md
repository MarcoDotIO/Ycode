# Spec: the simulator control channel (`launchd_sim`'s service port)

Status: **reference** for stage 7 (`stage7-contract.md` §1 item 2, agent
R3). It gives the messages that a host sends to the iOS 27.1 runtime's
(24A94401) `launchd_sim` on its **service port**, and the replies that
`launchd_sim` sends back. It is precise enough for Ycode's host to
register host-side Mach names into the guest, bind the session, look up
guest endpoints, read the guest domain environment, start one-shot
programs with the host's stdio, wait for them, and detect the guest's
death, without `liblaunch_sim.dylib`.

Every fact comes from public headers and old Apple open source
(level 1), from the exported names and load commands of
`RR/usr/lib/system/host/liblaunch_sim.dylib` (level 4), and from
black-box runs of our own programs (level 3). No Apple binary was
disassembled or decompiled. Header, disposition, and descriptor terms are
those of `mach-ipc.md` §2. All integers are little-endian.

Terms:

- **RR**, **DEV**, **TMP**, **device launchd name**: as in
  `launchd-sim.md` (terms).
- **Service port**: the port whose receive right the host hands to
  `launchd_sim` in the 808 reply to its 708 startup request
  (`bootstrap-wire.md` §5). The host keeps a send right. That send right
  is the **control channel**. On macOS, the port is also published as the
  device launchd name in the host user domain.
- **Host**: whoever holds the control channel. On macOS it is
  CoreSimulator's helper, through `liblaunch_sim`. In Ycode it is the VMM.
- **The library**: `RR/usr/lib/system/host/liblaunch_sim.dylib`
  (`launchd-sim.md` §6.2).
- **Probe**: our programs in
  `research/experiments/simulator/launch-sim-control/` (Appendix A). Its
  *call mode* serves a port itself and records what the library sends. Its
  *host mode* starts the runtime's real `launchd_sim` on this Mac as a host
  would, keeps the service port, and either relays the library's messages
  to it (recording both directions) or sends messages built by **our own
  writer** from this spec ("raw" calls).
- **`name128`**: a 128-byte, NUL-padded C string field (MIG `c_string`
  of fixed size 128).
- **`NDR`**: the 8-byte MIG NDR record `00 00 00 00 01 00 00 00`.

## 1. Overview

1. The control channel is a classic **MIG subsystem with base 700**, not
   libxpc pipe traffic. Requests carry plain MIG layouts (NDR record, fixed
   128-byte names, port descriptors, one out-of-line byte array). No
   serialized XPC object (`bootstrap-wire.md` §3) appears in either
   direction. The library imports the MIG helpers (`mig_get_reply_port`,
   `mig_strncpy_zerofill`, `NDR_record`) and no libxpc pipe calls.
2. Every request is a routine: it carries a reply port
   (`MAKE_SEND_ONCE`), and `launchd_sim` answers on it with
   `msgh_id` = request id + 100.
3. Operations (the library function that sends each one, and the
   CoreSimulator operation name from `launchd-sim.md` §6.1):

   | `msgh_id` | Reply id | Operation | Library function | SimLaunchHost name |
   |---|---|---|---|---|
   | **700** | 800 | bind the session to a host port | `launch_sim_bind_session_to_port` | `startsession` |
   | **701** | 801 | register a host-side endpoint in `user/<uid>` | `launch_sim_register_endpoint` | (registration, `launchd-sim.md` §6.3) |
   | **702** | 802 | find an endpoint in `user/<uid>` | `launch_sim_find_endpoint` | `findendpoint` |
   | **703** | 803 | read a variable of the `user/<uid>` domain environment | `launch_sim_getenv` | `getenv` |
   | **704** | 804 | spawn a one-shot program | `launch_sim_spawn` | `spawn` |
   | **705** | 805 | wait for a one-shot to exit | `launch_sim_waitpid` | `spawn` (exit status) |
   | **706** | 806 | give `launchd_sim` a port whose death tells the host that `launchd_sim` died | `launch_sim_set_death_handler` | — |
   | **709** | 809 | unregister a host-side endpoint | `launch_sim_unregister_endpoint` | — |

   No exported function sends 707 or 708. Whether `launchd_sim` serves
   them is open (§8); a host must not send them (§5.5).
4. The same port also receives libxpc pipe routine 700
   (`msgh_id` `0x400002BC`) from `xpcproxy_sim` (`launchd-sim.md` §9 Q5).
   The two are distinguished by the `0x40000000` pipe bit. They are
   different protocols on one port.

## 2. Envelope

### 2.1 Request header

| Field | Value |
|---|---|
| `msgh_bits` remote | `COPY_SEND` of the host's send right to the service port |
| `msgh_bits` local | `MAKE_SEND_ONCE` of a reply port |
| `msgh_bits` voucher | the library attaches the caller's voucher (`COPY_SEND`). Not required: requests with no voucher (Ycode's case) were accepted |
| `COMPLEX` | set if and only if the request has descriptors (700, 701, 704, 706) |
| `msgh_id` | 700 to 709 (§1) |

Body after the header (and after the descriptors, if complex), per
operation:

| Id | Descriptors | Inline body | `msgh_size` |
|---|---|---|---|
| 700 | 1 port: the session port, `COPY_SEND` | none | 40 |
| 701 | 1 port: the endpoint's send right, `COPY_SEND` | `NDR`, `name128` endpoint name | 176 |
| 702 | — | `NDR`, `name128` endpoint name | 160 |
| 703 | — | `NDR`, `name128` variable name | 160 |
| 704 | 4: OOL spawn attributes (§4), then 3 ports (stdin, stdout, stderr fileports) | `NDR`, `u32` attribute byte count | 92 |
| 705 | — | `NDR`, `i32` pid | 36 |
| 706 | 1 port: a receive right, `MOVE_RECEIVE` | none | 40 |
| 709 | — | `NDR`, `name128` endpoint name | 160 |

Port descriptors are 12-byte type-0 descriptors; the 704 OOL descriptor
is a 16-byte type-1 descriptor. Descriptor count is at offset 24, the
first descriptor at offset 28.

Names: the library copies at most 127 bytes and always NUL-terminates
(a 150-byte name was sent as its first 127 bytes). The rest of the field
is zero.

### 2.2 Reply forms

`launchd_sim` replies with `msgh_id` = request + 100, remote = the
request's reply right (received as a send-once right), local 0.

| Form | Layout after the header | Used for |
|---|---|---|
| **status** (36 bytes) | `NDR`, `i32 RetCode` | success of 700, 701, 706, 709; failure of any operation |
| **port** (40 bytes, complex) | 1 port descriptor (a send right) | success of 702 |
| **value** (164 bytes) | `NDR`, `i32 RetCode` (0), 128-byte value | success of 703 |
| **int** (40 bytes) | `NDR`, `i32 RetCode`, `i32 value` | 704 (pid) and 705 (wait status), success or failure |

A host must read `RetCode` (offset 32) of any non-complex reply first: a
non-zero `RetCode` can arrive in the status form or in the full form
(704 failures came both ways: 40 bytes with pid −1, and 36 bytes).

### 2.3 Error codes

`launchd_sim` encodes an errno `e` as **`0xC000 | e`** (the
`unix_err()` form of `<mach/error.h>`: system 0, subsystem 3; `launchctl
error 0xc003` prints "(os/unix) no such process"). The library turns
`0xC000 | e` back into `e`, and returns any other `RetCode`, kernel send
error, or look-up error unchanged.

| errno | Seen for |
|---|---|
| 3 `ESRCH` | 702 unknown name; 703 unset variable; 709 name not registered; 705 pid not a one-shot child, or already collected |
| 17 `EEXIST` | 701 name already present in `user/<uid>` (a second registration, or a job's `MachServices` name) |
| 37 `EALREADY` | 700 when the session is already bound |
| 111 (launchd: "Invalid or missing Program/ProgramArguments") | 704: program missing, relative path, or wrong architecture (`launchd.log` shows the `posix_spawn` errno, e.g. 86 `EBADARCH`) |

## 3. Operations

### 3.1 700 bind session

- **Request**: one port descriptor, a send right to a port whose receive
  right the host keeps (the **session port**). No body.
- **Reply**: status. Second bind: 37.
- **Effect** (`launchctl print system` before and after, `launchd.log`):
  - Before the bind, with `RequireDomainBinding = true` in the bootstrap
    plist, the `system` domain stays in its bootstrap and on-demand
    phases (`in-progress bootstraps = 1`, `properties = uncorked | in
    initial on-demand`). Its held jobs (here a `RunAtLoad` job with
    `LimitLoadToSessionType = System`) do not start. `user/<uid>` is not
    affected: it leaves its phases at creation, and 701–706/709 all work
    before the bind.
  - At the bind, `system` logs "exiting bootstrap mode" and "exiting
    ondemand mode", starts its held jobs, and shows `properties =
    uncorked | bound`. The `system` domain's **death port** becomes the
    session port (the `death port =` line of `launchctl print system`
    shows the session port's name).
  - With `RequireDomainBinding = false`, `system` leaves its phases at
    creation without a bind, and a bind is still accepted (`bound` is
    added).
- **Session port death**: when the host destroys the session port's
  receive right, `launchd_sim` runs a full **shutdown** within about 1 s
  (log: "shutting down", "committing to system shutdown", services sent
  `SIGTERM`, domains removed, "bye") and exits with status 0. A host can
  therefore shut the guest down cleanly by destroying the session port,
  and must keep that receive right alive for as long as the guest should
  run.

### 3.2 701 register endpoint

- **Request**: one port descriptor (the host service's send right,
  `COPY_SEND`: the host keeps its own right), `NDR`, `name128`.
- **Reply**: status. Failure: 17 if the name already exists in
  `user/<uid>`.
- **Effect**: the name becomes a **dynamic endpoint of the unmanaged
  pseudo-process `com.apple.xpc.launchd.simhost`** in `user/<uid>`,
  flagged `host-side = 1`, `active = 1`, `managed = 0` (`launchctl print
  user/501`: `0x… H A <name>` in `endpoints`). A guest process in
  `user/<uid>` that calls `bootstrap_look_up(name)` gets a send right to
  the host's port: a message that our guest probe sent there arrived on
  the host's receive right. A process in the `system` domain does **not**
  see the name (look-up error 3, logged as 1102 to the caller), because
  `system` look-ups do not fall through to `user/<uid>`.
- The library takes the port as an argument and does not look the
  endpoint name up anywhere. The "look up in the host bootstrap first,
  skip names with no host service" behavior of `launchd-sim.md` §6.3 is
  CoreSimulator's own logic around the call.

### 3.3 709 unregister endpoint

- **Request**: `NDR`, `name128`. **Reply**: status; 3 if the name is not
  registered (a second unregister).
- **Effect**: the name disappears; a later guest look-up gets 1102.
  At shutdown, `launchd_sim` removes all simhost endpoints itself.

### 3.4 702 find endpoint

- **Request**: `NDR`, `name128`.
- **Reply**: port form with a send right to the endpoint, or status with
  3.
- **Scope**: `user/<uid>` only. It finds host-side endpoints (it returned
  the host's own port) and the `MachServices` names of `user/<uid>` jobs
  (also on-demand jobs that are not running). It does **not** find
  `system`-domain names (3, before and after the bind).

### 3.5 703 getenv

- **Request**: `NDR`, `name128` variable name.
- **Reply**: value form, or status with 3 when the variable is not set.
- **Scope**: the **`user/<uid>` domain environment** (the variables shown
  under `environment = {}` in `launchctl print user/501`, set for example
  by a guest `launchctl setenv`). It is not `launchd_sim`'s own
  environment, the bootstrap plist's `Self` or `Child`: `SIMULATOR_UDID`
  and `HOME` gave 3 even after the bind.
- **Value field**: 128 bytes, NUL-padded. A value of 128 bytes or more is
  cut to 128 bytes **without** a terminating NUL (seen for 128 and 200).
  A receiver must bound the string at 128 bytes.

### 3.6 704 spawn (one-shot)

- **Request**: four descriptors, then `NDR` and a `u32` count:

  | # | Descriptor | Content |
  |---|---|---|
  | 0 | OOL memory (type 1), `copy` = virtual, `deallocate` = 1 (library) | the spawn attributes (§4); `size` = exact byte length (not rounded) |
  | 1 | port | stdin: a **fileport** send right for the host fd (`processes.md` §4.9), or `MACH_PORT_NULL` |
  | 2 | port | stdout, same |
  | 3 | port | stderr, same |

  The `u32` after `NDR` equals the attribute length (= the OOL `size`).
  The library makes each fileport with `fileport_makeport` (a new port per
  fd, moved to `launchd_sim`). A negative fd becomes `MACH_PORT_NULL`;
  the guest program then still ran normally (stdin null).
- **Reply**: int form, value = the new process's pid (a real pid in the
  host kernel's numbering on macOS). Failure: `RetCode` 111 with pid −1
  (40 bytes) or the status form.
- **Effect** (`launchd.log`, `launchctl print`, the probe's own output):
  - A one-shot job is created in **`user/<uid>`** with label
    `com.apple.xpc.launchd.oneshot.0x<8 hex>.<basename of path>`. The
    counter starts at `0x10000000` per `launchd_sim` instance and
    increases by one per spawn. Launch reason "one-shot". It is spawned
    through `xpcproxy_sim` like any job.
  - The **path is used as given** (a host path), not resolved under RR:
    `/bin/launchctl` ran the macOS binary and failed with `EBADARCH`; the
    runtime's tool had to be named by its full RR path. A relative path
    fails (111).
  - `argv` is used verbatim; `argv[0]` need not match the path (ps showed
    the given `argv[0]`).
  - Environment = the given variables plus the job environment of
    `launchd-sim.md` §4.4 (the `Child` keys such as `SIMULATOR_UDID`,
    `XPC_SIMULATOR_LAUNCHD_NAME`, plus `XPC_SERVICE_NAME=<label>` and
    `XPC_FLAGS=0x0`).
  - Working directory = the attribute's cwd (`/tmp` gave
    `/private/tmp`), or `/` when absent.
  - stdio = the passed fileports: the program's stdout and stderr lines
    appeared on the host's fd 1.
  - **Start suspended** flag (§4): the process is created stopped (ps
    state `T`) and runs when the host sends it `SIGCONT`.
  - **CPU type** preference (§4): arm64 (`0x0100000C`) ran;
    x86_64 (`0x01000007`) failed with 111 (`EBADARCH`) for an arm64-only
    program.
  - The process's bootstrap port is its domain's (`user/<uid>`): it found
    host-side endpoints registered with 701.

### 3.7 705 waitpid

- **Request**: `NDR`, `i32` pid.
- **Reply**: int form, value = the wait status in `waitpid(2)` encoding
  (`exit(7)` → `0x0700`; killed by `SIGKILL` → `9`). Failure: status with
  3.
- **Blocking**: the reply is sent when the process exits (2 s for a
  process killed after 2 s). For a process that had already exited, the
  reply is immediate: `launchd_sim` reaps the one-shot itself (no zombie
  remained) and keeps its status until the host collects it once. A
  second 705 for the same pid, or a pid that is not a one-shot (pid 1),
  gives 3. Whether 705 accepts the pid of an ordinary job is open (§8).

### 3.8 706 death port

- **Request**: one port descriptor, `MOVE_RECEIVE` of a port the host
  just made. The host keeps a send right to it. No body.
- **Reply**: status (0).
- **Effect**: `launchd_sim` holds the receive right; no domain property
  changes (the `death port` lines of `system` and `user/<uid>` did not
  change). When `launchd_sim` exits (killed, or after a shutdown caused by
  the session port's death), the port is destroyed and the host's send
  right becomes a dead name. The library watches that send right with a
  dispatch source of type "Mach send, dead" and runs the caller's handler
  then (the handler ran in both cases).
- For Ycode, this is only a convenience: the VMM knows when its own guest
  process exits. Ycode may skip 706.

## 4. Spawn attributes (the 704 OOL blob)

A 156-byte header of 39 `u32` words, then a **string region**. All
offsets in the header are relative to the start of the region (blob
offset 156). Strings are NUL-terminated and packed with no padding; the
binary-preference record is not aligned. The blob ends right after the
last item (no trailing padding).

| Blob offset | Word | Meaning |
|---|---|---|
| 0x00 | 0 | total length of the blob in bytes (= 156 + region length); equals the OOL size and the body count |
| 0x04 | 1 | 0 (the path is always at region offset 0) |
| 0x08 | 2 | argc (0 when argv is NULL) |
| 0x0C | 3 | region offset of the first argv string (0 when argc = 0) |
| 0x10 | 4 | number of environment strings (0 when none) |
| 0x14 | 5 | region offset of the first environment string (0 when none) |
| 0x18 | 6 | number of binary-preference records (0 or 1 seen) |
| 0x1C | 7 | region offset of the binary-preference records (0 when none) |
| 0x20–0x37 | 8–13 | 0 |
| 0x38 | 14 | region offset of the working-directory string; 0 = none (use `/`) |
| 0x3C–0x5B | 15–22 | 0 |
| 0x5C | 23 | start suspended: 1 or 0 |
| 0x60 | 24 | `0x400` as written by the library. A blob with 0 here was also accepted, with no visible difference (meaning open, §8) |
| 0x64–0x9B | 25–38 | 0 |
| 0x9C | — | region: path, argv strings, environment strings (`KEY=VALUE`), working directory, binary preferences, in this order |

Binary-preference record (8 bytes): `u32` CPU type, `u32` CPU subtype.
The library writes subtype `0xFFFFFFFF` (any).

Example (built by our writer and accepted by `launchd_sim`; path
`/tmp/ycode-R3/lsguest`, argv `lsguest-raw`, `com.ycode.rawsvc`, env
`YC_RAW=1`, cwd `/tmp`, no CPU preference, not suspended), 221 bytes:

| Offset | Bytes | Meaning |
|---|---|---|
| 0x00 | `DD 00 00 00` | total 221 |
| 0x08 | `02 00 00 00` `16 00 00 00` | argc 2, argv at region 22 |
| 0x10 | `01 00 00 00` `33 00 00 00` | 1 env string at region 51 |
| 0x38 | `3C 00 00 00` | cwd at region 60 |
| 0x60 | `00 04 00 00` | `0x400` |
| 0x9C | `/tmp/ycode-R3/lsguest\0` (22) `lsguest-raw\0` (12) `com.ycode.rawsvc\0` (17) `YC_RAW=1\0` (9) `/tmp\0` (5) | region, 65 bytes |

All other header words are 0.

## 5. Behavior and ordering

### 5.1 When requests are served

- `launchd_sim` serves the service port only after it has created its
  domains (after the 708 exchange and the holding-tank wait,
  `bootstrap-wire.md` §5.4). Requests sent earlier stay queued and are
  answered then: a 701 sent right after the 808 reply, while the
  holding-tank child still ran for 3 s, was answered successfully when
  `system` and `user/501` were created.
- A host may also **queue requests on the port before it hands the
  receive right over**: a 701 sent to the new port while the host still
  held its receive right, followed by the 808 reply that moves that right,
  was answered after domain creation, and a `user/<uid>` `RunAtLoad` job
  that started at domain creation found the name on its first look-up.
  This makes host-side names available before any guest job runs without
  depending on timing.

### 5.2 Order the host should use

1. Answer 708 with the service port (`bootstrap-wire.md` §5.2), with the
   701 registrations for all host-side names already queued on it (§5.1).
2. Optionally send 706 (death port).
3. Send 700 (bind) with a session port whose receive right the host keeps.
   Until then, `system`-domain jobs do not start when
   `RequireDomainBinding = true` (§3.1).
4. Use 702–705 and 709 at any time after that. 704/705 do not need the
   bind.
5. To shut the guest down cleanly, destroy the session port's receive
   right (§3.1).

### 5.3 Sender identity

`launchd_sim` accepted control requests from our probe process, which was
also the process that served its host bootstrap. Requests from a process
that never served the 708 request were not tried (§8).

### 5.4 Fileports and stdio

The stdio ports of 704 are fileports (a Mach port that holds an open
file). Ycode's host end must create fileport kernel objects for the host
fds it wants the guest program to use (the Ycode kernel personality
already implements fileports, `processes.md` §4.9). How `launchd_sim`
turns them into fds of the new process was not observed.

### 5.5 Unknown message ids

- With `AbortOnUnknownIPC = true` (CoreSimulator's value and Ycode's
  default plist), a message with an id that `launchd_sim` does not serve
  (710 was tried) makes `launchd_sim` **kill the sender** (`launchd.log`:
  "Killing sender of bogus IPC message: <name>.<pid>"); the probe received
  `SIGKILL`. `launchd_sim` itself kept running.
- With `AbortOnUnknownIPC = false`, ids 699 and 710 got no reply; the
  reply right was destroyed (the sender received a send-once notification,
  `msgh_id` 71).
- A Ycode host must therefore send only the ids of §1.

## 6. The library's C interface (observed; for reference)

The library is not used by Ycode. Its interface is recorded so that the
SimLaunchHost operations of `launchd-sim.md` §6.1 can be matched with
wire messages. Signatures were found by black-box calls (Appendix A); the
confidence column says how directly.

Every function first looks up its **first argument, the device launchd
name**, with `bootstrap_look_up` on the calling process's
`bootstrap_port`, and sends to the port it gets. A failed look-up is
returned as the function's result (1102), and nothing is sent. The
library looks the name up again on every call.

| Function | Parameters (in order) | Result | Message | Confidence |
|---|---|---|---|---|
| `launch_sim_bind_session_to_port` | device name; Mach port (send right, copied) | `kern_return_t`-style code | 700 | high |
| `launch_sim_register_endpoint` | device name; endpoint name; Mach port (send right, copied) | code | 701 | high |
| `launch_sim_unregister_endpoint` | device name; endpoint name | code | 709 | high |
| `launch_sim_find_endpoint` | device name; endpoint name; out Mach port | code; the port is written only on success | 702 | high |
| `launch_sim_getenv` | device name; variable name | a newly allocated C string, or NULL on any failure | 703 | high (ownership presumed caller's: not tested) |
| `launch_sim_spawn` | device name; path; argv (NULL-terminated, may be NULL); envp (same); cwd (string or NULL); stdin fd; stdout fd; stderr fd; CPU type (0 = none); start-suspended (bool, low bit); out pid | code (−1 if an fd cannot be made into a fileport; nothing is sent then) | 704 | high for the order and meaning of all 11 parameters. The CPU type and bool sit in the first stack slots (Apple arm64: they must be placed so that the out-pid pointer is at the third 8-byte stack slot). The out-pid pointer must not be NULL (crash) |
| `launch_sim_waitpid` | device name; pid; out int status | code | 705 | high |
| `launch_sim_set_death_handler` | device name; dispatch queue; handler block (no useful arguments) | code | 706 | high |

Other exports are helpers (`xpc_binprefs_*`, `_xpc_spawnattr_pack_*`,
`_xpc_spawnattr_unpack_*`, `_xpc_spawnattr_binprefs_*`,
`xpc_create_from_ce_der*`). Their names match the blob of §4 (packed
strings, binary preferences); they were not called.

## 7. Requirements for Ycode (derived)

1. **Keep the service port's send right** from the 708/808 exchange; it is
   the only way to reach `launchd_sim`'s control operations.
2. **Host-side names** (`launchd-sim.md` §6.3, e.g. configd now,
   framebuffer/HID/GPU/audio in stage 8): for each, create a port that the
   VMM serves and send 701 with a send right to it. Queue the 701s on the
   service port before the 808 reply (§5.1) so that boot-time jobs see
   them. Only `user/<uid>` processes see them (§3.2); a service that
   `system`-domain daemons need cannot be provided this way.
3. **Bind** (700) with a session port whose receive right the VMM keeps
   for the VM's life, unless the bootstrap plist says
   `RequireDomainBinding = false`. Ycode's plist may now use `true`, as
   CoreSimulator does. Destroying the session port is the clean shutdown.
4. **One-shot programs** (for the stage 7 probe app's helper and later
   `ycode spawn`): 704 with a §4 blob, absolute guest-visible paths (RR
   paths spelled in full), fileports for the stdio fds, then 705 for the
   exit status. Use the suspended flag plus `SIGCONT` when a debugger must
   attach first.
5. **Parsing**: read `RetCode` before anything else; map `0xC000 | e` to
   errno `e`; bound getenv values at 128 bytes.
6. **Never send other ids** on the service port (§5.5).

## 8. Open questions

1. Ids 707 and 708 on the service port (no exported function sends them;
   probing them with `AbortOnUnknownIPC = true` gets the sender killed).
2. The meaning of attribute word 24 (`0x400`) and of the zero words 8–13,
   15–22, 25–38. Other spawn options (e.g. a process type, a label, I/O
   paths) may live there; the library's interface does not reach them.
3. Whether 705 works for the pids of ordinary jobs, and what happens to a
   one-shot's status if the host never collects it.
4. Whether `launchd_sim` checks who sends control requests (§5.3).
5. The identity of the `system` domain's death port before a bind (a port
   name was shown; it is not one the host gave).
6. What the real CoreSimulator host passes as the session port, and what
   it registers with 706.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Library exports, linkage (libSystem only), imports (MIG helpers, `bootstrap_look_up`, `fileport_makeport`, `posix_spawnattr_setarchpref_np`, dispatch Mach-send source, voucher set) §1, §6 | 4 | `nm -gU`, `nm -u`, `otool -L`, `lipo -archs` of `liblaunch_sim.dylib` |
| MIG terminology, NDR record, `unix_err` encoding, `waitpid` status encoding §2.3, §3.7 | 1 | macOS SDK headers `mach/ndr.h`, `mach/error.h` (`unix_err`), `mach/notify.h` (`MACH_NOTIFY_SEND_ONCE` = 71), `sys/wait.h`; the 128-byte `name_t` of the old open-source launchd as cited in `bootstrap-wire.md` §6.1 |
| Request ids 700–706, 709; header bits; descriptors; NDR; `name128`; 127-byte truncation; reply sizes the library expects §1–§2 | 3 | probe call mode: every function called against our port, one argument varied at a time, interposed `mach_msg` trace of send and receive sizes (`dumps/*.txt` in the agent-R3 scratch) |
| Reply forms accepted, error mapping in the library, getenv value as a returned string, find out-port, spawn out-pid, waitpid out-status §2.2, §6 | 3 | probe call mode with crafted replies (`YC_REPLY`) |
| Function parameter order and meanings §6 | 3 | probe call mode (bad pointers crash in a separate process; fds traced through the interposed `fileport_makeport`; stack slots found by which buffer was written) |
| Spawn attribute layout §4 | 3 | probe call mode: blob captured for varied path, argv, env, cwd, CPU type, flag; then **our own writer** produced blobs that the real `launchd_sim` accepted (scenarios `s5`, `s9`, `s11`, `s13`) |
| `launchd_sim` replies, error codes, domain scopes, simhost endpoints, guest look-ups reaching the host port §2.3, §3 | 3 | probe host mode with the real `RR/sbin/launchd_sim` started on this Mac; relay of the library's messages and raw messages from our writer; guest probe `lsguest`; `launchctl print system` / `user/501` run as one-shots; `TMP/launchd.log` |
| Bind effects, `RequireDomainBinding`, session-port death → shutdown and exit 0 §3.1 | 3 | scenarios `s3`, `s4`, `s10`, relaxed plist run (`h7`), `launchd.log` |
| One-shot label, path handling, env, cwd, stdio, suspended state, CPU preference §3.6 | 3 | scenarios `s2`, `s4`, `s5`, `s13`; `ps`; `launchd.log` |
| waitpid blocking and reaping §3.7 | 3 | scenario `s9` |
| Death-port behavior §3.8 | 3 | call mode (destroying the received right fired the handler), host mode `s3`/`s10` |
| Queuing before domain creation and before the 808 hand-over §5.1 | 3 | scenarios `s11` (`YC_TANK_SLEEP=3`), `s12` (`YC_PREQUEUE`) with a `RunAtLoad` user job |
| Unknown ids §5.5 | 3 | raw `rawid 710` with the default plist (`h6`) and `699`/`710` with `AbortOnUnknownIPC = false` (`h7`) |
| Requirements §7 | — | derived from the above |

Level 5 was not used: no disassembly or decompilation of any Apple
binary. `.claude/Xcode.app`, `research/dirty/`, and Ghidra were not
opened. Raw dumps: `…/scratchpad/agent-R3/dumps/` (session scratch).

## Appendix A. Probe and method

### A.1 Files

`research/experiments/simulator/launch-sim-control/`:

- `lsprobe.c` (macOS arm64): call mode, host mode, relay, our own
  message writer ("raw" calls), dumper.
- `lsinterpose.c`: a dyld interposing library, inserted with
  `DYLD_INSERT_LIBRARIES` into `lsprobe` only. It logs the library's
  calls to `bootstrap_look_up`, `fileport_makeport`,
  `posix_spawnattr_setarchpref_np`, and `mach_msg`, and resolves the
  device launchd name to the probe's port. (Interposing tuples in the
  main executable itself were not applied to the loaded library; the
  inserted library worked.)
- `lsguest.c` (iOS simulator platform): the guest program spawned by 704;
  prints its pid, cwd, selected environment, looks up names, and sends
  one message to each port found.
- `build.sh`, `run-call.sh`, `run-host.sh`, `scenarios/*.txt`.

### A.2 Call mode

`lsprobe call <fn> <args…>` loads the library, makes ports P and P2 that
it serves on a thread, and calls the function with argument tokens
(strings, integers, out-buffers filled with `0xA5`, NULL, a queue, a
block, our port names). Each experiment ran in its own process, so a
wrong guess crashed only that process. The interposer made the library's
look-up of the device name return P, so every request arrived on a port
the probe served and could answer in any form (`YC_REPLY`).

### A.3 Host mode

`lsprobe host RR/sbin/launchd_sim <plist>` starts the runtime's
`launchd_sim` directly from the macOS probe (fork, special bootstrap port
set around the fork, a holding-tank grandchild, exec with the environment
file), answers its 708 with a fresh receive right, and keeps the send
right. No booted simulator device is needed for this. The fake device:
`/tmp/ycode-R3/dev` (bootstrap plist and environment derived from the
stage-4c fake device of `bootstrap-wire.md` A.3, UDID
`5C0DE000-0000-4000-8000-000000000003`, `Paths` = one directory with two
or three test job plists using `RootedSimulatorPath`). `launchd_sim`
created `TMP = /private/var/tmp/com.apple.CoreSimulator.SimDevice.5C0DE000-0000-4000-8000-000000000003`
and wrote `launchd.log` there.
