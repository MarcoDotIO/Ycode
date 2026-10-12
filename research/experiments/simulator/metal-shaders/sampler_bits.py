#!/usr/bin/env python3 -I
"""sampler_bits.py: learn the encoding of constexpr sampler state words.

Ycode research tool (R8). Compiles one tiny shader of ours per constexpr
sampler variant with the public Metal toolchain (xcrun metal -S -emit-llvm)
and prints the two 64-bit words of each @__air_sampler_state global, so that
each field's bits can be read off by varying one argument at a time.

Usage: sampler_bits.py SCRATCH_DIR
"""
import re
import subprocess
import sys

VARIANTS = [
    "coord::normalized",  # all defaults (an empty list is a declaration)
    "coord::pixel",
    "address::clamp_to_edge", "address::repeat", "address::mirrored_repeat",
    "address::clamp_to_zero", "address::clamp_to_border",
    "s_address::repeat", "t_address::repeat", "r_address::repeat",
    "filter::linear", "mag_filter::linear", "min_filter::linear",
    "mip_filter::nearest", "mip_filter::linear",
    "compare_func::less", "compare_func::greater", "compare_func::always",
    "compare_func::never", "compare_func::less_equal", "compare_func::equal",
    "compare_func::not_equal", "compare_func::greater_equal",
    "max_anisotropy(2)", "max_anisotropy(16)",
    "lod_clamp(1.0f, 4.0f)",
    "border_color::opaque_white", "border_color::opaque_black",
    "reduction::minimum", "reduction::maximum",
    "address::clamp_to_border, border_color::opaque_white",
    "address::clamp_to_zero, border_color::opaque_white",
]

SRC = """#include <metal_stdlib>
using namespace metal;
kernel void k(texture2d<float> t [[texture(0)]], device float4 *o [[buffer(0)]]) {
    constexpr sampler s(%s);
    o[0] = t.sample(s, float2(0.5));
}
"""


def main():
    d = sys.argv[1]
    for v in VARIANTS:
        src = "%s/s.metal" % d
        open(src, "w").write(SRC % v)
        r = subprocess.run(["xcrun", "-sdk", "iphonesimulator", "metal", "-S",
                            "-emit-llvm", src, "-o", "%s/s.ll" % d],
                           capture_output=True, text=True)
        if r.returncode:
            print("%-28s ERROR %s" % (v, r.stderr.strip().splitlines()[0][:80]))
            continue
        txt = open("%s/s.ll" % d).read()
        m = re.search(r"@__air_sampler_state\S* = .*\[i64 (-?\d+), i64 (-?\d+)\]", txt)
        if not m:
            print("%-28s no sampler state" % v)
            continue
        a, b = (int(x) & (2**64 - 1) for x in m.groups())
        print("%-28s %016x %016x  %s" % (v or "(default)", a, b, format(a, "064b")))


if __name__ == "__main__":
    main()
