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
    "___gettimeofday",
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
    # cached in the library, as xnu's libsyscall caches it (misc.c)
    "_getpid",
    # answered from the commpage credential block when the VMM allows it
    # (misc.c; fast-traps.md section 5)
    "_getuid", "_geteuid", "_getgid", "_getegid",
    # answered in the library when the commpage allows it (misc.c;
    # fast-traps.md section 5a)
    "_madvise", "_issetugid", "___sysctl",
    # library routine that builds the BSD 244 argument block and returns
    # the error number as its result (spawn.c, processes.md section 1)
    "_posix_spawn",
}

# Rows that stay generated unimplemented stubs: the public function is a
# library routine (not one raw call), its signature differs from the
# kernel's in a way not covered by a public document, or the exact system
# call is ambiguous.
LEAVE_AS_STUB = {
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

# Mach-routine rows written by hand in mach.c / machmsg.c on top of traps
# (listed here only so the map file can report them; the generator emits
# nothing for them). name -> (trap number(s) used, note). Private traps
# are 0x7963_2000 + n (host-libraries.md section 10, stage4a-contract.md
# section 7).
MACH_ROUTINES = {
    # time and self ports
    "_mach_absolute_time": ("-3", "mach.c"),
    "_mach_continuous_time": ("-4", "mach.c"),
    "_mach_timebase_info": ("-89", "mach.c: cached"),
    "_mach_get_times": ("-3,-4,116", "mach.c: wall clock from __gettimeofday as a timespec"),
    "_mach_task_self": ("-", "mach.c: mach_task_self_"),
    "_mach_host_self": ("-29", "mach.c"),
    "_host_self": ("-29", "mach.c: as mach_host_self"),
    "_mach_thread_self": ("-27", "mach.c"),
    # port routines over the _kernelrpc_mach_port_*_trap traps
    "_mach_port_allocate": ("-16", "mach.c"),
    "_mach_port_deallocate": ("-18", "mach.c"),
    "_mach_port_mod_refs": ("-19", "mach.c"),
    "_mach_port_move_member": ("-20", "mach.c"),
    "_mach_port_insert_right": ("-21", "mach.c"),
    "_mach_port_insert_member": ("-22", "mach.c"),
    "_mach_port_extract_member": ("-23", "mach.c"),
    "_mach_port_construct": ("-24", "mach.c"),
    "_mach_port_destruct": ("-25", "mach.c"),
    "_mach_port_get_attributes": ("-40", "mach.c"),
    "_mach_port_guard": ("-41", "mach.c"),
    "_mach_port_guard_with_flags": ("-41", "mach.c: MPG_STRICT -> strict"),
    "_mach_port_unguard": ("-42", "mach.c"),
    "_mach_port_type": ("-76", "mach.c"),
    "_mach_port_request_notification": ("-77", "mach.c"),
    "_mach_port_destroy": ("-76,-19,-18", "mach.c: library routine over the port traps"),
    "__kernelrpc_mach_port_allocate": ("-16", "mach.c: MIG name, uses the trap"),
    "__kernelrpc_mach_port_deallocate": ("-18", "mach.c: MIG name, uses the trap"),
    "__kernelrpc_mach_port_mod_refs": ("-19", "mach.c: MIG name, uses the trap"),
    "__kernelrpc_mach_port_move_member": ("-20", "mach.c: MIG name, uses the trap"),
    "__kernelrpc_mach_port_insert_right": ("-21", "mach.c: MIG name, uses the trap"),
    "__kernelrpc_mach_port_insert_member": ("-22", "mach.c: MIG name, uses the trap"),
    "__kernelrpc_mach_port_extract_member": ("-23", "mach.c: MIG name, uses the trap"),
    "__kernelrpc_mach_port_construct": ("-24", "mach.c: MIG name, uses the trap"),
    "__kernelrpc_mach_port_destruct": ("-25", "mach.c: MIG name, uses the trap"),
    "__kernelrpc_mach_port_get_attributes": ("-40", "mach.c: MIG name, uses the trap"),
    "__kernelrpc_mach_port_guard": ("-41", "mach.c: MIG name, uses the trap"),
    "__kernelrpc_mach_port_guard_with_flags": ("-41", "mach.c: MIG name, uses the trap"),
    "__kernelrpc_mach_port_unguard": ("-42", "mach.c: MIG name, uses the trap"),
    "__kernelrpc_mach_port_type": ("-76", "mach.c: MIG name, uses the trap"),
    "__kernelrpc_mach_port_request_notification": ("-77", "mach.c: MIG name, uses the trap"),
    "__kernelrpc_mach_port_destroy": ("-76,-19,-18", "mach.c: MIG name, as mach_port_destroy"),
    # VM
    "_mach_vm_allocate": ("-10", "mach.c"),
    "_mach_vm_deallocate": ("-12", "mach.c"),
    "_mach_vm_protect": ("-14", "mach.c"),
    "_mach_vm_purgable_control": ("-11", "mach.c"),
    "_mach_vm_map": ("-15", "syscall_special.S: anonymous memory only"),
    "_vm_allocate": ("-10", "mach.c"),
    "_vm_deallocate": ("-12", "mach.c"),
    "_vm_protect": ("-14", "mach.c"),
    "_vm_purgable_control": ("-11", "mach.c"),
    "_vm_map": ("-15", "syscall_special.S: anonymous memory only"),
    # semaphores
    "_semaphore_signal": ("-33", "mach.c"),
    "_semaphore_signal_all": ("-34", "mach.c"),
    "_semaphore_signal_thread": ("-35", "mach.c"),
    "_semaphore_wait": ("-36", "mach.c"),
    "_semaphore_wait_signal": ("-37", "mach.c"),
    "_semaphore_timedwait": ("-38", "mach.c: mach_timespec_t split into sec, nsec"),
    "_semaphore_timedwait_signal": ("-39", "mach.c: mach_timespec_t split into sec, nsec"),
    "_semaphore_create": ("0x79632003", "mach.c: private trap"),
    "_semaphore_destroy": ("0x79632004", "mach.c: private trap"),
    # other private-trap routines
    "_host_get_clock_service": ("0x79632001", "mach.c: private trap"),
    "_clock_get_time": ("0x79632002", "mach.c: private trap"),
    "_task_get_special_port": ("0x79632005", "mach.c: private trap"),
    "_task_set_special_port": ("0x79632006", "mach.c: private trap"),
    "_mach_ports_register": ("0x79632008", "mach.c: private trap, padded to three ports"),
    "_mach_ports_lookup": ("0x79632009,-10,-12", "mach.c: private trap into a vm_allocate'd array"),
    # messages
    "_mach_msg": ("-47", "machmsg.c: packed mach_msg2, MQ_CALL, interrupt retry"),
    "_mach_msg_overwrite": ("-47,-32", "machmsg.c: -32 only with a separate receive buffer"),
    "_mach_msg_send": ("-47", "machmsg.c: via mach_msg"),
    "_mach_msg_receive": ("-47", "machmsg.c: via mach_msg"),
    "_mach_msg2_internal": ("-47", "machmsg.c: packed words passed through, library-only bits stripped, interrupt retry"),
    "_mach_msg_destroy": ("-18,-19,-21,-42,-12", "machmsg.c: library routine (mach-ipc.md 4.4)"),
    "_mach_msg_priority_encode": ("-", "machmsg.c: library routine"),
    # MIG reply ports and special reply ports
    "_mig_get_reply_port": ("-26", "mach.c: TSD slot 2"),
    "_mig_dealloc_reply_port": ("-19", "mach.c"),
    "_mig_put_reply_port": ("-", "mach.c: no-op"),
    "_mig_get_special_reply_port": ("-50", "mach.c: TSD slot 8"),
    "_mig_dealloc_special_reply_port": ("-25", "mach.c: thread_destruct_special_reply_port(ALL)"),
    "_thread_destruct_special_reply_port": ("-25,-19,-18", "mach.c"),
    "_mig_deallocate": ("-12", "mach.c"),
    # vouchers
    "_host_create_mach_voucher": ("0x79632007", "mach.c: private trap, voucher 0"),
    "__kernelrpc_host_create_mach_voucher": ("0x79632007", "mach.c: private trap, voucher 0"),
    "_mach_voucher_extract_attr_recipe": ("-72", "mach.c"),
    "__kernelrpc_mach_voucher_extract_attr_recipe": ("-72", "mach.c"),
    "_mach_voucher_deallocate": ("-18", "mach.c"),
    "_mach_voucher_attr_command": ("-", "mach.c: MACH_SEND_INVALID_DEST (no voucher objects)"),
    # host
    "_host_info": ("-", "mach.c: HOST_PRIORITY_INFO only"),
    "_host_page_size": ("-", "mach.c"),
    "__host_page_size": ("-", "mach.c"),
}

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
    for n in sorted(HANDWRITTEN | set(LEAVE_AS_STUB) | set(MACH_ROUTINES)):
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
        if name in MACH_ROUTINES:
            num, note = MACH_ROUTINES[name]
            mapping.append((name, surf, cat, num, "routine: " + note))
            bump("routine")
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
