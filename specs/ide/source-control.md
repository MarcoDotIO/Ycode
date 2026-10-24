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
