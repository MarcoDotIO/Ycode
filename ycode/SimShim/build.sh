#!/bin/sh
# Builds the Ycode stage-2 guest binaries (see README.md):
#   out/shim.bin          EL1 shim, linked at 0x4000_0000, entry = first byte
#   out/el0_selftest.bin  EL0 self-test, linked at 0x1_0000_0000
#
# Needs clang, ld.lld and llvm-objcopy. On Linux they come from the Swift
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

# Layout checks the contract depends on.
shim_size=$(wc -c < "$out/shim.bin" | tr -d ' ')
[ "$shim_size" -le 1048576 ] || die "shim.bin is larger than 1 MiB ($shim_size bytes)"

selftest_size=$(wc -c < "$out/el0_selftest.bin" | tr -d ' ')
[ "$selftest_size" -ge 16392 ] || die "el0_selftest.bin has no data page ($selftest_size bytes)"
# The magic 0x5943_4F44_4531_3645 must be the first 8 bytes at file offset 0x4000.
magic=$(od -A n -t x1 -j 16384 -N 8 "$out/el0_selftest.bin" | tr -d ' \n')
[ "$magic" = "45363145444f4359" ] || die "el0_selftest.bin: wrong magic at 0x4000 ('$magic')"

echo "build.sh: ok"
