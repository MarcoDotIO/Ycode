# Spec: the apps on a fresh device's home screen

Status: **reference** (HOME-APPS-SPEC, 2026-10-19). It records which apps
the reference simulator shows on a freshly created device, where they come
from in the runtime, how the home screen learns about them, and what this
means for Ycode. It answers the report "Ycode's simulator is missing
default apps (Notes, Maps, Clock, …)".

Facts come from three throwaway devices on this Mac (level 3: `simctl
create`, `boot`, `listapps`, `launch`, `io screenshot`), from plists in the
runtime and in the device directory read with `plutil` as file formats
(level 2), and from bundle structure and Info.plist keys (level 4). No
disassembly or decompilation was used. Screenshots stayed in the scratch
area; none are in the repository.

Terms: **RR** (RuntimeRoot), **DEV** (the device directory), as in
`launchd-sim.md`. "Visible" means listed by `simctl listapps`: it omits
apps whose Info.plist `SBAppTags` contains `hidden` and apps with
`LSApplicationLaunchProhibited` = true.

## 1. Summary

1. **The reference shows two apps.** A fresh iOS 27.1 (24A94401) device of
   type iPhone Duo (model `iPhone19,4`, the device Ycode uses) shows
   **Settings** on page 1 and **Safari** in the dock. Nothing else: no
   other page, no folder, no widget on the home screen. This is the
   runtime's content, not a fault of the reference. Ycode already shows
   the same two icons (`home-screen.md` §1), so for this runtime Ycode's
   app set is correct.
2. **Notes, Clock, Maps and the other apps of a real iPhone are not in the
   runtime.** Notes, Clock, Calculator, Camera, Mail and about 100 other
   bundles in `RR/Applications` are empty directories ("husks"): they hold
   only `.lproj` folders and empty `PlugIns`/`Extensions` folders, with no
   `Info.plist` and no executable. Maps, Calendar, Photos, Messages and 13
   other apps that the iOS 27.0 runtime ships are not in the 27.1 runtime
   at all (§4). Ycode must not show these apps. Ycode must match the
   simulator, not a device.
3. **The iOS 27.1 runtime supports one device type only.** Its
   `supportedDeviceTypes` list is "iPhone Duo". `simctl create` with any
   iPad device type and this runtime fails with "Incompatible device"
   (CoreSimulator error 403). For iPad, the iPad data in §5 comes from the
   iOS 27.0 runtime (24A434), the newest one that supports iPads.

## 2. The reference home screen (iOS 27.1, iPhone Duo)

### 2.1 Layout

From `DEV/data/Library/SpringBoard/IconState.plist`, after the first boot,
and from the screenshot of the cover display:

| Place | Content |
|---|---|
| Page 1 (`iconLists[0]`) | `com.apple.Preferences` (Settings), one icon |
| Other pages | none |
| Dock (`buttonBar`) | `com.apple.mobilesafari` (Safari), one icon |
| Folders | none |
| Widgets on pages | none |
| Today view (`today`) | two widgets: Batteries (`com.apple.Batteries.BatteriesAvocadoWidgetExtension`, kind `BatteriesAvocadoWidget`, `small`) and Screen Time (`com.apple.ScreenTimeWidgetApplication.ScreenTimeWidgetExtension`, `large`) |
| `ignored` | key not present |
| App Library | not observed (see §8); expected to hold the same two apps |

What the cover display shows (screenshot `--display=LCD`, 1398 × 2034):
the default wallpaper; Settings with its label at the top left; the
camera cut-out, the time and the Wi-Fi indicator in a column at the top
right; Safari, without a label, on a glass dock tile at the right edge,
about two thirds down; the search button at the bottom right. The home
screen is drawn sideways compared with a usual iPhone (dock on the right,
status at the top right).

### 2.2 Two displays

The iPhone Duo device has two built-in displays (`simctl io enumerate`,
class 0):

| Screen name | Size | State on a fresh device |
|---|---|---|
| `LCD` | 1398 × 2034 | the cover display; shows the home screen |
| `LCD-1` | 2007 × 2853 | the inner display; black (the device is folded) |

`simctl io <dev> screenshot` without `--display` takes `LCD-1` and gives a
black image. Comparisons with Ycode must use `--display=LCD`. Ycode's
single display (1398 × 2034, `device-capabilities.md` §3) is the cover
display.

### 2.3 App table

All bundles are under RR. "Launches" is the result of `simctl launch` on
the booted reference device. The table has every app that `listapps`
reports (22), plus the apps of a real iPhone that are asked about.

**On the home screen**

| Display name | Bundle identifier | Path | Place | Launches | First screen / notes |
|---|---|---|---|---|---|
| Settings | `com.apple.Preferences` | `Applications/Preferences.app` | page 1, first slot | yes (pid returned) | large title "Settings"; an Apple Account sign-in row, an "Optimizing Search and Siri" row, then General, Accessibility, Appearance, Home Screen & App Library, Search, Siri, StandBy, … |
| Safari | `com.apple.mobilesafari` | `Applications/MobileSafari.app` | dock, only icon | yes (pid returned) | the app comes to the front; in 15 s on a heavily loaded host it showed a white page with the home indicator (start page not yet drawn) |

**Registered and visible, but not on the home screen**

| Display name | Bundle identifier | Path | Launches | Notes |
|---|---|---|---|---|
| Web | `com.apple.webapp` | `Applications/Web.app` | yes (pid) | web-clip host |
| Xcode Previews | `com.apple.PreviewShell` | `Applications/PreviewShell.app` | yes (pid) | Info.plist `SBIconVisibilityDefaultVisible` = false |
| Color | `com.apple.GradientPoster` | `Applications/GradientPoster.app` | no | poster app; FrontBoard: "Application … is unknown to FrontBoard" (`FBSOpenApplicationServiceErrorDomain` 1, reason NotFound) |
| Emoji | `com.apple.EmojiPoster` | `Applications/EmojiPoster.app` | no | as Color |
| Image Playground | `com.apple.Posters.ImagePlaygroundPosterApp` | `Applications/ImagePlaygroundPosterApp.app` | no | as Color |
| Kaleidoscope | `com.apple.Posters.KaleidoscopePosterApp` | `Applications/KaleidoscopePosterApp.app` | no | as Color |
| Pride | `com.apple.PridePoster` | `Applications/PridePosterApp.app` | not determined | poster app |
| Unity | `com.apple.Posters.UnityPosterApp` | `Applications/UnityPosterApp.app` | not determined | poster app |
| Weather Wallpaper | `com.apple.Posters.WeatherPosterApp` | `Applications/WeatherPosterApp.app` | not determined | poster app (not the Weather app) |
| VoiceOver | `com.apple.VoiceOverTouch` | `System/Library/CoreServices/VoiceOverTouch.app` | yes (pid) | accessibility service app |
| AssistiveTouch | `com.apple.assistivetouchd` | `System/Library/CoreServices/AssistiveTouch.app` | not determined | |
| Astronomy | `com.apple.NanoUniverse.AegirProxyApp` | `System/Library/CoreServices/AegirProxyApp.app` | not determined | |
| CarPlay | `com.apple.CarPlayApp` | `System/Library/CoreServices/CarPlay.app` | not determined | |
| EscrowSecurityAlert | `com.apple.EscrowSecurityAlert` | `System/Library/CoreServices/EscrowSecurityAlert.app` | not determined | |
| FullKeyboardAccess | `com.apple.fullkeyboardaccess` | `System/Library/CoreServices/FullKeyboardAccess.app` | not determined | |
| Live Captions | `com.apple.livetranscriptionui` | `System/Library/CoreServices/LiveTranscriptionUI.app` | not determined | |
| ShortcutsActions | `com.apple.ShortcutsActions` | `System/Library/CoreServices/ShortcutsActions.app` | not determined | |
| SystemIntents | `com.apple.SystemIntents` | `System/Library/CoreServices/SystemIntents.app` | not determined | |
| Voice Control | `com.apple.commandandcontrol` | `System/Library/CoreServices/CommandAndControl.app` | not determined | |
| SpringBoard | `com.apple.springboard` | `System/Library/CoreServices/SpringBoard.app` | — | the home screen itself |

"Not determined": the launch request did not finish within 300 s. The host
was heavily loaded at that time (load average above 800, other agents'
simulators running). The poster failures took several minutes each. None
of these apps is on the home screen, so this does not change the layout.

**Not in this runtime (must not appear in Ycode)**

| App | Bundle identifier (from the default layout) | State in the 27.1 runtime | In the 27.0 runtime |
|---|---|---|---|
| Notes | `com.apple.mobilenotes` | husk `Applications/MobileNotes.app` | husk |
| Clock | `com.apple.mobiletimer` | husk `Applications/MobileTimer.app` | husk |
| Calculator | `com.apple.calculator` | husk `Applications/Calculator.app` | husk |
| Camera | `com.apple.camera` | husk `Applications/Camera.app` | husk |
| Mail | `com.apple.mobilemail` | husk `Applications/MobileMail.app` | husk |
| FaceTime, Music, App Store, TV, Books, Podcasts, Freeform, Journal, Measure, Magnifier, Image Playground (app), Games, Translate | various | husks (`FaceTime.app`, `Music.app`, `AppStore.app`, `AppleTV.app`, `Books.app`, `Podcasts.app`, `Freeform.app`, `Journal.app`, `Measure.app`, `Magnifier.app`, `Image Playground.app`, `Games.app`, `SequoiaTranslator.app`) | husks |
| Maps | `com.apple.Maps` | **absent** | app (`Applications/Maps.app`) |
| Calendar | `com.apple.mobilecal` | absent | app (`MobileCal.app`) |
| Photos | `com.apple.mobileslideshow` | absent | app (`Photos.app`) |
| Messages | `com.apple.MobileSMS` | absent | app (`MobileSMS.app`) |
| Contacts | `com.apple.MobileAddressBook` | absent | app (`Contacts.app`) |
| Files | `com.apple.DocumentsApp` | absent | app (`Files.app`) |
| Reminders | `com.apple.reminders` | absent | app (`Reminders.app`) |
| News | `com.apple.news` | absent | app (`News.app`) |
| Health | `com.apple.Health` | absent | app (`Health.app`) |
| Fitness | `com.apple.Fitness` | absent | app (`Fitness.app`) |
| Wallet | `com.apple.Passbook` | absent | app (`Passbook.app`) |
| Passwords | `com.apple.Passwords` | absent | app (`Passwords.app`) |
| Preview | `com.apple.Preview` | absent | app (`Preview.app`) |
| Shortcuts | `com.apple.shortcuts` | absent | app (`Shortcuts.app`) |
| Siri | `com.apple.SiriApp` | absent | app (`SiriApp.app`) |
| Watch | `com.apple.Bridge` | absent | app (`Bridge.app`) |
| Remote | `com.apple.TVRemoteApp` | absent | app (`TVRemote.app`) |
| Phone, Weather, Stocks, Find My, Home, Voice Memos, Compass, Tips, Sports, Apple Store, GarageBand, iMovie, Keynote, Numbers, Pages | various | no bundle | no bundle |

A launch request for Notes, Clock, Maps or Calculator on the reference did
not start anything (no pid within 300 s). There is no app record for them,
so nothing can be launched.

## 3. Where the apps come from

### 3.1 Bundles in the runtime

| Directory | Bundles | With Info.plist | Notes |
|---|---|---|---|
| `RR/Applications` | 243 (27.1), 259 (27.0) | 152 (27.1) | the rest are husks (no Info.plist) |
| `RR/System/Library/CoreServices` | 11 `.app` with Info.plist in 27.1 | 11 | SpringBoard and service apps |

In 27.1, 163 bundles in these two directories have an Info.plist. One of
them, `AccessibilityReader_iOS.app`, has no executable. That leaves 162,
the number of apps that lsd registers on the first boot
(`first-boot.md` §1 item 5). Of the 162, 134 have `hidden` in `SBAppTags`;
6 have `LSApplicationLaunchProhibited` = true (Messages extension
wrappers: `com.apple.ActivityMessagesApp`, `com.apple.Animoji.StickersApp`,
`com.apple.icloud.apps.messages.business`,
`com.apple.siri.parsec.HashtagImagesApp`, `com.apple.Jellyfish`,
`com.apple.Stickers.UserGenerated`); 22 are visible (§2.3).

A **husk** is a directory named like an app bundle, with localization
folders and empty `PlugIns` or `Extensions` subfolders, without
`Info.plist` and without executable. The scanner that seeds the
LaunchServices database does not register it (no Info.plist), so for the
system it does not exist. A host that copies the runtime must copy the
husks as they are, but nothing depends on them.

### 3.2 Registration at first boot

1. lsd seeds its database on its first start (`first-boot.md` §1 item 5):
   MobileInstallation's scanner reads every bundle in the directories of
   §3.1 and LaunchServices registers each one as an app record
   (`home-screen.md` §3.3). Only bundles with Info.plist and executable
   become records.
2. If the host makes LaunchServices register apps as *placeholders*
   (`home-screen.md` §3.2–§3.3), SpringBoard shows the icons as grey
   placeholders and the apps do not launch.
3. `simctl listapps` lists the records that are not tagged `hidden`.

### 3.3 The default layout: SpringBoard's own plists

SpringBoard carries its default layouts in its bundle,
`RR/System/Library/CoreServices/SpringBoard.app/`, as XML property lists:

| File | Used for |
|---|---|
| `DefaultIconState-466w-678h~iphone.plist` | phones with a 466 × 678 point screen: the iPhone Duo cover display (1398 × 2034 at scale 3) |
| `DefaultIconState-375w-667h~iphone.plist`, `-414w-736h~iphone`, `-568h~iphone`, `-568h~ipod` | other phone sizes |
| `DefaultIconState~iphone.plist` | phones without a size-specific file |
| `DefaultIconState~ipad.plist` | iPads |
| `DefaultIconState.plist` | the fallback |
| `../PrivateFrameworks/DashBoard.framework/DefaultIconState_CarDisplay.plist` | CarPlay |

The file is chosen by idiom and by screen size in points. The
`DesiredIconState.plist` that the iPhone Duo device writes is the 466w-678h
file (its Today list matches that file, not the generic `~iphone` one,
which differs in two Today widgets). The 27.0 and 27.1 runtimes have the
same `~iphone` and `~ipad` files; 27.0 has no 466w-678h file.

**Format.** A dictionary:

| Key | Type | Meaning |
|---|---|---|
| `buttonBar` | array of bundle identifiers | the dock, in order |
| `iconLists` | array of pages; each page an array of elements | home-screen pages |
| `today` | array of widget dictionaries | the Today view |
| `ignored` | array of bundle identifiers | apps not placed on pages (`com.apple.TVRemoteApp`) |
| `dockUtilities` | array | iPad only, empty |
| `listUniqueIdentifiers` | array of UUID strings | page identifiers (some files) |

A page element is a bundle-identifier string (an app), a folder dictionary
(`defaultDisplayName`, `iconLists` = one array of identifiers), a widget
dictionary (`elementType` `widget`, `bundleIdentifier` of the widget
extension, `containerBundleIdentifier` of the app, `widgetIdentifier`,
`gridSize` `small`/`medium`/`large`/…, `iconType` `custom`,
`allowsSuggestions`, `allowsExternalSuggestions`) or a stack dictionary
(the same keys with `elements`, an array of widget dictionaries or
`{elementType: files}`). Default files mark suggested widgets with
`widgetSuggestionSource` `onboarding`.

**The default phone layout (the 466w-678h file)** — the full layout of a
real iPhone:

- dock: Phone, Safari, Messages, Music;
- page 1: two small widget stacks (Weather/Maps/Notes, Calendar/News/Photos),
  FaceTime, Calendar, Photos, Camera, Mail, Notes, Clock, Maps, TV, News,
  App Store, Games, Health, Wallet, Siri, Settings;
- page 2: Weather, Stocks, Find My, Home, Podcasts, Books, Fitness, Watch,
  Reminders, Files, Preview, folder "Utilities" (Voice Memos, Compass,
  Measure, Magnifier, Calculator, Shortcuts, Passwords), Contacts, iTunes
  Store, Translate, Freeform, Journal, Image Playground, Tips, Apple Store,
  folder "Creativity" (GarageBand, iMovie, Keynote, Numbers, Pages),
  Sports;
- `ignored`: Remote.

### 3.4 From the default layout to `IconState.plist`

On the first boot SpringBoard writes two files in `DEV/data/Library/SpringBoard/`:

- `DesiredIconState.plist`: the chosen default file as it is, plus
  `metadata.creationDate`, plus `dockUtilities` (empty array) when the
  default file has none: the iPhone Duo's file has it although the
  466w-678h default file does not (27.1, 2026-10-20 observation,
  `app-launch.md` §8 Q3);
- `IconState.plist`: what the home screen shows. It is the default layout
  **filtered by the app records**:

| Rule (observed on three devices) | Example |
|---|---|
| An identifier with no visible app record is removed from pages, folders and the dock. The dock is not refilled. | 27.1 iPhone: dock Phone, Safari, Messages, Music → Safari |
| A widget whose container app has no record is removed; a stack keeps its remaining widgets; a stack with one widget left becomes a plain widget | 27.0 iPhone: stack Weather/Maps/Notes → a Maps widget |
| A folder keeps its remaining apps; an empty folder is removed | 27.0 iPhone: "Utilities" with Shortcuts and Passwords; "Creativity" removed |
| Remaining items close up; empty pages are removed | 27.1 iPhone: one page with Settings |
| A visible app with a record that the layout does not name is added at the end of the last page | 27.0 iPad: Wallet after Fitness |
| An app whose `SBAppTags` names a device capability that is false is not shown | 27.0 iPad: Watch (`SBAppTags` `watch-companion`; capability `watch-companion` false on iPad) |
| Apps in `ignored` are not placed | Remote |
| Registered apps that SpringBoard never places | posters, Web, Xcode Previews, the `CoreServices` apps (see §8) |
| Today widgets of absent apps are removed | 27.1 iPhone: only Batteries and Screen Time remain |

The plist that the device type carries (`capabilities.plist`, key
`iconState`) is not used (`device-capabilities.md` §1).

Consequence for a host: the home screen is decided by SpringBoard from
three inputs that the host supplies — the runtime's bundles (§3.1), correct
LaunchServices records (§3.2) and the device answers (`idiom`, screen size
and the capabilities named in `SBAppTags`; `device-capabilities.md`). If
an app that the reference shows is missing in Ycode, check these in that
order.

## 4. The 27.1 runtime is reduced

Compared with the iOS 27.0 runtime (24A434) that ships with the same
Xcode, `RR/Applications` of 27.1 lacks these 17 bundles: `Bridge.app`,
`Contacts.app`, `Files.app`, `Fitness.app`, `Health.app`, `Maps.app`,
`MobileCal.app`, `MobileSMS.app`, `News.app`, `Passbook.app`,
`Passwords.app`, `Photos.app`, `Preview.app`, `Reminders.app`,
`Shortcuts.app`, `SiriApp.app`, `TVRemote.app`; it adds the husk
`Rushmore.app`. Everything else in the two directory listings is the same
by name. The 27.1 runtime supports only the iPhone Duo device type.

For comparison, a fresh iOS 27.0 iPhone 18 Pro (level 3) shows: dock
Safari, Messages; page 1 a small Maps widget, a small stack
Calendar/News/Photos, Calendar, Photos, Maps, News, Health, Wallet, Siri,
Settings; page 2 Fitness, Watch, Reminders, Files, Preview, folder
"Utilities" (Shortcuts, Passwords), Contacts. Notes, Clock, Camera, Mail
and Calculator are husks there too; no Xcode simulator runtime examined
ships them.

## 5. iPad (iOS 27.0 runtime, iPad Pro 11-inch (M5))

The 27.1 runtime cannot create an iPad (§1 item 3). On iOS 27.0 (24A434), a
fresh iPad Pro 11-inch (M5) shows, from `IconState.plist` and a screenshot:

| Place | Content |
|---|---|
| Dock | Messages, Safari, Calendar, Photos, Siri; then, at the right end, the App Library button (a tile of small icons) |
| Page 1 | a large stack News/Maps/Photos, a large stack Reminders/Files, a medium Calendar "Up Next" widget, then Files, Reminders, Maps, News, Settings |
| Page 2 | Contacts, Shortcuts, Passwords, Preview, Health, Fitness, Wallet |
| `ignored` | Remote |
| Not shown | Watch (capability `watch-companion` false) |

Visible apps (`listapps`, 39 records with the system ones): the 22 of the
27.1 iPhone plus Calendar, Contacts, Files, Fitness, Health, Maps,
Messages, News, Passwords, Photos, Preview, Reminders, Remote, Shortcuts,
Siri, Wallet, Watch (same bundle identifiers and paths as in §2.3's last
table, column 27.0).

Differences from the phone:

- default file `DefaultIconState~ipad.plist`: dock of eight (Messages,
  Safari, Music, Mail, Calendar, Photos, Notes, Siri), larger widgets
  (`large` stacks, a files element), a different page order;
- `IconState.plist` on iPad carries `listMetadata` per page:
  `rotatedOrder` (the order in the other orientation), `fixedLocations`,
  `fixedLocationsGridColumns` 4, `fixedLocationsGridRows` 6,
  `rotatedFixedLocations` (Settings at 18);
- the iPad device type answers `ipad` true, `hide-non-default-apps` true,
  `telephony`, `sms` and `watch-companion` false; the iPhone Duo answers
  the opposite;
- the dock ends with the App Library button.

Launches on the iPad were not determined (the host was overloaded; §8).

## 6. Deltas for Ycode (to be verified by the implementer)

| # | Item | Reference | Ycode (from its specs) | Action |
|---|---|---|---|---|
| 1 | App set on the home screen | Settings (page 1), Safari (dock) | the same (`home-screen.md` §1, §2.3) | none; Notes, Clock, Maps etc. must **not** be added — the runtime does not have them |
| 2 | Today view | Batteries, Screen Time widgets | not specified | check `IconState.plist` `today` after a fresh Ycode boot |
| 3 | `DesiredIconState.plist` | written on first boot (466w-678h file), with `metadata.creationDate` and an empty `dockUtilities` array added on the iPhone Duo too; `listUniqueIdentifiers` kept as in the default file (`app-launch.md` §8 Q3) | written by the guest's SpringBoard: the 466w-678h file plus `metadata` and `dockUtilities`, list identifiers kept (`app-launch.md` §6 check 3, 13 devices, 2026-10-20) | none (matches) |
| 4 | Visible app records | 22 (§2.3) | 162 registered, placeholders fixed (`home-screen.md` §3.3) | compare `listapps`-equivalent output (bundle ids, `SBAppTags`) |
| 5 | Settings launches, first screen | yes; Settings list | stage-7 path launches a probe app (`home-screen.md` §6) | launch `com.apple.Preferences` and `com.apple.mobilesafari` with `ylaunch` and compare first screens |
| 6 | Poster apps | not launchable: `FBSOpenApplicationServiceErrorDomain` 1, reason NotFound ("unknown to FrontBoard"), answered after about 12 s (`app-launch.md` §8 Q5, §8.2) | answered: NotFound after `ylaunch`'s 10 s window, no process; domain code 4, not 1 (`app-launch.md` §2.1, Q7) | not a Ycode fault if they fail the same way; a request that is never answered is a difference |
| 7 | Displays | cover `LCD` 1398 × 2034 shows the home screen; inner `LCD-1` 2007 × 2853 black | one display, 1398 × 2034 | compare against `--display=LCD` screenshots only |
| 8 | Home-screen orientation on the cover display | sideways: dock at the right edge, status at the top right | check Ycode screenshots | report if Ycode draws a portrait layout |
| 9 | iPad | needs a runtime that supports iPads (27.0, 24A434) | Ycode uses 27.1 only | iPadOS work must pick another runtime; its app set is larger (§5) |
| 10 | Husks | copied as plain directories | Ycode uses the same runtime image | nothing; they must not be registered |

If the user wants Maps, Calendar, Photos, Messages and the others, the
answer is a different runtime (27.0 ships them), not a change in Ycode.
Notes, Clock, Camera, Mail and Calculator are not in either runtime.

## 7. How to reproduce on the Mac

1. `xcrun simctl create ycode-test-<name> com.apple.CoreSimulator.SimDeviceType.iPhone-Duo com.apple.CoreSimulator.SimRuntime.iOS-27-1`, `boot`, `bootstatus -b`.
2. `xcrun simctl listapps <udid>` (an XML plist).
3. `plutil -p ~/Library/Developer/CoreSimulator/Devices/<udid>/data/Library/SpringBoard/IconState.plist`.
4. `xcrun simctl io <udid> screenshot --display=LCD <file>`.
5. `xcrun simctl launch <udid> <bundle id>`; wait at least 10 s before the screenshot (at 4 s Settings still showed a black frame).
6. Shut down and delete the device.

## 8. Open questions

- **App Library** contents were not observed (no headless way to swipe;
  the GUI was not driven). Expected: Settings and Safari only.
- **Why SpringBoard never places** the poster apps, Web and the
  `CoreServices` apps although they are visible records without the
  `hidden` tag. Info.plist shows no common key (only Xcode Previews has
  `SBIconVisibilityDefaultVisible` = false). This is SpringBoard's own
  behavior and needs no host support, so it was not pursued.
- **Launch results** marked "not determined" in §2.3 and all iPad launches:
  repeat on an idle host.
- **Safari's first screen** under normal load (a white page after 15 s
  under heavy load).

## Evidence

| Claim | Level | Source |
|---|---|---|
| Home screen of a fresh 27.1 iPhone Duo (§2.1) | 2, 3 | `IconState.plist` via `plutil`; `simctl io screenshot --display=LCD` |
| Two displays, default screenshot display (§2.2) | 3 | `simctl io enumerate`; screenshots of both displays |
| Visible app records, display names, paths (§2.3) | 3 | `simctl listapps` on the 27.1 iPhone, 27.0 iPhone and 27.0 iPad |
| Launch results (§2.3) | 3 | `simctl launch` return value and error text; screenshots after the launch |
| Husks, absent bundles, bundle counts (§2.3, §3.1, §4) | 4 | directory listings of both runtimes; presence of `Info.plist` and the `CFBundleExecutable` file |
| `SBAppTags`, `LSApplicationLaunchProhibited`, `UIDeviceFamily`, `SBIconVisibilityDefaultVisible` | 4 | Info.plist of each bundle via `plistlib` |
| 162 registered apps | 3 | `first-boot.md` §1 item 5, consistent with the count above |
| 27.1 supports only iPhone Duo; iPad create fails (§1 item 3) | 3 | `simctl list runtimes -j` (`supportedDeviceTypes`); `simctl create` error 403 |
| Default layout files and format (§3.3) | 2 | SpringBoard.app's `DefaultIconState*.plist` via `plutil`/`plistlib` |
| Desired = 466w-678h file | 2 | comparison of `DesiredIconState.plist` with the default files |
| `dockUtilities` added to the iPhone's Desired file; list identifiers kept; poster apps answered after ≈12 s | 2, 3 | new 27.1 iPhone Duo device, 2026-10-20 (`app-launch.md` §8) |
| Ycode's Desired file matches (§6 item 3) | 2 | 13 Ycode device directories on the Thor, `DesiredIconState.plist` compared key by key with the runtime's default file (`plistlib`), 2026-10-20 |
| Filtering rules (§3.4) | 2, 3 | `DesiredIconState.plist` against `IconState.plist` on three fresh devices |
| Device capabilities (§5) | 2 | the device types' `capabilities.plist` |
| 27.0 iPhone and iPad layouts (§4, §5) | 2, 3 | `IconState.plist`, screenshots |
| Ycode's side (§6) | — | `home-screen.md`, `first-boot.md`, `device-capabilities.md` |

Level 5 was not used. The reference tools folder, `research/dirty/` and
Ghidra were not opened. No Apple images, strings files or plists were
copied into the repository; bundle identifiers, file names and plist keys
are recorded as interoperability facts.
