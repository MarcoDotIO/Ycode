#!/usr/bin/env python3
# Copies everything a program needs to run under its own dynamic loader: the
# closure of DT_NEEDED of the given ELF files, the C library and the loader
# included, found in the search folders in order (the first match wins) and
# copied (symbolic links resolved) into one folder under each soname. The
# program then runs as `<dir>/ld-linux-*.so.* --library-path <dir> <program>`
# on a system whose own C library is older than the one it was built with
# (build-ycode.sh does this for ycode-airc).
#
# usage: copy-private-runtime.py <dest-dir> <elf>... -- <search-dir>...
import os
import shutil
import subprocess
import sys


def needed(path):
    out = subprocess.run(["readelf", "-d", path], capture_output=True, text=True, check=True).stdout
    return [line.split("[")[1].split("]")[0] for line in out.splitlines() if "(NEEDED)" in line]


def interpreter(path):
    out = subprocess.run(["readelf", "-l", path], capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        if "Requesting program interpreter:" in line:
            return os.path.basename(line.split(":", 1)[1].strip().rstrip("]"))
    return None


def main():
    args = sys.argv[1:]
    if "--" not in args or args.index("--") < 2:
        sys.exit("usage: copy-private-runtime.py <dest-dir> <elf>... -- <search-dir>...")
    split = args.index("--")
    dest, programs, search = args[0], args[1:split], args[split + 1:]
    os.makedirs(dest, exist_ok=True)
    queue = list(programs)
    wanted = {interpreter(p) for p in programs} - {None}
    seen = set()
    copied = []
    while queue or wanted:
        names = needed(queue.pop()) if queue else []
        names += sorted(wanted)
        wanted = set()
        for lib in names:
            if lib in seen:
                continue
            seen.add(lib)
            source = next((os.path.join(d, lib) for d in search if os.path.exists(os.path.join(d, lib))), None)
            if source is None:
                sys.exit(f"copy-private-runtime: {lib} was not found in {' '.join(search)}")
            target = os.path.join(dest, lib)
            if os.path.realpath(source) != os.path.realpath(target):
                if os.path.lexists(target):
                    os.remove(target)
                shutil.copy2(os.path.realpath(source), target)
                copied.append(lib)
            queue.append(target)
    print("private runtime in", dest + ":", " ".join(sorted(seen)), "(copied:", " ".join(sorted(copied)) + ")")


if __name__ == "__main__":
    main()
