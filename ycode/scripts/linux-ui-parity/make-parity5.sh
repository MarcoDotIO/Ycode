#!/bin/sh
# Writes the two copies of the "Merger" repository (scripts/linux-conflict/
# make-conflict.sh) that the cross-platform parity shots open on both IDEs
# (specs/ide/cross-platform-parity.md; CrossPlatformParityShotTests on
# macOS, YCODE_IDE_PARITY5 on Linux):
#
#   <folder>/rest/Merger    Sample.swift (declarations, comments, strings,
#                           numbers) and Stripes.png committed on main, then
#                           Sample.swift changed and Notes.swift added
#                           (the Changes view lists two files)
#   <folder>/merge/Merger   the same commits, clean (the merge alert and sheet)
#
#     make-parity5.sh <folder>
set -e
[ -n "$1" ] || { echo "usage: $0 <folder>" >&2; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
for KIND in rest merge; do
  mkdir -p "$1/$KIND"
  P=$("$HERE/../linux-conflict/make-conflict.sh" "$1/$KIND")
  {
    cat <<'SRC'
import Foundation

/// A greeting.
struct Greeting {
    static let defaultName = "World"
    let name: String
    var count = 7

    func describe() -> String {
        // A comment.
        "Hello, \(name)! \(count + 100)"
    }
}

enum Kind: Int { case plain, fancy }

func farewell(_ g: Greeting) -> String { "Bye, " + g.name }

SRC
    i=0
    while [ $i -lt 12 ]; do
      echo "// Section $i: a comment block that is long enough to wrap in a narrow editor width so that the wrapped-line indentation shows."
      printf 'struct Section%s {\n    let value: Int = %s\n    func describe() -> String {\n        return "\\(value)"\n    }\n}\n\n' $i $i
      i=$((i + 1))
    done
  } > "$P/Sources/Merger/Sample.swift"
  # An 80 x 180 PNG of four vertical stripes, written the same way on both machines.
  python3 -I - "$P/Sources/Merger/Stripes.png" <<'PY'
import struct, sys, zlib
w, h = 80, 180
colors = [(230, 60, 60), (60, 160, 230), (250, 200, 40), (40, 40, 40)]
row = b"".join(bytes(colors[x * 4 // w]) for x in range(w))
raw = b"".join(b"\x00" + row for _ in range(h))
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) \
    + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
PY
  git -C "$P" add Sources/Merger/Sample.swift Sources/Merger/Stripes.png
  git -C "$P" -c user.name=Parity -c user.email=parity@example.invalid commit -q -m "Sample files"
done
P="$1/rest/Merger"
sed 's/var count = 7/var count = 8/' "$P/Sources/Merger/Sample.swift" > "$P/Sources/Merger/Sample.swift.new"
mv "$P/Sources/Merger/Sample.swift.new" "$P/Sources/Merger/Sample.swift"
printf '// Notes for the next change.\nlet notes = ["one", "two"]\n' > "$P/Sources/Merger/Notes.swift"
echo "$1"
