#!/usr/bin/env python3
"""Write the parity run's part B test project, Parity: a small macOS SwiftUI
app with a unit test bundle, in a git repository. Our own content.

- Parity/ParityApp.swift, ContentView.swift (with a #Preview), Counter.swift
  (a function the app calls at launch, for a breakpoint and stepping, and a
  print for the console), Shapes.swift (documented types for completion, Quick
  Help and rename), Showcase.swift (about 400 lines of varied Swift for syntax
  colouring, folding and the minimap), Issues.swift (clean; the session swaps
  in .parity/issues-broken.txt for a warning and an error with fix-its, and
  .parity/issues-clean.txt to fix them).
- ParityTests/ParityTests.swift: a host-less XCTest bundle with one passing
  and one deliberately failing test.
- A shared scheme, Parity, that builds and runs the app and tests the bundle.
- A git repository with two commits by a fixed test identity on fixed dates
  (Authors / blame and history show no one's name), main checked out, clean.
- Signing: automatic, "Sign to Run Locally" (CODE_SIGN_IDENTITY -), no team.

Usage: python3 -I make-parity-project.py OUT_DIR   (writes OUT_DIR/Parity)
"""

import hashlib
import os
import pathlib
import shutil
import subprocess
import sys

NAME = "Parity"
TESTS = "ParityTests"
IDENTITY = {
    "GIT_AUTHOR_NAME": "Capture Test", "GIT_AUTHOR_EMAIL": "capture@example.invalid",
    "GIT_COMMITTER_NAME": "Capture Test", "GIT_COMMITTER_EMAIL": "capture@example.invalid",
}


def oid(name):
    return hashlib.sha1(f"{NAME}:{name}".encode()).hexdigest()[:24].upper()


APP = """import SwiftUI

@main
struct ParityApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
"""

CONTENT = """import SwiftUI

struct ContentView: View {
    @State private var counter = Counter()

    var body: some View {
        VStack(spacing: 12) {
            Text(Counter.greeting(for: "Parity"))
                .font(.title)
            Text("Count: \\(counter.count)")
            Button("Increment") { counter.increment() }
        }
        .padding(40)
    }
}

#Preview {
    ContentView()
}
"""

COUNTER = """// Counter.swift: a function the app calls at launch (breakpoint material).

struct Counter {
    private(set) var count = 0

    mutating func increment() {
        count += 1
    }

    static func greeting(for name: String) -> String {
        let prefix = "Hello"
        let message = "\\(prefix), \\(name)!"
        print("Parity greeting:", message)
        return message
    }
}
"""

SHAPES = """// Shapes.swift: documented types for completion, Quick Help and rename.

/// A shape that can report its area.
protocol Shape {
    /// The area of the shape, in square points.
    var area: Double { get }
}

/// A circle, described by its radius.
struct Circle: Shape {
    /// The radius, in points.
    var radius: Double

    var area: Double { .pi * radius * radius }

    /// Returns a circle whose radius is multiplied by `factor`.
    func scaled(by factor: Double) -> Circle {
        Circle(radius: radius * factor)
    }
}

/// An axis-aligned rectangle.
struct Rectangle: Shape {
    var width: Double
    var height: Double

    var area: Double { width * height }
}

/// The sum of the areas of `shapes`, plus a scaled reference circle.
func totalArea(of shapes: [any Shape]) -> Double {
    let circle = Circle(radius: 2)
    let bigger = circle.scaled(by: 2)
    return shapes.reduce(bigger.area) { $0 + $1.area }
}
"""

ISSUES_CLEAN = """// Issues.swift: material for the build issue captures.

func risky() throws -> Int { 1 }

func issues() -> Int {
    let fixed = 1
    let result = (try? risky()) ?? 0
    return fixed + result
}
"""

ISSUES_BROKEN = """// Issues.swift: material for the build issue captures.

func risky() throws -> Int { 1 }

func issues() -> Int {
    var neverMutated = 1
    let result = risky()
    return neverMutated + result
}
"""

TEST = """import XCTest

final class ParityTests: XCTestCase {
    func testAddition() {
        XCTAssertEqual(2 + 2, 4)
    }

    func testDeliberateFailure() {
        XCTAssertEqual("parity".count, 5, "a deliberate failure for the capture")
    }
}
"""


def showcase(revised=False):
    out = ["// Showcase.swift: varied Swift for syntax colouring, folding and the minimap.", "",
           "import Foundation", ""]
    for n in range(8):
        out += [
            f"// MARK: - Section {n}",
            "",
            f"/// A documented enumeration, number {n}.",
            f"enum Mode{n}: String, CaseIterable, Sendable {{",
            "    case idle, running, finished",
            "",
            "    /// A label for the mode.",
            "    var label: String {",
            "        switch self {",
            "        case .idle: return \"Idle\"",
            "        case .running: return \"Running…\"",
            "        case .finished: return \"Finished\"",
            "        }",
            "    }",
            "}",
            "",
            f"struct Box{n}<Value: Comparable & Sendable>: Sendable {{",
            "    var values: [Value] = []",
            f"    let limit = {0x10 + n}",
            f"    let ratio: Double = {n}.25e-1",
            "",
            "    mutating func insert(_ value: Value) -> Bool {",
            "        guard values.count < limit else { return false }",
            "        values.append(value)",
            "        values.sort(by: <)",
            "        return true",
            "    }",
            "",
            "    func describe() -> String {",
            f"        \"Box{n} holds \\(values.count) of \\(limit)\" + (values.isEmpty ? \"\" : \" items\")",
            "    }",
            "}",
            "",
            f"@MainActor final class Store{n} {{",
            "    private var cache: [String: Int] = [:]",
            "    nonisolated let name: String",
            "",
            "    init(name: String) { self.name = name }",
            "",
            "    func lookup(_ key: String) async throws -> Int? {",
            "        if let hit = cache[key] { return hit }",
            "        let value = key.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }",
            "        cache[key] = value",
            "        return value",
            "    }",
            "}",
            "",
            "#if DEBUG",
            f"let debugBanner{n} = \"\"\"",
            f"    Section {n} of the showcase",
            "    with a multi-line string",
            "    \"\"\"",
            "#endif",
            "",
            f"func filtered{n}(_ items: [Int]) -> [Int] {{",
            "    // TODO: a plain comment with a marker",
            "    items.lazy.filter { $0.isMultiple(of: 2) }.map { $0 * 3 }.sorted()",
            "}",
            "",
        ]
        if revised and n == 2:
            out[-3] = "    items.lazy.filter { $0 % 2 == 0 }.map { $0 * 3 }.sorted()   // revised"
    return "\n".join(out) + "\n"


def pbxproj():
    i = {k: oid(k) for k in ["project", "main", "products", "app", "xctest", "sync-app", "sync-tests",
                            "t-app", "t-tests", "src-app", "src-tests", "fw-app", "fw-tests", "res-app", "res-tests",
                            "list-project", "list-app", "list-tests", "p-debug", "p-release", "a-debug", "a-release",
                            "x-debug", "x-release"]}
    common = """				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				MACOSX_DEPLOYMENT_TARGET = 15.0;
				SDKROOT = macosx;
				SWIFT_VERSION = 6.0;"""

    def target_settings(bundle, extra=""):
        return f"""				CODE_SIGN_STYLE = Automatic;
				CODE_SIGN_IDENTITY = "-";
				GENERATE_INFOPLIST_FILE = YES;
				PRODUCT_BUNDLE_IDENTIFIER = {bundle};
				PRODUCT_NAME = "$(TARGET_NAME)";{extra}"""

    def phase(key, isa):
        return f"""		{i[key]} /* {isa.replace('PBX', '').replace('BuildPhase', '')} */ = {{
			isa = {isa};
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
"""

    def target(key, name, sync, src, fw, res, lst, product, ptype, prodname):
        return f"""		{i[key]} /* {name} */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {i[lst]} /* Build configuration list for PBXNativeTarget "{name}" */;
			buildPhases = (
				{i[src]} /* Sources */,
				{i[fw]} /* Frameworks */,
				{i[res]} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				{i[sync]} /* {name} */,
			);
			name = {name};
			productName = {name};
			productReference = {i[product]} /* {prodname} */;
			productType = "{ptype}";
		}};
"""

    def config(key, name, body):
        return f"""		{i[key]} /* {name} */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{body}
			}};
			name = {name};
		}};
"""

    def clist(key, what, d, r):
        return f"""		{i[key]} /* Build configuration list for {what} */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{i[d]} /* Debug */,
				{i[r]} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
"""

    return f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 77;
	objects = {{

/* Begin PBXFileReference section */
		{i['app']} /* {NAME}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {NAME}.app; sourceTree = BUILT_PRODUCTS_DIR; }};
		{i['xctest']} /* {TESTS}.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = {TESTS}.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
		{i['sync-app']} /* {NAME} */ = {{
			isa = PBXFileSystemSynchronizedRootGroup;
			path = {NAME};
			sourceTree = "<group>";
		}};
		{i['sync-tests']} /* {TESTS} */ = {{
			isa = PBXFileSystemSynchronizedRootGroup;
			path = {TESTS};
			sourceTree = "<group>";
		}};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
{phase('fw-app', 'PBXFrameworksBuildPhase')}{phase('fw-tests', 'PBXFrameworksBuildPhase')}/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{i['main']} = {{
			isa = PBXGroup;
			children = (
				{i['sync-app']} /* {NAME} */,
				{i['sync-tests']} /* {TESTS} */,
				{i['products']} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{i['products']} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{i['app']} /* {NAME}.app */,
				{i['xctest']} /* {TESTS}.xctest */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
{target('t-app', NAME, 'sync-app', 'src-app', 'fw-app', 'res-app', 'list-app', 'app', 'com.apple.product-type.application', NAME + '.app')}{target('t-tests', TESTS, 'sync-tests', 'src-tests', 'fw-tests', 'res-tests', 'list-tests', 'xctest', 'com.apple.product-type.bundle.unit-test', TESTS + '.xctest')}/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{i['project']} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2700;
				LastUpgradeCheck = 2700;
			}};
			buildConfigurationList = {i['list-project']} /* Build configuration list for PBXProject "{NAME}" */;
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = {i['main']};
			minimizedProjectReferenceProxies = 1;
			preferredProjectObjectVersion = 77;
			productRefGroup = {i['products']} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{i['t-app']} /* {NAME} */,
				{i['t-tests']} /* {TESTS} */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
{phase('res-app', 'PBXResourcesBuildPhase')}{phase('res-tests', 'PBXResourcesBuildPhase')}/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
{phase('src-app', 'PBXSourcesBuildPhase')}{phase('src-tests', 'PBXSourcesBuildPhase')}/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
{config('p-debug', 'Debug', common + chr(10) + '				ONLY_ACTIVE_ARCH = YES;' + chr(10) + '				SWIFT_OPTIMIZATION_LEVEL = "-Onone";' + chr(10) + '				ENABLE_TESTABILITY = YES;')}{config('p-release', 'Release', common + chr(10) + '				SWIFT_COMPILATION_MODE = wholemodule;')}{config('a-debug', 'Debug', target_settings('org.example.Parity'))}{config('a-release', 'Release', target_settings('org.example.Parity'))}{config('x-debug', 'Debug', target_settings('org.example.ParityTests'))}{config('x-release', 'Release', target_settings('org.example.ParityTests'))}/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
{clist('list-project', 'PBXProject "' + NAME + '"', 'p-debug', 'p-release')}{clist('list-app', 'PBXNativeTarget "' + NAME + '"', 'a-debug', 'a-release')}{clist('list-tests', 'PBXNativeTarget "' + TESTS + '"', 'x-debug', 'x-release')}/* End XCConfigurationList section */
	}};
	rootObject = {i['project']} /* Project object */;
}}
""", i


def scheme(i):
    def ref(key, product, name):
        return (f'            BuildableIdentifier = "primary"\n            BlueprintIdentifier = "{i[key]}"\n'
                f'            BuildableName = "{product}"\n            BlueprintName = "{name}"\n'
                f'            ReferencedContainer = "container:{NAME}.xcodeproj">')
    app = ref("t-app", NAME + ".app", NAME)
    tests = ref("t-tests", TESTS + ".xctest", TESTS)
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2700"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
{app}
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
{tests}
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
{app.replace(chr(10) + '            ', chr(10) + '            ')}
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
{app}
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


def git(root, *args, date="2026-01-01T12:00:00Z"):
    env = {**os.environ, **IDENTITY, "GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date,
           "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
    subprocess.run(["git", *args], cwd=root, env=env, check=True, capture_output=True)


def write(out_dir: pathlib.Path) -> pathlib.Path:
    root = out_dir / NAME
    if root.exists():
        shutil.rmtree(root)
    src, tests = root / NAME, root / TESTS
    proj = root / f"{NAME}.xcodeproj"
    for d in (src, tests, proj / "xcshareddata" / "xcschemes", root / ".parity"):
        d.mkdir(parents=True, exist_ok=True)
    text, ids = pbxproj()
    (proj / "project.pbxproj").write_text(text)
    (proj / "xcshareddata" / "xcschemes" / f"{NAME}.xcscheme").write_text(scheme(ids))
    files = {"ParityApp.swift": APP, "ContentView.swift": CONTENT, "Counter.swift": COUNTER,
             "Shapes.swift": SHAPES, "Showcase.swift": showcase(), "Issues.swift": ISSUES_CLEAN}
    for name, body in files.items():
        (src / name).write_text(body)
    (tests / "ParityTests.swift").write_text(TEST)
    (root / ".parity" / "issues-broken.txt").write_text(ISSUES_BROKEN)
    (root / ".parity" / "issues-clean.txt").write_text(ISSUES_CLEAN)
    (root / ".editorconfig").write_text("root = true\n\n[*]\nindent_style = space\nindent_size = 4\n")
    (root / ".gitignore").write_text("xcuserdata/\n*.xcuserstate\nproject.xcworkspace/\nDerivedData/\n.parity/\n")
    git(root, "init", "-q", "-b", "main")
    # The repository's own identity, so an app's commit UI shows the test identity, not the Mac's global one.
    git(root, "config", "user.name", IDENTITY["GIT_AUTHOR_NAME"])
    git(root, "config", "user.email", IDENTITY["GIT_AUTHOR_EMAIL"])
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "Start Parity")
    (src / "Showcase.swift").write_text(showcase(revised=True))
    git(root, "commit", "-q", "-am", "Revise the showcase filter", date="2026-01-05T12:00:00Z")
    return proj


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    print(write(pathlib.Path(sys.argv[1])))
