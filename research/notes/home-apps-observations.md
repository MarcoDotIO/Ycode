# Observations: default apps of a fresh simulator device (2026-10-19)

Dirty-room notes by HOME-APPS-SPEC. Prose only. The clean result is
`specs/simulator/home-apps.md`.

## Why this was looked at

The user reported that Ycode's simulator is missing default apps (Notes,
Maps, Clock, …). The question was whether the reference simulator shows
them. It does not.

## Devices used

All on this Mac, created and deleted by this session:

| Name | Device type | Runtime |
|---|---|---|
| `ycode-test-homeapps` | iPhone Duo | iOS 27.1 (24A94401) |
| `ycode-test-homeapps-ipad` | iPad Pro 11-inch (M5) | iOS 27.0 (24A434) |
| `ycode-test-homeapps-iphone270` | iPhone 18 Pro | iOS 27.0 (24A434) |

The iPad was planned on 27.1, but `simctl create` refused it
("Incompatible device", CoreSimulator error 403). `simctl list runtimes -j`
shows that 27.1's `supportedDeviceTypes` contains only "iPhone Duo". So
27.1 is a narrow runtime made for one device. The 27.0 iPhone was added to
separate "iPad versus iPhone" from "27.0 versus 27.1".

## What I saw, in order

1. `listapps` on the 27.1 iPhone returned 22 records. The only ones that a
   user would call apps are Settings and Safari. The others are poster
   apps, Web, Xcode Previews and service apps in `CoreServices`.
2. The listing of `RR/Applications` has 243 entries, including
   `MobileNotes.app`, `MobileTimer.app`, `Calculator.app`, `Camera.app`
   and `MobileMail.app`. That looked like a contradiction. On a closer look
   these directories have no `Info.plist` and no executable: only `.lproj`
   folders and `PlugIns`/`Extensions` folders whose `.appex` directories
   are also empty of plists. I call them husks. 104 of the bundle-named
   directories in `Applications` and `CoreServices` are husks. The 27.0
   runtime has the same husks for Notes, Clock, Calculator, Camera and
   Mail, so no current simulator runtime has these apps.
3. Maps, Calendar, Photos, Messages and 13 others are real apps in 27.0
   and simply not present in 27.1. The 27.1 runtime was built without
   them. `Rushmore.app` is a husk that only 27.1 has.
4. `IconState.plist` of the 27.1 device: one page with Settings, dock with
   Safari, Today view with Batteries and Screen Time. This agrees with
   what `device-capabilities.md` §4 and `home-screen.md` §1 recorded
   earlier.
5. `DesiredIconState.plist` holds the full iPhone layout (four dock apps,
   two pages, two folders). It is a copy of SpringBoard's bundled
   `DefaultIconState-466w-678h~iphone.plist`: 466 × 678 points is the
   iPhone Duo cover screen (1398 × 2034 at scale 3). The generic
   `~iphone` file differs from it only in the Today list, and the device's
   Today list matches the 466w-678h one. So SpringBoard picks the file by
   idiom and point size.
6. Comparing desired and actual layouts on the three devices gives the
   filtering rules in the spec (§3.4): absent apps are dropped, single
   widgets left over from stacks become plain widgets, empty folders go,
   unlisted visible apps are appended (Wallet on the iPad), apps whose
   `SBAppTags` name a false capability are hidden (Watch on the iPad,
   `watch-companion`).
7. `listapps` hides more than the `hidden` tag: six apps with
   `LSApplicationLaunchProhibited` (Messages extension wrappers) are not
   listed either. 134 hidden + 6 prohibited + 22 visible = 162, the
   registration count of `first-boot.md`. The 163rd bundle with an
   Info.plist, `AccessibilityReader_iOS.app`, has no executable.

## Screenshots and the second display

The first `simctl io screenshot` of the 27.1 iPhone was all black. `simctl
io enumerate` shows two class-0 displays: `LCD` 1398 × 2034 and `LCD-1`
2007 × 2853. The iPhone Duo is a folding device. The default screenshot
display is `LCD-1`, the inner screen, which is dark while folded. With
`--display=LCD` the home screen appeared: Settings at the top left, Safari
on a dock tile at the right edge, status at the top right, search button
at the bottom right. The layout is turned sideways compared with a normal
iPhone. Anyone comparing Ycode screenshots with the Mac must pass
`--display=LCD`.

## Launches

- Settings, Safari, Web and Xcode Previews returned a pid at once.
- At 4 s after launch Settings still showed a black frame with a status
  bar. At 12 s it showed its list (Apple Account row, then General,
  Accessibility, …). Wait at least 10 s before comparing.
- Safari was in front after 15 s but drew only a white page. The host was
  very loaded at that time, so this is not a reliable description of its
  first screen.
- Four poster apps failed with FrontBoard's "unknown to FrontBoard"
  (NotFound). Each failure took several minutes.
- VoiceOver launched (pid).
- I started the remaining launch requests (more posters, `CoreServices`
  apps, and Notes/Clock/Maps/Calculator as negative controls) in parallel.
  All but VoiceOver were still waiting after 300 s and were killed. The
  load average on the Mac was 870 at that time. Other sessions were
  running five more `ycode-test-*` simulators, which I did not touch, and
  a Swift build. Running the launches in parallel was a mistake; it made
  the load worse. The iPad launch loop also stalled on its first app
  (Messages) and was stopped.

## App Library

Not observed. `simctl` has no swipe. The iOS-simulator control tool
returned an internal error for screenshots of these devices (possibly the
two-display device), and I did not drive the Simulator GUI. Open question
in the spec.

## Things deliberately not done

No disassembly, no decompilation, no Ghidra, no reference-tools folder.
No Apple images or plists were copied into the repository. Screenshots and
listapps dumps stayed in the session scratch area.
