# B5-FIX-CI: three macOS UI tests that failed on the CI runner (1.0.0-beta.5)

Added 2026-11-24. The public CI's `ycode (macOS arm64)` job (a 3-core GitHub
macOS runner, debug build, `--no-parallel`, windows off screen) failed three
UI tests at the beta 5 content, twice in a row. All three passed on the
owner's Mac. Facts here come from Ycode's own code, the CI logs, and the
public runner-image scripts (`actions/runner-images`).

## 1. `B5FollowupUITests.selectingAnotherFileEasesTheEditor`

- **Cause: Reduce Motion is on in the runner image.** GitHub's macOS image
  build script (`images/macos/scripts/build/configure-system.sh`, "Disable
  graphic effects in System") writes `com.apple.universalaccess reduceMotion`
  and `reduceTransparency` true. The image was the same for beta 4's green
  run (`xcode-27-arm64` 20261104.0337.1); the test is new in beta 5. The
  ease is skipped with Reduce Motion (correctly: P-199 has no fade then), so
  `fileSelectionEase(to:in:)` returned nil on the runner and the open added
  no transition. Not a product bug.
- **Change.** `WorkspaceWindowController.fileSelectionEaseReducesMotion`
  (nil: the system setting) lets the test set Reduce Motion itself, as the
  build bezel's `bezelReduceMotionOverride` already does. The guard now
  goes through `fileSelectionEaseSkipReason(to:in:)` ("the editor shows no
  file", "… already", "Reduce Motion is on"). The test checks both settings
  (none with Reduce Motion, the fade without it) and prints the editor's
  file, the host's Reduce Motion, the override and the skip's reason with a
  failure.
- **Before/after (Mac):** passed before and after (Reduce Motion is off on
  the owner's Mac; its setting was not changed). On the runner it now does
  not depend on the host.

## 2. `B5NavigatorTests.openingASelectedFileIsQuick`

- **Cause: the runner lays out and draws slower.** CI measured small-file
  opens of 114, 117 and 146 ms against an absolute `< 100` (the Mac: about
  40). Beta 4's CI printed `R5 file switch ms: [132, 137, 122]` for a similar
  step and beta 5's `[135, 144, 158]`: no regression in the open, the limit
  did not fit that machine. The open's work is mostly layout and display,
  which the runner does about three times slower than the Mac, while
  pure-compute steps there are only 20–45 % slower (the synchronous syntax
  pass: 635 ms on CI against about 330–540 here).
- **Change: a calibrated machine factor.** `UIMachineFactor` (new, test
  helper) lays out and draws the test's own window in full (every view
  dirtied), takes the fastest of three passes, and divides by that pass on
  the owner's Mac (9.0 ms for this window, measured 2026-11-24). The limit
  is `100 ms × max(1, factor)`: the Mac keeps 100 ms (factor 1.03–1.10
  here), a slower machine gets a proportionally larger one. The test prints
  the redraw, the factor and the limit.
- **Before/after (Mac):** small opens `[47, 43, 41]`, `[39, 59, 39]`,
  `[54, 59, 39]` ms before (limit 100, under load from other jobs);
  `[39, 37, 39]`, `[39, 39, 42]`, `[38, 36, 38]` after, limits 103–109.

## 3. `CouncilRound6ChromeTests.inspectorSlideFramesAreCheapAndEndQuietly`

- **Cause: beta 5 added per-frame work to the inspector slide (a product
  regression), and the runner amplifies it.** A beta 4 build
  (`ee51387d`) and the beta 5 build were profiled with the same probe
  (`sample`, the slide's frames stepped as the test does) and timed per
  step:

  | Per frame, Mac (median ms) | beta 4 | beta 5 | beta 5 fixed |
  |---|---|---|---|
  | whole frame | 9.6–10.4 | 11.9–12.4 | 10.2–10.3 |
  | divider move (`setPosition`) | 6.2–6.6 | 6.1–6.2 | 6.1–6.2 |
  | content layout | 1.1–1.2 | 3.2–3.3 | 1.6 (beta 4 1.6–1.8 with the same probe) |
  | display | 2.3–2.4 | 2.5–2.6 | 2.4 |

  The added layout time is AppKit's: in beta 5 the navigator's header rows
  give way below their natural width (P-024, `letHeadersCompress`): their
  stacks resist clipping at 200 and their controls resist compression at
  200. The layout engine reports changes to every view of the window on
  every frame of the inspector's slide (the navigator does not move), and
  such a stack then checks again for clipping and builds its constraints
  anew (`-[NSStackView _subview:valueOfVariable:didChangeInEngine:]` →
  `setNeedsUpdateConstraints:` → `updateConstraints`, four stacks once or
  twice a frame, none in beta 4), while the weak compression constraints
  make every re-solve optimize again (`-[NSISEngine optimize]` 189 samples
  against 26). The toolbar is laid out every frame in both builds, so that
  is not new.
- **Product fix (smallest).** `NavigatorAreaController+HeaderHold.swift`
  (new): `holdHeaderClipping(true)` raises, for the slide, the clipping
  resistance of the navigator's horizontal stacks and the compression
  resistance of its header views to the usual priorities (required, 750),
  only for those at or above their natural width (their layout does not
  change; a row already giving way is left alone; the rows' scroll views
  are skipped); `holdHeaderClipping(false)` puts every priority back.
  `slideInspector` holds at the press and `finishInspectorSlide` releases
  (two lines in `WorkspaceWindowController+InspectorSlide.swift`), and one
  stored property in `NavigatorAreaController.swift`. The press costs
  about 1 ms more (toggle 4.2 against beta 4's 3.2 ms), the end the same.
- **Test change.** The limit is `27 ms × UIMachineFactor` (this window's
  reference redraw 9.0 ms), so the Mac keeps 27 ms; the test also checks
  that the rows are held during the slide and released after it, and prints
  the redraw, factor and limit. Beta 4's CI (21.7 / 20.9 ms) stayed under 27
  on a machine whose compute was 20–45 % faster than this run's; with the
  regression gone, this run's machine would be near 27, so a factor is
  needed as well.
- **Before/after (Mac):** hide / show medians 11.2 / 12.8, 15.3 / 11.5,
  11.6 / 12.1 ms before; 9.3 / 9.6, 9.6 / 10.5, 9.6 / 11.1 ms after (limits
  27.5–32.1, factor 1.02–1.19).
- New test `B5FixCIUITests`: holding keeps every navigator header frame
  and gives every priority back; the inspector's slide holds from its press
  to its end.

## Verification (Mac)

- Focused: the three tests' suites and the suites that slide the inspector
  or narrow the navigator (`B5FixCIUITests`, `B5FollowupUITests`,
  `B5NavigatorTests`, `CouncilRound6ChromeTests`, `B5FixLayoutUITests`,
  `B5MotionUITests`, `Beta5ToolbarTests`, `CouncilRound4/8/9MotionTests`,
  `CouncilRound10InspectorTests`, `FidelityCouncilTests`,
  `FidelityCouncilR2Tests`, `NavigatorInspectorR45Tests`): 127 tests in 14
  suites passed.
- Full `YcodeUITests` (one run, under both locks): 969 tests in 230 suites,
  2 failures unrelated to this change
  (`DeviceHubYcrunTests.aDeviceYcrunBootedIsRunningAndShutDownSendsSIGTERMToItsPid`,
  498 s under load; `B5NewProjectUITests.welcomeOpenClosesWelcomeFirst`);
  both pass when run alone. In that run: slide medians 12.2 / 13.1 ms
  (limit 32.1), small opens `[40, 38, 40]` ms (limit 121).
- No product code shared with Linux changed (`YcodeUI` is macOS only), so
  no x86 run.

## Not changed

- `.github/ci/known-flaky.txt`: nothing added. All three failed the same
  way on two runs and the two timing tests are slow alone on the runner, so
  a rerun would not help. `ycode/README.md` ("Tests in a full run") gains a
  note on the runner's Reduce Motion and on `UIMachineFactor`.
- The diagnostics settle test 1 locally (the runner script sets Reduce
  Motion); the printed redraw and factor will show on the next CI run how
  far the runner is from the Mac.

## Candidates

- The same navigator rows likely cost the same per frame during the debug
  area's slide (P-191) and a window's live resize; the hold could cover the
  debug-area slide too (its width does not change the navigator's).
- `R6CHROME file switch without the inspector` went from `[17, 15, 81]` to
  `[33, 91, 270]` ms on CI between beta 4 and beta 5 (not a failing test);
  the navigator rows may be part of it.
