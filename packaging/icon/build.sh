#!/bin/sh
# Renders the app icon from its two SVG masters into what each platform takes:
#   Ycode.icns (macOS) and hicolor/<size>x<size>/apps/<app id>.png plus
#   hicolor/scalable/apps/<app id>.svg (Linux). The outputs are checked in, so a
#   package build needs no SVG renderer. Needs rsvg-convert; iconutil for the .icns.
# Sizes up to 32 pixels come from ycode-icon-small.svg, the others from ycode-icon.svg.
set -eu
cd "$(dirname "$0")"
APP_ID=io.github.MarcoDotIO.Ycode
render() { # size output
    if [ "$1" -le 32 ]; then src=ycode-icon-small.svg; else src=ycode-icon.svg; fi
    rsvg-convert -w "$1" -h "$1" "$src" -o "$2"
}
rm -rf hicolor
for s in 16 22 24 32 48 64 128 256 512; do
    mkdir -p "hicolor/${s}x${s}/apps"
    render "$s" "hicolor/${s}x${s}/apps/$APP_ID.png"
done
mkdir -p hicolor/scalable/apps
cp ycode-icon.svg "hicolor/scalable/apps/$APP_ID.svg"
if command -v iconutil >/dev/null 2>&1; then
    set_dir="$(mktemp -d)/Ycode.iconset"
    mkdir -p "$set_dir"
    for s in 16 32 128 256 512; do
        render "$s" "$set_dir/icon_${s}x${s}.png"
        render "$((s * 2))" "$set_dir/icon_${s}x${s}@2x.png"
    done
    iconutil -c icns -o Ycode.icns "$set_dir"
    rm -rf "$(dirname "$set_dir")"
fi
