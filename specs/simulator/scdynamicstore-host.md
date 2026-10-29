# Spec: host SCDynamicStore server (minimal, for `configd_sim`)

## 1. Why

`configd_sim` (job `com.apple.configd_sim`, `KeepAlive` = true) loads the
SimulatorSupport plug-in. That plug-in opens a session on the **host's**
SystemConfiguration dynamic store, asserts that it succeeded, and mirrors a
few host keys into the simulator's own store. Ycode had no host store:

- Without a host name the session is NULL. `configd_sim` aborts with
  "Assertion failed: (store_host != NULL), function load_SimulatorSupport".
  launchd relaunches it about every 40 s. This made 49 of 61 `guest_fatal`
  lines in a 700 s boot.
- A stub that only answered with `KERN_FAILURE` (speed explorer X15) still
  gave a NULL session.

This spec defines the smallest host store that lets the plug-in start. The
store is **empty**: every lookup finds nothing, and nothing ever changes,
so it never sends a notification.

## 2. Names

The host offers one receive right under both names (`launchd-sim.md` §6.3):
`com.apple.SystemConfiguration.configd` and
`com.apple.SystemConfiguration.configd_host`. The names are registered into
the guest with the control session's 701 requests, like the other host
services.

## 3. What the plug-in does (open source)

From `configd/Plugins/SimulatorSupport/simulator_support.c`:

1. `SCDynamicStoreCreateWithOptions(NULL, "SimulatorSupport(host)",
   {kSCDynamicStoreUseHostServer: true}, mirror, NULL)`, then
   `assert(store_host != NULL)`.
2. `SCDynamicStoreSetNotificationKeys(store_host, keys, patterns)`, then
   `assert(ok)`. The keys are `Plugin:InterfaceNamer`,
   `State:/Network/MulticastDNS` and `State:/Network/PrivateDNS`. The
   patterns cover the global, service and interface network entities.
3. `SCDynamicStoreCreateRunLoopSource(NULL, store_host, 0)`, then
   `assert(rls != NULL)`. The source is added to the current run loop.
4. Prime: `SCDynamicStoreCopyMultiple(store_host, keys, patterns)`. A NULL
   result ends the prime step.
5. On a notification, the plug-in copies the changed keys from the host
   store into the simulator store.

## 4. Wire protocol (MIG subsystem `config`, base 20000)

The request and reply layouts are standard MIG (`config.defs`). The reply id
is the request id + 100. `xmlData` and `xmlDataOut` are out-of-line byte
arrays: an OOL descriptor, and a count word in the body after the NDR
record. Every reply body begins with the NDR record (8 bytes: 0, 0, 0, 1,
then 4 zero bytes). A non-complex reply then has `RetCode` (`kern_return_t`).
Ycode always sends `RetCode` = 0, and the result is in `status`
(`kSCStatus*`).

| Id | Routine | Request (after the header) | Ycode's reply |
|---|---|---|---|
| 20000 | `configopen` | 2 OOL (name, options); NDR, nameCnt, optionsCnt | complex: 1 port descriptor (the new **session** port, MAKE_SEND, received as PORT_SEND); NDR, `status` 0. Total 52 bytes |
| 20008 | `configlist` | on a session: 1 OOL (key); NDR, cnt, isRegex | complex: 1 OOL (empty array, binary plist); NDR, cnt, `status` 0 |
| 20009 / 20014 | `configadd` / `configadd_s` | 2 OOL | NDR, RetCode 0, newInstance 0, `status` 0 |
| 20010 | `configget` | 1 OOL | complex: 1 OOL (0 bytes); NDR, cnt 0, newInstance 0, `status` 1004 (`kSCStatusNoKey`) |
| 20011 | `configset` | 2 OOL; instance | NDR, RetCode 0, newInstance 0, `status` 0 |
| 20012 | `configremove` | 1 OOL | NDR, RetCode 0, `status` 1004 |
| 20015 | `confignotify` | 1 OOL | NDR, RetCode 0, `status` 0 |
| 20016 | `configget_m` | 2 OOL (keys, patterns) | complex: 1 OOL (0 bytes); NDR, cnt 0, `status` 1004 |
| 20017 | `configset_m` | 3 OOL | NDR, RetCode 0, `status` 0 |
| 20018 / 20019 | `notifyadd` / `notifyremove` | 1 OOL; isRegex | NDR, RetCode 0, `status` 0 |
| 20020 | `notifychanges` | — | complex: 1 OOL (empty array, binary plist); NDR, cnt, `status` 0 |
| 20021 | `notifyviaport` | 1 port (MOVE_SEND); msgid | NDR, RetCode 0, `status` 0. The right is kept until the session ends and is never used |
| 20024 | `notifycancel` | — | NDR, RetCode 0, `status` 0 |
| 20025 | `notifyset` | 2 OOL (keys, patterns) | NDR, RetCode 0, `status` 0 |
| 20026 | `notifyviafd` | 1 port; identifier | NDR, RetCode 0, `status` 0 (the fileport is dropped) |
| 20029 | `snapshot` | — | NDR, RetCode 0, `status` 0 |
| other | — | — | MIG `MIG_BAD_ID` error reply (-303). A message without a reply right is dropped |

Status values (SystemConfiguration `SCDynamicStore.h` / `SCD.h`): 0
`kSCStatusOK`, 1004 `kSCStatusNoKey`.

`configopen` is sent to the service port; every other routine goes to a
session port. A routine that arrives on the wrong kind of port gets
`status` 2001 (`kSCStatusNoStoreSession`). A session ends when its port
loses its last send right (the host asks for a no-senders notification,
id 70). When it ends, the host destroys the session's receive right and the
kept notify right.

## 5. Not covered

- Stored values: `configset` and `configadd` do not store anything. The
  store's contents are the network state of §7, read-only.
- Change notifications. Nothing changes, so none is ever sent.
- Session keys, `configopen` options, and entitlement or audit-token checks.
- The simulator's own `configd_sim` store, which the guest serves itself.

## 7. The network state (NET-IMPL)

The store holds the guest's network keys (`networking.md` §3.3 and §7 item
7; built by `SCDynamicStoreNetworkState.swift` from Ycode's interface
model, `networking-ycode.md` §5): `State:/Network/Interface`,
`State:/Network/Interface/<if>/IPv4|IPv6|Link`, `State:/Network/Global/
IPv4|IPv6|DNS|Proxies`, `State:/Network/Service/<id>` and its `IPv4`,
`IPv6`, `DNS`, `Setup:/Network/Global/IPv4` (ServiceOrder),
`Setup:/Network/Service/<id>` and its `Interface`, `IPv4`, `IPv6`,
`Proxies`, `State:/Network/MulticastDNS`, `State:/Network/PrivateDNS`. Empty
with `YCODE_NO_NETWORK=1`.

| Id | Routine | Ycode's reply with the network state |
|---|---|---|
| 20010 | `configget` | the key's value as a binary property list (OOL), `status` 0; a missing key as before (1004) |
| 20016 | `configget_m` | the keys given and the keys matching the patterns (each pattern anchored, `^(…)$`): a binary-plist dictionary key → binary-plist data of the value (`_SCSerializeMultiple`), `status` 0; nothing matching: as before (1004) |
| 20008 | `configlist` | the keys matching the pattern (isRegex) or equal to the key, as a binary-plist array |

SimulatorSupport's copy-multiple returns the service and interface
entities; configd_sim computes `State:/Network/Global/*` and its DNS
configuration from them (Ycode's guest store, `networking-ycode.md` §5).
The service logs the keys a copy-multiple returned.

## 6. Diagnostics

`YCODE_DEBUG_NO_SCDYNAMICSTORE=1` skips the service (the old abort loop).
The service logs the first 16 requests (id, session, size) as
`ycode-simd: scdynamicstore: …` lines.

## Evidence

| Claim | Level |
|---|---|
| Routine numbers, parameter lists, `skip`s, `UseSpecialReplyPort`, `ServerAuditToken` (`config.defs`) | 1 (Apple open source, configd project, APSL 2.0) |
| What SimulatorSupport calls and asserts, its keys and patterns | 1 (configd `Plugins/SimulatorSupport/simulator_support.c`) |
| MIG request/reply layout (NDR record, OOL descriptor + count, `RetCode`, reply id = id + 100, 52-byte `configopen` reply with one port descriptor) | 1 (MIG conventions in open-source xnu/MIG); 3 (the 52-byte reply size seen in Ycode traces of `configd_sim`'s own server) |
| `kSCStatus*` values | 1 (public SystemConfiguration headers) |
| The abort and its rate without a host store; 49 of 61 `guest_fatal` | 3 (Ycode boots, 2026-10-13) |
| The names are registered by the host into the guest (701) | 3 (`launchd-sim.md` §6.3) |
| §7: `configget`/`configget_m`/`configlist` value encodings (`_SCSerialize`, `_SCSerializeMultiple`, anchored patterns); key and property names | 1 (configd open source; public `SCSchemaDefinitions.h`) |
| §7: which keys SimulatorSupport copies; configd_sim builds the global keys | 3 (Ycode boots: the service's log, the guest store read by `p_netpath`) |
