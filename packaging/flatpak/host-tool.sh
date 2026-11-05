#!/bin/sh
# Installed as /app/libexec/ycode-host/host-tool, with a link for each tool
# (swift, git, ssh, ...) next to it. Runs the tool of that name on the host:
# Ycode's Flatpak has no toolchain of its own. A login shell finds tools the
# session's PATH lacks, and swiftly's folders are added for desktops whose login
# shell does not set them up.
tool=$(basename "$0")

# Runs on the host. $1 is the tool, the rest its arguments.
on_host='PATH="$HOME/.local/share/swiftly/bin:$HOME/.swiftly/bin:$PATH"
if ! command -v "$1" >/dev/null 2>&1; then
    case "$1" in
        swift*|sourcekit-lsp|lldb*|clang*)
            echo "Ycode: no Swift toolchain was found on this computer ($1 is missing)." >&2
            echo "The Ycode Flatpak builds with the Swift toolchain installed on the host. Install Swift 6 or newer from https://www.swift.org/install/linux/ and try again." >&2 ;;
        *)
            echo "Ycode: $1 was not found on this computer. Install it with your package manager and try again." >&2 ;;
    esac
    exit 127
fi
exec "$@"'

# Runs on the host first, under a plain sh: picks the login shell that runs
# $on_host. $1 is $on_host, then the tool and its arguments. The user's own shell
# reads their profile the way their session does. A POSIX sh stops at the first
# error in ~/.profile, and swiftly's installer adds a line there that sources a
# bash-only env.sh, so on Ubuntu (sh is dash) `sh -l` never gets to the tool; a
# profile that sh cannot read is skipped (swiftly's folders are added anyway).
pick_shell='script=$1; shift
shell=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f7)
case "$shell" in
    */bash|*/zsh|*/ksh|*/ksh93|*/mksh) [ -x "$shell" ] && exec "$shell" -lc "$script" ycode-host-tool "$@" ;;
esac
if /bin/sh -lc : </dev/null >/dev/null 2>&1; then
    exec /bin/sh -lc "$script" ycode-host-tool "$@"
fi
exec /bin/sh -c "$script" ycode-host-tool "$@"'

set -- /bin/sh -c "$pick_shell" ycode-host-tool "$on_host" "$tool" "$@"

# What a build needs from Ycode's environment (flatpak-spawn passes none by itself).
for name in $(env | sed -n 's/^\(YCODE_[A-Za-z0-9_]*\|SWIFT[A-Za-z0-9_]*\|NO_COLOR\|TERM\|CC\|CXX\|SSH_AUTH_SOCK\|GIT_[A-Za-z0-9_]*\)=.*/\1/p'); do
    # These name paths inside the sandbox, which the host does not have.
    case "$name" in YCODE|YCODE_SWB) continue ;; esac
    eval "value=\${$name}"
    set -- "--env=$name=$value" "$@"
done

if ! flatpak-spawn --host /bin/true 2>/dev/null; then
    echo "Ycode: cannot reach the host to run $tool. The Flatpak needs the permission --talk-name=org.freedesktop.Flatpak (flatpak override --user --talk-name=org.freedesktop.Flatpak io.github.MarcoDotIO.Ycode)." >&2
    exit 127
fi
exec flatpak-spawn --host --watch-bus --directory="$PWD" "$@"
