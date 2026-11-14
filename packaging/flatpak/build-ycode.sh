#!/bin/sh
# The Ycode module of the Flatpak: runs inside flatpak-builder, in the unpacked
# source, with no network. See io.github.MarcoDotIO.Ycode.yml.
set -eu

root=$PWD
arch=$(uname -m)
export HOME="$root/.home"
mkdir -p "$HOME"

python3 packaging/flatpak/prepare-swift-deps.py deps ycode ycode/Tools/ycode-swb

# Source paths in the binaries become relative; lld because the runtime has no gold.
# The package runs from wherever it is unpacked: libraries are found relative to
# the binary, from bin/ and from lib/ycode-sim/.build/release/. llbuild asks for
# ncurses for its terminal queries, which this runtime keeps in libtinfo.
# shellcheck disable=SC2016 # $ORIGIN is for the dynamic linker
# flatpak-builder's --jobs (FLATPAK_BUILDER_N_JOBS) limits SwiftPM too, for a shared builder.
jobs=${FLATPAK_BUILDER_N_JOBS:-$(nproc)}
swift_build() { # package-dir label product
    (cd "$1" && swift build -c release -j "$jobs" --force-resolved-versions -Xswiftc -use-ld=lld -Xlinker -ltinfo \
        -Xlinker -rpath -Xlinker '$ORIGIN/../lib' -Xlinker -rpath -Xlinker '$ORIGIN/../../..' \
        -Xswiftc -file-prefix-map -Xswiftc "$PWD=$2" -Xcc -ffile-prefix-map="$PWD=$2" \
        -Xcxx -ffile-prefix-map="$PWD=$2" --product "$3")
}

# What every package ships. ycode-ide comes first: it builds most of the rest.
tools="ycode-ide ycode ycodebuild ycode-bsp ycode-sim-viewer"
[ "$arch" = aarch64 ] && tools="$tools ycode-simd ycode-simhost"
for tool in $tools YcodeGaugeAgent; do
    swift_build ycode ycode "$tool"
done
for tool in ycode-swb SWBBuildServiceBundle; do
    swift_build ycode/Tools/ycode-swb ycode-swb "$tool"
done

bin=$(cd ycode && swift build -c release --show-bin-path)
swb=$(cd ycode/Tools/ycode-swb && swift build -c release --show-bin-path)
install -d /app/bin /app/lib /app/libexec/ycode-host /app/share/doc/ycode
for tool in $tools; do
    [ "$tool" = ycode-simd ] || install -m755 "$bin/$tool" /app/bin/
done
install -m755 "$bin/libYcodeGaugeAgent.so" /app/lib/
install -m755 "$swb/ycode-swb" "$swb/SWBBuildServiceBundle" /app/bin/
# SwiftPM resource folders: a tool looks for them next to itself (the UI's fonts,
# swift-build's specifications, both open source; see THIRD_PARTY_NOTICES.md).
for folder in "$bin"/*.resources "$bin"/*.bundle "$swb"/*.resources "$swb"/*.bundle; do
    if [ -d "$folder" ]; then cp -R "$folder" /app/bin/; fi
done

# The script a run on a simulator host builds with (ShellRemoteRun.toolsRoot finds
# a scripts/ folder up to three levels above the executable).
install -Dm755 ycode/scripts/ycode-ios-build-linux /app/scripts/ycode-ios-build-linux

# Tools that run on the host, through flatpak-spawn.
install -m755 packaging/flatpak/host-tool.sh /app/libexec/ycode-host/host-tool
for tool in swift swiftc swift-build swift-test swift-package swift-run sourcekit-lsp lldb lldb-dap clang clang++ \
            git ssh scp rsync make pkg-config; do
    ln -sf host-tool "/app/libexec/ycode-host/$tool"
done

# aarch64: the simulator tools, laid out like the source tree the scripts and
# ycode-simd expect (they look for each other by relative path).
if [ "$arch" = aarch64 ]; then
    sim=/app/lib/ycode-sim
    (cd ycode && sh SimShim/build.sh)
    (cd ycode && YCODE="$bin/ycode" sh SimHostLibs/build.sh)
    (cd ycode && sh SimGuestFrameworks/build.sh)
    # ycode-airc and libLLVM are built for this runtime, whose C library (and
    # libm: libLLVM takes sinh and cosh at GLIBC_2.44) is newer than many
    # distributions' (Ubuntu 24.04 has 2.39), and the tree must run there too
    # (docs/SIMULATOR-LINUX.md). So the translator gets its own folder, airc/,
    # with this runtime's dynamic loader, C library and every other library it
    # needs (copy-private-runtime.py), and .build/release/ycode-airc is a
    # wrapper that starts it under that loader: the same program everywhere.
    # Not LDFLAGS for the run-time path: under Ninja the $ORIGIN in it is lost
    # (the 1.0.0-beta.1 binary had /../../..). $ORIGIN/lib serves a direct run.
    # shellcheck disable=SC2016 # $ORIGIN is for the dynamic linker
    YCODE_AIRC_RPATH='$ORIGIN/lib' PKG_CONFIG_PATH=/app/lib/pkgconfig LLVM_DIR=/usr/lib/sdk/llvm22/lib/cmake/llvm \
        PATH="/usr/lib/sdk/llvm22/bin:$PATH" sh ycode/Translator/build.sh "$root/airc-build"
    install -d "$sim/.build/release" "$sim/scripts" "$sim/airc/lib"
    install -m755 "$bin/ycode-simd" "$sim/.build/release/"
    install -m755 "$root/airc-build/ycode-airc" "$sim/airc/ycode-airc"
    cp -L /usr/lib/sdk/llvm22/lib/libLLVM.so.22.1 /app/airc-staging/lib/libxml2.so.16 "$sim/airc/lib/"
    python3 packaging/flatpak/copy-private-runtime.py "$sim/airc/lib" "$sim/airc/ycode-airc" \
        -- "$sim/airc/lib" "/usr/lib/$arch-linux-gnu" /usr/lib
    loader=$(cd "$sim/airc/lib" && ls ld-linux-*.so.*)
    cat > "$sim/.build/release/ycode-airc" <<SCRIPT
#!/bin/sh
# ycode-airc under its own dynamic loader and libraries (../../airc; see
# packaging/flatpak/build-ycode.sh): runs where the C library is older than
# the one it was built with.
air=\$(cd "\$(dirname "\$(readlink -f "\$0")")/../../airc" && pwd)
export YCODE_AIRC_SELF="\$air/ycode-airc"
exec "\$air/lib/$loader" --library-path "\$air/lib" --argv0 "\$0" "\$air/ycode-airc" "\$@"
SCRIPT
    chmod 755 "$sim/.build/release/ycode-airc"
    ln -sf ../lib/ycode-sim/.build/release/ycode-simd /app/bin/ycode-simd
    ln -sf ../lib/ycode-sim/.build/release/ycode-airc /app/bin/ycode-airc
    install -m755 ycode/scripts/ycode-sim.sh ycode/scripts/ycode-sim-serve "$sim/scripts/"
    for part in SimShim SimHostLibs SimGuestFrameworks; do
        install -d "$sim/$part"
        cp -R "ycode/$part/out" "$sim/$part/"
    done
    # The guest tools (ylaunch and the agents), where ycode-simd and
    # ycode-simhost look first: without them a device boots but cannot install
    # or launch an app (docs/SIMULATOR-UX.md §7).
    if [ -f guest-tools/ylaunch ]; then
        install -d "$sim/SimShim/out/guest-tests/stage7"
        cp -R guest-tools/. "$sim/SimShim/out/guest-tests/stage7/"
        rm -f "$sim/SimShim/out/guest-tests/stage7/README"
    else
        echo "build-ycode: warning: no guest tools (YCODE_GUEST_TOOLS); the simulator tree can boot devices but not run apps" >&2
    fi
    # Build leftovers are not shipped (objects, linker scripts, listings).
    find "$sim" \( -name '*.o' -o -name '*.ld' -o -name '*.elf' \) -delete
    # Relative to where the package is.
    cat > /app/bin/ycode-sim <<'SCRIPT'
#!/bin/sh
sim=$(cd "$(dirname "$(readlink -f "$0")")/../lib/ycode-sim" && pwd)
export YCODE_SIM_TREE="${YCODE_SIM_TREE:-$sim}"
exec "$sim/scripts/ycode-sim.sh" "$@"
SCRIPT
    chmod 755 /app/bin/ycode-sim
fi

# The display stream's JPEG (CYcodeCodec loads libjpeg at run time, by this
# SDK's soname): next to the programs, whose run-time path has lib/, so a
# distribution without this soname (Ubuntu has libjpeg.so.8) still streams JPEG.
jpeg=$(ls "/usr/lib/$arch-linux-gnu"/libjpeg.so.[0-9]* | grep -E 'libjpeg\.so\.[0-9]+$' | head -n 1)
cp -L "$jpeg" /app/lib/

# The Swift runtime libraries the tools load, and nothing else of the toolchain.
python3 packaging/flatpak/copy-runtime-libraries.py /app/swift/usr/lib/swift/linux /app/lib /app/bin /app/lib

# Desktop integration.
id=io.github.MarcoDotIO.Ycode
install -Dm644 "packaging/flatpak/$id.desktop" "/app/share/applications/$id.desktop"
install -Dm644 "packaging/flatpak/$id.metainfo.xml" "/app/share/metainfo/$id.metainfo.xml"
if [ -d packaging/icon/hicolor ]; then
    install -d /app/share/icons
    cp -R packaging/icon/hicolor /app/share/icons/
else
    echo "build-ycode: warning: no packaging/icon/hicolor; the package has no icon" >&2
fi

install -m644 LICENSE THIRD_PARTY_NOTICES.md /app/share/doc/ycode/
