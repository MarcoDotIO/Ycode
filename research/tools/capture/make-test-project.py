#!/usr/bin/env python3
"""Write the capture sessions' test project, GlassScroll, into a folder.

GlassScroll is our own content, made for observation: a macOS app target
whose sources sit in one folder-synchronised group, with

- Long.swift: about 900 lines that alternate long comment blocks and code,
  so the editor can scroll under the toolbar for a long time;
- Models/Model01.swift ... Model48.swift: enough rows to scroll the navigator;
- Stripes.png: a tall image of black, white and coloured bands, so that light
  and dark content pass under the glass bars at known positions;
- Bands.swift: the same idea in text: bands of full-block characters in the
  comment and string colours between blank bands, for scrolling dark content
  under the bars where an image would be scaled to fit;
- Plain/: a plain group (PBXGroup, not a synchronised folder) whose children
  are listed out of alphabetical order (Zeta.swift, Sub, alpha.swift,
  Beta.swift), for the navigator's sort order of plain groups;
- .editorconfig with root = true, so the repository's own .editorconfig does
  not apply and the EditorConfig behaviour is tested on purpose (4 spaces).

Usage: python3 -I make-test-project.py OUT_DIR   (writes OUT_DIR/GlassScroll)
The output is deterministic, so every session opens identical input.
"""

import hashlib
import pathlib
import sys
import zlib
import struct

NAME = "GlassScroll"
MODEL_COUNT = 48
STRIPE_HEIGHT_PT = 120
STRIPES = [
    (0, 0, 0), (255, 255, 255), (230, 40, 40), (255, 255, 255), (20, 90, 220),
    (0, 0, 0), (250, 200, 30), (255, 255, 255), (40, 170, 80), (0, 0, 0),
    (128, 128, 128), (255, 255, 255), (150, 60, 200), (0, 0, 0), (255, 255, 255),
]


def object_id(name: str) -> str:
    return hashlib.sha1(f"{NAME}:{name}".encode()).hexdigest()[:24].upper()


def long_swift() -> str:
    lines = ["// Long.swift: scrolling material for the capture sessions.", "", "import Foundation", ""]
    for block in range(30):
        lines.append("/*")
        for row in range(10):
            lines.append(f" Block {block:02d}, line {row}: a comment line long enough to fill most of the editor width "
                         f"so that text passes under the toolbar as the editor scrolls.")
        lines.append("*/")
        lines.append(f"struct Section{block:02d} {{")
        for row in range(12):
            lines.append(f"    let value{row:02d}: Int = {block * 100 + row}  // a short trailing comment")
        lines.append(f"    func describe() -> String {{ \"Section {block:02d}\" }}")
        lines.append("}")
        lines.append("")
    return "\n".join(lines) + "\n"


BAND_LINES = 12
BLOCKS = "\u2588" * 110


def bands_swift() -> str:
    lines = ["// Bands.swift: dark and light bands for the glass tint (full-block characters).", ""]
    for band in range(16):
        kind = band % 4
        if kind == 0:
            lines += [f"// {BLOCKS}" for _ in range(BAND_LINES)]
        elif kind == 2:
            lines += [f"let band{band:02d} = \"\"\""] + [BLOCKS for _ in range(BAND_LINES - 2)] + ['"""']
        else:
            lines += [""] * BAND_LINES
    return "\n".join(lines) + "\n"


PLAIN_FILES = ["Zeta.swift", "alpha.swift", "Beta.swift"]
EDITORCONFIG = "root = true\n\n[*]\nindent_style = space\nindent_size = 4\n"


def model_swift(i: int) -> str:
    return (f"// Model{i:02d}.swift\n\nstruct Model{i:02d}: Identifiable {{\n"
            f"    let id = {i}\n    var name = \"Model {i:02d}\"\n}}\n")


APP_SWIFT = """import SwiftUI

@main
struct GlassScrollApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
"""

CONTENT_SWIFT = """import SwiftUI

struct ContentView: View {
    var body: some View {
        List(0..<100, id: \\.self) { Text("Row \\($0)") }
    }
}
"""


def png(width: int, height: int, rows) -> bytes:
    raw = b"".join(b"\x00" + bytes(row) * width for row in rows)

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def stripes_png() -> bytes:
    width = 800
    rows = [colour for colour in STRIPES for _ in range(STRIPE_HEIGHT_PT)]
    return png(width, len(rows), rows)


def pbxproj() -> str:
    ids = {k: object_id(k) for k in [
        "project", "main", "products", "app", "sync", "target", "sources", "frameworks", "resources",
        "plist-project", "plist-target", "proj-debug", "proj-release", "tgt-debug", "tgt-release",
        "plain", "sub", "ref:Sub/Inner.swift"] + [f"ref:{f}" for f in PLAIN_FILES]}
    plain_refs = [f for f in PLAIN_FILES] + ["Sub/Inner.swift"]
    for f in plain_refs:
        ids[f"build:{f}"] = object_id(f"build:{f}")
    build_files = "".join(
        f"\t\t{ids['build:' + f]} /* {f.split('/')[-1]} in Sources */ = {{isa = PBXBuildFile; "
        f"fileRef = {ids['ref:' + f]} /* {f.split('/')[-1]} */; }};\n" for f in plain_refs)
    file_refs = "".join(
        f"\t\t{ids['ref:' + f]} /* {f.split('/')[-1]} */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = sourcecode.swift; path = {f.split('/')[-1]}; sourceTree = \"<group>\"; }};\n"
        for f in plain_refs)
    sources = "".join(f"\t\t\t\t{ids['build:' + f]} /* {f.split('/')[-1]} in Sources */,\n" for f in plain_refs)
    common = """				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				MACOSX_DEPLOYMENT_TARGET = 15.0;
				SDKROOT = macosx;
				SWIFT_VERSION = 6.0;"""
    target_settings = """				CODE_SIGN_STYLE = Automatic;
				CODE_SIGN_IDENTITY = "-";
				GENERATE_INFOPLIST_FILE = YES;
				PRODUCT_BUNDLE_IDENTIFIER = org.example.GlassScroll;
				PRODUCT_NAME = "$(TARGET_NAME)";"""
    i = ids
    return f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 77;
	objects = {{

/* Begin PBXBuildFile section */
{build_files}/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{file_refs}		{i['app']} /* {NAME}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {NAME}.app; sourceTree = BUILT_PRODUCTS_DIR; }};
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
		{i['sync']} /* {NAME} */ = {{
			isa = PBXFileSystemSynchronizedRootGroup;
			path = {NAME};
			sourceTree = "<group>";
		}};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
		{i['frameworks']} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{i['main']} = {{
			isa = PBXGroup;
			children = (
				{i['sync']} /* {NAME} */,
				{i['plain']} /* Plain */,
				{i['products']} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{i['plain']} /* Plain */ = {{
			isa = PBXGroup;
			children = (
				{i['ref:Zeta.swift']} /* Zeta.swift */,
				{i['sub']} /* Sub */,
				{i['ref:alpha.swift']} /* alpha.swift */,
				{i['ref:Beta.swift']} /* Beta.swift */,
			);
			path = Plain;
			sourceTree = "<group>";
		}};
		{i['sub']} /* Sub */ = {{
			isa = PBXGroup;
			children = (
				{i['ref:Sub/Inner.swift']} /* Inner.swift */,
			);
			path = Sub;
			sourceTree = "<group>";
		}};
		{i['products']} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{i['app']} /* {NAME}.app */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{i['target']} /* {NAME} */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {i['plist-target']} /* Build configuration list for PBXNativeTarget "{NAME}" */;
			buildPhases = (
				{i['sources']} /* Sources */,
				{i['frameworks']} /* Frameworks */,
				{i['resources']} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				{i['sync']} /* {NAME} */,
			);
			name = {NAME};
			productName = {NAME};
			productReference = {i['app']} /* {NAME}.app */;
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{i['project']} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2700;
				LastUpgradeCheck = 2700;
			}};
			buildConfigurationList = {i['plist-project']} /* Build configuration list for PBXProject "{NAME}" */;
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
				{i['target']} /* {NAME} */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{i['resources']} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{i['sources']} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{sources}			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		{i['proj-debug']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{common}
				ONLY_ACTIVE_ARCH = YES;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			}};
			name = Debug;
		}};
		{i['proj-release']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{common}
				SWIFT_COMPILATION_MODE = wholemodule;
			}};
			name = Release;
		}};
		{i['tgt-debug']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{target_settings}
			}};
			name = Debug;
		}};
		{i['tgt-release']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{target_settings}
			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{i['plist-project']} /* Build configuration list for PBXProject "{NAME}" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{i['proj-debug']} /* Debug */,
				{i['proj-release']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{i['plist-target']} /* Build configuration list for PBXNativeTarget "{NAME}" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{i['tgt-debug']} /* Debug */,
				{i['tgt-release']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */
	}};
	rootObject = {i['project']} /* Project object */;
}}
"""


def write(out_dir: pathlib.Path) -> pathlib.Path:
    root = out_dir / NAME
    sources = root / NAME
    (sources / "Models").mkdir(parents=True, exist_ok=True)
    (root / f"{NAME}.xcodeproj").mkdir(parents=True, exist_ok=True)
    (root / f"{NAME}.xcodeproj" / "project.pbxproj").write_text(pbxproj())
    (sources / f"{NAME}App.swift").write_text(APP_SWIFT)
    (sources / "ContentView.swift").write_text(CONTENT_SWIFT)
    (sources / "Long.swift").write_text(long_swift())
    for i in range(1, MODEL_COUNT + 1):
        (sources / "Models" / f"Model{i:02d}.swift").write_text(model_swift(i))
    (sources / "Stripes.png").write_bytes(stripes_png())
    (sources / "Bands.swift").write_text(bands_swift())
    (root / "Plain" / "Sub").mkdir(parents=True, exist_ok=True)
    for name in PLAIN_FILES:
        (root / "Plain" / name).write_text(f"// {name}: a file in a plain group.\n")
    (root / "Plain" / "Sub" / "Inner.swift").write_text("// Inner.swift: a file in a subgroup.\n")
    (root / ".editorconfig").write_text(EDITORCONFIG)
    return root / f"{NAME}.xcodeproj"


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    print(write(pathlib.Path(sys.argv[1])))
