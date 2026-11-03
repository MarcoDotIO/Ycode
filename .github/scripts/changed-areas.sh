#!/bin/sh
# Decides which CI jobs a change needs, so that a change to the documentation
# does not run hours of tests. Prints key=value lines for $GITHUB_OUTPUT.
# Usage: changed-areas.sh <base-sha> <head-sha>
# With no usable base (a new branch, a manual run), everything runs.
set -eu
BASE="${1:-}"
HEAD="${2:-HEAD}"

everything() {
    echo "ycode=true"
    echo "frameworks=true"
    echo "lint=true"
    exit 0
}

case "$BASE" in
    "" | *[!0]*) ;;
    *) everything ;;
esac
[ -n "$BASE" ] || everything
FILES="$(git diff --name-only --no-renames "$BASE" "$HEAD" 2>/dev/null)" || everything

# The CI's own files affect every job.
if printf '%s\n' "$FILES" | grep -Eq '^(\.github/(workflows/ci\.yml|scripts/|ci/known-flaky\.txt|actions/))'; then
    everything
fi

# Prose inside the code folders changes no build.
CODE="$(printf '%s\n' "$FILES" | grep -Ev '\.md$' || true)"
area() { printf '%s\n' "$CODE" | grep -Eq "$1" && echo true || echo false; }

# ycode/ uses frameworks/swiftui by path.
echo "ycode=$(area '^(ycode/|frameworks/swiftui/)')"
echo "frameworks=$(area '^(frameworks/|composer/)')"
echo "lint=$(area '^(ycode/|frameworks/|composer/|\.swiftlint\.yml$)')"
