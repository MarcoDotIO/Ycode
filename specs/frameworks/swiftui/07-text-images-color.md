# SwiftUI 7: text and fonts, images and symbols, colours

Status: draft, round 0 (KIT-SWIFTUI, 2026-10-19). Level 3 measurements of
our probe (modes `layout`, `images`, `env`) on the iOS 27.1 simulator,
iPhone Duo, scale 3, unless marked otherwise. These values are what a
SwiftUI app *observes*; they are interop facts an implementation needs
for parity. No font, symbol or image resource was copied.

## 1. Fonts and Dynamic Type

### 1.1 Text styles → point sizes

The system resolves each `Font.TextStyle` to a point size that depends on
the content size category (Dynamic Type). UIKit's
`UIFont.preferredFont(forTextStyle:compatibleWith:)` gave these sizes
(SwiftUI's `Font` text styles map 1:1: `.title` ↔ title1, `.caption` ↔
caption1):

| Style | xS | S | M | **L (default)** | xL | xxL | xxxL | AX1 | AX2 | AX3 | AX4 | AX5 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| largeTitle | 31 | 32 | 33 | **34** | 36 | 38 | 40 | 44 | 48 | 52 | 56 | 60 |
| title1 | 25 | 26 | 27 | **28** | 30 | 32 | 34 | 38 | 43 | 48 | 53 | 58 |
| title2 | 19 | 20 | 21 | **22** | 24 | 26 | 28 | 34 | 39 | 44 | 50 | 56 |
| title3 | 17 | 18 | 19 | **20** | 22 | 24 | 26 | 31 | 37 | 43 | 49 | 55 |
| headline (semibold) | 14 | 15 | 16 | **17** | 19 | 21 | 23 | 28 | 33 | 40 | 47 | 53 |
| subheadline | 12 | 13 | 14 | **15** | 17 | 19 | 21 | 25 | 30 | 36 | 42 | 49 |
| body | 14 | 15 | 16 | **17** | 19 | 21 | 23 | 28 | 33 | 40 | 47 | 53 |
| callout | 13 | 14 | 15 | **16** | 18 | 20 | 22 | 26 | 32 | 38 | 44 | 51 |
| footnote | 12 | 12 | 12 | **13** | 15 | 17 | 19 | 23 | 27 | 33 | 38 | 44 |
| caption1 | 11 | 11 | 11 | **12** | 14 | 16 | 18 | 22 | 26 | 32 | 37 | 43 |
| caption2 | 11 | 11 | 11 | **11** | 13 | 15 | 17 | 20 | 24 | 29 | 34 | 40 |
| extraLargeTitle (UIKit only on iOS) | 33 | 34 | 35 | 36 | 38 | 40 | 42 | 44 | 46 | 48 | 50 | 52 |
| extraLargeTitle2 (UIKit only on iOS) | 25 | 26 | 27 | 28 | 30 | 32 | 34 | 36 | 38 | 40 | 42 | 44 |

All styles use the system UI font family (reported family name
`.AppleSystemUIFont`, regular face for all but headline, which is
semibold; the extra-large titles are bold). SwiftUI's `Font.extraLargeTitle`
and `.extraLargeTitle2` are unavailable on iOS (SDK availability).
`DynamicTypeSize` cases map to the categories in order (`xSmall` … `xxxLarge`,
`accessibility1` … `accessibility5`); `simctl ui content_size
accessibility-large` produced `dynamicTypeSize == .accessibility2`.

### 1.2 Metrics at the default size (UIKit, points)

| Style | ascender | descender | leading | lineHeight | capHeight | xHeight |
|---|---|---|---|---|---|---|
| largeTitle 34 | 32.37 | −8.20 | 0.43 | 40.57 | 23.96 | 17.27 |
| title1 28 | 26.66 | −6.75 | 0.59 | 33.41 | 19.73 | 14.22 |
| title2 22 | 20.95 | −5.31 | 1.75 | 26.25 | 15.50 | 11.37 |
| title3 20 | 19.04 | −4.82 | 1.13 | 23.87 | 14.09 | 10.44 |
| body 17 | 16.19 | −4.10 | 1.71 | 20.29 | 11.98 | 8.95 |
| callout 16 | 15.23 | −3.86 | 1.91 | 19.09 | 11.27 | 8.42 |
| footnote 13 | 12.38 | −3.14 | 2.49 | 15.51 | 9.16 | 6.84 |
| caption1 12 | 11.43 | −2.89 | 1.68 | 14.32 | 8.46 | 6.32 |
| caption2 11 | 10.47 | −2.65 | −0.13 | 13.13 | 7.75 | 5.79 |

Line height ≈ 1.19 × point size for this family; SwiftUI rounds a text
line's height up to the pixel grid (body: 20.29 → 20.33).

### 1.3 SwiftUI text heights per Dynamic Type size

Height of `Text("Ag").font(style)` under `.environment(\.dynamicTypeSize, size)`
(points; widths in `golden-layout.md`):

| style | xSmall | small | medium | large | xLarge | xxLarge | xxxLarge | ax1 | ax2 | ax3 | ax4 | ax5 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| largeTitle | 37 | 38.33 | 39.67 | 40.67 | 43 | 45.67 | 48 | 52.67 | 57.33 | 62.33 | 67 | 71.67 |
| title | 30 | 31.33 | 32.33 | 33.67 | 36 | 38.33 | 40.67 | 45.67 | 51.33 | 57.33 | 63.33 | 69.33 |
| title2 | 23 | 24 | 25.33 | 26.33 | 28.67 | 31.33 | 33.67 | 40.67 | 46.67 | 52.67 | 60 | 67 |
| title3 | 20.33 | 21.67 | 23 | 24 | 26.33 | 28.67 | 31.33 | 37 | 44.33 | 51.33 | 58.67 | 65.67 |
| headline | 17 | 18 | 19.33 | 20.33 | 23 | 25.33 | 27.67 | 33.67 | 39.67 | 48 | 56.33 | 63.33 |
| subheadline | 14.33 | 15.67 | 17 | 18 | 20.33 | 23 | 25.33 | 30 | 36 | 43 | 50.33 | 58.67 |
| body | 17 | 18 | 19.33 | 20.33 | 23 | 25.33 | 27.67 | 33.67 | 39.67 | 48 | 56.33 | 63.33 |
| callout | 15.67 | 17 | 18 | 19.33 | 21.67 | 24 | 26.33 | 31.33 | 38.33 | 45.67 | 52.67 | 61 |
| footnote | 14.33 | 14.33 | 14.33 | 15.67 | 18 | 20.33 | 23 | 27.67 | 32.33 | 39.67 | 45.67 | 52.67 |
| caption | 13.33 | 13.33 | 13.33 | 14.33 | 17 | 19.33 | 21.67 | 26.33 | 31.33 | 38.33 | 44.33 | 51.33 |
| caption2 | 13.33 | 13.33 | 13.33 | 13.33 | 15.67 | 18 | 20.33 | 24 | 28.67 | 34.67 | 40.67 | 48 |

The environment override and the system setting give the same result:
changing the device setting live (`simctl ui content_size`) re-laid out a
body `Text` from 20.67 × 20.33 to 39.67 × 39.67 within one update, without
relaunch (`env` mode, `08-environment-accessibility-localization.md` §1).

### 1.4 Fonts installed in the runtime

`UIFont.familyNames` listed 87 families (e.g. Helvetica Neue, Menlo,
Avenir, PingFang SC/TC/HK, Hiragino, Noto Nastaliq Urdu, Apple Color
Emoji). The system UI font is not in that list (it is reached through the
system-font API), and text rendering connects to the font service
(`com.apple.fontservicesd`, `01-simulator-parity.md` §3.3).

## 2. Text rendering facts

- Default text colour = `Color.primary` (black in light mode, white in
  dark).
- Truncation mode default `.tail`; multiline alignment default `.leading`;
  `lineLimit` default `nil` (environment defaults, `08-environment-accessibility-localization.md` §1).
- Localized string lookup and formatting: `08-environment-accessibility-localization.md` §3.

## 3. Images and SF Symbols

| Case | Observed |
|---|---|
| `UIImage(systemName:)` sizes at the default body configuration | star / star.fill 22 × 20.67 (baseline offset 3.67), heart 20.67 × 18, trash 19 × 21.33, gear 22 × 22, person.crop.circle 19.67 × 19.67, square.and.arrow.up 19 × 22.67, apple.logo 15.33 × 19.33, swift 22 × 19.33, iphone 17.67 × 20.33, cloud.sun.rain.fill 25.33 × 26.33; all `isSymbolImage`, scale 3 |
| unknown symbol name (`doesnotexist.symbol`, also `xcode`) | `UIImage` is `nil`; SwiftUI `Image(systemName:)` renders nothing and lays out as **0 × 0** |
| `Image(systemName:)` sizing | follows the current font (body: 22 × 20.67; `.largeTitle`: 44 × 41.67) and `imageScale` (small 17.67 × 16.33, large 28 × 26.67); `fontWeight` changes the size slightly (ultraLight 34.33 × 32.33, regular 36.33 × 34, black 38.67 × 36.33 at `.title`) |
| Symbol alignment | a symbol's first baseline in a stack is 17 (body), i.e. symbols align on the text baseline |
| Rendering modes | monochrome, hierarchical, palette, multicolor, variable value and `symbolEffect(.bounce)` all rendered (screenshot `images-end.png`, git-ignored) |
| Asset-catalog image (our own 60 × 40 px PNG at @2x, compiled with `actool`) | `UIImage(named:)` 30 × 20 pt at scale 2; `Image("ProbeImage")` lays out 30 × 20; `.resizable().frame(40, 40)` → 40 × 40 |
| Asset-catalog colour (`ProbeColor`: red, dark appearance blue) | resolves to red in light and blue in dark, and switches live (§4) |

Run-time dependencies seen: symbol and asset images load through the
runtime's symbol and CoreUI frameworks (no daemon lookup); the first
multicolor/hierarchical symbol drawing opened `com.apple.IOSurface.Remote`
(`01` §3).

## 4. Colours

`Color.resolve(in:)` with `colorScheme` set (sRGB hex, alpha last). Named
colours adapt to the colour scheme; plain components (`.white`, `.black`,
`.gray`, `.clear`) do not.

| Colour | Light | Dark |
|---|---|---|
| `primary` | #000000FF | #FFFFFFFF |
| `secondary` | #3C3C4399 | #EBEBF599 |
| `accentColor` (default tint) | #0088FFFF | #0091FFFF |
| `red` | #FF383CFF | #FF4245FF |
| `orange` | #FF8D28FF | #FF9230FF |
| `yellow` | #FFCC00FF | #FFD600FF |
| `green` | #34C759FF | #30D158FF |
| `mint` | #00C8B3FF | #00DAC3FF |
| `teal` | #00C3D0FF | #00D2E0FF |
| `cyan` | #00C0E8FF | #3CD3FEFF |
| `blue` | #0088FFFF | #0091FFFF |
| `indigo` | #6155F5FF | #6D7CFFFF |
| `purple` | #CB30E0FF | #DB34F2FF |
| `pink` | #FF2D55FF | #FF375FFF |
| `brown` | #AC7F5EFF | #B78A66FF |
| `white` / `black` / `gray` / `clear` | #FFFFFFFF / #000000FF / #8E8E93FF / #00000000 | same |
| UIKit `label` | #000000FF | #FFFFFFFF |
| `secondaryLabel` / `tertiaryLabel` | #3C3C4399 / #3C3C434C | #EBEBF599 / #EBEBF54C |
| `systemBackground` / `secondarySystemBackground` | #FFFFFFFF / #F2F2F7FF | #000000FF / #1C1C1EFF |
| `systemGroupedBackground` / `secondarySystemGroupedBackground` | #F2F2F7FF / #FFFFFFFF | #000000FF / #1C1C1EFF |
| `separator` | #3C3C431F | #54545880 |
| `link` | #007AFFFF | #0984FFFF |
| `tintColor` | #0088FFFF | #0091FFFF |
| `systemFill` / `placeholderText` | #78788033 / #3C3C434C | #7878805C / #EBEBF54C |

Increased contrast (`simctl ui increase_contrast enabled`, live):
`Color.blue`/`accentColor` became #1E6EF4 (light) and #5CB8FF (dark);
UIKit `systemRed` high-contrast: (0.9137, 0.0824, 0.1765) light,
(1.0, 0.3804, 0.3961) dark; label and background unchanged.
`colorSchemeContrast` read `.increased`.

Note the system blue used by SwiftUI's `.blue`/accent (#0088FF) differs
from UIKit's legacy `link` colour (#007AFF).

## Evidence

| Claim | Level |
|---|---|
| Point sizes, metrics, heights, symbol sizes, colour values, live changes | 3 (`SUIProbe` modes `layout`, `images`, `env`; logs in `research/experiments/swiftui/results/`) |
| Text style ↔ Dynamic Type mapping exists, colour adaptivity, `Color.resolve(in:)` | 1 (developer.apple.com `Font`, `DynamicTypeSize`, `Color` pages) |
| `extraLargeTitle` unavailable on iOS | 4 (SDK availability, compile error in our build) |
