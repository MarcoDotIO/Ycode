// The simulator host's setup script (#70), as text: Ycode sends it over ssh
// (`bash -s` reads it from standard input, so nothing is left on the host),
// or the user saves it and runs it by hand. It is idempotent and reports
// only unless asked to apply; steps that need root are listed first and run
// only with `--root`, through the user's own `sudo` in a terminal. Every
// line it prints on standard output starts with `YCODE-` (`HostSetupOutput`
// reads them). The KVM SVE probe is our own C program, written from the
// mechanism in `docs/postmortem-kvm-sve.md` §5: it never builds or installs
// a kernel.

import Foundation

public enum HostSetupScript {
    /// The file name when saved.
    public static let fileName = "ycode-host-setup"

    /// The script (bash).
    public static var text: String { script.replacingOccurrences(of: "@PROBE_SOURCE@", with: probeSource) }

    static let script = #"""
#!/usr/bin/env bash
# ycode-host-setup: prepares a Linux machine to run Ycode's simulator.
#
#   ycode-host-setup [--report | --apply | --root] [options]
#
#   --report   (the default) look only: nothing on the machine changes
#   --apply    run the steps that need no root, as you
#   --root     run the steps that need root; run it as: sudo bash ycode-host-setup --root …
#
#   --data-dir DIR      Ycode's data folder ($YCODE_DATA): runtimes, devices, run files
#   --config-dir DIR    where simhost.env goes (default ~/.config/ycode of the user, also under sudo)
#   --swift VERSION     the Swift toolchain Ycode needs (default 6.4); --apply installs it with swiftly
#   --ycode-version V   the Ycode release to install the simulator service from (aarch64 tarball)
#   --release-base URL  where that release's files are (default: its GitHub release)
#   --sim-tree DIR      a built simulator tree to use instead (YCODE_SIM_TREE)
#   --runtime-root DIR  the RuntimeRoot the service boots (default: the newest iOS one in DIR/runtimes)
#   --min-free-gb N     free space the data folder needs (default 40: about 16 GB per runtime, plus devices)
#   --tcp-port N, --udp-port N   the link's ports (default 47800 and 47801)
#   --probe-seconds N   how long the KVM SVE probe runs (default 3); --no-probe skips it
#
# A second run after the steps were applied only reports. Every line on
# standard output starts with YCODE- (Ycode's setup wizard reads them):
# FACT key=value, ROOT id command, USER id command, CHECK id state reason,
# SVE key=value…, RAN id status, DONE pass|fail.

set -u
mode=report; data=""; conf=""; conf_default=1
swiftver=6.4; minfree=40; probe_s=3; probe=1; tcp=47800; udp=47801
ycodever=""; relbase=""; simtree=""; rtroot=""
while [ $# -gt 0 ]; do
    case "$1" in
    --report) mode=report ;;
    --apply) mode=apply ;;
    --root) mode=root ;;
    --data-dir) data=${2:-}; shift ;;
    --config-dir) conf=${2:-}; conf_default=0; shift ;;
    --swift) swiftver=${2:-}; shift ;;
    --min-free-gb) minfree=${2:-}; shift ;;
    --probe-seconds) probe_s=${2:-}; shift ;;
    --no-probe) probe=0 ;;
    --tcp-port) tcp=${2:-}; shift ;;
    --udp-port) udp=${2:-}; shift ;;
    --ycode-version) ycodever=${2:-}; shift ;;
    --release-base) relbase=${2:-}; shift ;;
    --sim-tree) simtree=${2:-}; shift ;;
    --runtime-root) rtroot=${2:-}; shift ;;
    *) echo "YCODE-ERROR unknown option $1"; exit 64 ;;
    esac
    shift
done

# The user the setup is for (under sudo: the one who ran sudo), and their
# home: the defaults and ~ come from it, not from root's.
user=${SUDO_USER:-$(id -un)}
uhome=$(getent passwd "$user" 2>/dev/null | cut -d: -f6); uhome=${uhome:-$HOME}
if [ -z "$conf" ]; then
    if [ -n "${SUDO_USER:-}" ]; then conf="$uhome/.config/ycode"; else conf="${XDG_CONFIG_HOME:-$uhome/.config}/ycode"; fi
fi
for v in data conf simtree rtroot; do
    eval "x=\$$v"
    case "$x" in "~/"*) eval "$v=\$uhome/\${x#\\~/}" ;; esac
done
[ -n "$relbase" ] || relbase="https://github.com/MarcoDotIO/Ycode/releases/download/v$ycodever"

if [ "$mode" = root ] && [ "$(id -u)" != 0 ]; then
    echo "YCODE-ERROR --root needs root: run it with sudo in a terminal"; exit 77
fi
if [ "$mode" = apply ] && [ "$(id -u)" = 0 ]; then
    echo "YCODE-ERROR --apply runs as your own user, not as root"; exit 77
fi

facts=(); roots=(); rootcmds=(); users=(); usercmds=(); checks=(); ran=(); failed=0
fact()  { facts+=("$1=$2"); }
check() { checks+=("$1 $2 $3"); [ "$2" = missing ] && failed=1; return 0; }
rootstep() { roots+=("$1 $2"); rootcmds+=("$2"); }
userstep() { users+=("$1 $2"); usercmds+=("$2"); }
have() { command -v "$1" >/dev/null 2>&1; }
q() { printf '%q' "$1"; }

# The Swift toolchain from swiftly, as the user's shells have it (again after
# an apply, which may have installed it).
load_swiftly() {
    for f in "${SWIFTLY_HOME_DIR:-/nonexistent}/env.sh" "$uhome/.local/share/swiftly/env.sh"; do
        # shellcheck disable=SC1090
        [ -f "$f" ] && . "$f" >/dev/null 2>&1 && break
    done
    hash -r
}

# Who listens on a port: "user (program)" as far as ss can tell. $1 is t or u.
port_owner() {
    local line uid who proc pid
    line=$(ss -Hln"$1"ep "sport = :$2" 2>/dev/null | head -1)
    [ -n "$line" ] || return 1
    uid=$(printf '%s' "$line" | grep -o 'uid:[0-9]*' | head -1 | cut -d: -f2)
    proc=$(printf '%s' "$line" | grep -o 'users:(("[^"]*"' | head -1 | cut -d'"' -f2)
    # ss prints no uid for UDP sockets: the owner of the process then.
    if [ -z "$uid" ]; then
        pid=$(printf '%s' "$line" | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)
        [ -n "$pid" ] && uid=$(stat -c %u "/proc/$pid" 2>/dev/null)
    fi
    who=""; [ -n "$uid" ] && who=$(getent passwd "$uid" | cut -d: -f1)
    printf '%s' "${who:-another user}${proc:+ ($proc)}"
}

# The Ycode release a program lives in, read without running it (the
# release's tools are built for the Flatpak runtime and may not start on the
# host): manifest.json's "version" at the release's top, else the top
# folder's name, Ycode-<version>-<arch>.
release_version() {
    local real top v=""
    real=$(readlink -f "$1" 2>/dev/null) || return 1
    case "$real" in */bin/*) top=${real%/bin/*} ;; *) return 1 ;; esac
    [ -f "$top/manifest.json" ] && v=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$top/manifest.json" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    [ -n "$v" ] || v=$(basename "$top" | sed -nE 's/^Ycode-(.*)-(aarch64|x86_64)$/\1/p')
    [ -n "$v" ] && printf '%s' "$v"
}

# A key's value in simhost.env (empty when unset).
envval() { [ -f "$envf" ] && sed -n "s/^$1=//p" "$envf" | tail -1 | sed "s/^[\"']//; s/[\"']\$//"; }

inspect() {
    facts=(); roots=(); rootcmds=(); users=(); usercmds=(); checks=(); failed=0
    load_swiftly
    # YCODE_SETUP_ARCH stands in for uname -m in tests.
    os=$(uname -s); arch=${YCODE_SETUP_ARCH:-$(uname -m)}
    fact os "$os"; fact arch "$arch"; fact kernel "$(uname -r)"; fact kernel_build "$(uname -v)"; fact user "$user"
    if [ "$os" != Linux ]; then
        check setup.os missing "This is $os; the simulator host is Linux."
        return
    fi
    distro=unknown; pm=""
    if [ -r /etc/os-release ]; then distro=$(. /etc/os-release; echo "${ID:-linux} ${VERSION_ID:-}"); fi
    for m in apt-get dnf zypper pacman; do have "$m" && { pm=$m; break; }; done
    fact distro "$distro"; fact package_manager "${pm:-none}"
    check setup.os ok "Linux ($distro)."

    case "$arch" in
    aarch64|arm64) check setup.arch ok "$arch: Ycode's simulator runs here." ;;
    *) check setup.arch missing "$arch: Ycode's simulator needs arm64 Linux. This machine can only be reported on." ;;
    esac

    # KVM: the device, your access, the group that owns it.
    if [ -c /dev/kvm ]; then
        group=$(stat -c %G /dev/kvm 2>/dev/null || echo kvm)
        fact kvm_group "$group"
        if [ "$mode" != root ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
            fact kvm access; check setup.kvm ok "/dev/kvm is open to $user."
        elif id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$group"; then
            if [ "$mode" = root ]; then fact kvm access
                check setup.kvm ok "$user is in the $group group."
            else fact kvm denied
                check setup.kvm missing "$user is in the $group group, but this login started before: log out and in again."
            fi
        else
            fact kvm denied
            rootstep kvm-group "usermod -aG $(q "$group") $(q "$user")"
            check setup.kvm missing "/dev/kvm belongs to the $group group; $user is not in it (log out and in after it is added)."
        fi
    else
        fact kvm absent
        check setup.kvm missing "No /dev/kvm: turn on virtualization in the firmware and load the kvm module. Ycode does not change the kernel."
    fi

    # Packages: the tools the simulator's build and runs use. A release's tree
    # (the aarch64 tarball, or --sim-tree naming one) brings its translator,
    # with its own LLVM, and libjpeg: building them needs LLVM 18 and
    # SPIRV-Tools, running them nothing more.
    release_tree=0
    if [ -n "$ycodever" ] && [ -z "$simtree" ]; then release_tree=1
    elif [ -n "$simtree" ] && [ -x "$simtree/airc/ycode-airc" ]; then release_tree=1; fi
    missing_tools=(); pkgs=()
    for pair in python3:python3 rsync:rsync flock:util-linux llvm-config-18:llvm-18-dev spirv-val:spirv-tools vulkaninfo:vulkan-tools; do
        t=${pair%%:*}; p=${pair#*:}
        have "$t" && continue
        [ "$t" = llvm-config-18 ] && [ -x /usr/lib/llvm-18/bin/llvm-config ] && continue
        [ "$release_tree" = 1 ] && { [ "$t" = llvm-config-18 ] || [ "$t" = spirv-val ]; } && continue
        missing_tools+=("$t"); pkgs+=("$p")
    done
    # The display server's JPEG frames (the viewers' default) need libjpeg at
    # run time; a source build loads the system's (a release carries its own).
    # ldconfig is in /sbin, which a non-login PATH may lack.
    ldc=ldconfig; have ldconfig || ldc=/sbin/ldconfig
    if [ "$release_tree" = 0 ] && ! { "$ldc" -p 2>/dev/null | grep -q 'libjpeg\.so\.\(8\|62\) '; }; then
        missing_tools+=("libjpeg"); pkgs+=("libjpeg-turbo8")
    fi
    if [ ${#missing_tools[@]} = 0 ]; then
        check setup.packages ok "python3, rsync, flock, LLVM 18, SPIRV-Tools, vulkaninfo and libjpeg are installed."
    elif [ "$pm" = apt-get ]; then
        rootstep packages "DEBIAN_FRONTEND=noninteractive apt-get install -y ${pkgs[*]}"
        check setup.packages missing "Missing: ${missing_tools[*]} (packages ${pkgs[*]})."
    else
        check setup.packages missing "Missing: ${missing_tools[*]}. Install them with ${pm:-the package manager}."
    fi

    # Swift (swiftly).
    sv=$(swift --version 2>/dev/null | grep -o 'Swift version [0-9][0-9.]*' | head -1)
    fact swift "${sv:-none}"
    # The install ends by checking the version it installed.
    verify="swift --version | grep -q $(q "Swift version $swiftver")"
    case "$sv" in
    "Swift version $swiftver"|"Swift version $swiftver."*) check setup.swift ok "$sv." ;;
    *)
        if have swiftly; then
            userstep swift "swiftly install --use $(q "$swiftver") && hash -r && $verify"
        else
            # swiftly from swift.org's official installer, into the user's home (no root).
            userstep swift 't=$(mktemp -d) && cd "$t" && curl -fsSL "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz" -o swiftly.tar.gz && tar -xzf swiftly.tar.gz && ./swiftly init --quiet-shell-followup --assume-yes --skip-install && . "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh" && hash -r && swiftly install --use '"$(q "$swiftver")"' && hash -r && '"$verify"'; rc=$?; cd /; rm -rf "$t"; exit $rc'
        fi
        check setup.swift missing "${sv:-No Swift}; Ycode needs Swift $swiftver. Apply installs it with swiftly from swift.org, in $user's home (no root)." ;;
    esac

    # The data folder.
    if [ -z "$data" ]; then
        check setup.data missing "Choose Ycode's data folder on a volume with ${minfree} GB free."
    else
        fact data_dir "$data"
        p=$data; while [ ! -e "$p" ] && [ "$p" != / ]; do p=$(dirname "$p"); done
        free_kb=$(df -Pk "$p" 2>/dev/null | awk 'NR==2 {print $4}'); free_kb=${free_kb:-0}
        fact data_free_kb "$free_kb"
        if [ ! -d "$data" ]; then
            if [ -w "$p" ]; then userstep data-dir "mkdir -p $(q "$data")"
            else rootstep data-dir "install -d -o $(q "$user") -g $(id -gn "$user" | xargs printf '%q') $(q "$data")"; fi
            check setup.data missing "$data does not exist yet."
        elif [ "$mode" != root ] && [ ! -w "$data" ]; then
            rootstep data-owner "chown $(q "$user") $(q "$data")"
            check setup.data missing "$data is not writable by $user."
        elif [ "$free_kb" -lt $((minfree * 1024 * 1024)) ]; then
            check setup.data missing "$data has $((free_kb / 1024 / 1024)) GB free; the check asks for ${minfree} GB: each runtime needs about 16 GB unpacked, plus its devices. With one runtime, pass --min-free-gb 20 (or what you need)."
        else
            check setup.data ok "$data, $((free_kb / 1024 / 1024)) GB free."
        fi
        sub_missing=""
        for s in runtimes devices run bin; do [ -d "$data/$s" ] || sub_missing="$sub_missing $s"; done
        if [ -n "$sub_missing" ]; then
            userstep data-folders "mkdir -p $(for s in $sub_missing; do printf '%q ' "$data/$s"; done)"
        fi
    fi

    # Ycode's simulator service: its program (from Ycode's own aarch64 release
    # unless one is here), its tree, its launcher, its configuration, its unit.
    envf="$conf/simhost.env"
    simhost=$(command -v ycode-simhost 2>/dev/null || true)
    [ -n "$data" ] && [ -x "$data/bin/ycode-simhost" ] && simhost="$data/bin/ycode-simhost"
    installed=""
    if [ -n "$data" ] && [ -e "$data/bin/ycode-simhost" ]; then installed=$(release_version "$data/bin/ycode-simhost"); fi
    # A source build has no release folder: ask its ycode.
    [ -z "$installed" ] && [ -n "$data" ] && [ -x "$data/bin/ycode" ] && installed=$("$data/bin/ycode" --version 2>/dev/null | grep -o '[0-9][0-9A-Za-z.+-]*' | head -1)
    fact ycode_installed "${installed:-none}"
    reldir=""; release=0
    case "$arch" in aarch64|arm64)
        if [ -n "$data" ] && [ -n "$ycodever" ] && [ -z "$simtree" ] && { [ -z "$simhost" ] || { [ "$simhost" = "$data/bin/ycode-simhost" ] && [ "$installed" != "$ycodever" ]; }; }; then
            top="Ycode-$ycodever-aarch64"; reldir="$data/ycode/$top"; release=1
            userstep release "t=$(q "$data/ycode/.download") && rm -rf \"\$t\" && mkdir -p \"\$t\" $(q "$data/bin") && curl -fsSL $(q "$relbase/$top.tar.xz") -o \"\$t/$top.tar.xz\" && curl -fsSL $(q "$relbase/SHA256SUMS.txt") -o \"\$t/SHA256SUMS.txt\" && (cd \"\$t\" && grep -E $(q "[[:space:]]\\*?$top\\.tar\\.xz\$") SHA256SUMS.txt | sha256sum -c -) && rm -rf $(q "$reldir") && tar -xJf \"\$t/$top.tar.xz\" -C $(q "$data/ycode") && ln -sfn $(q "$reldir/bin/ycode-simhost") $(q "$data/bin/ycode-simhost") && ln -sfn $(q "$reldir/bin/ycode") $(q "$data/bin/ycode"); rc=\$?; rm -rf \"\$t\"; exit \$rc"
            simhost="$data/bin/ycode-simhost"
        fi ;;
    esac
    # A tree named with --sim-tree carries its own ycode-simhost: a source
    # tree in .build/release, an unpacked release in ../../bin. Apply links it
    # into the data folder, where the service unit runs it.
    linked=""
    if [ -z "$simhost" ] && [ -n "$simtree" ]; then
        for c in "$simtree/.build/release/ycode-simhost" "$simtree/../../bin/ycode-simhost"; do
            [ -x "$c" ] || continue
            linked="$(cd "$(dirname "$c")" && pwd)/ycode-simhost"
            if [ -n "$data" ]; then
                userstep simhost-link "mkdir -p $(q "$data/bin") && ln -sfn $(q "$linked") $(q "$data/bin/ycode-simhost")"
                simhost="$data/bin/ycode-simhost"
            else simhost=$linked; linked=""; fi
            break
        done
    fi
    fact simhost "${simhost:-none}"
    if [ -n "$linked" ]; then
        check setup.simhost missing "The simulator tree's ycode-simhost ($linked) is not in $data/bin yet; Apply links it there."
    elif [ "$release" = 1 ]; then
        check setup.simhost missing "No ycode-simhost ${installed:+for $ycodever }here. Apply downloads Ycode $ycodever for aarch64 from its release, checks it against SHA256SUMS.txt and unpacks it in $data/ycode."
    elif [ -n "$simhost" ]; then
        check setup.simhost ok "$simhost${installed:+ (Ycode $installed)}."
    else
        check setup.simhost missing "ycode-simhost was not found. Name the Ycode version to install (--ycode-version), or build Ycode on the host (scripts/ycode-sim-serve build) and pass --sim-tree."
    fi
    # The simulator tree: given, configured, the release's, or next to ycode-simhost.
    tree=${simtree:-$(envval YCODE_SIM_TREE)}
    if [ -z "$tree" ] && [ -n "$reldir" ]; then tree="$reldir/lib/ycode-sim"; fi
    if [ -z "$tree" ] && [ -n "$simhost" ] && [ -e "$simhost" ]; then
        d=$(dirname "$(readlink -f "$simhost")")
        if [ -x "$d/ycode-simd" ] && [ "$(basename "$d")" = release ]; then tree=$(cd "$d/../.." && pwd)
        elif [ -d "$d/../lib/ycode-sim" ]; then tree=$(cd "$d/../lib/ycode-sim" && pwd); fi
    fi
    # The runtime: given, configured, else the newest iOS RuntimeRoot Ycode copied.
    rt=${rtroot:-$(envval YCODE_SIM_RUNTIME)}
    if [ -z "$rt" ] && [ -n "$data" ]; then
        rt=$(ls -d "$data"/runtimes/iOS-*/RuntimeRoot 2>/dev/null | grep -v '\.incoming/' | sort -V | tail -1)
    fi
    fact sim_tree "${tree:-none}"; fact runtime_root "${rt:-none}"
    # The launcher the service runs per device (YCODE_SIM_LAUNCHER's default).
    if [ -n "$data" ] && [ -n "$tree" ] && [ ! -e "$data/bin/ycode-sim" ]; then
        userstep launcher "mkdir -p $(q "$data/bin") && ln -sfn $(q "$tree/scripts/ycode-sim.sh") $(q "$data/bin/ycode-sim")"
    fi
    # simhost.env: every key the service needs; existing values are kept.
    if [ -n "$data" ]; then
        add=()
        [ -n "$(envval YCODE_SIM_HOME)" ] || add+=("YCODE_SIM_HOME=$data")
        [ -n "$(envval YCODE_SIM_TREE)" ] || [ -z "$tree" ] || add+=("YCODE_SIM_TREE=$tree")
        [ -n "$(envval YCODE_SIM_RUNTIME)" ] || [ -z "$rt" ] || add+=("YCODE_SIM_RUNTIME=$rt")
        [ -n "$(envval YCODE_SIMHOST_LISTEN)" ] || add+=("YCODE_SIMHOST_LISTEN=0.0.0.0:$tcp")
        [ -n "$(envval YCODE_SIMHOST_MEDIA_PORT)" ] || add+=("YCODE_SIMHOST_MEDIA_PORT=$udp")
        if [ ${#add[@]} -gt 0 ]; then
            userstep service-config "mkdir -p $(q "$conf") && printf '%s\\n' $(for a in "${add[@]}"; do printf '%q ' "$a"; done)>> $(q "$envf")"
        fi
        lack=""
        [ -n "$(envval YCODE_SIM_TREE)$tree" ] || lack="$lack YCODE_SIM_TREE (install ycode-simhost first)"
        [ -n "$(envval YCODE_SIM_RUNTIME)$rt" ] || lack="$lack YCODE_SIM_RUNTIME (no runtime on the host yet: copy one with the wizard's Add a Runtime, then Apply again)"
        if [ -n "$lack" ]; then check setup.service missing "$envf needs:$lack."
        elif [ ${#add[@]} -gt 0 ]; then check setup.service missing "$envf lacks ${#add[@]} key(s); Apply adds them."
        else check setup.service ok "$envf names the home, tree, runtime and ports."; fi
    else
        check setup.service missing "Needs the data folder first."
    fi
    if [ "$conf_default" = 1 ]; then unitdir="$uhome/.config/systemd/user"; else unitdir="$conf/systemd/user"; fi
    unit="$unitdir/ycode-simhost.service"
    if [ ! -f "$unit" ] && [ -n "$data" ]; then
        userstep service-unit "mkdir -p $(q "$unitdir") && printf '%s\n' '[Unit]' 'Description=Ycode simulator host' '[Service]' $(q "ExecStart=${simhost:-$data/bin/ycode-simhost} serve --config $envf") 'Restart=on-failure' '[Install]' 'WantedBy=default.target' > $(q "$unit")"
    fi
    fact service_unit "$unit"

    # The self-test: the service itself reads the configuration (it boots nothing).
    if [ -n "$simhost" ] && [ -x "$simhost" ] && [ -f "$envf" ]; then
        own=0
        if have ss && [ "$(port_owner t "$tcp")" = "$user (ycode-simhost)" ]; then own=1; fi
        out=$("$simhost" check --config "$envf" 2>&1); rc=$?
        # The running service holds its own ports: check's bind test is not a problem then.
        if [ "$rc" != 0 ] && [ "$own" = 1 ] && ! printf '%s\n' "$out" | grep -v 'in use by another program' | grep -q '[^[:space:]]'; then
            check setup.selftest ok "ycode-simhost check: the service runs with $envf (it holds $tcp/tcp and $udp/udp)."
        elif [ "$rc" = 0 ]; then
            check setup.selftest ok "ycode-simhost check: the service can start with $envf."
        elif printf '%s' "$out" | grep -q "unknown command check"; then
            # An older ycode-simhost (before 1.0.0-beta.2) has no check: look at the files it needs here.
            gone=""
            t=$(envval YCODE_SIM_TREE); r=$(envval YCODE_SIM_RUNTIME); h=$(envval YCODE_SIM_HOME)
            [ -x "$t/.build/release/ycode-simd" ] || gone="$gone ycode-simd in YCODE_SIM_TREE,"
            [ -e "$t/SimShim/out/shim.bin" ] || gone="$gone the shim in YCODE_SIM_TREE,"
            [ -e "$r/sbin/launchd_sim" ] || gone="$gone launchd_sim in YCODE_SIM_RUNTIME,"
            [ -x "${h:-/nonexistent}/bin/ycode-sim" ] || gone="$gone the launcher \$YCODE_SIM_HOME/bin/ycode-sim,"
            if [ -n "$gone" ]; then
                check setup.selftest missing "This ycode-simhost${installed:+ (Ycode $installed)} predates ycode-simhost check, and the files the service needs are not all there:${gone%,}."
            else
                check setup.selftest unknown "This ycode-simhost${installed:+ (Ycode $installed)} predates ycode-simhost check (it came with 1.0.0-beta.2), so the script checked $envf's keys and files itself."
            fi
        else
            check setup.selftest missing "ycode-simhost check: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
        fi
    else
        check setup.selftest unknown "The service is checked once ycode-simhost and $envf are in place."
    fi

    # Ports and the firewall.
    if have ss; then
        busy=""
        for pp in "t $tcp tcp" "u $udp udp"; do
            set -- $pp
            if o=$(port_owner "$1" "$2"); then
                case "$o" in "$user (ycode-simhost)") ;; *) busy="$busy $2/$3 by $o," ;; esac
            fi
        done
        if [ -n "$busy" ]; then
            fact listening yes
            check setup.ports missing "In use:${busy%,}. Choose free ports with --tcp-port N --udp-port M (the wizard's Ports field)."
        else
            fact listening no
            check setup.ports ok "$tcp/tcp and $udp/udp are free (or Ycode's own service holds them)."
        fi
    else
        check setup.ports unknown "ss is not installed, so the ports could not be checked."
    fi
    if have ufw && grep -qs '^ENABLED=yes' /etc/ufw/ufw.conf; then
        if [ "$mode" = root ]; then
            if ufw status 2>/dev/null | grep -q "^$tcp/tcp" && ufw status 2>/dev/null | grep -q "^$udp/udp"; then
                check setup.firewall ok "ufw allows $tcp/tcp and $udp/udp."
            else
                rootstep firewall "ufw allow $tcp/tcp && ufw allow $udp/udp"
                check setup.firewall missing "ufw does not allow $tcp/tcp and $udp/udp yet."
            fi
        else
            rootstep firewall "ufw status | grep -q '^$tcp/tcp' && ufw status | grep -q '^$udp/udp' || { ufw allow $tcp/tcp && ufw allow $udp/udp; }"
            check setup.firewall unknown "ufw is on; its rules can be read only as root. The root step allows $tcp/tcp and $udp/udp if they are not yet."
        fi
    elif have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        if firewall-cmd --query-port="$tcp/tcp" >/dev/null 2>&1 && firewall-cmd --query-port="$udp/udp" >/dev/null 2>&1; then
            check setup.firewall ok "firewalld allows $tcp/tcp and $udp/udp."
        else
            rootstep firewall "firewall-cmd --permanent --add-port=$tcp/tcp --add-port=$udp/udp && firewall-cmd --reload"
            check setup.firewall missing "firewalld does not allow $tcp/tcp and $udp/udp."
        fi
    else
        check setup.firewall ok "No ufw or firewalld is on; nothing to open for $tcp/tcp and $udp/udp."
    fi
}

# The KVM SVE probe (docs/postmortem-kvm-sve.md): facts only; the wizard decides.
sve_probe() {
    local arch sve cc dir out
    arch=$(uname -m)
    if [ "$(uname -s)" != Linux ]; then echo "YCODE-SVE arch=$arch sve=no kvm=absent error=not-linux"; return; fi
    if grep -qw sve /proc/cpuinfo 2>/dev/null; then sve=yes; else sve=no; fi
    local kvm=absent; [ -c /dev/kvm ] && { kvm=denied; [ -r /dev/kvm ] && [ -w /dev/kvm ] && kvm=access; }
    local head="arch=$arch sve=$sve kvm=$kvm kernel=$(uname -r)"
    case "$arch" in aarch64|arm64) ;; *) echo "YCODE-SVE $head error=not-arm64"; return ;; esac
    [ "$sve" = yes ] || { echo "YCODE-SVE $head error=no-sve"; return; }
    [ "$kvm" = access ] || { echo "YCODE-SVE $head error=no-kvm-access"; return; }
    [ "$probe" = 1 ] || { echo "YCODE-SVE $head error=skipped"; return; }
    cc=""; for c in cc clang gcc; do have "$c" && { cc=$c; break; }; done
    [ -n "$cc" ] || { echo "YCODE-SVE $head error=no-compiler"; return; }
    dir=$(mktemp -d) || { echo "YCODE-SVE $head error=no-tempdir"; return; }
    cat > "$dir/probe.c" <<'YCODE_PROBE_EOF'
@PROBE_SOURCE@
YCODE_PROBE_EOF
    if ! "$cc" -O2 -pthread -o "$dir/probe" "$dir/probe.c" >"$dir/cc.log" 2>&1; then
        echo "YCODE-SVE $head error=compile-failed"; rm -rf "$dir"; return
    fi
    out=$(timeout $((probe_s + 20)) "$dir/probe" "$probe_s" 2>/dev/null | tail -1)
    rm -rf "$dir"
    echo "YCODE-SVE $head ${out:-error=probe-failed}"
}

inspect
case "$mode" in
apply)
    for i in "${!usercmds[@]}"; do
        id=${users[$i]%% *}
        if bash -c "${usercmds[$i]}"; then ran+=("$id ok"); else ran+=("$id failed"); fi
    done
    inspect ;;
root)
    for i in "${!rootcmds[@]}"; do
        id=${roots[$i]%% *}
        if bash -c "${rootcmds[$i]}"; then ran+=("$id ok"); else ran+=("$id failed"); fi
    done
    inspect ;;
esac

echo "YCODE-SETUP mode=$mode version=1"
for f in "${facts[@]}"; do echo "YCODE-FACT $f"; done
for r in "${ran[@]+"${ran[@]}"}"; do echo "YCODE-RAN $r"; done
for r in "${roots[@]+"${roots[@]}"}"; do echo "YCODE-ROOT $r"; done
for u in "${users[@]+"${users[@]}"}"; do echo "YCODE-USER $u"; done
for c in "${checks[@]}"; do echo "YCODE-CHECK $c"; done
[ "$mode" = root ] || sve_probe
if [ "$failed" = 0 ]; then echo "YCODE-DONE pass"; else echo "YCODE-DONE fail"; fi
exit 0
"""#

    /// The probe, in C (arm64 Linux): VMM-style threads run a guest that
    /// never touches FP/SIMD (it only writes to an unmapped address, a KVM
    /// MMIO exit), set the SVE predicate p0 after each `KVM_RUN` returns,
    /// spin without system calls (a preemption may come), then count p0's
    /// active lanes. A kernel without the fix loses the predicates at a
    /// preemption; a fixed one never does. Prints one line:
    /// `runs=N lost=M threads=T seconds=S vl=B`, or `error=…`.
    public static let probeSource = #"""
/* ycode-kvm-sve-probe: Ycode's own test, after docs/postmortem-kvm-sve.md §5. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <linux/kvm.h>
#if !defined(__aarch64__)
int main(void) { puts("error=not-arm64"); return 3; }
#else
#include <sys/auxv.h>
#ifndef HWCAP_SVE
#define HWCAP_SVE (1UL << 22)
#endif
#define CODE_GPA 0x10000ULL
#define MMIO_GPA 0x9000000ULL
#define CORE(off) (KVM_REG_ARM64 | KVM_REG_SIZE_U64 | KVM_REG_ARM_CORE | ((off) / sizeof(__u32)))

static volatile int stop;
static int kvm_fd, run_size, spin = 20000;
static unsigned long long total_runs, total_lost, total_other;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static const char *failure;

static inline void set_p0(void) { __asm__ volatile(".arch_extension sve\n\tptrue p0.b\n" ::: "memory"); }
static inline unsigned long active_p0(void) {
    unsigned long n;
    __asm__ volatile(".arch_extension sve\n\tptrue p1.b\n\tcntp %0, p1, p0.b\n" : "=r"(n) :: "memory");
    return n;
}
static inline unsigned long vector_bytes(void) {
    unsigned long n;
    __asm__ volatile(".arch_extension sve\n\tcntb %0\n" : "=r"(n));
    return n;
}

static int set_reg(int vcpu, __u64 id, __u64 value) {
    struct kvm_one_reg r = { .id = id, .addr = (__u64)(uintptr_t)&value };
    return ioctl(vcpu, KVM_SET_ONE_REG, &r);
}

static void fail(const char *why) {
    pthread_mutex_lock(&lock);
    if (!failure) failure = why;
    pthread_mutex_unlock(&lock);
}

static void *worker(void *arg) {
    (void)arg;
    int vm = ioctl(kvm_fd, KVM_CREATE_VM, 0);
    if (vm < 0) { fail("create-vm"); return NULL; }
    /* str x1, [x0]; b .-4  (no FP/SIMD in the guest) */
    uint32_t *mem = mmap(NULL, 0x10000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mem == MAP_FAILED) { fail("mmap"); close(vm); return NULL; }
    mem[0] = 0xf9000001; mem[1] = 0x17ffffff;
    struct kvm_userspace_memory_region region = { .slot = 0, .guest_phys_addr = CODE_GPA, .memory_size = 0x10000,
                                                  .userspace_addr = (__u64)(uintptr_t)mem };
    int vcpu = -1;
    struct kvm_run *run = MAP_FAILED;
    struct kvm_vcpu_init init;
    memset(&init, 0, sizeof init);
    if (ioctl(vm, KVM_SET_USER_MEMORY_REGION, &region) < 0) { fail("memory-region"); goto out; }
    vcpu = ioctl(vm, KVM_CREATE_VCPU, 0);
    if (vcpu < 0) { fail("create-vcpu"); goto out; }
    run = mmap(NULL, run_size, PROT_READ | PROT_WRITE, MAP_SHARED, vcpu, 0);
    if (run == MAP_FAILED) { fail("map-run"); goto out; }
    if (ioctl(vm, KVM_ARM_PREFERRED_TARGET, &init) < 0 || ioctl(vcpu, KVM_ARM_VCPU_INIT, &init) < 0) { fail("vcpu-init"); goto out; }
    if (set_reg(vcpu, CORE(offsetof(struct kvm_regs, regs.pc)), CODE_GPA) < 0
        || set_reg(vcpu, CORE(offsetof(struct kvm_regs, regs.regs[0])), MMIO_GPA) < 0
        || set_reg(vcpu, CORE(offsetof(struct kvm_regs, regs.regs[1])), 1) < 0) { fail("set-regs"); goto out; }
    unsigned long want = vector_bytes();
    unsigned long long runs = 0, lost = 0, other = 0;
    while (!stop) {
        if (ioctl(vcpu, KVM_RUN, 0) < 0) {
            if (errno == EINTR) continue;
            fail("kvm-run");
            break;
        }
        if (run->exit_reason != KVM_EXIT_MMIO) other++;
        /* No system call from here to the check: a preemption may come. */
        set_p0();
        for (volatile int i = 0; i < spin; i++) {}
        if (active_p0() != want) lost++;
        runs++;
    }
    pthread_mutex_lock(&lock);
    total_runs += runs; total_lost += lost; total_other += other;
    pthread_mutex_unlock(&lock);
out:
    if (run != MAP_FAILED) munmap(run, run_size);
    if (vcpu >= 0) close(vcpu);
    munmap(mem, 0x10000);
    close(vm);
    return NULL;
}

int main(int argc, char **argv) {
    int seconds = argc > 1 ? atoi(argv[1]) : 3;
    if (seconds < 1) seconds = 1;
    if (!(getauxval(AT_HWCAP) & HWCAP_SVE)) { puts("error=no-sve"); return 3; }
    kvm_fd = open("/dev/kvm", O_RDWR | O_CLOEXEC);
    if (kvm_fd < 0) { printf("error=kvm-open-%d\n", errno); return 2; }
    run_size = ioctl(kvm_fd, KVM_GET_VCPU_MMAP_SIZE, 0);
    if (run_size <= 0) { puts("error=mmap-size"); return 2; }
    long cpus = sysconf(_SC_NPROCESSORS_ONLN);
    int threads = (int)(cpus > 0 ? cpus * 4 : 8);
    if (threads > 64) threads = 64;
    pthread_t t[64];
    int started = 0;
    for (int i = 0; i < threads; i++) if (pthread_create(&t[i], NULL, worker, NULL) == 0) started++;
    sleep(seconds);
    stop = 1;
    for (int i = 0; i < started; i++) pthread_join(t[i], NULL);
    if (failure && total_runs == 0) { printf("error=%s\n", failure); return 2; }
    printf("runs=%llu lost=%llu threads=%d seconds=%d vl=%lu other_exits=%llu\n", total_runs, total_lost, started, seconds, vector_bytes(), total_other);
    return 0;
}
#endif
"""#
}
