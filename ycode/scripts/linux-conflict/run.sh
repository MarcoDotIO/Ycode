#!/bin/sh
# The Linux IDE's merge workflow and merge sheet end to end
# (specs/ide/merge-sheet.md; issue #75): makes the Merger repository
# (make-conflict.sh), runs ycode-ide on it with YCODE_IDE_CONFLICT
# (ShellDriver+Conflicts.swift), which starts the merge of "feature" from
# its branch row's menu and the alert, resolves Colors.swift through the
# tokens' Choose menus and Greeting.swift by hand, clicks Merge (the merge
# commit), then cherry-picks "pick" through the sheet and cancels a rebase
# of "topic" from it (Abort); then checks the repository with git.
#
#     WAYLAND_DISPLAY=… XDG_RUNTIME_DIR=… run.sh <ycode-ide> <work folder> <shots prefix>
#
# OV_COLOR_SCHEME=dark runs it in the dark appearance. Exit 0 when every
# check passes.
set -u
IDE=$1; WORK=$2; SHOTS=$3
HERE=$(cd "$(dirname "$0")" && pwd)
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
mkdir -p "$WORK" "$(dirname "$SHOTS")"
P=$("$HERE/make-conflict.sh" "$WORK")
export XDG_CONFIG_HOME="$WORK/config" XDG_DATA_HOME="$WORK/data"
LOG="$WORK/conflict-walk.log"
YCODE_IDE_CONFLICT="$SHOTS" OV_QUIT_AFTER=${OV_QUIT_AFTER:-150} timeout 240 "$IDE" "$P" > "$LOG" 2>&1
echo "ide exit $?"
grep -E '^(conflict|backend|window)' "$LOG"

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2], want [$3]"; fail=1; fi; }
g() { git -C "$P" "$@"; }
MERGE=$(g log --merges --format=%H -n 1)
check "a merge commit of feature" "$(g rev-list --parents -n 1 "$MERGE" | wc -w | tr -d ' ')" "3"
check "Colors.swift: Left then Right" "$(g show "$MERGE:Sources/Merger/Colors.swift" | grep -E 'background|accent' | tr -s ' ' | tr '\n' '|')" \
  ' static let background = "snow"| static let accent = "teal"|'
check "Greeting.swift: written by hand" "$(g show "$MERGE:Sources/Merger/Greeting.swift" | sed -n 3p | tr -s ' ')" ' "Greetings, \(name)!"'
check "the pick: Right (crimson)" "$(g show HEAD:Sources/Merger/Colors.swift | grep accent | tr -s ' ')" ' static let accent = "crimson"'
check "the pick is HEAD's subject" "$(g log -1 --format=%s)" "Pick: crimson accent"
check "no operation in progress" "$(ls "$P/.git" | grep -E '^(MERGE_HEAD|CHERRY_PICK_HEAD|rebase-merge|rebase-apply)$' | wc -l | tr -d ' ')" "0"
check "the rebase was aborted (topic unchanged)" "$(g log -1 --format=%s topic)" "Topic: a formal greeting"
check "back on main" "$(g branch --show-current)" "main"
check "no conflicted files" "$(g diff --name-only --diff-filter=U | wc -l | tr -d ' ')" "0"
exit $fail
