#!/usr/bin/env python3
# Copies the libraries the shipped programs need from the toolchain's runtime
# folder: the closure of DT_NEEDED, so nothing unused ships.
#
# usage: copy-runtime-libraries.py <runtime-dir> <install-dir> <scan-dir>...
import os
import shutil
import subprocess
import sys


def needed(path):
    try:
        out = subprocess.run(["readelf", "-d", path], capture_output=True, text=True, check=True).stdout
    except subprocess.CalledProcessError:
        return []
    return [line.split("[")[1].split("]")[0] for line in out.splitlines() if "(NEEDED)" in line]


def is_elf(path):
    with open(path, "rb") as f:
        return f.read(4) == b"\x7fELF"


def main():
    runtime, install = sys.argv[1], sys.argv[2]
    queue = []
    for directory in sys.argv[3:]:
        for name in os.listdir(directory):
            path = os.path.join(directory, name)
            if os.path.isfile(path) and is_elf(path):
                queue.append(path)
    seen = set()
    while queue:
        for lib in needed(queue.pop()):
            source = os.path.join(runtime, lib)
            if lib in seen or not os.path.exists(source):
                continue
            seen.add(lib)
            target = os.path.join(install, lib)
            shutil.copy2(source, target)
            queue.append(target)
    print("Swift runtime libraries:", " ".join(sorted(seen)))


if __name__ == "__main__":
    main()
