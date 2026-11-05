#!/usr/bin/env python3
# check_imports.py - list the imports of Mach-O images that a macOS userland
# root cannot satisfy (specs/macos/libsystem.md §12). Ycode's dyld binds
# every import at load time (dyld.md §5), so one missing non-weak symbol
# stops a program; this finds all of them at once, before a run.
#
#   check_imports.py ROOT IMAGE...    print "image: library: symbol" for each
#                                     import that ROOT does not export;
#                                     exit 1 if any non-weak one is missing
#
# Exports come from `llvm-nm -gU -j` (NM overrides) of the library named by
# the import's two-level ordinal, following LC_REEXPORT_DYLIB. @rpath names
# are looked up in ROOT/usr/lib/swift and the directories of the images.
# Clean-room Ycode code from the public <mach-o/loader.h> facts.

import os
import struct
import subprocess
import sys

MAGIC_64 = 0xFEEDFACF
LC_LOAD_DYLIB = 0xC
LC_ID_DYLIB = 0xD
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_LOAD_UPWARD_DYLIB = 0x80000023
DEPENDENCY_COMMANDS = (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB)

NM = os.environ.get("NM", "llvm-nm")


def load_commands(path):
    data = open(path, "rb").read()
    magic, _, _, _, ncmds, _ = struct.unpack_from("<6I", data, 0)
    if magic != MAGIC_64:
        raise SystemExit(f"{path}: not a thin 64-bit Mach-O image")
    at = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<2I", data, at)
        yield cmd, data[at:at + size]
        at += size


def dylib_name(command):
    offset = struct.unpack_from("<I", command, 8)[0]
    return command[offset:].split(b"\0", 1)[0].decode()


def dependencies(path):
    """(kind, install name) of each dependency, in ordinal order."""
    return [(cmd, dylib_name(body)) for cmd, body in load_commands(path) if cmd in DEPENDENCY_COMMANDS]


def short_name(install_name):
    """The library name llvm-nm prints in "(from X)"."""
    leaf = install_name.rsplit("/", 1)[-1]
    if ".framework/" in install_name:
        return leaf
    for suffix in (".dylib",):
        if leaf.endswith(suffix):
            leaf = leaf[: -len(suffix)]
    # libFoo.A / libFoo.1 / libFoo.B -> libFoo
    head, dot, tail = leaf.partition(".")
    return head if dot and len(tail) <= 2 else leaf


class Root:
    def __init__(self, root, extra_dirs):
        self.root = root
        self.search = [os.path.join(root, "usr/lib/swift")] + extra_dirs
        self.cache = {}

    def resolve(self, install_name):
        if install_name.startswith("@rpath/") or install_name.startswith("@loader_path/") \
                or install_name.startswith("@executable_path/"):
            leaf = install_name.split("/", 1)[1]
            for directory in self.search:
                candidate = os.path.join(directory, leaf)
                if os.path.exists(candidate):
                    return candidate
            return None
        candidate = os.path.join(self.root, install_name.lstrip("/"))
        return candidate if os.path.exists(candidate) else None

    def exports(self, install_name, depth=0):
        if install_name in self.cache:
            return self.cache[install_name]
        path = self.resolve(install_name)
        names = set()
        if path and depth < 16:
            out = subprocess.run([NM, "-gU", "-j", path], capture_output=True, text=True, check=True).stdout
            names.update(out.split())
            for cmd, name in dependencies(path):
                if cmd == LC_REEXPORT_DYLIB:
                    names |= self.exports(name, depth + 1)
        self.cache[install_name] = names
        return names


def undefined(path):
    """(symbol, short library name or None, weak) for each import."""
    out = subprocess.run([NM, "-m", "-u", path], capture_output=True, text=True, check=True).stdout
    result = []
    for line in out.splitlines():
        line = line.strip()
        if "(undefined)" not in line:
            continue
        weak = " weak " in line
        library = None
        if line.endswith(")") and "(from " in line:
            library = line[line.rindex("(from ") + 6:-1]
            line = line[: line.rindex("(from ")].strip()
        result.append((line.split()[-1], library, weak))
    return result


def main(argv):
    if len(argv) < 3:
        raise SystemExit(__doc__ if __doc__ else "usage: check_imports.py ROOT IMAGE...")
    root = Root(argv[1], sorted({os.path.dirname(os.path.abspath(p)) for p in argv[2:]}))
    missing_strong = 0
    for image in argv[2:]:
        libraries = {short_name(name): name for _, name in dependencies(image)}
        for symbol, library, weak in undefined(image):
            if library is None:
                continue
            install_name = libraries.get(library)
            if install_name is None:
                print(f"{image}: {library}: {symbol} (library not among the dependencies)")
                missing_strong += 1
                continue
            if symbol in root.exports(install_name):
                continue
            if root.resolve(install_name) is None:
                tag = "library missing"
            else:
                tag = "weak" if weak else "missing"
            print(f"{os.path.basename(image)}: {install_name}: {symbol} [{tag}]")
            if not weak:
                missing_strong += 1
    print(f"check_imports: {missing_strong} unresolved non-weak import(s)", file=sys.stderr)
    return 1 if missing_strong else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
