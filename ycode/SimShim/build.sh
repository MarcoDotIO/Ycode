#!/bin/sh
# Builds the Ycode micro-VM guest binaries (see README.md):
#   out/shim.bin          EL1 shim, linked at 0x4000_0000, entry = first byte
#   out/el0_selftest.bin  EL0 self-test, linked at 0x1_0000_0000
#   out/host_stubs.bin    stage-3a host page, linked at 0x3_1000_0000,
#                         exactly 0x10000 bytes (stage3-contract.md section 5)
#   out/host_stubs.syms   host page symbol offsets (needs llvm-nm)
#
# Needs clang, ld.lld and llvm-objcopy (llvm-nm is optional). On Linux they come from the Swift
# toolchain:  . ~/.local/share/swiftly/env.sh && sh build.sh
# Override the tools with CLANG=, LD_LLD=, OBJCOPY= if needed.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
out="$here/out"

CLANG=${CLANG:-clang}
LD_LLD=${LD_LLD:-ld.lld}
OBJCOPY=${OBJCOPY:-llvm-objcopy}

die() {
    echo "build.sh: error: $*" >&2
    exit 1
}

for tool in "$CLANG" "$LD_LLD" "$OBJCOPY"; do
    command -v "$tool" >/dev/null 2>&1 || die "'$tool' not found in PATH"
done

mkdir -p "$out"

# Linker scripts. Both put .text.start (the entry point) first.
cat > "$out/shim.ld" <<'EOF'
ENTRY(_start)
SECTIONS
{
    . = 0x40000000;
    .text : { *(.text.start) *(.text .text.*) *(.rodata .rodata.*) }
    .data : { *(.data .data.*) *(.bss .bss.* COMMON) }
    /DISCARD/ : { *(.comment) *(.note .note.*) *(.ARM.attributes) }
}
EOF

cat > "$out/el0_selftest.ld" <<'EOF'
ENTRY(_start)
SECTIONS
{
    . = 0x100000000;
    .text : { *(.text.start) *(.text .text.*) *(.rodata .rodata.*) }
    . = ALIGN(16384);
    .data : { *(.data .data.*) *(.bss .bss.* COMMON) }
    /DISCARD/ : { *(.comment) *(.note .note.*) *(.ARM.attributes) }
}
EOF

# The host page: code at +0, helpers table at +0x4000, RW data at +0x8000.
# The fixed addresses make ld.lld fail if a part outgrows its slot.
cat > "$out/host_stubs.ld" <<'EOF'
ENTRY(_ycode_launch)
SECTIONS
{
    . = 0x310000000;
    .text : { *(.text.start) *(.text .text.*) }
    . = 0x310004000;
    .rodata : { *(.rodata.helpers) *(.rodata .rodata.*) }
    . = 0x310008000;
    .data : { *(.data.host) *(.data .data.*) *(.bss .bss.* COMMON) }
    /DISCARD/ : { *(.comment) *(.note .note.*) *(.ARM.attributes) }
}
EOF

build() {
    name=$1
    "$CLANG" -target aarch64-none-elf -march=armv8-a -c \
        -o "$out/$name.o" "$here/$name.S" \
        || die "assembling $name.S failed"
    "$LD_LLD" -nostdlib -static --no-pie --build-id=none \
        -T "$out/$name.ld" -o "$out/$name.elf" "$out/$name.o" \
        || die "linking $name failed"
    "$OBJCOPY" -O binary "$out/$name.elf" "$out/$name.bin" \
        || die "objcopy $name failed"
    [ -s "$out/$name.bin" ] || die "$name.bin is empty"
    size=$(wc -c < "$out/$name.bin" | tr -d ' ')
    echo "$out/$name.bin: $size bytes"
}

build shim
build el0_selftest
build host_stubs

# Layout checks the contract depends on.
shim_size=$(wc -c < "$out/shim.bin" | tr -d ' ')
[ "$shim_size" -le 1048576 ] || die "shim.bin is larger than 1 MiB ($shim_size bytes)"

selftest_size=$(wc -c < "$out/el0_selftest.bin" | tr -d ' ')
[ "$selftest_size" -ge 16392 ] || die "el0_selftest.bin has no data page ($selftest_size bytes)"
# The magic 0x5943_4F44_4531_3645 must be the first 8 bytes at file offset 0x4000.
magic=$(od -A n -t x1 -j 16384 -N 8 "$out/el0_selftest.bin" | tr -d ' \n')
[ "$magic" = "45363145444f4359" ] || die "el0_selftest.bin: wrong magic at 0x4000 ('$magic')"

# Host page checks (stage3-contract.md section 5).
hs="$out/host_stubs.bin"
hs_size=$(wc -c < "$hs" | tr -d ' ')
[ "$hs_size" -eq 65536 ] || die "host_stubs.bin must be exactly 65536 bytes (is $hs_size)"

# The little-endian u64 at file offset $1 of host_stubs.bin, as 16 hex digits.
u64_at() {
    od -A n -t x1 -j "$1" -N 8 -v "$hs" | tr -d ' \n' |
        sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\8\7\6\5\4\3\2\1/'
}
helpers=16384   # 0x4000
[ "$(u64_at $helpers)" = "0000000000000012" ] \
    || die "helpers table: the word at 0x4000 is not version 18 ($(u64_at $helpers))"
slot=1
while [ $slot -le 67 ]; do
    v=$(u64_at $((helpers + 8 * slot)))
    if [ $slot -eq 32 ] || [ $slot -eq 33 ]; then
        [ "$v" = "0000000000000000" ] || die "helpers slot $slot must be 0 (is $v)"
    else
        # A code address in the host page: 0x3_1000_0000 .. 0x3_1000_3FFF.
        case "$v" in
            000000031000[0-3]???) ;;
            *) die "helpers slot $slot ($v) does not point into the host page code" ;;
        esac
    fi
    slot=$((slot + 1))
done
[ "$(u64_at $((helpers + 544)))" = "0000000000000000" ] \
    || die "something follows the 544-byte helpers table"
ret=$(od -A n -t x1 -j 3840 -N 4 -v "$hs" | tr -d ' \n')
[ "$ret" = "c0035fd6" ] || die "no 'ret' at host page offset 0x0F00 ('$ret')"
entry=$(od -A n -t x1 -j 0 -N 4 -v "$hs" | tr -d ' \n')
[ "$entry" != "00000000" ] || die "no code at host page offset 0"
nonzero=$(od -A n -t x1 -j 32768 -N 32768 -v "$hs" | tr -d ' 0\n')
[ -z "$nonzero" ] || die "host page RW data (+0x8000..+0xFFFF) is not zero-filled"
echo "host_stubs.bin: helpers table at 0x4000 (version 18), ret stub at 0x0F00"

# Symbol offsets from the host page base, for the VMM and for tracing.
NM=${NM:-llvm-nm}
if command -v "$NM" >/dev/null 2>&1; then
    "$NM" -n "$out/host_stubs.elf" > "$out/host_stubs.nm" || die "llvm-nm failed"
    # Addresses are 0x0000_0003_100X_XXXX: the offset is the last 5 hex digits.
    awk '$2 ~ /^[TtDdRr]$/ && $3 !~ /^\$/ { printf "+0x%s  %s\n", substr($1, 12, 5), $3 }' \
        "$out/host_stubs.nm" > "$out/host_stubs.syms"
    echo "$out/host_stubs.syms: $(wc -l < "$out/host_stubs.syms" | tr -d ' ') symbols"
fi

echo "build.sh: ok"
