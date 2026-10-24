# SwiftUI 3: architecture — views, identity, dependencies, updates

Status: draft, round 0 (KIT-SWIFTUI, 2026-10-19). Concepts in our own
words from public documentation and WWDC session pages (level 1); every
"measured" statement comes from our probe app (level 3, modes `dataflow`,
`nav`, `anim`; logs in `research/experiments/swiftui/results/`). Internal
mechanisms are described only as far as they are observable; names of
Apple's internal types are not used.

## 1. Views are values

- A view is a value of a type conforming to `View`: a struct whose stored
  properties are its inputs and whose `body` computes another view.
  Primitive views (`Text`, `Image`, `Color`, shapes, `Spacer`, stacks,
  `ForEach`, `Group`, `EmptyView`, `AnyView`, `TupleView`, `ModifiedContent`,
  …) have `Never` bodies and are interpreted by the framework.
- `@ViewBuilder` turns a closure's statements into one static type:
  several children → `TupleView`, `if`/`else` → a two-branch conditional
  type, `if` alone → an `Optional`, `switch` → nested conditionals,
  `ForEach` → a dynamic collection. The static type *is* the structure;
  the framework walks it to build its retained tree.
- Modifiers wrap a view: `content.padding()` is a `ModifiedContent`
  of the content and a padding modifier. `ViewModifier` types have a
  `body(content:)`.
- View values are cheap and short-lived: SwiftUI creates new values every
  time a parent's body runs and compares them with the previous ones. The
  long-lived things are the **identities** and their state.

## 2. Identity and lifetime

Two kinds of identity (WWDC21 "Demystify SwiftUI"):

- **Structural:** the position of the view in the static type structure
  (which child of which tuple, which branch of which conditional).
- **Explicit:** `id(_:)` values and `ForEach` element identifiers.

The lifetime of a view's state (`@State`, `@StateObject`, focus, scroll
position, animations in flight) equals the lifetime of its identity.
Measured (mode `dataflow`, a child with `@State var token = random()` that
logs `onAppear`/`onDisappear` with its token):

| Change | Result |
|---|---|
| Parent re-evaluated, child unchanged | Same identity; state kept (token unchanged). The child's `@State` **initial-value expression is still evaluated** every time the child struct is created (we saw a fresh random number logged on every parent update) but the value is discarded. |
| `if flag { Child() } else { Child() }`, flag toggled | Different branch = different identity: the new branch's child gets **new state**; `onAppear` of the new view is called **before** `onDisappear` of the old one (2 ms apart, same update). |
| `Child().opacity(flag ? 1 : 0.5)`, flag toggled | Same identity; state kept; no appear/disappear. |
| `Child().id(n)`, n changed | New identity: new state; new `onAppear` before old `onDisappear`. |
| `ForEach([1,2,3], id: \.self)` reordered to `[3,1,2]` | State follows the IDs; no appear/disappear. |
| Element removed (`[3,2]`) | Only the removed element's view disappears. |
| `task(id:)` value changed | The running task is cancelled and a new one starts in the same update. |

`onAppear` order within one update (measured): **children before their
parent, and siblings in reverse declaration order** (for `VStack {
first; second }` with `onAppear` on each and on the stack: second, first,
stack; the six stateful siblings of the root also appeared last-to-first).
Implementations must reproduce this order; apps can observe it.

Navigation pushes and presentations follow the same rules: a pushed
destination's `onAppear` fires when the push starts, the covered view's
`onDisappear` when the transition ends (`06-app-and-components.md` §2).

## 3. Data flow

| Wrapper / mechanism | Owner | Dependency granularity (measured) |
|---|---|---|
| `@State` | the view identity | the view(s) whose body read it |
| `@Binding` | someone else's storage | readers of the binding |
| `@Observable` class (Observation) | anything; often `@State var model = Model()` | **per property**: a body that read `m.a` re-runs when `a` changes, not when `b` changes; a body that read only `items.count` re-runs when the array is appended to **or mutated in place** (the property `items` changed); assigning the **same value** to a property re-ran nothing |
| `ObservableObject` + `@Published`, `@ObservedObject`/`@StateObject`/`@EnvironmentObject` | the object | **per object**: any `@Published` change re-runs every view that observes the object, even if it read nothing from it, plus the owner's body |
| `@Environment(\.key)` | ancestors via `.environment(_:_:)` | per key: only readers of the changed key re-run |
| `@AppStorage`, `@SceneStorage` | `UserDefaults` / scene archive | readers of the key (`06` §7) |
| `@FocusState`, `@GestureState`, `@Namespace`, `@ScaledMetric` | framework | readers |

`onChange(of:)` actions run after the update that changed the value,
with old and new values; with `initial: true` the action also runs once
when the view appears (old == new).

## 4. When is a body re-evaluated (measured)

### 4.1 Re-evaluation counts

Mode `dataflow` counts body evaluations of each child after one change
(0.6 s window). A parent holds `@State counter`, an `@Observable` model, a
`@StateObject` legacy model, an environment value it injects, and these
children (each logs its body):

| Change | Bodies that ran |
|---|---|
| initial render | parent ×2 (once more when the scene became active), every child ×1, the closure-holding child ×2 |
| parent `@State` changed (`counter += 1`) | parent; the child that stores a **closure**; *not* the child without inputs; *not* the child with an unchanged `Int` input |
| `@Observable` property `a` changed | only the child that read `a` (the parent, which only stores the model reference, did not run) |
| `@Observable` property `b` changed | only the child that read `b` |
| `@Observable` array appended / mutated in place | only the child that read the array |
| `@Observable` property set to its current value | none |
| `@Published a` changed | the parent (owner via `@StateObject`), both observing children (also the one that read nothing), the closure child |
| `@Published b` changed | the same set (per-object granularity) |
| environment value changed (parent's `@State` → `.environment`) | parent, the environment reader, the closure child; not the sibling that does not read the key |
| a field ignored by a custom `==` changed on a child wrapped in `.equatable()` | the child **did** re-run (open question: for a view whose fields are all plain values, the framework apparently compares field by field and does not consult `==`; see §8) |
| parent `@State` set to its current value | none |

### 4.2 Rules an implementation must follow

1. When a view value is re-created by its parent, its body runs only if
   one of its stored inputs differs from the previous value, or one of the
   dependencies recorded during its last body evaluation changed.
2. Inputs are compared field by field; closures never compare equal
   (closure-holding views always re-run with their parent); plain value
   fields compare by value.
3. Dependencies are recorded while the body runs: state and environment
   reads, `@Observable` property reads (per property), and whole
   `ObservableObject`s for the object wrappers.
4. Writing a value equal to the current one does not schedule an update
   (state and `@Observable` both).
5. All writes in one run-loop turn (or one `withAnimation` closure) are
   coalesced into one update.

## 5. The update cycle

Observable order per frame (from our logs: state change → `onChange` →
body logs → `onAppear`/`onDisappear` → geometry observers → display link
tick):

1. **Transaction**: state writes are collected with their transaction
   (animation etc.).
2. **Bodies**: invalidated bodies are re-evaluated top-down.
3. **Lifecycle actions**: `onChange` actions run (during the update, after
   the value changed), insertions and removals produce `onAppear` /
   `onDisappear` (removal deferred until a removal transition ends,
   `05-animation.md` §5); `task` starts/cancels.
4. **Layout**: dirty subtrees are measured and placed (`04-layout.md`).
5. **Geometry and preferences**: preference values are reduced up the tree
   (`onPreferenceChange` actions run); `onGeometryChange` /
   `GeometryReader` contents update.
6. **Render**: the new tree is turned into layers / drawing for the
   compositor; animations are sampled once per display frame
   (`05-animation.md` §1).

On iOS the root of this tree is hosted by a UIKit view controller (the
window's root view controller was a `UIHostingController` subclass in
our app); scene, window and event delivery come from UIKit (§7).

## 6. Modifier order semantics

A modifier applies to **everything before it** in the chain; the outermost
(last) modifier is the outermost wrapper:

- Layout modifiers compose outward: `.padding().frame(width: 100)` pads
  first, then fixes the width of the padded view; `.frame(width: 100)
  .padding()` gives 132 wide (arithmetic from §5 of `04-layout.md`, not a separate measurement).
- Drawing modifiers apply to the current extent: `.padding().background(.red)`
  colours the padded area (71 × 52.33 for "Hello"), `.background(.red)
  .padding()` only the text (39 × 20.33).
- Environment modifiers apply to the subtree they wrap and are
  overridden by inner ones (`.font(.title)` on a stack, `.font(.caption)`
  on one child → the child is caption).
- Gesture and hit-testing modifiers attach to the extent at that point
  (`.contentShape` changes it).
- Transaction/animation modifiers (`.animation(_:value:)`, `.transaction`)
  affect the subtree they wrap (`05-animation.md` §4.1).
- Render-only modifiers (`offset`, `scaleEffect`, `rotationEffect`,
  `opacity`, `clipped`) do not change layout (`04-layout.md` §5).

## 7. Environment and preferences

- **Environment** values flow down. `EnvironmentValues` is a key/value
  store keyed by `EnvironmentKey` types (or `@Entry`); system values
  (colour scheme, Dynamic Type size, locale, layout direction, size
  classes, accessibility settings, display scale, `scenePhase`, `openURL`,
  `dismiss`, …) are injected at the scene root from the platform and
  update live (`08-environment-accessibility-localization.md` §1).
- **Preferences** flow up. A `PreferenceKey` defines a default and a
  `reduce` that combines sibling values **in declaration order** (measured:
  `first,second`). `onPreferenceChange` runs when the reduced value
  changes; it ran once during the initial update in our probe.
- `anchorPreference` / `overlayPreferenceValue` /
  `backgroundPreferenceValue` combine preferences with geometry.

## 8. Open questions for round R2

- `.equatable()` on a view whose stored properties are all plain values did
  not prevent re-evaluation when only an "ignored" field changed. Probe a
  view with a non-trivial field (a class reference or a string) to find
  when the custom `==` is consulted.
- `disablesAnimations` vs implicit `.animation` modifiers
  (`05-animation.md` §4.1) needs a case where the two animations differ.
- The second initial body evaluation (scene becoming active): confirm that
  it is the `scenePhase` environment change by removing the root's
  `scenePhase` reader.

## Evidence

| Claim | Level |
|---|---|
| Views as values, `ViewBuilder` result types, structural/explicit identity, lifetime, dependencies, modifiers wrap content | 1 (developer.apple.com `View`, `ViewBuilder`, `ViewModifier` pages; WWDC21 session 10022 "Demystify SwiftUI"; WWDC23 session 10160 "Demystify SwiftUI performance"; WWDC23 session 10149 "Discover Observation in SwiftUI") |
| Re-evaluation counts, appear/disappear order, state lifetime cases, preference reduce order, `task(id:)` restart, `onChange` timing | 3 (`SUIProbe` mode `dataflow`, iOS 27.1 simulator) |
| Update-cycle order | 3 (order of our log lines) with level-1 background (WWDC23 10156 "Explore SwiftUI animation", chapter "Anatomy of an update") |
| `UIHostingController` as root view controller | 3 (class name of the window's root view controller in our app; public type) |
| Interop names | 4 (`api-inventory.md`) |
