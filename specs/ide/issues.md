# Issues: the live project warning, the issue capsule and the jump-bar stepper

**Status:** boundary spec for B5-ISSUES (inventory row P-120). It records what the
reference, Xcode 27.1, shows for a project that has never been built: the live
"Update to recommended settings" warning, where it appears (toolbar capsule, issue
navigator, jump-bar stepper) and the checklist sheet it opens. Prose, tables and
measured numbers only: no code, no copied resources. UI labels are quoted
exactly; build-setting names are interop identifiers.

Related: `specs/ide/navigators.md` (Issue navigator), `specs/ide/reference-ui-6.md`
§5.1 (issue grouping: file-less project issues directly under the project row),
`specs/ide/reference-ui-5.md` §11.6, `fidelity-council.md` rows 138, 139, 161, 188
and 216 (capsule and stepper geometry), `specs/build-settings.md`.

**Capture conditions.** b5-obs capture of 2026-11-20: a **1x** display at
**100 Hz**, the workspace window 1400 × 880 pt, key and in front, dark then light,
host load 7–12. A fresh copy of the Parity test project (one app target, one test
target, an asset catalog and a String Catalog), **never built**, opened and left
20 s. Sizes ±1 pt, timings ±20 ms.

## 1. When the warning appears

1. On an **unbuilt** project the warning is live: within 20 s of opening, with no
   build, the issue capsule, the issue navigator and the jump-bar stepper show
   one warning.
2. It is a project-level warning: it has no file and no line.
3. After a build it stays and is listed with the build's issues (2026-11-15: a
   build reported "Update to recommended settings" under the project, beside the
   build's own error and warnings).
4. It is offered when the project's settings differ from the recommended set
   (§4). What clears it (Perform Changes, then a re-check) was **not exercised**.
5. **Which projects are checked: the project's `LastUpgradeCheck`.** The
   `PBXProject` attribute `LastUpgradeCheck` (the IDE version as four digits,
   `specs/ide/templates.md`) gates the check. Evidence: the projects that showed
   the warning (parity 2026-11-15; b5-obs 2026-11-20, item 5) had
   `LastUpgradeCheck = 2700` and were opened in 27.1, while a project created
   from the reference's own templates carries the running IDE's version (`2710`)
   and shows no warning, although those templates leave keys such as
   `DEAD_CODE_STRIPPING` unset. So the rule is: the warning is offered only when
   `LastUpgradeCheck` is missing or lower than the running IDE's version, and
   then only for the §5 rows that apply. A template project never warns, and
   the templates must not add settings to avoid it. This is an inference from
   level 2 (the file format) and level 3 (the two observed cases); the exact
   comparison (equal versus greater) and whether Cancel or Perform Changes
   writes the new version are OPEN. Ycode's choice: Perform Changes writes the
   running version into `LastUpgradeCheck` along with the checked rows, and
   Cancel writes nothing (the warning stays until the next open).

## 2. The toolbar issue capsule

| Property | Value |
|---|---|
| Content | a yellow warning triangle and the count **"1"** ("⚠ 1") |
| Place | right after the scheme › destination capsule (7.5–8 pt gap), before the next group; accessibility item 65 × 52 at window x 807 |
| Shape | a glass capsule 36 tall, ≈ 61 wide for one warning (council row 161); errors come first (red circle, white cross), then warnings, a pair 24.5 pt apart |
| Hover | a 53 × 28 bezel, dark #424242 → #565656, light #FAF9F9 → #EFEEEF, one frame (`specs/ui/control-states.md` §2) |
| Narrow window | its count goes at 1200 pt (light 1175), the capsule moves into » at 1000 (`window-layout.md` §2) |
| No issues | not shown |

Ycode shows the capsule only when a build has issues; with this warning it must
show it on an unbuilt project too (P-120). Its absence today shifts the toolbar's
centre group by ≈ 34 pt.

## 3. The issue navigator (⌘5)

```
Parity  1 issue                       ← project glyph, name, count in secondary text
  ⚠  Update to recommended settings   ← yellow triangle; exact text
```

- One row group, the project (project glyph, "**Parity**", then "**1 issue**" in
  grey), with the warning as its direct child: "**Update to recommended
  settings**". Rows 22 pt tall.
- No file group: the warning is file-less (`reference-ui-6.md` §5.1).
- Clicking the row opens the project editor and the checklist sheet (§5).

## 4. The jump-bar issue stepper

| Element | Value |
|---|---|
| Place | the right end of the jump bar, every editor's jump bar, also with "No Selection" (council row 161); window x 1082–1128 here |
| ‹ | "Show Previous Issue", 14 × 28, a chevron |
| centre | a menu button (accessibility "Issues", 20 × 30) showing the most severe kind's symbol: the yellow triangle |
| › | "Show Next Issue", 14 × 28 |
| Chevron colour | #7F7F7F (light, council row 161) |
| Action | › selected the warning: the project editor opened (as a click on the navigator row, without the sheet) |

## 5. The checklist sheet

Clicking the warning in the issue navigator opens the **project editor**
(PROJECT / TARGETS list, Info tab) and, over it, a sheet:

| Property | Value |
|---|---|
| Size and place | **581 × 364**, centred in the window both ways (window (410, 258)); the window dimmed (`specs/ide/popovers.md` §7) |
| Body | a bordered, scrolling list 522 pt wide with a vertical scroller; each row a **checkbox** column (≈ 40 pt) and a text column |
| Row kinds | a **group heading** (bold, 18 tall, with its own checkbox; its effect on the group's rows was not exercised); a **change** (bold title, then a grey explanation; 30 tall for one line of explanation, 44 for two, taller for a list) |
| Buttons | **Cancel** (84 × 23) and **Perform Changes** (130 × 23, the default button, blue), right-aligned, 12 pt apart, 20 pt from the sheet's right edge and 17 pt from its bottom |
| Escape / Return | Cancel / Perform Changes as the default button (not exercised) |
| Cancel | closes the sheet; nothing is applied |

Rows for this project, in order (titles exactly as shown, including the mixed
hyphen and em-dash separators):

| Group | Change | Checked | Explanation |
|---|---|---|---|
| **Asset Catalog** | — | no | — |
| | Enable Generated Asset Symbol Extensions | no | "Generate asset symbol extensions on Apple framework color and image types." |
| **Build Settings** | — | yes | — |
| | Target 'Parity' - Enable Weak References in Manual Retain Release | yes | "Enabling weak references in manual retain release is recommended. This will set the CLANG_ENABLE_OBJC_WEAK setting to "YES" for the "Debug" configuration." |
| | Target 'Parity' - Enable Weak References in Manual Retain Release | yes | the same for the "Release" configuration |
| | Target 'Parity' — Enable Dead Code Stripping | yes | "Enabling dead code stripping is recommended. This will update the DEAD_CODE_STRIPPING build setting." |
| | Target 'ParityTests' - Enable Weak References in Manual Retain Release | yes | as above, "Debug" |
| | Target 'ParityTests' - Enable Weak References in Manual Retain Release | yes | as above, "Release" |
| | Target 'ParityTests' — Enable Dead Code Stripping | yes | as above |
| | Project 'Parity' - Enable Recommended Warnings | yes | "This will enable the following recommended compiler warnings:" then a bulleted list (first items "Block Capture of Autoreleasing", "Duplicate Method Definitions"…; the row is ≈ 408 pt tall) |
| | Project 'Parity' — Enable Dead Code Stripping | yes | as above |
| | Enable User Script Sandboxing | yes | "Enabling user script sandboxing is recommended to ensure correctness of the build. This will enable the ENABLE_USER_SCRIPT_SANDBOXING …" (the rest not recorded) |
| **Localization** | — | yes | — |
| | Project 'Parity' — Enable String Catalog Symbol Generation | yes | "Generate Swift code to access manually-added strings in your String Catalogs." |

Pattern: one row per setting **per target and per configuration** where it
differs, then project-level rows; a title names its scope ("Target '<name>'",
"Project '<name>'") or none for a workspace-wide change; an explanation names
the build setting it changes.

## 6. What Ycode builds (P-120)

1. A project check that runs when a workspace opens (no build needed) and after
   each build, comparing the project's settings with Ycode's recommended set,
   and reporting one project-level warning, "Update to recommended settings",
   when anything differs. The set itself is build-system work: start from the
   settings named in §5, specified in `specs/build-settings.md`.
2. The warning drives the toolbar capsule (§2), the issue navigator's project row
   (§3) and the jump-bar stepper (§4) exactly as a build warning does.
3. Clicking it opens the project editor and the checklist sheet (§5), listing
   only the differing settings, grouped, all checked except those the reference
   leaves unchecked (the asset-symbol extensions row). Perform Changes writes the
   checked settings through the pbxproj writer (`specs/formats/pbxproj.md`) and
   re-runs the check; Cancel changes nothing.
4. Texts name the build settings, never the reference product (the owner's
   rule; compare the Signing text, P-096).
5. Both IDEs: the Linux IDE shows the same warning, capsule, stepper and sheet
   (OpenViews sheet, P-215).

## 7. OPEN

1. The full list in the Enable Recommended Warnings row and the end of the User
   Script Sandboxing explanation.
2. What Perform Changes writes, and whether the warning goes immediately or
   after the next build.
3. Whether the stepper's › also opens the sheet when the warning is the only
   issue (here it opened the project editor only).
4. The same check on a Swift package and on a workspace with several projects.

## 8. Ycode's choices for the OPEN items (B5-ISSUES, 2026-11-20)

The conservative answers Ycode builds until an observation settles them.
Code: `YcodeProject/RecommendedSettings.swift` (the check and Perform
Changes), `YcodeIDECore` `RecommendedSettingsChecklist` (the sheet's state and
measures, shared by both IDEs).

1. **The recommended set** is the §5 rows and nothing more:

   | Row | Read from | Offered when | Perform Changes writes |
   |---|---|---|---|
   | Enable Generated Asset Symbol Extensions (unchecked) | the project's configurations | the project has an asset catalog (a file reference or one inside a synchronized folder) and `ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS` is not `YES` | `= YES` in those project configurations |
   | Target '<t>' - Enable Weak References… (one per configuration) | the target's configuration, else the project's configuration of the same name | `CLANG_ENABLE_OBJC_WEAK` is not `YES` | `= YES` in that target configuration |
   | Target '<t>' — Enable Dead Code Stripping | as above | `DEAD_CODE_STRIPPING` is not `YES` in any of the target's configurations | `= YES` in those target configurations |
   | Project '<p>' - Enable Recommended Warnings | the project's configurations | one of the warning settings below is not set | each missing one, at the value below, in those project configurations |
   | Project '<p>' — Enable Dead Code Stripping | the project's configurations | `DEAD_CODE_STRIPPING` is not `YES` | `= YES` there |
   | Enable User Script Sandboxing | the project's configurations | `ENABLE_USER_SCRIPT_SANDBOXING` is not `YES` | `= YES` there |
   | Project '<p>' — Enable String Catalog Symbol Generation | the project's configurations | the project has a String Catalog and `STRING_CATALOG_GENERATE_SYMBOLS` is not `YES` | `= YES` there |

   Only native targets have target rows. A value starting with `YES` counts as
   set, so `YES_ERROR` and `YES_AGGRESSIVE` are never weakened. A setting a
   configuration leaves to its `.xcconfig` base configuration is not judged.
2. **The recommended warnings** (§7 item 1) are the warning settings every new
   project gets (`templates.md`, "Project-level settings in every template"):
   the 22 `CLANG_WARN_*` and 6 `GCC_WARN_*` settings, written at the template's
   values (`YES`, or `YES_ERROR` / `YES_AGGRESSIVE` where the template has
   them). The list shows only the missing ones, by their build settings'
   public titles, "Block Capture of Autoreleasing" and "Duplicate Method
   Definitions" first as observed, then in the settings' order. All 28 missing
   make the row 2 + 14 × 30 = 422 pt tall, close to the observed ≈ 408.
3. **The sandboxing explanation** ends "…ENABLE_USER_SCRIPT_SANDBOXING build
   setting." (§7 item 1).
4. **Perform Changes** (§7 item 2) writes only the checked rows' keys in the
   configurations that lack them and the running version into
   `LastUpgradeCheck` (item 8), through the pbxproj writer, and re-runs the
   check at once: the warning goes. Nothing else in the file changes
   (round-trip tests compare the bytes).
5. **The stepper** (§7 item 3): with no issue in a file to go to, › and ‹ open
   the project editor without the sheet, as observed. Linux has no project
   editor yet: there the stepper selects the warning's row only.
6. **Packages and several projects** (§7 item 4): a package has no check; in a
   workspace each project is checked and the warning (one row, deduplicated by
   text) opens the first project that needs the update.
7. **The group checkbox** shows on, off or mixed for its rows; clicking it
   turns them all on, or all off when all are on.
8. **The gate** (§1 item 5; B5-FOLLOWUP, 2026-11-21): a project is checked
   only when its `LastUpgradeCheck` is missing or lower than Ycode's IDE
   version (`2710`, the four digits the templates write); then the rows of
   item 1 that apply are offered. Every project Ycode creates (each New
   Project template, the untitled App, the iOS App generator, the older
   macOS App and Command Line Tool) records that version and raises no
   warning; the templates add no setting to avoid it (they match
   `templates.md`). Perform Changes writes the running version into
   `LastUpgradeCheck` with the checked rows (so rows left unchecked are not
   offered again by this version); Cancel, or Perform Changes with nothing
   checked, writes nothing. A version equal to or newer than Ycode's is not
   checked.

## Evidence

| Claim | Level | Source |
|---|---|---|
| §1–§5 | 3 | b5-obs 2026-11-20, item 5: stills, recordings and accessibility trees of the unbuilt project (capsule, its hover, ⌘5, the jump bar, ›, the row clicked, the sheet, Cancel), dark and light |
| §1 item 3 | 3 | parity 2026-11-15, item B-S-042 (inventory P-120) |
| §2, §4 geometry | 3 | `fidelity-council.md` rows 138, 139, 161, 188 |
| Build-setting names | 2 | interop identifiers as they appear in project files (`specs/build-settings.md`) |
| §6 | — | Ycode's design under the owner's rules |
| §8 | 1 (templates.md, public build-setting titles), — | Ycode's conservative choices |

Nothing here rests on levels 4 or 5.
