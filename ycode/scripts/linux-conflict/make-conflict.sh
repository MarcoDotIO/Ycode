#!/bin/sh
# Writes the "Merger" package in a git repository whose branch "feature"
# conflicts with "main" in two files, for the Linux IDE's merge-sheet
# walk (YCODE_IDE_CONFLICT, ShellDriver+Conflicts.swift):
#
#   Sources/Merger/Colors.swift   two conflicts (resolved by choosing sides)
#   Sources/Merger/Greeting.swift one conflict (resolved by hand)
#
# and two more branches for the cherry-pick and rebase steps: "pick" (one
# commit that conflicts with main in Colors.swift) and "topic" (a commit
# that conflicts with main in Greeting.swift). main is checked out; no
# merge is started (the IDE starts it).
#
#     make-conflict.sh <folder>        # writes <folder>/Merger
set -e
[ -n "$1" ] || { echo "usage: $0 <folder>" >&2; exit 2; }
P="$1/Merger"
rm -rf "$P"
mkdir -p "$P/Sources/Merger"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
g() { git -C "$P" "$@"; }
cat > "$P/Package.swift" <<'PKG'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(name: "Merger", targets: [.executableTarget(name: "Merger")])
PKG
colors() {
cat > "$P/Sources/Merger/Colors.swift" <<SRC
/// The palette.
enum Palette {
    static let background = "$1"
    static let border = "gray"
    static let text = "black"
    static let link = "blue"
    static let visited = "purple"
    static let selection = "lightblue"
    static let shadow = "black"
    static let accent = "$2"
}
SRC
}
greeting() {
cat > "$P/Sources/Merger/Greeting.swift" <<SRC
/// What the program prints.
func greeting(for name: String) -> String {
    $1
}
SRC
}
# The IDE's language service builds the package: keep its output untracked.
printf '.build/\n.swiftpm/\n' > "$P/.gitignore"
cat > "$P/Sources/Merger/main.swift" <<'SRC'
print(greeting(for: "World"), Palette.accent)
SRC
colors white orange
greeting '"Hello, \(name)!"'
g init -q -b main
g config user.name "Conflict Tester"
g config user.email "conflict@ycode.invalid"
g config commit.gpgsign false
g add -A
g commit -q -m "First commit"

g switch -q -c feature
colors ivory teal
greeting '"Welcome, \(name)."'
g commit -q -am "Feature: new colors and greeting"

g switch -q main
colors snow purple
greeting '"Hi \(name)"'
g commit -q -am "Main: other colors and greeting"

g switch -q -c pick main
colors snow crimson
g commit -q -am "Pick: crimson accent"

g switch -q -c topic main~1
greeting '"Good day, \(name)!"'
g commit -q -am "Topic: a formal greeting"

g switch -q main
echo "$P"
