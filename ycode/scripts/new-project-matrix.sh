#!/bin/bash
# Creates every New Project template (and the option combinations the
# done-criterion lists) with `ycode new`, then builds each with Ycode's
# build path (`ycode build --engine swift-build`). Prints one line per
# project and a summary; exits 1 when any build fails.
#
#   scripts/new-project-matrix.sh <work-dir> [filter-regex]
#
# Needs `swbuild` (YCODE_SWBUILD, or YCODE_SWB's sibling; see
# `SwiftBuildEngine.locate`). Packages build with `swift build`.
set -u
work=${1:?usage: new-project-matrix.sh <work-dir> [filter]}
filter=${2:-.}
here=$(cd "$(dirname "$0")/.." && pwd)
ycode=${YCODE_BIN:-$here/.build/debug/ycode}
mkdir -p "$work"
pass=0; fail=0; failed=()

# name|template|destination|options...
cases=()
add() { cases+=("$*"); }
AU="audioUnitSubtypeCode=demo|audioUnitManufacturerCode=Demo|ORGANIZATIONNAME=Ycode"
for i in SwiftUI Storyboard; do
  for t in None XCTest "Swift Testing"; do
    for s in None SwiftData "Core Data"; do
      n="Ios${i:0:2}$(echo "$t" | tr -d ' ' | cut -c1-4)$(echo "$s" | tr -d ' ' | cut -c1-4)"
      add "$n|ios.app|generic/platform=iOS Simulator|userInterface=$i|testingSystem=$t|storageType=$s"
    done
  done
done
add "IosObjC|ios.app|generic/platform=iOS Simulator|userInterface=Storyboard|languageChoice=Objective-C|testingSystem=XCTest"
add "IosCloud|ios.app|generic/platform=iOS Simulator|storageType=SwiftData|hostInCloudKit=true"
add "MpApp|multiplatform.app|platform=macOS|storageType=SwiftData|testingSystem=Swift Testing"
add "MpAppIos|multiplatform.app|generic/platform=iOS Simulator|storageType=Core Data|hostInCloudKit=true"
add "MpDoc|multiplatform.document-app|platform=macOS|testingSystem=XCTest"
add "MpDocData|multiplatform.document-app|generic/platform=iOS Simulator|storageTypeDocument=SwiftData"
for g in RealityKit SceneKit SpriteKit Metal; do add "MpGame$g|multiplatform.game|platform=macOS|gameType=$g"; done
add "MpGameIos|multiplatform.game|generic/platform=iOS Simulator|gameType=SpriteKit"
for g in SceneKit SpriteKit Metal; do add "IosGame$g|ios.game|generic/platform=iOS Simulator|gameType=$g|testingSystem=XCTest"; done
add "IosGameGK|ios.game|generic/platform=iOS Simulator|gameType=SpriteKit|integrateGK=true"
for g in RealityKit SceneKit SpriteKit Metal; do add "MacGame$g|macos.game|platform=macOS|gameType=$g"; done
for g in RealityKit SceneKit SpriteKit Metal; do add "TvGame$g|tvos.game|generic/platform=tvOS Simulator|gameType=$g"; done
add "MpAU|multiplatform.audio-unit-extension-app|platform=macOS|$AU|audioUnitType=Effect"
add "MpAUInst|multiplatform.audio-unit-extension-app|generic/platform=iOS Simulator|$AU|audioUnitType=Instrument|hasUserInterface=No User Interface"
add "MpSafari|multiplatform.safari-extension-app|platform=macOS"
add "MpKit|multiplatform.framework|platform=macOS|testingSystem=Swift Testing"
add "IosDoc|ios.document-app|generic/platform=iOS Simulator"
add "IosDocUIKit|ios.document-app|generic/platform=iOS Simulator|userInterface=Storyboard"
add "IosAR|ios.augmented-reality-app|generic/platform=iOS Simulator"
add "IosARSceneKit|ios.augmented-reality-app|generic/platform=iOS Simulator|contentType=SceneKit|userInterface=Storyboard"
add "IosARSpriteKit|ios.augmented-reality-app|generic/platform=iOS Simulator|contentType=SpriteKit|userInterface=Storyboard"
add "IosStickers|ios.sticker-pack-app|generic/platform=iOS Simulator"
add "IosMessages|ios.imessage-app|generic/platform=iOS Simulator"
add "IosSafari|ios.safari-extension-app|generic/platform=iOS Simulator"
add "IosKit|ios.framework|generic/platform=iOS Simulator|testingSystem=XCTest"
add "IosKitObjC|ios.framework|generic/platform=iOS Simulator|languageChoice=Objective-C"
add "IosLib|ios.static-library|generic/platform=iOS Simulator"
add "IosLibObjC|ios.static-library|generic/platform=iOS Simulator|languageChoice=Objective-C"
add "IosShaders|ios.metal-library|generic/platform=iOS Simulator"
for i in SwiftUI Storyboard XIB; do add "MacApp$i|macos.app|platform=macOS|userInterface=$i|testingSystem=XCTest"; done
add "MacAppObjC|macos.app|platform=macOS|userInterface=XIB|languageChoice=Objective-C"
add "MacAppData|macos.app|platform=macOS|storageType=Core Data|hostInCloudKit=true"
for i in SwiftUI Storyboard XIB; do add "MacDoc$i|macos.document-app|platform=macOS|userInterface=$i"; done
add "MacDocCoreData|macos.document-app|platform=macOS|userInterface=XIB|storageTypeDocument=Core Data"
for l in Swift Objective-C C++ C; do add "Tool$(echo $l | tr -d '+-')|macos.command-line-tool|platform=macOS|languageChoice=$l"; done
add "MacSafari|macos.safari-extension-app|platform=macOS"
add "MacKit|macos.framework|platform=macOS|testingSystem=Swift Testing"
for f in Cocoa STL None; do for t in Dynamic Static; do add "MacLib$f$t|macos.library|platform=macOS|libraryFramework=$f|libraryType=$t"; done; done
add "MacXPC|macos.xpc-service|platform=macOS"
add "MacXPCLow|macos.xpc-service|platform=macOS|apiLevel=Low Level"
add "MacBundle|macos.bundle|platform=macOS|bundleExtension=plugin"
add "MacShaders|macos.metal-library|platform=macOS"
add "MacKext|macos.generic-kernel-extension|platform=macOS"
add "MacIOKit|macos.iokit-driver|platform=macOS"
add "MacInstaller|macos.installer-plug-in|platform=macOS"
add "MacInstruments|macos.instruments-package|platform=macOS"
add "MacPrefPane|macos.preference-pane|platform=macOS"
add "MacSaver|macos.screen-saver|platform=macOS"
add "WatchOnly|watchos.app|generic/platform=watchOS Simulator|testingSystem=Swift Testing"
add "WatchPair|watchos.app|generic/platform=iOS Simulator|companionAppStyle=Watch App with New Companion iOS App"
add "WatchKit|watchos.framework|generic/platform=watchOS Simulator"
add "WatchLib|watchos.static-library|generic/platform=watchOS Simulator|testingSystem=XCTest"
add "TvApp|tvos.app|generic/platform=tvOS Simulator|testingSystem=XCTest"
add "TvAppSb|tvos.app|generic/platform=tvOS Simulator|userInterface=Storyboard"
add "TvKit|tvos.framework|generic/platform=tvOS Simulator"
add "TvLib|tvos.static-library|generic/platform=tvOS Simulator"
add "TvShaders|tvos.metal-library|generic/platform=tvOS Simulator"
for sc in Window Volume; do
  add "Vision$sc|visionos.app|generic/platform=visionOS Simulator|primarySceneType=$sc|testingSystem=Swift Testing"
  for r in RealityKit Metal; do
    for im in Mixed Progressive Full; do
      add "Vision$sc$r$im|visionos.app|generic/platform=visionOS Simulator|primarySceneType=$sc|secondarySceneType=$r|immersiveSpaceStyle=$im"
    done
  done
done
add "VisionEnv|visionos.immersive-environment-app|generic/platform=visionOS Simulator"
add "VisionEnvProg|visionos.immersive-environment-app|generic/platform=visionOS Simulator|immersiveSpaceStyle=Progressive"
add "VisionKit|visionos.framework|generic/platform=visionOS Simulator"
add "VisionLib|visionos.static-library|generic/platform=visionOS Simulator"
add "Driver|driverkit.driver|generic/platform=DriverKit"
add "DKKit|driverkit.framework|generic/platform=DriverKit"
add "DKLib|driverkit.library|generic/platform=DriverKit"
add "Empty|other.empty|-"
add "External|other.external-build-system|-"
add "PkgLib|package.library|swift|testingSystem=Swift Testing"
add "PkgEmpty|package.empty|-"
add "PkgBuildTool|package.build-tool-plug-in|swift"
add "PkgCommand|package.command-plug-in|swift|testingSystem=XCTest"
add "PkgMacro|package.swift-macro|-"
add "PkgTool|package.macos.command-line-tool|-"
add "PkgExe|package.macos.executable|swift"
add "Playground|ios.app-playground|swift"

for c in "${cases[@]}"; do
  IFS='|' read -r -a f <<< "$c"
  name=${f[0]}; tmpl=${f[1]}; dest=${f[2]}
  [[ "$name $tmpl" =~ $filter ]] || continue
  opts=()
  for o in "${f[@]:3}"; do opts+=(--option "$o"); done
  rm -rf "$work/$name" "$work/$name.swiftpm" "$work/dd-$name"
  out=$("$ycode" new --template "$tmpl" --name "$name" --org org.ycode.matrix ${opts[@]+"${opts[@]}"} "$work" 2>&1)
  if [ $? -ne 0 ]; then echo "FAIL create $name ($tmpl): $out"; fail=$((fail+1)); failed+=("$name"); continue; fi
  log="$work/$name.log"
  case "$dest" in
    -) echo "ok   $name ($tmpl): created, nothing to build"; pass=$((pass+1)); continue ;;
    swift) (cd "$out" && swift build --scratch-path "$work/dd-$name") > "$log" 2>&1; status=$? ;;
    *) scheme=${SCHEME:-$name}
       case "$tmpl" in multiplatform.game) [ "${f[3]}" = "gameType=RealityKit" ] || scheme="$name macOS"; [[ "$dest" == *iOS* ]] && scheme="$name iOS";; multiplatform.safari-extension-app) scheme="$name (macOS)";; esac
       extra=(); [[ "$dest" == *DriverKit* ]] && extra=(CODE_SIGNING_ALLOWED=NO)
       "$ycode" build "$out" -scheme "$scheme" -destination "$dest" -derivedDataPath "$work/dd-$name" --engine swift-build --quiet ${extra[@]+"${extra[@]}"} > "$log" 2>&1; status=$? ;;
  esac
  if [ $status -eq 0 ]; then
    echo "ok   $name ($tmpl, $dest)"; pass=$((pass+1))
  else
    echo "FAIL $name ($tmpl, $dest): see $log"; grep -m5 -E "error|ycode:" "$log" | sed 's/^/       /'
    fail=$((fail+1)); failed+=("$name")
  fi
  rm -rf "$work/dd-$name"
done
echo "passed $pass, failed $fail${failed[*]:+: ${failed[*]}}"
[ $fail -eq 0 ]
