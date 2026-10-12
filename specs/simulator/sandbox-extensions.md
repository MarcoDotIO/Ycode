# Spec: sandbox extensions in the simulator guest

Status: **reference** for stage 7 (`stage7-contract.md`). It gives what the
iOS 27.1 runtime's (24A94401) sandbox library sends to the kernel when a
guest process issues, consumes or releases a sandbox extension, and what
the kernel must answer. installd needs a successful issue before it lets
installcoordinationd stage an app (`app-install-launch.md` §2.1).

Every fact comes from black-box runs of our own programs (level 3): our
probe `sbext` on this Mac's booted iOS simulator, and the same probe and
the runtime's daemons running on Ycode, where the kernel's trace records
each call's argument block. No Apple binary was disassembled or
decompiled. The function names `sandbox_extension_issue_file`,
`sandbox_extension_consume` and `sandbox_extension_release` are exported
interop names. The prototypes the probe uses are its own declarations.

## 1. Library behavior (Mac simulator)

| Call | Result |
|---|---|
| `sandbox_extension_issue_file(class, path, flags 0)` | A newly allocated NUL-terminated token string (§3). This happened for an existing path, for a missing path, and for an unknown class name (`com.apple.nonexistent.class`). `errno` stayed 0. |
| `sandbox_extension_consume(token)` with a token from issue | Handle **0**, `errno` 0. A second consume of the same token also returns 0. |
| `sandbox_extension_consume("not-a-token")` | −1, `errno` 22 (`EINVAL`). The library also logs "sandbox_extension_consume failed: 22 (Invalid argument)". |
| `sandbox_extension_release(h)` | 0 for handle 0 and for an unknown handle (999999). |

The simulator's processes run unsandboxed on the Mac, so a consume grants
nothing new there. Ycode answers in the same way.

## 2. Kernel interface (`__mac_syscall`)

Each call is `__mac_syscall("Sandbox", op, arg)` (BSD 381), where `arg`
points to a block of 64-bit words in the caller's memory. Ops 5, 6 and 7 are
the issue, consume and release calls. Op 2 is the check call
(`stage6-contract.md` §6).

| Op | Library function | Argument words (as passed) | Kernel answer that makes the library succeed |
|---|---|---|---|
| **5** | `sandbox_extension_issue_file` | 0: pointer to the class string; 1: 0; 2: pointer to the path string; 3: the flags argument; 4: pointer to an output buffer allocated by the library (zero-filled when seen) | Write the NUL-terminated token into the word-4 buffer and return 0. The library returns that string. With ENOPOLICY (103) the library returns NULL with `errno` 103. |
| **6** | `sandbox_extension_consume` | 0: pointer to the token; 1: token length including the NUL; 2: pointer to a 64-bit output location (word 3 of the same block in every call seen) | Write the handle to the word-2 location and return 0. The library returns the handle. An error `e` makes the library return −1 with `errno` `e`. |
| **7** | `sandbox_extension_release` | 0: the handle | Return 0. |

The size of the issue buffer is not passed. Tokens of up to about 220 bytes
were seen. Ycode refuses tokens of 2048 bytes or more.

## 3. Token form

Twelve fields separated by `;`. Examples seen on the Mac:

| # | Content | Example |
|---|---|---|
| 1 | 64 lowercase hex digits (an authenticator; not interpreted by the guest) | `6b5c…7741` |
| 2–5 | `00`, `00000000`, `00000000`, `00000000` | |
| 6 | Length of the class string, 16 hex digits | `000000000000001a` (26) |
| 7 | The class | `com.apple.app-sandbox.read` |
| 8 | `01` when the path exists, `00` when it does not | |
| 9 | Device, 8 hex digits | `0100000d` |
| 10 | Inode, 16 hex digits (for a missing path, a different value) | `000000001586b31a` |
| 11 | `01` | |
| 12 | The resolved path (on the Mac, `realpath` form, lowercased on the case-insensitive volume) | `/private/tmp/yc-7-i3-sb/t` |

## 4. Ycode's answer (normative for Ycode)

- **Issue (5):** a token in the form of §3. Field 1 is a Ycode digest of
  fields 2–12. Field 12 is the guest `realpath` of the path, or the path as
  given if it cannot be resolved. Fields 8–10 come from `stat` (`00`, 0, 0
  when it fails). Returns 0. A missing class, path or buffer is EINVAL.
- **Consume (6):** a token with at least 12 fields whose first field is 64
  hex digits is accepted: handle 0 is written to the word-2 location and
  0 is returned. Anything else is EINVAL.
- **Release (7):** returns 0.
- Other Sandbox ops except 2 still get ENOPOLICY.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Library results, token form, handle 0, EINVAL for a bad token, release always 0 (§1, §3) | 3 | `research/experiments/simulator/sandbox-extensions/sbext.c` run with `xcrun simctl spawn` on this Mac's booted simulator (iOS 27.1 runtime), classes `com.apple.app-sandbox.read`, `…read-write`, an unknown class, and a missing path |
| Op numbers and argument words (§2) | 3 | Ycode kernel trace of `sbext` run with `ycode-simd --exec` on the Thor: the `__mac_syscall` lines with argument words and the strings they point to |
| Output buffer in word 4 and handle location in word 2 (§2) | 3 | Experiments on our own runs: answering op 5 by writing a token into the word-4 buffer made the library return that token, and consume then passed it in word 0 with its length in word 1; answering op 6 by writing 7 to the word-2 location made `sandbox_extension_consume` return 7, and release then passed 7 in word 0 |
| installd needs the issue to succeed (introduction) | 3 | Ycode install run: IXErrorDomain 2, with the underlying error "Failed to create sandbox extension for path …/PromiseStaging", NSPOSIXErrorDomain 103 |
| Ycode's answer (§4) | — | Ycode decision, shaped by the rows above |

Level 5 was not used. `.claude/Xcode.app`, `research/dirty/`, and Ghidra
were not opened.
