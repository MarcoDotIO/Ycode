# Spec: Mach IPC as user space sees it (ports, rights, messages, notifications)

Status: **reference for stage 4** (`docs/SIMULATOR-LINUX.md` §3, stage 5 in
that list: "Mach IPC and bootstrap"). It describes the behavior that Ycode's
VMM must reproduce so that unmodified simulator code (`launchd_sim`,
libdispatch, libxpc, MIG clients) sees a faithful Mach kernel.

Scope:

- The port and right model, user references, and name encoding (§1).
- The message format, dispositions, trailers, the `mach_msg` and
  `mach_msg2` traps, queueing, timeouts, and return codes (§2).
- The kernel-generated notifications (§3).
- Reply ports, special reply ports, vouchers (just enough to stub them),
  and `mach_msg_destroy` (§4).
- MIG wire conventions, so the VMM can answer MIG RPCs on kernel-object
  ports (§5).
- An ordered implementation checklist (§6) and open questions (§7).

Out of scope: the bootstrap/launchd protocol (it is launchd's own protocol,
not xnu's), `kevent` with `EVFILT_MACHPORT` and workloops (a separate spec),
and importance donation / QoS overrides (Ycode may ignore them, §2.13).

Relationship to `specs/simulator/host-libraries.md` §10: the private
Mach-routine traps (`x16 = 0x7963_2000 + n`) stay valid. This spec describes
the *real* Mach behavior that those private traps, the real port traps
(§1.8), and `mach_msg2` must implement. Where Ycode's own `libsystem_kernel`
calls a real trap, the VMM must follow this spec exactly, because other
simulator libraries reach the same traps through exported functions.

Conventions: all sizes and offsets are for **64-bit (arm64) user space**,
little-endian. "Name" means a `mach_port_name_t` (32-bit). `u32`/`u64` are
unsigned little-endian integers. Numbers in `0x…` are hexadecimal. Message
IDs written `0100` are octal, and the decimal value is given beside them.

---

## 1. Port model

### 1.1 Objects and rights

There are two kinds of IPC object:

- A **port**: a kernel message queue. Exactly one **receive right** exists
  for a live port, held by one task's name space or *in transit* inside a
  message.
- A **port set**: a group of receive rights. A receive on the set returns a
  message from any member.

A task's **name space** maps names to *entries*. Each entry holds a bit set
of rights (the "type") and a 16-bit user-reference count (`urefs`).

| Right | `mach_port_right_t` | Type bit (`MACH_PORT_TYPE_*`) | Meaning |
|---|---|---|---|
| send | 0 | `0x00010000` | May send to the port, any number of times |
| receive | 1 | `0x00020000` | May receive; owns the queue |
| send-once | 2 | `0x00040000` | May send exactly one message; then the right is gone |
| port set | 3 | `0x00080000` | Names a port set |
| dead name | 4 | `0x00100000` | What a send or send-once right becomes when its port dies |
| (labelh, obsolete) | 5 | `0x00200000` | Always invalid |
| (number) | 6 | — | First invalid right value |

`MACH_PORT_TYPE(right) = 1 << (right + 16)`. Pseudo-type bits reported by
`mach_port_type`/`mach_port_names`: `0x80000000` dead-name request armed
(`MACH_PORT_TYPE_DNREQUEST`). `0x40000000`/`0x20000000` (send-possible) are
masked out of `mach_port_type` results.

Composite masks: `SEND_RECEIVE = 0x30000`, `SEND_RIGHTS = 0x50000`,
`PORT_RIGHTS = 0x70000`, `PORT_OR_DEAD = 0x170000`, `ALL_RIGHTS = 0x1F0000`.

Special names: `MACH_PORT_NULL = 0`, `MACH_PORT_DEAD = 0xFFFFFFFF`. A name is
*valid* if it is neither. Neither ever denotes an entry.

### 1.2 Entry rules (normative)

1. **One name per port for send and receive.** In one space, all send rights
   and the receive right for a port share **one** name. Getting another send
   right for a port the space already names (by message, by
   `insert_right`, by `MAKE_SEND`) adds to that entry's `urefs` under the
   existing name. The kernel finds it by a reverse (port → name) lookup that
   only considers send and receive rights.
2. **Send-once rights never coalesce.** Each send-once right gets a fresh
   name with `urefs = 1`, even if the space already names the port.
3. **A port set entry** holds only `PORT_SET`. A **dead-name** entry holds
   only `DEAD_NAME`.
4. **What `urefs` counts:**

   | Entry type | `urefs` meaning |
   |---|---|
   | receive only | 0 (reported as 1 by `get_refs` for the receive right) |
   | send (with or without receive) | number of send user references, ≥ 1 |
   | send-once | always 1 |
   | port set | 0 (reported as 1) |
   | dead name | number of dead-name references, ≥ 1 |

5. **Maximum.** `MACH_PORT_UREFS_MAX = 0xFFFF`. An increment that would reach
   or exceed the maximum *pegs* the count at `0xFFFF` instead of failing
   (copyout and `mod_refs` both peg). A pegged count is changed only by a
   delta of exactly `−0xFFFF`. Other deltas on a pegged entry succeed and do
   nothing.
6. **The name is freed** when its last right goes: `urefs` of a send-only
   entry reaches 0, a send-once right is used or deallocated, a receive-only
   entry loses its receive right, a dead name's `urefs` reaches 0, or a port
   set is destroyed.
7. **"Ex-receive" marker.** When an entry that holds send + receive loses the
   receive right (moved away, or destroyed while a port-destroyed request
   exists), the entry stays as a send right and remembers that it used to be
   a receive right. This only suppresses guard exceptions. Ycode can ignore
   it.

### 1.3 Port state the VMM must keep

| Field | Initial value | Used by |
|---|---|---|
| receiver | the creating space and name, or "in transit", or dead | copyout, `ip_in_space` checks |
| send-rights count (`srights`) | 0 (1 with `INSERT_SEND_RIGHT`) | no-senders |
| send-once count (`sorights`) | 0 | status |
| make-send count (`mscount`) | 0 (1 with `INSERT_SEND_RIGHT`) | no-senders message body |
| sequence number (`seqno`) | 0 | trailer, status |
| queue limit (`qlimit`) | 5 (`MACH_PORT_QLIMIT_DEFAULT`) | send blocking |
| queued-message count (`msgcount`) | 0 | full test |
| context (64-bit) | 0, or the `construct` context | context trailer, guard |
| guarded / strict / immovable-receive flags | clear | guard rules |
| port-destroyed request (one send-once right) | none | §3 |
| no-senders request (one send-once right) | none | §3 |
| dead-name requests (table of (name, send-once right)) | empty | §3 |
| port-set memberships | none | receive |
| kind | ordinary, reply, special reply, service, connection, or a VMM kernel object | policies, MIG dispatch |

`srights` counts every send right in existence: in all spaces (counting each
entry once, regardless of its `urefs`) and in transit in messages. Precisely:
it is incremented by `MAKE_SEND` and `COPY_SEND` copyins and by each entry
creation that receives a send right, and decremented when an entry's last
send uref goes, when a moved/copied send right is merged into an existing
entry at copyout, and when a send right in a message is destroyed.

### 1.4 Name encoding and allocation

- `MACH_PORT_INDEX(name) = name >> 8` (24-bit table index).
- The low byte is the **generation byte**. Its two low bits are **always
  `11`**: every name the kernel produces satisfies `(name & 3) == 3`, and the
  kernel *rejects* user-chosen names (`allocate_name`, `insert_right`) whose
  low two bits are not `11` with `KERN_INVALID_VALUE`.
- The upper six bits of the low byte are a 6-bit generation counter.
- Index 0 is reserved (it heads the free list). A user-chosen name with
  index 0 fails with `KERN_FAILURE`.
- **Generation rule.** A table slot starts at generation 63 with a
  "rollover period" of 0. Each time the slot is (re)allocated, the
  generation is advanced by `1 + r`, where `r` (0…3) is the slot's rollover
  setting. When the 6-bit counter overflows, it restarts at 0 and `r` is
  chosen at random. So the **first** name ever given out for index `i` is
  `(i << 8) | 0x03`. Reuse of the slot gives `…07`, `…0B`, … (`r = 0`) or
  `…13`, `…23`, … (`r = 3`).
- **Free-list order.** A new space's first 8 allocations take indices 1…8 in
  order (`0x103`, `0x203`, …, `0x803`). After that, xnu hands out indices in
  a pseudo-random order. A freed slot is pushed on the **head** of the free
  list (LIFO), so the next allocation reuses it with the next generation.
- A user-chosen name must not collide: if the slot is free it is taken
  (generation from the name); if it holds the same name it is reused
  (`KERN_NAME_EXISTS` for a new right, or a merge for `insert_right` of a
  send right to the same port); if it holds a different generation the call
  fails with `KERN_FAILURE`.
- Tables start with 32 entries and grow. `KERN_NO_SPACE` when the table
  cannot grow.

**Ycode's choice (normative for the VMM):** allocate deterministically:
sequential indices from 1, LIFO reuse of freed slots, `r = 0`. This is a
legal xnu behavior (randomization is not observable as a contract). It keeps
the existing fixed name `0x0503` (bootstrap, `host-libraries.md` §10) a
well-formed name (index 5, generation 0). The VMM must reserve the indices it
hands out at process start (task self, bootstrap, host, …) so later
allocations never reuse them.

### 1.5 Port death and lazy dead names

A port dies when its receive right is destroyed and no port-destroyed request
diverts it (§3.4). On death:

1. The port is marked inactive. Every queued message is destroyed (its
   rights are released; each send-once right in it produces a send-once
   notification, each receive right in it is destroyed in turn).
2. Threads blocked receiving on the port (or on a set it was in) wake with
   `MACH_RCV_PORT_CHANGED`. Threads blocked sending to it wake and their
   message is silently destroyed; their `mach_msg` returns success.
3. An armed no-senders request is not fired; its send-once right gets a
   **send-once notification** instead (§3.5).
4. Every armed dead-name request on the port fires a **dead-name
   notification** (§3.2) to its notify port.
5. Port-set memberships are dropped.

Send and send-once entries in other spaces are **not** rewritten at death.
They are converted **lazily**, the next time the space touches the entry
(any lookup that checks liveness: `deallocate`, `mod_refs`, `type`,
`get_refs`, a send, a copyin of the name):

- A send entry becomes a dead name **with the same name and `urefs`**. A
  send-once entry becomes a dead name with `urefs = 1`.
- If the entry had an armed dead-name request, `urefs` is incremented by one
  more (the reference "carried" by the dead-name notification).
- `srights`/`sorights` of the dead port are decremented at this point.

Exception: when a dead send-once right is copied in as a message
**destination** and it has no dead-name request, the copyin succeeds and the
message is silently destroyed (send returns success).

### 1.6 Kernel object ports (VMM-owned)

Ports whose receive right belongs to the kernel (task, thread, host, clock,
semaphore, voucher, and in Ycode the bootstrap port until `launchd_sim`
owns it) are *kernel objects*. A message sent to one is not queued: the
kernel runs the MIG server routine synchronously and sends the reply message
to the request's reply port (§5). The port's `seqno` is still incremented.
`mach_task_self()`, `mach_thread_self()`, and `mach_host_self()` each return
a **send right**; each call adds one `urefs` to the same name (callers are
expected to `mach_port_deallocate` the thread/host names).

### 1.7 Port routines: behavior and errors

The `target`/`task` argument is the caller's task port name. The real traps
(§1.8) return `MACH_SEND_INVALID_DEST` (`0x10000003`) if `target` does not
name the caller's own task; Apple's `libsystem_kernel` then falls back to the
MIG message. Ycode's library only ever passes `mach_task_self()`.

Common errors for every routine: `KERN_INVALID_TASK` (16) for a null or dead
space; `KERN_INVALID_NAME` (15) when a valid name has no entry (or its
generation does not match); `KERN_INVALID_RIGHT` (17) when the entry lacks
the needed right.

| Routine | Behavior | Specific results |
|---|---|---|
| `mach_port_allocate(task, right, *name)` | New receive right (a fresh port, defaults of §1.3), empty port set, or dead name (`urefs` 1) under a kernel-chosen name | `KERN_INVALID_VALUE` (18) for any other right; `KERN_NO_SPACE` (3) |
| `mach_port_allocate_name(task, right, name)` | Same, under a caller-chosen name (§1.4 rules) | `KERN_INVALID_VALUE` if the name is not valid or lacks the `…11` low bits; `KERN_NAME_EXISTS` (13); `KERN_FAILURE` (5) on collision |
| `mach_port_destroy(task, name)` | Removes **all** rights of the name at once (receive → port death unless diverted; send → as if all urefs dropped; send-once → send-once notification; set → set destroyed) | NULL/DEAD name → `KERN_SUCCESS` with no effect; guarded receive with a nonzero context → `KERN_INVALID_RIGHT` (guard exception) |
| `mach_port_deallocate(task, name)` | Drops one uref of a send, send-once, dead-name, or port-set right. Order: port set (destroys it), dead name, send-once (frees the name and sends a **send-once notification** to the port), send (last uref frees the send right; if the space holds no receive right the name is freed). For a send+receive entry with `urefs 1`, only the send right goes | NULL/DEAD → `KERN_SUCCESS`; receive-only entry → `KERN_INVALID_RIGHT`; if the send right turns out dead, it is first converted (§1.5) and the dead-name uref is dropped |
| `mach_port_mod_refs(task, name, right, delta)` | Adds `delta` to the urefs of the named right. Receive: delta must be 0 or −1 (−1 destroys the receive right; remaining send rights become a dead name with the same `urefs`, plus one if a dead-name request was armed, unless a port-destroyed request diverts the port, in which case the entry keeps the send right). Port set: 0 or −1. Send-once: 0 or −1 (−1 frees and sends a send-once notification). Send/dead name: any delta in ±0xFFFF with underflow → error, overflow → peg. Reaching 0 frees the right (§1.2) | `right ≥ 6` → `KERN_INVALID_VALUE`; NULL/DEAD with right send/send-once → `KERN_SUCCESS`, otherwise `KERN_INVALID_NAME`; wrong right → `KERN_INVALID_RIGHT`; bad delta → `KERN_INVALID_VALUE`; guarded receive → `KERN_INVALID_RIGHT`; a send right whose port died → `KERN_INVALID_RIGHT` after converting the entry to a dead name (use `MACH_PORT_RIGHT_DEAD_NAME` then) |
| `mach_port_get_refs(task, name, right, *refs)` | Send/dead name → `urefs`; receive/send-once/port set → 1; right not present on the entry → 0 (success) | `right ≥ 6` → `KERN_INVALID_VALUE`; NULL/DEAD with send/send-once → 1 |
| `mach_port_type(task, name, *type)` | Type bits of the entry (after lazy dead-name conversion) plus `0x80000000` if a dead-name request is armed | NULL → `KERN_INVALID_NAME`; DEAD → `DEAD_NAME` type, success |
| `mach_port_insert_right(task, name, poly, polyPoly)` | Copies in `poly` with disposition `polyPoly` from the caller (§2.4), then copies the resulting right out **under `name`**. Common case `name == poly` with `MAKE_SEND`/`COPY_SEND` adds a send uref to the existing entry (`MAKE_SEND` also increments `mscount`, and `srights` if the entry had no send right) | name not valid or `polyPoly` not 16…21 → `KERN_INVALID_VALUE`; `poly` NULL/DEAD or a dead port → `KERN_INVALID_CAPABILITY` (20); the space already names the port under another name → `KERN_RIGHT_EXISTS` (21); name used by another port → `KERN_NAME_EXISTS`; copyin failures as in §2.4 |
| `mach_port_extract_right(task, name, msgt_name, *poly, *polyPoly)` | Copies the right out of the space "as if sent in a message" and returns it to the caller; via the MIG path the right arrives in the reply message. Result disposition is the received form (16/17/18) | `msgt_name` not 16…21 → `KERN_INVALID_VALUE`; NULL/DEAD name → `KERN_INVALID_RIGHT` |
| `mach_port_construct(task, *options, context, *name)` | Allocates a receive right with options (table below). `options` is a 32-byte `mach_port_options_t`: `u32 flags` @0, `u32 mpl_qlimit` @4, a 16-byte union @8 (`work_interval_port`, service-port-info pointer, or `service_port_name`) | unknown flag bits or not exactly one port-type value → `KERN_INVALID_ARGUMENT` (4); qlimit > 1024 → `KERN_INVALID_VALUE`; `MPO_CONNECTION_PORT` without a service name → `KERN_INVALID_ARGUMENT`; missing entitlement → `KERN_DENIED` (53) |
| `mach_port_destruct(task, name, srdelta, guard)` | Destroys the receive right, first applying `srdelta` (must be ≤ 0) to the entry's send urefs. If the port is guarded, `guard` must equal the context | name invalid → `KERN_INVALID_NAME`; no receive right, or `srdelta ≠ 0` without a send right → `KERN_INVALID_RIGHT`; `srdelta > 0` or underflow → `KERN_INVALID_VALUE`; guard mismatch → `KERN_INVALID_ARGUMENT` |
| `mach_port_guard(task, name, guard, strict)` | Requires the receive right. Fails if the context is already nonzero. Sets context = guard, guarded, strict = `strict` | context already set → `KERN_INVALID_ARGUMENT` |
| `mach_port_unguard(task, name, guard)` | Requires guarded and context == guard; clears context and both flags | not guarded or mismatch → `KERN_INVALID_ARGUMENT` |
| `mach_port_guard_with_flags(…, guard, flags)` | As guard; flags `MPG_STRICT` 0x01, `MPG_IMMOVABLE_RECEIVE` 0x02 | same |
| `mach_port_swap_guard(…, old, new)` | Requires guarded, not strict, context == old; sets context = new | otherwise `KERN_INVALID_ARGUMENT` |
| `mach_port_set_context(task, name, ctx)` / `get_context` | Requires the receive right. Set fails on a strictly guarded port. Get returns 0 for a strictly guarded port | NULL/DEAD name → `KERN_INVALID_RIGHT`; strict set → `KERN_INVALID_ARGUMENT` |
| `mach_port_get_attributes(task, name, flavor, info, *count)` | `*count` is in 32-bit words; the result sets it | `*count` too small → `KERN_FAILURE`; unknown flavor → `KERN_INVALID_ARGUMENT` |
| `mach_port_set_attributes(task, name, flavor, info, count)` | | as above |
| `mach_port_request_notification(task, name, id, sync, notify, notifyPoly, *previous)` | See §3.6 | |
| `mach_port_move_member(task, member, after)` | `after` = a set: removes `member` from **every** set it is in, then adds it to `after`. `after` = NULL: removes it from all sets | member NULL/DEAD or `after` DEAD → `KERN_INVALID_RIGHT`; member not a receive right / `after` not a set → `KERN_INVALID_RIGHT`; `after` NULL and not in any set → `KERN_NOT_IN_SET` (12) |
| `mach_port_insert_member(task, name, pset)` | Adds the receive right to the set **without** leaving other sets (a port may be in several sets) | either name invalid → `KERN_INVALID_RIGHT`; already a member → `KERN_ALREADY_IN_SET` (11) |
| `mach_port_extract_member(task, name, pset)` | Removes it from that one set | not a member → `KERN_NOT_IN_SET` |
| `mach_port_set_mscount`, `set_seqno`, `peek`, `names`, `get_set_status`, `space_info`, `kobject*`, `dnrequest_info` | Diagnostics and rare calls. MIG only | — |

`ipc_port_translate_receive`-style lookups used by the receive-right
routines return `KERN_INVALID_NAME` for no entry and `KERN_INVALID_RIGHT` for
an entry without a receive right.

**`mach_port_construct` flags** (`MPO_*`, `osfmk/mach/port.h`):

| Flag | Value | Effect |
|---|---|---|
| `CONTEXT_AS_GUARD` | 0x01 | Guard the new port with `context` (strict if `STRICT`) |
| `QLIMIT` | 0x02 | Set `qlimit = mpl_qlimit` (≤ 1024) |
| `TEMPOWNER` | 0x04 | Importance bookkeeping only |
| `IMPORTANCE_RECEIVER` | 0x08 | Importance only |
| `INSERT_SEND_RIGHT` | 0x10 | Entry gets send + receive, `urefs 1`; `srights = mscount = 1` |
| `STRICT` | 0x20 | Strict guard |
| `DENAP_RECEIVER` | 0x40 | Importance only |
| `IMMOVABLE_RECEIVE` | 0x80 | The receive right can never be moved |
| `FILTER_MSG` | 0x100 | Message filtering (ignore) |
| `TG_BLOCK_TRACKING` | 0x200 | Graphics-server only (`KERN_DENIED` otherwise) |
| `ENFORCE_REPLY_PORT_SEMANTICS` | 0x2000 | Makes a *strong* service port, except in simulated processes |
| Port type field (exactly one) | bits `0x1DC00` | `MPO_PORT` 0, `SERVICE_PORT` 0x400, `CONNECTION_PORT` 0x800, `REPLY_PORT` 0x1000, `WEAK_REPLY_PORT` 0x4000, `NOTIFICATION_PORT` 0x4400, `EXCEPTION_PORT` 0x8000, `CONNECTION_PORT_WITH_PORT_ARRAY` 0x10000 |

For a **simulated** process (Ycode's case) xnu turns `MPO_REPLY_PORT` into a
*weak* reply port and every service port into a *weak* service port, and the
reply-port enforcement policies do not apply. Ycode may therefore treat every
port type as an ordinary port, with one exception: copyin from a reply port
(§4.1) only accepts send-once dispositions.

**Attribute flavors:**

| Flavor | Value | Count (words) | get | set |
|---|---|---|---|---|
| `MACH_PORT_LIMITS_INFO` | 1 | 1 | `{u32 qlimit}`; NULL/DEAD name → count 0, success | `qlimit` ≤ 1024 else `KERN_INVALID_VALUE`; raising it wakes blocked senders |
| `MACH_PORT_RECEIVE_STATUS` | 2 | 10 | `mach_port_status_t` (below) | — (`KERN_INVALID_ARGUMENT`) |
| `MACH_PORT_DNREQUESTS_SIZE` | 3 | 1 | number of dead-name request slots | accepted, no effect |
| `MACH_PORT_TEMPOWNER` | 4 | — | — | importance; accepted |
| `MACH_PORT_IMPORTANCE_RECEIVER` | 5 | — | — | accepted |
| `MACH_PORT_DENAP_RECEIVER` | 6 | — | — | accepted |
| `MACH_PORT_INFO_EXT` | 7 | 17 | status + `u32 boost_cnt` + 6 reserved words | — |
| `MACH_PORT_GUARD_INFO` | 8 | 2 | (assert-only) | — |
| `MACH_PORT_SERVICE_THROTTLED` | 9 | 1 | service ports only, else `KERN_INVALID_CAPABILITY` | same |

`mach_port_status_t` (40 bytes, ten `u32`): `mps_pset` (1 if in any set),
`mps_seqno`, `mps_mscount`, `mps_qlimit`, `mps_msgcount`, `mps_sorights`,
`mps_srights` (boolean: `srights > 0`), `mps_pdrequest` (boolean),
`mps_nsrequest` (boolean), `mps_flags` (`0x02` guarded, `0x04` strict,
`0x40` immovable receive, `0x01/0x08/0x20` importance).

### 1.8 Trap numbers and MIG IDs

Real Mach traps for port operations (from `data/mach-traps.json`; `x16 = −N`,
arguments in `x0…`, `kern_return_t` in `x0`, no carry):

| Trap | Name | Arguments |
|---|---|---|
| −16 | `_kernelrpc_mach_port_allocate_trap` | target, right, `name*` |
| −18 | `…deallocate_trap` | target, name |
| −19 | `…mod_refs_trap` | target, name, right, delta |
| −20 | `…move_member_trap` | target, member, after |
| −21 | `…insert_right_trap` | target, name, poly, polyPoly |
| −22 | `…insert_member_trap` | target, name, pset |
| −23 | `…extract_member_trap` | target, name, pset |
| −24 | `…construct_trap` | target, `options*`, context (u64), `name*` |
| −25 | `…destruct_trap` | target, name, srdelta, guard (u64) |
| −26 | `mach_reply_port` | — (returns a name) |
| −27 / −28 / −29 | `thread_self_trap` / `task_self_trap` / `host_self_trap` | — (return a name, §1.6) |
| −31 | `mach_msg_trap` | §2.7 |
| −32 | `mach_msg_overwrite_trap` | §2.7 |
| −40 | `…get_attributes_trap` | target, name, flavor, `info*`, `count*` (in/out, clamped to 17) |
| −41 | `…guard_trap` | target, name, guard, strict |
| −42 | `…unguard_trap` | target, name, guard |
| −47 | `mach_msg2_trap` | §2.7 |
| −50 | `thread_get_special_reply_port` | — (returns a name, §4.2) |
| −70 | `host_create_mach_voucher_trap` | host, recipes, size, `voucher*` (§4.3) |
| −72 | `mach_voucher_extract_attr_recipe_trap` | voucher, key, recipe, `size*` |
| −76 | `…type_trap` | target, name, `type*` |
| −77 | `…request_notification_trap` | target, name, msgid, sync, notify, notifyPoly, `previous*` |

Trap-specific rules: out-pointers are written with copyout (a fault returns
the copyout error). `request_notification_trap` requires `notifyPoly` to
copy in as a send-once right (`MAKE_SEND_ONCE` or `MOVE_SEND_ONCE`), else it
returns `MACH_SEND_INVALID_DEST`; a NULL/DEAD `notify` is passed through
as-is; the previous send-once right, if any, is copied out under a new name
(DEAD if its port died).

MIG subsystem `mach_port` = **3200**. Request IDs in definition order:
names 3200, type 3201, rename 3202, allocate_name 3203, allocate 3204,
destroy 3205, deallocate 3206, get_refs 3207, mod_refs 3208, peek 3209,
set_mscount 3210, get_set_status 3211, move_member 3212,
request_notification 3213, insert_right 3214, extract_right 3215,
set_seqno 3216, get_attributes 3217, set_attributes 3218, allocate_qos 3219,
allocate_full 3220, task_set_port_space 3221, get_srights 3222,
space_info 3223, dnrequest_info 3224, kernel_object 3225,
insert_member 3226, extract_member 3227, get_context 3228,
set_context 3229, kobject 3230, construct 3231, destruct 3232, guard 3233,
unguard 3234, space_basic_info 3235, special_reply_port_reset_link 3236,
guard_with_flags 3237, swap_guard 3238, kobject_description 3239,
is_connection_for_service 3240, get_service_port_info 3241,
assert_attributes 3242. Replies are +100 (§5).

---

## 2. Messages

### 2.1 Header (`mach_msg_header_t`, 24 bytes)

| Offset | Size | Field | Send meaning | Receive meaning |
|---|---|---|---|---|
| 0 | 4 | `msgh_bits` | §2.2 | §2.5 |
| 4 | 4 | `msgh_size` | Bytes sent; header + body + descriptors + inline data; multiple of 4 | Size of the received message *without* trailer |
| 8 | 4 | `msgh_remote_port` | Destination name | The reply right's name (or 0/DEAD) |
| 12 | 4 | `msgh_local_port` | Reply name | The receiver's name for the destination (or 0/DEAD) |
| 16 | 4 | `msgh_voucher_port` | Voucher name (§4.3) | Voucher name or 0 |
| 20 | 4 | `msgh_id` | Uninterpreted 32-bit ID | Same value |

`mach_msg_base_t` = header + `mach_msg_body_t` (`u32
msgh_descriptor_count` at offset 24) = 28 bytes. Only complex messages have
the body word. Descriptors start at offset 28 and are packed with 4-byte
alignment, so a 64-bit field inside a descriptor is generally **not 8-byte
aligned** in guest memory.

### 2.2 `msgh_bits`

| Bits | Mask | Meaning |
|---|---|---|
| 0–4 | `0x0000001F` | Remote (destination) disposition |
| 8–12 | `0x00001F00` | Local (reply) disposition |
| 16–20 | `0x001F0000` | Voucher disposition |
| 28 | `0x10000000` | `IMPHOLDASRT` (user-private importance hint) |
| 29 | `0x20000000` | `RAISEIMP` (importance; set by the kernel) |
| 31 | `0x80000000` | `MACH_MSGH_BITS_COMPLEX`: body + descriptors present |

On send, the kernel keeps only `0x801F1F1F` (`MACH_MSGH_BITS_USER`); other
bits are silently cleared. `MACH_MSGH_BITS(remote, local) = remote |
(local << 8)`; with voucher: `| (voucher << 16)`.

### 2.3 Descriptors (64-bit user layout)

The **descriptor type is always the byte at offset 11** of a descriptor,
whatever its size. Port descriptors are 12 bytes; every other kind is 16
bytes in a 64-bit task. The kernel walks descriptors by reading the type
byte and advancing 12 or 16 bytes.

| Type value | Kind | Size | Layout |
|---|---|---|---|
| 0 | `MACH_MSG_PORT_DESCRIPTOR` | 12 | @0 `u32 name`; @4 `u32` pad; @8 `u16` pad; @10 `u8 disposition`; @11 `u8 type` |
| 1 | `MACH_MSG_OOL_DESCRIPTOR` | 16 | @0 `u64 address`; @8 `u8 deallocate`; @9 `u8 copy`; @10 `u8` pad; @11 `u8 type`; @12 `u32 size` |
| 2 | `MACH_MSG_OOL_PORTS_DESCRIPTOR` | 16 | @0 `u64 address` (array of `u32` names); @8 `u8 deallocate`; @9 `u8 copy`; @10 `u8 disposition`; @11 `u8 type`; @12 `u32 count` |
| 3 | `MACH_MSG_OOL_VOLATILE_DESCRIPTOR` | 16 | As OOL |
| 4 | `MACH_MSG_GUARDED_PORT_DESCRIPTOR` | 16 | @0 `u64 context`; @8 `u16 flags`; @10 `u8 disposition`; @11 `u8 type`; @12 `u32 name` |

(The C union `mach_msg_descriptor_t` is 16 bytes, but the wire layout uses
the per-kind size above.)

`copy` values: `MACH_MSG_PHYSICAL_COPY` 0, `MACH_MSG_VIRTUAL_COPY` 1,
`MACH_MSG_ALLOCATE` 2, `MACH_MSG_OVERWRITE` 3 (deprecated). On send only 0
and 1 are accepted (else `MACH_SEND_INVALID_TYPE`).

Guard flags: `MACH_MSG_GUARD_FLAGS_IMMOVABLE_RECEIVE` 0x1,
`…_UNGUARDED_ON_SEND` 0x2, mask 0x3.

Send-side descriptor rules:

- **Port** (type 0): `name` may be NULL or DEAD (carried as-is, no right).
  Otherwise copied in with `disposition` (§2.4). Failure →
  `MACH_SEND_INVALID_RIGHT`.
- **OOL memory** (1, 3): `size` bytes at `address` are captured at send
  time (copy-on-write or eager copy; the receiver must never see later
  writes by the sender). `deallocate = 1` removes the range from the
  sender's address space as part of the send. `size 0` carries nothing.
  Bad address → `MACH_SEND_INVALID_MEMORY`.
- **OOL ports** (2): `count` names at `address` are each copied in with the
  same disposition; NULL/DEAD entries are carried as-is; any failure
  releases the ones already copied and fails the send with
  `MACH_SEND_INVALID_RIGHT`. `deallocate = 1` frees `count × 4` bytes at
  `address` in the sender. Unreadable array → `MACH_SEND_INVALID_MEMORY`.
- **Guarded port** (4): only `disposition = MOVE_RECEIVE` (else
  `MACH_SEND_INVALID_TYPE`); flags must be nonzero, within the mask, and if
  `UNGUARDED_ON_SEND` is set the context must be 0 (else
  `MACH_SEND_INVALID_TYPE`). The port's guard must match `context`, or the
  port must be unguarded when `UNGUARDED_ON_SEND` is set (else failure).
- Any other type value → `MACH_SEND_INVALID_TYPE`. Not enough bytes for the
  declared descriptor count → `MACH_SEND_MSG_TOO_SMALL`.

### 2.4 Dispositions and copyin (send side)

| Value | Name | Sender must hold | Effect on the sender's entry | Carried as (received type) |
|---|---|---|---|---|
| 16 | `MOVE_RECEIVE` | receive | Receive right leaves the space. Entry keeps its send rights if any, else the name is freed (an armed dead-name request on it is cancelled → port-deleted notification). The port is "in transit"; its guard is cleared unless it is immovable | 16 `PORT_RECEIVE` |
| 17 | `MOVE_SEND` | send | `urefs − 1`; at 0 the send right leaves (name freed if no receive right; armed dead-name request → port-deleted notification) | 17 `PORT_SEND` |
| 18 | `MOVE_SEND_ONCE` | send-once | Name freed (armed request → port-deleted notification) | 18 `PORT_SEND_ONCE` |
| 19 | `COPY_SEND` | send | None; `srights + 1` | 17 |
| 20 | `MAKE_SEND` | receive | None; `mscount + 1`, `srights + 1` | 17 |
| 21 | `MAKE_SEND_ONCE` | receive | None; `sorights + 1` | 18 |
| 22 | `COPY_RECEIVE` | — | Invalid | — |
| 24–26 | `DISPOSE_*` | — | Invalid in messages | — |
| 15 | `MACH_MSG_TYPE_PORT_NAME` | — | MIG type code for a plain name; never a disposition | — |

Dead rights: `COPY_SEND`/`MOVE_SEND`/`MOVE_SEND_ONCE` of a name whose port
has died is converted (§1.5). The same applies to a name that already is a
dead name. Then:

- as the **reply** or in a **descriptor** (port, OOL ports) it copies in as
  `MACH_PORT_DEAD` (a move consumes one dead-name uref, a copy consumes
  none), and the receiver sees `MACH_PORT_DEAD`;
- as the **destination** it fails with `MACH_SEND_INVALID_DEST`;
- `mach_port_extract_right` also yields `MACH_PORT_DEAD`;
  `mach_port_insert_right` then fails with `KERN_INVALID_CAPABILITY`.

Header slot rules (checked in this order; all of these leave the space
untouched):

1. Reply: disposition 0 requires reply name 0, else `MACH_SEND_INVALID_HEADER`.
   A nonzero reply disposition must be 17…21, else
   `MACH_SEND_INVALID_HEADER`. A reply name of NULL or DEAD with a nonzero
   disposition is carried as-is.
2. Voucher: disposition must be 0, `MOVE_SEND`, or `COPY_SEND`, and the name
   must not be DEAD, else `MACH_SEND_INVALID_VOUCHER`.
3. Destination: disposition must be 17…21 (`MOVE_RECEIVE` is not allowed)
   else `MACH_SEND_INVALID_HEADER`; the name must be valid else
   `MACH_SEND_INVALID_DEST`.
4. Same name in two slots: dest == voucher requires the dest disposition to
   be `MOVE_SEND`/`COPY_SEND` (else `MACH_SEND_INVALID_DEST`). dest == reply
   forbids `MOVE_SEND_ONCE` in either slot (`MACH_SEND_INVALID_DEST`). A
   valid reply name equal to the voucher name → `MACH_SEND_INVALID_REPLY`.
   When dest and reply (or voucher) name the same send right with
   `MOVE_SEND`+`MOVE_SEND`, the entry must hold ≥ 2 urefs.
5. Lookups: a nonzero voucher name must name a send right to a **voucher**
   object, else `MACH_SEND_INVALID_VOUCHER`. The destination must name a
   port right (send, send-once, or receive), else `MACH_SEND_INVALID_DEST`.
   The reply must name a port right or dead name that satisfies its
   disposition, else `MACH_SEND_INVALID_REPLY`.
6. The destination copyin itself fails → `MACH_SEND_INVALID_DEST`.

The header copyin is **atomic**: it either succeeds completely or leaves
every right as it was.

### 2.5 Copyout (receive side)

**Header.** The received header is rewritten as follows:

- `msgh_bits` = (other bits kept, including `COMPLEX`) | remote = the
  *reply's* received type (17 or 18, or 0) | local = the *destination's*
  received type (17 or 18) | voucher = 17 if a voucher is delivered, else 0.
  The remote and local fields are **swapped** compared with what was sent.
- `msgh_remote_port` = the reply right, copied out into the receiver: a send
  right merges into an existing entry for that port (§1.2), a send-once right
  gets a new name. If the reply port died in transit → `MACH_PORT_DEAD`;
  sent as NULL → 0.
- `msgh_local_port` = the destination. The destination right carried by the
  message is **consumed**, not given to the receiver: if the receiving space
  holds the receive right, the field is that name; if the receive right is
  elsewhere, 0; if the port is dead, `MACH_PORT_DEAD`.
- `msgh_voucher_port`: if the receive did **not** pass `MACH_RCV_VOUCHER`,
  any voucher is released, the voucher disposition is cleared, and the field
  is 0. With `MACH_RCV_VOUCHER`, the voucher send right is copied out
  (merging) and its name is returned. If the sender's voucher disposition was
  0, the field's original 32-bit value is delivered unchanged (legacy
  "reserved field" round trip).
- `msgh_size` = the received size (header 24 + body + user descriptors +
  inline data).

**Descriptors.** Copyout continues past errors and ORs error bits (§2.12):

- Port: copied out like the reply (receive rights get a name and the port
  enters the space; send rights merge; send-once rights get a new name). A
  dead port → `MACH_PORT_DEAD`. No room → name 0 and `MACH_MSG_IPC_SPACE`.
  The received disposition is 16/17/18.
- OOL memory: mapped at a **new, kernel-chosen address** in the receiver
  (the sender's `address` is never reused). `size` is the byte size. The
  received `deallocate` field is 1 if `copy == VIRTUAL_COPY`, else 0; `copy`
  is as sent. Mapping failure → address 0, size 0, `MACH_MSG_VM_SPACE` (or
  `MACH_MSG_VM_KERNEL`).
- OOL ports: a new zero-filled region of `count × 4` bytes is allocated in
  the receiver, and each right is copied out into it as a name. The received
  descriptor has `deallocate = 1`, `copy = VIRTUAL_COPY`.
- Guarded port: delivered only if the receive passed `MACH_RCV_GUARDED_DESC`
  (0x1000). Otherwise the right is **destroyed** and the descriptor has name
  0, context 0. When delivered with `IMMOVABLE_RECEIVE`, the receiver's new
  receive right is guarded with context = the receive buffer's address
  (reported in the descriptor's `context`) and marked immovable.

Received OOL regions and OOL port arrays belong to the receiver, who frees
them with `vm_deallocate`/`mach_vm_deallocate`.

### 2.6 Trailers

Every received message is followed **immediately** (at offset `msgh_size`,
which is a multiple of 4) by a trailer. The trailer is not counted in
`msgh_size`. Its size is chosen by the receive options:

| `MACH_RCV_TRAILER_ELEMENTS(n)` (bits 24–27 of the option) | n | Trailer | Size |
|---|---|---|---|
| `NULL` | 0 | type + size | 8 |
| `SEQNO` | 1 | + `msgh_seqno` | 12 |
| `SENDER` | 2 | + `security_token_t` (format 0 trailer) | 20 |
| `AUDIT` | 3 | + `audit_token_t` | 52 |
| `CTX` | 4 | + `mach_port_context_t` | 60 |
| `AV` | 7 | + `msgh_ad`, `msgh_labels` | 68 |
| `LABELS` | 8 | (= max) | 68 |
| other | 5, 6, 9–15 | max | 68 |

`MACH_RCV_TRAILER_TYPE(t)` (bits 28–31) selects the format; only format 0
exists and the kernel does not validate this field.

Maximum trailer layout (`mach_msg_mac_trailer_t`, 68 bytes):

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 4 | `msgh_trailer_type` | 0 (`MACH_MSG_TRAILER_FORMAT_0`) |
| 4 | 4 | `msgh_trailer_size` | The requested size from the table |
| 8 | 4 | `msgh_seqno` | The port's sequence number for this message |
| 12 | 8 | `msgh_sender` | `{uid, gid}` of the sender (effective) |
| 20 | 32 | `msgh_audit` | `val[0]` audit uid, `[1]` euid, `[2]` egid, `[3]` ruid, `[4]` rgid, `[5]` pid, `[6]` audit session id, `[7]` pid version |
| 52 | 8 | `msgh_context` | The destination port's context at receive time (unaligned `u64`) |
| 60 | 4 | `msgh_ad` | 0 |
| 64 | 4 | `msgh_labels.sender` | 0 |

Kernel-originated messages (notifications, MIG replies from kernel objects)
carry sender `{0, 1}` and an all-zero audit token. Only the requested number
of trailer bytes is written to the user buffer.

Sequence numbers: each port has a counter starting at 0. Each message taken
off the queue (or handed directly to a waiting receiver, or consumed by a
kernel object) gets the current value and the counter increments.
`MACH_RCV_LARGE` probes do not consume a number.

`MACH_SEND_TRAILER` (0x20000) is accepted on send and ignored.

### 2.7 The traps

**`mach_msg_trap` (−31)** and **`mach_msg_overwrite_trap` (−32)** (legacy;
xnu keeps them for macOS only, and Apple's own `libsystem_kernel` no longer
uses them):

| Reg | −31 | −32 |
|---|---|---|
| x0 | `msg` (header address) | same |
| x1 | `option` (32-bit) | same |
| x2 | `send_size` | same |
| x3 | `rcv_size` | same |
| x4 | `rcv_name` | same |
| x5 | `timeout` (ms) | same |
| x6 | `priority` (with `MACH_SEND_OVERRIDE`) or the sync-wait destination name (receive-only with `MACH_RCV_SYNC_WAIT`) | same |
| x7 | — | `rcv_msg` (receive buffer; 0 = use `msg`) |

**`mach_msg2_trap` (−47)** — the primary primitive. Eight 64-bit arguments,
each "low 32 | high 32 << 32":

| Reg | Content |
|---|---|
| x0 | `data`: the message (scalar) or an array of `mach_msg_vector_t` (vector) |
| x1 | `options` (64-bit `mach_msg_option64_t`) |
| x2 | low: `msgh_bits`; high: `send_size` (scalar) or **send vector count** (vector) |
| x3 | low: `msgh_remote_port`; high: `msgh_local_port` |
| x4 | low: `msgh_voucher_port`; high: `msgh_id` |
| x5 | low: descriptor count (the library copies it from the body word when the bits say complex and sending, else passes 0; the kernel uses this register value, not the word in memory); high: `rcv_name` |
| x6 | low: `rcv_size` (scalar) or **receive vector count** (vector); high: `priority` |
| x7 | `timeout` (ms; low 32 bits used) |

The header fields in x2–x5 are **authoritative** for the send; the kernel
builds the header from these registers, not from memory, and copies only the
descriptors and data from memory (starting at `data + 28` for a complex
message, `data + 24` otherwise; vector mode uses `msgv_data` instead of
`data`). The legacy traps read the header from memory. With
`MACH_RCV_SYNC_WAIT` on a receive-only call, the low half of x3 is the
sync-wait destination name.

`mach_msg_vector_t` (24 bytes): @0 `u64 msgv_data`, @8 `u64 msgv_rcv_addr`
(0 = receive into `msgv_data`), @16 `u32 msgv_send_size`, @20 `u32
msgv_rcv_size`. Vector 0 is the message; optional vector 1 is the auxiliary
data block, which starts with `mach_msg_aux_header_t` (`u32 msgdh_size`, `u32
reserved`) and is at most 1024 bytes. Vector count 0 or > 2 is an error
(`MACH_SEND_MSG_TOO_SMALL`/`MACH_SEND_INVALID_DATA` on send,
`MACH_RCV_INVALID_ARGUMENTS` on receive). A receive with an aux vector always
gets at least an empty aux header (`msgdh_size = 0`) as an end marker; aux
data that does not fit a receiver without an aux buffer is silently dropped.

**Option bits** (the low 32 bits are shared by both traps):

| Option | Value | Meaning |
|---|---|---|
| `MACH_SEND_MSG` | 0x1 | Do a send |
| `MACH_RCV_MSG` | 0x2 | Do a receive (after the send) |
| `MACH_RCV_LARGE` | 0x4 | Too-large message stays queued; report its size (§2.10) |
| `MACH_RCV_LARGE_IDENTITY` | 0x8 | With `RCV_LARGE`: also report which port had it |
| `MACH_SEND_TIMEOUT` | 0x10 | `timeout` applies to a send blocked on a full queue |
| `MACH_SEND_OVERRIDE` | 0x20 | `priority` is a QoS override (ignorable) |
| `MACH_SEND_INTERRUPT` | 0x40 | Library-only: do not retry `MACH_SEND_INTERRUPTED` |
| `MACH_SEND_NOTIFY` | 0x80 | Arm send-possible notification (rare) |
| `MACH_RCV_TIMEOUT` | 0x100 | `timeout` applies to the receive |
| `MACH_MSG_STRICT_REPLY` | 0x200 | Strict reply checking (ignorable) |
| `MACH_RCV_INTERRUPT` | 0x400 | Library-only: do not retry `MACH_RCV_INTERRUPTED` |
| `MACH_RCV_VOUCHER` | 0x800 | Willing to receive a voucher |
| `MACH_RCV_GUARDED_DESC` | 0x1000 | Willing to receive guarded port descriptors |
| `MACH_RCV_SYNC_WAIT` | 0x4000 | Sync IPC linkage (ignorable, §4.2) |
| `MACH_RCV_SYNC_PEEK` | 0x8000 | Sync peek (ignorable) |
| `MACH_SEND_FILTER_NONFATAL` | 0x10000 | (ignorable) |
| `MACH_SEND_TRAILER` | 0x20000 | Ignored |
| `MACH_SEND_NOIMPORTANCE` | 0x40000 | Ignorable |
| `MACH_SEND_SYNC_OVERRIDE` | 0x100000 | Ignorable |
| `MACH_SEND_PROPAGATE_QOS` | 0x200000 | Ignorable |
| `MACH_SEND_SYNC_BOOTSTRAP_CHECKIN` | 0x800000 | Ignorable |
| `MACH_RCV_TRAILER_ELEMENTS(n)` | `n << 24` | §2.6 |
| `MACH_RCV_TRAILER_TYPE(t)` | `t << 28` | §2.6 |
| `MACH64_MSG_VECTOR` | `1 << 32` | `data` is a vector array |
| `MACH64_SEND_KOBJECT_CALL` | `1 << 33` | Destination must be a kernel object |
| `MACH64_SEND_MQ_CALL` | `1 << 34` | Destination must be an ordinary message queue |
| `MACH64_SEND_ANY` | `1 << 35` | Old-simulator escape; only honored on macOS |
| `MACH64_SEND_DK_CALL` | `1 << 36` | DriverKit object |

`mach_msg2` "CFI" rules for a send (enforced by xnu):

1. Exactly one of `KOBJECT_CALL`, `MQ_CALL`, `DK_CALL` (and on macOS
   `SEND_ANY`) must be set, else `MACH_SEND_INVALID_OPTIONS` (`0x10000013`).
2. `MSG_VECTOR` requires `MQ_CALL` (or `SEND_ANY`), else
   `MACH_SEND_INVALID_OPTIONS`.
3. After header copyin: a kernel-object destination requires `KOBJECT_CALL`;
   a kernel-object call that is send-only (no `RCV_MSG`) and carries a
   reply port is refused; an ordinary port requires `MQ_CALL`. Mismatch →
   `MACH_SEND_INVALID_OPTIONS` and the header rights are destroyed (this is a
   post-copyin failure, §2.8 step 7).

Apple's libraries set `MQ_CALL` for `mach_msg()` and `KOBJECT_CALL` for MIG
calls to kernel servers (`mach_msg2_internal`, imported directly by a few
simulator images). **Ycode recommendation:** implement the rules but treat
a VMM-implemented service port that stands in for a user-space server (the
bootstrap port before `launchd_sim` owns it) as an ordinary queue for this
check.

Timeouts are in **milliseconds**. `timeout == 0` with the matching
`*_TIMEOUT` option means "do not block": the operation fails immediately with
`MACH_SEND_TIMED_OUT`/`MACH_RCV_TIMED_OUT` if it would block. Without the
option, the operation blocks indefinitely.

The library-only bits `SEND_INTERRUPT`/`RCV_INTERRUPT` are stripped by
`libsystem_kernel` before the trap. When the trap returns
`MACH_SEND_INTERRUPTED` the library retries the same call; when it returns
`MACH_RCV_INTERRUPTED` it retries a receive-only call (send size 0,
`SEND_MSG` and `RCV_SYNC_WAIT` cleared).

### 2.8 Send: order of operations (normative)

1. **Size checks** (nothing changed on failure): `send_size < 24` or not a
   multiple of 4 → `MACH_SEND_MSG_TOO_SMALL`; `send_size >
   IPC_KMSG_MAX_BODY_SPACE` (= 50,331,580: 48 MiB − 68) →
   `MACH_SEND_TOO_LARGE`. Complex with `send_size < 28` →
   `MACH_SEND_MSG_TOO_SMALL`; descriptor count > `(send_size − 28) / 12` →
   `MACH_SEND_MSG_TOO_SMALL`; a simple message with a nonzero descriptor count
   (only possible through `mach_msg2`) → `MACH_SEND_TOO_LARGE`.
2. **Copy the message in.** Fault → `MACH_SEND_INVALID_DATA`. Walk the
   descriptors (§2.3): overrun → `MACH_SEND_MSG_TOO_SMALL`, bad type → 
   `MACH_SEND_INVALID_TYPE`, bad OOL copy option or bad guarded descriptor →
   `MACH_SEND_INVALID_TYPE`. More than 16,383 port rights in total →
   `MACH_SEND_TOO_LARGE`. Too much OOL memory → `MACH_MSG_VM_KERNEL`.
3. **Header rights** (§2.4). Failure → the error, nothing changed.
4. **Policy checks** (mach_msg2 CFI, reply-port rules). Failure → header
   rights are destroyed, error returned.
5. **Body rights and memory**, descriptor by descriptor. On failure
   (`MACH_SEND_INVALID_RIGHT`, `MACH_SEND_INVALID_MEMORY`,
   `MACH_MSG_VM_KERNEL`, `MACH_SEND_NO_BUFFER`) the header rights **and** the
   descriptors already processed are destroyed (destroying a send-once right
   produces a send-once notification; destroying a moved receive right
   destroys the port). The sender has lost them.
6. **Circularity**: if a receive right in the message would end up (directly
   or through a chain of in-transit receive rights) inside its own queue,
   the message is destroyed and the send **returns success**.
7. **Deliver** (§2.9):
   - Destination dead → message destroyed (except the destination right),
     **success**.
   - Kernel object → VMM runs the server routine, the reply is sent to the
     reply port, **success**.
   - Ordinary port → enqueue or hand off; may block on a full queue.
8. **Send failure after step 5** (`MACH_SEND_TIMED_OUT`,
   `MACH_SEND_INTERRUPTED`, `MACH_SEND_NO_BUFFER`, policy errors): the
   message is **pseudo-received** back into the sender's buffer: every right
   and memory region is copied out into the sender's space **without**
   swapping remote/local (the header keeps destination in
   `msgh_remote_port`, reply in `msgh_local_port`, with the *received*
   dispositions 16/17/18; a `COPY_SEND` voucher is restored as `COPY_SEND`
   and its extra right dropped). OOL memory reappears at new addresses. The
   return value is the send error ORed with any copyout error bits.
   Consequence: a `MAKE_SEND` the sender used is now a real send right it
   must deallocate (`mach_msg_destroy` does this).

So, from the caller's point of view:

| Result | Rights and memory |
|---|---|
| `MACH_SEND_MSG_TOO_SMALL`, `TOO_LARGE`, `INVALID_DATA`, `INVALID_TYPE`, `INVALID_HEADER`, `INVALID_DEST`, `INVALID_REPLY`, `INVALID_VOUCHER` | Untouched |
| `MACH_SEND_INVALID_RIGHT`, `INVALID_MEMORY`, `MACH_MSG_VM_KERNEL` | Header and partial body rights destroyed |
| `MACH_SEND_TIMED_OUT`, `INTERRUPTED`, `NO_BUFFER` (from the queue), `INVALID_OPTIONS` (post-copyin) | Pseudo-received: rights and memory are back in the sender's space under (possibly new) names, header rewritten in place |
| `MACH_MSG_SUCCESS` | All consumed |

(`libsystem_kernel`'s `mach_msg_server` treats only `INVALID_DEST`,
`TIMED_OUT`, and `INTERRUPTED` as "message intact, destroy it yourself".)

### 2.9 Queueing and blocking

- `qlimit` defaults to 5; settable 0…1024. `msgcount` is the number of
  queued messages (plus slots granted to woken senders).
- A send **does not block** if `msgcount < qlimit`, or if the destination
  disposition is send-once (send-once messages bypass `qlimit`), as long as
  `msgcount < 65534` (`MACH_PORT_QLIMIT_KERNEL`).
- Otherwise the sender blocks until a slot frees, the port dies (→ message
  destroyed, success), the timeout expires (`MACH_SEND_TIMED_OUT`, then
  pseudo-receive), or it is interrupted (`MACH_SEND_INTERRUPTED`). At the
  kernel limit (65534) the send fails with `MACH_SEND_NO_BUFFER`.
- If a receiver is waiting, the message is handed to it directly (it never
  occupies a queue slot), subject to the too-large rule (§2.10). Otherwise it
  is appended. Queue order is FIFO (xnu may reorder by QoS; Ycode keeps
  FIFO).
- Raising `qlimit` wakes as many blocked senders as new slots.
- A port in one or more sets makes each set "ready" when its queue becomes
  non-empty. A set receive takes the oldest ready member; after a message is
  taken from a member, that member moves to the back of the set's ready
  list (round robin).

### 2.10 Receive

1. `rcv_name` must name a receive right or a port set; otherwise
   `MACH_RCV_INVALID_NAME` (`0x10004002`). A port that is a member of a set
   can still be received from directly (`MACH_RCV_IN_SET` is no longer
   returned).
2. If a message is available, it is selected; else, with `RCV_TIMEOUT` and
   `timeout == 0`, return `MACH_RCV_TIMED_OUT`; else block. Wake-ups:
   message arrives; timeout (`MACH_RCV_TIMED_OUT`); interruption
   (`MACH_RCV_INTERRUPTED`); the port/set is destroyed, or the receive right
   is moved away, or the port is added to/removed from a set while waiting
   (`MACH_RCV_PORT_CHANGED`).
3. **Too-large test:** with `S` = received size (§2.5 header size with user
   descriptor sizes) and `T` = requested trailer size, the message is too
   large if `rcv_size < S + T` (vector receives: also if the aux block does
   not fit the aux buffer).
   - With `MACH_RCV_LARGE`: the message **stays queued**. The call returns
     `MACH_RCV_TOO_LARGE` and writes only: `msgh_size` = `S` (if `rcv_size ≥
     8`), and with `MACH_RCV_LARGE_IDENTITY` `msgh_local_port` = the name of
     the port holding the message (if `rcv_size ≥ 16`). Callers retry with a
     buffer of at least `S + T` (usually `S + 68`).
   - Without `MACH_RCV_LARGE`: the message is **dequeued and destroyed**,
     except that the destination is copied out as usual. The caller receives
     a bare header (`msgh_size = 24`, `msgh_id` kept, `msgh_local_port` =
     destination name, `msgh_remote_port` = 0 or the dead/null reply value,
     voucher 0) followed by the trailer, and the call returns
     `MACH_RCV_TOO_LARGE`. The reply right and every body right/memory are
     destroyed (a send-once reply right produces a send-once notification).
4. Copy the message out (§2.5). Header failure (no room in the name space)
   → the message is destroyed as in the "without `RCV_LARGE`" case and the
   call returns `MACH_RCV_HEADER_ERROR | MACH_MSG_IPC_SPACE`. Body failures
   → the message is delivered anyway with the failed items zeroed and the
   call returns `MACH_RCV_BODY_ERROR | bits`.
5. Write header + body + trailer to the buffer. If even the message without
   trailer does not fit (only possible through the error paths), or the
   buffer faults, return `MACH_RCV_INVALID_DATA`; the message is lost. A
   buffer that fits the message but not the whole trailer receives a
   truncated trailer.

### 2.11 Send-then-receive in one call

With both `SEND_MSG` and `RCV_MSG`: the send runs completely first (§2.8).
If it returns anything other than `MACH_MSG_SUCCESS`, the receive is
**skipped** and the send error is returned. Otherwise the receive runs on
`rcv_name`, writing into the same buffer (scalar) or into
`msgv_rcv_addr ?: msgv_data` (vector), with `rcv_size` as its limit. The
same `timeout` value applies to both phases (each phase only if its
`*_TIMEOUT` option is set). This is the MIG RPC pattern: dest = server port
(`COPY_SEND`), reply = `mig_get_reply_port()` (`MAKE_SEND_ONCE`), `rcv_name`
= the same reply port.

### 2.12 Return codes

`mach_msg_return_t` is a `kern_return_t`. Send errors are `0x1000000x`,
receive errors `0x100040xx`. Resource bits may be ORed in:

| Bit | Value | Meaning |
|---|---|---|
| `MACH_MSG_IPC_SPACE` | 0x2000 | No room in the name space for a right |
| `MACH_MSG_VM_SPACE` | 0x1000 | No room in the address space for OOL memory |
| `MACH_MSG_IPC_KERNEL` | 0x0800 | Kernel resource shortage (rights) |
| `MACH_MSG_VM_KERNEL` | 0x0400 | Kernel resource shortage (memory) |
| `MACH_MSG_MASK` | 0x3E00 | All of the above |

| Code | Value | When |
|---|---|---|
| `MACH_MSG_SUCCESS` | 0 | |
| `MACH_SEND_IN_PROGRESS` | 0x10000001 | (internal) |
| `MACH_SEND_INVALID_DATA` | 0x10000002 | Fault reading the message or vector |
| `MACH_SEND_INVALID_DEST` | 0x10000003 | Bad destination name/right; also the trap "target is not self" result |
| `MACH_SEND_TIMED_OUT` | 0x10000004 | Full queue, timeout expired |
| `MACH_SEND_INVALID_VOUCHER` | 0x10000005 | Bad voucher name/disposition |
| `MACH_SEND_INTERRUPTED` | 0x10000007 | Blocked send interrupted |
| `MACH_SEND_MSG_TOO_SMALL` | 0x10000008 | Size checks |
| `MACH_SEND_INVALID_REPLY` | 0x10000009 | Bad reply name/right |
| `MACH_SEND_INVALID_RIGHT` | 0x1000000A | Bad right in a descriptor |
| `MACH_SEND_INVALID_NOTIFY` | 0x1000000B | (legacy) |
| `MACH_SEND_INVALID_MEMORY` | 0x1000000C | Bad OOL memory |
| `MACH_SEND_NO_BUFFER` | 0x1000000D | Allocation failure / kernel queue limit |
| `MACH_SEND_TOO_LARGE` | 0x1000000E | Size or port-count limits |
| `MACH_SEND_INVALID_TYPE` | 0x1000000F | Bad descriptor type/options |
| `MACH_SEND_INVALID_HEADER` | 0x10000010 | Bad dispositions in the header |
| `MACH_SEND_INVALID_TRAILER` | 0x10000011 | (unused) |
| `MACH_SEND_INVALID_CONTEXT` | 0x10000012 | Strict-reply context mismatch |
| `MACH_SEND_INVALID_OPTIONS` | 0x10000013 | mach_msg2 CFI / policy |
| `MACH_SEND_INVALID_RT_OOL_SIZE` | 0x10000015 | (unused) |
| `MACH_SEND_NO_GRANT_DEST` | 0x10000016 | (policy) |
| `MACH_SEND_MSG_FILTERED` | 0x10000017 | Message filter |
| `MACH_SEND_AUX_TOO_SMALL` | 0x10000018 | Aux vector < 8 bytes |
| `MACH_SEND_AUX_TOO_LARGE` | 0x10000019 | Aux vector > 1024 bytes |
| `MACH_RCV_IN_PROGRESS` | 0x10004001 | (internal) |
| `MACH_RCV_INVALID_NAME` | 0x10004002 | `rcv_name` is not a receive right or set |
| `MACH_RCV_TIMED_OUT` | 0x10004003 | |
| `MACH_RCV_TOO_LARGE` | 0x10004004 | §2.10 |
| `MACH_RCV_INTERRUPTED` | 0x10004005 | |
| `MACH_RCV_PORT_CHANGED` | 0x10004006 | Port/set destroyed or moved while waiting |
| `MACH_RCV_INVALID_NOTIFY` | 0x10004007 | Bad sync-wait linkage (§4.2) |
| `MACH_RCV_INVALID_DATA` | 0x10004008 | Fault writing the buffer |
| `MACH_RCV_PORT_DIED` | 0x10004009 | (documented, not produced by this kernel) |
| `MACH_RCV_IN_SET` | 0x1000400A | (no longer produced) |
| `MACH_RCV_HEADER_ERROR` | 0x1000400B | Header copyout failed (+ resource bits) |
| `MACH_RCV_BODY_ERROR` | 0x1000400C | Body copyout partially failed (+ resource bits) |
| `MACH_RCV_INVALID_TYPE` | 0x1000400D | (legacy) |
| `MACH_RCV_SCATTER_SMALL` | 0x1000400E | (legacy) |
| `MACH_RCV_INVALID_TRAILER` | 0x1000400F | (unused) |
| `MACH_RCV_IN_PROGRESS_TIMED` | 0x10004011 | (internal) |
| `MACH_RCV_INVALID_REPLY` | 0x10004012 | Strict-reply violation |
| `MACH_RCV_INVALID_ARGUMENTS` | 0x10004013 | Bad receive vector |

### 2.13 Limits and ignorable features

| Limit | Value |
|---|---|
| Maximum send size | 50,331,580 bytes |
| Maximum aux data | 1024 bytes |
| Port rights per message (inline + OOL) | 16,383 |
| `qlimit` | 0…1024, default 5 |
| Kernel queue limit | 65,534 |
| "Reliable" size (`MACH_MSG_SIZE_RELIABLE`) | 256 KiB |
| `urefs` | 65,535 (pegs) |

Ycode may ignore: QoS/priority fields and overrides, importance bits
(`RAISEIMP`, `IMPHOLDASRT`, `NOIMPORTANCE`), send-possible notifications
(it may return success and never fire them, or fire them immediately),
strict-reply checking, message filtering, reply-port and service-port
security policies (xnu itself relaxes them for simulated processes), and
port guard **exceptions** (return the error code; do not raise
`EXC_GUARD`).

---

## 3. Notifications

All notifications are **simple-or-complex messages sent by the kernel** to a
send-once right that the task registered (or, for send-once notifications,
to the port itself). They are MIG "simpleroutines" of subsystem `notify`
(base `0100` = 64). As received:

- `msgh_bits` = `0x00001200` (local = `PORT_SEND_ONCE` 18, remote 0, voucher
  0), plus `0x80000000` for the port-destroyed notification;
- `msgh_remote_port` = 0, `msgh_local_port` = the receiver's name for the
  notification port, `msgh_voucher_port` = 0;
- trailer sender `{0, 1}`, audit token all zero (§2.6);
- `NDR_record_t` is the 8-byte record of §5.2.

| Notification | `msgh_id` | `msgh_size` | Body after the 24-byte header |
|---|---|---|---|
| `MACH_NOTIFY_PORT_DELETED` | `0101` = **65** | 36 | NDR (8) @24, `u32 name` @32 |
| `MACH_NOTIFY_SEND_POSSIBLE` | `0102` = **66** | 36 | NDR, `u32 name` |
| `MACH_NOTIFY_PORT_DESTROYED` | `0105` = **69** | 40 | complex: `u32 descriptor_count = 1` @24, port descriptor @28 (name = the new receive right, disposition 16) |
| `MACH_NOTIFY_NO_SENDERS` | `0106` = **70** | 36 | NDR, `u32 mscount` @32 |
| `MACH_NOTIFY_SEND_ONCE` | `0107` = **71** | 24 | none |
| `MACH_NOTIFY_DEAD_NAME` | `0110` = **72** | 36 | NDR, `u32 name` @32 |

`MACH_NOTIFY_FIRST` = 64 and `MACH_NOTIFY_LAST` = `0115` = 77 bound the range.
IDs 67 and 68 are unused (old ownership/receive-rights notifications).

A notification whose notification port is already dead is not sent; its
send-once right is simply released. Notifications use the send-once path, so
they ignore `qlimit` (§2.9).

### 3.1 Port-deleted (65)

Sent to the registered send-once right of a **dead-name request** when the
*name* that the request watches is freed while the port is still alive:
deallocating or `mod_refs`-ing the last uref, moving the right away in a
message (`MOVE_SEND` of the last uref, `MOVE_SEND_ONCE`, `MOVE_RECEIVE` of a
receive-only entry), `mach_port_destroy`. `name` is the freed name. The
request is cancelled.

### 3.2 Dead-name (72)

Sent to every armed dead-name request when the port dies (§1.5). `name` is
the watched name in the requester's space. The notification carries one
dead-name uref: when the requester's entry is converted to a dead name its
`urefs` is incremented by one. **A receiver of this notification must call
`mach_port_deallocate(name)` once for the notification's reference** (and
once more per reference it held before).

### 3.3 Send-once (71)

Sent to a port when a send-once right for it is **destroyed without a
message having been sent through it**: `mach_port_deallocate`,
`mod_refs(…, SEND_ONCE, −1)`, `mach_port_destroy`, task death, a queued
message carrying the right is destroyed (port death, too-large receive,
failed send step 5), or the right was the armed no-senders request of a port
that died. Not sent if the port is dead or its queue is at the 65,534 kernel
limit. MIG clients treat a reply with ID 71 as `MIG_SERVER_DIED` (§5).

### 3.4 Port-destroyed (69)

Registered with `mach_port_request_notification(…,
MACH_NOTIFY_PORT_DESTROYED, sync = 0, notify, …)` on a **receive right**.
When that receive right would be destroyed (mod_refs −1, destroy, destruct,
task death, a message carrying it destroyed), the port does **not** die:
it is sent, with its queued messages intact, as a `MOVE_RECEIVE` right in a
port-destroyed notification to `notify`. The request is consumed. If the
destroying space still held send rights under that name, it keeps them. If
`notify`'s port is not alive, the port is destroyed normally. Registration
errors: `sync ≠ 0` → `KERN_INVALID_VALUE`; a second registration or a reply
port → `KERN_FAILURE`; `previous` is always NULL. (launchd uses this for
service ports so it gets their receive rights back from dead services.)

### 3.5 No-senders (70)

Registered on a **receive right** with `sync` = a make-send count. Fires
once, when `srights` drops to 0, with body `mscount` = the port's make-send
count at that moment. Registration: the old request (if any) is returned in
`previous`; if `srights == 0` already and `sync ≤ mscount` and `notify` is
valid, the notification is sent **immediately** and nothing stays armed;
otherwise `notify` is armed (replacing the old one). If the port dies with
the request armed, the request's send-once right gets a send-once
notification instead. Typical use: server checks `mscount` in the
notification against its own count to avoid races with rights in flight.

### 3.6 `mach_port_request_notification` rules

| `id` | Name must denote | `sync` | Effect |
|---|---|---|---|
| 69 `PORT_DESTROYED` | receive right | 0 | §3.4 |
| 70 `NO_SENDERS` | receive right | make-send count | §3.5 |
| 72 `DEAD_NAME` | send, send-once, or receive right (one request per name) | ignored | Replaces any previous request on this name and returns the previous send-once right in `previous`. `notify` NULL cancels (returns the previous). Requires a dead-name request table on the port |
| 66 `SEND_POSSIBLE` | send right | nonzero = "arm" | Ycode may treat as fire-immediately |
| other | | | `KERN_INVALID_VALUE` |

Errors: `notify == DEAD` → `KERN_INVALID_CAPABILITY`; name NULL/DEAD →
`KERN_INVALID_ARGUMENT`. For `DEAD_NAME` on a name that is **already** a dead
name, this kernel returns `KERN_INVALID_ARGUMENT` (it does not generate an
immediate notification; see §7). For `DEAD_NAME` on a name without port
rights → `KERN_INVALID_RIGHT`.

Ordering facts a faithful VMM must keep:

- A copyin that consumes a watched name before the port dies produces
  port-deleted; if the port died first, the name became a dead name and a
  dead-name notification was sent (and the move of a dead send right copies
  in `MACH_PORT_DEAD` as a reply, or fails as a destination).
- The notification messages are queued like any message; the receiver sees
  them in queue order with the other traffic on the notification port.

---

## 4. Reply ports, special reply ports, vouchers, `mach_msg_destroy`

### 4.1 MIG reply ports

- `mig_get_reply_port()`: per-thread cached receive right, kept in TSD slot
  `__TSD_MIG_REPLY`. Created lazily by `mach_port_construct` with
  `MPO_REPLY_PORT` (in a simulated process, a weak reply port, i.e. an
  ordinary receive right with **no** send right). Old libraries used the
  `mach_reply_port` trap (−26), which allocates a plain receive right (no
  send right) and returns its name (0 on failure).
- `mig_dealloc_reply_port(port)`: destroys the thread's cached reply port
  (`mod_refs(RECEIVE, −1)`) and clears the TSD slot; MIG calls it after a
  failed RPC so a late reply cannot be mistaken for the next one.
  `mig_put_reply_port` does nothing.
- MIG clients send with local disposition `MAKE_SEND_ONCE` (21) on the reply
  port and receive on the same port (§2.11).
- **Reply-port rule (all kernels, including simulated processes):** for a
  port of kind *reply* or *special reply*, copyin accepts only
  `MAKE_SEND_ONCE` and `MOVE_SEND_ONCE`; any other disposition fails
  (`KERN_INVALID_CAPABILITY` → `MACH_SEND_INVALID_RIGHT`/`_REPLY`/`_DEST`
  by slot). `MAKE_SEND_ONCE` from a reply port is only accepted in the reply
  or destination slot of a message, and `MOVE_SEND_ONCE` of a reply port's
  send-once right only in the destination slot (that is, to send the reply
  itself). For a *weak* reply port (what `MPO_REPLY_PORT` becomes in the
  simulator) none of this applies.

### 4.2 Special reply ports

`thread_get_special_reply_port()` (trap −50): allocates a new port of kind
*special reply* in the caller's space with a **receive right and a send right
under one name** (`urefs 1`), binds it to the calling thread (unbinding any
previous one), and returns the name (0 on failure). libdispatch uses it for
synchronous IPC: it sends with the special reply port as local port
(`MAKE_SEND_ONCE`) and receives on it with `MACH_RCV_SYNC_WAIT`, passing the
destination name (x3 low half for `mach_msg2`, the `priority` argument for
the legacy traps) for priority-inheritance linkage.

What Ycode needs:

- Treat it as an ordinary port of kind *special reply* (copyin restricted to
  send-once dispositions, §4.1).
- `MACH_RCV_SYNC_WAIT` linkage may be ignored, with one check that xnu
  performs: if the receive names a port that is **not** the calling
  thread's bound special reply port, or the sync destination name is not
  valid, the receive fails with `MACH_RCV_INVALID_NOTIFY`. A destination
  name that does not resolve to a send right is not an error.
- `mig_get_special_reply_port`, `mig_dealloc_special_reply_port`,
  `thread_destruct_special_reply_port`, and
  `_kernelrpc_mach_port_special_reply_port_reset_link` are library routines
  over these traps and `mach_port_destruct`/MIG 3236; the VMM answers the
  reset-link MIG with `srp_lost_link = FALSE`.

### 4.3 Vouchers (enough to ignore them safely)

Vouchers are kernel-object ports (type *voucher*). The constraints that
matter:

1. A message may carry a voucher only with voucher disposition `MOVE_SEND` or
   `COPY_SEND` and a name that is a send right to a **voucher object**;
   anything else nonzero → `MACH_SEND_INVALID_VOUCHER`. Name 0 with a
   voucher disposition is allowed.
2. On receive without `MACH_RCV_VOUCHER` the voucher is dropped (§2.5).
3. libdispatch calls `host_create_mach_voucher` (trap −70 or MIG on the host
   port) during initialization and **crashes the process** if it returns an
   error. Other voucher calls are `dispatch_assume_zero`-checked and
   tolerate `MACH_VOUCHER_NULL`.

**Minimal kernel behavior (recommended):**

- `host_create_mach_voucher(_trap)`: return `KERN_SUCCESS` and voucher name
  **0** (xnu itself returns a null voucher for an empty recipe). Recipe
  sizes < 0 → `KERN_INVALID_ARGUMENT`; too large → `MIG_ARRAY_TOO_LARGE`.
- `mach_voucher_extract_attr_recipe(_trap)`: name 0 or anything not a
  voucher → `MACH_SEND_INVALID_DEST` (this is xnu's result); a VMM voucher →
  size 0.
- `mach_voucher_deallocate(0)`: `KERN_SUCCESS`.
- Because no voucher objects exist, libdispatch's `voucher_mach_msg_set` has
  nothing to attach, so messages carry voucher 0.
- If tracing shows a caller that needs a real voucher name, add one VMM
  "empty voucher" object: creation returns a send right to it (merging
  urefs), it is accepted in the voucher slot, and it is dropped or delivered
  per §2.5.

### 4.4 `mach_msg_destroy(msg)` (library routine, semantics)

Releases the rights and memory **in a received (or pseudo-received) message
buffer**, using the dispositions recorded in it:

- `msgh_remote_port` with the remote disposition and `msgh_voucher_port`
  with the voucher disposition. `msgh_local_port` is **not** touched (on a
  received message it is the destination, whose right was consumed).
- For each descriptor (walking 12/16-byte descriptors): port → destroy the
  right; OOL → if `deallocate`, `vm_deallocate(address, size)`; volatile
  OOL → skip; OOL ports → destroy each right, then deallocate the array if
  `deallocate`; guarded port → `mach_port_unguard` with `context` first,
  unless `UNGUARDED_ON_SEND` is set, then destroy.
- "Destroy" per disposition: `MOVE_SEND`/`MOVE_SEND_ONCE` →
  `mach_port_deallocate` (a send-once one thus produces a send-once
  notification); `MOVE_RECEIVE` → `mod_refs(RECEIVE, −1)`; `MAKE_SEND` →
  `insert_right(MAKE_SEND)` then `deallocate` (net effect: `mscount + 1`,
  possibly a no-senders notification); `MAKE_SEND_ONCE` →
  `extract_right(MAKE_SEND_ONCE)` then `deallocate` (net effect: a
  send-once notification). NULL/DEAD names are skipped.

The VMM needs nothing special for this; it only has to make the underlying
routines exact.

---

## 5. MIG wire conventions

### 5.1 IDs and headers

- A subsystem has a base ID `B` (e.g. `mach_port` 3200, `notify` 64). Routine
  `k` (0-based, counting `skip` slots) has request ID `B + k`. The **reply ID
  is request ID + 100**.
- Request header from a MIG client: `msgh_bits` = `MACH_MSGH_BITS(COPY_SEND
  (19), MAKE_SEND_ONCE (21))` (+ `COMPLEX` if it carries descriptors),
  `msgh_remote_port` = the server port, `msgh_local_port` = the reply port,
  `msgh_voucher_port` = 0, `msgh_id` = request ID. Simple routines with no
  reply (`simpleroutine`) have local port 0 and local disposition 0.
- The request body follows the header: if complex, the descriptor count and
  the descriptors (rights and OOL data) first; then `NDR_record_t` (8 bytes);
  then the in-line arguments in declaration order, each 4-byte aligned
  (counts precede variable arrays). The server checks `msgh_size` and the
  descriptor count exactly and answers `MIG_BAD_ARGUMENTS` on mismatch.
- **Server side:** the reply header is `msgh_bits` =
  `MACH_MSGH_BITS(remote = the request's received remote disposition, 0)` —
  i.e. 18 (`MOVE_SEND_ONCE`) for a normal RPC —, `msgh_remote_port` = the
  request's received `msgh_remote_port` (the reply right), local 0, voucher
  0, `msgh_id` = request ID + 100. An unknown request ID gets a
  `mig_reply_error_t` with `RetCode = MIG_BAD_ID`. If the reply right is
  `MOVE_SEND` (not send-once), servers send with `MACH_SEND_TIMEOUT` 0.
- **Client side checks on the reply:** `msgh_id` must equal request ID +
  100; if it is 71 (`MACH_NOTIFY_SEND_ONCE`) the call returns
  `MIG_SERVER_DIED`, any other ID → `MIG_REPLY_MISMATCH`. For a simple
  reply: not complex, and `msgh_size` == the reply struct size, **or**
  `msgh_size == 36` (a `mig_reply_error_t`) with `RetCode ≠ KERN_SUCCESS`;
  otherwise `MIG_TYPE_ERROR`. For a complex reply: the descriptor count must
  match, or the reply must be a simple 36-byte error reply with nonzero
  `RetCode`.
- On a `mach_msg` failure the client: for `MACH_SEND_INVALID_DATA`,
  `_INVALID_DEST`, `_INVALID_HEADER` keeps the reply port; for every other
  error (and for timeouts) calls `mig_dealloc_reply_port` (or the special
  reply-port variant).

### 5.2 `NDR_record` and `mig_reply_error_t`

`NDR_record_t` (8 bytes) for arm64: `mig_vers 0, if_vers 0, reserved1 0,
mig_encoding 0 (NDR_PROTOCOL_2_0), int_rep 1 (little-endian), char_rep 0
(ASCII), float_rep 0 (IEEE), reserved2 0` → bytes `00 00 00 00 01 00 00 00`.
Servers do not reject other values; they only byte-swap if `int_rep`
differs.

`mig_reply_error_t` (36 bytes, packed to 4): header (24) @0, `NDR_record_t`
@24, `kern_return_t RetCode` @32. It is the reply for every routine that
fails, and the whole reply for routines with no out-arguments. A successful
routine's simple reply is `header, NDR, RetCode = 0, out-arguments…`. A
**complex** reply (one that returns rights or OOL data) is `header,
descriptor count, descriptors, NDR, in-line out-arguments…` with **no**
`RetCode`: a complex reply implies success, and every failure is reported
with the simple 36-byte `mig_reply_error_t`.

MIG error codes (`kern_return_t`): `MIG_TYPE_ERROR` −300,
`MIG_REPLY_MISMATCH` −301, `MIG_REMOTE_ERROR` −302, `MIG_BAD_ID` −303,
`MIG_BAD_ARGUMENTS` −304, `MIG_NO_REPLY` −305 (server: send no reply),
`MIG_EXCEPTION` −306, `MIG_ARRAY_TOO_LARGE` −307, `MIG_SERVER_DIED` −308,
`MIG_TRAILER_ERROR` −309.

### 5.3 What this means for VMM-hosted MIG servers

To answer a MIG request on a VMM kernel-object port, the VMM:

1. Copies the request in as a normal send (§2.8 steps 1–5), so rights in it
   (the reply send-once right, any port arguments) are moved out of the
   client's space.
2. Decodes by `msgh_id`; unknown → `mig_reply_error_t` with `MIG_BAD_ID`.
3. Builds the reply in kernel form and enqueues it on the reply right with
   remote disposition `MOVE_SEND_ONCE`; it ignores `qlimit` (send-once).
   Rights returned to the client (e.g. `extract_right`'s `poly`, a new
   semaphore) are port descriptors in a complex reply and are copied out at
   the client's receive.
4. Increments the server port's `seqno`. If the request had no reply port
   (a simpleroutine), sends nothing.
5. If the client's reply right is dead (the client destroyed its reply
   port), the reply is destroyed.

Kernel-originated messages use the kernel trailer (§2.6).

---

## 6. Implementation checklist for Ycode's VMM

Ordered by what `launchd_sim` and libdispatch hit first. Each item names
the sections it implements.

1. **Per-process name space** (§1.2–§1.4): deterministic name allocation,
   entries with type bits + `urefs`, reverse (port → name) map for send and
   receive rights, LIFO free list, `(name & 3) == 3` validation. Seed task
   self, host, bootstrap (`0x0503`), and the main thread's names at exec.
2. **Port objects** (§1.3) with `srights`/`sorights`/`mscount`/`seqno`/
   `qlimit`/`msgcount`/context/guard; port sets with membership in several
   sets.
3. **Port traps** −16, −18, −19, −21, −24, −25, −40, −41, −42, −76 with the
   exact error codes of §1.7, then −20, −22, −23, −77. Lazy dead-name
   conversion (§1.5) from day one: it changes error codes.
4. **`mach_msg2` (−47), scalar, simple messages**: size checks, header
   copyin (§2.4) including the dest==reply and dest==voucher combinations,
   header copyout swap (§2.5), trailers (§2.6), send-then-receive (§2.11),
   timeouts with 0 = poll (§2.7), `MACH_RCV_LARGE`/too-large (§2.10), CFI
   checks (§2.7). Also accept −31/−32 for any code that still uses them.
5. **Blocking and wake-up** across guest threads (stage 4 threads): a
   blocked receive must be woken by a send from another thread; a blocked
   send by a receive or `qlimit` change. With only one runnable vCPU, a
   receive that can never complete must not hang the VMM silently: log
   `DEADLOCK` (as §10 of `host-libraries.md` does for semaphores) and keep
   the thread blocked.
6. **Port descriptors and OOL ports** (§2.3–§2.5), with pseudo-receive on
   post-copyin send failures (§2.8) and circularity detection.
7. **OOL memory** (§2.3, §2.5): capture at send, map at a fresh address in
   the receiver (copy is fine; copy-on-write is an optimization),
   `deallocate` handling.
8. **Notifications** (§3): send-once (needed for `MIG_SERVER_DIED`),
   no-senders and dead-name (libxpc/libdispatch connection teardown),
   port-deleted, port-destroyed (launchd service ports).
9. **Reply ports** (§4.1–§4.2): `MPO_REPLY_PORT` construct, reply-port
   copyin rule, `thread_get_special_reply_port` (−50), `MACH_RCV_SYNC_WAIT`
   check.
10. **Vouchers stubbed** (§4.3): `host_create_mach_voucher` → success, name 0.
11. **VMM MIG servers** (§5.3) on task/host/thread/clock/semaphore ports for
    whatever routines tracing shows (the private traps of
    `host-libraries.md` §10 can stay for Ycode's own library). The bootstrap
    port keeps answering `MACH_SEND_INVALID_DEST` until the bootstrap design
    is specified.
12. **Vectors and aux data** (§2.7): only if Ycode's `mach_msg` or a traced
    caller uses `MACH64_MSG_VECTOR`.
13. **`kevent` `EVFILT_MACHPORT` / workloops** (separate spec): libdispatch's
    main receive path for Mach channels and sources. It must reuse the
    receive algorithm of §2.10 (receive into `ext[0]`/`ext[1]`, return code
    in `fflags`).
14. **Task death**: destroy every right in the space (receive rights →
    port-destroyed or death; send-once → send-once notifications; dead-name
    requests → port-deleted not needed since the requester is gone).

Test oracle: each item can be checked against the host Mac by running the
same small probe program natively (level 3 black-box), comparing return
codes, names (allowing for randomized generations), and notification
messages byte for byte.

---

## 7. Open questions

1. **Dead-name request on an already-dead name.** The routine comment in
   xnu promises an immediate dead-name notification when `sync ≠ 0`, but
   at this tag the code returns `KERN_INVALID_ARGUMENT` for
   `MACH_NOTIFY_DEAD_NAME` (the immediate path is only reached for
   send-possible requests). Confirm on the host Mac (level 3) which result
   current callers see, and match it.
2. **Bare header after a non-`RCV_LARGE` too-large receive.** The rebuilt
   header keeps the "other" bits, which would include `COMPLEX`. Whether the
   user-visible header still has `0x80000000` set (and what follows it) needs
   a black-box probe. Ycode should clear `COMPLEX` until proven otherwise.
3. **Which traps the simulator images call directly.** `mach_msg2_internal`
   has 3 importers (MIG kernel-server stubs use `KOBJECT_CALL`). Trace
   whether any simulator image issues `svc` for −31/−32/−47 itself rather
   than through `libsystem_kernel`.
4. **Bootstrap port ownership.** How `launchd_sim` gets its bootstrap port
   from the host side (`launchd_sim_trampoline`, host `launchd`), and what
   messages it expects on it, is launchd's protocol and needs its own spec
   (black-box tracing).
5. **`mach_task_self()` name.** xnu's first allocations are `0x103`… but
   the exact name of the task self port in a freshly exec'd simulator
   process (and whether any code hard-codes it) should be checked against
   the host (level 3). Ycode's deterministic layout must stay consistent
   with `0x0503` for bootstrap.
6. **Voucher stub sufficiency.** Verify by tracing that no simulator
   component requires a nonzero voucher from `host_create_mach_voucher`
   (e.g. `voucher_mach_msg_adopt`, `mach_voucher_attr_command`).
7. **`EVFILT_MACHPORT` and workloop semantics** (`kevent_id`,
   `MACH_RCV_MSG` in `fflags`, `ext[0..3]`, voucher content extraction)
   must be specified from xnu `bsd/kern/kern_event.c` and
   `osfmk/ipc/ipc_pset.c` in a follow-up.
8. **Guard exceptions.** xnu raises `EXC_GUARD` (often fatal) for misuse such
   as destroying a guarded receive right. Ycode returns the error codes only.
   Decide whether any simulator code depends on the crash (unlikely).
9. **QoS and `MACH_SEND_SYNC_OVERRIDE`/`MACH_RCV_SYNC_WAIT` ordering.**
   Ignoring them changes scheduling only, not results, on one vCPU; revisit
   with SMP.

---

## Evidence

All claims are **evidence level 1** (Apple open source and public headers),
read through the GitHub API into a scratch directory outside the repository.
Nothing from `.claude/Xcode.app`, `research/dirty/`, Ghidra, or any Apple
binary was used. No source text is reproduced here; the spec restates
behavior, layouts, and constants.

- **xnu**, tag **`xnu-12377.121.6`** (commit
  `ac9718fb1af618d5ce8678d0dc6e8a58f252216f`, the newest tag on 2026-10-11;
  same tag as `darwin-trap-tables.md`):
  - Public headers: `osfmk/mach/message.h` (header, bits, descriptors,
    trailers, options, return codes, vectors, `mach_msg2` packing),
    `osfmk/mach/port.h` (rights, types, names, `MPO_*`, status, flavors,
    guard codes), `osfmk/mach/notify.h` and `osfmk/mach/notify.defs`
    (notification IDs and layouts), `osfmk/mach/mach_port.defs` (MIG IDs),
    `osfmk/mach/mig_errors.h`, `osfmk/mach/ndr.h`,
    `osfmk/mach/arm/ndr_def.h`, `osfmk/mach/kern_return.h`,
    `osfmk/mach/task_special_ports.h`, `osfmk/mach/mach_traps.h`.
  - Kernel IPC: `osfmk/ipc/ipc_entry.{h,c}` and `ipc_space.c` (name
    encoding, generations, free list), `ipc_right.c` (urefs, dealloc,
    delta, destroy, destruct, copyin, copyout, dead-name conversion,
    requests), `ipc_object.c` (copyin type map, copyout, copyout to a
    chosen name, destination copyout, destroy), `ipc_kmsg.c` (send/receive
    algorithms, descriptor sizes, header copyin/copyout, pseudo-receive,
    too-large message, trailer fill, delivery), `ipc_mqueue.{h,c}` (queue
    limits, blocking, too-large test, receive results, sequence numbers),
    `mach_msg.c` (trap entry points, `mach_msg2` unpacking, vectors,
    send-then-receive, `RCV_LARGE`, sync-wait check), `mach_port.c`
    (routine semantics and errors), `mach_kernelrpc.c` (trap wrappers),
    `ipc_notify.c`, `ipc_port.{h,c}` (allocation, destruction,
    dead-name notifications, port kinds), `ipc_policy.{h,c}` (limits, CFI
    and policy rules), `ipc_voucher.c`, `ipc/port.h` (`urefs` limits),
    `osfmk/kern/ipc_tt.c` (self traps, `mach_reply_port`,
    `thread_get_special_reply_port`), `bsd/kern/kern_prot.c` (audit and
    security token contents), `bsd/sys/event.h` (`EVFILT_MACHPORT` notes).
  - `libsyscall/mach/`: `mach_msg.c` (library `mach_msg` →
    `mach_msg2`, interrupt retries, `mach_msg_destroy`, `mach_msg_server`),
    `mach_port.c` (trap-then-MIG fallback), `mig_reply_port.c`,
    `mig_reply_setup.c`, `mach_init.c`.
- **bootstrap_cmds** (MIG generator), tag `bootstrap_cmds-138` (commit
  `c71d2d72f48995baaea76148f61002e5299841de`): `migcom.tproj/user.c` and
  `server.c` for client reply checks, the `+100` reply ID, server reply
  headers, `MIG_BAD_ID`, and reply-port disposal on errors.
- **libdispatch**, tag `libdispatch-1542.100.32` (commit
  `701f4d1a24ae9c6863901bbbb22624b7d1b87321`): `src/voucher.c` for the
  crash-on-failure of the initial `host_create_mach_voucher` call (§4.3).
- Cross-references inside this repository: `data/mach-traps.json` (trap
  numbers and argument lists), `host-libraries.md` §10 (private traps,
  bootstrap name `0x0503`), `darwin-arm64-abi.md` (trap register
  convention), `host-library-surface.json` data (which Mach routines the
  simulator imports).
- §1.4 "Ycode's choice", §6, and the recommendations marked as such are
  Ycode design decisions, not observations.


## Addendum (orchestrator, 2026-10-12): facts used by the kernel library

The stage-4a kernel-library agent took these from Apple's public xnu
headers (level 1, APSL open source; interop facts only):

- **`mach_msg2_internal` arguments** (library-side, before packing into the
  §2.7 registers): `(data, options64, msgh_bits_and_send_size,
  msgh_remote_and_local_port, msgh_voucher_and_id,
  desc_count_and_rcv_name, rcv_size_and_priority, timeout)`. These are the
  same 8 words the trap receives in x0–x7.
- **`mach_msg_priority_t`** (32-bit):

  | Bits | Field |
  |---|---|
  | 8–15 | relative priority |
  | 16–19 | QoS class |
  | 20–23 | override QoS |
  | 0–7 | zero (reserved) |

- **`thread_destruct_special_reply_port` rights selector:**

  | Value | Meaning |
  |---|---|
  | 0 | all rights |
  | 1 | receive only |
  | 2 | send only |

- **Library-only option bits** `MACH_SEND_INTERRUPT` (0x40) and
  `MACH_RCV_INTERRUPT` (0x400) are stripped before the trap. The library
  retries itself on `MACH_SEND_INTERRUPTED` and `MACH_RCV_INTERRUPTED`.
