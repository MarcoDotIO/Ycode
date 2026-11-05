# Releasing Ycode

The checklist for cutting a release, written for 1.0.0-beta.2 and meant to be reused. Each step names the
script or workflow that does it; a step marked **by hand** has no automation yet. The release workflow is
[`.github/workflows/release.yml`](../.github/workflows/release.yml), and the packaging scripts are described in
[packaging/README.md](../packaging/README.md).

Below, `<version>` is the new version (`1.0.0-beta.2`) and `<date>` the day it is tagged, as `YYYY-MM-DD`.

## 1. Before the release branch

- [ ] **The milestone is done.** Every issue in the `<version>` milestone is closed or moved to the next one
  (**by hand**: `gh issue list -R MarcoDotIO/Ycode --milestone <version> --state open` must list nothing).
- [ ] **CI is green on `main`** for macOS arm64, Linux x86-64 and Linux arm64: the `ycode` and `frameworks and
  composer` jobs, SwiftLint, and the public scan ([`ci.yml`](../.github/workflows/ci.yml); the `CI passed` job
  sums them up). A known-flaky test passes only when rerun alone (`.github/scripts/run-tests.py` does that).
- [ ] **The Flatpak runtime is current.** `runtime-version` in
  [`io.github.MarcoDotIO.Ycode.yml`](../packaging/flatpak/io.github.MarcoDotIO.Ycode.yml) names the freedesktop
  runtime the Flatpak repository asks for (26.08 since beta 2), and its LLVM SDK extension exists for that
  runtime (`flatpak remote-info --user flathub runtime/org.freedesktop.Sdk.Extension.llvm<N>/<arch>/<runtime>`).
  The glibc named in `packaging/README.md` and in `.github/scripts/prepare-release.sh` matches it.

## 2. The version commit

One commit on `main` that states the new version everywhere it is stated. `YcodeReleaseTests`
(`swift test --filter YcodeReleaseTests` in `ycode/`) fails until the first three agree.

- [ ] `ycode/VERSION`: `<version>`.
- [ ] `YcodeRelease.version` in `ycode/Sources/YcodeRelease/YcodeRelease.swift`: `<version>`.
- [ ] **The metainfo:** a new first `<release version="<version>" date="<date>" type="development">` in
  [`io.github.MarcoDotIO.Ycode.metainfo.xml`](../packaging/flatpak/io.github.MarcoDotIO.Ycode.metainfo.xml), with a
  one-paragraph description. Add it only now, when the release is cut, never ahead of time. Check it with
  `appstreamcli validate --no-net` (`build-flatpak.sh` runs it too).
- [ ] **CHANGELOG.md:** rename `## [Unreleased]` to `## [<version>] - <date>` and start a new empty
  `## [Unreleased]` above it. The section becomes the release notes, so it must not be empty. Narrow or drop
  the known limitations that the release fixed.
- [ ] **The README:** the beta banner and the file names in Install (`Ycode-<version>.dmg`,
  `Ycode-<version>-x86_64.flatpak`).
- [ ] **The issue templates:** the version placeholder in `.github/ISSUE_TEMPLATE/bug_report.yml` and
  `simulator_report.yml`.
- [ ] Check the metadata the release workflow will check:
  `python3 -I .github/scripts/changelog-section.py <version>` prints the notes, and
  `python3 -I .github/scripts/check-release-metadata.py <version>` says the metainfo and CHANGELOG agree.
- [ ] `python3 -I .github/scripts/scan-public.py` passes.

## 3. A dry run of the packages

- [ ] **Run the release workflow by hand on `main`** (Actions ▸ Release ▸ Run workflow). A manual run builds every
  package and keeps them as workflow artifacts, without publishing. The `check` job fails on a missing or
  undated CHANGELOG section, a metainfo that disagrees with it, or the public scan.
- [ ] **macOS** (`macos` job, `ycode/scripts/make-dmg.sh`): the universal disk image, signed inside out with the
  hardened runtime, notarized and stapled when the `MACOS_CERTIFICATE_*` and `NOTARY_KEY_*` secrets are set.
  `packaging/macos/verify-dmg.sh` checks it as part of the build, and with the notary secrets
  `YCODE_VERIFY_REQUIRE_GATEKEEPER=1` makes a Gatekeeper rejection fail the job. Open the image once **by hand**
  to check the window layout, which the script does not look at.
- [ ] **Linux** (`flatpak` job, `packaging/flatpak/build-flatpak.sh`, x86-64 and aarch64): two `.flatpak`
  bundles and two `.tar.xz` tarballs. Install each bundle **by hand** on its architecture and run it:

  ```sh
  flatpak install --user --bundle Ycode-<version>-<arch>.flatpak
  flatpak run --user --command=ycode io.github.MarcoDotIO.Ycode --version
  flatpak run --user io.github.MarcoDotIO.Ycode    # the window opens; YCODE_IDE_WALK walks it
  ```

  On a machine that already has a Ycode install you want to keep, check the command-line tools without
  installing (`flatpak-builder --run <build-dir> <manifest> ycode --version`). The window needs a real install:
  under `flatpak-builder --run` on 26.08 it aborts in GTK's icon loader (used for the window decorations),
  which needs the Flatpak portal that a real install has. Install it under another branch instead
  (`flatpak build-commit-from --src-ref=app/io.github.MarcoDotIO.Ycode/<arch>/master <repo>
  app/io.github.MarcoDotIO.Ycode/<arch>/test`, `flatpak build-bundle <repo> test.flatpak io.github.MarcoDotIO.Ycode test`,
  install that, run it with `flatpak run --branch=test`). Installing makes the new branch current: run
  `flatpak make-current --user io.github.MarcoDotIO.Ycode master` straight after, and uninstall the test branch at
  the end.

## 4. Tag and publish

- [ ] **Tag the version commit** `v<version>` and push the tag (**by hand**: `git tag v<version>`,
  `git push origin v<version>`). The tag starts the release workflow. Its `check` job fails when the tag does
  not match `ycode/VERSION`.
- [ ] **The workflow publishes** (`publish` job, `.github/scripts/prepare-release.sh`, then `gh release create`):
  - collects the disk image, both Flatpak bundles and both tarballs, and fails if one is missing;
  - writes `SHA256SUMS.txt` over the five files;
  - writes the release notes from the CHANGELOG section (`changelog-section.py`), then the Install paragraph,
    the macOS signing state (notarized, Developer ID only, or ad-hoc) and the tarballs' runtime;
  - creates the GitHub release with `--latest` and `--verify-tag`. A prerelease can't be the latest release,
    and the repository page lists only the latest, so beta versions are published as full releases; the version
    and title say beta.
- [ ] **Check the published release by hand:** it is marked as Latest, it has the five files and
  `SHA256SUMS.txt`, `shasum -a 256 -c SHA256SUMS.txt` passes on the downloaded files, and the notes state the
  signing you expected.

## 5. After the release

- [ ] **FlatPark** (**by hand**; no script in this repository yet): update Ycode's listing to the new version's
  bundles and manifest. The listing builds on the same freedesktop runtime as the manifest here.
- [ ] **The milestone:** close the `<version>` milestone and open the next one (**by hand**, on GitHub).
- [ ] **Sync the public repository** if the work happened elsewhere, so the tag's commit is on the public
  `main`.

## Notes for 1.0.0-beta.2

- The Flatpak moved to freedesktop 26.08 (glibc 2.44) and the llvm22 SDK extension (issue #26). The bundled
  libxml2 (`libxml2.so.2` for the Swift toolchain), libcurl (versioned symbols for FoundationNetworking) and
  SDL 3 are still built, because 26.08 does not provide them in the form the package needs.
- beta 1's metainfo date was corrected to 2026-11-04 (issue #27). **Add the `1.0.0-beta.2` `<release>` entry
  only in the version commit above**, with the tag's date; `check-release-metadata.py` stops a release whose
  metainfo and CHANGELOG disagree.
