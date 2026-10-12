#!/usr/bin/env python3 -I
"""categorize.py: group intrinsic family names from air_inventory.py output.

Usage: categorize.py inventory.json [home-screen-substring ...]
Prints per-category family counts (number of files using each family) and
the union for the files whose path contains any given substring.
"""
import json
import re
import sys

CATS = [
    ("convert", r"^air\.convert"),
    ("texture-sample", r"^air\.(sample|gather)_"),
    ("texture-read-write", r"^air\.(read|write|fence)_"),
    ("texture-query", r"^air\.(get_(width|height|depth|num_mip_levels|num_samples|array_size)|is_null|get_null)_"),
    ("sampler", r"^air\.get_.*sampler"),
    ("atomic", r"^air\.atomic\."),
    ("barrier", r"^air\.(wg|simdgroup|mem)\.barrier|^air\.(threadgroup|simdgroup)_barrier"),
    ("simd-quad", r"^air\.(simd_|quad_|get_simdgroup|is_uniform|simdgroup_matrix|simdgroup\.)"),
    ("imageblock-tile", r"imageblock|^air\.(get_.*color|.*_tile_|write_imageblock)"),
    ("fragment-control", r"^air\.(discard_fragment|dfdx|dfdy|fwidth|get_.*sample|get_.*pixel|render_target|set_.*depth)"),
    ("function-constant", r"function_constant"),
    ("ray-tracing", r"intersect|acceleration_structure|raytracing|ray_"),
    ("function-table", r"visible_function|function_table|^air\.get_function_pointer"),
    ("pack-unpack", r"^air\.(pack|unpack)\."),
    ("math", r"^air\.(fast_|precise_)?[a-z0-9_]+$|^air\.(fast_|precise_)?[a-z0-9_]+\.(u|s)$"),
    ("llvm", r"^llvm\."),
]


def norm(f):
    if f.startswith("air.convert"):
        return "air.convert"
    return f


def cat(f):
    for name, rx in CATS:
        if re.search(rx, f):
            return name
    return "other"


def main():
    r = json.load(open(sys.argv[1]))
    subs = sys.argv[2:]
    fam = {}
    for f, n in r["families_by_file_count"].items():
        fam[norm(f)] = max(fam.get(norm(f), 0), n)
    bycat = {}
    for f, n in fam.items():
        bycat.setdefault(cat(f), []).append((f, n))
    home = set()
    for path, v in r["per_file"].items():
        if any(s in path for s in subs):
            home |= {norm(x) for x in v["intrinsic_families"]}
    out = {}
    for c, lst in sorted(bycat.items()):
        lst.sort(key=lambda x: -x[1])
        hs = sorted(f for f, _ in lst if f in home)
        out[c] = {"families": len(lst), "home_screen": len(hs),
                  "top": lst[:25], "home_list": hs}
    print(json.dumps({"families_total": len(fam), "home_total": len(home),
                      "categories": out}, indent=1))


if __name__ == "__main__":
    main()
