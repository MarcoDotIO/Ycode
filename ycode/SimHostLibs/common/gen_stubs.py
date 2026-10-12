#!/usr/bin/env python3
# gen_stubs.py - generates the "unimplemented" layer of one Ycode host library.
#
# Clean-room Ycode code (contract: specs/simulator/host-libraries.md section 4).
#
# For every row of the library's surface table that no hand-written or
# fallback object already defines, it emits:
#   - a function stub that executes the Ycode-private trap
#     (svc #0x80, x16 = 0x7963_0F00, x0 = the function's C name) and then
#     fails in the conventional way for its category, or
#   - a data variable of the required size and initial value.
#
# Usage:
#   python3 -I gen_stubs.py --lib kernel --data-dir SPECS/simulator/data \
#       --common DIR --defined FILE --out FILE.S --manifest FILE.tsv
#
# --defined lists Mach-O names (one per line) that already exist; they get
# no stub. The manifest records the convention chosen for every generated
# stub (name, kind, category, convention).

import argparse
import json
import os
import sys

TRAP_LO = 0x0F00
TRAP_HI = 0x7963
ENOSYS = 78
KERN_NOT_SUPPORTED = 46
CONVENTIONS = ("errno", "kern", "zero", "void", "errret", "noreturn", "nop")

PLATFORM_DEFAULTS = {
    "string-memory": "zero",
    "simple-printf-asl": "zero",
    "os-lock": "void",
    "atomics-spinlock": "zero",
    "setjmp-longjmp": "errno",
    "os-sync": "errno",
    "signal-bitops": "zero",
    "os-misc": "zero",
    "os-once": "void",
    "cache-control": "void",
    "ucontext": "errno",
    "other": "void",
}
PTHREAD_DEFAULTS = {
    "pthread-api": "errret",
    "pthread-spi": "errret",
    "tsd": "errret",
    "spawn-qos": "errret",
    "pthread-private": "errret",
    "qos": "zero",
    "sched-signal": "errno",
    "stack-probe": "nop",
    "thread-entry": "noreturn",
    "other": "void",
}


def die(msg):
    sys.stderr.write("gen_stubs.py: error: %s\n" % msg)
    sys.exit(1)


def read_table(path, lib, ncols):
    """Rows of a whitespace table filtered to `lib`; '#' starts a comment."""
    rows = []
    with open(path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split(None, ncols - 1)
            if len(parts) < 2:
                die("%s:%d: malformed line" % (path, lineno))
            if parts[0] == lib:
                rows.append((lineno, parts[1:]))
    return rows


def c_name(macho_name):
    return macho_name[1:] if macho_name.startswith("_") else macho_name


def strip_variant(name):
    return name.split("$", 1)[0]


def default_convention(lib, row, bsd, mach):
    cat = row["category"]
    name = c_name(row["name"])
    if lib == "kernel":
        if cat == "bsd-syscall":
            info = bsd.get(strip_variant(name))
            if info is not None and info.get("returns") == "void":
                return "noreturn"  # exit, abort_with_payload
            return "errno"
        if cat == "mach-trap":
            info = mach.get(name)
            if info is not None:
                if info.get("returns_port") or info.get("returns") == "boolean_t":
                    return "zero"
            return "kern"
        if cat == "mach-routine":
            return "kern"
        if cat == "posix-spawn":
            return "errret"
        return "errno"
    if lib == "platform":
        return PLATFORM_DEFAULTS.get(cat, "zero")
    if lib == "pthread":
        return PTHREAD_DEFAULTS.get(cat, "errret")
    die("unknown library %s" % lib)


def asm_string(text):
    out = []
    for ch in text.encode("utf-8"):
        if ch in (0x22, 0x5C):
            out.append("\\" + chr(ch))
        elif 0x20 <= ch < 0x7F:
            out.append(chr(ch))
        else:
            out.append("\\%03o" % ch)
    return '"' + "".join(out) + '"'


def parse_init(spec, size, name):
    data = bytearray(size)
    if spec is None:
        return data
    key, _, value = spec.partition("=")
    if key == "u32":
        raw = int(value, 0).to_bytes(4, "little")
    elif key == "u64":
        raw = int(value, 0).to_bytes(8, "little")
    elif key == "bytes":
        raw = bytes(int(b, 16) for b in value.split(","))
    elif key == "str":
        raw = value.rstrip("\n").encode("utf-8").decode("unicode_escape").encode("latin-1") + b"\0"
    else:
        die("bad init '%s' for %s" % (spec, name))
    if len(raw) > size:
        die("init of %s is %d bytes, more than its size %d" % (name, len(raw), size))
    data[: len(raw)] = raw
    return data


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", required=True, choices=("kernel", "platform", "pthread"))
    ap.add_argument("--data-dir", required=True)
    ap.add_argument("--common", required=True)
    ap.add_argument("--defined", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--manifest", required=True)
    args = ap.parse_args()
    lib = args.lib

    surface_path = os.path.join(args.data_dir, "host-lib-surface-%s.json" % lib)
    with open(surface_path, encoding="utf-8") as f:
        surface = json.load(f)
    with open(os.path.join(args.data_dir, "bsd-syscalls.json"), encoding="utf-8") as f:
        bsd = {r["name"]: r for r in json.load(f)}
    mach = {}
    with open(os.path.join(args.data_dir, "mach-traps.json"), encoding="utf-8") as f:
        for r in json.load(f):
            if r.get("status") == "reserved":
                continue
            mach[r["name"]] = r
            if r.get("user_stub"):
                mach[r["user_stub"]] = r

    names = {r["name"] for r in surface}
    overrides = {}
    for lineno, parts in read_table(os.path.join(args.common, "stub-conventions.txt"), lib, 3):
        if len(parts) != 2 or parts[1].strip() not in CONVENTIONS:
            die("stub-conventions.txt:%d: bad row" % lineno)
        if parts[0] not in names:
            die("stub-conventions.txt:%d: %s is not in the %s surface" % (lineno, parts[0], lib))
        overrides[parts[0]] = parts[1].strip()
    data_rows = {}
    for lineno, parts in read_table(os.path.join(args.common, "data-symbols.txt"), lib, 4):
        if parts[0] not in names:
            die("data-symbols.txt:%d: %s is not in the %s surface" % (lineno, parts[0], lib))
        init = parts[2] if len(parts) > 2 else None
        data_rows[parts[0]] = (int(parts[1], 0), init)

    with open(args.defined, encoding="utf-8") as f:
        defined = {line.strip() for line in f if line.strip()}

    text = []
    strings = []
    data_text = []
    const_text = []
    manifest = []
    used_conv = set()

    for row in sorted(surface, key=lambda r: r["name"]):
        name = row["name"]
        if name in defined:
            continue
        if row["kind"] == "data":
            min_size, init = data_rows.get(name, (0, None))
            size = max(min_size, int(row.get("sizeUpperBound") or 0), 1)
            size = (size + 7) & ~7
            align = 4 if size >= 16 else 3
            blob = parse_init(init, size, name)
            section = row.get("section") or "__DATA,__data"
            target = const_text if section.startswith("__TEXT") else data_text
            target.append("    .globl \"%s\"\n    .p2align %d\n\"%s\":\n" % (name, align, name))
            nz = blob.rstrip(b"\0")
            for i in range(0, len(nz), 16):
                target.append("    .byte %s\n" % ", ".join("0x%02x" % b for b in nz[i:i + 16]))
            if len(blob) > len(nz):
                target.append("    .space %d\n" % (len(blob) - len(nz)))
            manifest.append((name, "data", row["category"], "data:%d" % size))
            continue
        conv = overrides.get(name) or default_convention(lib, row, bsd, mach)
        manifest.append((name, row["kind"], row["category"], conv))
        text.append("    .globl \"%s\"\n    .p2align 2\n\"%s\":\n" % (name, name))
        if conv == "nop":
            text.append("    ret\n")
            continue
        idx = len(strings)
        strings.append("Lyc_name_%d:\n    .asciz %s\n" % (idx, asm_string(c_name(name))))
        text.append("    adrp x0, Lyc_name_%d@PAGE\n" % idx)
        text.append("    add x0, x0, Lyc_name_%d@PAGEOFF\n" % idx)
        text.append("    b Lyc_fail_%s\n" % conv)
        used_conv.add(conv)

    out = []
    out.append("// Generated by SimHostLibs/common/gen_stubs.py for libsystem_%s. Do not edit.\n" % lib)
    out.append("// Unimplemented-function stubs (host-libraries.md section 4).\n\n")
    out.append("    .section __TEXT,__text,regular,pure_instructions\n")
    tails = {
        "errno": "    b ___ycode_stub_enosys\n",  # sets errno = ENOSYS, returns -1
        "kern": "    mov w0, #%d\n    ret\n" % KERN_NOT_SUPPORTED,
        "zero": "    mov x0, #0\n    ret\n",
        "void": "    ret\n",
        "errret": "    mov w0, #%d\n    ret\n" % ENOSYS,
        "noreturn": "1:  brk #0x7963\n    b 1b\n",
    }
    for conv in CONVENTIONS:
        if conv not in used_conv:
            continue
        out.append("    .p2align 2\nLyc_fail_%s:\n" % conv)
        out.append("    movz x16, #0x%04x\n    movk x16, #0x%04x, lsl #16\n    svc #0x80\n" % (TRAP_LO, TRAP_HI))
        out.append(tails[conv])
    out.extend(text)
    if strings:
        out.append("\n    .section __TEXT,__cstring,cstring_literals\n")
        out.extend(strings)
    if const_text:
        out.append("\n    .section __TEXT,__const\n")
        out.extend(const_text)
    if data_text:
        out.append("\n    .section __DATA,__data\n")
        out.extend(data_text)
    # No .subsections_via_symbols: the stubs share tails through local labels.

    with open(args.out, "w", encoding="utf-8") as f:
        f.write("".join(out))
    with open(args.manifest, "w", encoding="utf-8") as f:
        f.write("# name\tkind\tcategory\tconvention\n")
        for m in manifest:
            f.write("\t".join(m) + "\n")


if __name__ == "__main__":
    main()
