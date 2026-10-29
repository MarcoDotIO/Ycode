# Spec: the data volume's capabilities and what they promise

Status: **implemented** (agent FS-HOST, clean room, 2026-10-27).
Code: `ycode/Sources/YcodeDarwinABI/VolumeFeatures.swift`,
`DarwinFileSystem.swift`, `ycode/Sources/YcodeDarwinKernel/AttributeList.swift`,
`Descriptors/FileMetadataCalls.swift`. Terms as in `launchd-sim.md` (DEV, RR).

## 1. Why

`getattrlist(ATTR_VOL_CAPABILITIES)` tells a client which features of a
volume it may use. fileindexerd (FileProvider's change monitor) subscribes
to its file-provider root only when the volume reports document IDs, write
generation counts, clones and exclusive renames; without them it stops with
"Failed to init after preparing dependencies: … Code=19" and launchd
restarts it 16 times in 700 s (`service-fidelity.md` §11, Q11.2). A bit is
a promise: each one Ycode now reports is backed by the calls and attributes
below, with the semantics of the public headers and of open source
(xnu `bsd/sys/attr.h`, `bsd/sys/stat.h`, `bsd/sys/clonefile.h`,
`bsd/vfs/vfs_attrlist.c`, `bsd/vfs/vfs_syscalls.c`, `bsd/vfs/doc_tombstone.c`;
the HFS sources for document IDs and generation counts).

## 2. The capability words

| Word | Before | Now | Added |
|---|---|---|---|
| format | 0x00024F47 | **0x001A4F47** | `VOL_CAP_FMT_DOCUMENT_ID` (0x80000), `VOL_CAP_FMT_WRITE_GENERATION_COUNT` (0x100000) |
| interfaces | 0x00004302 | **0x000D4302** | `VOL_CAP_INT_CLONE` (0x10000), `VOL_CAP_INT_RENAME_SWAP` (0x40000), `VOL_CAP_INT_RENAME_EXCL` (0x80000) |

The valid masks are unchanged (0x07FFFFFF, 0x01FF7FFF); they already
covered these bits. RENAME_SWAP is reported too because Ycode implements it
(`service-fidelity.md` §4); fileindexerd does not need it.

**Both of Ycode's volumes report the same words.** The data volume ("/":
DEV, the temporary directories, /System's view) is writable. The runtime
volume (RR) is read-only, as the Mac's runtime disk image is; there every
feature is honest in its read-only form: a generation count never changes
because no file does, every object's document ID is 0 (nothing can be
tracked), and a clone, a flag change or a rename that would write RR is
EROFS — what a read-only APFS volume answers while still reporting the
format's capabilities. A clone from RR to the data volume is EXDEV.

## 3. File flags and document IDs (`VOL_CAP_FMT_DOCUMENT_ID`)

**Storage.** A Linux host file has no BSD flags and no document ID. Ycode
keeps both per object in one host extended attribute,
`user.ycodevfs.meta` (8 bytes: u32 flags, u32 document ID, little-endian),
absent when both are 0. It moves with the file on renames, disappears with
it, and is copied by copies that keep extended attributes (`cp -a`). The
guest never sees it (guest attributes are `user.ycode.<name>`). The
document-ID counter of the volume is the host attribute
`user.ycodevfs.next-document-id` of DEV/data, so it travels with the data
whose IDs it issued; IDs start at 16. Read-only prefixes keep nothing.

| Call | Behaviour |
|---|---|
| `chflags`, `fchflags`, `setattrlist(ATTR_CMN_FLAGS)` | Stores the owner-settable flags (`UF_SETTABLE`, except UF_COMPRESSED). Changing a superuser flag (`SF_SETTABLE`) or UF_DATAVAULT: EPERM (guest processes are never the superuser). Read-only volume: EROFS. Setting UF_TRACKED gives the object a new document ID (unless it has one); clearing it clears the ID. Ycode does not enforce UF_IMMUTABLE or UF_APPEND. |
| `stat`, `lstat`, `fstat`, `fstatat`, `getattrlist(ATTR_CMN_FLAGS)`, `getattrlistbulk` | `st_flags` = the stored flags (writable volume; one host attribute read per call). |
| `getattrlist(ATTR_CMN_DOCUMENT_ID)` | The stored ID; 0 for an untracked object. A tracked object without an ID (a clone of a tracked file) gets one now (HFS `hfs_vnop_getattr`). |
| rename | The ID moves with the object. **Safe save:** renaming an object without an ID over a tracked object gives it the replaced object's ID and UF_TRACKED. |
| unlink; rename to a free name | A tracked object leaving a name leaves a **tombstone** (directory, name, ID) in its process; the next object created there (`open(O_CREAT)`) or renamed there that has no ID inherits it; creating or renaming another name clears the tombstone, except temporary names (`atmp…`, `….bak`, `….tmp`), as xnu `doc_tombstone.c`. |

xnu keeps the tombstone per thread; Ycode keeps it per process (a safe save
on one thread and the re-creation on another also inherit). The
document-ID change events (`FSE_DOCID_CHANGED`, the `/.docid` stream of
revisiond) are not produced.

`ATTR_CMN_GEN_COUNT` and `ATTR_CMN_DOCUMENT_ID` need
`FSOPT_ATTR_CMN_EXTENDED` in `getattrlist` (EINVAL otherwise; xnu
`getattrlist_internal`); `getattrlistbulk` always has it.

## 4. Write generation counts (`VOL_CAP_FMT_WRITE_GENERATION_COUNT`)

`ATTR_CMN_GEN_COUNT` of a regular file or directory is a nonzero value that
**changes whenever the object's contents change and stays the same
otherwise, also across boots**; other object types report 0 (HFS). It is a
hash of the host modification time (ns), the size, the inode number, and
the number of writes Ycode made to the file since the value was last read
with that same modification time. The last term covers two writes within
one tick of the host's file-time clock (a few ms on Linux 6.8), which would
otherwise leave the same time and size. Writes are counted at every write,
`pwrite`, `writev`, `ftruncate`, `truncate` and `O_TRUNC` open through Ycode.

Not covered: a change made through a writable shared mapping within one
clock tick of a read of the count (HFS answers 0 while a file is mapped
writable; Ycode does not track that state); a directory's count follows its
modification time only. The value is not ordered (HFS's counter is; no
client was seen comparing order). Metadata changes (`chmod`, `chown`, times,
extended attributes) do not change it.

## 5. Clones (`VOL_CAP_INT_CLONE`)

`clonefileat(src_dirfd, src, dst_dirfd, dst, flags)` (462) and
`fclonefileat(src_fd, dst_dirfd, dst, flags)` (517), checks in xnu's order
(`clonefile_internal`):

| Condition | Result |
|---|---|
| a flag other than `CLONE_NOFOLLOW` 0x1, `CLONE_NOOWNERCOPY` 0x2, `CLONE_ACL` 0x4, `CLONE_NOFOLLOW_ANY` 0x8 | EINVAL (`CLONE_RESOLVE_BENEATH` 0x10 is not implemented, as for `renameatx_np`) |
| source missing / a directory component missing | ENOENT |
| `fclonefileat` on a descriptor not open for reading | EBADF |
| source not a file, link or directory; a volume root or mount point | EINVAL |
| target exists | EEXIST |
| target on a read-only volume | EROFS |
| target on another volume | EXDEV |

The clone gets the source's contents, mode, access and modification times,
guest extended attributes, and flags except UF_DATAVAULT; the caller owns it
(`CLONE_NOOWNERCOPY` is what happens anyway); it has no document ID of its
own (a tracked clone gets a new one when read). A directory is cloned
recursively (files, links and directories; sockets and FIFOs are skipped).
Host side: Linux `FICLONE` where the host file system shares extents (btrfs,
XFS), otherwise `copy_file_range`, otherwise reads and writes; on macOS
`clonefile`. The Thor's data drive is ext4, which has no reflinks, so there
a clone is a copy with the same observable result. On failure nothing is
left at the target. The copy runs without the kernel lock. Each clone is a
file change "cloned" of the source and "cloned + created" of the target
(xnu's `FSE_CLONE` pair).

## 6. Exclusive and swapping renames (`VOL_CAP_INT_RENAME_EXCL`, `…_RENAME_SWAP`)

The flags and checks are those of `service-fidelity.md` §4. RENAME_EXCL is
now atomic on the host: Linux `renameat2(RENAME_NOREPLACE)` (macOS
`renamex_np(RENAME_EXCL)`), so a name made between Ycode's check and the
rename is not replaced (EEXIST). RENAME_SWAP uses
`renameat2(RENAME_EXCHANGE)` and needs no temporary name. Where the host
refuses the flag (EINVAL, ENOSYS), Ycode falls back to the check-then-rename
and the three-rename swap of before.

## 7. The file-change feed

Every change a guest process makes through Ycode's VFS is reported to one
observer, the host's file-event service (`fsevents-host.md`, "Ycode
implementation"): kind (created, removed, renamed — both names, modified,
inode metadata (times, flags), owner (`chmod`, `chown`), extended
attribute, cloned), item type (file, directory, symbolic link, other), the
canonical guest path, and the process. While no stream is started the
feed costs one atomic load per change.

## Evidence

| Claim | Level |
|---|---|
| fileindexerd needs the four bits (§1) | 3 (`service-fidelity.md` §11, the dirty room's fault injection) |
| Capability bit names and values, valid masks (§2) | 1 (xnu `bsd/sys/attr.h`) |
| UF_* / SF_* values, UF_TRACKED's meaning (§3) | 1 (xnu `bsd/sys/stat.h`) |
| Document IDs: assigned on UF_TRACKED, cleared with it, kept by renames, moved by a rename over a tracked object, lazily assigned on read, tombstones and their temporary-name rule (§3) | 1 (HFS `hfs_vnops.c` `hfs_set_bsd_flags`, `hfs_vnop_getattr`, `hfs_vnop_rename`, `hfs_makenode`, `hfs_removefile`; xnu `bsd/vfs/doc_tombstone.c`) |
| GEN_COUNT / DOCUMENT_ID need FSOPT_ATTR_CMN_EXTENDED (§3) | 1 (xnu `bsd/vfs/vfs_attrlist.c`) |
| Generation counts: per write, 0 for other types (§4) | 1 (HFS `hfs_cnode.c` `hfs_incr_gencount`, `hfs_get_gencount`) |
| clonefile flags, checks and order, attribute rules, FSE_CLONE events (§5) | 1 (xnu `bsd/sys/clonefile.h`, `bsd/vfs/vfs_syscalls.c` `clonefile_internal`, `clonefileat`, `fclonefileat`) |
| Linux FICLONE, copy_file_range, renameat2 flags; ext4 has no reflinks (§5, §6) | 1 (Linux man pages ioctl_ficlone(2), copy_file_range(2), rename(2)) |
| Read-only volumes keep reporting format capabilities, EROFS for writes (§2) | 1 (getattrlist(2); xnu namei EROFS for CREATE on a read-only mount) |
| Ycode's behaviour (all sections) | Ycode design; unit tests `VolumeFeaturesTests`, guest probe `p_fsevents` on the Thor |
