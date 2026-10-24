"""Builds specs/frameworks/swiftui/api-inventory.md from inv.py output
(KIT-SWIFTUI, original Ycode code). Names, labels, conformance names and iOS
availability only. Usage: python3 -I mkinv.py core.jsonl ui.jsonl > api-inventory.md"""
import json, re, sys, collections

recs = [json.loads(l) for f in sys.argv[1:] for l in open(f)]
AREAS = [
    ('App, scenes and lifecycle', r'^(App|Scene|.*Scene$|WindowGroup|Window.*|DocumentGroup|.*Document.*|Settings|ScenePhase|Command.*|.*Commands$|OpenWindow.*|OpenURL.*|Dismiss.*|.*Delegate.*Adaptor|.*ImmersiveSpace.*|Immersi.*|SceneBuilder|SceneStorage|UIApplicationDelegateAdaptor|MenuBarExtra.*|Restoration.*|.*Launch.*|.*Activation.*)$'),
    ('Views and composition', r'^(View|ViewBuilder|ViewModifier|ModifiedContent|EmptyView|EmptyModifier|AnyView|TupleView|Group|ForEach.*|EquatableView|ViewThatFits|.*Content$|.*ContentBuilder|Subview.*|SectionConfiguration|ContainerValues|ContainerValueKey|.*ContainerValues.*|Entry|DynamicViewContent|IdentifiedContent|ViewContent.*)$'),
    ('Layout and geometry', r'^(Layout.*|AnyLayout|.*Stack.*|Spacer|Divider|Grid.*|.*Alignment.*|Alignment|Edge.*|ProposedViewSize|ViewDimensions|GeometryReader.*|GeometryProxy|.*CoordinateSpace.*|SafeArea.*|ContainerRelative.*|ViewSpacing|Spacing|Anchor|UnitPoint|Axis|LayoutDirection.*|.*Layout$|ContentMode|.*Geometry.*|ScaledMetric|.*Inset.*|CG.*|.*Placement.*|FrameResizePosition|ViewSize.*|Viewport.*)$'),
    ('Text and fonts', r'^(Text.*|Font.*|LocalizedStringKey|LocalizedStringResource|.*Text$|TruncationMode|Typesetting.*|.*Typography.*|AttributeScopes|.*Line.*|DynamicTypeSize|LegibilityWeight|Kerning.*)$'),
    ('Images and symbols', r'^(Image.*|.*Image$|SymbolRenderingMode|.*Symbol.*|AsyncImage.*|.*ImageRenderer.*|ImagePhase)$'),
    ('Shapes, colour and drawing', r'^(Shape.*|.*Shape$|.*ShapeStyle$|Path|Rectangle|Circle|Capsule|Ellipse|RoundedRectangle|UnevenRoundedRectangle|RoundedCornerStyle|Canvas.*|GraphicsContext|Gradient.*|.*Gradient|Color.*|Material|Shader.*|StrokeStyle|FillStyle|BlendMode|Angle|Angle2D|.*Style$|Glass.*|.*Glass.*|ForegroundStyle|BackgroundStyle|TintShapeStyle|HierarchicalShapeStyle.*|SeparatorShapeStyle|Visual.*|.*Effect$|ColorScheme.*|ColorRenderingMode|ContentShapeKinds|Corner.*|.*Corner.*|ConcentricRectangle|.*Concentric.*|Edge.*Style)$'),
    ('Animation, transactions and transitions', r'^(Animation.*|Animatable.*|.*Animation$|Transaction.*|.*Transition.*|Transition|Spring|UnitCurve|.*Keyframe.*|Keyframe.*|PhaseAnimator.*|CustomAnimation|MatchedGeometry.*|Namespace|ContentTransition|AnyTransition|.*TransitionPhase.*|TimelineView.*|.*Schedule.*|AnimationContext|AnimationState|AnimationCompletionCriteria|.*Animatable.*)$'),
    ('Data flow, environment and preferences', r'^(State|Binding|Environment.*|EnvironmentValues|EnvironmentKey|StateObject|ObservedObject|EnvironmentObject|Bindable|FocusState|Focus.*|Focused.*|AppStorage|PreferenceKey|.*PreferenceKey|Preference.*|DynamicProperty|.*Storage$|UUID|Observable.*|Observation.*|Published|ObservableObject)$'),
    ('Navigation, tabs, toolbars and presentation', r'^(Navigation.*|.*Navigation.*|TabView.*|Tab.*|.*Tab$|.*Tab.*Style|Presentation.*|.*Presentation.*|Sheet.*|Alert.*|ConfirmationDialog.*|Inspector.*|Toolbar.*|.*Toolbar.*|Search.*|.*Search.*|Popover.*|.*Detent.*|Dialog.*|.*Dialog.*|BackgroundInteraction.*|.*Sidebar.*|.*SplitView.*)$'),
    ('Lists, scrolling and collections', r'^(List.*|.*List.*|Section.*|Table.*|.*Table.*|OutlineGroup|DisclosureGroup.*|ScrollView.*|Scroll.*|.*Scroll.*|Lazy.*|EditMode|EditButton|.*Selection.*|.*Row.*|.*Column.*|KeyPathComparator|SortDescriptor|PinnedScrollableViews|RefreshAction|.*Refresh.*|SwipeAction.*|.*Swipe.*)$'),
    ('Controls, forms and text input', r'^(Button.*|.*Button.*|Toggle.*|.*Toggle.*|Slider.*|Stepper.*|Picker.*|.*Picker.*|DatePicker.*|ColorPicker.*|TextField.*|.*TextField.*|SecureField|TextEditor.*|Menu.*|.*Menu.*|Link|.*Link.*|ShareLink|ProgressView.*|.*Progress.*|Gauge.*|.*Gauge.*|Label.*|.*Label.*|LabeledContent.*|Form.*|.*Form.*|ControlSize|ControlGroup.*|.*Control.*|.*Field.*|TextInput.*|.*Keyboard.*|SubmitLabel|SubmitTriggers|.*Submit.*|TextSelection.*|.*Autocapitalization.*|.*TextContentType.*|.*Autocorrection.*|Writing.*|.*Writing.*)$'),
    ('Gestures, input and drag and drop', r'^(Gesture.*|.*Gesture.*|GestureState.*|EventModifiers|KeyPress.*|KeyEquivalent|KeyboardShortcut|.*Hover.*|Drop.*|.*Drop.*|.*Drag.*|Draggable|Transferable|.*Pointer.*|.*Haptic.*|SensoryFeedback.*|.*Sensory.*|.*Interaction.*|.*Hit.*|.*Touch.*|.*Pencil.*|.*Crown.*|.*Spatial.*|.*Manipulation.*)$'),
    ('Accessibility', r'^(Accessibility.*|.*Accessibility.*)$'),
    ('UIKit interoperability and hosting', r'^(UI.*|.*Representable.*|.*Hosting.*)$'),
    ('Previews and developer tools', r'^(Preview.*|.*Preview.*|_Test|.*Test$)$'),
]
MOD_AREAS = [
    ('Layout and geometry', r'^(frame|padding|fixedSize|layoutPriority|alignmentGuide|position|offset|aspectRatio|scaledTo|safeArea|ignoresSafeArea|coordinateSpace|containerRelativeFrame|edgesIgnoringSafeArea|layoutValue|gridCell|gridColumn|onGeometryChange|contentMargins|containerShape|layoutDirection|flipsForRightToLeft|zIndex|ignoresSafe|.*[Ss]pacing)'),
    ('Text and fonts', r'^(font|bold|italic|fontWeight|fontDesign|fontWidth|kerning|tracking|baselineOffset|lineLimit|lineSpacing|multilineTextAlignment|truncationMode|minimumScaleFactor|allowsTightening|textCase|dynamicTypeSize|monospaced|underline|strikethrough|textSelection|typesetting|lineHeight|textRenderer|writingDirection|speechAnnounce|textScale|.*[Tt]ext.*)'),
    ('Drawing, colour and effects', r'^(foreground|background|tint|accentColor|overlay|border|clip|cornerRadius|mask|shadow|blur|opacity|brightness|contrast|saturation|grayscale|hueRotation|colorInvert|colorMultiply|luminanceToAlpha|blendMode|compositingGroup|drawingGroup|rotationEffect|rotation3DEffect|scaleEffect|transformEffect|projectionEffect|colorEffect|distortionEffect|layerEffect|visualEffect|glassEffect|preferredColorScheme|colorScheme|containerBackground|backgroundStyle|symbol|imageScale|renderingMode|allowedDynamicRange|backgroundExtensionEffect|.*[Ee]ffect$)'),
    ('Animation and transitions', r'^(animation|transition|transaction|matchedGeometryEffect|matchedTransitionSource|navigationTransition|contentTransition|phaseAnimator|keyframeAnimator|geometryGroup|scrollTransition|animatable|.*[Aa]nimat.*)'),
    ('Data flow, environment and preferences', r'^(environment|environmentObject|preference|onPreferenceChange|anchorPreference|transformPreference|transformEnvironment|backgroundPreferenceValue|overlayPreferenceValue|focusedValue|focusedSceneValue|focusedObject|focusedSceneObject|defaultAppStorage|modelContainer|modelContext|containerValue|id|equatable|tag)$'),
    ('Lifecycle and events', r'^(onAppear|onDisappear|task|onChange|onReceive|onOpenURL|onContinueUserActivity|userActivity|handlesExternalEvents|backgroundTask|onSubmit|refreshable|onScenePhase|.*[Ll]ifecycle.*)'),
    ('Navigation, toolbars and presentation', r'^(navigation|toolbar|sheet|fullScreenCover|popover|alert|confirmationDialog|inspector|presentation|interactiveDismissDisabled|searchable|search|tabItem|tabView|tab|badge|statusBar|persistentSystemOverlays|dialog|fileImporter|fileExporter|fileMover|fileDialog|menuBar|windowToolbar|onDismiss|tabBar|sidebar|.*[Pp]resentation.*|.*[Tt]oolbar.*|.*[Nn]avigation.*|.*[Ss]earch.*)'),
    ('Lists and scrolling', r'^(list|scroll|refreshable|swipeActions|deleteDisabled|moveDisabled|selectionDisabled|onDelete|onMove|onInsert|defaultScroll|section|headerProminence|contentMargins|safeAreaPadding|safeAreaInset|.*[Ss]croll.*|.*[Ll]ist.*|table.*)'),
    ('Controls and input', r'^(buttonStyle|toggleStyle|pickerStyle|datePickerStyle|textFieldStyle|progressViewStyle|gaugeStyle|labelStyle|labelsHidden|menuStyle|controlSize|controlGroupStyle|formStyle|disclosureGroupStyle|keyboardType|textContentType|textInputAutocapitalization|autocorrectionDisabled|submitLabel|focused|focusable|focusSection|focusScope|prefersDefaultFocus|defaultFocus|keyboardShortcut|onKeyPress|disabled|buttonBorderShape|buttonRepeatBehavior|menu|labeledContentStyle|.*[Ss]tyle$|.*[Kk]eyboard.*|.*[Ff]ocus.*)'),
    ('Gestures, drag and drop, haptics', r'^(gesture|simultaneousGesture|highPriorityGesture|onTapGesture|onLongPressGesture|onLongTouchGesture|contentShape|allowsHitTesting|onDrag|onDrop|draggable|dropDestination|onHover|hoverEffect|onContinuousHover|sensoryFeedback|defersSystemGestures|onPencil|digitalCrown|handGesture|manipulable|.*[Gg]esture.*|.*[Hh]over.*|.*[Dd]rop.*|.*[Dd]rag.*|.*[Pp]ointer.*)'),
    ('Accessibility', r'^(accessibility|speech)'),
    ('Images', r'^(image|resizable|interpolation|antialiased|symbolRenderingMode|symbolVariant|symbolEffect)'),
    ('Previews', r'^(preview)'),
]

def area_of(name, table, default='Other'):
    for a, pat in table:
        if re.match(pat, name):
            return a
    return default

def ver(r):
    v = r['ios'] or '?'
    if r['dep']:
        v += ', deprecated' + ('' if r['dep'] in ('yes', '100000.0') else ' ' + r['dep'])
    return v

def ios_ok(r):
    return r['ios'] is not None and not r['unavail']

types = collections.OrderedDict()   # name -> {'kind','mod','ios','conf'}
members = collections.defaultdict(list)  # parent -> [rec]
skipped = 0
for r in recs:
    if not ios_ok(r):
        skipped += 1; continue
    if r['parent'] == '' and r['kind'] in ('struct', 'class', 'enum', 'protocol', 'actor'):
        types.setdefault(r['name'], dict(kind=r['kind'], mod=r['module'], ios=ver(r), conf=r['conf']))
    elif r['parent'] == '' and r['kind'] == 'extension':
        if r['conf']:
            t = types.get(r['name'])
            members['__conf__' + r['name']] += r['conf']
    elif r['parent'] == '':
        members['__top__'].append(r)
    else:
        top = r['parent'].split('.')[0]
        members[r['parent']].append(r)

def fmt_members(lst, parent_ios):
    out = []; seen = set()
    for r in lst:
        k = r['kind'].replace('static ', 'static ')
        n = r['name']
        if n in seen:
            continue
        seen.add(n)
        tag = ''
        v = ver(r)
        if v != parent_ios:
            tag = f' [{v}]'
        pre = 'static ' if r['kind'].startswith('static') else ''
        if r['kind'] in ('case',):
            pre = 'case '
        elif r['kind'] in ('typealias', 'associatedtype'):
            pre = r['kind'] + ' '
        elif r['kind'] in ('struct', 'class', 'enum', 'protocol'):
            pre = r['kind'] + ' '
        out.append(f'`{pre}{n}`{tag}')
    return ', '.join(out)

print('# SwiftUI: API name inventory (iOS 27.1 SDK)')
print()
print('Status: generated, round 0 (KIT-SWIFTUI, 2026-10-19). Level 4 evidence: produced by')
print('`research/experiments/swiftui/inventory/inv.py` and `mkinv.py` from the public SDK module')
print('interfaces of `SwiftUICore` and `SwiftUI` (iPhoneSimulator 27.1). Only names, argument')
print('labels, conformance names and iOS availability are kept; no declaration, type signature,')
print('body or documentation text. Underscored, SPI and non-iOS (macOS/watchOS/tvOS/visionOS-only')
print(f'or iOS-unavailable) symbols are left out ({skipped} records skipped).')
print()
print('Legend: `[17.0]` = first iOS release with the member when it differs from its type;')
print('"deprecated" = marked deprecated for iOS. Types are grouped into areas by a name heuristic;')
print('the grouping is ours and only for navigation. Module = where the type is declared;')
print('`SwiftUI` re-exports `SwiftUICore`, so apps see one module.')
print()
by_area = collections.defaultdict(list)
for n, t in types.items():
    by_area[area_of(n, AREAS)].append(n)
order = [a for a, _ in AREAS] + ['Other']
print('## Contents')
print()
for a in order:
    if by_area.get(a):
        print(f'- {a} ({len(by_area[a])} types)')
print('- View modifiers by area')
print('- Top-level functions and macros')
print()
for a in order:
    if not by_area.get(a):
        continue
    print(f'## {a}')
    print()
    for n in sorted(by_area[a], key=str.lower):
        t = types[n]
        conf = list(dict.fromkeys(t['conf'] + members.get('__conf__' + n, [])))
        conf_s = (' : ' + ', '.join(conf)) if conf else ''
        print(f'- **{t["kind"]} `{n}`**{conf_s} — {t["mod"]}, iOS {t["ios"]}')
        if n == 'View':
            ml = [r for r in members.get(n, []) if r['kind'] in ('associatedtype', 'var', 'typealias')]
            if ml:
                print(f'  - requirements and core members: {fmt_members(ml, t["ios"])}')
            print('  - modifiers: see "View modifiers by area" below')
        else:
            ml = members.get(n, [])
            if ml:
                print(f'  - {fmt_members(ml, t["ios"])}')
        nested = sorted({p for p in members if p.startswith(n + '.') and p.count('.') >= 1})
        for p in nested:
            print(f'  - `{p}`: {fmt_members(members[p], t["ios"])}')
    print()
print('## View modifiers by area')
print()
print('Members of `View` (protocol extensions in both modules), i.e. the modifier and')
print('convenience surface. One entry per distinct label set.')
print()
mods = collections.defaultdict(list)
for r in members.get('View', []):
    if r['kind'] == 'func':
        mods[area_of(r['name'], MOD_AREAS)].append(r)
for a in [x for x, _ in MOD_AREAS] + ['Other']:
    if mods.get(a):
        print(f'### {a} ({len(mods[a])})')
        print()
        print(fmt_members(sorted(mods[a], key=lambda r: r['name'].lower()), None))
        print()
print('## Top-level functions, macros and other top-level names')
print()
print(fmt_members(sorted(members.get('__top__', []), key=lambda r: r['name'].lower()), None))
print()
print('## Evidence')
print()
print('| Claim | Level |')
print('|---|---|')
print('| Every name, label, conformance and availability in this file | 4 (public SDK module interfaces, names only, extracted by our scripts) |')
print('| Area grouping | ours (no evidence claim) |')
