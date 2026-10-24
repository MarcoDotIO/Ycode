#!/usr/bin/env python3 -I
"""Black-box conformance harness: runs `xcodebuild` and `ycodebuild` with the
same arguments over a project corpus and compares stdout, stderr and exit
status. See specs/xcodebuild/conformance.md.

    YCODE_PBXPROJ_CORPUS=manifest.txt YCODE_SWB=/path/ycode-swb \
        python3 -I scripts/xcodebuild-conformance.py [--ycodebuild .build/debug/ycodebuild]

The manifest has one project per line, `= /path/App.xcodeproj` or
`~ /path/App.xcodeproj` (a path to `project.pbxproj` also works). Projects
inside an Xcode application bundle are skipped (clean-room rule: the
reference application is not opened). Reference results are cached under
--cache so later runs only execute ycodebuild. Nothing is written into the
corpus projects; the reference tool's DerivedData is not touched because
only read-only commands are run.

    python3 -I scripts/xcodebuild-conformance.py --builds [--refresh] [--details]

runs the build cases instead: test actions, result bundles (compared through
`xcrun xcresulttool`), archives and exports, on sample projects the script
writes itself (never on corpus projects).
"""
import argparse, concurrent.futures, hashlib, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
YCODE = os.path.dirname(HERE)


def run(tool, args, cwd, timeout=300):
    try:
        p = subprocess.run([tool] + args, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return {"out": p.stdout, "err": p.stderr, "code": p.returncode}
    except subprocess.TimeoutExpired:
        return {"out": "", "err": "timeout", "code": -999}


def reference(args, cwd, cache, refresh):
    key = hashlib.sha256(json.dumps([args, cwd]).encode()).hexdigest()[:24]
    path = os.path.join(cache, key + ".json")
    if os.path.exists(path) and not refresh:
        with open(path) as f:
            return json.load(f)
    r = run("xcodebuild", args, cwd)
    r["args"], r["cwd"] = args, cwd
    with open(path, "w") as f:
        json.dump(r, f)
    return r


NOISE = re.compile(r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+ xcodebuild\[|^ycodebuild: warning:")


def normalize(r):
    out = r["out"].split("\n")
    # The tool path in the invocation header differs by design.
    for i in range(len(out) - 1):
        if out[i] == "Command line invocation:":
            parts = out[i + 1].strip().split(" ", 1)
            out[i + 1] = "    <tool> " + (parts[1] if len(parts) > 1 else "")
    err = [l for l in r["err"].split("\n") if not NOISE.search(l)]
    return "\n".join(out), "\n".join(err), r["code"]


def parse_settings(text):
    """{target: {name: value}} from -showBuildSettings text output."""
    blocks, cur = [], None
    for line in text.split("\n"):
        m = re.match(r"^Build settings for action (\S+) and target (.*):$", line)
        if m:
            cur = {}
            blocks.append((m.group(2), cur))
            continue
        m = re.match(r"^    (\S+) = (.*)$", line)
        if m and cur is not None:
            cur[m.group(1)] = m.group(2)
        elif line == "":
            cur = None
    return blocks


def parse_settings_json(text):
    try:
        return [(e["target"], e["buildSettings"]) for e in json.loads(text)]
    except Exception:
        return []


ENGINE_DEPENDENT = {"PATH"}  # first element names the build service's own location


class Stats:
    def __init__(self):
        self.cases = {}
        self.settings = {"compared": 0, "equal": 0, "missing": 0, "extra": 0, "different": 0}
        self.extra_names = {}
        self.diff_names = {}
        self.failures = []

    def case(self, kind, ok, detail=None):
        n, k = self.cases.get(kind, (0, 0))
        self.cases[kind] = (n + 1, k + (1 if ok else 0))
        if not ok and detail:
            self.failures.append((kind, detail))

    def compare_settings(self, ref_blocks, ycb_blocks):
        for (rt, rs), (yt, ys) in zip(ref_blocks, ycb_blocks):
            for k, v in rs.items():
                if k in ENGINE_DEPENDENT:
                    continue
                self.settings["compared"] += 1
                if k not in ys:
                    self.settings["missing"] += 1
                    self.diff_names[k] = self.diff_names.get(k, 0) + 1
                elif ys[k] == v:
                    self.settings["equal"] += 1
                else:
                    self.settings["different"] += 1
                    self.diff_names[k] = self.diff_names.get(k, 0) + 1
            for k in ys:
                if k not in rs:
                    self.settings["extra"] += 1
                    self.extra_names[k] = self.extra_names.get(k, 0) + 1


def load_manifest(path):
    projects = []
    for line in open(path):
        line = line.rstrip("\n")
        if len(line) < 3 or line[0] not in "=~":
            continue
        p = line[2:].strip()
        if p.endswith("project.pbxproj"):
            p = os.path.dirname(p)
        if ".app/Contents/" in p:
            continue  # inside an application bundle: not opened (clean room)
        if os.path.isdir(p):
            projects.append(p)
    return projects


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ycodebuild", default=os.path.join(YCODE, ".build/debug/ycodebuild"))
    ap.add_argument("--cache", default=os.path.join(YCODE, ".build-xcb-scratch/conformance"))
    ap.add_argument("--refresh", action="store_true", help="re-run xcodebuild instead of using cached results")
    ap.add_argument("--only", default="", help="comma-separated case kinds")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--details", action="store_true")
    ap.add_argument("--builds", action="store_true",
                    help="run the build, test, result-bundle and archive cases on generated sample projects instead of the corpus")
    a = ap.parse_args()
    # ycodebuild evaluates settings through its swift-build helper.
    local = os.path.join(YCODE, "Tools/ycode-swb/.build/debug/ycode-swb")
    if not os.environ.get("YCODE_SWB") and os.path.exists(local):
        os.environ["YCODE_SWB"] = local
    if a.builds:
        return build_main(a)
    manifest = os.environ.get("YCODE_PBXPROJ_CORPUS")
    if not manifest or not os.path.exists(manifest):
        print("set YCODE_PBXPROJ_CORPUS to a corpus manifest", file=sys.stderr)
        return 2
    os.makedirs(a.cache, exist_ok=True)
    scratch = os.path.join(a.cache, "cwd")
    os.makedirs(scratch, exist_ok=True)
    only = set(filter(None, a.only.split(",")))

    cases = []  # (kind, args, cwd, compare)
    def add(kind, args, cwd, compare="exact"):
        if not only or kind in only:
            cases.append((kind, args, cwd, compare))

    add("showsdks", ["-showsdks"], scratch)
    add("showsdks-json", ["-showsdks", "-json"], scratch, "json-sdks")
    add("version-sdk", ["-version", "-sdk"], scratch, "version-sdk")
    add("version-sdk-name", ["-version", "-sdk", "iphoneos"], scratch)
    add("version-sdk-item", ["-version", "-sdk", "macosx", "SDKVersion"], scratch)
    for name, args in [("invalid-option", ["-foo"]), ("missing-value", ["-list", "-project"]),
                       ("repeated-option", ["-configuration", "A", "-configuration", "B"]),
                       ("sdk-without-value", ["-list", "-sdk"]), ("jobs-zero", ["-jobs", "0", "-list"]),
                       ("double-dash", ["--list"]), ("dry-run", ["-dry-run"]),
                       ("project-and-workspace", ["-project", "a.xcodeproj", "-workspace", "b.xcworkspace", "-list"]),
                       ("bad-sdk", ["-sdk", "nosuchsdk", "-showBuildSettings"]),
                       ("no-project", ["-list"]), ("missing-project", ["-project", "Nope.xcodeproj", "-list"]),
                       ("missing-workspace", ["-workspace", "Nope.xcworkspace", "-list"])]:
        add("error:" + name, args, scratch, "error")

    for proj in load_manifest(manifest):
        cwd, name = os.path.dirname(proj), os.path.basename(proj)
        add("list", ["-list", "-project", name], cwd, "list")
        add("list-json", ["-list", "-json", "-project", name], cwd, "json")
        add("showBuildSettings", ["-showBuildSettings", "-project", name], cwd, "settings")
        add("showBuildSettings-json-alltargets-Debug", ["-showBuildSettings", "-json", "-alltargets", "-configuration", "Debug", "-project", name], cwd, "settings-json")
        add("showBuildSettings-json-alltargets-Release", ["-showBuildSettings", "-json", "-alltargets", "-configuration", "Release", "-project", name], cwd, "settings-json")
        # Scheme runs: DerivedData locations and the default run destination.
        listing = reference(["-list", "-json", "-project", name], cwd, a.cache, a.refresh)
        try:
            schemes = json.loads(listing["out"])["project"]["schemes"]
            targets = set(json.loads(listing["out"])["project"]["targets"])
        except Exception:
            schemes, targets = [], set()
        for scheme in [s for s in schemes if s in targets][:2]:
            add("showBuildSettings-json-scheme", ["-showBuildSettings", "-json", "-project", name, "-scheme", scheme], cwd, "settings-json")
        add("error:unknown-target", ["-showBuildSettings", "-project", name, "-target", "NoSuchTarget"], cwd, "error")
        add("error:unknown-scheme", ["-showBuildSettings", "-project", name, "-scheme", "NoSuchScheme"], cwd, "error")

    def do(case):
        kind, args, cwd, compare = case
        return case, reference(args, cwd, a.cache, a.refresh), run(a.ycodebuild, args, cwd)

    stats = Stats()
    with concurrent.futures.ThreadPoolExecutor(max_workers=a.jobs) as pool:
        for (kind, args, cwd, compare), ref, ycb in pool.map(do, cases):
            ro, re_, rc = normalize(ref)
            yo, ye, yc = normalize(ycb)
            label = " ".join(args) + "  (in " + cwd + ")"
            if compare == "exact":
                stats.case(kind, (ro, re_, rc) == (yo, ye, yc), label)
            elif compare == "list":
                # The resolved-package lines come in no fixed order (two
                # projects with the same packages list them differently).
                stats.case(kind, (unordered_blocks(ro.split("\n")), re_, rc) == (unordered_blocks(yo.split("\n")), ye, yc), label)
            elif compare == "json":
                try:
                    same = json.loads(ro) == json.loads(yo) and rc == yc
                except Exception:
                    same = False
                stats.case(kind, same, label)
            elif compare == "json-sdks":
                # Entries for one SDK under several bundle names come in no fixed order.
                key = lambda e: json.dumps(e, sort_keys=True)
                try:
                    same = sorted(map(key, json.loads(ro))) == sorted(map(key, json.loads(yo))) and rc == yc
                except Exception:
                    same = False
                stats.case(kind, same, label)
            elif compare == "version-sdk":
                stats.case(kind, sorted(ro.split("\n\n")[:-1]) == sorted(yo.split("\n\n")[:-1]) and rc == yc, label)
            elif compare == "error":
                first = lambda e: next((l for l in e.split("\n") if l.startswith("xcodebuild: error:")), "")
                stats.case(kind, first(re_) == first(ye) and rc == yc, label + f"\n      want {rc} {first(re_)!r}\n      got  {yc} {first(ye)!r}")
            elif compare in ("settings", "settings-json"):
                rb = parse_settings(ro) if compare == "settings" else parse_settings_json(ro)
                yb = parse_settings(yo) if compare == "settings" else parse_settings_json(yo)
                targets_ok = [t for t, _ in rb] == [t for t, _ in yb] and rc == yc
                stats.compare_settings(rb, yb)
                exact = targets_ok and all({k: v for k, v in r.items() if k not in ENGINE_DEPENDENT} == {k: v for k, v in y.items() if k not in ENGINE_DEPENDENT}
                                           for (_, r), (_, y) in zip(rb, yb))
                stats.case(kind + " (targets+status)", targets_ok, label + f"\n      want {rc} {[t for t, _ in rb]}\n      got  {yc} {[t for t, _ in yb]}")
                stats.case(kind + " (all values)", exact, None)

    print("| Case | Runs | Identical |")
    print("|---|---:|---:|")
    for k in sorted(stats.cases):
        n, ok = stats.cases[k]
        print(f"| {k} | {n} | {ok} |")
    s = stats.settings
    print()
    print(f"Settings compared (values the reference prints, PATH excluded): {s['compared']}")
    print(f"  equal {s['equal']}, different {s['different']}, missing {s['missing']}; extra names printed only by ycodebuild: {s['extra']}")
    if a.details:
        print("\nMost frequent differing/missing names:")
        for k, v in sorted(stats.diff_names.items(), key=lambda kv: -kv[1])[:40]:
            print(f"  {v:5d} {k}")
        print("\nExtra names:")
        for k, v in sorted(stats.extra_names.items(), key=lambda kv: -kv[1])[:40]:
            print(f"  {v:5d} {k}")
        print("\nFailures:")
        for kind, d in stats.failures:
            print(f"  [{kind}] {d}")
    return 0


# ---------------------------------------------------------------------------
# Build cases (--builds): tests, result bundles, archives and exports on
# hand-written sample projects the harness generates. These write files, so
# they never touch corpus projects: each tool gets its own copy of the
# samples and its own DerivedData. The reference tool's test runner cannot
# load test bundles from some external volumes, so its work directory is in
# the system temporary directory; ycodebuild's is under --cache.

PBX_HEAD = "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 77;\n\tobjects = {\n"
PBX_TAIL = "\t};\n\trootObject = %s;\n}\n"


def pbxproj(objects, root):
    return PBX_HEAD + "".join("\t\t%s = {%s};\n" % (k, v) for k, v in objects) + PBX_TAIL % root


def project_config(sdk_extra=""):
    return ("isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; ONLY_ACTIVE_ARCH = YES; %s}; name = Debug; " % sdk_extra,
            "isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; %s}; name = Release; " % sdk_extra.replace("DEBUG_INFORMATION_FORMAT = dwarf; ", ""))


def calc_sample():
    p = "C1000000000000000000"
    o = [
        (p + "0001", "isa = PBXBuildFile; fileRef = %s0002; " % p),
        (p + "0002", 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Calc.swift; sourceTree = "<group>"; '),
        (p + "0003", "isa = PBXFileReference; explicitFileType = archive.ar; includeInIndex = 0; path = libCalcKit.a; sourceTree = BUILT_PRODUCTS_DIR; "),
        (p + "0004", "isa = PBXBuildFile; fileRef = %s0005; " % p),
        (p + "0005", 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CalcXCTests.swift; sourceTree = "<group>"; '),
        (p + "0006", "isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = CalcTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; "),
        (p + "0007", "isa = PBXBuildFile; fileRef = %s0003; " % p),
        (p + "0008", "isa = PBXBuildFile; fileRef = %s0009; " % p),
        (p + "0009", 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CalcSwiftTests.swift; sourceTree = "<group>"; '),
        (p + "0010", 'isa = PBXGroup; children = (%s0011, %s0012, %s0013); sourceTree = "<group>"; ' % (p, p, p)),
        (p + "0011", 'isa = PBXGroup; children = (%s0002); path = CalcKit; sourceTree = "<group>"; ' % p),
        (p + "0012", 'isa = PBXGroup; children = (%s0005, %s0009); path = CalcTests; sourceTree = "<group>"; ' % (p, p)),
        (p + "0013", 'isa = PBXGroup; children = (%s0003, %s0006); name = Products; sourceTree = "<group>"; ' % (p, p)),
        (p + "0020", 'isa = PBXNativeTarget; buildConfigurationList = %s0021; buildPhases = (%s0022); buildRules = (); dependencies = (); name = CalcKit; productName = CalcKit; productReference = %s0003; productType = "com.apple.product-type.library.static"; ' % (p, p, p)),
        (p + "0021", "isa = XCConfigurationList; buildConfigurations = (%s0023, %s0024); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; " % (p, p)),
        (p + "0022", "isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (%s0001); runOnlyForDeploymentPostprocessing = 0; " % p),
        (p + "0023", 'isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; }; name = Debug; '),
        (p + "0024", 'isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; }; name = Release; '),
        (p + "0030", 'isa = PBXNativeTarget; buildConfigurationList = %s0031; buildPhases = (%s0032, %s0035); buildRules = (); dependencies = (%s0036); name = CalcTests; productName = CalcTests; productReference = %s0006; productType = "com.apple.product-type.bundle.unit-test"; ' % (p, p, p, p, p)),
        (p + "0031", "isa = XCConfigurationList; buildConfigurations = (%s0033, %s0034); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; " % (p, p)),
        (p + "0032", "isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (%s0004, %s0008); runOnlyForDeploymentPostprocessing = 0; " % (p, p)),
        (p + "0033", 'isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = "org.example.CalcTests"; GENERATE_INFOPLIST_FILE = YES; }; name = Debug; '),
        (p + "0034", 'isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = "org.example.CalcTests"; GENERATE_INFOPLIST_FILE = YES; }; name = Release; '),
        (p + "0035", "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (%s0007); runOnlyForDeploymentPostprocessing = 0; " % p),
        (p + "0036", "isa = PBXTargetDependency; target = %s0020; targetProxy = %s0037; " % (p, p)),
        (p + "0037", "isa = PBXContainerItemProxy; containerPortal = %s0040; proxyType = 1; remoteGlobalIDString = %s0020; remoteInfo = CalcKit; " % (p, p)),
        (p + "0040", 'isa = PBXProject; buildConfigurationList = %s0041; compatibilityVersion = "Xcode 15.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = %s0010; productRefGroup = %s0013; projectDirPath = ""; projectRoot = ""; targets = (%s0020, %s0030); ' % (p, p, p, p, p)),
        (p + "0041", "isa = XCConfigurationList; buildConfigurations = (%s0042, %s0043); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; " % (p, p)),
    ]
    debug, release = project_config('SWIFT_VERSION = 6.0; ENABLE_TESTABILITY = YES; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; DEBUG_INFORMATION_FORMAT = dwarf; CODE_SIGN_IDENTITY = "-"; ')
    release = release.replace("ENABLE_TESTABILITY = YES; ", "").replace('SWIFT_OPTIMIZATION_LEVEL = "-Onone"; ', "")
    o += [(p + "0042", debug), (p + "0043", release)]
    return {
        "Calc.xcodeproj/project.pbxproj": pbxproj(o, p + "0040"),
        "CalcKit/Calc.swift": "public enum Calc {\n    public static func add(_ a: Int, _ b: Int) -> Int { a + b }\n    public static func mul(_ a: Int, _ b: Int) -> Int { a * b }\n}\n",
        "CalcTests/CalcXCTests.swift": (
            "import XCTest\n@testable import CalcKit\n\n"
            "final class AddTests: XCTestCase {\n    func testAdd() { XCTAssertEqual(Calc.add(2, 3), 5) }\n    func testAddZero() { XCTAssertEqual(Calc.add(0, 7), 7) }\n}\n\n"
            "final class MulTests: XCTestCase {\n    func testMul() { XCTAssertEqual(Calc.mul(2, 3), 6) }\n    func testSkipped() throws { throw XCTSkip(\"not today\") }\n}\n\n"
            "final class FailingTests: XCTestCase {\n    func testWrong() { XCTAssertEqual(Calc.add(2, 2), 5, \"arithmetic\") }\n}\n"),
        "CalcTests/CalcSwiftTests.swift": (
            "import Testing\n@testable import CalcKit\n\n"
            "@Suite struct SwiftCalcTests {\n    @Test func adds() { #expect(Calc.add(1, 1) == 2) }\n    @Test(arguments: [1, 2, 3]) func doubles(n: Int) { #expect(Calc.mul(n, 2) == n + n) }\n}\n\n"
            "@Test func freeFunction() { #expect(Calc.mul(0, 9) == 0) }\n\n"
            "@Suite struct SwiftFailing {\n    @Test func wrong() { #expect(Calc.mul(2, 2) == 5) }\n}\n"),
    }


def cov_sample():
    """The Calc project with multi-line functions, an untested function and
    a struct, for line and column coverage."""
    files = dict(calc_sample())
    files["CalcKit/Calc.swift"] = (
        "public enum Calc {\n"
        "    public static func add(_ a: Int, _ b: Int) -> Int { a + b }\n"
        "    public static func mul(_ a: Int, _ b: Int) -> Int { a * b }\n\n"
        "    public static func classify(_ n: Int) -> String {\n"
        "        if n < 0 {\n            return \"negative\"\n        } else if n == 0 {\n            return \"zero\"\n        }\n"
        "        let doubled = n * 2\n        return doubled > 10 ? \"big\" : \"small\"\n    }\n\n"
        "    public static func unused(_ x: Int) -> Int {\n        var total = 0\n        for i in 0..<x {\n            total += i\n        }\n        return total\n    }\n\n"
        "    // A comment line inside the type.\n\n"
        "    public static var label: String {\n        \"calc\"\n    }\n}\n\n"
        "public struct Counter {\n    public private(set) var value = 0\n    public init() {}\n"
        "    public mutating func bump(by step: Int = 1) {\n        value += step\n        if value > 100 { value = 100 }\n    }\n}\n")
    files["CalcTests/CalcXCTests.swift"] = (
        "import XCTest\n@testable import CalcKit\n\n"
        "final class AddTests: XCTestCase {\n    func testAdd() { XCTAssertEqual(Calc.add(2, 3), 5) }\n"
        "    func testClassify() {\n        XCTAssertEqual(Calc.classify(5), \"small\")\n        XCTAssertEqual(Calc.classify(-1), \"negative\")\n    }\n}\n\n"
        "final class CounterTests: XCTestCase {\n    func testBump() {\n        var c = Counter()\n        c.bump()\n        c.bump(by: 3)\n        XCTAssertEqual(c.value, 4)\n    }\n}\n")
    files["CalcTests/CalcSwiftTests.swift"] = "import Testing\n@testable import CalcKit\n\n@Test func multiplies() {\n    #expect(Calc.mul(3, 4) == 12)\n}\n"
    return files


def package_samples():
    """Three Swift packages: a library with tests, a library and a tool
    with tests, and a tool using the first package by path."""
    greeter = {
        "Package.swift": ("// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(\n    name: \"Greeter\",\n"
                          "    platforms: [.macOS(.v14)],\n    products: [.library(name: \"Greeter\", targets: [\"Greeter\"])],\n"
                          "    targets: [\n        .target(name: \"Greeter\"),\n        .testTarget(name: \"GreeterTests\", dependencies: [\"Greeter\"]),\n    ]\n)\n"),
        "Sources/Greeter/Greeter.swift": "public struct Greeter {\n    public init() {}\n    public func greet(_ name: String) -> String { \"Hello, \\(name)!\" }\n}\n",
        "Tests/GreeterTests/GreeterTests.swift": ("import Testing\nimport XCTest\n@testable import Greeter\n\n"
                                                 "@Test func greets() { #expect(Greeter().greet(\"Ycode\") == \"Hello, Ycode!\") }\n\n"
                                                 "final class GreeterXCTests: XCTestCase {\n    func testEmpty() { XCTAssertEqual(Greeter().greet(\"\"), \"Hello, !\") }\n}\n"),
    }
    tools = {
        "Package.swift": ("// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(\n    name: \"Tools\",\n"
                          "    platforms: [.macOS(.v14)],\n    products: [\n        .library(name: \"GreetKit\", targets: [\"GreetKit\"]),\n"
                          "        .executable(name: \"greet\", targets: [\"greet\"]),\n    ],\n    targets: [\n        .target(name: \"GreetKit\"),\n"
                          "        .executableTarget(name: \"greet\", dependencies: [\"GreetKit\"]),\n"
                          "        .testTarget(name: \"GreetKitTests\", dependencies: [\"GreetKit\"]),\n    ]\n)\n"),
        "Sources/GreetKit/GreetKit.swift": "public func greeting(for name: String) -> String { \"Hi \\(name)\" }\n",
        "Sources/greet/main.swift": "import GreetKit\n\nprint(greeting(for: CommandLine.arguments.dropFirst().first ?? \"world\"))\n",
        "Tests/GreetKitTests/GreetKitTests.swift": ("import XCTest\n@testable import GreetKit\n\nfinal class GreetKitTests: XCTestCase {\n"
                                                   "    func testGreeting() { XCTAssertEqual(greeting(for: \"a\"), \"Hi a\") }\n"
                                                   "    func testFails() { XCTAssertEqual(greeting(for: \"b\"), \"Hi c\") }\n}\n"),
    }
    uses = {
        "Package.swift": ("// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(\n    name: \"Uses\",\n"
                          "    platforms: [.macOS(.v14)],\n    dependencies: [.package(path: \"../Greeter\")],\n    targets: [\n"
                          "        .executableTarget(name: \"Uses\", dependencies: [.product(name: \"Greeter\", package: \"Greeter\")]),\n    ]\n)\n"),
        "Sources/Uses/main.swift": "import Greeter\n\nprint(Greeter().greet(\"package\"))\n",
    }
    local_dep = {
        "LocalDep.xcodeproj/project.pbxproj": LOCAL_DEP_PBXPROJ,
        "App/main.swift": "import Greeter\nprint(Greeter().greet(\"local\"))\n",
    }
    return {"pkg/Greeter": greeter, "pkg/Tools": tools, "pkg/Uses": uses, "LocalDep": local_dep,
            "Loc": LOC_FILES, "../in": {"fr.xliff": LOC_TRANSLATED_XLIFF}}


# An application with a String Catalog and a localized .strings file.
LOC_FILES = {'Loc.xcodeproj/project.pbxproj': '// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 77;\n\tobjects = {\n\t\tF10000000000000000000001 = {isa = PBXBuildFile; fileRef = F10000000000000000000002; };\n\t\tF10000000000000000000002 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = main.swift; sourceTree = "<group>"; };\n\t\tF10000000000000000000003 = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Loc.app; sourceTree = BUILT_PRODUCTS_DIR; };\n\t\tF10000000000000000000004 = {isa = PBXGroup; children = (F10000000000000000000005, F10000000000000000000006); sourceTree = "<group>"; };\n\t\tF10000000000000000000005 = {isa = PBXGroup; children = (F10000000000000000000002, F10000000000000000000020, F10000000000000000000022); path = Loc; sourceTree = "<group>"; };\n\t\tF10000000000000000000006 = {isa = PBXGroup; children = (F10000000000000000000003); name = Products; sourceTree = "<group>"; };\n\t\tF10000000000000000000007 = {isa = PBXNativeTarget; buildConfigurationList = F10000000000000000000008; buildPhases = (F10000000000000000000009, F10000000000000000000010); buildRules = (); dependencies = (); name = Loc; productName = Loc; productReference = F10000000000000000000003; productType = "com.apple.product-type.application"; };\n\t\tF10000000000000000000008 = {isa = XCConfigurationList; buildConfigurations = (F1000000000000000000000A, F1000000000000000000000B); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };\n\t\tF10000000000000000000009 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (F10000000000000000000001); runOnlyForDeploymentPostprocessing = 0; };\n\t\tF10000000000000000000010 = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (F10000000000000000000021, F10000000000000000000023); runOnlyForDeploymentPostprocessing = 0; };\n\t\tF10000000000000000000020 = {isa = PBXFileReference; lastKnownFileType = text.json.xcstrings; path = Localizable.xcstrings; sourceTree = "<group>"; };\n\t\tF10000000000000000000021 = {isa = PBXBuildFile; fileRef = F10000000000000000000020; };\n\t\tF10000000000000000000022 = {isa = PBXVariantGroup; children = (F10000000000000000000024, F10000000000000000000025); name = Greetings.strings; sourceTree = "<group>"; };\n\t\tF10000000000000000000023 = {isa = PBXBuildFile; fileRef = F10000000000000000000022; };\n\t\tF10000000000000000000024 = {isa = PBXFileReference; lastKnownFileType = text.plist.strings; name = en; path = en.lproj/Greetings.strings; sourceTree = "<group>"; };\n\t\tF10000000000000000000025 = {isa = PBXFileReference; lastKnownFileType = text.plist.strings; name = fr; path = fr.lproj/Greetings.strings; sourceTree = "<group>"; };\n\t\tF1000000000000000000000A = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = org.ycode.samples.Loc; GENERATE_INFOPLIST_FILE = YES; CODE_SIGN_IDENTITY = "-"; SWIFT_VERSION = 5.0; SWIFT_EMIT_LOC_STRINGS = YES; LOCALIZATION_PREFERS_STRING_CATALOGS = YES; }; name = Debug; };\n\t\tF1000000000000000000000B = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = org.ycode.samples.Loc; GENERATE_INFOPLIST_FILE = YES; CODE_SIGN_IDENTITY = "-"; SWIFT_VERSION = 5.0; SWIFT_EMIT_LOC_STRINGS = YES; LOCALIZATION_PREFERS_STRING_CATALOGS = YES; }; name = Release; };\n\t\tF1000000000000000000000C = {isa = PBXProject; buildConfigurationList = F1000000000000000000000D; compatibilityVersion = "Xcode 15.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, fr, Base); mainGroup = F10000000000000000000004; productRefGroup = F10000000000000000000006; projectDirPath = ""; projectRoot = ""; targets = (F10000000000000000000007); };\n\t\tF1000000000000000000000D = {isa = XCConfigurationList; buildConfigurations = (F1000000000000000000000E, F1000000000000000000000F); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };\n\t\tF1000000000000000000000E = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; ONLY_ACTIVE_ARCH = YES; }; name = Debug; };\n\t\tF1000000000000000000000F = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; }; name = Release; };\n\t};\n\trootObject = F1000000000000000000000C;\n}\n', 'Loc/main.swift': 'import Foundation\n\n// Hand-written sample for localization export probes.\nprint(String(localized: "Hello, world!", comment: "Greeting shown at launch"))\nprint(String(localized: "Files: \\(3)", comment: "Number of files"))\nprint(NSLocalizedString("Goodbye", tableName: "Greetings", comment: "Farewell"))\n', 'Loc/Localizable.xcstrings': '{\n  "sourceLanguage" : "en",\n  "strings" : {\n    "Files: %lld" : {\n      "comment" : "Number of files",\n      "localizations" : {\n        "fr" : {\n          "stringUnit" : {\n            "state" : "translated",\n            "value" : "Fichiers : %lld"\n          }\n        }\n      }\n    },\n    "Hello, world!" : {\n      "comment" : "Greeting shown at launch",\n      "localizations" : {\n        "fr" : {\n          "stringUnit" : {\n            "state" : "needs_review",\n            "value" : "Bonjour, le monde !"\n          }\n        }\n      }\n    },\n    "Unused key" : {\n      "extractionState" : "manual",\n      "localizations" : {\n        "en" : {\n          "stringUnit" : {\n            "state" : "translated",\n            "value" : "Unused key value"\n          }\n        }\n      }\n    }\n  },\n  "version" : "1.0"\n}\n', 'Loc/en.lproj/Greetings.strings': '/* Farewell */\n"Goodbye" = "Goodbye";\n', 'Loc/fr.lproj/Greetings.strings': '/* Farewell */\n"Goodbye" = "Au revoir";\n'}

# A translator's edits to the exported French XLIFF.
LOC_TRANSLATED_XLIFF = '<?xml version="1.0" encoding="UTF-8"?>\n<xliff xmlns="urn:oasis:names:tc:xliff:document:1.2" version="1.2">\n  <file original="Loc/en.lproj/Greetings.strings" source-language="en" target-language="fr" datatype="plaintext">\n    <body>\n      <trans-unit id="Goodbye" xml:space="preserve">\n        <source>Goodbye</source>\n        <target>Salut</target>\n        <note>Farewell</note>\n      </trans-unit>\n    </body>\n  </file>\n  <file original="Loc/Loc-InfoPlist.xcstrings" source-language="en" target-language="fr" datatype="plaintext">\n    <body>\n      <trans-unit id="CFBundleName" xml:space="preserve">\n        <source>Loc</source>\n        <target>Loc FR</target>\n        <note>Bundle name</note>\n      </trans-unit>\n    </body>\n  </file>\n  <file original="Loc/Localizable.xcstrings" source-language="en" target-language="fr" datatype="plaintext">\n    <body>\n      <trans-unit id="Hello, world!" xml:space="preserve">\n        <source>Hello, world!</source>\n        <target state="translated">Bonjour le monde !</target>\n        <note>Greeting shown at launch</note>\n      </trans-unit>\n      <trans-unit id="Unused key" xml:space="preserve">\n        <source>Unused key value</source>\n        <target>Valeur inutilisée</target>\n        <note/>\n      </trans-unit>\n    </body>\n  </file>\n</xliff>\n'


# A tool target using the Greeter package through a local reference.
LOCAL_DEP_PBXPROJ = '// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 77;\n\tobjects = {\n\t\tD10000000000000000000001 = {isa = PBXBuildFile; fileRef = D10000000000000000000002; };\n\t\tD10000000000000000000002 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = main.swift; sourceTree = "<group>"; };\n\t\tD10000000000000000000003 = {isa = PBXFileReference; explicitFileType = "compiled.mach-o.executable"; includeInIndex = 0; path = App; sourceTree = BUILT_PRODUCTS_DIR; };\n\t\tD10000000000000000000004 = {isa = PBXGroup; children = (D10000000000000000000005, D10000000000000000000006); sourceTree = "<group>"; };\n\t\tD10000000000000000000005 = {isa = PBXGroup; children = (D10000000000000000000002); path = App; sourceTree = "<group>"; };\n\t\tD10000000000000000000006 = {isa = PBXGroup; children = (D10000000000000000000003); name = Products; sourceTree = "<group>"; };\n\t\tD10000000000000000000007 = {isa = PBXNativeTarget; buildConfigurationList = D10000000000000000000008; buildPhases = (D10000000000000000000009, D10000000000000000000010); buildRules = (); dependencies = (); name = App; packageProductDependencies = (D10000000000000000000012); productName = App; productReference = D10000000000000000000003; productType = "com.apple.product-type.tool"; };\n\t\tD10000000000000000000008 = {isa = XCConfigurationList; buildConfigurations = (D1000000000000000000000A, D1000000000000000000000B); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };\n\t\tD10000000000000000000009 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (D10000000000000000000001); runOnlyForDeploymentPostprocessing = 0; };\n\t\tD10000000000000000000010 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (D10000000000000000000013); runOnlyForDeploymentPostprocessing = 0; };\n\t\tD10000000000000000000011 = {isa = XCLocalSwiftPackageReference; relativePath = ../pkg/Greeter; };\n\t\tD10000000000000000000012 = {isa = XCSwiftPackageProductDependency; productName = Greeter; };\n\t\tD10000000000000000000013 = {isa = PBXBuildFile; productRef = D10000000000000000000012; };\n\t\tD1000000000000000000000A = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; SWIFT_VERSION = 5.0; }; name = Debug; };\n\t\tD1000000000000000000000B = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; SWIFT_VERSION = 5.0; }; name = Release; };\n\t\tD1000000000000000000000C = {isa = PBXProject; buildConfigurationList = D1000000000000000000000D; compatibilityVersion = "Xcode 15.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = D10000000000000000000004; packageReferences = (D10000000000000000000011); productRefGroup = D10000000000000000000006; projectDirPath = ""; projectRoot = ""; targets = (D10000000000000000000007); };\n\t\tD1000000000000000000000D = {isa = XCConfigurationList; buildConfigurations = (D1000000000000000000000E, D1000000000000000000000F); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };\n\t\tD1000000000000000000000E = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; ONLY_ACTIVE_ARCH = YES; }; name = Debug; };\n\t\tD1000000000000000000000F = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; }; name = Release; };\n\t};\n\trootObject = D1000000000000000000000C;\n}\n'


def single_target_sample(name, product_type, product, file_type, source, source_name, source_type, target_settings, project_extra):
    p = "A1000000000000000000"
    o = [
        (p + "0001", "isa = PBXBuildFile; fileRef = %s0002; " % p),
        (p + "0002", 'isa = PBXFileReference; lastKnownFileType = %s; path = %s; sourceTree = "<group>"; ' % (source_type, source_name)),
        (p + "0003", "isa = PBXFileReference; explicitFileType = %s; includeInIndex = 0; path = %s; sourceTree = BUILT_PRODUCTS_DIR; " % (file_type, product)),
        (p + "0004", 'isa = PBXGroup; children = (%s0005, %s0006); sourceTree = "<group>"; ' % (p, p)),
        (p + "0005", 'isa = PBXGroup; children = (%s0002); path = %s; sourceTree = "<group>"; ' % (p, name)),
        (p + "0006", 'isa = PBXGroup; children = (%s0003); name = Products; sourceTree = "<group>"; ' % p),
        (p + "0007", 'isa = PBXNativeTarget; buildConfigurationList = %s0008; buildPhases = (%s0009); buildRules = (); dependencies = (); name = %s; productName = %s; productReference = %s0003; productType = "%s"; ' % (p, p, name, name, p, product_type)),
        (p + "0008", "isa = XCConfigurationList; buildConfigurations = (%s000A, %s000B); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; " % (p, p)),
        (p + "0009", "isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (%s0001); runOnlyForDeploymentPostprocessing = 0; " % p),
        (p + "000A", 'isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; %s}; name = Debug; ' % target_settings),
        (p + "000B", 'isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; %s}; name = Release; ' % target_settings),
        (p + "000C", 'isa = PBXProject; buildConfigurationList = %s000D; compatibilityVersion = "Xcode 15.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = %s0004; productRefGroup = %s0006; projectDirPath = ""; projectRoot = ""; targets = (%s0007); ' % (p, p, p, p)),
        (p + "000D", "isa = XCConfigurationList; buildConfigurations = (%s000E, %s000F); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; " % (p, p)),
    ]
    debug, release = project_config(project_extra)
    o += [(p + "000E", debug), (p + "000F", release)]
    return {name + ".xcodeproj/project.pbxproj": pbxproj(o, p + "000C"), name + "/" + source_name: source}


def samples():
    tool = lambda src: single_target_sample("Tool", "com.apple.product-type.tool", "Tool", '"compiled.mach-o.executable"', src, "main.c", "sourcecode.c.c", "", "")
    hello = single_target_sample(
        "Hello", "com.apple.product-type.application", "Hello.app", "wrapper.application",
        "import AppKit\n\nlet app = NSApplication.shared\napp.setActivationPolicy(.regular)\nprint(\"Hello\")\n", "main.swift", "sourcecode.swift",
        'PRODUCT_BUNDLE_IDENTIFIER = org.ycode.samples.Hello; GENERATE_INFOPLIST_FILE = YES; MARKETING_VERSION = 1.2; CURRENT_PROJECT_VERSION = 7; CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Automatic; SWIFT_VERSION = 5.0; ',
        'DEBUG_INFORMATION_FORMAT = dwarf; ')
    return {
        "Calc": calc_sample(),
        "Cov": cov_sample(),
        **package_samples(),
        "Hello": hello,
        "Tool": tool('#include <stdio.h>\nint main(void) { printf("hello\\n"); return 0; }\n'),
        "ToolBad": tool('#include <stdio.h>\nint main(void) { printf("hello\\n"); return nope; }\n'),
        "eo": {
            "mac-application.plist": plist({"method": "mac-application"}),
            "adhoc-manual.plist": plist({"method": "mac-application", "signingStyle": "manual", "signingCertificate": "-"}),
            "debugging.plist": plist({"method": "debugging"}),
        },
    }


def plist(d):
    import plistlib
    return plistlib.dumps(d).decode()


# (kind, sample directory, arguments; {W} = the tool's work directory)
BUILD_CASES = [
    ("test", "Calc", ["-scheme", "CalcTests", "-derivedDataPath", "{W}/dd/calc", "test"]),
    ("test-resultBundle", "Calc", ["-scheme", "CalcTests", "-derivedDataPath", "{W}/dd/calc", "-resultBundlePath", "{W}/rb/test.xcresult", "test"]),
    ("test-resultBundle-pass", "Calc", ["-scheme", "CalcTests", "-derivedDataPath", "{W}/dd/calc", "-resultBundlePath", "{W}/rb/pass.xcresult",
                                        "-skip-testing:CalcTests/FailingTests", "-skip-testing:CalcTests/SwiftFailing", "test"]),
    ("test-only-class", "Calc", ["-scheme", "CalcTests", "-derivedDataPath", "{W}/dd/calc", "-only-testing:CalcTests/AddTests", "test"]),
    ("test-only-method", "Calc", ["-scheme", "CalcTests", "-derivedDataPath", "{W}/dd/calc", "-only-testing:CalcTests/AddTests/testAdd", "test"]),
    ("test-only-swift", "Calc", ["-scheme", "CalcTests", "-derivedDataPath", "{W}/dd/calc", "-only-testing:CalcTests/SwiftCalcTests", "test"]),
    ("test-quiet", "Calc", ["-scheme", "CalcTests", "-derivedDataPath", "{W}/dd/calc", "-quiet", "test"]),
    ("test-coverage", "Cov", ["-scheme", "CalcTests", "-derivedDataPath", "{W}/dd/cov", "-enableCodeCoverage", "YES",
                              "-resultBundlePath", "{W}/rb/coverage.xcresult", "test"]),
    ("test-no-coverage", "Cov", ["-scheme", "CalcTests", "-derivedDataPath", "{W}/dd/cov", "-enableCodeCoverage", "NO",
                                 "-resultBundlePath", "{W}/rb/nocoverage.xcresult", "test"]),
    ("pkg-list-Greeter", "pkg/Greeter", ["-list"]),
    ("pkg-list-Tools", "pkg/Tools", ["-list"]),
    ("pkg-list-Uses", "pkg/Uses", ["-list"]),
    ("pkg-list-json-Tools", "pkg/Tools", ["-list", "-json"]),
    ("pkg-list-json-Uses", "pkg/Uses", ["-list", "-json"]),
    ("error:pkg-settings-no-scheme", "pkg/Greeter", ["-showBuildSettings"]),
    ("error:pkg-no-destination", "pkg/Greeter", ["-scheme", "Greeter", "-derivedDataPath", "{W}/dd/greeter", "build"]),
    ("error:pkg-unknown-scheme", "pkg/Greeter", ["-scheme", "Nope", "build"]),
    ("pkg-settings-json", "pkg/Greeter", ["-showBuildSettings", "-json", "-scheme", "Greeter", "-destination", "platform=macOS", "-derivedDataPath", "{W}/dd/greeter"]),
    ("pkg-build-library", "pkg/Greeter", ["-scheme", "Greeter", "-destination", "platform=macOS", "-derivedDataPath", "{W}/dd/greeter", "build"]),
    ("pkg-test", "pkg/Greeter", ["-scheme", "Greeter", "-destination", "platform=macOS", "-derivedDataPath", "{W}/dd/greeter",
                                 "-resultBundlePath", "{W}/rb/pkg-test.xcresult", "test"]),
    ("pkg-build-tool", "pkg/Tools", ["-scheme", "greet", "-destination", "platform=macOS", "-derivedDataPath", "{W}/dd/tools", "build"]),
    ("pkg-test-package-scheme", "pkg/Tools", ["-scheme", "Tools-Package", "-destination", "platform=macOS", "-derivedDataPath", "{W}/dd/tools", "test"]),
    ("pkg-test-coverage-package-scheme", "pkg/Tools", ["-scheme", "Tools-Package", "-destination", "platform=macOS", "-derivedDataPath", "{W}/dd/tools",
                                                       "-resultBundlePath", "{W}/rb/pkg-tools.xcresult", "test"]),
    ("pkg-test-coverage-executable", "pkg/Tools", ["-scheme", "greet", "-destination", "platform=macOS", "-derivedDataPath", "{W}/dd/tools",
                                                   "-resultBundlePath", "{W}/rb/pkg-greet.xcresult", "test"]),
    ("error:pkg-test-not-configured", "pkg/Tools", ["-scheme", "GreetKit", "-destination", "platform=macOS", "-derivedDataPath", "{W}/dd/tools", "test"]),
    ("pkg-build-dependency", "pkg/Uses", ["-scheme", "Uses", "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", "{W}/dd/uses", "build"]),
    ("resolve-project-local", "LocalDep", ["-resolvePackageDependencies", "-clonedSourcePackagesDirPath", "{W}/cloned"]),
    ("resolve-package", "pkg/Uses", ["-resolvePackageDependencies", "-clonedSourcePackagesDirPath", "{W}/cloned2"]),
    ("resolve-none", "Tool", ["-resolvePackageDependencies"]),
    ("docbuild-package", "pkg/Greeter", ["-scheme", "Greeter", "-destination", "platform=macOS", "-derivedDataPath", "{W}/dd/docpkg", "docbuild"]),
    ("docbuild-library", "Calc", ["-scheme", "CalcKit", "-derivedDataPath", "{W}/dd/doccalc", "docbuild"]),
    ("loc-export", "Loc", ["-exportLocalizations", "-localizationPath", "{W}/loc", "-project", "Loc.xcodeproj", "-exportLanguage", "fr"]),
    ("loc-export-source", "Loc", ["-exportLocalizations", "-localizationPath", "{W}/locsrc", "-project", "Loc.xcodeproj"]),
    ("loc-import", "Loc", ["-importLocalizations", "-localizationPath", "{W}/in/fr.xliff", "-project", "Loc.xcodeproj"]),
    ("build-for-testing", "Calc", ["-scheme", "CalcTests", "-derivedDataPath", "{W}/dd/calc", "build-for-testing"]),
    ("test-without-building", "Calc", ["-scheme", "CalcTests", "-derivedDataPath", "{W}/dd/calc", "-skip-testing:CalcTests/FailingTests",
                                       "-skip-testing:CalcTests/SwiftFailing", "test-without-building"]),
    ("error:test-plan", "Calc", ["-scheme", "CalcTests", "-derivedDataPath", "{W}/dd/calc", "-testPlan", "Nope", "test"]),
    ("build-resultBundle", "Calc", ["-scheme", "CalcKit", "-derivedDataPath", "{W}/dd/calc", "-resultBundlePath", "{W}/rb/build.xcresult", "build"]),
    ("build-fail-resultBundle", "ToolBad", ["-scheme", "Tool", "-derivedDataPath", "{W}/dd/toolbad", "-resultBundlePath", "{W}/rb/fail.xcresult", "build"]),
    ("clean-build-resultBundle", "Tool", ["-scheme", "Tool", "-derivedDataPath", "{W}/dd/tool", "-resultBundlePath", "{W}/rb/clean.xcresult", "clean", "build"]),
    ("build-resultBundle-quiet", "Tool", ["-scheme", "Tool", "-derivedDataPath", "{W}/dd/tool", "-resultBundlePath", "{W}/rb/quiet.xcresult", "-quiet", "build"]),
    ("error:resultBundle-exists", "Tool", ["-scheme", "Tool", "-derivedDataPath", "{W}/dd/tool", "-resultBundlePath", "{W}/rb/quiet.xcresult", "build"]),
    ("build-legacy-resultBundle", "Tool", ["-resultBundlePath", "{W}/rb/legacy.xcresult", "build"]),
    ("archive-settings", "Hello", ["-scheme", "Hello", "-derivedDataPath", "{W}/dd/hello", "-showBuildSettings", "-json", "archive"]),
    ("archive-app", "Hello", ["-scheme", "Hello", "-derivedDataPath", "{W}/dd/hello", "-archivePath", "{W}/ar/Hello.xcarchive", "archive"]),
    ("archive-tool", "Tool", ["-scheme", "Tool", "-derivedDataPath", "{W}/dd/tool", "-archivePath", "{W}/ar/Tool.xcarchive", "archive"]),
    ("archive-resultBundle", "Hello", ["-scheme", "Hello", "-derivedDataPath", "{W}/dd/hello2", "-archivePath", "{W}/ar/Hello2.xcarchive",
                                       "-resultBundlePath", "{W}/rb/archive.xcresult", "archive"]),
    ("export-mac-application", "Hello", ["-exportArchive", "-archivePath", "{W}/ar/Hello.xcarchive", "-exportPath", "{W}/ar/export-app",
                                         "-exportOptionsPlist", "{W}/eo/mac-application.plist"]),
    ("export-adhoc-manual", "Hello", ["-exportArchive", "-archivePath", "{W}/ar/Hello.xcarchive", "-exportPath", "{W}/ar/export-adhoc",
                                      "-exportOptionsPlist", "{W}/eo/adhoc-manual.plist"]),
    ("error:export-debugging", "Hello", ["-exportArchive", "-archivePath", "{W}/ar/Hello.xcarchive", "-exportPath", "{W}/ar/export-dbg",
                                         "-exportOptionsPlist", "{W}/eo/debugging.plist"]),
    ("error:export-missing-archive", "Hello", ["-exportArchive", "-archivePath", "{W}/ar/Nope.xcarchive", "-exportPath", "{W}/ar/export-none",
                                               "-exportOptionsPlist", "{W}/eo/mac-application.plist"]),
    ("error:export-no-path", "Hello", ["-exportArchive", "-archivePath", "{W}/ar/Hello.xcarchive", "-exportOptionsPlist", "{W}/eo/mac-application.plist"]),
]

XCRESULT_QUERIES = [("build-results", ["get", "build-results"]), ("summary", ["get", "test-results", "summary"]),
                    ("tests", ["get", "test-results", "tests"]), ("availability", ["get", "content-availability"])]
VOLATILE_KEYS = {"startTime", "endTime", "finishTime", "duration", "durationInSeconds", "testIdentifier", "topInsights"}


def observe(tool, kind, sample, args, work):
    """Runs one case and records what is compared: streams, exit status,
    result bundles (as xcresulttool reports them), archives (file tree and
    Info.plist), test run file keys, exported folders."""
    import plistlib
    argv = [x.replace("{W}", work) for x in args]
    # Keep each tool's default DerivedData folder inside the work directory
    # (never the user's Library): the documented -userdefault=value form,
    # removed again from the invocation line it echoes.
    extra = ""
    if "-derivedDataPath" not in argv:
        extra = f" -IDECustomDerivedDataLocation={work}/dd/default"
    r = run(tool, argv + ([extra.strip()] if extra else []), os.path.join(work, "samples", sample), timeout=1800)
    if extra:
        r["out"] = r["out"].replace(extra, "", 1)
    obs = {"out": r["out"], "err": r["err"], "code": r["code"], "bundles": {}, "trees": {}, "plists": {}, "xctestrun": None}
    for i, x in enumerate(argv):
        if x.endswith(".xcresult") and i > 0 and argv[i - 1] == "-resultBundlePath" and os.path.isdir(x) and not kind.startswith("error:"):
            obs["bundles"][os.path.basename(x)] = {
                name: json.loads(subprocess.run(["xcrun", "xcresulttool"] + q + ["--path", x], capture_output=True, text=True).stdout or "null")
                for name, q in XCRESULT_QUERIES}
            # Code coverage as xccov reads it: the report and each file's lines.
            def xccov(args):
                p = subprocess.run(["xcrun", "xccov", "view"] + args + [x], capture_output=True, text=True)
                return json.loads(p.stdout) if p.returncode == 0 and p.stdout.strip() else None
            report = xccov(["--report", "--json"])
            if report is not None:
                obs["bundles"][os.path.basename(x)]["coverage report"] = report
                listing = subprocess.run(["xcrun", "xccov", "view", "--archive", "--file-list", x], capture_output=True, text=True).stdout
                obs["bundles"][os.path.basename(x)]["coverage lines"] = {
                    f: xccov(["--archive", "--json", "--file", f]) for f in sorted(filter(None, listing.split("\n")))}
        if (x.endswith(".xcarchive") and argv[i - 1] == "-archivePath" and kind.startswith("archive")) or (argv[i - 1] == "-exportPath" and not kind.startswith("error:")):
            if os.path.isdir(x):
                obs["trees"][os.path.basename(x)] = sorted(
                    os.path.relpath(os.path.join(d, n), x) + ("/" if os.path.isdir(os.path.join(d, n)) else "")
                    for d, dirs, files in os.walk(x) for n in dirs + files)
                info = os.path.join(x, "Info.plist")
                if os.path.exists(info):
                    d = plistlib.load(open(info, "rb"))
                    d.pop("CreationDate", None)
                    obs["plists"][os.path.basename(x)] = json.loads(json.dumps(d, default=str))
    if kind.startswith("loc-export"):
        # Each catalog's XLIFF (tool line masked), source copies and contents.json (tool info masked).
        out_dir = argv[argv.index("-localizationPath") + 1]
        for b in sorted(os.listdir(out_dir)) if os.path.isdir(out_dir) else []:
            root = os.path.join(out_dir, b)
            got = {}
            for d, ds, fs in os.walk(root):
                for f in fs:
                    p = os.path.join(d, f)
                    text = open(p, encoding="utf-8", errors="replace").read()
                    text = re.sub(r"<tool [^>]*/>", "<tool/>", text)
                    if f == "contents.json":
                        c = json.loads(text); c.pop("toolInfo", None); text = json.dumps(c, sort_keys=True)
                    got[os.path.relpath(p, root)] = text
            obs["plists"][b] = got
    if kind.startswith("loc-import"):
        root = os.path.join(work, "samples", sample)
        got = {}
        for rel in ["Loc/Localizable.xcstrings", "Loc/Loc-InfoPlist.xcstrings", "Loc/fr.lproj/Greetings.strings", "Loc/en.lproj/Greetings.strings"]:
            p = os.path.join(root, rel)
            got[rel] = open(p, encoding="utf-8").read() if os.path.exists(p) else None
        pbx = open(os.path.join(root, "Loc.xcodeproj/project.pbxproj"), encoding="utf-8").read()
        got["project references the generated catalog"] = len(re.findall(r"Loc-InfoPlist\.xcstrings[^\n]*(PBXFileReference|PBXBuildFile)", pbx))
        obs["plists"]["imported files"] = got
    if kind.startswith("docbuild"):
        # Documentation archives under the products folder.
        for d, dirs, files in os.walk(os.path.join(work, "dd")):
            for n in list(dirs):
                if n.endswith(".doccarchive"):
                    x = os.path.join(d, n)
                    obs["trees"][os.path.relpath(x, os.path.join(work, "dd"))] = sorted(
                        os.path.relpath(os.path.join(dd, m), x) for dd, ds, fs in os.walk(x) for m in ds + fs)
                    dirs.remove(n)
    if kind == "build-for-testing":
        products = os.path.join(work, "dd/calc/Build/Products")
        for n in sorted(os.listdir(products)) if os.path.isdir(products) else []:
            if n.endswith(".xctestrun"):
                d = plistlib.load(open(os.path.join(products, n), "rb"))
                keys = set()
                def walk(v, p):
                    if isinstance(v, dict):
                        for k, c in v.items():
                            keys.add(p + "/" + k)
                            walk(c, p + "/" + k)
                    elif isinstance(v, list):
                        for c in v: walk(c, p + "[]")
                walk(d, "")
                obs["xctestrun"] = {"name": n, "keys": sorted(keys)}
    return obs


def mask_paths(text, work):
    roots = {work, os.path.realpath(work)}
    roots |= {r[len("/private"):] for r in list(roots) if r.startswith("/private/")}
    roots |= {"/private" + r for r in list(roots) if r.startswith(("/var/", "/tmp/"))}
    for r in sorted(roots, key=len, reverse=True):
        text = text.replace(r, "<W>")
    text = re.sub(r"/Applications/Xcode[^/]*\.app/Contents/Developer/usr/bin/xcodebuild|\S+/ycodebuild\b", "<tool>", text)
    text = re.sub(r"\d{4}\.\d\d\.\d\d_\d\d-\d\d-\d\d-[-+]\d{4}", "<date>", text)
    text = re.sub(r"Timestamp=[0-9.]+", "Timestamp=<t>", text)
    text = re.sub(r"(?m)^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d (?=[A-Z])", "<time> ", text)
    return text


STDERR_NOISE = re.compile(r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+[-+ 0-9]*\S+\[\d+[:\d]*\]|^(Details|Object|Method|Thread):  ?|^Please file a bug|^ycodebuild: warning:")


def unordered_blocks(lines):
    """Runs of destination lines (`{ platform:...}`), of resolved-package
    lines (`  Name: path`) and of target-level warnings of targets built in
    parallel (`warning: ... (in target 'T' from project 'P')`), whose order
    varies from run to run, sorted."""
    out, run = [], []
    def flush():
        out.extend(sorted(run)); run.clear()
    for l in lines:
        if l.startswith("resolved source packages: "):
            l = "resolved source packages: " + ", ".join(sorted(l[len("resolved source packages: "):].split(", ")))
        if l.startswith("{ platform:") or (l.startswith("  ") and not l.startswith("   ") and ": " in l) \
                or (l.startswith("warning: ") and re.search(r"\(in target '[^']*' from project '[^']*'\)$", l)):
            run.append(l)
        else:
            flush(); out.append(l)
    flush()
    return out


def test_section(out, work):
    """The runner output between the build log and the session lines,
    timings masked; concurrent swift-testing lines as a multiset."""
    lines, on = [], False
    for l in out.split("\n"):
        # The runner's output-barrier marker can split into other lines.
        l = l.replace("\u200b", "").replace("XCTestOutputBarrier", "")
        l = re.sub(r"^[A-Za-z]+(?=[◇✔✘↳])", "", l)
        if l.startswith("Test Suite '") or l.startswith("◇ Test run started") or l.startswith("Test Case"):
            on = True
        if not on:
            continue
        if l.startswith("Test session results") or l.startswith("** TEST") or l == "Testing started":
            break
        if re.match(r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+", l):
            continue  # runner log lines
        l = re.sub(r"at \d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+", "at T", l)
        l = re.sub(r"\(\d+\.\d+ seconds\)", "(N seconds)", l)
        l = re.sub(r"in \d+\.\d+ \(\d+\.\d+\) seconds", "in N (N) seconds", l)
        l = re.sub(r"after \d+\.\d+ seconds", "after N seconds", l)
        lines.append(mask_paths(l, work))
    while lines and lines[-1] == "":
        lines.pop()
    ordered = [l for l in lines if l[:1] not in "◇✔✘↳"]
    unordered = sorted(l for l in lines if l[:1] in "◇✔✘↳")
    return ordered, unordered


def trailer(out, work):
    """What follows the last build-log section: session/bundle lines,
    banners, `Testing started`, the export lines."""
    lines = out.split("\n")
    marks = [i for i, l in enumerate(lines) if l.startswith(("Result bundle written", "Test session results", "Exported "))]
    banners = [i for i, l in enumerate(lines) if l.startswith("** ")]
    start = marks[-1] if marks else banners[-1] if banners else len(lines)
    if start > 0 and lines[start - 1] == "":
        start -= 1
    return [mask_paths(l, work) for l in lines[start:]]


def banners(out, work):
    """Banners and result-bundle lines of every action, in order."""
    lines = out.split("\n")
    keep = [l for i, l in enumerate(lines)
            if l.startswith(("** ", "Result bundle written", "Test session results", "Writing result bundle"))
            or (i > 0 and lines[i - 1].startswith(("Result bundle written", "Test session results", "Writing result bundle")))]
    return [mask_paths(l, work) for l in keep]


def header(out, work):
    """The invocation header and the lines before the build log."""
    lines = out.split("\n")
    stops = ("ComputePackagePrebuildTargetDependencyGraph", "CreateBuildRequest", "Test Suite", "◇", "Testing started", "Exported ", "** ", "[")
    end = next((i for i, l in enumerate(lines) if l.startswith(stops)), len(lines))
    return [mask_paths(l, work) for l in lines[:end]]


def section_headers(out, work):
    """Unindented build-log lines (task headers, diagnostics) as a multiset,
    paths and hashes masked."""
    heads = []
    for l in out.split("\n"):
        if not l or l.startswith((" ", "\t", "Test ", "◇", "✔", "✘", "↳", "\u200b")) or re.match(r"^\d{4}-\d\d-\d\d ", l):
            continue
        l = re.sub(r"[0-9a-f]{32,}", "<hash>", mask_paths(l, work))
        # Explicit-module file names carry a hash of the build's paths.
        l = re.sub(r"-[A-Z0-9]{8,}(?=\.(pcm|swiftmodule)\b)", "-<hash>", l)
        heads.append(l)
    return sorted(heads)


def normalize_json(v, work):
    if isinstance(v, dict):
        return {mask_paths(k, work): normalize_json(x, work) for k, x in v.items() if k not in VOLATILE_KEYS}
    if isinstance(v, list):
        items = [normalize_json(x, work) for x in v]
        if items and all(isinstance(x, dict) for x in items):
            items.sort(key=lambda x: json.dumps(x, sort_keys=True))
        return items
    if isinstance(v, str):
        return re.sub(r"\d+(\.\d+)?s$", "Ns", mask_paths(v, work))
    return v


def build_main(a):
    import shutil, tempfile
    ycb_tool = os.path.abspath(a.ycodebuild)
    if not os.path.exists(ycb_tool):
        print("build ycodebuild first", file=sys.stderr)
        return 2
    os.makedirs(a.cache, exist_ok=True)
    cache_file = os.path.join(a.cache, "builds-reference.json")
    reference_obs = json.load(open(cache_file)) if os.path.exists(cache_file) else {}
    only = set(filter(None, a.only.split(",")))
    cases = [c for c in BUILD_CASES if not only or c[0] in only]
    if a.refresh:  # re-run the reference for the selected cases only
        for kind, _, _ in cases:
            reference_obs.pop(kind, None)

    def prepare(work):
        for name, files in samples().items():
            for rel, text in files.items():
                path = os.path.join(work, "eo" if name == "eo" else "samples/" + name, rel)
                os.makedirs(os.path.dirname(path), exist_ok=True)
                open(path, "w").write(text)
        for d in ("rb", "ar", "dd"):
            os.makedirs(os.path.join(work, d), exist_ok=True)

    missing = [c for c in cases if c[0] not in reference_obs]
    if missing:
        ref_work = tempfile.mkdtemp(prefix="ycodebuild-conformance-ref-")
        prepare(ref_work)
        for kind, sample, args in missing:
            print(f"reference: {kind}", file=sys.stderr)
            o = observe("xcodebuild", kind, sample, args, ref_work)
            o["work"] = ref_work
            reference_obs[kind] = o
        json.dump(reference_obs, open(cache_file, "w"))

    ycb_work = tempfile.mkdtemp(prefix="ycb-work-", dir=a.cache)
    prepare(ycb_work)
    env_helper = os.environ.get("YCODE_SWB")
    if not env_helper:
        local = os.path.join(YCODE, "Tools/ycode-swb/.build/debug/ycode-swb")
        if os.path.exists(local):
            os.environ["YCODE_SWB"] = local

    rows, failures = [], []
    observed = {}
    for kind, sample, args in cases:
        ref = reference_obs[kind]
        ycb = observe(ycb_tool, kind, sample, args, ycb_work)
        observed[kind] = ycb
        rw, yw = ref["work"], ycb_work
        checks = {}
        checks["exit status"] = ref["code"] == ycb["code"]
        rerr = unordered_blocks([mask_paths(l, rw) for l in ref["err"].split("\n") if not STDERR_NOISE.search(l)])
        yerr = unordered_blocks([mask_paths(l, yw) for l in ycb["err"].split("\n") if not STDERR_NOISE.search(l)])
        if kind.startswith("error:"):
            # Error cases: the first error line (ycodebuild keeps messages short).
            first = lambda lines: next((l for l in lines if "error:" in l), "")
            checks["error line"] = first(rerr) == first(yerr)
        else:
            checks["stderr"] = rerr == yerr
        if kind.startswith(("test", "build-for-testing", "pkg-test")) and not kind.startswith("test-plan"):
            checks["test output"] = test_section(ref["out"], rw) == test_section(ycb["out"], yw)
        checks["header"] = unordered_blocks(header(ref["out"], rw)) == unordered_blocks(header(ycb["out"], yw))
        if "-list" in args or "-resolvePackageDependencies" in args:
            checks["stdout"] = unordered_blocks(mask_paths(ref["out"], rw).split("\n")) == unordered_blocks(mask_paths(ycb["out"], yw).split("\n"))
        checks["trailer"] = trailer(ref["out"], rw) == trailer(ycb["out"], yw)
        checks["banners"] = banners(ref["out"], rw) == banners(ycb["out"], yw)
        if kind == "archive-settings":
            rs = parse_settings_json(ref["out"])
            ys = parse_settings_json(ycb["out"])
            same = [t for t, _ in rs] == [t for t, _ in ys] and all(
                {k: mask_paths(v, rw) for k, v in r.items() if k not in ENGINE_DEPENDENT} == {k: mask_paths(v, yw) for k, v in y.items() if k not in ENGINE_DEPENDENT}
                for (_, r), (_, y) in zip(rs, ys))
            checks["settings"] = same
            checks.pop("trailer")
        for name, queries in ref["bundles"].items():
            for q, value in queries.items():
                checks[f"bundle {q}"] = normalize_json(value, rw) == normalize_json(ycb["bundles"].get(name, {}).get(q), yw)
        for name, tree in ref["trees"].items():
            checks[f"tree {name}"] = tree == ycb["trees"].get(name)
        for name, info in ref["plists"].items():
            checks[f"Info.plist {name}"] = info == ycb["plists"].get(name)
        if ref["xctestrun"]:
            checks["xctestrun name"] = ref["xctestrun"]["name"] == (ycb["xctestrun"] or {}).get("name")
            # The reference adds its own diagnostic environment variables and coverage infos.
            plumbing = re.compile(r"EnvironmentVariables/(?!DYLD_FRAMEWORK_PATH|DYLD_LIBRARY_PATH|__X|XCODE_)|CodeCoverageBuildableInfos\[\]/")
            rk = [k for k in ref["xctestrun"]["keys"] if not plumbing.search(k)]
            checks["xctestrun keys"] = rk == [k for k in (ycb["xctestrun"] or {}).get("keys", []) if not plumbing.search(k)]
        rh, yh = section_headers(ref["out"], rw), section_headers(ycb["out"], yw)
        import collections
        common = sum((collections.Counter(rh) & collections.Counter(yh)).values())
        rows.append((kind, checks, common, len(rh), len(yh)))
        for c, ok in checks.items():
            if not ok:
                failures.append((kind, c))
    # ycodebuild's observations, for inspecting differences.
    json.dump(dict(observed, work=ycb_work), open(os.path.join(a.cache, "builds-ycodebuild.json"), "w"))
    if not a.details:
        shutil.rmtree(ycb_work, ignore_errors=True)

    print("| Case | Checks identical | Build-log section headers shared (ref / ycb) |")
    print("|---|---:|---:|")
    total = ok_total = 0
    per_check = {}
    for kind, checks, common, nr, ny in rows:
        n_ok = sum(1 for v in checks.values() if v)
        total += len(checks)
        ok_total += n_ok
        for c, v in checks.items():
            key = c.split(" ")[0] if c.startswith(("tree ", "Info.plist ")) else c
            n, k = per_check.get(key, (0, 0))
            per_check[key] = (n + 1, k + (1 if v else 0))
        print(f"| {kind} | {n_ok}/{len(checks)} | {common} ({nr} / {ny}) |")
    print()
    print("| Check | Runs | Identical |")
    print("|---|---:|---:|")
    for c in sorted(per_check):
        print(f"| {c} | {per_check[c][0]} | {per_check[c][1]} |")
    print(f"\nAll checks: {ok_total}/{total} identical")
    if failures:
        print("\nDifferent:")
        for kind, c in failures:
            print(f"  [{kind}] {c}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
