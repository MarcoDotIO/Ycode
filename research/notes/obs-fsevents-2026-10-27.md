# The host's file-event service, intelligencetasksd and PosterBoard (agent OBS-FSEVENTS, 2026-10-27)

Dirty-room notes behind `specs/simulator/fsevents-host.md` and the answers
in `service-fidelity.md` §11 and §13. Prose only. Raw traces, the recorder,
the probe, the stand-in and scripts live in `research/dirty/obs-fsevents/`
(git-ignored). No disassembly or decompilation; Ghidra, the reference tools
folder and the IPSW were not opened. Evidence levels as in AGENTS.md rule 4.

## Setup

- Mac15,10, macOS 27.2 (26B5112a), Xcode 27.1, iOS 27.1 runtime
  (24A94401), device type iPhone Duo. Throwaway devices only:
  `ycode-test-fsevents-1` (four boots: discovery, probe, deny runs; two
  earlier boot attempts ended in launchd_sim crashes caused by the first
  recorder versions),
  `-2` (Q13.1, no recorder), `-3` (new device: deny run, the reproduction
  of Ycode's crash and the capability bisection, five boots) and `-4`
  (new device: stand-in runs, three boots). All deleted at the end. No
  other simulator was touched; no Mac setting was changed.
- The Mac was shared with other agents' visionOS boots and was heavily
  loaded the whole afternoon: load averages 90–1000 on 14 cores. Adaptive
  daemons (fileindexerd among them) were starved: a step of fileindexerd's
  start that takes seconds on a quiet Mac took up to ten minutes, and its
  first FSEvents call came 3 to 40+ minutes after its spawn. All counts and
  times below must be read with that in mind.
- No copy of a Ycode run's `DEV/data` was available locally (the golden
  device lives on the Thor, which this agent does not touch), so Q13.1 used
  new devices.

## Method

1. **Recorder** (`fsevrec`, C, built for `arm64-apple-ios27.0-simulator`,
   inserted with `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` into every guest
   process of a boot). Per process it records: every `bootstrap_look_up`,
   `…2`, `…3` (name, flags, result, caller image) and every
   `xpc_connection_create_mach_service` name into one shared file; Mach
   messages sent to a port obtained from a `com.apple.FSEvents` look-up or
   received from it, messages sent by the FSEvents client image, and
   messages received on receive rights the client handed to the service
   (header, descriptors, bytes); the public FSEvents API calls with
   arguments, results, caller chains, and each callback delivery (event
   ids, flags, paths, extended-data dictionaries); port deallocation of the
   tracked ports. Lessons: a hook that runs before libSystem is initialised
   must not touch `getenv` or thread-local storage (two launchd_sim crashes
   of the first versions); CoreFoundation and CoreServices are bound
   weakly so that the library does not load them into small daemons.
2. **Probe** (`fsprobe`, C, public API only), run in the guest with
   `simctl spawn` (spawned processes inherit the boot's insertion): UUIDs
   for the data volume, dev 0 and a made-up device; current id; last id
   before a time for two devices; three streams (A: file events, CF types,
   extended data, document ids, MarkSelf, one exclusion directory, latency
   0.3 s; B: directory level, NoDefer, WatchRoot, two paths, latency 1 s;
   C: relative to the device, file events, IgnoreSelf, latency 0.5 s); 14
   file operations (create+write, append, chmod, setxattr, rename, symlink,
   hard link, mkdir, rmdir, create in a subdirectory, create in the
   excluded directory, three unlinks); FlushAsync, FlushSync on all three,
   GetLatestEventId, Stop, Start again, one more file, then
   Stop/Invalidate/Release.
3. **Stand-in** (in the recorder, active only in fileindexerd and, in one
   run, the probe): the
   `com.apple.FSEvents` look-up is answered with 1102 (`deny`, as in
   Ycode) or with a send right to a port that a thread of fileindexerd
   itself serves (`serve`): 66002 → a fixed test UUID, 66003 → an id
   counting from 1000, 66000 → a new stream port (no events ever),
   66001 → last id, 66006 → 0, anything else → `MIG_BAD_ID`.
   `com.apple.FileProvider.sim2host` (also absent in Ycode) is denied too
   in the stand-in runs.
4. **Fault injection** (in the recorder, fileindexerd only): the two
   capability words of a `getattrlist` reply that asks for
   `ATTR_VOL_CAPABILITIES` are replaced by values from an environment
   variable or, re-read at every call, from a file; the rest of the reply
   is the Mac's. `getattrlist`, `fgetattrlist`, `getattrlistat`, `statfs`
   and `fstatfs` calls of fileindexerd are logged with their answers.

## Results: the protocol (Q11.1)

Recorded in `fsevents-host.md` §2–§5. Points that needed care:

- Field identification of 66000: the two counts at body offsets 12 and 16
  are equal in every message (path count); with one exclusion path the
  probe's message had 1, 1, 141 at offsets 24, 28, 32 (offsets count,
  exclusion count, exclusion bytes), and DockFolderViewService's had 6, 6,
  151 with a 24-byte offsets descriptor. The latency field: 0.2 s → 200000,
  0.3 s → 300000, 0.5 s → 500000, 1 s → 1000000, 3 s → 3000000 (fontservicesd),
  0 → 0 (cfprefsd), so microseconds; its upper half is always 0. The dev
  field is 0x100000e only for the relative streams (revisiond, probe C).
- 66004's time: for "now − 60 s" the request carried 814823885 and
  814823896 for two calls 11 s apart, the integer part of the
  `CFAbsoluteTime` argument.
- The unknown-device answer of 66002 is the text NO-UUID-UNKNOWN-DEVICE in
  the 36-byte field, RetCode 0; the client returns NULL.
- 66006 is Stop (it follows every FSEventStreamStop, on the stream port,
  including the probe's stop before its restart); 66001 is FlushSync (one
  per call; the reply id equals the stream's last delivered id, 0 for the
  IgnoreSelf stream that got no events). FlushAsync sent nothing and
  returned 0.
- The probe's restart reused the client port and sent `sinceWhen` = the
  last id it had received; the service answered with HistoryDone for that
  id at once.
- IgnoreSelf is applied by the service: stream C's client port received
  only the HistoryDone message, while A and B received 15 and 8 messages
  for the same operations.
- Event paths in 67000 start with `/System/Volumes/Data/Users/…` (the
  canonical form the client registered); the callback got `/Users/…` (the
  string the probe passed).
- Extended records: 12 bytes after each path when the stream asked for
  extended data: a uint64 equal to the callback's `fileID` (the inode
  number) and a uint32 that was always 0 (no document id was assigned in
  these operations). History-done records of such a stream have 12 zero
  bytes.
- Wire flags were paired with delivered flags by event id (14 operations
  on the probe, 46 931 + 4 489 + 3 events on DockFolderViewService's host
  `/` stream, 633 document-id events on revisiond's `/.docid` stream). The
  bit 0x200000 appeared on every event of the MarkSelf stream and was
  delivered as OwnEvent; no non-own file-level event was recorded, so
  "0x200000 = own event" rests on that one stream.

Clients seen in boots 1–4 of device 1: fileindexerd, UserEventAgent (the
`com.apple.fsevents.matching` plug-in: ≈25 registrations in a boot, many
replaced at once), cfprefsd (a stream replaced by a larger one each time a
preferences directory is added: 1 → 6 paths in 94 s), revisiond (`/.docid`
relative to the data volume; on the Mac it gets the host volume's
document-id changes, 633 in one boot), configd_sim (the host's resolver
directory), fontservicesd, DockFolderViewService (the host's `/` with six
exclusions; 51 000 events in one boot).

## Results: the UUID (Q11.3)

- Every guest path is on the host data volume (dev 0x100000e, 1,14); its
  FSEvents UUID (value kept in the dirty folder) was the same in both boots in
  which it was read (device `-1`: fileindexerd in boot 2, the probe in
  boot 3). The volume's APFS UUID is different
  (also kept in the dirty folder), so the FSEvents UUID is the event store's own.
- fileindexerd writes `streamUUID` (that UUID) and `lastEventID` (the id
  it used as `sinceWhen`) into
  `DEV/data/Containers/Data/InternalDaemon/<fileindexerd's container>/indexingState`
  (JSON, with its roots and scans). At the next start it logs "successfully
  loaded state from disk with state: IndexingState(streamUUID: …, # roots:
  1, # scans: 1)" and then asks the service for the UUID again.

## Results: what fileindexerd does without the service (Q11.2)

- **Device 1, boot 4, lookup denied** (state stored in boot 2 with the
  real service): fileindexerd logged "FSEventsCopyUUIDForDevice: ERROR:
  FSEvents_connect() => Unknown service name (1102)", "failed to get stream
  UUID for device 16777230", "FSEventsGetCurrentEventId: ERROR …",
  "FSEventStreamStart: ERROR …" (Start returned false), and went on: it
  registered its roots, ran its scan task, and stayed up until the
  shutdown about 5 minutes later (the process had run 33 minutes in all,
  most of it starved; exit 0 at shutdown). **No crash.** So the bare
  absence of the service is not what kills fileindexerd in Ycode (the
  cause is below: the volume capabilities).
- **Device `-3`, second boot (new device, fresh path), lookup denied and
  `com.apple.FileProvider.sim2host` denied**: "[StateManager] Spotlight
  clientState is nil -- fresh device, no prior index", then the same two
  errors and `FSEventStreamStart` false (its `sinceWhen` was SinceNow;
  the current id had come back 0), "simulator host support level 1"
  (level 2 with sim2host), scan task run, up until the shutdown 7 minutes
  later. **No crash.** The state file got `lastEventID` 0 and no
  `streamUUID`.
- Neither run logged "failed to subscribe to events in …" or "Failed to
  init after preparing dependencies", the two lines of Ycode's crash.
- **Stand-in, probe** (device `-4`, third boot): every API call worked
  against the stand-in (details in the spec §7). The stand-in had no
  answer for 66001 and 66004 and sent `MIG_BAD_ID`; the client accepted
  both (FlushSync returned; the last-id call returned 0).
- **Stand-in, fileindexerd** (same boot; new-device state): stream
  registered with `sinceWhen` 1000 (the stand-in's current id), HistoryDone
  processed ("begin transaction event processing) count 0" … "end
  transaction event processing count 1"), state file written with the
  stand-in's UUID and `lastEventID` 1000, scan, up until the shutdown.
- **What fileindexerd asks the kernel before it subscribes** (recorder with
  `getattrlist`, `fgetattrlist`, `getattrlistat`, `statfs`, `fstatfs`
  logging, same run). In order:
  1. FileProvider: `getattrlist(<group container>/File Provider Storage,
     ATTR_CMN_FULLPATH)` → the path.
  2. FileProviderDaemon: `fstatfs` on a descriptor of the root → type
     `apfs`, flags 0x04909080, fsid {0x0100000E, 0x1A}, mounted on
     `/System/Volumes/Data`.
  3. FileProviderDaemon: `getattrlist("/System/Volumes/Data",
     common ATTR_CMN_DEVID, volume ATTR_VOL_INFO | ATTR_VOL_CAPABILITIES)`
     → dev 0x0100000E; capabilities: format 0x019B6EDF, interfaces
     0x01AF6FC7, valid 0x07FFFFFF and 0x01FFFFFF.
  4. `FSEventsCopyUUIDForDevice(0x0100000E)`.
  5. CoreServices (the FSEvents client): `getattrlist` on each of the two
     paths with `ATTR_CMN_RETURNED_ATTRS` and the extended attribute
     0x20 (`ATTR_CMNEXT_NOFIRMLINKPATH`) → `/System/Volumes/Data/Users/…`.
  6. `FSEventStreamCreate` (flags 0x1F1, which include
     `kFSEventStreamCreateWithDocID`), Start.
- Ycode's own answer to step 3 (read from `ycode/Sources/YcodeDarwinKernel/AttributeList.swift`):
  format 0x00024F47, interfaces 0x00004302. Missing against the Mac's
  data volume: format `JOURNAL`, `JOURNAL_ACTIVE`, `ZERO_RUNS`,
  `HIDDEN_FILES`, `DECMPFS_COMPRESSION`, `DOCUMENT_ID`,
  `WRITE_GENERATION_COUNT`, `SHARED_SPACE`, `VOL_GROUPS`; interfaces
  `SEARCHFS`, `NFSEXPORT`, `ALLOCATE`, `VOL_RENAME`, `EXTENDED_SECURITY`,
  `USERACCESS`, `NAMEDSTREAMS`, `CLONE`, `SNAPSHOT`, `RENAME_SWAP`,
  `RENAME_EXCL`, `RENAME_SECLUDE`, `PUNCHHOLE`, `BARRIERFSYNC` (names
  from the macOS SDK's `sys/attr.h`).
  Ycode sets `VOL_CAP_FMT_CASE_SENSITIVE`, which the Mac's volume does not.
- **Fault injection: Ycode's capability words on the Mac** (device `-3`,
  third boot; lookup and sim2host denied as before; our recorder replaces
  the format and interface capability words in fileindexerd's
  `getattrlist` replies with Ycode's 0x00024F47 and 0x00004302).
  Result: **Ycode's crash, reproduced.** State loaded from disk
  ("IndexingState(streamUUID: nil, # roots: 1, # scans: 1)"), the
  FSEvents errors as before, then the change monitor's `fstatfs` and
  `getattrlist` (capabilities replaced; the reply was otherwise the
  Mac's), then a `statfs` of CoreFoundation's errno string table (the
  error being described), then "failed to subscribe to events in
  <GroupContainers>/…/F{19}e with NSError: POSIX 19 "The operation
  couldn’t be completed. Operation not supported by device"", "Failed to
  subscribe to root …, registering it for removal", "Setting up roots",
  the same two calls and the same error again, and "FileIndexerDaemon/
  FileIndexerDaemon.swift:638: Fatal error: Failed to init after
  preparing dependencies: Error Domain=NSPOSIXErrorDomain Code=19
  "Operation not supported by device"" → SIGTRAP, "service has crashed 1
  times in a row". These are Ycode's lines word for word.
- **Which bit** (device `-3`, fourth and fifth boots; capability words read from a
  file at each call, so that launchd's restarts can try other values
  within one boot; a surviving start was killed so that the next start
  read the next value). "up" = `FSEventStreamStart` reached and the
  process alive 25 s later; "crash" = the POSIX 19 subscription error
  and the fatal error, SIGTRAP. Mac = 0x019B6EDF / 0x01AF6FC7, Ycode =
  0x00024F47 / 0x00004302.

  | # | Format word | Interface word | Result |
  |---|---|---|---|
  | 1 | Ycode | Ycode | crash (boot 3, the reproduction above) |
  | 2 | Ycode + DOCUMENT_ID (0xA4F47) | Ycode | crash |
  | 3 | Mac | Ycode | crash |
  | 4 | Ycode | Mac | crash |
  | 5 | 0xA4F47 | Mac | crash |
  | 6 | Mac | Mac | up (control) |
  | 7 | Mac + CASE_SENSITIVE | Mac | up |
  | 8 | Mac − {DECMPFS, DOCUMENT_ID, WRITE_GEN, SHARED_SPACE, VOL_GROUPS} | Mac | crash |
  | 9 | Mac − {WRITE_GEN, SHARED_SPACE, VOL_GROUPS} | Mac | crash |
  | 10 | Mac − VOL_GROUPS | Mac | up |
  | 11 | Mac − SHARED_SPACE | Mac | up |
  | 12 | Mac − WRITE_GENERATION_COUNT | Mac | crash |
  | 13 | Mac | Mac − 0x01AF0000 (CLONE and higher) | crash |
  | 14 | Mac | Mac − {RENAME_SECLUDE, PUNCHHOLE, BARRIERFSYNC} | up |
  | 15 | Mac | Mac − {CLONE, SNAPSHOT} | crash |
  | 16 | Mac | Mac − CLONE | crash |
  | 17 | Ycode + WRITE_GEN | Ycode + CLONE | crash |
  | 18 | Mac | Ycode + CLONE | crash |
  | 19 | Mac | Ycode + CLONE + the Mac's bits below 0x10000 (0x16FC7) | crash (boot 5 from here: the throttle had reached minutes) |
  | 20 | Mac | 0x16FC7 + SNAPSHOT | crash |
  | 21 | Mac | 0x16FC7 + RENAME_SWAP | crash |
  | 22 | Mac | 0x16FC7 + RENAME_EXCL | up |
  | 23 | Ycode + WRITE_GEN | Ycode + CLONE + RENAME_EXCL (0x94302) | crash |
  | 24 | Mac | 0x94302 | up |
  | 25 | Ycode + WRITE_GEN + JOURNAL, JOURNAL_ACTIVE, ZERO_RUNS, HIDDEN_FILES | 0x94302 | crash |
  | 26 | Ycode + WRITE_GEN + DECMPFS + DOCUMENT_ID | 0x94302 | up |
  | 27 | Ycode + WRITE_GEN + DOCUMENT_ID (0x1A4F47) | 0x94302 | up |

  So: DOCUMENT_ID (23 → 27), WRITE_GENERATION_COUNT (12), CLONE (16)
  and RENAME_EXCL (18 → 24, 19–21 → 22) are each necessary, and Ycode's
  words with those four are enough (27). 35 starts in all (boots 4 and
  5 of device `-3`): where launchd restarted fileindexerd before the next
  value was written, the repeated value gave the same result. In every
  crashing start the capability request came twice (once per subscription
  attempt) and `FSEventStreamCreate` was never reached; every surviving
  start created its stream after one request.

## Results: intelligencetasksd (Q13.1)

- dasd submits five intelligencetasksd tasks at every boot, about 30–60 s
  after launchd_sim starts (dasd log, "SUBMITTED …"): the post-install
  task `com.apple.intelligencetasksd.spotlight-verification-post-install`
  (Utility, priority 30, window [submission + 300 s, submission + 3600 s])
  and four interval tasks (`sets.maintenance.A/B/C`,
  `spotlight-verification-nightly`, interval 86400 s) whose windows
  started the next morning. Only the post-install task ran in any of the
  runs.
- When dasd initiates the task ("Initiating BGST", state 1 → 2), launchd
  logs "launching: xpc event"; intelligencetasksd logs "Starting
  intelligencetasksd...", opens two listeners and stops in the XPC Swift
  overlay (Peer Requirement) with SIGTRAP. launchd starts it again for the
  same event every ~10 s ("Service only ran for 0 seconds. Pushing respawn
  out by 10 seconds.", "deferred event: domain spawn response: 0"), and
  from the 12th crash in a row with "Exponential throttling".
- 61 s after the initiation dasd logs "BGST client (PID 0) did not
  acknowledge launch within 61s", cancels with reason 3, and resubmits the
  task with a window that starts and ends one hour later. launchd's
  relaunches do not stop at the cancel.
- Per device: `-2`, second boot (700 s, no recorder): submitted at +82 s,
  window from +382 s, not run by +700 s: 0 starts. `-1`, third boot:
  initiated at +357 s, 5 starts by the shutdown at +467 s (one after the
  cancel at +425 s). `-1`, fourth boot (33 min): 0 starts (the
  resubmitted window was later). `-4`, second boot: initiated at +442 s
  (the process, starved, reached its crash only at +806 s), then 19
  starts in 61 minutes (10 at ~10 s, then exponential). `-3` showed the
  same timeline as `-4` (crash reports at the same times).
- Crash reports: one `.ips` per start, SIGTRAP, all with the same frames.
- Conclusion: the exit kind and throttle are as in Ycode; the Mac keeps
  relaunching after dasd's cancel, so a Mac boot in which dasd fires the
  task early gets 10+ starts in 700 s (the earlier 15–16). Ycode's 3–5
  with "no new launch event after the 3rd crash" is either a late
  initiation or a difference in how the pending event survives; the
  Ycode `launchd.log` around dasd's 61 s cancel decides it.

## Results: PosterBoard (Q13.2)

- None of this agent's eight boots crashed PosterBoard.
- The Mac's crash-report folder (including `Retired/`) held PosterBoard
  reports of other agents' simulator devices: two on 2026-10-20 (one
  device, 13 s apart), one each on 2026-10-26, 2026-10-27 14:38 and
  2026-10-27 16:59 (three more devices). The three newest have the iOS
  27.1 runtime's shared cache identity; the two oldest were rotated out
  of the folder during the afternoon, after their frames had been read.
- All five: `EXC_BREAKPOINT` / SIGTRAP, 16–69 s after PosterBoard's
  launch, faulting thread on the queue
  `PBFPosterDescriptorStoreCoordinator-accessQueue_<UUID>`, frames (binary
  metadata, level 4): PosterFoundation
  `+[NSURL(PosterFoundation) pf_posterPathInstanceURLForVersionsURL:version:]`
  (its `.cold.1` assertion branch) ← PosterBoard
  `-[PBFPosterModelStoreCoordinator _accessQueue_configureFileSystemForNewContents:atPath:error:]`
  ← `_accessQueue_setupNewVersionWithOptions:contents:error:` ←
  `addNewVersionWithContents:error:` ← `-[PBFPosterExtensionDataStore
  _stateLock_ingestReloadedDescriptorsForExtensionBundleIdentifier:preReloadDescriptors:postReloadDescriptors:error:]`
  ← the reload-descriptors operation of an extension.
- The simulator's `.ips` files have no application-specific information,
  so the assertion text is not in them. The guest log of those devices
  would have it, but the devices belong to other agents and were not
  touched.
- No other thread in the three reports read in full was inside a file
  removal at the time of the crash.
- DockFolderViewService's host-wide stream showed PosterBoard's data store
  being written in the same boot of device `-1`: cloned
  (`ItemCloned`) `…/PRBPosterExtensionDataStore/<n>/Extensions/…/configurations/<UUID>/versions/34/contents/`
  directories and `PFTemporaryDirectory/_STAGED_<UUID>` staging
  directories; consistent with versions being created by copy-and-rename.

## Other host-side names (§4 of the task)

Recorded in `launchd-sim.md` §6.4 (all look-ups and XPC connection names
of six boots, with results for the MIG look-ups). Host names used by guest
processes and not provided by Ycode: `com.apple.FSEvents` (seven
processes), `com.apple.audio.audiohald` (SpringBoard, at boot),
`com.apple.FileProvider.sim2host` (fileindexerd; "simulator host support
level 2" with it, "level 1" without), `com.apple.fpsd.sim` (assistantd,
amsengagementd), `com.apple.CoreSimulator.SimIdentityService` (apsd),
`com.apple.CoreSimulator.NearbyInteraction` (sharingd),
`com.apple.modelmanager.simulator` (HostInferenceProviderService). The
per-process Metal names of SpringBoard and backboardd are host names on
the Mac and absent in Ycode (fallback to the base name). Names of §6.3
nobody looked up: the bootstrap-port name, SimCaptureService, the
PineBoard/HeadBoard/Carousel/SBRendererService Metal names, gputools,
coreaudiod, configd_host, PPPController, storekitservice.sim2host,
lsuseractivity.simulatorsupport.
