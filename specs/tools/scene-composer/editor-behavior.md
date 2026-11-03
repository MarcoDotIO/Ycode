# Scene composer 7: editor behaviour (reference: Reality Composer Pro 3)

Status: draft, OBS-RCP round 0 (2026-10-29). Reference: Reality Composer
Pro 3.0 (build 75.0.14.500.1), a standalone download that needs Xcode 27
or later only for the Xcode link. In this file, "the reference" means that
app. Ycode's editor has its own name and must not use Apple's names,
artwork, icons or theme colours.

Sources: Apple's public documentation for Reality Composer Pro 3 and four
WWDC26 sessions (level 1), the WWDC23 session for the earlier version
(level 1, marked **[RCP2]**), and names only (command identifiers, menu
titles, panel titles, shortcut labels, feature-flag names, command-line
option names) from the app's binaries (level 4). No clicks or keystrokes
were made in the app for this file. Behaviour that needs the GUI is listed
in §16 as open questions.

What this file is for: an editor that users can switch to from the
reference without relearning. Layout and keys should match where a
convention exists. Data compatibility is specified in `project-format.md`,
`scene-usd.md` and `compile.md`, not here.

## 1. Generations of the reference

| Generation | Editing model | Project | How the app gets the content |
|---|---|---|---|
| RCP 1/2 (shipped inside Xcode 15–26) | A **USD editor**: the hierarchy is the USD prims of the open `.usda` scene | Swift package with a `.realitycomposerpro` package and an `.rkassets` folder | Xcode compiles the `.rkassets` with `realitytool` at build time |
| RCP 3 (standalone, 2026) | An **entity/component/asset editor**. USD is only an import and export format | `.realitycomposerpro` directory in a new text-asset store (see `project-format.md`) | The editor exports `.reality` files that Xcode copies as resources. Exporting is an explicit step or runs automatically when an Xcode project is linked |

RCP 3 opens an RCP 2 project only through a one-way **migration** (§11).
Docs and videos from before 2026 describe RCP 2. Where they differ from
RCP 3, this file says so.

## 2. Windows and workspaces

1. **Welcome window** at launch. It offers recent projects, *Create New
   Project* and *Open Existing Project*. Any command-line argument skips
   it unless `--welcome` is given.
2. **Project window.** One window can hold several **workspaces**. They
   appear as window-level tabs below the toolbar. Double-clicking an
   entity or another asset (material, graph, animation graph) in the
   Project Browser opens it in a new workspace. Each workspace has its
   own docking layout.
3. **Tabs (panels).** Each workspace is a docking layout of tabs. You can
   drag a tab onto a dock target to move it, and you can move tabs
   between the upper and lower tab bars. *Tab ▸ New Tab* opens one of
   these:

| Tab (title) | Internal kind | Default | Purpose |
|---|---|---|---|
| Viewport (Scene) | scene tab | yes | 3D editing of the open entity or scene |
| Hierarchy | tree tab | yes | Entity tree of the open scene, with components shown as children (can be toggled) |
| Inspector (Properties) | properties tab | yes | Components of the selection, node inputs and outputs in graphs, and asset import options |
| Project Browser | asset browser tab | yes | Folders and assets of the project |
| Console | console tab | yes | Import, export, build and runtime messages |
| Preview | preview tab | yes | Preview of the selected asset; for audio, plays the file and shows its waveform |
| Simulate | simulate tab | no | Runs the scene with systems active; can dock beside the Viewport |
| Graph | graph tab | no | Node editor for Shader Graph, Script Graph, Animation Graph, Compute Graph and Behavior Tree assets (§8) |
| Lightmap Preview | — | no | Shows lightmap bake results |
| Skeleton | skeleton tab | no | Skeleton and IK-rig editing |
| Parameters, Behavior Tree Parameters, Tags, Context, List | — | no | Auxiliary panels for graphs and animation graphs |

   The binaries also define these panels: Modified Assets, Collaboration,
   Task Manager, Memory Use, Statistics, Profiler, Resources, Device, the
   animation curve editor, the animation sequencer (the timeline, §9),
   and a truth/object inspector. The docs do not list all of them in the
   New Tab menu (§16 Q3).
4. **Assistant.** A tab in the Inspector area (top right). It is a chat
   panel attached to a user-configured model provider (URL, optional API
   key, header name, description). It can answer questions about the
   app, generate assets and materials from prompts or images, and edit
   the hierarchy through editor commands. Ycode may offer its own
   equivalent. Asset generation needs macOS 27 in the reference.
5. **Settings.** There are two settings windows: application settings
   (themes, language, workspace templates, and window layouts stored per
   user), and **Project Settings** (*Reality Composer Pro ▸ Project
   Settings*, ⌘⌥,). Project Settings includes *Build Settings*, whose
   *Plugin Directory* field locates the custom-component plug-in (§12).
6. **Focus mode** (*View* menu, ⌘.) hides the other panels around the
   viewport. **Command Palette** (⌘⇧P) searches every editor command.
   Workspaces can be saved as templates, restored to their default, and
   all windows can be merged into one.

**[RCP2]** RCP 2 had a fixed layout: hierarchy on the leading side,
viewport in the centre, inspector on the trailing side, and a bottom
editor area with tabs *Project Browser*, *Shader Graph*, *Audio Mixer*
and *Statistics*. A **Content Library** of curated assets opened from the
toolbar's + button. RCP 3 has no global Audio Mixer: mixing happens
through an Audio Mix Groups component (§10). It also has no separate
content library. New projects instead get a read-only **core** folder
with basic geometry (box, plane, sphere), cameras, lights, environments
and default materials.

## 3. Menus and commands

The reference is built on a command registry. Every action is a named
command with an optional menu path, a shortcut and a description. Menus,
context menus and the command palette are views of that registry. Ycode
should copy this design so that every action is reachable from the
palette.

Top-level menus seen: *Reality Composer Pro* (app menu: About, Project
Settings, Hide, Quit), *File*, *Edit*, *View*, *Tab*, *Editor* (graph
layout: Align, Distribute, Subtype), *Tools* (Screenshot, Language,
Feature Flags), *Window* (New Window, Theme, Minimize, Merge All
Windows), *Help* (Documentation, Tutorials, Report Issue).

| Command (menu ▸ item) | Shortcut | Behaviour |
|---|---|---|
| File ▸ New (project) | ⌘N | New project. Saves or asks first, disconnects collaboration, reopens windows with the default layout |
| File ▸ Open Project | ⌘O | Opens a `.realitycomposerpro` project. A legacy package starts migration (§11) |
| File ▸ Open Recent / Clear Recent | — | Most-recently-used list |
| File ▸ Save (all modified assets) | ⌘S | Writes only the assets that changed. The first save of a new project asks for a location |
| File ▸ Save Project As | ⌘⇧S | Copies the project to a new location. A *Save A Copy* variant exists |
| File ▸ Save Project As Asset Database | — | Writes the project as one database file instead of a directory (`project-format.md`) |
| File ▸ Revert All Changes | — | Discards unsaved changes in every file |
| File ▸ Import File | ⌘I | Imports one or more files (§6) |
| File ▸ Export Selected ▸ Reality / USDA (Mesh) / USDZ (Mesh) | — | Exports the selected entities (§7) |
| File ▸ Export (with settings) | — | Runs a *Reality Export Settings* asset (§7) |
| Edit ▸ Undo / Redo | ⌘Z / ⌘⇧Z | Project-wide undo stack. Each entry is labelled ("Undo: ‹action›") |
| Edit ▸ Cut / Copy / Paste / Duplicate | ⌘X / ⌘C / ⌘V / ⌘D | Paste places clipboard entities as children of the selected entities. A *Paste Values* variant pastes property values |
| Edit ▸ Copy Path | ⌥⌘C | Copies an asset's project path |
| Edit ▸ Delete | ⌘⌫ (⌫ in lists) | Deletes the selection |
| Edit ▸ Select All / Deselect All | ⌘A / ⌘⇧A | |
| View ▸ Focus Mode | ⌘. | §2 |
| View ▸ Hide/Show Hierarchy | ⌘⌃S | Sidebar toggle |
| View ▸ Hide/Show Inspector | ⌘⌃I | |
| View ▸ Status Bar, Full Screen | —, ⌘⌃F | |
| View ▸ New Workspace / Restore Default Workspace / Save Workspace as Template | — | |
| Tab ▸ New Tab / Change Tab / Close Tab / Pin Tab | — / — / ⌘W / — | |
| Command Palette | ⌘⇧P | |
| Play Scene (Launch Control) | ⌘R | Starts or stops the active scene with the selected tool (§5) |
| Minimize / Hide / Quit | ⌘M / ⌘H / ⌘Q | Standard macOS |

**[RCP2]** documented: ⌘N new scene, ⌘S save, ⌘D duplicate, Delete to
remove, and WASD or arrow keys to fly. RCP 3 keeps ⌘D, ⌘S and Delete,
uses ⌘N for a new project, and creates scenes from the Project Browser's
+ menu (*Entity*).

## 4. Hierarchy, Project Browser and Inspector

**Hierarchy.** It shows the open scene's entity tree under its root
entity, and optionally each entity's components as children (toggle
⌘⇧H). Filter with ⌘F; the filter also matches component names. Each row
has *lock* and *show/hide* toggles. These are editor state only and do
not change exported files. *Deactivate/Activate* is different: a
deactivated entity is greyed out, hidden in the viewport and **not
exported**. Drag to reparent; dragging onto the root makes an entity a
top-level child. Add actions:

| Action | Shortcut |
|---|---|
| Add Component (picker) | Space |
| Add Child Entity ▸ From Asset (picker of project assets) | ⇧Space |
| Add Child Entity ▸ Empty | ⌃Space |
| Add Child Entity ▸ geometry (box, plane, sphere from the core folder's labelled assets) | — |
| Create Portal Hierarchy (a world, a portal and a portal material set up together) | — |
| Simplify (remove empty intermediate entities, flattening the tree) | ⌘⇧D |
| Move To New Parent / Move To Separate Entity, Rename, Frame Selection | — |
| Prototype commands: Create Prototype Asset, Replace With Asset, Open Prototype in New Workspace, Find Prototype in Project Browser, Reset, Propagate, Make Unique, Override | — |

**Prototypes and instances.** An entity or graph asset in the Project
Browser is a *prototype*. Dragging it into a scene creates an *instance*.
Edits to an instance are *overrides*, which the Hierarchy marks with a
dot. *Reset* drops the overrides, *Propagate* writes them into the
prototype (and so to every instance), and *Make Unique* breaks the link.
Dragging an entity from the Hierarchy into the Project Browser makes it
a prototype. Assigning a prototype material directly to a component
edits the prototype itself, unless the user first makes an *Instance* of
it. The storage of prototypes and overrides is in `project-format.md`.

**Project Browser.** It shows the project's folders, with the read-only
core folder at the top. Toolbar: close, Console, side panel, New Folder,
New Asset (+ menu: Entity, materials, graphs, Audio ▸ Audio Mix Group,
Audio File Group, Reality Export Settings, Custom Node Library, and
others), Import Asset, back/forward, list/grid view (⌘1 / ⌘2), thumbnail
size, and search (⌘F, with a project-wide toggle on ⌘G). Sort by name,
kind or size (⌘⌃1/2/3). Item commands: Open (⌘⇧O), Open In Tab, Open
Location (⌘⌥O), Show in Finder (⌘⇧E), Find References (⌘⌥R), Show
Package Contents, New Folder From Selection, Paste into folder (⌘V),
Move into folder (⌥⌘V), Instantiate, Export To ▸ Reality, Reimport,
Reimport Automatically. Selection can be synchronised with the
Hierarchy.

**Inspector.** It shows a header with the entity's name and an
active/inactive state, a fixed **Transform** section (position, rotation,
scale), then one section per component, then *Add Component* at the
bottom. Holding ⌥ while dragging over a numeric field changes the value
by dragging. Control-click a property to get Reset or Propagate. For an
asset, the Inspector shows its import options (for USD sources) or its
resource properties (for audio files: Should Loop, Should Randomize
Start, Should Stream). For a graph node it shows inputs and outputs.
Lighting tools in the Inspector bake lightmaps with quality Low, Medium,
High or Production, and capture environments.

## 5. Viewport

| Feature | Behaviour |
|---|---|
| Select / Move / Rotate / Scale tools | Buttons at the bottom left. Keys **Q, W, E, R**: the docs list them as Select, Move, Scale and Rotate in that order (§16 Q1) |
| Manipulator | One handle per axis (X, Y, Z). The centre handle acts freely. Move and Scale add plane handles for two axes. Rotate shows one ring at a time. Dragging the entity body moves it in the view plane |
| Snapping | *Enable Snapping* toggle with a *Snap Distance* for moves. Separate angular snapping (degrees) and scale snapping settings exist. *Align to Grid* command |
| Transform space | World or Local |
| Pivot for multiple selections | First Selected, Last Selected, Center, Bounding Box |
| Selection | Click; Shift-click to add; drag for marquee (Box Select add, remove or toggle) |
| Navigation | Scroll to zoom. ⌥-drag to orbit. Pan, dolly and track camera modes exist. A free-flight camera uses WASD keys (forward, back, left, right, up, down) with speed in m/s and a rotation speed. Invert-zoom option. **[RCP2]**: game controllers also navigate |
| Framing | **F** frames the selection. *Frame Scene* is ⌘⇧F |
| Grid | Toggle ⌘G. The grid has thin and thick lines, a configurable size, and axis lines X and Z (Y up) |
| Camera menu | *Default Camera* or any entity with a camera component |
| Lighting environment | Choose the environment-lighting asset. Assets with no lights of their own get a default environment |
| Component debug visualisation | Per-component overlays: collision shapes, point-light radius, skeletons, character controller, directional and spot lights, docking region, model, virtual environment probe |
| Rendering visualisation | Geometry channels (normals, tangent, bitangent, UVs), material channels (base colour, roughness, metallic, AO, specular, emissive, clearcoat, clearcoat roughness), output channels (final colour, final alpha, diffuse lighting, specular lighting) |
| Statistics overlay | A *Statistics* mode in the viewport's visualisation menu (§13) |
| Launch Control bar | Above the viewport. A Play button (⌘R) and a mode menu: **Simulate** (run in the Simulate tab), **Preview on Device**, or **Run with Xcode** (§12). Simulate tab: pause or resume (⌘P), restart, cap or uncap frame rate, show or hide toolbar |

Units: the scene unit is the metre (RealityKit). Whether the Inspector
can display other length units, as RCP 2 could, is §16 Q4.

## 6. Importing

Import paths: *File ▸ Import File* (⌘I), the Project Browser's import
button or context menu, or dragging files from Finder into the Project
Browser.

| Kind | Extensions the importers register (level 4) |
|---|---|
| Scenes and models (through the bundled USD library and its file-format plug-ins) | `usd`, `usda`, `usdc`, `usdz`, `gltf`, `glb`, `obj`, `ply`, `stl`, `abc` |
| Images | `png`, `jpg`/`jpeg`, `bmp`, `gif`, `hdr`, `psd`, `tga` (general image loader); `exr`; `dds`; `ktx`; `tif`/`tiff`; `avif`, `webp` (in USD packages) |
| Audio | `wav`, `aif`/`aiff`, `caf`, `m4a`, `aac`, `mp3`, `flac` |
| Projects | legacy `.realitycomposerpro` packages (migration, §11); Object Capture `.objcap` projects (document type) |

Behaviour (from the docs):

1. Imported source files are **read-only inputs**. They are not moved
   into the project. The project stores an optimised **import bundle**
   (entity, meshes, materials, textures, animations as separate assets in
   a folder next to the entity). Edits go to the project, not to the
   source file.
2. The reference **watches source files**. When one changes on disk it is
   reimported (*Reimport Automatically*, per asset). *Reimport* forces a
   reimport.
3. Images never become entities. Dragging an image into the scene does
   nothing, and images are used only through materials. USD, entity and
   audio assets can be dragged into the viewport or the Hierarchy to
   create an instance.
4. USD-authored animations import as assets but are not attached to the
   entity. Scope prims are not recreated; their children move up to the
   parent.
5. Headless re-extraction: `--update-usd-resources` re-extracts every
   imported USD asset, saves and quits. `--update-textures` reimports
   every texture, saves and quits.

## 7. Exporting

| Export | Where | Output |
|---|---|---|
| Reality | *File ▸ Export Selected ▸ Reality*, Project Browser *Export To ▸ Reality*, a *Reality Export Settings* asset, automatic export to a linked Xcode project | A `.reality` file (`compile.md`). The default name is `Untitled.reality` |
| USDA (Mesh), USDZ (Mesh) | *File ▸ Export Selected* | A newly built USD stage. Docs: this does **not** round-trip: layer structure, references, payloads, comments, prim order and many names are lost. Default name `Untitled.usdz` |
| Export back to source | "options to export changes back to the original source `.usd`" (docs) | §16 Q6 |
| Publish | `--publish <dir>` and a *Publish* command | Builds a stand-alone runnable of the project. Publish settings: executable name, window title, world entity, resolution, fullscreen, and "directory project" (publish data as a readable folder) |

**Reality Export Settings** is a project asset. It holds the entities to
export, the output file name, the **reality-file version** and texture
options. Exporting it writes one `.reality` file.

The app also has a headless export mode (names from its built-in help
text, level 4; not run yet, §16 Q7):

| Option | Meaning |
|---|---|
| `--reality-export-asset NAME` (repeatable) | Export an entity asset (needs `--reality-export-output` and `--reality-export-version`) or run a Reality Export Settings asset |
| `--reality-export-all` | Run every Reality Export Settings asset in the project |
| `--reality-export-output FILE.reality` | Output file for entity exports |
| `--reality-export-version V` | Target version: `15.0/18.0/2.0`, `15.2/18.2/2.2`, `15.4/18.4/2.4` (macOS/iOS/visionOS triples), then `26.0`, `26.2`, `26.4`, `27.0` |
| `--reality-astc-quality-override Q` | `fastest`, `fast`, `medium`, `thorough`, `exhaustive` |
| `--reality-disable-compression` | Store payloads uncompressed |
| `--usd-run-pipeline`, `--usd-asset PATH`, `--usd-output-reality FILE` | Convert a USD file directly to `.reality` |

A component list shipped with the app maps each RealityKit component
type name to the first reality-file version that can carry it (`v25_0`,
`v26_0`, `v27_0`). The exporter uses it to refuse or drop components that
the chosen target version cannot carry (`compile.md`).

## 7a. Headless export and what the editor wrote (observed, OBS-RCP4)

**Headless export works on a project made in the app** (level 3). On a
copy of the owner's sample, with no GUI instance running:

```
RealityComposerPro --headless --load-project <copy>.realitycomposerpro \
    --reality-export-asset world \
    --reality-export-output <copy>.realitycomposerpro/<out>.reality \
    --reality-export-version 27.0
```

- `--reality-export-asset` takes the **asset name** (the entity file's name
  without extension; `world` for the default scene). A Reality Export
  Settings asset is named the same way; with it, `--reality-export-output`
  gives the file and the asset's entity list is used.
- A run takes 4–5 s and exits 0 even when the export fails; failures are
  only in the log (`error: Exporting to … failed`). Typical log noise: one
  engine plug-in fails to load on macOS 27.2 (`compute_graph`), "Couldn't
  find Hierarchy View" repeated, "Window area arguments cannot be null".
- `--reality-export-all` ran our hand-written settings asset
  (`tm_reality_export_settings`: `assets` → entity references, `version`
  (default 18), `filename`, `export_all_entities`; file extension
  `.tm_reality_export_settings`) but wrote nothing: "Exporting to `null`
  failed" — the settings' `filename` is resolved against something the
  headless run did not have (setting the project's `xcode_directory` did
  not help; probably the linked Xcode project kept in per-user state).
- **Sandbox.** The app is sandboxed. Output outside the loaded project's
  folder failed with a permission error after the file had been built in
  the app container's caches; output inside the loaded project folder
  worked. Each export leaves an empty `RealityFileBundleZippingTmp_<UUID>`
  folder in the container's caches.
- **No home isolation.** Setting `HOME` (or `CFFIXED_USER_HOME`) does not
  move the app's state: a sandboxed app always uses its container. Headless
  runs update the real `settings.json` (recent files, last opened project),
  create a per-project settings file and write a log per run
  (`project-format.md` §6). Ycode's tests of the reference must therefore
  restore those entries afterwards (we did).
- The copy of the project was byte-identical after every run: a headless
  export does not save the project.

What the GUI wrote for the owner's actions (from the saved files,
`project-format.md` §4.7):

| Action | Result |
|---|---|
| Cube from the core library | an entity `box` that is a prototype instance of the core box entity, with a parametric 1 m box mesh and the core default material slot `Material` |
| Point light | an entity `point_light` with a transform and `tm_re_point_light_component` |
| Material from an imported image | a material asset named after the image, graph: image node → preview-surface node → output |
| Import an image or a WAV | the file copied byte-for-byte into a `<name>.tm_buffers/` folder beside a new `<name>.tm_texture` / `<name>.tm_audio_file` asset at the project root (audio also decoded to float samples) |
| New Animation Graph / Behavior Tree | assets `Animation Graph.tm_animation_graph`, `Behavior Tree.tm_behavior_tree` with one root node each (a state machine with one state "New State" added in the graph) |
| Add components to a library instance | the added components go to the instance's `components`; changes to the prototype's own components go to `components__instantiated` |
| Export Selected ▸ USDA (Mesh) | a folder `<Name>.usda/` with the layer and an (empty) `<Name>_textures/`; default name `Selection` (`scene-usd.md` §5.1) |

## 8. Graph editors

All node graphs share one editor (the *Graph* tab). The graph types are
**Shader Graph** (materials, `materials.md`), **Script Graph** (visual
scripting), **Animation Graph** (state machines, blends, IK), **Compute
Graph** (GPU particles, `particles-audio.md`) and **Behavior Tree**.

- Open a graph: double-click a graph asset, or drag one onto a Graph tab.
  A Script Graph opens from the Scripting component in the Inspector.
- Add a node: **N** or Space opens the node picker. You can also
  control-click and choose *Add Node*, or drag from a port into empty
  space, which opens a picker filtered to compatible nodes.
- Connect nodes: drag from an output to a compatible input. Incompatible
  ports refuse the connection, and valid targets are highlighted. Input,
  Output and Subgraph nodes have a **+** port that creates a new typed
  port from the connection. Shader graphs cannot gain new outputs.
- Layout: *Clean Up*, *Zoom Fit*, *Align* (left, right, top, bottom),
  *Distribute* (horizontal, vertical), and spacing changes. The
  scroll wheel zooms. A search field centres the view on the matching
  node (⌘F). Breadcrumbs navigate into and out of subgraphs.
- Subgraphs: *Compose Subgraph* from a selection; *Decompose Subgraph*
  inlines it again. *Convert to Prototyped Subgraph* makes a reusable
  node asset that appears in the node picker; its instances can be
  detached.
- Comment boxes: press **C** with nodes selected, or use the context
  menu. A comment box can be cut, copied, duplicated (with its nodes but
  without their connections) and coloured. Deleting a comment box leaves
  its nodes.
- Clipboard: cut, copy, paste and duplicate nodes.
- Inherited nodes (from prototypes) can be shown or hidden with ⌘⇧H.
  *Remove Override* restores an inherited value.
- Node positions, sizes and stacking order are stored with the graph
  (`materials.md` gives the USD form for RCP 2 shader graphs).

## 9. Timeline (sequencer)

Sequences are timeline assets. A *Sequence* has a root entity. Tracks
target entities and can have subtracks. Tracks hold actions (built-in or
custom `EntityAction` types dragged from the left panel), animation
clips or paths. Commands seen: new or mute track, new subtrack, rename,
cut, copy, paste and delete, show frames or seconds, three snapping
toggles (node to nodes, node to ruler, playhead to ruler), and the
timeline settings: start, end, delay, speed, loop behaviour and
duration, fill mode, additive, base or preview animation, root motion
and its joint, target skeleton. Paths have waypoints and orbit settings.
Action parameters are edited in the Inspector. RCP 2 Behaviors and
Timelines migrate with warnings ("Unsupported Actions Detected").
Storage and runtime behaviour are in `timelines-behaviors.md`.

## 10. Audio

- Import audio into the Project Browser. Selecting a file plays it in the
  Preview tab, with a channel and waveform display. The Inspector edits
  the file resource's loop, random start and streaming flags.
- **Audio File Group** assets (created from the Project Browser) group
  files for random or sequential playback.
- Components: Spatial Audio, Ambient Audio, Channel Audio, Reverb (preset
  names in `particles-audio.md`), Audio Library, Audio Mix Groups.
- **Audio mixer:** in RCP 3 the mixer is the UI of an *Audio Mix Groups*
  component. Copies of the component on different entities stay in sync.
  Mix groups are created in the component or from the Project Browser
  (*+ ▸ Audio ▸ Audio Mix Group*), and sounds are added to a group with
  *Add Sound*. **[RCP2]**: there was a global Audio Mixer tab with level
  meters on the stereo output, which RCP 3 does not have.

## 11. Opening legacy (RCP 2) projects

Opening a legacy package (from Finder, *Open With*, or the Open command)
is detected. The app asks for folder access if needed, then offers
**Migrate**. Migration is **one-way and leaves the legacy package
untouched**. It builds a new, unsaved project named after the legacy
Swift package (not after the folder the user picked). It imports the
`.rkassets` contents: each scene becomes an entity at the project root,
and its textures, geometry, animations and materials go into subfolders.
No world root entity is created, Scope prims are flattened, and custom
components become **placeholders**. The placeholders are resolved once
an Xcode project with the plug-in is linked (§12). Legacy custom Swift
code is not migrated. The rules for what maps where are in
`project-format.md` §RCP2 import.

## 12. Xcode integration and plug-ins

**Link an Xcode project** (Launch Control mode *Run with Xcode*, then
*Link an Xcode project*):

1. The first time, a privileged helper (an XPC service that runs as a
   launch agent and is installed from a package inside the app) must be
   installed or updated. It runs `xcodebuild`, `xcrun`, `devicectl` and
   `simctl` for the editor.
2. *Create new*: the editor runs Xcode's template instantiation with its
   own hidden "Reality Composer Pro Application" template. Options:
   organisation and bundle-ID prefix, **Initial Entity** (default
   `World`), **Immersive Space** (None, Mixed, Progressive, Full) and
   **Include Custom Components** (adds the plug-in packages). The result
   is a universal app (iOS, macOS, tvOS, visionOS) in a new parent
   folder, with the sample `Scene.reality` added to the app target's
   Resources phase.
3. *Link existing*: pick an `.xcodeproj` or `.xcworkspace`. Then build
   once in Xcode and restart the editor.
4. The link is stored as a **file path**. If the Xcode project moves, or
   the project opens on another Mac, the editor treats it as unlinked
   and asks again.
5. While linked, the editor exports `.reality` files into the Xcode
   project automatically. It edits `project.pbxproj` text directly to add
   resources and package products, and fails with a "Project Format
   Error" when the expected sections are missing. *Running Destinations*
   lists simulators and connected devices, and *Play* builds, installs
   and launches there. Build output is parsed into progress and error
   messages.

**Plug-ins (custom components, systems, timeline actions, Script Graph
nodes).** The interface is the open-source **RealityComposerPro Plugin
Interface** Swift package (MIT licence, Apple; public repository
`apple/reality-composer-pro-plugin`; the app's template ships a copy).
Its contract, at the interface level:

- `RealityComposerProContext` (protocol) registers components (each must
  be `Component & Codable`, with an optional default value), entity
  actions (`EntityAction`) and systems (`System` types).
- `RealityComposerProPlugin` (class protocol) has `setup(context:)` and an
  optional `shutdown()`, plus a helper that returns a retained opaque
  pointer to the plug-in.
- Discovery: the plug-in is a **dynamic library** (the template's product
  is `.dynamic`). It exports a C symbol `createRealityComposerProPlugin`
  that returns that opaque pointer. The host finds the library in the
  *Plugin Directory* (Project Settings ▸ Build Settings), which defaults
  to the linked project's derived-data products.
- An extension on RealityKit `Scene` reports the editor state by
  checking the name of the first anchor's first child. The values are
  the empty string (an app), "RCP - Viewport", "RCP - Simulation -
  Paused", "RCP - Simulation - Playing", "RCP - Preview - Paused" and
  "RCP - Preview - Playing". These names are an interop contract: a
  compatible editor must name its root entity the same way, so that
  plug-in systems can tell whether they are running in an editor.
- Trust: a project that contains plug-ins asks for trust (*Trust* /
  *Don't ask again*). Headless and safe modes skip plug-ins unless
  `--always-load-plugins` is given. `--skip-custom-systems` loads
  components but not systems. After a plug-in rebuild the editor must be
  restarted, and it then lists the component changes for the user to
  accept.
- Custom systems run inside the editor's simulation. Debug them by
  attaching a debugger to the editor process.

Ycode's editor should load plug-ins written against this MIT interface
unchanged. On Linux that means a `.so` that exports the same C symbol and
links Ycode's open RealityKit (`frameworks/realitykit/09-open-design.md`).

## 13. Preview, statistics and diagnostics

- **Preview on Device**: Apple Vision Pro running the companion app
  *Reality Composer Pro Preview*. The editor offers to install or update
  it. Devices are discovered on the local network. Scene data streams on
  demand. The docs say live edits appear immediately. Some of this is
  "later this year" in the WWDC26 sessions. A Mac Virtual Display
  workflow is suggested. Ycode equivalent: stream to the Ycode simulator
  or a device agent. The wire protocol is not specified (level 5 would be
  needed; out of scope).
- **Device panel**: a metrics view with record, baseline and reset
  controls, and a "freeze camera" mode that copies the viewport camera
  to the device.
- **Statistics**: a viewport statistics mode and a dashboard of
  configurable items: frame time (graph or table, ms), memory use,
  renderer statistics. Each item can be a line graph, table, number or
  gauge. **[RCP2]** grouped statistics by geometry, particles, audio and
  materials.
- **Console**: import, export, build and runtime messages; Clear (⌘K);
  export of the log to a text file. Migration and missing-texture errors
  appear here.
- **Screenshot** command (Tools) and a viewport screenshot.

## 14. Collaboration and version control

- **Live collaboration**: *Host LAN Server*, *Join LAN Server*, *Host
  Internet Server*, *Join Internet Server* (Collaboration tab). The
  command line can also host: `--host-lan-server`, or
  `--host-internet-server [port]` (default port **20183**). Clients do
  not save; the host owns all changes. Collaborators appear as avatars
  in the viewport.
- **Git**: the docs recommend keeping the editor project and the Xcode
  project in one repository. The text asset files merge with git. The
  bundled **`rcpmerge`** tool is a three-way merge driver for the RCP 3
  format: `rcpmerge [-p fail|local|remote|newer] BASE LOCAL REMOTE
  MERGED`. It keeps objects added on both sides and objects removed on
  both sides, and property changes from both sides. Only when both sides
  set the same property to different values does it apply the policy
  (default `fail`; `newer` compares file modification times). Suggested
  setup: a `merge=rcpmerge` attribute on `*.realitycomposerpro/**`, with
  the binary `*.tm_buffers/**` folders excluded from the driver. Ycode
  should ship an equivalent merge driver for the same format
  (`project-format.md`).
- A version-control panel and git-LFS support exist behind a feature
  flag.

## 15. Command line (editor binary)

The editor binary takes options (own wording, from its help text):

| Option | Effect |
|---|---|
| `PROJECT` or `--load-project PROJECT` | Open a project at start |
| `--open-asset PATH` | Open an asset once the project has loaded |
| `--simulate PATH` | Start in simulation of that asset |
| `--tab NAME`, `--layout NAME` | Open a tab or window layout |
| `--headless`, `--no-renderer` | No window, or no rendering |
| `--blank`, `--safe-mode` | Start without restoring a project. Safe mode also skips settings and plug-ins |
| `--welcome` | Force the welcome window |
| `--import-asset PATH` (repeatable) | Import files into the loaded project |
| `--update-usd-resources`, `--update-textures` | Headless reimport, save, quit |
| `--publish DIR` | Publish the project (§7) |
| `--always-load-plugins`, `--skip-custom-systems` | Plug-in loading control |
| `--host-lan-server`, `--host-internet-server [port]` | Collaboration server |
| `--set-feature-flag F`, `--clear-feature-flag F` | Feature flags |
| `--crash-recovery`, `--load-core`, `--data-dir`, `--shader-dir`, `--fixed-refresh-rate`, `--test…`, `--debug-ui-test`, `--enable-accessibility-testing`, `--hold`, `--no-hot-reload`, `--version`, `--help` | Development and test switches |
| Reality export options | §7 |

Feature-flag names seen include cloth, bloom, version control, RCP 3
plug-ins, new settings window, implicit overrides, on-demand buffer
streaming, material de-duplication, the USD scene optimiser, and
assistant scripting and material editing.

**Ycode recommendation.** Give Ycode's editor a headless mode with
equivalent `import`, `export` (to `.reality` via `compile.md`, and to USD)
and `publish` subcommands. This lets CI and Linux hosts build content
without a GUI.

## 15a. Menu bar as read through accessibility (level 3)

Read on 2026-10-29 from a background instance (`open -g` on our legacy
sample; no clicks, no keystrokes). Shortcut notation: ⌘ command, ⇧
shift, ⌥ option, ⌃ control; "no ⌘" means a bare key. Only the native
menu bar and the window titles were exposed; the engine-drawn windows
gave no AX children, and after a few seconds even the window list came
back empty (AX gap recorded).

| Menu | Items (shortcut) |
|---|---|
| Reality Composer Pro | About; Settings (⌘,); Project Settings (⌥⌘,); Hide (⌘H); Quit (⌘Q) |
| File | New ▸ New Project, New Object Capture Model; Open Project… (⌘O); Open Recent ▸; Close Window (⌘W); Save All Modified Assets (⌘S); Save Project As… (⇧⌘S); Save Project As Asset Database…; Revert All Changes; Export Selected ▸ Reality, USDA (Mesh), USDZ (Mesh); Import File… (⌘I) |
| Edit | Undo (⌘Z); Redo (⇧⌘Z); Cut (⌘X); Copy (⌘C); Paste (⌘V); Duplicate (⌘D); Simplify (⇧⌘D); Delete; Select All (⌘A); Deselect All (⇧⌘A) |
| View | Close Workspace; Hide Sidebar (⌃⌘S); Hide Inspector (⌃⌘I); Hide Status Bar; Enter Focus Mode (⌘.); Enter Full Screen (⌃⌘F) |
| Tab | Pin; Change Tab ▸ / New Tab ▸ (same list: Assistant, Behavior Tree Parameters, Console, Context, Graph, Hierarchy, Inspector, Lightmap Preview, List, Parameters, Preview, Project Browser, Simulate, Skeleton, Tags, Viewport); Close; Close Others; Close All; Split Up / Down / Left / Right |
| Tools | Feature Flags ▸ Assistant for ShaderGraph (Preview), Bloom (Preview), Cloth (Preview), Lightmap Bounce Entities (Preview) |
| Editor | Deselect (bare key, no ⌘); Native Resolution; Grid Settings…; Hide Grid (⌘G); Camera ▸ Default Camera; Render Pipelines ▸ Reality Renderer Pipeline, two engine default/forward pipelines; Render Pipeline Settings ▸; Frame Selection (F, no ⌘); Frame Scene (⇧F, no ⌘); Component Visualize ▸ Decal, Docking Region, Virtual Environment Probe, Point Light, Spot Light, Directional Light, Anchoring, Navigation Mesh, Collision, Character Controller, Diffuse Light Probe Group, Skeleton, Model, Diffuse Light Probe Marker, Mixed Reality Lighting; Physics Visualization…; Editor Visibility ▸ Editor Icons; Play Scene (⌘R) |
| Window | Minimize (⌘M); New Window; Merge All Windows |
| Help | (empty in this build) |

Windows at launch with a legacy package: a migration window titled
"Migrate <package name>" and an "Untitled" project window. Our hand-made
legacy package (only `ProjectData/main.json`, an empty `WorkspaceData/`
and the `.rkassets` folder) was recognised as a legacy project. Nothing
was written to the sample before we stopped the instance.

This settles open questions 2 and 3 below (menu bar; New Tab list).

## 16. Open questions (need the GUI; the owner can do them by hand)

1. Q, W, E, R mapping: confirm which of Q/W/E/R is Select/Move/Rotate/
   Scale (the docs' order is Select, Move, Scale, Rotate).
2. Exact top-level menu bar titles and the full item list of each menu.
   This could be read from the accessibility tree with no clicks; see the
   AX list below.
3. The full *Tab ▸ New Tab* list in this build (Statistics, Memory Use,
   Collaboration, Modified Assets, Device, Task Manager?).
4. Units: can the Inspector show centimetres or degrees and radians, as
   RCP 2's unit defaults did? Where is the setting stored (user or
   project)?
5. Copy and paste between two scenes or workspaces, and between two
   projects: are prototype links kept? Does pasting into another project
   copy the assets?
6. The "export changes back to the original source USD" option: menu
   location and what it writes.
7. **Answered** (§7a): entity export by asset name works headless and
   writes into the loaded project's folder; `--reality-export-all` with a
   hand-made settings asset found the asset but had no output location.
   Still open: where a settings asset's `filename` is resolved.
8. Snapping defaults (distance, angle, scale increments) and where they
   are stored.
9. Undo: is it one stack per project or per workspace? Does it survive a
   save?
10. Statistics panel: the exact counters (triangles, draw calls,
    particles, audio voices, texture memory?).

**AX reads requested from the parent** (background only, after
`open -g -a RealityComposerPro <our sample>`; no clicks): (a) the menu bar:
every `AXMenuBarItem` title and, for each, its `AXMenu` children's
`AXTitle` and `AXMenuItemCmdChar` / `AXMenuItemCmdModifiers`; (b) the
window's top-level `AXGroup`/`AXTabGroup` titles (the dock layout and
default tabs); (c) the toolbar's `AXButton` descriptions (Launch Control
modes, viewport tool buttons); (d) the welcome window's buttons if it
appears. The reference draws much of its UI in a custom immediate-mode
toolkit, so AX may expose only the native menu bar and native panels.
Record what is missing.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Menu bar items and shortcuts §15a, migration window title | 3 | background accessibility read of the native menu bar and window titles, our legacy sample, no input events |
| RCP 3 is standalone, not a USD editor; migration behaviour; Xcode consumes exported `.reality`; link stored as a path; USD export does not round-trip | 1 | developer.apple.com Reality Composer Pro documentation: "Migrating older projects to Reality Composer Pro 3", "Updating migrated assets…" |
| Workspace sections, tab list, docking, Hierarchy and Project Browser controls, viewport tools, snapping, pivot, visualisation modes, Inspector, lightmap baking | 1 | Docs: "Navigating the Reality Composer Pro workspace", "Configuring the project workspace" |
| Import paths and behaviour, deactivation not exported, Space for Add Component, ⌥-drag on fields | 1 | Docs: "Adding entities and assets to a scene" |
| Prototypes, instances, overrides | 1 | Docs: "Reusing assets with prototypes and instances"; WWDC26 280 |
| Graph editor controls (N, Space, C, compose/decompose, comments) | 1 | Docs: "Working with the Graph Editor"; WWDC26 252, 393 |
| Xcode link flow, template options, plug-in directory, restart | 1 | Docs: "Linking an Xcode project"; WWDC26 281 |
| Preview on Device, Simulate, Running Destinations | 1 | Docs: "Previewing content and running simulations"; WWDC26 252, 280 |
| Audio mixer through Audio Mix Groups; audio preview; file flags | 1 | Docs: "Adding audio components…", "Updating migrated assets…" |
| Assistant panel and model provider | 1 | Docs: "Working with the Reality Composer Pro Assistant"; WWDC26 280 |
| Plug-in interface (protocols, C entry symbol, editor-state names) | 1 | MIT-licensed RealityComposerPro Plugin Interface package (app template copy; public GitHub repository) |
| RCP 2 layout, Content Library, Audio Mixer tab, Statistics categories, RCP 2 shortcuts | 1 | WWDC23 session 10083 "Meet Reality Composer Pro" **[RCP2]** |
| Command identifiers, menu paths, panel titles, shortcut labels, tool names, extension lists, collaboration commands, feature-flag names | 4 | `strings` of the app's editor plug-in libraries (names only) |
| Editor and reality-export command-line options, default collaboration port, export version identifiers, ASTC quality names | 4 | The editor's built-in usage text (paraphrased) |
| `rcpmerge` behaviour and setup | 3 | `rcpmerge --help` output (paraphrased) |
| Xcode integration details (helper, `pbxproj` editing, `devicectl`/`simctl`, template options) | 4 | `strings` of the Xcode-integration and device plug-ins; app template `TemplateInfo.plist` (read as a format study, not copied) |
| Component-to-reality-version table exists | 2 | The app's component availability JSON (key names only) |
| Headless export behaviour, sandbox limits, state written to the container (§7a) | 3 | eight headless runs on a copy of the owner-made sample, logs and file checksums (OBS-RCP4) |
| What the GUI wrote for each action (§7a table) | 2 | the owner-made sample's files, read with our parser |
