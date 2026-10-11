#!/usr/bin/env python3
"""Build a structural inventory of an Xcode.app bundle.

Records only metadata: bundle names, sizes, linked libraries, language mix,
and exported class *counts*. It never extracts code, strings, or resources.

Usage: python3 -I tools/inventory.py <Xcode.app> <out-dir>
"""
import json
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

# Components Apple publishes as open source. Ycode reuses these instead of
# reimplementing them. Keys are bundle names without the extension.
OPEN_SOURCE = {
    "SwiftBuild": "swiftlang/swift-build",
    "llbuild": "swiftlang/swift-llbuild",
    "SwiftPM": "swiftlang/swift-package-manager",
    "LLDB": "llvm/llvm-project (lldb)",
    "SourceKitLSPSupport": "swiftlang/sourcekit-lsp (partial)",
    "LanguageServerProtocol": "swiftlang/sourcekit-lsp",
    "LanguageServerProtocolTransport": "swiftlang/sourcekit-lsp",
    "BuildServerProtocol": "swiftlang/sourcekit-lsp",
    "SKLogging": "swiftlang/sourcekit-lsp",
    "ToolsProtocolsSwiftExtensions": "swiftlang/swift-tools-protocols",
    "IndexStoreDB_CIndexStoreDB": "swiftlang/indexstore-db",
    "IndexStoreDB_Core": "swiftlang/indexstore-db",
    "IndexStoreDB_Database": "swiftlang/indexstore-db",
    "IndexStoreDB_Index": "swiftlang/indexstore-db",
    "IndexStoreDB_LLVMSupport": "swiftlang/indexstore-db",
    "IndexStoreDB_Support": "swiftlang/indexstore-db",
    "SwiftSyntax": "swiftlang/swift-syntax",
    "SwiftParser": "swiftlang/swift-syntax",
    "SwiftParserDiagnostics": "swiftlang/swift-syntax",
    "SwiftDiagnostics": "swiftlang/swift-syntax",
    "SwiftBasicFormat": "swiftlang/swift-syntax",
    "SwiftOperators": "swiftlang/swift-syntax",
    "SwiftIDEUtils": "swiftlang/swift-syntax",
    "SwiftRefactor": "swiftlang/swift-syntax",
    "SwiftSyntaxBuilder": "swiftlang/swift-syntax",
    "SwiftSyntaxCShims": "swiftlang/swift-syntax",
    "Testing": "swiftlang/swift-testing",
    "XCTest": "swiftlang/swift-corelibs-xctest (API-compatible)",
    "ArgumentParser": "apple/swift-argument-parser",
    "Subprocess": "swiftlang/swift-subprocess",
    "OpenAPIRuntime": "apple/swift-openapi-runtime",
    "OpenAPIURLSession": "apple/swift-openapi-urlsession",
    "HexFiend": "HexFiend/HexFiend",
    "CreateMLSwiftProtobuf": "apple/swift-protobuf",
}

BUNDLE_EXT = (".framework", ".ideplugin", ".dvtplugin", ".xcplugin", ".appex", ".app", ".bundle")


def run(args):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=300).stdout
    except subprocess.TimeoutExpired:
        return ""


def find_binary(bundle):
    """Return the main Mach-O of a bundle, or None."""
    info = os.path.join(bundle, "Contents", "Info.plist")
    name = os.path.splitext(os.path.basename(bundle))[0]
    candidates = [
        os.path.join(bundle, "Versions", "A", name),
        os.path.join(bundle, name),
        os.path.join(bundle, "Contents", "MacOS", name),
    ]
    if os.path.exists(info):
        exe = run(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleExecutable", info]).strip()
        if exe:
            candidates.insert(0, os.path.join(bundle, "Contents", "MacOS", exe))
    for c in candidates:
        if os.path.isfile(c) and not os.path.islink(c):
            return c
        if os.path.islink(c):
            return os.path.realpath(c)
    return None


def analyze(bundle, root):
    name, ext = os.path.splitext(os.path.basename(bundle))
    rec = {
        "name": name,
        "kind": ext.lstrip("."),
        "path": os.path.relpath(bundle, root),
        "open_source": OPEN_SOURCE.get(name),
    }
    binary = find_binary(bundle)
    if not binary:
        rec["binary"] = None
        return rec
    rec["binary_size"] = os.path.getsize(binary)
    links = run(["otool", "-L", binary]).splitlines()[1:]
    deps = []
    swift = False
    for line in links:
        lib = line.strip().split(" (")[0]
        if "libswift" in lib or lib.endswith("/libswiftCore.dylib"):
            swift = True
        m = re.search(r"/([^/]+)\.framework/", lib)
        if m and (lib.startswith("@rpath") or "/SharedFrameworks/" in lib or "/PrivateFrameworks/" in lib):
            deps.append(m.group(1))
        elif lib.startswith("@rpath"):
            deps.append(os.path.basename(lib))
    symbols = run(["nm", "-U", "-j", binary]).splitlines()
    rec["objc_classes"] = sum(1 for s in symbols if s.startswith("_OBJC_CLASS_$_"))
    # Swift nominal type descriptors end in Mn (struct/class/enum/protocol variants).
    rec["swift_types"] = sum(1 for s in symbols if s.startswith("_$s") and re.search(r"(?:C|V|O|P)Mn$", s))
    rec["links_swift"] = swift
    rec["deps"] = sorted(set(d for d in deps if d != name))
    return rec


def bundles(root):
    for top in ("Frameworks", "SharedFrameworks", "PlugIns", "MacOS"):
        base = os.path.join(root, "Contents", top)
        if not os.path.isdir(base):
            continue
        if top == "MacOS":
            yield os.path.join(root)  # the app itself
            continue
        for entry in sorted(os.listdir(base)):
            if entry.endswith(BUNDLE_EXT):
                yield os.path.join(base, entry)


def main():
    app, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    items = list(bundles(app))
    with ThreadPoolExecutor(max_workers=os.cpu_count()) as pool:
        recs = list(pool.map(lambda b: analyze(b, app), items))
    for r in recs:
        if r["path"] == ".":
            r["name"], r["kind"], r["path"] = "Xcode", "app", "Contents/MacOS/Xcode"
    with open(os.path.join(out, "bundles.json"), "w") as f:
        json.dump(recs, f, indent=1, sort_keys=True)
    print(f"{len(recs)} bundles -> {out}/bundles.json")


if __name__ == "__main__":
    main()
