#!/usr/bin/env python3 -I
"""addrspace_names.py: which pointee type NAMES appear with each address
space in entry-point signatures and declarations (names only, counted).

Ycode research tool (R8). Usage: addrspace_names.py ROOT SCRATCH [llvm-dis]
Prints {addrspace: {pointee-type-name: count}} as JSON. Never prints code.
"""
import collections
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import metallib_dump  # noqa: E402

PTR = re.compile(r'(%[\w."$:]+|i\d+|float|half|double|<\d+ x \w+>|\[[^\]]*\]|\{[^}]*\}|ptr) addrspace\((\d+)\)')


def main():
    root, scratch = sys.argv[1], sys.argv[2]
    dis = sys.argv[3] if len(sys.argv) > 3 else "llvm-dis-18"
    acc = collections.defaultdict(collections.Counter)
    files = collections.defaultdict(set)
    for d, _, fs in os.walk(root):
        for f in fs:
            if not f.endswith(".metallib"):
                continue
            p = os.path.join(d, f)
            try:
                h = metallib_dump.dump(p, scratch)
            except (Exception, SystemExit):
                continue
            for i in range(len(h["modules"])):
                bc = os.path.join(scratch, "%d.bc" % i)
                ll = bc + ".ll"
                if subprocess.run([dis, bc, "-o", ll]).returncode == 0:
                    for line in open(ll, errors="replace"):
                        if line.startswith(("define ", "declare ")):
                            for t, a in PTR.findall(line):
                                if int(a) >= 4:
                                    acc[a][t.split('"')[0][:60]] += 1
                                    files[a].add(os.path.relpath(p, root))
                    os.unlink(ll)
                os.unlink(bc)
    out = {a: {"types": dict(c.most_common(15)), "files": sorted(files[a])[:12],
               "file_count": len(files[a])} for a, c in acc.items()}
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
