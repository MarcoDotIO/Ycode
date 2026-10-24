# SwiftUI 4: layout — proposals, sizes, placement

Status: draft, round 0 (KIT-SWIFTUI, 2026-10-19). Behaviour described in
our own words from public documentation (level 1) and from measurements of
our probe app (level 3, mode `layout`; every number below is in
`golden-layout.md`, which is the authority for exact values). Interop
names (types, members, labels) are facts.

Coordinates and sizes are in points. On the reference device (iPhone Duo,
scale 3) every layout result we saw is a multiple of 1/3 pt: sizes and
positions are rounded to the device pixel grid (§9).

## 1. The negotiation model

Layout is a recursive, top-down negotiation with three steps per child:

1. **Propose.** The parent offers a `ProposedViewSize`: a width and a
   height, each either a number, `nil` (unspecified), `0` or infinity.
2. **Respond.** The child returns the size it wants for that proposal.
   It may ignore the proposal. The parent must accept the answer (it can
   only choose where to put the child and how to clip it).
3. **Place.** The parent places the child at a point, with an anchor
   (`UnitPoint`), and a proposal (normally the one it measured with).

A parent may ask the same child several times with different proposals
before placing it. Our `Measure` container did exactly this for seven
proposals per view; children answered consistently and without side
effects, so answers must be **pure functions of the proposal and the
view's inputs** (an implementation may cache them, §8).

Meaning of the special proposals (public documentation, confirmed by
measurement):

| Proposal in a dimension | Asks for | Example answers (width) |
|---|---|---|
| `nil` | the ideal size | Text: single-line width (39 for "Hello"); shapes, `Color`, `GeometryReader`: **10**; `Spacer`: 8 (its minimum length) |
| `0` | the minimum size | Text: 0; shapes: 0; `Spacer`: its minimum length (8, or `minLength`) |
| infinity | the maximum size | Text: single-line width; shapes and `Color`: infinity |
| a number | a concrete offer | Text wraps to fit it (§3); shapes and `Color` take it |

The root view of a window is proposed the window's safe-area rectangle
(on the reference device 382 × 644: the 466 × 678 window minus a 34 pt
bottom inset and an **84 pt trailing inset** — the device has a status
area on the right edge; §7).

## 2. Primitive views

| View | Rule (observed) |
|---|---|
| `Color`, `Rectangle`, `Capsule`, `Ellipse`, `RoundedRectangle` | Take the proposal in each dimension; `nil` becomes 10. |
| `Circle` | A square: side = the smaller of the two proposed dimensions; if one is `nil` the other is used; both `nil` → 10 × 10. Placed in a 300 × 100 offer it is 100 × 100. |
| `Spacer` | Along any axis outside a stack: takes the proposal, but never less than its minimum length (default 8); `nil` → minimum length. Reports layout priority −∞ (it yields to everything). |
| `Divider` | Outside a stack: horizontal hairline, height = one device pixel (0.33 at scale 3), width = proposal (`nil` → 10). Inside an `HStack` it turns vertical and takes the stack's full proposed height. |
| `GeometryReader` | Takes the whole proposal (`nil` → 10); places its content at its top-leading corner, proposing its own size. |
| `Image(systemName:)` (not resizable) | Fixed size from the symbol and the current font (body: 22 × 20.67 for `star.fill`); ignores proposals. `.imageScale(.small/.large)` changes it (17.67 × 16.33 / 28 × 26.67). |
| `Image` + `.resizable()` | Takes the proposal; `nil` → the image's natural size (18.67 × 18 for `star.fill`). |
| `Text` | §3. |
| `EmptyView` | Zero size, contributes no spacing. |

## 3. Text

- **Ideal size** (`nil` or infinite width): the width of the string on one
  line (explicit newlines still break). Height for n lines = first-line
  height + (n − 1) × line pitch. Body font, default size: line height
  20.33, line pitch 22 (baselines 16.33, 38.33, …): "Hello" is 39 × 20.33,
  "Hello\nWorld" 45 × 42.33, four wrapped lines 86.33.
- **Concrete width:** the text wraps at word boundaries and answers the
  width of its **longest line**, not the proposal (proposal 100 →
  93.33 × 86.33 for our 43-character sentence, four lines). When a single
  word does not fit, it breaks inside words (the low-priority text in
  `hstack.priority` was squeezed to 17 pt wide and became 24 lines).
- **Proposed height is ignored** unless a line limit applies: the answer
  for 100 × 100 equals the answer for 100 × `nil` even though it is taller
  than 100 when it does not fit.
- **Zero proposal → 0 × 0** (even for non-empty text). `Text("")` answers
  0 × 14 for every non-zero proposal (an empty line is shorter than a
  full line; height 14 at body size).
- **Line limit:** `.lineLimit(1)` at width 100 → one line, truncated
  with an ellipsis, 88 × 20.33; `.lineLimit(2)` → at most two lines.
- **Baselines:** `firstTextBaseline` = 16.33 and `lastTextBaseline` =
  16.33 + 22 × (lines − 1) for the body font.
- **Fonts:** sizes per text style and per Dynamic Type category are in
  `07-text-images-color.md` §1; line heights round **up** to the pixel
  grid (UIKit reports 20.29 for the body font; the text is 20.33 tall).

## 4. Stacks

### 4.1 Spacing

A stack's `spacing: nil` (the default) means "use each pair's preferred
spacing". Preferences are carried by every view as `ViewSpacing` and are
asymmetric (they depend on which edge meets which). Measured values
(full matrix in `golden-layout.md`, "Default spacing"):

- **Horizontal:** 8 between every pair of kinds we tried (text, image,
  colour, button, toggle, text field, padded view).
- **Vertical:** depends on text metrics at the touching edges:
  text → text 2; text → non-text 10.64; non-text → text 6.43;
  text → image 0; image → text 0; non-text → non-text 8;
  caption-font text → non-text 7.53; non-text → caption text 4.56.
  The rule implied: a text edge's preferred vertical spacing is defined
  from its font's ascent/descent (so text lines sit at a consistent
  baseline-to-baseline rhythm), while non-text views use 8.
- Explicit `spacing:` replaces the preference for every adjacent pair.

### 4.2 Distribution along the stack axis (`HStack`, `VStack`)

The available length = proposal along the axis minus the sum of
spacings. Observed behaviour, consistent with a "least flexible first"
distribution:

1. Children are grouped by `layoutPriority` (higher first). A higher
   group is offered everything except the **minimum** lengths of all
   lower-priority children (`hstack.priority`: the priority-1 text got
   300 − 8 − 0 = 292 offered, answered 275, and the other text got the
   remaining 17).
2. Within a group, children are sorted by flexibility (the difference
   between their maximum and minimum length, measured with infinite and
   zero proposals); the least flexible child goes first. Each child is
   offered an equal share of what is left (remaining length ÷ remaining
   children), answers, and its answer is subtracted.
   Examples: two `Color`s in 300 → 146 + 8 + 146. `Color`,
   `Color.frame(maxWidth: 50)`, `Text("Hello")` in 300 → the text (39) and
   the 50-wide frame go first, the free `Color` gets 195.
   `HStack(spacing: 0)` with `Color`, `Color.frame(minWidth: 150)`,
   `Color` → 75, 150, 75 (the minimum is honoured, the others share the
   rest). Two texts that need 339 and 128.67 in 300 → the short one
   (less flexible) gets 128.67, the long one is offered 163.33 and answers
   158 (longest wrapped line), so the stack is 294.67 wide — **narrower
   than its proposal**.
3. Spacers are flexible with priority −∞: they take what is left after
   all other children, never less than their minimum length
   (`hstack.spacer`: "Left" 29.67, spacer 230.33, "Right" 40 in 300).
4. The stack's own size along the axis is the sum of child sizes plus
   spacings; across the axis it is the largest child (subject to
   alignment, §4.3). With `nil` proposals the stack is its ideal size
   (`hstack.spacer` ideal = 77.67 = 29.67 + 8 + 40, i.e. the spacer
   contributes nothing beyond its minimum).
5. A stack proposes each child, across its axis, the stack's own
   proposal across the axis (so a `Divider` or `Color` in an `HStack`
   proposed 500 tall becomes 500 tall).

### 4.3 Alignment across the axis

Each child is positioned so that the chosen alignment guide (e.g.
`VerticalAlignment.center`, `.top`, `.firstTextBaseline`) lines up on one
line. The stack's cross size is the extent of the aligned children.
`HStack(alignment: .firstTextBaseline)` with a large-title "Big" and a
caption "small": the caption sits at y = 21 so that both baselines are at
32.33; with `.center` it sits at 13.17. Default alignments: `HStack` →
`.center`, `VStack` → `.center`, `ZStack` → `.center`.

Custom guides: `.alignmentGuide(.leading) { d in d.width / 2 }` moves the
view so that its own guide value lies on the line; the line is placed at
the largest guide value (`alignmentGuide` case: "One" moves to x = 15.67,
"Two" stays at 0).

### 4.4 `ZStack`

Proposes its own proposal to every child; its size is the union of the
children aligned on the alignment guide; children are then aligned within
that size (`zstack`: text centred at 42, 14.83 in a 100 × 50 colour;
`.bottomTrailing` → 84, 29.67). A flexible child makes the whole stack
take the proposal.

## 5. Modifiers that change layout

| Modifier | Rule (observed) |
|---|---|
| `frame(width:height:alignment:)` | Answers the given dimensions; for an omitted dimension it answers the child's size. Proposes the fixed dimensions to the child, places it by `alignment` (default centre): "Hello" in 100 × 100 at 30.5, 39.83. A child larger than the frame overflows symmetrically (`frame.tooSmall`). |
| `frame(minWidth:idealWidth:maxWidth:…)` | Proposes the incoming proposal clamped to [min, max], with `nil` dimensions replaced by the ideal values when given. Answer per dimension: if both min and max (including `.infinity`) are given, the incoming proposal clamped to them; if only one bound is given, the child's answer clamped to that bound; `nil` proposal → child's ideal clamped. Examples: `Text.frame(maxWidth: .infinity)` → 300 wide when offered 300, 39 when offered `nil`; `Text.frame(minWidth: 200)` → 200 for every proposal; `Color.frame(minWidth: 50, maxWidth: 150, minHeight: 20, maxHeight: 40)` → 50 × 20 ideal, 150 × 40 for 300 × 500, 100 × 40 for 100 × 100. |
| `fixedSize()` / `fixedSize(horizontal:vertical:)` | Replaces the proposal with `nil` in the fixed dimensions (the child gets its ideal size); `fixedSize(horizontal: false, vertical: true)` keeps the width offer and uses the ideal height for it. |
| `padding(_:)` | Default amount **16** on every edge (iOS). Proposes the incoming size minus the insets (not below 0), answers child + insets. Negative amounts shrink the answer and shift the child outward. `padding(.horizontal)` pads only leading/trailing. |
| `aspectRatio(_:contentMode:)` | Fits (`.fit`) or fills (`.fill`) the largest/smallest rectangle of that ratio inside/around the proposal: ratio 2 in 300 × 500 → 300 × 150 (fit) and 1000 × 500 (fill); with one `nil` dimension it derives it from the other (100 × nil → 100 × 50); with both `nil` it passes `nil` and answers the child's ideal (10 × 10 for `Color`, the ratio is **not** applied). Without a ratio it uses the child's ideal aspect (symbol 18.67 : 18). |
| `offset(x:y:)`, `scaleEffect`, `rotationEffect` | No effect on layout (size and placement of siblings unchanged); they transform rendering and the frames that geometry readers report (offset 20, 10 → frame at 20, 10; scale 2 about the centre → −19.5, −10.17, 78 × 40.67; 90° rotation → the rotated bounding box). |
| `position(x:y:)` | Takes the whole proposal (like a flexible frame) and places the child's centre at the point. |
| `overlay(_:alignment:)`, `background(_:alignment:)` | Answer the **base** view's size. The secondary view is proposed the base's size and aligned to it (default centre): a 200-wide overlay on a 39-wide text sits at x = −80.5. |
| `clipped()` | No effect on layout; clips rendering to the view's frame. |
| `layoutPriority(_:)` | Only affects distribution in stacks (§4.2). A `VStack` with a priority-1 `Color` and a plain `Color` in 500: 492 and 0 (the plain one gets only its minimum). |
| `ignoresSafeArea(_:edges:)` | Expands the view into the safe-area insets of the container it touches; no effect when the view does not touch them. |
| `alignmentGuide(_:computeValue:)` | Overrides one guide value (§4.3). |
| `coordinateSpace(_:)` | Names a coordinate space for `GeometryProxy.frame(in:)` (our probe relies on it). |

**Modifier order matters** because each modifier wraps everything before
it: `Text.padding().background(Color)` paints the background over the
padded area (71 × 52.33); `Text.background(Color).padding()` paints it
only behind the text (39 × 20.33). See `03-architecture.md` §6.

## 6. Grids and adaptive containers

- **`Grid` / `GridRow`:** column width = the widest cell in that column;
  row height = the tallest cell; default spacing between columns 8 and
  between rows the cells' preferred vertical spacing (10.65 between a text
  row and a row containing a colour; 0 with `Grid(horizontalSpacing: 0,
  verticalSpacing: 0)`); cells centred by default. Two rows
  ("A", "Longer") / ("Wide cell", 10 × 10 colour) → 131 × 51.31.
  A flexible cell expands its column to take the remaining width.
  `gridCellColumns(_:)` spans columns.
- **`LazyVGrid`:** columns are computed from the offered width first:
  two `.flexible()` columns in 300 → 146 each (8 spacing); `.adaptive
  (minimum: 80)` in 300 → as many 80-minimum columns as fit (3, each
  94.67); `.fixed(50), .fixed(70)` → 128 wide, centred in 300 (starting at
  x = 86). Row spacing default 8. Ideal width (`nil` offer) of an adaptive
  grid = one column.
- **`ViewThatFits`:** chooses the first child whose ideal size fits the
  offer along the constrained axes (a 339-wide fixed-size text in 300 →
  the second child; in 400 → the first). Its ideal size is the first
  child's.

## 7. Safe areas

- Containers receive safe-area insets from the window (reference device:
  top 0, leading 0, bottom 34, trailing 84). The root content is laid out
  inside them; a `GeometryReader` reports both the inset rectangle size and
  the insets (`safeAreaInsets`).
- Navigation bars add to the top inset (82 on the reference device for
  both inline and large titles in our runs; content frames start at
  y = 82), tab bars to the bottom.
- The software keyboard adds its overlap to the bottom inset when it is
  visible; with the simulator's hardware keyboard attached (the default in
  our runs) it never appears and insets stay unchanged (`06-app-and-components.md` §5).
- Sheets get their own insets (a medium sheet's content: bottom 34,
  trailing 76).

## 8. Caching and invalidation (observable)

- Answers are stable: asking the same view the same proposal twice gives
  the same answer (all our cases).
- A layout re-runs when a child's inputs change (text content, font,
  environment such as Dynamic Type — the `env` mode shows a `Text` frame
  changing height live when the content size category changes, without
  relaunch).
- `onGeometryChange`/`GeometryReader` observers fire after placement, once
  per change of the observed value (frames were logged once per change,
  plus intermediate frames during animations).

## 9. Pixel rounding

Observed sizes are multiples of 1/3 pt at scale 3 (20.33, 93.33, 0.33 for
a hairline); positions obtained by centring can fall on half-thirds
(239.83 = (500 − 20.33) / 2) — the frame origin is not snapped, the
rendered pixels are. Our golden values were printed with two
decimals; implementations compare with a tolerance of 0.01 pt for
font-independent cases and treat text answers per `10-plan.md` §3.3.

## Evidence

| Claim | Level |
|---|---|
| Negotiation model, meaning of `nil`/0/infinity proposals, `Layout` protocol roles, `ViewThatFits`, `Grid`, `AnyLayout` existence | 1 (developer.apple.com `Layout`, `ProposedViewSize` pages; WWDC22 session 10056 "Compose custom layouts with SwiftUI") |
| Every number and every "observed" rule | 3 (`SUIProbe` mode `layout`, iOS 27.1 simulator, iPhone Duo; `golden-layout.md`) |
| Stack distribution order ("least flexible first", priority groups) | 3 (inferred from the measured cases; consistent with all of them) |
| Interop names | 4 (SDK module interface names, `api-inventory.md`) |
