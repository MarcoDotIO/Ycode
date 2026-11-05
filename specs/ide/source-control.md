# Source control (git)

Ycode module: `YcodeUI` (`GitRepository` and its history extension,
`CommitController`, `CommitEditorController`, `BranchHistoryController`,
`SourceControlCoordinator`, Source Control navigator, project-navigator
badges). Everything goes through the
`git` command-line tool; no git library is linked.

## Repository

The repository is the one containing the opened container
(`git -C <dir> rev-parse --show-toplevel`). Every later command runs as
`git -C <top level> …` with `GIT_TERMINAL_PROMPT=0`, `GIT_PAGER=cat` and
`GIT_EDITOR=true`, so git never prompts, pages or opens an editor, and no
command touches another repository. Network commands run only from the
Integrate menu: `fetch --all --prune`, `pull --ff-only`, `push` (to the
configured upstream); with `GIT_TERMINAL_PROMPT=0` a remote that needs
credentials fails instead of prompting.

## Reading

| View | Command |
|---|---|
| Branches (current marked) | `for-each-ref --format=%(HEAD)%09%(refname:short) refs/heads` |
| Tags | same on `refs/tags` |
| Remote branches | same on `refs/remotes`, without `*/HEAD` |
| Remotes | `remote -v` (first URL per name) |
| File status | `status --porcelain=v1 -z --untracked-files=all` |

Porcelain status → badge: `??` → `?`; `U` in either column, `AA`, `DD` →
`C`; `R…` → `R` (the next entry is the original path); `A…` → `A`; `D` in
either column → `D`; anything else → `M`.

## Source Control navigator (⌘2)

Layout and labels follow `reference-ui-4.md` §2. A segmented control
switches **Changes | Repositories**.

- Changes: "<repository>  <branch>" (branch from
  `symbolic-ref --short HEAD`), then "Uncommitted Changes" with the count,
  one row per change (name without extension, boxed letter).
- Repositories: Branches, Recents, Tags, Stashes, Remotes. A `/` in a
  name makes folders per component. Recents: up to five existing branches
  named in HEAD's reflog `checkout: moving from A to B` entries, newest
  first, without the current branch. Stashes: `stash list --format=%gd: %gs`.

## Reading history

| View | Command |
|---|---|
| History | `log --format=%H%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%G?%x1f%s%x1f%b%x1e -n 500 <ref> --` (decorations give branch and `tag:` badges) |
| Commit files | `diff-tree --no-commit-id --name-status -r --root -M <hash>` |
| Branches with a commit | `branch --format=%(refname:short) --contains <hash>` |
| Branch remote | `config branch.<name>.remote`; upstream `rev-parse --abbrev-ref <name>@{upstream}` |
| Author | `config user.name`, `config user.email` |

Verification is "Commit verified" for `%G?` = `G`, else "Commit
unverified". Relative day: "Today", "Yesterday", else `MMM d, yyyy`;
detail date `MMM d, yyyy 'at' h:mm a`. Time scopes: All, last 24 hours,
7 days, 30 days (from now); the filter matches subject, message, author or
a hash prefix, case-insensitively.

## Commit editor

Selecting a change (or the repository row in Changes) shows the commit
editor over the editor area; opening a file hides it. Cards per change
with the diff for the scope: All Changes `diff HEAD` (`diff --cached`
before the first commit), Unstaged `diff`, Staged `diff --cached`, each
`--no-color --no-ext-diff -U3 -- <path>`; an untracked file is shown as
one all-added hunk and only outside the Staged scope. Stage All is
`add -A`. Discard: a tracked file returns to HEAD
(`checkout HEAD -- <path>`); a file only in the index is unstaged
(`rm --cached`) and moved to the Trash; an untracked file is moved to the
Trash. Nothing is deleted outright. Commit: when nothing is staged, every
change is staged first; then `commit -q -m <message>` (plus `--amend`
with the Amend switch, which pre-fills HEAD's message into an empty
field). The Commit menu also offers Commit and Push.

## Integrate menu enablement

| Item | Enabled when |
|---|---|
| Commit…, Stash Changes…, Discard All Changes… | a repository with changes |
| Push…, Pull…, Fetch Changes | a repository with a remote |
| Stage All / Unstage All Changes | unstaged / staged changes exist |
| Stage / Unstage Changes in Selected Files | the selected file is changed and tracked / has staged changes |
| Mark Selected Files as Resolved | the selected file is conflicted (`add`) |
| Add Selected Files | the selected file is untracked |
| Cherry-Pick… | a commit is selected in branch history |
| Move Selected Files to Trash… | the selected file exists |
| Clone… | always (`clone -- <url> <folder>`) |
| New Git Repository… | no repository (`init` in the workspace's folder) |
| Create Workflow…, Manage Workflows… | never (no cloud CI service) |

"Selected file": the Changes row while the Source Control navigator is
shown, else the project navigator's selection, else the open file.

## Project navigator badges

Files show their status letter at the right edge of the row. Correction
(2026-10-19): group, folder and project rows show no letter
(`reference-ui-5.md` §5.1; Ycode formerly showed `M` on them). Badges refresh when
the window opens, after Save, after a commit, and with Integrate ▸ Refresh
File Status.

## Commit (Integrate ▸ Commit…, ⌥⌘C)

A sheet lists changed files (checkbox, status letter, path relative to the
repository), a message field, Cancel and Commit Files. Commit saves the
editor, then for the selected files only: `git add -- <files>` and
`git commit -m <message> -- <files>`. An empty message or no selected file
is refused before git runs; a path outside the repository is refused.

## Evidence

- Source Control navigator, badges (M/A/?), the commit sheet and its
  shortcut: Apple's public Xcode Help ("Source control management") and
  shortcut reference (level 1).
- git command and porcelain formats: git's public documentation (level 1);
  verified on a repository created by the test (level 3).
- Navigator groups, commit editor, history and inspector labels:
  `reference-ui-4.md` (level 3).
- OPEN QUESTION: Xcode's exact badge letters for renamed/conflicted files;
  what "Recents" lists exactly (Ycode uses the reflog); per-hunk staging;
  the Commit button menu's items; Push/Pull option sheets (remote and
  branch choice).

## Ycode implementation: branch workflows (SCM-BRANCHES, 2026-10-31)

Gap #13 of `docs/PARITY.md`. Ycode's design unless an evidence line says
otherwise; everything is in the portable core (`YcodeIDECore/SourceControl/`)
except the AppKit views, so the Linux shell can use the same models.

### Operations (`GitRepository+Branches.swift`, `+Integration.swift`)

All through `git -C <top level>` with the environment above, plus
`GIT_SEQUENCE_EDITOR=true`. Names are checked first (`check-ref-format
--branch <name>`, `check-ref-format refs/tags/<name>`; a leading `-` is
refused) and always follow `--` or the option that takes them.

| Operation | Command |
|---|---|
| New branch (and check out) | `branch --no-track -- <name> [<start>]` (`switch --no-track -c <name> [<start>]`) |
| Rename | `branch -m -- <old> <new>` (the current branch too) |
| Delete | `branch -d -- <name>`; unmerged: a second confirmation, then `-D`; the current branch is refused |
| Check out a local branch | `switch -- <name>` |
| Check out a remote branch | `switch -c <name> --track <remote>/<name>` (or `switch` to an existing local branch of that name) |
| Check out a commit | `switch --detach <hash>` |
| Merge | `merge --no-edit` with `--ff`, `--ff-only` or `--no-ff`, `[-m <message>] <rev>` |
| Rebase | `rebase <rev>` |
| Cherry-pick, revert | `cherry-pick <rev>`, `revert --no-edit <rev>` |
| Continue | merge: `commit --no-edit`; rebase: `rebase --continue`; pick: `cherry-pick --continue` (`--skip` when the resolution leaves nothing to commit); revert: `revert --continue` |
| Abort | `merge --abort`, `rebase --abort`, `cherry-pick --abort`, `revert --abort` |
| Stash apply, pop, drop | `stash apply <stash@{n}>`, `stash pop <stash@{n}>`, `stash drop -q <stash@{n}>`; files: `diff --name-status -M <ref>^1 <ref>` |
| Tags | `tag -- <name> <rev>` (lightweight), `tag -a -m <message> -- <name> <rev>`, `tag -d -- <name>`; list `for-each-ref refs/tags` with `%(objecttype)`, `%(*objectname)`, `%(contents:subject)` |
| Remotes | `remote add -- <name> <url>`, `remote remove -- <name>`, `fetch --prune -- <remote>` |
| Pull | fetch, then a fast-forward-only merge, a merge or a rebase of `<remote>/<branch>` |
| Push | `push [--set-upstream] [--force-with-lease] -- <remote> refs/heads/<b>:refs/heads/<b>`; a tag `refs/tags/<t>`; delete `:refs/heads/<b>` |
| Ahead / behind | `rev-list --left-right --count refs/heads/<b>...<upstream>` |

**Uncommitted changes when switching.** Three choices: refuse (tracked
changes exist), carry them (`git switch`, which itself refuses when a
change would be overwritten), or stash first (`stash push
--include-untracked -m "Before switching to <b>"`; the stash stays in
Stashes). The window asks "Stash and Check Out / Keep Changes / Cancel"
when tracked files changed. A working copy with conflicts never switches.

**Results.** Integrating commands return up to date, fast-forwarded,
completed (the new HEAD) or conflicts (the files `diff --name-only
--diff-filter=U` lists). A non-zero status without conflicts is an error
with git's message.

**What is in progress.** Read from git's state files in `rev-parse
--absolute-git-dir`: `rebase-merge/` or `rebase-apply/` (`head-name`,
`onto`, `msgnum`/`end` or `next`/`last`) → rebasing; `MERGE_HEAD` →
merging, named from `MERGE_MSG`'s quoted name; `CHERRY_PICK_HEAD`,
`REVERT_HEAD`. The snapshot carries it; the Changes header reads
"main (Merging “feature”)", "(Rebasing “b” onto 1a2b3c4, 1 of 3)".

### Conflicts (`GitRepository+Conflicts.swift`)

A conflicted file's versions are its index stages: `ls-files -u -z`, then
`show :1:<path>` (base), `:2:` (ours), `:3:` (theirs). A missing stage is
an empty side ("(deleted)" in its label). Without stages, the conflict
markers in the working file are parsed (`ConflictMarkers`). Labels: merge
— ours is the current branch, theirs the merged name; rebase — ours is the
commit rebased onto (short hash), theirs the branch being replayed;
cherry-pick — the picked short hash; a stash apply — "Stashed changes".
Resolving writes the result (refused while it has markers) and runs
`add`; resolving a delete moves the file to the Trash and runs `rm
--cached`. The editor itself is in `comparison.md` ("Ycode implementation").

### Source Control navigator menus (`SourceControlRowMenu`)

Rows carry keys; groups get `group:Branches|Tags|Remotes`, remotes
`remote:<name>`. Context menus (curly quotes around names):

| Row | Items |
|---|---|
| Repository | New Branch…, New Tag… — Add Remote… |
| Branches / Tags / Remotes group | New Branch… / New Tag… / Add Remote… |
| Branch (not current) | Check Out “b”… — New Branch from “b”…, New Tag from “b”… — Merge “b” into “current”…, Rebase “current” onto “b”… — Push “b”… (with a remote) — Rename…, Delete… |
| Current branch | New Branch from…, New Tag from… — Push “b”…, Pull… (with a remote) — Rename…, Delete… (disabled) |
| Remote branch | Check Out “b”… — New Branch from “r/b”… — Merge…, Rebase… — Delete “b” from “r”… |
| Tag | New Branch from “t”…, Push “t”… (with a remote) — Delete… |
| Stash | Apply Stashed Changes, Apply and Delete Stash — Delete… |
| Remote | Fetch “r” — Remove “r”… |
| Conflicted change | Resolve Conflicts…, Mark as Resolved |

Check out, merge, rebase and the stash items are disabled while an
operation is stopped. Selecting a conflicted change opens the conflict
editor instead of the commit editor. A conflicting merge, rebase,
cherry-pick, pull or stash apply opens it on the first conflicted file;
one that completes closes it.

### Integrate menu additions

After Stash Changes…, shown only while an operation is stopped or files
have conflicts (`MenuCondition.integrationInProgress`): **Resolve
Conflicts…** (enabled with conflicts), **Continue <Merge|Rebase|Cherry-Pick|Revert>**
(enabled once none remain), **Abort <…>** (asks first). Their generic
titles are "Continue" and "Abort". Cherry-Pick… now opens the conflict
editor when the pick conflicts.

### Blame (`GitBlame.swift`)

`blame --porcelain [--contents <temporary copy of the editor's text>] --
<path>` (git-blame's documented porcelain format). Lines that differ from
HEAD come back with the all-zero id: "Not Committed Yet". Consecutive
lines of one commit form a block.

- **Editor ▸ Authors (⌃⇧⌘A)** and the Adjust Editor Options item toggle,
  per editor, a 170-pt column at the gutter's far left (before the change
  column): at each block's first line "Author  Today|Yesterday|MMM d, yyyy";
  every other block shaded; hovering shows "<short hash> — Author <email>",
  the date ("MMM d, yyyy at h:mm a") and the summary. It re-reads on open,
  save and after an edit's pause. A click shows that line's last change.
- **Editor ▸ Show Last Change for Line**: the history of the commit that
  last changed the caret's line, with that commit selected (and its
  inspector); a beep for an uncommitted line.

### Tests

`YcodeIDECoreTests/SourceControlBranchesTests.swift` and
`ThreeWayMergeTests.swift` (every operation on repositories in temporary
folders, a bare repository there as the only remote, a conflicting merge,
rebase and cherry-pick resolved through the model);
`YcodeUITests/SourceControlBranchWorkflowTests.swift` (navigator menus,
the conflict editor through Continue Merge, Abort Rebase from Integrate,
Compare Files, Authors and Show Last Change).

### Evidence

- Commands, porcelain formats, state files and conflict stages: git's
  public documentation (`git-merge`, `git-rebase`, `git-cherry-pick`,
  `git-stash`, `git-blame`, `git-ls-files`, `gitrepository-layout`;
  level 1), verified on repositories the tests create (level 3).
- That Xcode offers branch creation, merge, rebase, stash, tags and an
  Authors view: Apple's public Xcode Help (level 1). Menu titles, the
  switch prompt and the Authors column's look are Ycode's design.
- OPEN QUESTION: the reference's branch, tag, stash and remote context
  menu titles and order; the merge sheet (Xcode Help describes choosing
  "Merge into" / "Merge from"); whether the reference rebases from the
  navigator; the Authors column's width, format and hover card.

## Ycode implementation: the Linux IDE (B2-SCM, 2026-11-04)

The SwiftUI shell (`YcodeIDEShell/SourceControlShellModel.swift`,
`SourceControlRows.swift`; views in `ycode-ide/SourceControlNavigator.swift`
and `SourceControlEditor.swift`) shows the core's models; it runs no git
of its own beyond `GitRepository`'s operations, always off the main actor,
one command after another, then reads `SourceControlSnapshot` again. In
the Flatpak `git` is the host-tool wrapper (`HostTool.path("git")`).

- **Navigator (⌘2):** Changes | Repositories as in the AppKit navigator;
  rows carry the same keys, so `SourceControlRowMenu` gives the context
  menus; a change row adds Stage or Unstage, Discard Changes… and Show in
  Editor. A merge, rebase or cherry-pick that stopped shows a banner with
  Continue and Abort. Outside git: "No Repository" and New Git Repository….
- **Commit editor** over the editor area: author, Amend, Commit with
  Commit and Push in its menu; the message; the scope and Stage All; one
  card per change (Stage or Unstage, discard, status letter, numbered diff
  with bars). The inspector shows the selected change and the repository.
- **Commit sheet** (Integrate ▸ Commit…, ⌥⌘C): checked files, message,
  Commit Files (`commit(files:message:)`).
- **Questions:** Check Out (with Stash and Check Out when tracked files
  changed), Delete, Merge, Rebase, Discard; prompts for New Branch (checked
  out), New Tag (optional message), Rename, Add Remote, Stash Changes.
- **Push and Pull:** to the upstream; without one, Push sets it on the
  branch's remote (else `origin`, else the first remote) and Pull
  fast-forwards from that remote's branch of the same name. The
  remote-and-branch sheet is still to do.
- **History:** a branch's, tag's, remote branch's or stash's log with the
  time scope and filter; a commit's detail below (files, message), and the
  Branch and Commit sections in the inspector. The History inspector tab
  lists the open file's commits (`history(ofFile:)`).
- **Status:** letters in the project navigator; change bars in the gutter
  (`SourceChanges.regions` against the index and HEAD, recomputed a moment
  after typing); the branch in the debug bar. The repository is watched
  (`FileSystemWatcher`, inotify on Linux) for outside changes.
- **Integrate menu:** the shell performs Commit…, Push…, Pull…, Fetch,
  Refresh File Status, Stage/Unstage All and Selected, Mark as Resolved,
  Add, Cherry-Pick…, Stash Changes…, Discard All / Selected… and New Git
  Repository…, enabled by `IntegrateMenuState`.
- Paths: a workspace opened through a link is mapped to git's real paths
  and back (`repoPath`, `workspacePath`).
- **Conflict editor** (B3-CONFLICT, 2026-11-05, #75) over the editor
  area, as `comparison.md` describes the AppKit one: both IDEs draw the
  core's `ConflictEditorState` (`YcodeIDECore/SourceControl/`: the files
  and the shown one, its `MergeDocument`, the selected change, the
  compared pair, hand editing, every title, count and enablement);
  `YcodeIDEShell/ConflictEditorShellModel.swift` reads and writes git off
  the main actor, `SourceControlShellModel+Conflicts.swift` opens and
  closes it, and `ycode-ide/ConflictEditorView.swift` draws it: the top
  row, the hunk bar (choices and pairs as capsule segments sized to their
  titles), the two versions side by side with line numbers, "Edited
  Change" while a change is written by hand, and the result, tinted per
  change; clicking a result line selects its change. A conflicting merge,
  rebase, cherry-pick, pull or stash apply opens it on the first
  conflicted file (instead of a notice); one that completes, or an abort,
  closes it. Selecting a conflicted change, its Resolve Conflicts… and
  Integrate ▸ Resolve Conflicts… open it; Integrate's Mark Selected Files
  as Resolved writes its result there. Integrate shows Resolve
  Conflicts…, Continue <operation> and Abort <operation> only while an
  operation is stopped or files conflict (`MenuConditions`). Abort, from
  the editor, the banner or the menu, asks "Abort the <operation>?"
  first.

Tests: `YcodeIDEShellTests/SourceControlShellTests.swift` (repositories with
a repository-local `user.name` and `user.email` and a bare repository as the
remote: both trees, the commit editor, scopes, staging, amend, the sheet,
discard, branches, checkout with stash, merge, delete, history, push, pull,
Commit and Push, change bars, file history, the Integrate menu outside
git); `ConflictEditorShellTests.swift` (a merge resolved by sides and by
hand, then continued; markers refused; the row and Integrate items; a
rebase aborted after the question; a cherry-pick continued) and
`YcodeIDECoreTests/ConflictEditorStateTests.swift`. End to end on Linux:
`ycode-ide` with `YCODE_IDE_SCM=<prefix>` (`ShellDriver+SourceControl.swift`)
and `scripts/linux-conflict/run.sh` (`YCODE_IDE_CONFLICT`,
`ShellDriver+Conflicts.swift`: the Merger repository's merge resolved
through the pointer, one file by choosing sides and one by typing, the
merge continued, a cherry-pick continued and a rebase aborted, then
checked with git).

### Evidence

- git commands and formats: git's public documentation (level 1),
  verified on repositories the tests create (level 3).
- Layout and labels: `reference-ui-4.md` §2–§3 (level 3) through the AppKit
  IDE's implementation. The change-row menu items, the banner, the
  questions' wording and the push and pull fallbacks are Ycode's design.
- The conflict editor: Ycode's design (`comparison.md`, "Ycode
  implementation", and its open question on the reference's layout).
