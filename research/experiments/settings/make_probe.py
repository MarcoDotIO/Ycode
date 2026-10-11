#!/usr/bin/env python3
"""Black-box probe: generate a minimal macOS tool project whose project and
target configurations use given xcconfig files and build settings, run
`xcodebuild -showBuildSettings -json`, and print the requested settings.

Usage: python3 -I make_probe.py <workdir> <spec.json>
spec = {"project_xcconfig": "...text...", "target_xcconfig": "...",
        "project_settings": {...}, "target_settings": {...},
        "extra_files": {"name": "text"}, "query": ["A", "B"],
        "configuration": "Debug", "overrides": ["K=V"]}
"""
import json, os, subprocess, sys

def q(s):
    import re
    if s and re.fullmatch(r"[A-Za-z0-9_$/:.]+", s) and "//" not in s and "___" not in s:
        return s
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'

def settings(d):
    return "".join(f"\t\t\t\t{q(k)} = {q(v)};\n" for k, v in sorted(d.items()))

def main():
    work, spec = sys.argv[1], json.load(open(sys.argv[2]))
    os.makedirs(os.path.join(work, "Probe.xcodeproj"), exist_ok=True)
    for name, text in {"project.xcconfig": spec.get("project_xcconfig", ""),
                       "target.xcconfig": spec.get("target_xcconfig", ""),
                       **spec.get("extra_files", {})}.items():
        path = os.path.join(work, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, "w").write(text)
    ps, ts = settings(spec.get("project_settings", {})), settings(spec.get("target_settings", {}))
    pbx = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 77;
	objects = {{
		A0 = {{isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = project.xcconfig; sourceTree = "<group>"; }};
		A1 = {{isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = target.xcconfig; sourceTree = "<group>"; }};
		A2 = {{isa = PBXFileReference; explicitFileType = "{spec.get('product_file_type', 'compiled.mach-o.executable')}"; includeInIndex = 0; path = {spec.get('product_path', 'Probe')}; sourceTree = BUILT_PRODUCTS_DIR; }};
		G0 = {{isa = PBXGroup; children = (A0, A1, G1, ); sourceTree = "<group>"; }};
		G1 = {{isa = PBXGroup; children = (A2, ); name = Products; sourceTree = "<group>"; }};
		S0 = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};
		T0 = {{isa = PBXNativeTarget; buildConfigurationList = L1; buildPhases = (S0, ); buildRules = (); dependencies = (); name = Probe; productName = Probe; productReference = A2; productType = "{spec.get('product_type', 'com.apple.product-type.tool')}"; }};
		P0 = {{isa = PBXProject; buildConfigurationList = L0; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, ); mainGroup = G0; productRefGroup = G1; projectDirPath = ""; projectRoot = ""; targets = (T0, ); }};
		C0 = {{isa = XCBuildConfiguration; baseConfigurationReference = A0; buildSettings = {{
{ps}				SDKROOT = {spec.get('sdkroot', 'macosx')};
			}}; name = Debug; }};
		C1 = {{isa = XCBuildConfiguration; baseConfigurationReference = A0; buildSettings = {{
{ps}				SDKROOT = {spec.get('sdkroot', 'macosx')};
			}}; name = Release; }};
		C2 = {{isa = XCBuildConfiguration; baseConfigurationReference = A1; buildSettings = {{
{ts}			}}; name = Debug; }};
		C3 = {{isa = XCBuildConfiguration; baseConfigurationReference = A1; buildSettings = {{
{ts}			}}; name = Release; }};
		L0 = {{isa = XCConfigurationList; buildConfigurations = (C0, C1, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};
		L1 = {{isa = XCConfigurationList; buildConfigurations = (C2, C3, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};
	}};
	rootObject = P0;
}}
"""
    open(os.path.join(work, "Probe.xcodeproj", "project.pbxproj"), "w").write(pbx)
    cmd = ["xcodebuild", "-showBuildSettings", "-json", "-project", os.path.join(work, "Probe.xcodeproj"),
           "-target", "Probe", "-configuration", spec.get("configuration", "Debug")] + spec.get("overrides", [])
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stderr[-2000:], file=sys.stderr); sys.exit(1)
    bs = json.loads(r.stdout)[0]["buildSettings"]
    out = {k: bs.get(k, "<unset>") for k in spec.get("query", [])} if spec.get("query") else bs
    print(json.dumps(out, indent=1))

main()
