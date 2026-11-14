#!/usr/bin/env python3
# Writes THIRD_PARTY_NOTICES.md at the repository's root: what each package
# bundles and the full licence texts. Run it when a dependency changes, after a
# build (the Swift dependencies' licences are read from SwiftPM's checkouts):
#
#   python3 -I packaging/generate-notices.py <folder with checkouts>...
#
# for example ycode/.build-release/arm64/checkouts /tmp/ycode-release-<uid>/swb-arm64/checkouts
import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
L = "packaging/licenses/"
OV = "frameworks/swiftui/Sources/"
# component, version, source, licence, where it ships, licence files (repo paths or
# checkout:<identity>/<file>).
COMPONENTS = [
    ("Swift runtime and standard libraries, Foundation, Dispatch", "6.4.2", "https://github.com/swiftlang/swift",
     "Apache-2.0 WITH Swift Runtime Library Exception", "Flatpak (libraries in /app/lib)", [L + "swift-LICENSE.txt"]),
    ("ICU data and code inside Foundation", "from Swift 6.4.2", "https://github.com/swiftlang/swift-foundation-icu",
     "Unicode-3.0 and Apache-2.0", "Flatpak", [L + "unicode-icu-LICENSE.txt", L + "swift-LICENSE.txt"]),
    ("libxml2 (loaded by Foundation's XML library)", "2.13.9", "https://gitlab.gnome.org/GNOME/libxml2", "MIT", "Flatpak", [L + "libxml2-LICENSE.txt"]),
    ("curl (libcurl, for Foundation's networking)", "8.23.0", "https://github.com/curl/curl", "curl (MIT-style)", "Flatpak", [L + "curl-LICENSE.txt"]),
    ("7-Zip (7zz), built without the RAR code", "26.05", "https://www.7-zip.org",
     "LGPL-2.1-or-later; LZFSE and Zstandard decoders BSD-3-Clause; xxHash BSD-2-Clause",
     "Flatpak (/app/bin/7zz, run as a separate program to read a runtime's disk image, never linked)",
     [L + "7zip-License.txt", L + "7zip-LGPL-2.1.txt"]),
    ("SDL 3", "3.4.20", "https://github.com/libsdl-org/SDL", "Zlib", "Flatpak; headers in the source", [OV + "COVSDL/SDL3-LICENSE.txt"]),
    ("ThorVG", "vendored", "https://github.com/thorvg/thorvg", "MIT", "Flatpak (compiled into ycode-ide)", [OV + "CThorVG/thorvg/LICENSE"]),
    ("Inter", "4.001", "https://github.com/rsms/inter", "OFL-1.1", "Flatpak (fonts); DMG background picture", [OV + "OVText/Resources/Fonts/Inter-OFL.txt"]),
    ("Noto Sans, Noto Sans Mono", "2.004, 2.006", "https://github.com/notofonts", "OFL-1.1", "Flatpak (fonts)", [OV + "OVText/Resources/Fonts/OFL.txt"]),
    ("Vulkan headers", "vendored", "https://github.com/KhronosGroup/Vulkan-Headers", "Apache-2.0 OR MIT", "Compiled into the tools (headers only)", ["ycode/Sources/CYcodeOpenXR/openxr/LICENSE"]),
    ("OpenXR headers", "1.1.47", "https://github.com/KhronosGroup/OpenXR-SDK", "Apache-2.0 OR MIT", "Compiled into the tools (headers only)", ["ycode/Sources/CYcodeOpenXR/openxr/LICENSE"]),
    ("NVIDIA codec headers (nv-codec-headers)", "n12.2.72.0", "https://github.com/FFmpeg/nv-codec-headers", "MIT", "Compiled into the tools (headers only)", ["ycode/Sources/CYcodeVideo/nvheaders/ffnvcodec/nvEncodeAPI.h#license"]),
    ("swift-crypto (includes BoringSSL)", "4.5.2", "https://github.com/apple/swift-crypto", "Apache-2.0; BoringSSL: ISC, OpenSSL", "DMG, Flatpak (compiled in)", ["checkout:swift-crypto/LICENSE.txt", "checkout:swift-crypto/NOTICE.txt"]),
    ("swift-asn1", "1.7.3", "https://github.com/apple/swift-asn1", "Apache-2.0", "DMG, Flatpak (compiled in)", ["checkout:swift-asn1/LICENSE.txt", "checkout:swift-asn1/NOTICE.txt"]),
    ("swift-syntax", "604.0.0", "https://github.com/swiftlang/swift-syntax", "Apache-2.0 WITH Swift Runtime Library Exception", "DMG, Flatpak (compiled in)", ["checkout:swift-syntax/LICENSE.txt"]),
    ("swift-build (includes its build specifications)", "release/6.4.x", "https://github.com/swiftlang/swift-build", "Apache-2.0 WITH Swift Runtime Library Exception", "DMG, Flatpak (ycode-swb, SWBBuildServiceBundle, resources)", ["checkout:swift-build/LICENSE.txt"]),
    ("swift-driver", "release/6.4.x", "https://github.com/swiftlang/swift-driver", "Apache-2.0 WITH Swift Runtime Library Exception", "DMG, Flatpak (ycode-swb)", ["checkout:swift-driver/LICENSE.txt"]),
    ("swift-llbuild", "release/6.4.x", "https://github.com/swiftlang/swift-llbuild", "Apache-2.0 WITH Swift Runtime Library Exception", "DMG, Flatpak (ycode-swb)", ["checkout:swift-llbuild/LICENSE.txt"]),
    ("swift-tools-support-core", "release/6.4.x", "https://github.com/swiftlang/swift-tools-support-core", "Apache-2.0 WITH Swift Runtime Library Exception", "DMG, Flatpak (ycode-swb)", ["checkout:swift-tools-support-core/LICENSE.txt"]),
    ("swift-tools-protocols", "release/6.4.x", "https://github.com/swiftlang/swift-tools-protocols", "Apache-2.0 WITH Swift Runtime Library Exception", "DMG, Flatpak (ycode-swb)", ["checkout:swift-tools-protocols/LICENSE.txt"]),
    ("swift-argument-parser", "1.8.2", "https://github.com/apple/swift-argument-parser", "Apache-2.0 WITH Swift Runtime Library Exception", "DMG, Flatpak (ycode-swb)", ["checkout:swift-argument-parser/LICENSE.txt"]),
    ("swift-system", "1.8.1", "https://github.com/apple/swift-system", "Apache-2.0", "DMG, Flatpak (ycode-swb)", ["checkout:swift-system/LICENSE.txt"]),
    ("swift-toolchain-sqlite (SQLite)", "1.0.13", "https://github.com/swiftlang/swift-toolchain-sqlite", "Public domain (SQLite); Apache-2.0 packaging", "DMG, Flatpak (ycode-swb)", ["checkout:swift-toolchain-sqlite/LICENSE"]),
    ("LLVM (libLLVM)", "22.1", "https://github.com/llvm/llvm-project", "Apache-2.0 WITH LLVM-exception", "aarch64 Flatpak only (ycode-airc)", [L + "llvm-LICENSE.txt"]),
    ("libjpeg-turbo (libjpeg.so.62, from the freedesktop 26.08 runtime)", "the runtime's", "https://github.com/libjpeg-turbo/libjpeg-turbo",
     "IJG AND BSD-3-Clause AND Zlib", "Flatpak (lib/; the display stream loads it at run time)", [L + "libjpeg-turbo-LICENSE.txt"]),
    # ycode-airc's private runtime (aarch64, lib/ycode-sim/airc/lib; build-ycode.sh):
    # copied unmodified from the freedesktop 26.08 SDK, except libxml2 (built here).
    ("GNU C Library (dynamic loader, libc, libm)", "2.44, from the freedesktop 26.08 runtime", "https://sourceware.org/glibc/",
     "LGPL-2.1-or-later; parts under the notices in its LICENSES file", "aarch64 Flatpak only (ycode-airc's private libraries; source: the runtime's)",
     [L + "7zip-LGPL-2.1.txt", L + "glibc-LICENSES.txt"]),
    ("GCC runtime libraries (libstdc++, libgcc_s)", "from the freedesktop 26.08 runtime", "https://gcc.gnu.org",
     "GPL-3.0-or-later WITH GCC-exception-3.1", "aarch64 Flatpak only (ycode-airc's private libraries)",
     [L + "gcc-COPYING.RUNTIME.txt", L + "gcc-COPYING3.txt"]),
    ("libffi", "from the freedesktop 26.08 runtime", "https://github.com/libffi/libffi", "MIT", "aarch64 Flatpak only (ycode-airc's private libraries)",
     [L + "libffi-LICENSE.txt"]),
    ("zlib-ng (libz.so.1)", "from the freedesktop 26.08 runtime", "https://github.com/zlib-ng/zlib-ng", "Zlib", "aarch64 Flatpak only (ycode-airc's private libraries)",
     [L + "zlib-ng-LICENSE.txt"]),
    ("Zstandard (libzstd)", "1.5.7, from the freedesktop 26.08 runtime", "https://github.com/facebook/zstd", "BSD-3-Clause", "aarch64 Flatpak only (ycode-airc's private libraries)",
     [L + "zstd-LICENSE.txt"]),
    ("libxml2 (for libLLVM, built without ICU)", "2.15.4", "https://gitlab.gnome.org/GNOME/libxml2", "MIT", "aarch64 Flatpak only (ycode-airc's private libraries)",
     [L + "libxml2-2.15-LICENSE.txt"]),
    ("SPIRV-Tools", "vulkan-sdk-1.4.363.0", "https://github.com/KhronosGroup/SPIRV-Tools", "Apache-2.0", "aarch64 Flatpak only (compiled into ycode-airc)", [L + "spirv-tools-LICENSE.txt"]),
    ("SPIRV-Headers", "vulkan-sdk-1.4.363.0", "https://github.com/KhronosGroup/SPIRV-Headers", "MIT-style (Khronos)", "aarch64 Flatpak only (compiled into ycode-airc)", [L + "spirv-headers-LICENSE.txt"]),
    ("devicon (language logos in the project navigator)", "v2.18.0", "https://github.com/devicons/devicon", "MIT",
     "DMG, Flatpak (compiled in as vector outlines converted from its single-colour \"-plain\" and \"-line\" SVGs, in ycode/Resources/language-logos)",
     ["ycode/Resources/language-logos/LICENSE"]),
]

# The language logos' owners (devicon's MIT licence covers the collection;
# the logos stay their owners' marks).
TRADEMARKS = [
    "Swift and the Swift logo are trademarks of Apple Inc.",
    "Python and the Python logos are trademarks or registered trademarks of the Python Software Foundation.",
    "The C++ logo is a trademark of the Standard C++ Foundation.",
    "JavaScript is a trademark or registered trademark of Oracle Corporation; Java and the Java logo are trademarks or registered trademarks of Oracle Corporation and its affiliates.",
    "TypeScript and the TypeScript logo are trademarks of Microsoft Corporation.",
    "Rust and the Rust logo are trademarks of the Rust Foundation.",
    "Go and the Go gopher are trademarks of Google LLC; the gopher was designed by Renee French.",
    "The Ruby logo is copyright 2006 Yukihiro Matsumoto, licensed under the Creative Commons Attribution-ShareAlike 2.5 licence (CC BY-SA 2.5); Ycode draws devicon's single-colour rendering of it (ruby-plain), which stays under that licence.",
    "Kotlin and the Kotlin logo are trademarks of the Kotlin Foundation.",
    "The HTML5 logo is by the W3C; the CSS3 logo is drawn from devicon's single-colour variant.",
    "The Bash logo and the C logo are drawn from devicon's single-colour variants.",
]

# Programs Ycode runs when the user asks for a runtime download (#55) but
# never ships or links: name, version, source, licence, how Ycode uses it.
RUN_ONLY = [
    ("python-aea", "1.1.0", "https://github.com/kinnay/AEA", "MIT",
     "Decrypts a runtime archive on Linux (route B). Installed on request, with pip, into a Python environment in Ycode's runtime folder; run as a separate program."),
    ("cryptography, lz4, pyliblzfse, cffi, pycparser (python-aea's dependencies)", "as pip resolves them", "https://pypi.org/project/python-aea/",
     "Apache-2.0 OR BSD-3-Clause; BSD-3-Clause; MIT (LZFSE: BSD-3-Clause); MIT-0; BSD-3-Clause", "Installed by pip with python-aea, in the same environment."),
    ("7-Zip (7zz or 7z)", "23 or later", "https://www.7-zip.org", "LGPL-2.1-or-later with the unRAR restriction; parts BSD-3-Clause",
     "Reads the runtime's disk image (UDIF and APFS) on Linux when Ycode is built from source. Installed by the user; run as a separate program, never linked. The Flatpak ships its own 7zz (above)."),
    ("liblzma (XZ Utils)", "the system's", "https://github.com/tukaani-project/xz", "0BSD (public domain before 5.6)",
     "Decodes XZ chunks of an asset archive; the system's library, loaded at run time."),
    ("curl (the command)", "the system's", "https://github.com/curl/curl", "curl (MIT-style)", "Fetches Apple's index, asset answer and archive."),
    ("Python 3", "3.11 or later, the system's", "https://www.python.org", "PSF-2.0", "Runs python-aea."),
]
RUN_ONLY_TEXTS = [("python-aea", L + "python-aea-LICENSE.txt")]


def read_license(ref, checkouts):
    if ref.startswith("checkout:"):
        relative = ref[len("checkout:"):]
        for folder in checkouts:
            path = os.path.join(folder, relative)
            if os.path.exists(path):
                with open(path, encoding="utf-8", errors="replace") as f:
                    return f.read()
        raise SystemExit("no checkout has " + relative)
    if ref.endswith("#license"):  # the licence in a source file's opening comment
        with open(os.path.join(ROOT, ref[: -len("#license")]), encoding="utf-8", errors="replace") as f:
            head = f.read().split("*/")[0]
        lines = [line.strip(" */") for line in head.splitlines()]
        return "\n".join(line for line in lines if line) + "\n"
    with open(os.path.join(ROOT, ref), encoding="utf-8", errors="replace") as f:
        return f.read()


def main():
    checkouts = sys.argv[1:]
    texts, users = {}, {}
    out = ["# Third-party notices", "",
           "Ycode itself is under the MIT License (`LICENSE`). Each package also contains the following",
           "open-source components, listed with the package they ship in. Ycode contains no files from",
           "Apple's Xcode, SDKs or simulator runtimes. The Flatpak also runs on the freedesktop.org runtime,",
           "which Flatpak installs separately under its own licences.", "",
           "This file is generated by `packaging/generate-notices.py`.", "",
           "| Component | Version | Licence | Ships in |", "|---|---|---|---|"]
    for name, version, url, licence, ships, files in COMPONENTS:
        out.append("| [%s](%s) | %s | %s | %s |" % (name, url, version, licence, ships))
        for ref in files:
            text = read_license(ref, checkouts)
            key = hashlib.sha256(text.encode()).hexdigest()
            texts.setdefault(key, text)
            users.setdefault(key, [])
            if name not in users[key]:
                users[key].append(name)
    out += ["", "## Licence texts", ""]
    for key, text in texts.items():
        out += ["### " + ", ".join(users[key]), "", "```text", text.rstrip(), "```", ""]
    out += ["## Trademarks", "",
            "The project navigator, the jump bar, the merge sheet and Open Quickly show each language's logo next to files in that language, from devicon (above): its single-colour "-plain" variant, or its "-line" variant where devicon has no plain one (C, Rust). Ycode converts their outlines to its own vector data and draws each in one colour, tinted per file type (white on a selected row); the outlines of the "-line" variants are drawn with a thicker stroke. The Swift logo is devicon's plain variant inverted: the bird alone, without the rounded square it is knocked out of. The Python logo is drawn as the outline of devicon's plain variant's shapes, not filled. Markdown and JSON files show Ycode's own glyphs (an open book; braces round a quote), not logos; no devicon file is used for them.",
            "The logos belong to their owners:", ""]
    out += ["- " + t for t in TRADEMARKS]
    out += ["", "Ycode is not affiliated with, sponsored by or endorsed by any of these owners.", ""]
    out += ["## Programs Ycode runs but does not ship", "",
            "Getting a simulator runtime (`specs/simulator/runtime-downloads.md` §6) uses these programs, only when the user",
            "asks for a download. Ycode runs each as a separate program, or loads the system's library at run time; it links",
            "none of them, and no Ycode package contains them except 7-Zip, which the Flatpak ships (above).", "",
            "| Program | Version | Licence | How Ycode uses it |", "|---|---|---|---|"]
    for name, version, url, licence, use in RUN_ONLY:
        out.append("| [%s](%s) | %s | %s | %s |" % (name, url, version, licence, use))
    out.append("")
    for name, ref in RUN_ONLY_TEXTS:
        out += ["### " + name, "", "```text", read_license(ref, checkouts).rstrip(), "```", ""]
    with open(os.path.join(ROOT, "THIRD_PARTY_NOTICES.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(out))


if __name__ == "__main__":
    main()
