# qa probes (dirty side, black-box)

Our own programs, public API only, built with the iOS Simulator SDK and run
on throwaway reference simulators named `ycode-test-qa*`. Raw output stays in
`research/dirty/qa/` (not committed). Results: `specs/simulator/app-launch.md`
§8, `ipad.md` §10, `home-apps.md`.

- `cacheprobe.m`: `stat`/`lstat`/`access`/`open`/`readlink`/`realpath` and
  `_dyld_shared_cache_contains_path` of framework executables under several
  path spellings; CFBundle/NSBundle executable answers for WebKit;
  `_dyld_get_image_name` of cache images. `cacheprobe <path>...` prints only
  the dyld answer per path; `cacheprobe --respawn-env VAR=VALUE ...` re-runs
  itself with one environment variable replaced (chainable; end with
  `--full` for the full report).
  Build: `xcrun -sdk iphonesimulator clang -fobjc-arc -framework Foundation
  -mios-simulator-version-min=27.0 cacheprobe.m -o cacheprobe`; run with
  `xcrun simctl spawn <device> ./cacheprobe`.
- `webprobe/`: a one-window app whose WKWebView loads a `data:` URL and logs
  the navigation result, then (with `--open`) asks the system to open the
  same URL. Build `main.m` with `-framework UIKit -framework WebKit` into
  `webprobe.app/webprobe`, copy `Info.plist`, sign ad hoc (`codesign -s -`),
  `simctl install`, `simctl launch --console-pty <device> io.ycode.qa.webprobe --open`.
