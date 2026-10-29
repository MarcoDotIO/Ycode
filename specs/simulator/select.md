# Spec: `select` and `pselect` (kernel side)

Ycode's kernel personality implements the BSD descriptor-multiplexing calls
`select` and `pselect` with Darwin semantics. Guest code (SpringBoard's
run-loop helpers among others) uses `select` both to wait for descriptors
and, with no descriptors, as a sleep. Before this spec the call was
unimplemented: every call failed at once with `ENOSYS`, and callers spun
(about 764 000 calls and 21 s of kernel-lock hold per boot, X14 profile).

Implementation: `ycode/Sources/YcodeDarwinKernel/Select.swift`.

## 1. Calls

| Number | Name | Arguments |
|---|---|---|
| 93 | `select` | `nd`, `in`, `ou`, `ex`, `tv` |
| 407 | `select_nocancel` | as 93 |
| 394 | `pselect` | `nd`, `in`, `ou`, `ex`, `ts`, `mask` |
| 395 | `pselect_nocancel` | as 394 |

The `_nocancel` forms behave like the plain calls (Ycode has no thread
cancellation). The libc wrappers `select$DARWIN_EXTSN` and
`select$1050` reach the same numbers.

On success the result is the number of bits set in the three output sets
(a descriptor ready for both reading and writing counts twice). On failure
carry is set and `x0` is the errno.

## 2. Descriptor sets

- A set is an array of 32-bit words (`fd_mask`, `__DARWIN_NFDBITS` = 32).
  Descriptor `fd` is bit `fd % 32` of word `fd / 32`.
- Only descriptors below `nd` are examined. `nd` < 0 is `EINVAL`.
- **Clamp.** Darwin clamps `nd` to the size of the process's descriptor
  table. Ycode clamps it to the highest open descriptor + 1. Set bits at or
  above the clamped `nd` are ignored.
- For each non-NULL set, Ycode reads `howmany(nd, 32)` words, using the
  clamped `nd`. On success or timeout it writes back the same number of
  words. Words past them are not touched. A NULL set is neither read nor
  written.
- A set bit below the clamped `nd` that names a descriptor that is not open
  makes the call fail with `EBADF`. No set is written.

## 3. Timeout

- `select`: `tv` points to a 64-bit `struct timeval`. `tv_sec` is an int64
  at +0, and `tv_usec` is an int32 at +8 (16 bytes with padding).
- `pselect`: `ts` points to a `struct timespec`. `tv_sec` is an int64 at +0,
  and `tv_nsec` is an int64 at +8.
- `tv_sec` < 0, `tv_sec` > 100 000 000, a sub-second field < 0, or a
  sub-second field ≥ one second (10⁶ µs or 10⁹ ns) is `EINVAL`.
- A NULL pointer waits with no limit. A zero timeout polls: the call scans
  once and returns.
- The timeout is not written back.

## 4. Readiness

| Descriptor | Readable | Writable | Exceptional |
|---|---|---|---|
| Host file, directory, or console | always | always | never |
| Pipe, read end | data buffered, or the writer closed (end of file) | never | never |
| Pipe, write end | never | at least `PIPE_BUF` bytes of space, or the reader closed | never |
| AF_UNIX socket | as `EVFILT_READ` (data, a pending connection, or end of file) | as `EVFILT_WRITE` (space, or the peer gone) | never |
| IP socket, PF_ROUTE socket | as `EVFILT_READ`/`EVFILT_WRITE` (`networking-ycode.md` §2.4) | as `EVFILT_WRITE` | never |
| kqueue | at least one event is pending | never | never |
| Other kernel objects (POSIX shm, semaphores, …) | never | never | never |

The rule is the same as for kevent's `EVFILT_READ` and `EVFILT_WRITE`
(`threads-and-events.md` §3.7.7): the object is ready, or it is at end of
file. End of file counts as ready, so the next `read` or `write` returns at
once (0 or `EPIPE`). No descriptor ever has an exceptional condition,
because Ycode has no out-of-band data. Bits in the `ex` set are always
cleared.

## 5. Blocking

1. Scan the sets. If at least one bit is ready, or the timeout is zero,
   write the output sets back and return the count.
2. Otherwise block until one of these happens: the readiness of a watched
   descriptor changes, the deadline passes, or the thread is interrupted.
   While the thread is blocked, the kernel lock is released. The wait uses
   the readiness observers that kevent's descriptor knotes use. An observer
   is registered on each watched object while the lock is held, before the
   lock is released, so no change is missed.
3. On a wakeup, check again that every set bit still names an open
   descriptor (`EBADF` if not) and scan again. If nothing is ready, go back
   to step 2 with the same deadline.
4. At the deadline, clear the output sets (the words of §2), write them
   back, and return 0.
5. If the thread is interrupted (a signal, or the process exiting), fail
   with `EINTR` and do not write the sets.

`pselect` with a non-NULL `mask` replaces the calling process's recorded
signal mask with `*mask` for the duration of the call (SIGKILL and SIGSTOP
cannot be blocked) and then restores the old mask. If a signal that the new
mask lets through is already pending when the call would block, the call
fails with `EINTR`.

## 5a. poll

`poll` (230) and `poll_nocancel` (417) use the same readiness and the same
wait (readiness observers, the kernel lock released; NET-IMPL,
`networking-ycode.md` §2.4). Per `struct pollfd` (8 bytes: fd, events,
revents): a negative fd is skipped (revents 0); a descriptor that is not
open gets POLLNVAL (0x20); readable sets the asked POLLIN/POLLRDNORM;
writable the asked POLLOUT/POLLWRBAND unless POLLHUP; end of file sets
POLLHUP (0x10) (and the asked read bits). A host file or the console is
always readable and writable. The timeout is in milliseconds (negative:
no limit; 0: poll). More than 12288 entries: EINVAL. The result is the
number of entries with a non-zero revents; EINTR when interrupted. Before,
`poll` was not implemented (ENOSYS).

## 6. Diagnostics

`YCODE_DEBUG_SELECT_STATS=1` prints a `ycode-select-stats:` line to standard
error for each process image every 5000 calls. The line gives the number of
calls, sleeps (no sets), polls, waits with no limit, calls that were ready
at once, blocked calls and their total wait, wakeups (and wakeups after
which nothing was ready), timeouts, interruptions, errors, the largest
`nd`, and a timeout histogram.

## Evidence

| Claim | Level |
|---|---|
| Call numbers 93/407/394/395 and their argument lists | 1 (`specs/simulator/data/bsd-syscalls.json`, from xnu's open-source `syscalls.master`) |
| Set layout: 32-bit words, `howmany(nd, NFDBITS)` | 1 (Darwin `sys/_types/_fd_def.h`, `sys/select.h`) |
| `nd` < 0 → EINVAL; clamp of `nd` to the descriptor table; EBADF for a set bit naming a closed descriptor; result = number of set bits; sets written only on success | 1 (select(2) manual page; xnu open source `bsd/kern/sys_generic.c`) |
| Timeout layouts (64-bit `timeval` with int32 `tv_usec`; `timespec`) and the EINVAL bounds (negative, `tv_sec` > 10⁸, sub-second out of range) | 1 (Darwin `sys/_types/_timeval64.h`/`_timeval.h`, `sys/_types/_timespec.h`; select(2) "too large"; xnu `itimerfix`) |
| NULL timeout waits with no limit; zero polls; EINTR on a signal | 1 (POSIX `select`/`pselect`; select(2)) |
| `poll` semantics (§5a): POLLNVAL, POLLHUP at end of file, skipped negative descriptors, the millisecond timeout | 1 (POSIX `poll`; xnu `sys_generic.c` poll callback) |
| `pselect` replaces the signal mask for the call | 1 (POSIX `pselect`; pselect(2)) |
| Readiness rules for pipes and sockets, and end of file counts as ready | 1 (POSIX: "a descriptor shall be considered ready for reading when a call to an input function … would not block"); same rules as kevent (`threads-and-events.md` §3.7.7) |
| Regular files and terminals are always ready | 1 (POSIX `select`: "File descriptors associated with regular files shall always select true") |
| Clamping to the highest open descriptor + 1, not to the allocated table size | Ycode choice (more forgiving than Darwin for a closed descriptor between the two) |
| SpringBoard's call volume with an unimplemented `select` | 3 (Ycode boot profile, X14, 2026-10-13) |
