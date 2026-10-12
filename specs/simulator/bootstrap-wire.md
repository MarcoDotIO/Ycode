# Spec: bootstrap wire format (what guest code sends to its bootstrap port)

Status: **reference** for stage 4c (`stage4c-contract.md` §4 row R). It
gives the Mach messages that the iOS 27.1 simulator runtime (24A94401)
sends to a task's bootstrap port, and the replies it accepts. It is precise
enough for Ycode to implement (a) the **host bootstrap** that `launchd_sim`
talks to at startup and (b) later, a guest-side reading of bootstrap and
XPC lookups.

Every fact comes from Apple open source and public headers (level 1) and
from black-box captures made by our own probe program (level 3). No
runtime binary was opened. Terms for header fields, dispositions, and
descriptors are those of `mach-ipc.md` §2. All integers are
little-endian.

Terms:

- **Pipe routine**: a request/reply pair in libxpc's pipe format (§2–§3).
  The request carries a serialized XPC dictionary, and so does the reply.
- **Routine number**: the low bits of a pipe request's `msgh_id` (§2.1).
- **Requester**: the process whose message arrives (identified by the
  audit token in the receive trailer, `mach-ipc.md` §2.6).
- **Probe**: `research/experiments/simulator/bootstrap-mitm/bsmitm.c`
  (our code). In its relay mode, it spawns a child whose bootstrap special
  port is a port that the probe owns. It then records each request, sends
  the request on to the real bootstrap port with the probe's own reply port,
  records the reply, and sends the reply back to the child. In its host mode,
  it answers requests itself (§7). Appendix A has details.

## 1. Overview

1. Every bootstrap call that the runtime's libraries make is a **pipe
   routine**. This includes `bootstrap_look_up`, `bootstrap_check_in`,
   `bootstrap_register`, `bootstrap_create_service`, `bootstrap_parent`, the
   private `bootstrap_look_up2/3` and `bootstrap_check_in2`, the XPC
   service lookup behind `xpc_connection_create_mach_service`, the XPC
   listener check-in, the pid-domain setup behind `xpc_connection_create`,
   and `launchctl`'s requests. No message in the legacy MIG `job`
   subsystem (IDs 400 to 4xx, §6.1) was seen.
2. `launchd_sim` sends **one** message to its own bootstrap port (the host)
   at startup: a bare MIG-style request with `msgh_id` **708** (§5). It
   sends nothing more to the host bootstrap, even when a guest looks up an
   unknown name.
3. A process reads its bootstrap port **once, during library
   initialization**. After that, a change to the `bootstrap_port` global or
   to the task special port has no effect on libxpc's bootstrap traffic
   (probe "self" mode captured nothing). Ycode must install the bootstrap
   special port before the process's first instruction.
4. A plain C program sends **nothing** to its bootstrap port during startup.
   Its first bootstrap message is its first explicit call.

## 2. Mach envelope of a pipe routine

### 2.1 Request

The table shows the request **as the receiver sees it**. Disposition values
are the received types (`mach-ipc.md` §2.5).

| Field | Value |
|---|---|
| `msgh_bits` remote | 18 (`PORT_SEND_ONCE`): the requester's reply port, made with `MAKE_SEND_ONCE` |
| `msgh_bits` local | 17 (`PORT_SEND`): the bootstrap port, sent with `COPY_SEND` |
| `msgh_bits` voucher | 17 with a voucher name on macOS. Ycode guests carry voucher 0 (`mach-ipc.md` §4.3). The server ignores it |
| `COMPLEX` | set if and only if the payload holds a port-bearing object (§3.4), or if the payload is out of line (§2.3) |
| `msgh_size` | 24, plus 4 + the descriptor bytes if complex, plus the inline payload |
| `msgh_id` | **`0x40000000 | routine`** (for example, look-up 207 → `0x400000CF`) |

Other pipe envelopes, observed with libxpc's general pipe calls on a port
the probe owns:

| Kind | `msgh_id` | Reply port |
|---|---|---|
| Routine with no routine number (general pipe call) | `0x40000000` | yes (`MAKE_SEND_ONCE`) |
| One-way message (pipe "simpleroutine") | `0x10000000` | none: remote is `MACH_PORT_NULL`, and the reply disposition is 0 |

### 2.2 Reply

| Field | Value |
|---|---|
| `msgh_bits` | remote = `MOVE_SEND_ONCE` (18) to the request's reply right, local 0, voucher 0, `COMPLEX` if the reply carries rights |
| `msgh_id` | **`0x20000000`** for every routine |
| Body | descriptors (if complex), then the serialized reply dictionary, inline |

The client checks the reply ID: a reply with ID `0x12345` made the general
pipe call fail with error 5 (`EIO`) and return no reply object. A reply
built by the probe (§7) with ID `0x20000000` and the layout below was
accepted every time.

### 2.3 Where the payload goes

The serialized object (§3) follows the last descriptor. If the message is
not complex, it starts at offset 24. For a large message, libxpc moves the
**whole payload** into a single out-of-line memory descriptor (type 1,
`copy` = virtual, `deallocate` = 1). The message then has a descriptor count
of 1 and no inline bytes (`msgh_size` 44). The descriptor's `size` field is
rounded up to a 16 KiB multiple. Receivers must therefore use the
dictionary's own length field, not the OOL size. Measured: a 16 060-byte
message stayed inline, and a 16 360-byte one went out of line. The exact
cut-off lies between these two sizes. Bootstrap requests are small (less
than 400 bytes), so this matters only for general pipe traffic.

## 3. XPC object serialization

### 3.1 Header

| Offset (in payload) | Size | Value |
|---|---|---|
| 0 | 4 | magic: the bytes `3F 63 70 78` (ASCII `?cpx`, u32 `0x7870633F`) |
| 4 | 4 | version: `5` |
| 8 | … | one object, the root. For pipe routines it is always a dictionary |

Every request and reply that was captured used `?cpx`. Ycode writes this
magic and should also accept `@cpx` (`0x78706340`), for safety (§8).

### 3.2 Objects

An object is a `u32` type tag, followed by its payload. Everything is
4-byte aligned. Variable-length payloads are padded with zero bytes to a
4-byte multiple. 64-bit values are only 4-byte aligned.

| Tag | Type | Payload after the tag |
|---|---|---|
| `0x1000` | null | none |
| `0x2000` | bool | `u32` 0 or 1 |
| `0x3000` | int64 | 8 bytes |
| `0x4000` | uint64 | 8 bytes |
| `0x5000` | double | 8 bytes, IEEE 754 |
| `0x7000` | date | int64, the value as given to the date setter (nanoseconds) |
| `0x8000` | data | `u32` length, then the bytes (padded). For **length > 16 384**, no bytes follow. The bytes are in a memory object, sent as the next port descriptor (§3.4) |
| `0x9000` | string | `u32` length **including** the terminating NUL, then the bytes and the NUL (padded). An empty string has length 1 |
| `0xA000` | uuid | 16 raw bytes |
| `0xB000` | file descriptor | none. The descriptor travels as the next port descriptor (a send right, received as type 17) |
| `0xC000` | shared memory | `u32` size, `u32` 0, plus the next port descriptor (a send right to the memory) |
| `0xD000` | Mach send right | none. Next port descriptor, received as type 17 |
| `0xE000` | array | `u32` byte length, `u32` count, then `count` objects |
| `0xF000` | dictionary | `u32` byte length, `u32` count, then `count` entries |
| `0x15000` | Mach receive right | none. Next port descriptor, received as type 16 |

Seen once, outside bootstrap traffic: an XPC connection's first message to
a service port has `msgh_id` `0x77303074`, no payload, and two port
descriptors (a receive right, then a send right). This is the connection
protocol, not bootstrap. It is out of scope here.

### 3.3 Dictionaries and arrays

- **Byte length** is the number of bytes after the length field: the 4-byte
  count plus all the entries. Example: a reply that holds only `"port"` as a
  receive right has byte length 16 (count 4 + key `port\0` padded to 8 + tag
  4).
- **Dictionary entry**: the key as NUL-terminated UTF-8, zero-padded to a
  4-byte multiple (`name` → `6E 61 6D 65 00 00 00 00`), then the value
  object.
- **Array entry**: the object only.
- **Key order** is libxpc's internal order, not insertion order. For
  example, a look-up always comes out as `handle, instance, flags, name,
  type, targetpid`. Readers must find values by key. Writers may use any
  order: one-key replies built by the probe were accepted.
- Nesting is allowed: dictionaries can hold dictionaries and arrays, and
  arrays can hold any object.

### 3.4 Port descriptors and objects

The port descriptors are in the same order as the port-bearing objects
(`0x8000` large data, `0xB000`, `0xC000`, `0xD000`, `0x15000`) in a
depth-first walk of the serialized payload. The *k*-th such object uses the
*k*-th port descriptor. All are 12-byte port descriptors (type 0). No
guarded or OOL-ports descriptors were seen. Example: the probe sent a
dictionary that it filled as `a-send` (send right), `b-blob` (data), `c-fd`
(fd). It serialized as `c-fd, a-send, b-blob`, and its descriptors were
[fd, send right].

### 3.5 A complete example (look-up, captured)

Request for `bootstrap_look_up("com.apple.cfprefsd.daemon")`. The message is
not complex, `msgh_size` 204, and `msgh_id` `0x400000CF`. Payload offsets
are from the start of the message:

| Offset | Bytes | Meaning |
|---|---|---|
| 24 | `3F 63 70 78` `05 00 00 00` | magic, version |
| 32 | `00 F0 00 00` `A4 00 00 00` `06 00 00 00` | dictionary, 164 bytes, 6 entries |
| 44 | `handle\0\0` `00 40 00 00` + 8 × `00` | `handle` = uint64 0 |
| 64 | `instance\0\0\0\0` `00 A0 00 00` + 16 × `00` | `instance` = null UUID |
| 96 | `flags\0\0\0` `00 40 00 00` + 8 × `00` | `flags` = uint64 0 |
| 116 | `name\0\0\0\0` `00 90 00 00` `1A 00 00 00` `com.apple.cfprefsd.daemon\0` + 2 pad | `name` (26 bytes with NUL) |
| 160 | `type\0\0\0\0` `00 40 00 00` `07 00 …` | `type` = uint64 7 |
| 180 | `targetpid\0\0\0` `00 30 00 00` + 8 × `00` | `targetpid` = int64 0 |

Reply (complex, one port descriptor at offset 28: the service's send right,
received as type 17), `msgh_size` 116, `msgh_id` `0x20000000`:
dictionary with 3 entries: `rec_execcnt` uint64, `req_pid` uint64, and
`port` `0xD000` (descriptor 0).

## 4. Bootstrap routines

### 4.1 Common request keys

| Key | Type | Meaning (observed) |
|---|---|---|
| `type` | uint64 | domain selector. **7**: the requester's own domain (every `bootstrap_*` call and XPC look-ups by name). **6**: XPC listener check-in. **5**: a pid domain. **2**: a user domain. **1**: the system domain |
| `handle` | uint64 | domain handle: 0 for types 1, 6, and 7, the uid for type 2, the pid for type 5 |
| `name` | string | service name. No length limit is applied on the client side: 127, 128, and 200-byte names were all sent |
| `flags` | uint64 | the caller's flags, passed through unchanged (`bootstrap_look_up2` flags 8 → 8. The XPC "privileged" connection flag → 8. `bootstrap_check_in2` flags 1 → 1) |
| `instance` | uuid | instance UUID (all zero unless `bootstrap_look_up3` passes one) |
| `targetpid` | int64 | `bootstrap_look_up2/3` target pid (0 by default) |
| `lookup-handle` | uint64 | XPC look-up only, 0 in every capture |

### 4.2 Routine table

"Error" means a reply dictionary whose only entry is `error` (int64),
unless more keys are listed. The client returns that value as the call's
`kern_return_t`. This was checked by sending error 45 from host mode: the
caller got 45.

| Routine (`msgh_id`) | Sent by | Request keys | Request descriptors | Success reply | Failures seen |
|---|---|---|---|---|---|
| **203** (`0x400000CB`) | `bootstrap_parent` | `handle` 0, `type` 7, `port` (`0xD000`) | 1: a send right to the bootstrap port the call was made on | `{parent: send right}` (1 descriptor) | — |
| **204** (`0x400000CC`) | `bootstrap_register` | `handle` 0, `flags` 0, `name`, `type` 7, `port` (`0xD000`) | 1: the service's send right | empty dictionary (byte length 4, count 0), not complex | — |
| **205** (`0x400000CD`) | `bootstrap_create_service` | `handle` 0, `name`, `type` 7 | — | not seen | `error` **126** (meaning not established) |
| **206** (`0x400000CE`) | `bootstrap_check_in`, `bootstrap_check_in2` | `handle` 0, `flags`, `name`, `type` 7 | — | `{port: receive right}` (`0x15000`, 1 descriptor received as type 16). The client ends up with the receive right only, no send right | `error` **1103** (name already checked in), **1100** (name belongs to another job) |
| **207** (`0x400000CF`) | `bootstrap_look_up`, `…_look_up2`, `…_look_up3` | `handle` 0, `instance`, `flags`, `name`, `type` 7, `targetpid` | — | `{rec_execcnt, req_pid, port: send right}` | `{rec_execcnt, req_pid, error}` with **1102** |
| **802** (`0x40000322`) | first `xpc_connection_create` (bundled XPC service) in a process | `handle` = own pid, `environment` (dictionary), `paths` (dictionary), `origin` (string: the directory of the main executable), `type` 5, `simhack` (`0xD000`) | 1: the `simhack` send right | not seen | `error` **1** (handle ≠ requester pid), **37** (domain already set up) |
| **803** (`0x40000323`) | same flow, after 802 | `handle` = pid, `type` 5 | — | empty dictionary | `error` 1 (handle ≠ requester) |
| **804** (`0x40000324`) | XPC service look-up (`xpc_connection_create_mach_service`, `xpc_connection_create` with `type` 5, `launchctl`) | `handle`, `flags`, `name`, `type`, `lookup-handle` | — | as for 207 | `{rec_execcnt, req_pid, error}` with **3** (`ESRCH`). `error` 1 for a pid domain that is not the requester's |
| **805** (`0x40000325`) | XPC listener (`…_create_mach_service` with the listener flag) | `handle` 0, `flags` 0, `name`, `type` **6** | — | `{port: receive right}` was accepted by the client (§7) | `error` **1** (`EPERM`: the requester's job does not own the name) |
| **708** (`0x400002C4`) | `launchctl print <domain>/<label>` | `handle`, `shmem` (`0xC000`, 1 MiB), `name`, `type` | 1: shared-memory send right | `{bytes-written: uint64}`. The text is in the shared memory | — |
| **828** (`0x4000033C`) | `launchctl print <domain>` | `handle`, `shmem`, `type` (1 system, 2 user, 5 pid) | 1 | `{bytes-written}` | `error` 1 |

Notes:

- In look-up replies, `rec_execcnt` is a large counter that grows between
  runs, and `req_pid` is the requester's pid. Clients do **not** need them.
  The probe's host mode answered with `{port}` only (and `{error}` only),
  and both were accepted (§7).
- The `simhack` right in 802 was not the requester's task, host, thread,
  or bootstrap port, or its registered port 0. That was checked by sending
  those rights to the probe first and comparing the names. Its identity is
  open (§9).
- `launchctl print` first looks up `com.apple.logd` and
  `com.apple.system.notification_center` (207, flags 8) and
  `com.apple.diagnosticd` (804). It then sends 828 or 708 and prints the
  shared-memory text. It tolerates failure of the three look-ups (§5.3).

### 4.3 Error domains: legacy calls and XPC calls

- **Legacy** routines (203–207, from the `bootstrap_*` API) report
  BOOTSTRAP codes: 1100 `NOT_PRIVILEGED`, 1101 `NAME_IN_USE`, 1102
  `UNKNOWN_SERVICE`, 1103 `SERVICE_ACTIVE` (values from the public
  `servers/bootstrap.h`).
- **XPC** routines (802–805) report errno values: 1 `EPERM`, 3 `ESRCH`, 37
  `EALREADY`.
- The same failure maps to both domains. An unknown name is 1102 for 207
  and 3 for 804. A check-in of a name that is already active is 1103 for
  206, and `launchd_sim` logs it as error 37.

## 5. What `launchd_sim` sends to its host bootstrap

### 5.1 The startup request (708)

`launchd_sim` was started under the probe (§A.3) with the fake bootstrap as
its task bootstrap port. Its **first and only** message to that port:

| Field | Value (received) |
|---|---|
| `msgh_bits` | `0x00111112`: remote 18 (reply, `MAKE_SEND_ONCE`), local 17 (`COPY_SEND`), voucher 17 (macOS) |
| `msgh_size` | **24**: header only, no NDR, no body |
| `msgh_id` | **708** (`0x2C4`), without the `0x40000000` pipe bit |

It is a MIG-style request (reply ID convention: request + 100). The
contrast with the pipe routine 708 in §4.2 is in the high bit: this message
is not a pipe message.

### 5.2 The reply `launchd_sim` accepts

The probe's host mode tried these answers:

| Reply tried | Result |
|---|---|
| **complex, `msgh_id` 808, `msgh_size` 40, 1 port descriptor carrying a new receive right (`MOVE_RECEIVE`), no NDR, no other bytes** | **accepted**: `launchd_sim` continues and creates its domains |
| same plus `NDR_record` (`msgh_size` 48) | rejected |
| same as accepted, but the descriptor carries a send right (`MAKE_SEND`) | rejected |
| simple 36-byte `mig_reply_error_t`, `RetCode` 1102 | rejected |
| simple 36-byte `mig_reply_error_t`, `RetCode` 0 | rejected |
| the real device's `launchd_sim` (asked through the relay) | `mig_reply_error_t` with `RetCode` `0xC02D`: rejected |

In each rejected case, `launchd_sim` logs `could not retrieve service
port` (Critical) and exits with a trap (status signal 5). The receive right
in the accepted reply is `launchd_sim`'s **service port**. This matches
`launchd-sim.md` §2.4: on macOS, it is the receive right for the device
launchd name `com.apple.CoreSimulator.SimDevice.<UDID>`, which the host
user domain holds for the job. The device name is **not** on the wire. The
host knows from the requester which name is meant. The host keeps a send
right to that port. That send right is the host end of the control channel
(`launchd-sim.md` §6.1).

### 5.3 After startup

- With the accepted reply (and §5.4 satisfied), `launchd_sim` creates the
  `system` and `user/501` domains (`launchd.log`: "entering ondemand mode",
  "created", "entering/exiting bootstrap mode") and keeps running. In 10 s
  it sent **nothing more** to the host bootstrap.
- With one guest job (a probe in `Paths`), the job's look-ups of unknown
  names and of host-side names were answered by `launchd_sim` itself with
  1102, and **none reached the host bootstrap**. The host bootstrap
  therefore needs only routine 708 at startup. Host-side names (§6.3 of
  `launchd-sim.md`) exist in the guest only if the host registers them
  through the control channel, which is outside this spec.
- A guest `launchctl print system` job ran to completion under this minimal
  host. It printed the system domain with no services, `properties =
  uncorked | in initial on-demand`, and `in-progress bootstraps = 1`. Its
  three look-ups failed with error 3 in `launchd_sim`'s log. Phase 4c-iii
  can start from this: no further host behavior is required for this
  command.
- `launchd_sim` resolves job paths under the runtime root:
  `ProgramArguments[0]` `/bin/launchctl` is `RR/bin/launchctl`. Job
  `StandardOutPath` paths in `/tmp/…` were written under `DEV/data/tmp/…`.

### 5.4 The holding-tank child (`launchd-sim.md` §9 Q1)

`launchd_sim` requires the variable `XPC_SIMULATOR_HOLDING_TANK_HACK`. Its
value must be the pid of one of **its own child processes**:

| Environment | Result (log line, exit) |
|---|---|
| variable absent | `no child pid` (Critical), trap |
| a pid that is not its child (99999) | `waitpid() returned unexpected result` (Critical), trap |
| the pid of a child that has already exited (a zombie) | success, immediately |
| the pid of a child that exits after 4 s | success. Domain creation waits about 4 s, until the child exits |

`XPC_SIMULATOR_HOLDING_TANK_FD_HACK` was **not** set in the successful runs.
The order was: the 708 exchange, then the wait for the child, then the
domains. For Ycode: before pid 100 executes `launchd_sim`, the VMM must
give it a child process (for example pid 101, already exited and
unreaped). It then passes that pid in the variable.

### 5.5 The real macOS host's reply

The probe could not observe the reply that macOS `launchd` sends to 708
when it serves a real device. The accepted layout in §5.2 is the minimum
that the client takes. A real host reply might contain more (it cannot
contain an NDR record or a body, because those were rejected).

## 6. Legacy MIG bootstrap (level 1, for terminology only)

### 6.1 What the open-source launchd defined

Apple's open-source `launchd-842.92.1` (`src/job.defs`, `liblaunch/libbootstrap.c`)
defines the MIG subsystem `job` with base **400**: `create_server` 400,
`reboot2` 401, `check_in2` 402, `register2` 403, `look_up2` 404,
`send_signal` 405, `parent` 406, and so on. Name arguments are
`c_string[128]`. `bootstrap_check_in` maps to `check_in2(flags 0)`,
`bootstrap_look_up` to `look_up2(pid 0, null UUID, flags 0)`, and
`bootstrap_create_service` to check-in followed by look-up. That version's
server already received libxpc pipe requests on the same port set, through
the pipe "try receive / routine reply" calls in `src/runtime.c`.

### 6.2 What iOS 27.1 uses

None of the 400-series IDs appear. The arguments of the old MIG routines
match keys in the pipe dictionaries: `servicename` → `name`,
`target_pid` → `targetpid`, `instance_id` → `instance`, `flags` →
`flags`. A Ycode bootstrap server must implement the **pipe** routines of
§4. It needs a 400-series MIG server only if some guest binary still sends
those IDs. None did in the captures.

### 6.3 Legacy and XPC look-ups (`launchd-sim.md` §5.1)

On the wire, they differ in two ways:

1. The **routine number**: 207 is legacy, 804 is XPC. Check-in follows the
   same pattern: 206 is legacy, 805 is XPC listener.
2. The **key set**: 207 has `instance` and `targetpid`. 804 has
   `lookup-handle`.

The `flags` key is the caller's value (usually 0). The "flags = 0x1" in
`launchd.log` is added inside `launchd_sim` to mark a legacy request. It is
OR-ed with the wire flags: `launchctl`'s legacy look-ups with wire flags 8
are logged as `0x9`. XPC look-ups are logged with no flags field. XPC
listener check-ins are logged as `0x0`.

## 7. Replies Ycode's host may send (checked against real clients)

The probe's host mode answered the runtime's own `bootstrap_*` and libxpc
calls. It used only the layouts below, and every client accepted them:

| Request | Reply sent | Client result |
|---|---|---|
| 207 found | complex, 1 descriptor (send right, `MAKE_SEND`), dictionary `{port: 0xD000}` (`msgh_size` 72) | `KERN_SUCCESS` and a send right |
| 207 not found | simple, `{error: int64 1102}` (`msgh_size` 64) | 1102 |
| 206 | complex, 1 descriptor (`MOVE_RECEIVE`), `{port: 0x15000}` (72) | `KERN_SUCCESS`. The caller holds a receive right and no send right |
| 804 found or not found | as for 207, or `{error: 3}` | connection created, or "Connection invalid" |
| 805 | as for 206 | listener runs (no immediate error event) |
| 204 | `{error: int64 45}` | 45 |
| `launchd_sim` 708 | §5.2 | `launchd_sim` starts |

The reply header in all cases: remote = the request's reply right with
`MOVE_SEND_ONCE`, local 0, voucher 0, `msgh_id` `0x20000000` (808 for the
MIG 708).

## 8. Requirements for Ycode (derived)

1. **Host bootstrap, phase 4c-ii.** Receive on the host bootstrap port.
   For `msgh_id` 708 with `msgh_size` 24: create a port, keep a send right
   (the control-channel end), and reply as in §5.2. For pipe requests
   (`0x40000000 | n`): decode the dictionary. Answer 207 and 804 with 1102
   or 3, or with `{port}` for names that Ycode provides. Answer 206 and 805
   with a new receive right. Answer anything else with `{error: 45}` (or
   1102 for legacy routines). Log every unknown ID.
2. **Process start.** Install the bootstrap special port before the first
   instruction (§1.3). Give `launchd_sim` a child pid in
   `XPC_SIMULATOR_HOLDING_TANK_HACK` (§5.4).
3. **Parsing rules.** Match keys by name, not position. Accept both
   `?cpx` and `@cpx`. Accept a payload in one OOL descriptor (§2.3). Treat
   unknown tags as a reason to reject the request with an error reply, and
   do not crash.
4. **Writing rules.** Use magic `?cpx`, version 5, and a root dictionary.
   Set the `COMPLEX` bit and the descriptor count to match the
   port-bearing objects, in order.

## 9. Open questions

1. The full reply of macOS `launchd` to 708, and whether it carries
   anything that `launchd_sim` uses later (§5.5).
2. The identity of the `simhack` right in routine 802, and the success
   reply of 802 (the relay could not produce it, because the server checks
   that `handle` is the requester's own pid).
3. The meaning of error 126 for `bootstrap_create_service` (205), and
   whether any runtime component still calls it.
4. The success layout of 805 as `launchd_sim` sends it (the probe produced
   only a host-mode answer and an `EPERM`).
5. The control-channel protocol on the 708 service port (bind session,
   register endpoint, spawn, `launch_sim_*`). It is private between
   `liblaunch_sim` and `launchd_sim` and is not covered here.
6. The XPC connection protocol after look-up (`msgh_id` `0x77303074`, §3.2).
   It is needed later, when Ycode serves XPC services itself.
7. The exact inline/OOL cut-off (§2.3) and the large-data threshold (seen:
   16 384 inline, 16 385 by port).

## Appendix A. Probe and method

### A.1 Files

- `research/experiments/simulator/bootstrap-mitm/bsmitm.c`: the probe (our
  code). It contains the dumper, an XPC decoder and a minimal writer
  written from these captures, the relay, host mode, and the tests.
- `research/experiments/simulator/bootstrap-mitm/build.sh`: builds it with
  `xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator`
  into a directory outside the repo.

### A.2 Modes

| Mode | What it does |
|---|---|
| `spawn <tests>` | Spawns itself with `posix_spawnattr_setspecialport_np(…, TASK_BOOTSTRAP_PORT)` set to the probe's port. Relays every request (§A.4) and records request and reply |
| `child <tests>` | Runs the tests directly (real bootstrap). The `pipe` and `conn` tests send to the probe's own ports |
| `exec <path> …` | Relays for an arbitrary program, for example `RR/bin/launchctl` |
| `host <path> …` | Answers requests itself (§7) |
| `hostfork <path> …` | As host mode, but forks twice so that the program has a child of its own. The variable `XPC_SIMULATOR_HOLDING_TANK_HACK` gets that child's pid (§5.4). The bootstrap port is passed by inheritance across fork and exec |

### A.3 Running `launchd_sim`

The device was a fake one under `/tmp/ycode-R/dev`. Its bootstrap plist was
derived from a real device's plist (read as a file format): a fake UDID
`5C0DE000-0000-4000-8000-000000000001`, device paths moved to
`/tmp/ycode-R/dev`, and `Paths` set to one directory. The environment was
`Bootstrap.Self` plus `XPC_SERVICE_NAME`, `XPC_FLAGS`, `OSLogRateLimit`,
and `USER`. The executable was `RR/sbin/launchd_sim`, with argv
`launchd_sim <plist>`. Run inside the booted iOS 27.1 simulator through
`xcrun simctl spawn`. `launchd_sim` created its TMP directory
`/private/var/tmp/com.apple.CoreSimulator.SimDevice.<UDID>` itself (mode
0700) and wrote `launchd.log` there.

### A.4 Relay limitation

Relayed requests reach the server with the relay's audit token, not the
child's. Pid-checked routines (802, 803, and 804 with `type` 5) therefore
fail with `EPERM` in relay mode. An optional mode rewrites `handle` to the
relay's pid (to see 803 succeed). In replies, `req_pid` is the relay's pid.

## Evidence

| Claim | Level | Source |
|---|---|---|
| BOOTSTRAP error codes 1100–1106 | 1 | public `servers/bootstrap.h` (macOS SDK) |
| Legacy MIG subsystem `job` 400, routine order, `name_t` 128, mapping of public calls, pipe receive in launchd's server loop (§6.1) | 1 | `launchd-842.92.1`: `src/job.defs`, `src/job_types.defs`, `liblaunch/libbootstrap.c`, `liblaunch/bootstrap_priv.h`, `src/runtime.c` (Apple open source, read in scratch) |
| Pipe request and reply envelope, IDs `0x40000000 | n`, `0x20000000`, `0x10000000` (§2.1–2.2) | 3 | probe `spawn lookup/checkin/register/xpc/listen/misc`, `child pipe` |
| Client rejects a wrong reply ID (EIO) | 3 | probe `child pipe` with `YC_REPLY_ID=0x12345` |
| OOL payload and large-data port (§2.3, §3.2) | 3 | probe `child pipe` (sizes 4096–40000) |
| Serialization: magic, version, tags, alignment, lengths, key order, descriptor mapping (§3) | 3 | probe `child pipe` (every type in one dictionary) and every bootstrap capture |
| Routine numbers, keys, replies, and error codes 203–207, 802–805 (§4.2) | 3 | probe `spawn register/checkin/lookup/lookup2/host/xpc/listen/misc/ident,bundled`, `YC_REWRITE_HANDLE` run |
| Routines 708/828 and shared memory | 3 | probe `exec launchctl print system / user/501 / pid/N / user/501/<label>` |
| `simhack` is not the task, host, thread, or bootstrap port or registered[0] | 3 | probe `spawn ident,bundled` (name comparison in the relay's space) |
| Error domains and log flags (§4.3, §6.3) | 3 | probe captures plus the real device's `launchd.log` lines for the probe's requests |
| Bootstrap port read once at start, no startup traffic (§1.3–1.4) | 3 | probe `self` mode (no capture) and `spawn` mode (first message = first test) |
| `launchd_sim` startup message 708 and accepted reply (§5.1–5.2) | 3 | probe `serve`, `exec`, and `host`/`hostfork` runs of `RR/sbin/launchd_sim` with reply variants A/B/C/E and their `launchd.log` |
| No forwarding of guest look-ups to the host. Minimal host sufficient for `launchctl print system` (§5.3) | 3 | probe `hostfork` with job plists for the probe and for `/bin/launchctl`. `launchd.log`, job output files |
| Holding-tank child requirement (§5.4) | 3 | probe `host` (no or fake pid) and `hostfork` (`YC_TANK=exit` and `sleep:4`) runs, `launchd.log` timestamps |
| Host-mode reply layouts accepted (§7) | 3 | probe `host … child found` and `host … child listen` |
| Requirements and design (§8) | — | derived from the above |

Levels 4 and 5 were not used: no runtime or Xcode binary was opened,
listed for symbols, or disassembled. Third-party descriptions of the XPC
format were not consulted. The decoder in the probe was written from our
captures alone. Full dumps: the agent-R scratch directory (`dumps/`).
