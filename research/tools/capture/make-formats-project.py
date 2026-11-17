#!/usr/bin/env python3
"""Write the parity run's part C test project: Parity (make-parity-project.py)
with one file of each kind that has its own editor, in the synchronized Parity
folder, committed by the fixed test identity. Our own content.

- Assets.xcassets: AccentColor and Swatch colour sets, an AppIcon set without
  images, and a Stripes image set (a PNG drawn here).
- Defaults.plist: a property list (dictionary, array, number, boolean, date,
  data). Not named Info.plist, so the app's build does not see two of them.
- Parity.entitlements: App Sandbox with read-only user-selected files.
- Localizable.xcstrings: a String Catalog with three strings, English and German.
- Parity.xctestplan: a test plan with the ParityTests bundle.
- Main.storyboard: a macOS storyboard (a window controller and a view
  controller with a label and a button).
- Model.xcdatamodeld: a Core Data model with two entities and a relationship.
- NOTES.md, palette.json and Stripes.png (an image file on its own).

The copy is written to OUT_DIR/formats/Parity (its own folder, so these
files never reach the plain Parity copy).

Usage: python3 -I make-formats-project.py OUT_DIR   (writes OUT_DIR/formats/Parity)
"""

import importlib.util
import json
import pathlib
import shutil
import struct
import sys
import zlib

HERE = pathlib.Path(__file__).resolve().parent


def png(width, height, rgb_at):
    """A PNG (8-bit RGB) whose pixel colour comes from rgb_at(x, y)."""
    rows = b"".join(b"\x00" + b"".join(bytes(rgb_at(x, y)) for x in range(width)) for y in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))


STRIPES = [(30, 111, 217), (242, 169, 0), (43, 182, 115), (240, 240, 240)]


def stripes(x, y):
    return STRIPES[((x + y) // 16) % len(STRIPES)]


def contents(obj):
    return json.dumps({**obj, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n"


def colorset(r, g, b, dark=None):
    def comp(c):
        return {"alpha": "1.000", "blue": f"{c[2]:.3f}", "green": f"{c[1]:.3f}", "red": f"{c[0]:.3f}"}

    colors = [{"color": {"color-space": "srgb", "components": comp((r, g, b))}, "idiom": "universal"}]
    if dark:
        colors.append({"appearances": [{"appearance": "luminosity", "value": "dark"}],
                       "color": {"color-space": "srgb", "components": comp(dark)}, "idiom": "universal"})
    return contents({"colors": colors})


APPICON = contents({"images": [{"idiom": "mac", "scale": s, "size": f"{p}x{p}"}
                               for p in (16, 32, 128, 256, 512) for s in ("1x", "2x")]})

PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Greeting</key>
	<string>Hello, Parity!</string>
	<key>LaunchCount</key>
	<integer>3</integer>
	<key>ShowsWelcome</key>
	<true/>
	<key>Scale</key>
	<real>1.5</real>
	<key>Created</key>
	<date>2026-01-01T12:00:00Z</date>
	<key>Token</key>
	<data>UGFyaXR5</data>
	<key>Shapes</key>
	<array>
		<string>Circle</string>
		<string>Square</string>
	</array>
	<key>Window</key>
	<dict>
		<key>Width</key>
		<integer>480</integer>
		<key>Height</key>
		<integer>270</integer>
	</dict>
</dict>
</plist>
"""

ENTITLEMENTS = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.files.user-selected.read-only</key>
	<true/>
</dict>
</plist>
"""


def strings_catalog():
    def unit(text):
        return {"stringUnit": {"state": "translated", "value": text}}

    strings = {
        "Count: %lld": {"localizations": {"de": unit("Anzahl: %lld")}},
        "Hello, Parity!": {"comment": "The greeting at the top of the window.",
                           "localizations": {"de": unit("Hallo, Parity!")}},
        "Increment": {"localizations": {}},
    }
    return json.dumps({"sourceLanguage": "en", "strings": strings, "version": "1.0"}, indent=2) + "\n"


def test_plan(tests_id):
    return json.dumps({
        "configurations": [{"id": "4F3A0C1E-2B6D-4E8A-9C1F-0D2E3F4A5B6C", "name": "Configuration 1",
                            "options": {}}],
        "defaultOptions": {"codeCoverage": False},
        "testTargets": [{"target": {"containerPath": "container:Parity.xcodeproj", "identifier": tests_id,
                                    "name": "ParityTests"}}],
        "version": 1,
    }, indent=2) + "\n"


STORYBOARD = """<?xml version="1.0" encoding="UTF-8"?>
<document type="com.apple.InterfaceBuilder3.Cocoa.Storyboard.XIB" version="3.0" toolsVersion="23504" targetRuntime="MacOSX.Cocoa" propertyAccessControl="none" useAutolayout="YES" initialViewController="Pw1-Wc-001">
    <dependencies>
        <plugIn identifier="com.apple.InterfaceBuilder.CocoaPlugin" version="23504"/>
    </dependencies>
    <scenes>
        <scene sceneID="Pw1-Sc-001">
            <objects>
                <windowController id="Pw1-Wc-001" sceneMemberID="viewController">
                    <window key="window" title="Parity" allowsToolTipsWhenApplicationIsInactive="NO" autorecalculatesKeyViewLoop="NO" releasedWhenClosed="NO" animationBehavior="default" id="Pw1-Wn-001">
                        <windowStyleMask key="styleMask" titled="YES" closable="YES" miniaturizable="YES" resizable="YES"/>
                        <windowPositionMask key="initialPositionMask" leftStrut="YES" rightStrut="YES" topStrut="YES" bottomStrut="YES"/>
                        <rect key="contentRect" x="196" y="240" width="480" height="270"/>
                        <rect key="screenRect" x="0.0" y="0.0" width="1512" height="944"/>
                    </window>
                    <connections>
                        <segue destination="Pw1-Vc-001" kind="relationship" relationship="window.shadowedContentViewController" id="Pw1-Sg-001"/>
                    </connections>
                </windowController>
                <customObject id="Pw1-Fr-001" userLabel="First Responder" customClass="NSResponder" sceneMemberID="firstResponder"/>
            </objects>
            <point key="canvasLocation" x="75" y="250"/>
        </scene>
        <scene sceneID="Pw1-Sc-002">
            <objects>
                <viewController id="Pw1-Vc-001" sceneMemberID="viewController">
                    <view key="view" id="Pw1-Vw-001">
                        <rect key="frame" x="0.0" y="0.0" width="480" height="270"/>
                        <autoresizingMask key="autoresizingMask"/>
                        <subviews>
                            <textField focusRingType="none" horizontalHuggingPriority="251" verticalHuggingPriority="750" fixedFrame="YES" translatesAutoresizingMaskIntoConstraints="NO" id="Pw1-Lb-001">
                                <rect key="frame" x="18" y="224" width="240" height="22"/>
                                <autoresizingMask key="autoresizingMask" flexibleMaxX="YES" flexibleMinY="YES"/>
                                <textFieldCell key="cell" lineBreakMode="clipping" title="Parity storyboard" id="Pw1-Lc-001">
                                    <font key="font" metaFont="system" size="17"/>
                                    <color key="textColor" name="labelColor" catalog="System" colorSpace="catalog"/>
                                    <color key="backgroundColor" name="textBackgroundColor" catalog="System" colorSpace="catalog"/>
                                </textFieldCell>
                            </textField>
                            <button verticalHuggingPriority="750" fixedFrame="YES" translatesAutoresizingMaskIntoConstraints="NO" id="Pw1-Bt-001">
                                <rect key="frame" x="13" y="173" width="110" height="32"/>
                                <autoresizingMask key="autoresizingMask" flexibleMaxX="YES" flexibleMinY="YES"/>
                                <buttonCell key="cell" type="push" title="Increment" bezelStyle="rounded" alignment="center" borderStyle="border" imageScaling="proportionallyDown" inset="2" id="Pw1-Bc-001">
                                    <behavior key="behavior" pushIn="YES" lightByBackground="YES" lightByGray="YES"/>
                                    <font key="font" metaFont="system"/>
                                </buttonCell>
                            </button>
                        </subviews>
                    </view>
                </viewController>
                <customObject id="Pw1-Fr-002" userLabel="First Responder" customClass="NSResponder" sceneMemberID="firstResponder"/>
            </objects>
            <point key="canvasLocation" x="75" y="655"/>
        </scene>
    </scenes>
</document>
"""

DATA_MODEL = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<model type="com.apple.IDECoreDataModeler.DataModel" documentVersion="1.0" lastSavedToolsVersion="1" systemVersion="1" minimumToolsVersion="Automatic" sourceLanguage="Swift" userDefinedModelVersionIdentifier="">
    <entity name="Note" representedClassName="Note" syncable="YES" codeGenerationType="class">
        <attribute name="created" optional="YES" attributeType="Date" usesScalarValueType="NO"/>
        <attribute name="title" optional="YES" attributeType="String"/>
        <relationship name="shelf" optional="YES" maxCount="1" deletionRule="Nullify" destinationEntity="Shelf" inverseName="notes" inverseEntity="Shelf"/>
    </entity>
    <entity name="Shelf" representedClassName="Shelf" syncable="YES" codeGenerationType="class">
        <attribute name="name" optional="YES" attributeType="String"/>
        <relationship name="notes" optional="YES" toMany="YES" deletionRule="Cascade" destinationEntity="Note" inverseName="shelf" inverseEntity="Note"/>
    </entity>
</model>
"""

MARKDOWN = """# Parity notes

Test project for the parity run's editors.

## Files

- **Assets.xcassets**: colour sets and an image set
- `Defaults.plist`: a property list
- Localizable.xcstrings: a String Catalog

> Our own content, written by the capture tooling.

```swift
let greeting = "Hello, Parity!"
```
"""

JSON_TEXT = """{
  "name": "Parity palette",
  "colors": ["#1E6FD9", "#F2A900", "#2BB673"],
  "sizes": {"small": 12, "large": 24},
  "version": 1
}
"""


def write(out_dir: pathlib.Path) -> pathlib.Path:
    spec = importlib.util.spec_from_file_location("make_parity_project", HERE / "make-parity-project.py")
    parity = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(parity)
    parent = out_dir / "formats"
    if parent.exists():
        shutil.rmtree(parent)
    parent.mkdir(parents=True)
    project = parity.write(parent)
    root = parent / parity.NAME
    src = root / parity.NAME
    assets = src / "Assets.xcassets"
    for d in ("AccentColor.colorset", "Swatch.colorset", "AppIcon.appiconset", "Stripes.imageset"):
        (assets / d).mkdir(parents=True)
    (assets / "Contents.json").write_text(contents({}))
    (assets / "AccentColor.colorset" / "Contents.json").write_text(colorset(0.118, 0.435, 0.851))
    (assets / "Swatch.colorset" / "Contents.json").write_text(colorset(0.949, 0.663, 0.0, dark=(1.0, 0.749, 0.2)))
    (assets / "AppIcon.appiconset" / "Contents.json").write_text(APPICON)
    image = png(64, 64, stripes)
    (assets / "Stripes.imageset" / "Stripes.png").write_bytes(image)
    (assets / "Stripes.imageset" / "Contents.json").write_text(contents({"images": [
        {"filename": "Stripes.png", "idiom": "universal", "scale": "1x"},
        {"idiom": "universal", "scale": "2x"}, {"idiom": "universal", "scale": "3x"}]}))
    (src / "Defaults.plist").write_text(PLIST)
    (src / "Parity.entitlements").write_text(ENTITLEMENTS)
    (src / "Localizable.xcstrings").write_text(strings_catalog())
    (src / "Parity.xctestplan").write_text(test_plan(parity.oid("t-tests")))
    (src / "Main.storyboard").write_text(STORYBOARD)
    model = src / "Model.xcdatamodeld" / "Model.xcdatamodel"
    model.mkdir(parents=True)
    (model / "contents").write_text(DATA_MODEL)
    (src / "NOTES.md").write_text(MARKDOWN)
    (src / "palette.json").write_text(JSON_TEXT)
    (src / "Stripes.png").write_bytes(image)
    parity.git(root, "add", "-A")
    parity.git(root, "commit", "-q", "-m", "Add files for the editors", date="2026-01-08T12:00:00Z")
    return project


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    print(write(pathlib.Path(sys.argv[1])))
