# Spec: the host's file-event service `com.apple.FSEvents`

Status: **specification** (agent OBS-FSEVENTS, dirty room, 2026-10-27);
**implemented** in Ycode with change events (agent FS-HOST, clean room,
2026-10-27; §10). It answers `service-fidelity.md` §11 (Q11.1–Q11.3).
Terms are as in `launchd-sim.md` (DEV, TMP, RR).

## 1. Why

The guest's public FSEvents API (FSEvents.h: `FSEventsCopyUUIDForDevice`,
`FSEventsGetCurrentEventId`, `FSEventStreamCreate`, …) is a client of a
**host** service. On the Mac the simulator registers the host's own
`com.apple.FSEvents` endpoint into the guest's `user/<uid>` domain
(`launchd-sim.md` §6.3), so every guest stream is served by the Mac's
file-event daemon and watches host paths. Ycode registers no such name:
every guest call that needs the service fails ("FSEvents_connect() =>
Unknown service name (1102)" in the guest log). §8 lists what that costs.

This spec describes the service as the guest sees it: the endpoint, the
messages and their layouts, the stream life cycle, the event messages, and
the smallest host behaviour that is enough for the guest (§7).

## 2. Endpoint and connection

- Name `com.apple.FSEvents`, a host-side endpoint of `user/<uid>` like the
  other names of `launchd-sim.md` §6.3.
- A client process looks the name up once, at its first FSEvents call
  that needs the service (`bootstrap_look_up2`, flags 8; launchd_sim logs
  a failed lookup with flags 0x9). It keeps the send right for the life
  of the process. A failed lookup is not cached: every later call looks
  the name up again and fails again.
- **Service port.** One receive right serves all clients. It receives the
  requests 66000, 66002, 66003, 66004 (and, not observed, 66005).
- **Stream port.** For every started stream the service makes a new
  receive right and returns a send right in the reply to 66000. The
  requests 66001 and 66006 of that stream go to it. The client holds the
  only send right.
- **Client port.** For every stream the client makes a receive right and
  sends a send right to it in 66000. The service sends the event messages
  (67000) to it. A stream that is stopped and started again sends the
  same client port again in its new 66000.

All requests are MIG routines with a reply: the reply port is a
send-once right (`MAKE_SEND_ONCE`), the request carries a voucher, and the
reply id is the request id + 100. Every body starts with the NDR record
(8 bytes: 0, 0, 0, 0, 1, 0, 0, 0). A simple reply then has `RetCode`
(int32, 0 = success). Integers are little-endian. Messages are packed to
4 bytes (a 64-bit field can start at a 4-byte offset).

## 3. Messages

Sizes are the sent size (header included). "—" = header only.

| Id | API call | Port | Request (after header) | Size | Reply id: body after NDR | Reply size |
|---|---|---|---|---|---|---|
| 66000 | `FSEventStreamStart` (register a stream) | service | complex, 5 descriptors (§3.1); NDR; scalars (§3.1) | 160 | 66100: complex, 1 port descriptor (the stream port, `MOVE_SEND` as received) | 40 |
| 66001 | `FSEventStreamFlushSync` | stream | — | 24 | 66101: RetCode; uint64 event id (§3.3) | 44 |
| 66002 | `FSEventsCopyUUIDForDevice` | service | NDR; uint32 dev | 36 | 66102: RetCode; char[36] UUID string (§4) | 72 |
| 66003 | `FSEventsGetCurrentEventId` | service | — | 24 | 66103: RetCode; uint64 event id | 44 |
| 66004 | `FSEventsGetLastEventIdForDeviceBeforeTime` | service | NDR; uint32 dev; int64 time (whole seconds since 2001-01-01, the `CFAbsoluteTime` argument cut to an integer) | 44 | 66104: RetCode; uint64 event id (0 when none) | 44 |
| 66006 | `FSEventStreamStop` | stream | — | 24 | 66106: RetCode | 36 |

Not observed: 66005 (presumably `FSEventsPurgeEventsForDeviceUpToEventId`;
it was not called, because it would change the Mac's event history).
`FSEventStreamCreate`, `FSEventStreamSetDispatchQueue`,
`FSEventStreamSetExclusionPaths`, `FSEventStreamGetLatestEventId` and
`FSEventStreamFlushAsync` send nothing (FlushAsync returned 0 in the
probe). `FSEventStreamInvalidate` and `FSEventStreamRelease` send nothing;
the client then destroys the client port's receive right.

### 3.1 66000: register a stream

Descriptors, in order:

| # | Kind | Content |
|---|---|---|
| 0 | port, `MAKE_SEND` | the client port |
| 1 | OOL bytes | path offsets: one uint32 per path, the offset of the path in descriptor 2 |
| 2 | OOL bytes | the paths: NUL-terminated strings, one after another |
| 3 | OOL bytes | exclusion offsets (as 1, for the exclusion paths; 0 bytes when none) |
| 4 | OOL bytes | the exclusion paths (as 2; 0 bytes when none) |

Scalars after the NDR record, in order (offsets from the start of the
body after the descriptors):

| Offset | Type | Field |
|---|---|---|
| 8 | uint32 | dev: 0 for `FSEventStreamCreate`; the device for `…RelativeToDevice` |
| 12 | uint32 | count of descriptor 1 (in uint32 elements) |
| 16 | uint32 | number of paths |
| 20 | uint32 | byte count of descriptor 2 |
| 24 | uint32 | count of descriptor 3 (in uint32 elements) |
| 28 | uint32 | number of exclusion paths |
| 32 | uint32 | byte count of descriptor 4 |
| 36 | uint64 | latency in microseconds (0.2 s → 200000) |
| 44 | uint32 | the stream's create flags (FSEvents.h `kFSEventStreamCreateFlag*`) |
| 48 | uint64 | `sinceWhen` (`kFSEventStreamEventIdSinceNow` = all ones) |

Paths. For `FSEventStreamCreate` the client sends absolute paths. A path
that exists is sent in its canonical form (on the Mac the firmlinks are
resolved: `/Users/…` is sent as `/System/Volumes/Data/Users/…`); other
paths are sent as given. For `…RelativeToDevice` the paths are relative
to the device's root and have no leading `/`. Exclusion paths are sent
canonical too. The client gets the canonical form itself, from
`getattrlist` on each path with `ATTR_CMN_RETURNED_ATTRS` and the extended
common attribute `ATTR_CMNEXT_NOFIRMLINKPATH` (`FSOPT_ATTR_CMN_EXTENDED`);
whatever the guest's kernel answers there is the path the service
receives.

### 3.2 67000: events (service → client port)

A one-way message (no reply port, no voucher), complex, 4 OOL
descriptors, then NDR and five uint32: the number of events n, then the
element counts of descriptors 0, 1 and 2 (each n), then the byte count of
descriptor 3. Size 120.

| # | Content |
|---|---|
| 0 | uint32[n]: the offset of each event's record in descriptor 3 |
| 1 | uint32[n]: each event's flags, in the wire encoding of §3.4 |
| 2 | uint64[n]: each event's id |
| 3 | the event records: the event's path, NUL-terminated; for a stream created with `kFSEventStreamCreateFlagUseExtendedData` (0x40) followed by 12 bytes: uint64 file id (the inode number) and uint32 document id (0 when the file has none) |

One message carries one or more events (the service batches events that
fall into one latency period). Event paths are in the form the client
registered (canonical, or relative for a relative stream); the client
translates them back to the strings the application passed. A directory-
level stream (no `kFSEventStreamCreateFlagFileEvents`) gets the changed
directory's path with a trailing `/`.

### 3.3 Event ids

64-bit, one sequence for the whole host, increasing (about 1.204 × 10⁹ on
the observed Mac). 66003 returns the current id. A stream's 66001 reply
carries the id of the last event the service sent to that stream (0 if
none). `FSEventStreamGetLatestEventId` is answered by the client itself.

### 3.4 Event flag encoding on the wire

The service sends its own flag bits; the client converts them to the
FSEvents.h `kFSEventStreamEventFlag*` values it passes to the callback:

| Wire bit | Delivered flag |
|---|---|
| 0x00000001 | ItemCreated (0x100) — file, symbolic link, hard link |
| 0x00000080 | ItemCreated (0x100) — directory |
| 0x00000002 | ItemRemoved (0x200) |
| 0x00000004 | ItemInodeMetaMod (0x400) |
| 0x00000008 | ItemRenamed (0x800) |
| 0x00000010 | ItemModified (0x1000) |
| 0x00000100 | ItemChangeOwner (0x4000) (seen for `chmod`) |
| 0x00000200 | ItemXattrMod (0x8000) |
| 0x00004000 | ItemCloned (0x400000) |
| 0x00100000 | ItemIsHardlink (0x100000) |
| 0x00200000 | OwnEvent (0x80000); seen on every event of the one stream with `kFSEventStreamCreateFlagMarkSelf` whose events were all its own (no other file-level event was recorded, so the bit's meaning rests on that stream) |
| 0x00400000 | ItemIsSymlink (0x40000) |
| 0x00800000 | ItemIsFile (0x10000) |
| 0x01000000 | ItemIsDir (0x20000) |
| 0x08000000 | HistoryDone (0x10) |
| 0x40000000 | MustScanSubDirs \| UserDropped (0x3) (the service dropped events for this client) |
| 0x00001000 | none (sent with the document-id records of a `/.docid` stream) |

Item bits reach the callback only on a file-level stream; a directory-
level stream gets flags 0 for ordinary changes (ItemCloned and the
dropped-events flags did reach one). Examples (wire → delivered, file-level stream
with MarkSelf): new file written 0x00A00011 → 0x00091100; `chmod`
0x00A00111 → 0x00095100; `setxattr` 0x00A00311 → 0x0009D100; rename, old
name 0x00A00319 → 0x0009D900, new name 0x00A00008 → 0x00090800; `mkdir`
0x01200080 → 0x000A0100; `rmdir` 0x01200082 → 0x000A0300.

`kFSEventStreamEventFlagRootChanged` (0x20, event id 0) for a stream with
`kFSEventStreamCreateFlagWatchRoot` is made by the client itself, not sent
by the service.

## 4. Device UUIDs (66002)

The reply string is the UUID of the service's event store for that
device, in the 36-character form, with no NUL. For a device the service
does not know (dev 0, a made-up device) the reply is RetCode 0 and the
36 bytes `NO-UUID-UNKNOWN-DEVICE` followed by NUL bytes; the client then
returns NULL. The public documentation lets `FSEventsCopyUUIDForDevice`
return NULL when no UUID is available, and says that event ids are
comparable only while the UUID stays the same.

On the Mac the guest's data directory is on the host's data volume, so
every guest path has the same device (`0x100000e`, major 1, minor 14) and
the same UUID. The UUID is not the volume's APFS UUID; it is the event
store's own, and it was the same in both boots in which it was read
(device `ycode-test-fsevents-1`, boots 2 and 3, 2026-10-27). Clients store it: fileindexerd keeps `streamUUID`
and `lastEventID` in its state file
(`DEV/data/Containers/Data/InternalDaemon/<container>/indexingState`, a
JSON object), reads them back at its next start and asks the service
for the UUID again (§6).

## 5. Stream life cycle

1. `FSEventStreamCreate` / `…RelativeToDevice`: nothing is sent.
2. `FSEventStreamStart`: the client looks the service up (first use),
   makes the client port, and sends 66000. The reply's stream port is
   watched by the client for a dead name. Start returns true when the
   reply carries a port.
3. If `sinceWhen` is not `SinceNow`, the service sends, after any stored
   events newer than `sinceWhen`, one event with flags 0x08000000
   (HistoryDone), the stream's first path (registered form), and as id
   the `sinceWhen` it was given (in every observation the history was
   empty, so only this event was sent). With `SinceNow` nothing is sent.
4. Events (67000) as changes happen, after the latency.
5. `FSEventStreamFlushSync`: 66001 on the stream port; the reply's id.
6. `FSEventStreamStop`: 66006 on the stream port; after the reply the
   client drops its send right to the stream port (the service sees no
   more senders). A new `FSEventStreamStart` repeats step 2 with the same
   client port and `sinceWhen` = the last id the client received.
7. `FSEventStreamInvalidate` / `Release`: the client destroys the client
   port.

The service filters per client: a stream with
`kFSEventStreamCreateFlagIgnoreSelf` (0x8) gets no events that its own
process caused; a stream with `…MarkSelf` (0x20) gets them with the
OwnEvent bit.

## 6. Who uses it in an iOS 27.1 boot

Observed on the Mac (§9), second and later boots of a throwaway device:

| Process | Calls | Watched (DEV = the device's data directory) |
|---|---|---|
| fileindexerd (FileProvider's change monitor) | 66002 ×2, 66003, 66000 | `DEV/data/Containers/Shared/AppGroup/<group.com.apple.FileProvider.LocalStorage>/File Provider Storage` and its parent; latency 0.2 s; flags 0x1F1 (CF types, file events, mark self, extended data, document ids); `sinceWhen` = the current id |
| UserEventAgent (the `com.apple.fsevents.matching` plug-in) | 66003, 66000 (≈25), 66006 (≈20) | the `WatchPaths` / `QueueDirectories` of launchd jobs and of `com.apple.fsevents.matching` launch events, e.g. bookdatastored's `Mobile Documents/iCloud~com~apple~iBooks/Documents`, nsurlsessiond's queue directory, configuration-profile and eligibility files |
| cfprefsd | 66000, 66006 (stream replaced as preference directories are added) | `DEV/data/Library/Preferences` and the `Library/Preferences` of app and group containers; latency 0; flags 0x19 |
| revisiond | 66003, 66000 (relative to the device) | `/.docid` of the data volume (document-id changes) |
| configd_sim | 66000 | the **host's** `/Library/Preferences/SystemConfiguration/resolver` |
| fontservicesd | 66000 | `DEV/data/private/var/MobileAsset/AssetsV2/com_apple_MobileAsset_Font8/` |
| DockFolderViewService | 66000 | `/` (the whole **host**) with 6 exclusion paths, latency 0.5 s |

On the Mac several of these see host files (configd_sim's resolver
directory, DockFolderViewService's `/`, revisiond's volume-wide document
ids). Ycode serves the guest's own file system, so these streams see only
guest changes; that is a deliberate difference.

## 7. The minimal host behaviour

**Requirement.** Register `com.apple.FSEvents` like the other host names
and answer:

| Request | Minimal answer |
|---|---|
| 66002 | RetCode 0 and a fixed UUID string per device of the guest's data (one per Ycode device, kept with the device so that it is the same in every boot; a new UUID tells clients that their stored ids are void, which they handle by rescanning) |
| 66003 | RetCode 0 and an id that never decreases across boots of the device (for example a counter kept with the device and advanced by every answer and every event) |
| 66004 | RetCode 0 and id 0 |
| 66000 | a new stream port; keep the client port's send right; if `sinceWhen` is not `SinceNow`, send the HistoryDone event of §5 step 3 |
| 66001 | RetCode 0 and the last id sent to the stream (0 if none) |
| 66006 | RetCode 0; the stream sends nothing more |
| other | the MIG error reply `MIG_BAD_ID` (−303); a message without a reply right is dropped |

End a stream when its stream port has no more senders (ask for the
no-senders notification) and drop its client port then.

**Checked against the guest's client library (§9.3, level 3).** A
stand-in that answered 66002 with a fixed UUID string, 66003 with a
counter starting at 1000, 66000 with a new stream port (plus the
HistoryDone event when `sinceWhen` was not `SinceNow`), 66006 with
RetCode 0, and everything else with `MIG_BAD_ID`, was used by our probe
through the public API exactly as the Mac's service: the UUID came back
as that CFUUID, the current id as 1000, all three streams started
(`FSEventStreamStart` true, including the relative one), each got its
HistoryDone callback (flags 0x10, id = its `sinceWhen`), Stop sent 66006
and then dropped the stream port (the stand-in got the no-senders
notification, id 70), and a restart re-registered with `sinceWhen` = the
last id received. The client also accepted `MIG_BAD_ID` for 66001
(FlushSync returned) and 66004 (the call returned 0); the table above
still gives the proper answers.

**fileindexerd needs none of it to stay up on the Mac (§9.3).** With
the look-up answered 1102 inside fileindexerd (and
`com.apple.FileProvider.sim2host` denied too), on a device that had used
the real service before and on a new device, fileindexerd logged "failed
to get stream UUID for device 16777230", got `false` from
`FSEventStreamStart`, and went on: it registered its root, ran its scan
task and stayed up until the shutdown, 5 and 7 minutes after the
failed calls (one start in each boot; the processes had run 33 and 107
minutes in all, most of it starved by the host's load). It did not
log the subscription failure (POSIX 19) or the fatal error seen in
Ycode (`service-fidelity.md` §11). The service is therefore not what
keeps fileindexerd alive; §7's behaviour gives the guest file-event
notification and removes the failed calls. Ycode's crash comes from the
volume capabilities that Ycode's `getattrlist` reports for the data
volume: injecting Ycode's two capability words into fileindexerd's reply
on the Mac reproduces the crash word for word (`service-fidelity.md`
§11, Q11.2).

With the stand-in serving fileindexerd on a new device (the minimal
answers plus HistoryDone, never a change event), fileindexerd started its
stream (`sinceWhen` = the stand-in's 1000), processed the HistoryDone
event (one event-processing transaction), wrote `streamUUID` = the
stand-in's UUID and `lastEventID` = 1000 into its state file, scanned and
stayed up: the same course as with the Mac's service.

**Change events (beyond the minimum).** To deliver events, watch the
registered paths in the host file system (inotify on Linux), map host
paths back to the registered guest form, batch per latency period, and
encode flags as §3.4 (file-level streams: item bits and the item kind;
own-process events: OwnEvent for MarkSelf streams, none for IgnoreSelf
streams; directory-level streams: the directory path with `/` and flags
0). Apply the exclusion paths. History replay is not needed: answer every
`sinceWhen` as if no stored event were newer, i.e. with HistoryDone only.

## 8. What the missing service costs today (Ycode)

- fileindexerd: its file-provider root gets no change notification
  (it rescans instead); its crash in Ycode is caused by the volume
  capabilities, not by this service (`service-fidelity.md` §11).
- UserEventAgent's `com.apple.fsevents.matching` plug-in cannot watch
  anything, so `WatchPaths` / `QueueDirectories` of launchd jobs
  (bookdatastored, nsurlsessiond) and the jobs' `com.apple.fsevents.matching`
  launch events never fire.
- cfprefsd does not notice preference files written by other processes
  directly to disk; revisiond, configd_sim, fontservicesd and
  DockFolderViewService run without change notification. None of them
  stops (all ran normally on the Mac with the lookup denied; §9.3).

## 9. How this was observed (summary)

Details: `research/notes/obs-fsevents-2026-10-27.md`.

1. **Recorder.** Ycode's own interposing library (built for the simulator
   SDK, kept in the dirty room) inserted into every guest process of a
   boot of a throwaway Mac device (iPhone Duo, iOS 27.1 24A94401, macOS
   27.2, Xcode 27.1). It records each bootstrap look-up and XPC
   connection name, each Mach message to and from the service, stream and
   client ports (header, descriptors, bytes), and the public API calls
   with their arguments, results and callback deliveries.
2. **Probe.** Our own program using only the public FSEvents API, run in
   the guest with the recorder: device UUIDs for known and unknown
   devices, current and last ids, three streams (file-level with extended
   data, document ids, MarkSelf and an exclusion path; directory-level
   with NoDefer and WatchRoot; relative to the device with IgnoreSelf),
   fourteen file operations, flushes, stop, restart, invalidate.
3. **Stand-in.** In fileindexerd (and, in one run, the probe) the
   look-up of `com.apple.FSEvents` is answered either with 1102 (as Ycode
   does) or with a port served by a thread in the same process that gives
   the answers of §7 and never sends a change event;
   `com.apple.FileProvider.sim2host` (also absent in Ycode) is denied too.
   No Mac setting was changed.

## 10. Ycode implementation

Code: `ycode/Sources/YcodeHostServices/FSEventsHostService.swift`; started
by the device session (`ycode-simd/DeviceSession.swift`); tests
`FSEventsHostServiceTests`; guest probe
`ycode/SimShim/guest-tests/fsevents/p_fsevents.c` (public API only).

**Endpoint.** `com.apple.FSEvents` is a host-side name of `user/<uid>`
(`launchd-sim.md` §6.3), registered with the late names (after the GPU,
surface and HID names; a client that looks it up earlier goes on without
events, §7). One service port; one stream port per started stream (a member
of the service's port set, with a no-senders request); the client port's
send right is kept until the stream port loses its last sender.
`YCODE_DEBUG_NO_FSEVENTS=1` leaves the name unregistered (the old state);
`YCODE_FSEVENTS_NO_CHANGES=1` gives the minimal service of §7.

**Requests.** As §3 and §7: 66002 answers the store UUID for the guest's
data volume (device 0x01000010, which holds DEV, the temporary directories
and /System's view; Ycode's runtime volume is read-only and has no store)
and `NO-UUID-UNKNOWN-DEVICE` otherwise; 66003 the last event id issued;
66004 id 0 (no history is kept); 66000 a new stream port (a malformed
request: MIG_BAD_ARGUMENTS); 66001 sends the stream's pending events at once
and answers the id of the last event sent to it; 66006 stops the stream;
anything else MIG_BAD_ID; a message without a reply right is dropped.

**The store.** `DEV/ycode-fsevents.plist`: `UUID` (made at the device's
first boot, kept) and `ReservedEventID`. Event ids start at 1000 and are
reserved 10 000 at a time: the file is written when a reservation is used
up, and a new boot (or a restore, whose DEV holds the file as it was at the
save) continues after the last reservation, so ids never go back and are
never issued twice.

**Change events.** Ycode does not watch the host. Its VFS reports every
change a guest process makes (`file-system-features.md` §7): the kind, the
item type, the canonical guest path and the process. A stream's paths are
made canonical when it starts (symbolic links resolved; for a path that
does not exist yet, its nearest existing ancestor's canonical path plus the
rest), so a stream on `/tmp/x` sees changes made as `/private/tmp/x/…`;
relative streams are relative to "/" (the data volume's mount point). A
change at or below a stream's path, and not below an exclusion path, is
queued for the stream:

| VFS change | Wire flags (§3.4) |
|---|---|
| file created (`open(O_CREAT)` of a new name) | 0x1 \| IsFile |
| directory created (`mkdir`) | 0x80 \| IsDir |
| removed (`unlink`, `rmdir`) | 0x2 \| type |
| renamed (both names; `rename`, `renameatx_np`, RENAME_SWAP) | 0x8 \| type |
| contents (`write`, `pwrite`, `writev`, `truncate`, `ftruncate`, `O_TRUNC`) | 0x10 \| IsFile |
| owner, mode (`chmod`, `fchmod`, `chown`) | 0x100 \| type (the Mac reports `chmod` as ChangeOwner) |
| times, file flags (`utimes`, `futimes`, `setattrlist` times, `chflags`) | 0x4 \| type |
| extended attributes (`setxattr`, `removexattr`) | 0x200 \| type |
| clone (`clonefileat`, `fclonefileat`) | source 0x4000 \| type; target 0x4000 \| 0x1 or 0x80 \| type |

Type bits: IsFile 0x00800000, IsDir 0x01000000, IsSymlink 0x00400000. A
change by the stream's own process (the 66000 sender's pid) is dropped for
`IgnoreSelf` and marked 0x00200000 (OwnEvent) for `MarkSelf`. A file-level
stream gets the item's path; a directory-level stream the containing
directory's path with `/` and flags 0 (only Cloned and dropped-events bits
are kept). Paths are reported in the stream's registered form (the
registered path plus the rest), relative for a relative stream.

**Coalescing.** A stream's queued changes are merged per path (flags ORed,
first-seen order) and sent when the stream's latency has passed since its
first queued change; with `NoDefer` a change after a quiet period of at
least the latency is sent at once. Each event gets the next id. At most
1024 events go in one 67000 message. A send never waits: a full client
queue drops the batch and the stream's next event carries 0x40000000
(MustScanSubDirs | UserDropped). `UseExtendedData` streams get each event's
inode number and document ID (0 for an object that is gone or untracked).
`HistoryDone` is sent at once to a stream registered with a `sinceWhen`
other than `SinceNow`, with that id (§5 step 3; no history is replayed).

**Snapshots.** The streams (stream and client port names, process, paths,
flags, latency, last id) are kept in the snapshot's host-service record
(`fsevents`) and served again after a restore; events pending at the save
are not replayed.

**Differences from the Mac (by design).** Ycode's service sees only the
guest's own changes made through Ycode: not changes made on the host
behind the guest's back, not the host's files (configd_sim's resolver
directory, DockFolderViewService's `/` are guest paths here, §6), and not
writes through a writable shared mapping. No document-id (`/.docid`)
events and no event history are kept. Hard links are not reported as such
(Ycode has no `link`). None of the streams logged in a full boot (the first
64 registrations) watches `var/run/simulatoraudio`; the running app's
volume (`simulator-features.md` I.9) was a kqueue `EVFILT_VNODE` matter
(the app watches that directory with a vnode source), fixed in
`threads-and-events.md` §3.10.

**Host writes (agent VNODE-EVENTS, 2026-10-28).** Files that `ycode-simd`
itself writes into a running device's data tree (the settings controller's
audio settings, preference and Environment Overrides files,
`simulator-features.md`) go through one hook, `HostDataWrites`
(`YcodeDarwinABI/VnodeNotes.swift`), which reports to this service the same
changes a guest process's safe save would make, with pid 0: the temporary
file created and modified, then renamed, and the name renamed (so a
`MarkSelf` stream never marks them as its own, and `IgnoreSelf` never drops
them); a directory it makes is reported created. The same hook fires the
kernel's vnode notes. Changes that other host processes make behind the
guest's back are still not seen (no host watch; the decision is in
`threads-and-events.md` §3.10).

**Checked on the Linux host (2026-10-28).** The guest probe passes on two
boots of one device: capability words, generation counts, UF_TRACKED and a
safe save, `clonefile` (EEXIST onto an existing name), `RENAME_EXCL`
(EEXIST; a free name), `RENAME_SWAP`, NULL UUID for device 0, the device's
UUID (the same in both boots) and current id (1007, then 11009 in the next
boot: a new reservation, never back), file events of a new file (created,
modified, ChangeOwner for `chmod`, extended attribute, renamed, OwnEvent;
then the new name; a directory created and removed) and HistoryDone for a
stream since an id. fileindexerd starts once in 700 s
(`service-fidelity.md` §11, Ycode implementation).

## Evidence

| Claim | Level |
|---|---|
| The API names and their documented results (NULL UUID allowed, event ids comparable only for one UUID, `kFSEventStream*` flag values) | 1 (public FSEvents.h documentation) |
| The host registers `com.apple.FSEvents` in the guest | 3 (`launchd-sim.md` §6.3) |
| Message ids, ports, layouts, sizes, field meanings, reply contents (§2–§5) | 3 (recorder traces of guest clients and of the probe on the Mac, 2026-10-27; fields identified by varying the probe's arguments) |
| Wire flag encoding (§3.4) | 3 (wire flags and the flags delivered to the callback, paired by event id, for 14 operations and three host-side streams) |
| The UUID differs from the APFS volume UUID; stable across boots; stored by fileindexerd | 3 (`diskutil info`; five boots; the state file read as data) |
| Clients and watched paths (§6); jobs with `WatchPaths`/`QueueDirectories` | 3 (recorder); 2 (RR job plists read as data) |
| The client library accepts the minimal answers; fileindexerd stays up without the service and with the minimal stand-in (§7) | 3 (stand-in runs with the probe and with fileindexerd, and look-ups denied, on three devices, §9.3) |
| Ycode's fileindexerd crash comes from the data volume's capability bits (§7) | 3 (fault injection on the Mac; `service-fidelity.md` §11) |
| Interposition of the guest's own calls (method) | 3 (black-box; our own code) |
| Ycode's service, its store, flag mapping and coalescing (§10) | Ycode design (from §2–§7); unit tests `FSEventsHostServiceTests`; guest probe `p_fsevents` on the Linux host (runs `fsh/probe1`, `probe2`) |
| No guest stream on `var/run/simulatoraudio` (§10) | 3 (the service's stream log of a full boot, `fsh/probe1`) |
| Host writes reported through `HostDataWrites` (§10) | Ycode design; unit test `VnodeEventsTests.anotherProcessAndTheHostPost` |
| Darwin's own change kinds behind the flags (FSE_CREATE_FILE, FSE_CHOWN for chmod, FSE_STAT_CHANGED, FSE_CLONE pairs) (§10) | 1 (xnu `bsd/sys/fsevents.h`, `bsd/vfs/vfs_syscalls.c`) |

No disassembly or decompilation was used (level 5 not used).
