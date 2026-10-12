#!/usr/bin/env python3 -I
"""air_inventory.py: names-only inventory of AIR modules in metallib files.

Ycode research tool (R8, stage 8a). For every .metallib under ROOT it reads
the container tables (metallib_dump.py), writes each bitcode module to a
scratch directory, converts it to text with llvm-dis, and counts NAMES only:

  - target triples and data layouts
  - producer (llvm.ident) and !air.version / !air.language_version tuples
  - declared functions whose names start with "air." or "llvm." (intrinsics)
  - named metadata (!air.*) and metadata strings that start with "air."
  - string attributes that start with "air-"
  - address spaces that appear in pointer types

It never prints or stores function bodies. Text files are deleted right
after counting. Output: one JSON summary.

Usage: air_inventory.py ROOT SCRATCH_DIR OUT.json [--llvm-dis llvm-dis-18]
       [--filter SUBSTRING ...]
"""
import collections
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import metallib_dump  # noqa: E402

DECL = re.compile(r'^declare\b.*?@"?((?:air|llvm)\.[\w.$]+)"?\(')
NAMED_MD = re.compile(r'^!(air\.[\w.]+|llvm\.[\w.]+)\s*=')
MD_STR = re.compile(r'!"(air\.[\w.]+)"')
ATTR = re.compile(r'"(air-[\w-]+)"')
ADDRSPACE = re.compile(r'addrspace\((\d+)\)')
TRIPLE = re.compile(r'^target triple = "([^"]+)"')
LAYOUT = re.compile(r'^target datalayout = "([^"]+)"')
IDENT = re.compile(r'^!\d+ = !\{!"((?:Apple|LLVM|clang|Metal)[^"]*)"\}')
AIRVER = re.compile(r'^!\d+ = !\{i32 (\d+), i32 (\d+), i32 (\d+)\}')
LANGVER = re.compile(r'^!\d+ = !\{!"(Metal|MetalCI|[A-Za-z]+)", i32 (\d+), i32 (\d+), i32 (\d+)\}')

# Overload suffixes (types) collapsed to get an intrinsic "family".
SUFFIX = re.compile(r'(\.(?:v\d+)?(?:[fiu]\d+|p\d+|i1|f16|bf16|f32|f64|i8|i16|i32|i64|s\.[\w]+))+$')


def family(name):
    return SUFFIX.sub("", name)


def scan_module(path_bc, path_ll, dis, acc, file_acc):
    r = subprocess.run([dis, path_bc, "-o", path_ll], capture_output=True, text=True)
    if r.returncode != 0:
        acc["dis_errors"][r.stderr.strip().splitlines()[-1][:160] if r.stderr else "?"] += 1
        return False
    with open(path_ll, errors="replace") as fh:
        for line in fh:
            m = TRIPLE.match(line)
            if m:
                acc["triples"][m.group(1)] += 1
                continue
            m = LAYOUT.match(line)
            if m:
                acc["layouts"][m.group(1)] += 1
                continue
            m = DECL.match(line)
            if m:
                n = m.group(1)
                acc["intrinsics"][n] += 1
                acc["intrinsic_families"][family(n)] += 1
                file_acc["intrinsic_families"].add(family(n))
                for a in ADDRSPACE.findall(line):
                    acc["addrspace_in_decls"][a] += 1
                continue
            if line.startswith("define "):
                for a in ADDRSPACE.findall(line):
                    acc["addrspace_in_entry_signatures"][a] += 1
                for a in ATTR.findall(line):
                    acc["attributes"][a] += 1
                continue
            if line.startswith("!"):
                m = NAMED_MD.match(line)
                if m:
                    acc["named_metadata"][m.group(1)] += 1
                    file_acc["named_metadata"].add(m.group(1))
                for s in MD_STR.findall(line):
                    acc["metadata_strings"][s] += 1
                    file_acc["metadata_strings"].add(s)
                m = IDENT.match(line)
                if m:
                    acc["producers"][m.group(1)] += 1
                m = LANGVER.match(line)
                if m:
                    acc["language_versions"]["%s %s.%s.%s" % m.groups()] += 1
                continue
            if line.startswith("attributes #"):
                for a in ATTR.findall(line):
                    acc["attributes"][a] += 1
    os.unlink(path_ll)
    return True


def main():
    args = sys.argv[1:]
    dis = "llvm-dis-18"
    if "--llvm-dis" in args:
        i = args.index("--llvm-dis")
        dis = args[i + 1]
        del args[i:i + 2]
    filters = []
    while "--filter" in args:
        i = args.index("--filter")
        filters.append(args[i + 1])
        del args[i:i + 2]
    root, scratch, out = args
    os.makedirs(scratch, exist_ok=True)
    acc = collections.defaultdict(collections.Counter)
    files = []
    per_file = {}
    for d, _, fs in os.walk(root):
        for f in fs:
            if f.endswith(".metallib"):
                p = os.path.join(d, f)
                if filters and not any(x in p for x in filters):
                    continue
                files.append(p)
    files.sort()
    for p in files:
        rel = os.path.relpath(p, root)
        try:
            h = metallib_dump.dump(p, scratch + "/mods")
        except (Exception, SystemExit) as e:  # noqa: BLE001
            acc["parse_errors"][str(e)[:120]] += 1
            continue
        fa = {"intrinsic_families": set(), "named_metadata": set(),
              "metadata_strings": set()}
        acc["file_types"][h["file_type"]] += 1
        acc["platforms"][h["platform"]] += 1
        acc["container_versions"][h["container_version"]] += 1
        acc["os_versions"][h["os_version"]] += 1
        for t, _ in h["header_extension"]:
            acc["header_extension_tags"][t] += 1
        nf = len(h["functions"])
        acc["functions_total"]["n"] += nf
        for f in h["functions"]:
            acc["function_types"][str(f.get("TYPE"))] += 1
            acc["function_tags"][",".join(f["_tags"])] += 1
            acc["vers"][str(f.get("VERS"))] += 1
            for t, _ in f["_public_tags"] or []:
                acc["public_md_tags"][t] += 1
            for t, _ in f["_private_tags"] or []:
                acc["private_md_tags"][t] += 1
        nm = len(h["modules"])
        acc["modules_total"]["n"] += nm
        acc["layout_kind"]["single-module" if nm == 1 and nf > 1 else
                           "per-function" if nm == nf else "mixed"] += 1
        ok = 0
        for i in range(nm):
            bc = os.path.join(scratch, "mods", "%d.bc" % i)
            if scan_module(bc, bc + ".ll", dis, acc, fa):
                ok += 1
            os.unlink(bc)
        per_file[rel] = {"functions": nf, "modules": nm, "disassembled": ok,
                         "file_type": h["file_type"],
                         "size": h["file_size"],
                         "types": dict(collections.Counter(str(f.get("TYPE")) for f in h["functions"])),
                         "intrinsic_families": sorted(fa["intrinsic_families"]),
                         "named_metadata": sorted(fa["named_metadata"]),
                         "metadata_strings": sorted(fa["metadata_strings"])}
        for k in fa["intrinsic_families"]:
            acc["families_by_file_count"][k] += 1
        for k in fa["metadata_strings"]:
            acc["md_strings_by_file_count"][k] += 1
    res = {"root": root, "files": len(files)}
    for k, v in acc.items():
        res[k] = dict(v.most_common())
    res["per_file"] = per_file
    with open(out, "w") as fh:
        json.dump(res, fh, indent=1)
    print("files", len(files), "modules", acc["modules_total"]["n"],
          "functions", acc["functions_total"]["n"],
          "dis_errors", sum(acc["dis_errors"].values()))


if __name__ == "__main__":
    main()
