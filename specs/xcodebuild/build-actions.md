# xcodebuild: build actions and the build log

Ycode: `YcodeXcodebuild` (`BuildActions`, `BuildLog`), helper
`ycode-swb build`. Grammar: `cli.md`. Targets, configuration and
parameters: `show-build-settings.md` §2 and §4 (the same plan is built).

## 1. Actions

| Action | Banner word | ycodebuild |
|---|---|---|
| `build` | `BUILD` | swift-build, build command `build` |
| `analyze` | `ANALYZE` | swift-build, action `analyze` |
| `build-for-testing` | `TEST BUILD` | swift-build, scheme testing entries plus testables; writes the `.xctestrun` file (`test-actions.md` §4) |
| `install` | `INSTALL` | swift-build, action `install` (products under `DSTROOT`) |
| `clean` | `CLEAN` | swift-build, build command "clean build folder" |
| `test`, `test-without-building` | `TEST`, `TEST EXECUTE` | build for testing (`test`), then the platform's test runner (`test-actions.md`) |
| `archive` | `ARCHIVE` | swift-build, action `archive`, then the `.xcarchive` bundle (`archive.md`) |
| `docbuild` | `BUILD DOCUMENTATION` | swift-build, action `docbuild`: the build system compiles each module's documentation with the toolchain's open-source DocC into `<products>/<Module>.doccarchive` (§5) |
| `installsrc` | `INSTALLSRC` | not supported: exit 70 (`cli.md` §5) |

Several actions run in order (`clean build`); the first failure stops the
run. With a scheme, the run destination is chosen again for each action,
so the `Using the first of multiple matching destinations` warning is
printed once per action. `clean` removes the whole build folder: with a scheme,
`<DerivedData folder>/Build/Products` and `…/Build/Intermediates.noindex`;
without, the project's `build` directory. Its log is only the three
preparation lines and the banner.

Exit status: 0 when every action succeeded; 65 when one failed.

## 2. Log format (stdout)

After the invocation header, the command-line sections
(`show-build-settings.md` §1) and the package report:

    CreateBuildRequest
    <blank>
    SendProjectDescription
    <blank>
    CreateBuildOperation
    <blank>

(the reference tool prints its own preparation steps in this style; it
also prints `ComputePackagePrebuildTargetDependencyGraph` and `Prepare
packages`, which ycodebuild, resolving no packages, leaves out). Then, for
each swift-build message, in arrival order:

| Message | Printed |
|---|---|
| task started | `<ruleInfo>` + ` (in target '<target>' from project '<project>')` when the task belongs to a target; then the task's command display (already indented by 4 spaces: a `cd <dir>` line, the command, for some tasks extra lines such as `Using response file:` or the entitlements); the section stays open |
| task output | the text, as is |
| task finished | the open section is closed with one blank line (a section is also closed before the next task header) |
| diagnostic not tied to a task (global or target) | `[<path>[:<line>[:<column>]]: ]<kind>: <message>`, + the target suffix for target diagnostics; attached notes follow, each `    <message>` |
| diagnostic of a task | not printed separately (it is in the task's output), except diagnostics the build system reports itself (`appendToOutputStream` true, such as product validation warnings): printed in the task's section as `<kind>: <message>` + the target suffix |
| build finished | the open section is closed |

Then the banner `** <WORD> SUCCEEDED **` and a blank line, on stdout.

On failure, on **stderr**:

    ** <WORD> FAILED **
    <blank>
    <blank>
    The following build commands failed:
    \t<ruleInfo of each failed task, with target suffix>
    \tBuilding project <project> with scheme <scheme>
    (<n> failures)

where `n` counts the listed lines (the last line is
`Building project <project>` for a build without a scheme).

`-quiet` (and `-json`, which implies it): no header, no sections, no
success banner; task output is printed when its task fails or the output
contains `error:` or `warning:`; global and target warnings and errors are
printed; the failure banner and a blank line go to stderr without the
failed-command list.

Parallel tasks make the order of sections vary from run to run in both
tools; the multiset of lines is the comparable property.

**Target-level issues** (diagnostics located at a target, such as
`warning: Traditional headermap style is no longer supported; …`, with
the target suffix): for `archive` and `docbuild` they are printed after
the build's last section, just before the banner (and before the
result-bundle lines); for the other actions where they arrive, before the
target's first task section. Task-level issues stay in their task's
section.

## 3. The helper's build command

`ycode-swb build <request.json>` with
`{"pif", "parameters", "targets": [guid], "containerPath", "parallel",
"implicitDependencies", "hideShellScriptEnvironment", "continueAfterErrors",
"command": "build" | "cleanBuildFolder", "locationStyle": "regular" |
"legacy", "schemeCommand": "launch" | "test" | "archive", "debuggable"}` creates a swift-build build operation (configured targets with
the request's parameters; parallel and implicit-dependency flags from the
scheme's `BuildAction`, or `-parallelizeTargets`) and writes every
swift-build message as one JSON object per line on stdout. Exit status 0
when the build succeeded, 1 when it failed, 2 on an internal error (its
stderr is reported as an `xcodebuild: error:` line).

Message fields used (swift-build's message encoding): `kind`;
`targetStarted` {`id`, `name`, `projectName`}; `taskStarted` {`id`,
`targetID`, `ruleInfo`, `commandLineDisplayString`}; `taskOutput`
{`taskID`, `data`}; `output` {`data` base64, `locationContext`};
`taskComplete` {`id`, `result`}; diagnostics `error`/`warning`/`note`/
`remark` {`message`, `location` {`path`, `line`, `column`},
`locationContext` {`locationType`: `task`/`target`/`globalTask`,
`targetID`}, `childDiagnostics`}; `buildCompleted` {`result` "ok"}.
`taskDiagnostic` and `targetDiagnostic` repeat diagnostics and are ignored.

## 4. Signing

The helper answers swift-build's provisioning questions for local builds:
identity `-` ("Sign to Run Locally") signs ad hoc with the project's
entitlements plus `com.apple.security.get-task-allow`; the identity name it
reports, `Sign to Run Locally`, appears in the `CodeSign` section as in the
reference log; `archive` builds (`"debuggable": false`) leave the
debugging entitlement out, as in the reference tool's archived products;
products that take no entitlements (swift-build's `supportsEntitlements`
false: test bundles, libraries) get none, so no entitlements file is
written for them (the reference logs have no such tasks for test bundles).
Other identities fail with a message naming the gap
(provisioning profiles and certificates are not supported).

## 5. docbuild

The same build as `build` with swift-build's `docbuild` action (scheme
configuration of the launch action, `Debug` in autocreated schemes;
`-target` builds use the project's default configuration). The build
system adds symbol-graph and `CompileDocumentation` tasks; the archive is
`TARGET_BUILD_DIR/<PRODUCT_MODULE_NAME>.doccarchive` (scheme builds:
`<DerivedData folder>/Build/Products/<configuration>/`; `-target` builds:
`build/<configuration>/`). For package schemes ycodebuild builds the
products' package targets (`packages.md` §3). Banner `** BUILD
DOCUMENTATION SUCCEEDED **`.

## Evidence

- Banners, the preparation lines, section layout, target suffix, failure
  summary and its stdout/stderr split, quiet behavior, exit 65, what `clean`
  deletes (with and without a scheme): black-box `xcodebuild` 27.1 runs on
  hand-written tool and library projects, successful, failing and quiet
  (level 3). A normalized comparison of the tool project's build log
  (paths and hashes masked) left only the two package preparation lines,
  and a stat-cache file name, as differences.
- Message kinds and fields, build operation API, provisioning delegate
  protocol, clean-build-folder command: open-source swift-build (level 1).
- Target-level issue placement: black-box runs of every harness case.
  For `archive` and `docbuild` the reference prints them before the
  banner in every observed run (app and tool archives, archive with
  result bundle, library docbuild).
- OPEN QUESTION: for `build` and `test` the reference prints them either
  before the target's first task or at the end of the build, varying
  between cases of the same project (end of the build after a fresh
  description, it seems); ycodebuild prints them where they arrive.
- Test and archive logs: `test-actions.md`, `archive.md`; result bundles:
  `result-bundle.md`. The validation warning placement (inside the
  `Validate` section): black-box archive run (level 3); the
  `appendToOutputStream` flag: swift-build's diagnostic encoding (level 1).
- `docbuild`: black-box runs on a static library scheme of a project and
  on a package scheme; the archives' file trees are identical to the
  reference tool's (`conformance.md`) (level 3); the `docbuild` action
  and documentation tasks: open-source swift-build (level 1).
- OPEN QUESTION: for package schemes the reference tool extracts symbol
  graphs into `<target temp>/symbol-graph/…` and also lists the product
  target in its dependency graph; ycodebuild's build emits them from the
  compiler into `<products>/<arch>/<Module>.symbolgraphs` (same archive).
