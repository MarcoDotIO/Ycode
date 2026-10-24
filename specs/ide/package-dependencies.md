# Package dependencies

Ycode modules: `YcodeProject` (typed mutations), `YcodeBuild`
(`PackageResolver`), `YcodeUI` (`PackageDependencyModel`,
`AddPackageController`, the project editor's Package Dependencies tab, the
navigator section).

## Project-file objects

| Object | Keys (besides `isa`) |
|---|---|
| `XCRemoteSwiftPackageReference` | `repositoryURL`, `requirement` (dictionary) |
| `XCLocalSwiftPackageReference` | `relativePath` (relative to the project directory) |
| `XCSwiftPackageProductDependency` | `package` (the reference), `productName` |
| `PBXBuildFile` (product link) | `productRef` (the product dependency); single-line like other build files |

`PBXProject.packageReferences` lists the references in order; each target's
`packageProductDependencies` lists its products. Reference comments are in
`specs/formats/pbxproj.md` (a product build file's comment is
`<product> in Frameworks`).

`requirement` dictionaries, by `kind`:

| Rule (sheet title) | `kind` | Other keys |
|---|---|---|
| Up to Next Major Version | `upToNextMajorVersion` | `minimumVersion` |
| Up to Next Minor Version | `upToNextMinorVersion` | `minimumVersion` |
| Range of Versions | `versionRange` | `minimumVersion`, `maximumVersion` (exclusive) |
| Exact Version | `exactVersion` | `version` |
| Branch | `branch` | `branch` |
| Commit | `revision` | `revision` |

## Mutations (YcodeProject)

- `addRemotePackage(url:requirement:)`, `addLocalPackage(relativePath:)`:
  a new object appended to `packageReferences` (key created if missing).
- `setRequirement(_:ofPackage:)`.
- `addPackageProduct(_:package:toTarget:)`: the product dependency,
  appended to the target's `packageProductDependencies`, and a build file
  appended to the target's frameworks phase. Without a frameworks phase
  one is made (`buildActionMask = 2147483647`,
  `runOnlyForDeploymentPostprocessing = 0`) and placed after the sources
  phase.
- `removePackageProduct(_:)`: removes the product, its build files and its
  entries (the target keeps an empty `packageProductDependencies`).
- `removePackage(_:)`: removes the reference and every product on it;
  `packageReferences` is dropped when it becomes empty.
- Invariant (tested): removing the fixture's package and adding it back
  with the same IDs reproduces the file byte for byte.

## Resolution (Ycode's approach)

Ycode does not link libSwiftPM. It resolves with git and SwiftPM's public
command line:

1. Versions: `git ls-remote --tags <url>`; tags that parse as semantic
   versions (an optional `v` prefix is accepted). Pre-releases are chosen
   only when the rule's lower bound is itself a pre-release.
2. Selection: the highest version the rule allows. Branch rules check out
   `origin/<branch>`; commit rules check out the revision.
3. Checkout: `git clone` into `<checkouts>/<identity>` (identity = last URL
   component without `.git`, lowercased), later `git fetch --tags`, then a
   detached checkout. Default checkouts:
   `~/Library/Caches/Ycode/SourcePackages/<project>-<hash>/checkouts`.
4. Products: `swift package dump-package` on the checkout (or the local
   folder): the `products[].name` values.
5. Transitive dependencies: each checked-out package's remote
   dependencies (`dump-package` `dependencies[].sourceControl`, `remote`
   URL or `local` repository path, requirement `range` / `exact` /
   `branch` / `revision`) are added as requirements from
   `<identity> <version>`. Every package gets the highest version inside
   the intersection of all version requirements on it. An empty
   intersection, no matching tag, or a branch/commit rule meeting any
   other rule fails with "Dependencies could not be resolved: …" naming
   each requirement (`the project requires 2.0.0 – Next Major; app 0.1.0
   requires 1.0.0 – 2.0.0`). There is no backtracking: a package's
   version, once chosen, changes only when a new requirement excludes
   it, and requirements from a package's earlier version stay.
6. `Package.resolved`, format version 3, is written to
   `<project>.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/`:
   `originHash`, then `pins` sorted by identity, each with `identity`,
   `kind` (`remoteSourceControl`), `location`, and `state` (`revision`,
   plus `version` or `branch`), then `version` (3). Keys sorted, two-space
   indentation, `" : "` separators, final newline. `originHash` follows
   SwiftPM's open-source definition: the SHA-256 (lowercase hex) of the
   root manifests' contents followed by the root dependencies' location
   strings. A project has no root manifest, so Ycode hashes the project's
   remote package URLs in `packageReferences` order (OPEN QUESTION).
7. File ▸ Packages ▸ Resolve Package Versions (reference-ui.md §1), and every package addition, resolve
   again. A failure becomes one error, "Package resolution failed: …",
   in the issue navigator (with no file, under the build-system group);
   success clears it.

Building with packages goes through swift-build's PIF
(`specs/ide/build-pif.md`) and is not covered here.

## Add Package sheet

File ▸ Add Package Dependencies…, or + in the Package Dependencies tab.
A field for a URL or a local path (absolute, `~`, `.`-relative, or text
with no `://` and no `@`), a Dependency Rule pop-up with the six rules
above and one or two version fields (the second only for Range), and Add
to Target. The first Add Package fetches the package and lists its
products, all checked; the second links the checked products to the
target, resolves, and writes `Package.resolved` and the project. Local
paths are stored relative to the project directory.

## Project navigator and project editor

- After the project, a "Package Dependencies" row lists one row per
  package: remote ones as `<name> <resolved version>` (the version from
  `Package.resolved`, omitted when unresolved) listing their checkout;
  local ones by folder name, listing the folder.
- Project ▸ Package Dependencies tab: per package its name, Location,
  Dependency Rule (e.g. `1.5.0 – Next Major`, `Local`) and the products
  targets use; a + button.

## Evidence

- Object classes, keys and `kind` values: project files studied as a
  format (level 2); the same names are used by open-source project-file
  libraries (level 1). Our fixture follows that layout.
- Rule titles and the sheet's flow: Apple's public documentation on adding
  package dependencies to an app (level 1).
- `Package.resolved` layout and identity rules: SwiftPM's open source
  (level 1).
- Navigator section and tab: Apple's public documentation (level 1).
- OPEN QUESTION: whether the reference writes `package` on products of
  local packages (Ycode writes it); whether an empty `packageReferences`
  key is kept; the exact tab layout; the search and package-collection
  panel of the reference sheet (Ycode takes only a URL or path).
