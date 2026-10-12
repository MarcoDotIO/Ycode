#!/usr/bin/env python3
# gen_syscalls.py - generates libsystem_kernel's plain system-call and
# Mach-trap wrappers (SimHostLibs/kernel/syscalls.S).
#
# Clean-room Ycode code. Inputs (all under specs/simulator/):
#   data/host-lib-surface-kernel.json   the names libsystem_kernel exports
#   data/bsd-syscalls.json              BSD numbers, argument and return types
#   data/mach-traps.json                Mach trap numbers and user-stub names
# Conventions: darwin-arm64-abi.md, stage3-contract.md section 10,
# host-library-init.md section 4.2:
#   BSD:  x16 = number, svc #0x80; carry clear = success (x0, x1 untouched);
#         carry set = x0 holds the errno -> tail-call cerror / cerror_nocancel.
#   Mach: x16 = -number, svc #0x80; the result is in x0; no carry, no errno.
#
# Usage (from ycode/SimHostLibs):
#   python3 -I kernel/gen_syscalls.py [--data-dir ../../specs/simulator/data]
# writes kernel/syscalls.S and kernel/syscalls-map.tsv. Both are committed;
# build.sh only assembles syscalls.S, so the generator is run by hand when
# the tables or the rules below change.
#
# A table row becomes a generated wrapper only when its name maps with
# confidence onto one system call whose C signature equals the public one.
# Names that need argument shuffling (variadic calls, two-result calls,
# by-value arguments, extra kernel arguments) are written by hand in
# syscall_special.S / *.c and listed in HANDWRITTEN. Names that cannot be
# mapped confidently are listed in LEAVE_AS_STUB and keep the generated
# unimplemented stub (host-libraries.md section 4).

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

BSD_CATEGORIES = ("bsd-syscall", "bsd-syscall-private")

# On arm64, Darwin's public struct stat / statfs are the 64-bit-inode
# layouts (there is no $INODE64 variant), so the public names use the "64"
# system calls. Private "__name" wrappers keep the exact kernel name.
PUBLIC_RENAMES = {
    "stat": "stat64",
    "fstat": "fstat64",
    "lstat": "lstat64",
    "fstatat": "fstatat64",
    "statfs": "statfs64",
    "fstatfs": "fstatfs64",
    "getfsstat": "getfsstat64",
}

# Public names whose system call has a different kernel name but the same
# arguments.
ALIASES = {
    "getsgroups_np": "getsgroups",
    "setsgroups_np": "setsgroups",
    "getwgroups_np": "getwgroups",
    "setwgroups_np": "setwgroups",
    "pthread_getugid_np": "gettid",
    "pthread_setugid_np": "settid",
    "__sandbox_ms": "__mac_syscall",
}
ALIAS_CATEGORIES = BSD_CATEGORIES + ("other",)

# Written by hand (syscall_special.S, mach.c, misc.c): the generator must
# not emit them. Each must be a row of the table.
HANDWRITTEN = {
    # two results / special return conventions
    "_pipe", "___fork",
    # extra kernel argument or by-value argument
    "_kill", "_sigsuspend", "_sigsuspend$NOCANCEL", "_reboot",
    # FD_SETSIZE check for the non-$DARWIN_EXTSN select family
    "_select", "_select$NOCANCEL", "_pselect", "_pselect$NOCANCEL",
    # ULF_NO_ERRNO handling
    "___ulock_wait", "___ulock_wait2", "___ulock_wake",
    # variadic: the optional argument is read from the caller's stack
    "_open", "_open$NOCANCEL", "_openat", "_openat$NOCANCEL",
    "_fcntl", "_fcntl$NOCANCEL", "_ioctl", "_sem_open", "_shm_open",
    "_semctl", "_open_dprotected_np", "_guarded_open_np",
    "_guarded_open_dprotected_np",
    # commpage fast path
    "_kdebug_trace",
}

# Rows that stay generated unimplemented stubs: the public function is a
# library routine (not one raw call), its signature differs from the
# kernel's in a way not covered by a public document, or the exact system
# call is ambiguous.
LEAVE_AS_STUB = {
    "_posix_spawn": "library routine that builds the kernel's argument block",
    "_mach_eventlink_signal": "public kern_return_t API over a call that returns a packed u64",
    "_mach_eventlink_wait_until": "public kern_return_t API over a call that returns a packed u64",
    "_mach_eventlink_signal_wait_until": "public kern_return_t API over a call that returns a packed u64",
    "_task_read_for_pid": "kern_return_t API; the BSD call's result convention is not specified",
    "_task_inspect_for_pid": "kern_return_t API; the BSD call's result convention is not specified",
    "_kdebug_typefilter": "public signature not specified",
    "_debug_syscall_reject": "public signature not specified",
    "_debug_syscall_reject_config": "public signature not specified",
    "_panic_with_data": "public signature not specified",
    "_semsys": "variadic legacy multiplexer",
    "_msgsys": "variadic legacy multiplexer",
    "_shmsys": "variadic legacy multiplexer",
    "_reboot_np": "no system call of that name",
    "_openat_dprotected_np": "public signature not specified (kernel takes an extra authfd)",
    "___stat": "32-bit-inode vs 64-bit-inode call is ambiguous",
    "___fstat": "32-bit-inode vs 64-bit-inode call is ambiguous",
    "___lstat": "32-bit-inode vs 64-bit-inode call is ambiguous",
    "___fstatat": "32-bit-inode vs 64-bit-inode call is ambiguous",
    "___statfs": "32-bit-inode vs 64-bit-inode call is ambiguous",
    "___fstatfs": "32-bit-inode vs 64-bit-inode call is ambiguous",
    "___getfsstat": "32-bit-inode vs 64-bit-inode call is ambiguous",
    "___stat_extended": "32-bit-inode vs 64-bit-inode call is ambiguous",
    "___lstat_extended": "32-bit-inode vs 64-bit-inode call is ambiguous",
    "___fstat_extended": "32-bit-inode vs 64-bit-inode call is ambiguous",
    "_getdirentries": "legacy 32-bit-inode directory format",
}

# Mach-routine rows that are written by hand in mach.c on top of traps
# (listed here only so the map file can report them).
KNOWN_VARIANTS = {"NOCANCEL", "DARWIN_EXTSN"}


def die(msg):
    sys.stderr.write("gen_syscalls.py: error: %s\n" % msg)
    sys.exit(1)


def norm_kernel_name(name):
    if name.startswith("sys_"):
        name = name[4:]
    return name.lstrip("_")


def load(data_dir):
    with open(os.path.join(data_dir, "host-lib-surface-kernel.json"), encoding="utf-8") as f:
        table = json.load(f)
    with open(os.path.join(data_dir, "bsd-syscalls.json"), encoding="utf-8") as f:
        bsd_rows = json.load(f)
    with open(os.path.join(data_dir, "mach-traps.json"), encoding="utf-8") as f:
        mach_rows = json.load(f)
    bsd = {}
    for r in bsd_rows:
        if r["status"] != "implemented" or not r["macos_arm64"]:
            continue
        key = norm_kernel_name(r["name"])
        if key in bsd:
            die("two BSD calls normalize to %s" % key)
        bsd[key] = r
    mach = {}
    for r in mach_rows:
        if r["status"] != "implemented":
            continue
        for n in (r["name"], r["user_stub"]):
            if n:
                mach[n] = r
    return table, bsd, mach


def map_bsd(cname, category, bsd):
    """(row, nocancel) for a C symbol name, or (None, reason)."""
    parts = cname.split("$")
    base, variants = parts[0], parts[1:]
    for v in variants:
        if v not in KNOWN_VARIANTS:
            return None, "unknown variant $%s" % v
    if "DARWIN_EXTSN" in variants and base.lstrip("_") not in ("select", "pselect"):
        return None, "$DARWIN_EXTSN on an unexpected name"
    nocancel = "NOCANCEL" in variants
    private = base.startswith("__")
    if base in ALIASES and category in ALIAS_CATEGORIES:
        core = norm_kernel_name(ALIASES[base])
    else:
        core = base.lstrip("_")
        if not private and core in PUBLIC_RENAMES:
            core = PUBLIC_RENAMES[core]
    if core.endswith("_nocancel"):
        nocancel = True
        key = core
    elif nocancel:
        key = core + "_nocancel"
    else:
        key = core
    row = bsd.get(key)
    if row is None:
        return None, "no system call named %s" % key
    return (row, nocancel), None


def asm_name(n):
    return '"%s"' % n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-dir", default=os.path.join(HERE, "..", "..", "..", "specs", "simulator", "data"))
    ap.add_argument("--out", default=os.path.join(HERE, "syscalls.S"))
    ap.add_argument("--map", default=os.path.join(HERE, "syscalls-map.tsv"))
    args = ap.parse_args()

    table, bsd, mach = load(args.data_dir)
    names = {r["name"]: r for r in table}
    for n in sorted(HANDWRITTEN | set(LEAVE_AS_STUB)):
        if n not in names:
            die("%s is listed but is not a row of the kernel table" % n)

    text = []
    mapping = []  # (name, surface?, kind, number, error path or note)
    counts = {}

    def bump(k):
        counts[k] = counts.get(k, 0) + 1

    for row in sorted(table, key=lambda r: r["name"]):
        name = row["name"]
        cat = row["category"]
        surf = "surface" if row["importers"] > 0 else "table"
        cname = name[1:]
        if row["kind"] != "function":
            continue
        is_bsd = cat in BSD_CATEGORIES or (cat in ALIAS_CATEGORIES and cname in ALIASES)
        is_mach = cat == "mach-trap"
        if not (is_bsd or is_mach):
            continue
        if name in HANDWRITTEN:
            mapping.append((name, surf, cat, "-", "hand-written"))
            bump("handwritten")
            continue
        if name in LEAVE_AS_STUB:
            mapping.append((name, surf, cat, "-", "stub: " + LEAVE_AS_STUB[name]))
            bump("stub")
            continue
        if is_mach:
            r = mach.get(cname)
            if r is None:
                mapping.append((name, surf, cat, "-", "stub: no Mach trap of that name"))
                bump("stub")
                continue
            num = r["number"]
            text.append("    .globl %s\n    .p2align 2\n%s:\n" % (asm_name(name), asm_name(name)))
            text.append("    mov x16, #%d\n    svc #0x80\n    ret\n" % num)
            mapping.append((name, surf, cat, str(num), "mach"))
            bump("mach")
            continue
        res, why = map_bsd(cname, cat, bsd)
        if res is None:
            mapping.append((name, surf, cat, "-", "stub: " + why))
            bump("stub")
            continue
        r, nocancel = res
        num = r["number"]
        if num <= 0 or num > 0xFFFF:
            die("bad number for %s" % name)
        text.append("    .globl %s\n    .p2align 2\n%s:\n" % (asm_name(name), asm_name(name)))
        text.append("    mov x16, #%d\n    svc #0x80\n" % num)
        if r["returns"] == "void":
            # exit-like calls: they must not return.
            text.append("    brk #0x7963\n")
            mapping.append((name, surf, cat, str(num), "noreturn"))
            bump("bsd")
            continue
        # Cancellation points (calls with a _nocancel twin) use cerror;
        # $NOCANCEL / _nocancel variants and every other call use
        # cerror_nocancel (host-library-init.md section 4.2).
        kernel_key = norm_kernel_name(r["name"])
        cancelable = (not nocancel) and (kernel_key + "_nocancel") in bsd
        target = "Lyc_cerror" if cancelable else "Lyc_cerror_nocancel"
        text.append("    b.cs %s\n    ret\n" % target)
        mapping.append((name, surf, cat, str(num), "cerror" if cancelable else "cerror_nocancel"))
        bump("bsd")

    out = []
    out.append("// Generated by SimHostLibs/kernel/gen_syscalls.py. Do not edit.\n")
    out.append("// Plain BSD system-call and Mach-trap wrappers of libsystem_kernel\n")
    out.append("// (clean-room Ycode code; see the generator for the rules).\n\n")
    out.append("    .section __TEXT,__text,regular,pure_instructions\n")
    out.append("    .p2align 2\n")
    out.append("Lyc_cerror:\n    b _cerror\n")
    out.append("Lyc_cerror_nocancel:\n    b _cerror_nocancel\n\n")
    out.extend(text)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write("".join(out))
    with open(args.map, "w", encoding="utf-8") as f:
        f.write("# Generated by gen_syscalls.py. name\tsurface\tcategory\tnumber\twrapper\n")
        for m in mapping:
            f.write("\t".join(m) + "\n")
    sys.stdout.write("gen_syscalls.py: %s\n" % ", ".join("%s %d" % kv for kv in sorted(counts.items())))


if __name__ == "__main__":
    main()
