#!/usr/bin/env python3
"""Generate Swift Testing golden-layout tests from the spec.

Reads specs/frameworks/swiftui/golden-layout.md (the measured table and the
default-spacing matrix) and writes Tests/OpenViewsTests/GoldenLayoutTests.swift
and Tests/OpenViewsTests/GoldenSpacingTests.swift: one test per case, named
after the case id. Since R4 it also reads the Dynamic Type table of
07-text-images-color.md §1.1 and writes Tests/OpenViewsTests/Support/
GoldenTextRuns.swift: the measured widths of "Ag" per point size and weight
(rows `font.*`, frames of `dyn.*`), inputs of the reference test font. Probe sources are translated mechanically into the test
DSL (Tests/OpenViewsTests/Support/DSL.swift); cases this round cannot run are
emitted as disabled tests with the reason.

It also writes Tests/OpenViewsTests/GoldenViewLayoutTests.swift: the same
runnable cases built from the probe source itself as SwiftUI views (round
R2), lowered by the view graph onto the layout engine.

Usage (from frameworks/swiftui):
    python3 -I Scripts/gen_golden_tests.py [path/to/golden-layout.md]
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.dirname(HERE)
DEFAULT_SPEC = os.path.join(PKG, "..", "..", "specs", "frameworks", "swiftui", "golden-layout.md")
TEXT_SPEC = os.path.join(PKG, "..", "..", "specs", "frameworks", "swiftui", "07-text-images-color.md")
OUT_RUNS = os.path.join(PKG, "Tests", "OpenViewsTests", "Support", "GoldenTextRuns.swift")
OUT_CASES = os.path.join(PKG, "Tests", "OpenViewsTests", "GoldenLayoutTests.swift")
OUT_SPACING = os.path.join(PKG, "Tests", "OpenViewsTests", "GoldenSpacingTests.swift")
OUT_VIEWS = os.path.join(PKG, "Tests", "OpenViewsTests", "GoldenViewLayoutTests.swift")

FIT_COLUMNS = ["nil×nil", "0×0", "∞×∞", "100×nil", "nil×100", "100×100", "300×500"]

# Cases that need later rounds. Prefix match on the case id.
SKIP = [
    ("image.symbol.largeTitle", "R5 symbols: symbol metrics per font"),
    ("image.symbol.scaleSmall", "R5 symbols: symbol metrics per image scale"),
    ("image.symbol.scaleLarge", "R5 symbols: symbol metrics per image scale"),
    ("image.symbol.wide", "R5 symbols: metrics of another symbol"),
    ("label", "R8 controls: Label"),
    ("button.", "R8 controls: Button styles"),
    ("toggle", "R8 controls: Toggle"),
    ("slider", "R8 controls: Slider"),
    ("stepper", "R8 controls: Stepper"),
    ("progress.", "R8 controls: ProgressView"),
    ("picker.", "R8 controls: Picker"),
    ("textfield.", "R8 controls: TextField"),
    ("secureField", "R8 controls: SecureField"),
    ("datePicker.", "R8 controls: DatePicker"),
    ("gauge", "R8 controls: Gauge"),
    ("link", "R8 controls: Link"),
    ("scrollView", "R9 containers: ScrollView"),
    ("list.", "R9 containers: List (UIKit-backed, informative only)"),
    ("form.", "R9 containers: Form (UIKit-backed, informative only)"),
    ("navigationStack", "R9 containers: NavigationStack (UIKit-backed, informative only)"),
    ("tabView", "R9 containers: TabView (UIKit-backed, informative only)"),
]
# Exact-id skips (prefix rules above would be too broad).
SKIP_EXACT = {
    "image.symbol": "R5 symbols: the case measures a symbol itself (its size is a stub fixture)",
}

# Probe sources the mechanical translation cannot handle (the table
# truncates long sources with "…"); the full sources are in 04-layout.md §6.
OVERRIDES = {
    "grid": 'grid { gridRow { text("A").probe("a"); text("Longer").probe("b") }; '
            'gridRow { text("Wide cell").probe("c"); color().frame(width: 10, height: 10).probe("d") } }',
    "grid.spacing0": 'grid(horizontalSpacing: 0, verticalSpacing: 0) { '
                     'gridRow { text("A").probe("a"); text("Longer").probe("b") }; '
                     'gridRow { text("Wide cell").probe("c"); color().frame(width: 10, height: 10).probe("d") } }',
    "grid.flex": 'grid { gridRow { color().probe("a"); text("Fixed").probe("b") }; '
                 'gridRow { text("X").gridCellColumns(2).probe("c") } }',
}

# View sources where the table abbreviates (statements on one line need ";").
VIEW_OVERRIDES = {
    "grid": 'Grid { GridRow { Text("A").probe("a"); Text("Longer").probe("b") }; '
            'GridRow { Text("Wide cell").probe("c"); Color.red.frame(width: 10, height: 10).probe("d") } }',
    "grid.spacing0": 'Grid(horizontalSpacing: 0, verticalSpacing: 0) { '
                     'GridRow { Text("A").probe("a"); Text("Longer").probe("b") }; '
                     'GridRow { Text("Wide cell").probe("c"); Color.red.frame(width: 10, height: 10).probe("d") } }',
    "grid.flex": 'Grid { GridRow { Color.red.probe("a"); Text("Fixed").probe("b") }; '
                 'GridRow { Text("X").gridCellColumns(2).probe("c") } }',
}

# Dynamic Type cases: the table abbreviates the source ("for each text style").
STYLES = ["largeTitle", "title", "title2", "title3", "headline", "subheadline", "body", "callout",
          "footnote", "caption", "caption2"]
DYN_SIZES = {"xSmall": "xSmall", "small": "small", "medium": "medium", "large": "large",
             "xLarge": "xLarge", "xxLarge": "xxLarge", "xxxLarge": "xxxLarge",
             "ax1": "accessibility1", "ax2": "accessibility2", "ax3": "accessibility3",
             "ax4": "accessibility4", "ax5": "accessibility5"}
for cat, swift_case in DYN_SIZES.items():
    OVERRIDES["dyn." + cat] = "vstack(alignment: .leading, spacing: 0) { " + "; ".join(
        'text("Ag").font(.style(.%s, .%s)).probe("%s")' % (st, swift_case, st) for st in STYLES) + " }"
    VIEW_OVERRIDES["dyn." + cat] = "VStack(alignment: .leading, spacing: 0) { " + "; ".join(
        'Text("Ag").font(.%s).probe("%s")' % (st, st) for st in STYLES) + \
        " }.environment(\\.dynamicTypeSize, .%s)" % swift_case

VIEW_TRANSLATIONS = [
    (r"Text\(longText\)", "Text(Fixture.longText)"),
]

TRANSLATIONS = [
    (r"\bHStack\b", "hstack"),
    (r"\bVStack\b", "vstack"),
    (r"\bZStack\b", "zstack"),
    (r"\bViewThatFits\b", "viewThatFits"),
    (r"\bLazyVGrid\b", "lazyVGrid"),
    (r"GeometryReader \{ _ in", "geometryReader {"),
    (r"ForEach\(([^,]+), id: \\\.self\)", r"forEach(\1)"),
    (r"Text\(longText\)", "text(Fixture.longText)"),
    (r"\bText\(", "text("),
    (r"\bImage\(systemName:", "image(systemName:"),
    (r"\bColor\.(red|blue|green)\b", "color()"),
    (r"\bRectangle\(\)", "rectangle()"),
    (r"\bCircle\(\)", "circle()"),
    (r"\bCapsule\(\)", "capsule()"),
    (r"\bSpacer\(", "spacer("),
    (r"\bDivider\(\)", "divider()"),
]


def translate(src):
    out = src
    for pat, rep in TRANSLATIONS:
        out = re.sub(pat, rep, out)
    return out


def translate_view(src):
    out = src
    for pat, rep in VIEW_TRANSLATIONS:
        out = re.sub(pat, rep, out)
    return out


def skip_reason(case_id):
    if case_id in SKIP_EXACT:
        return SKIP_EXACT[case_id]
    for prefix, reason in SKIP:
        if case_id == prefix.rstrip(".") or case_id.startswith(prefix):
            return reason
    return None


def num(s):
    s = s.strip()
    if s == "∞":
        return "inf"
    if s == "nil":
        return "nil"
    float(s)  # validate
    return s


def size(s):
    s = s.strip()
    if s in ("–", "-", ""):
        return None
    w, h = s.split("x")
    return num(w), num(h)


def proposal(col):
    w, h = col.split("×")
    return num(w), num(h)


def parse_frames(cell):
    frames = {}
    baselines = None
    for part in [p.strip() for p in cell.split(";") if p.strip()]:
        m = re.match(r"^(\w+)=\(([^)]*)\)$", part)
        if m:
            frames[m.group(1)] = [num(v) for v in m.group(2).split(",")]
            continue
        m = re.match(r"^baselines ([\d.\-]+)/([\d.\-]+)$", part)
        if m:
            baselines = (num(m.group(1)), num(m.group(2)))
    return frames, baselines


def swift_ident(case_id):
    return "golden_" + re.sub(r"[^A-Za-z0-9]", "_", case_id)


def swift_string(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def parse_table(lines):
    rows = []
    for line in lines:
        if not line.startswith("| `"):
            continue
        cells = [c.strip() for c in re.split(r"\s\|\s", line.strip().strip("|"))]
        if len(cells) != 11:
            raise SystemExit("unexpected column count %d in: %s" % (len(cells), line[:80]))
        case_id = cells[0].strip("`")
        source = cells[1].strip("`")
        rows.append((case_id, source, cells[2], cells[3:10], cells[10]))
    return rows


def emit_cases(rows, spec_rel):
    out = []
    out.append("// GENERATED by Scripts/gen_golden_tests.py from %s. Do not edit." % spec_rel)
    out.append("// One test per golden case (04-layout.md; 10-plan.md suites T-LAYOUT-F and T-LAYOUT-T).")
    out.append("import Foundation")
    out.append("import Testing")
    out.append("#if OPENVIEWS_RENAMED")
    out.append("@testable import OpenViewsCore")
    out.append("@testable import OpenViews")
    out.append("#else")
    out.append("@testable import SwiftUICore")
    out.append("@testable import SwiftUI")
    out.append("#endif")
    out.append("")
    out.append("@Suite(\"golden-layout.md\")")
    out.append("struct GoldenLayoutTests {")
    counts = {"run": 0, "skip": 0}
    for case_id, source, placed, fits, frames_cell in rows:
        reason = skip_reason(case_id)
        ident = swift_ident(case_id)
        display = "%s — %s" % (case_id, source)
        if reason:
            counts["skip"] += 1
            out.append("    @Test(%s, .disabled(%s))" % (swift_string(display), swift_string(reason)))
            out.append("    func %s() {}" % ident)
            out.append("")
            continue
        counts["run"] += 1
        dsl = OVERRIDES.get(case_id) or translate(source)
        if "…" in dsl:
            raise SystemExit("truncated source without override: " + case_id)
        pw, ph = proposal(placed)
        fit_lines = []
        for col, val in zip(FIT_COLUMNS, fits):
            sz = size(val)
            if sz is None:
                continue
            w, h = proposal(col)
            fit_lines.append("            .init(%s, %s, %s, %s)," % (w, h, sz[0], sz[1]))
        frames, baselines = parse_frames(frames_cell)
        out.append("    @Test(%s)" % swift_string(display))
        out.append("    func %s() {" % ident)
        out.append("        let c = GoldenCase(")
        out.append("            id: %s, placed: CGSize(width: %s, height: %s)," % (swift_string(case_id), pw, ph))
        out.append("            fits: [")
        out.extend(["    " + l for l in fit_lines])
        out.append("            ],")
        if frames:
            out.append("            frames: [")
            for name in sorted(frames):
                x, y, w, h = frames[name]
                out.append("                %s: CGRect(%s, %s, %s, %s)," % (swift_string(name), x, y, w, h))
            out.append("            ],")
        else:
            out.append("            frames: [:],")
        out.append("            baselines: %s)" % ("(%s, %s)" % baselines if baselines else "nil"))
        out.append("        Golden.run(c) { %s }" % dsl)
        out.append("    }")
        out.append("")
    out.append("}")
    return "\n".join(out) + "\n", counts


def emit_view_cases(rows, spec_rel):
    out = []
    out.append("// GENERATED by Scripts/gen_golden_tests.py from %s. Do not edit." % spec_rel)
    out.append("// The runnable golden cases built from the probe sources as views (round R2): the view")
    out.append("// graph lowers them onto the layout engine (04-layout.md; 10-plan.md T-LAYOUT-F, T-LAYOUT-T).")
    out.append("import Foundation")
    out.append("import Testing")
    out.append("#if OPENVIEWS_RENAMED")
    out.append("@testable import OpenViewsCore")
    out.append("@testable import OpenViews")
    out.append("#else")
    out.append("@testable import SwiftUICore")
    out.append("@testable import SwiftUI")
    out.append("#endif")
    out.append("")
    out.append("@MainActor")
    out.append("@Suite(\"golden-layout.md, built from views\")")
    out.append("struct GoldenViewLayoutTests {")
    counts = {"run": 0, "skip": 0}
    for case_id, source, placed, fits, frames_cell in rows:
        reason = skip_reason(case_id)
        if reason:
            counts["skip"] += 1
            continue
        counts["run"] += 1
        src = VIEW_OVERRIDES.get(case_id) or translate_view(source)
        if "…" in src:
            raise SystemExit("truncated view source without override: " + case_id)
        ident = swift_ident(case_id).replace("golden_", "goldenView_", 1)
        pw, ph = proposal(placed)
        fit_lines = []
        for col, val in zip(FIT_COLUMNS, fits):
            sz = size(val)
            if sz is None:
                continue
            w, h = proposal(col)
            fit_lines.append("            .init(%s, %s, %s, %s)," % (w, h, sz[0], sz[1]))
        frames, baselines = parse_frames(frames_cell)
        out.append("    @Test(%s)" % swift_string("%s — %s" % (case_id, source)))
        out.append("    func %s() {" % ident)
        out.append("        let c = GoldenCase(")
        out.append("            id: %s, placed: CGSize(width: %s, height: %s)," % (swift_string("view:" + case_id), pw, ph))
        out.append("            fits: [")
        out.extend(["    " + l for l in fit_lines])
        out.append("            ],")
        if frames:
            out.append("            frames: [")
            for name in sorted(frames):
                x, y, w, h = frames[name]
                out.append("                %s: CGRect(%s, %s, %s, %s)," % (swift_string(name), x, y, w, h))
            out.append("            ],")
        else:
            out.append("            frames: [:],")
        out.append("            baselines: %s)" % ("(%s, %s)" % baselines if baselines else "nil"))
        out.append("        Golden.run(c) { ViewGraph.layoutNode(for: %s) }" % src)
        out.append("    }")
        out.append("")
    out.append("}")
    return "\n".join(out) + "\n", counts


SPACING_NODES = {
    "text": 'text("A")',
    "textCaption": 'text("A").font(.caption)',
    "image": 'image(systemName: "star")',
    "color": "color().frame(width: 10, height: 10)",
    "padded": 'text("A").padding()',
}
SPACING_SKIP = {
    "button": "R8 controls: Button",
    "toggle": "R8 controls: Toggle",
    "textField": "R8 controls: TextField",
}


def parse_spacing(lines):
    header = None
    rows = []
    for line in lines:
        if line.startswith("| from \\ to |"):
            header = [c.strip() for c in line.strip().strip("|").split("|")][1:]
            continue
        if header and line.startswith("| ") and not line.startswith("|---"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if len(cells) != len(header) + 1:
                break
            rows.append((cells[0], cells[1:]))
    return header, rows


def emit_spacing(header, rows, spec_rel):
    out = []
    out.append("// GENERATED by Scripts/gen_golden_tests.py from %s. Do not edit." % spec_rel)
    out.append("// Default spacing between kinds of views (04-layout.md §4.1; golden-layout.md matrix).")
    out.append("import Foundation")
    out.append("import Testing")
    out.append("#if OPENVIEWS_RENAMED")
    out.append("@testable import OpenViewsCore")
    out.append("@testable import OpenViews")
    out.append("#else")
    out.append("@testable import SwiftUICore")
    out.append("@testable import SwiftUI")
    out.append("#endif")
    out.append("")
    out.append("@Suite(\"golden-layout.md default spacing\")")
    out.append("struct GoldenSpacingTests {")
    counts = {"run": 0, "skip": 0}
    for frm, values in rows:
        for to, val in zip(header, values):
            h, v = [x.strip() for x in val.split("/")]
            case_id = "spacing.%s.%s" % (frm, to)
            ident = swift_ident(case_id)
            reason = SPACING_SKIP.get(frm) or SPACING_SKIP.get(to)
            display = "%s — %s → %s: %s / %s" % (case_id, frm, to, h, v)
            if reason:
                counts["skip"] += 1
                out.append("    @Test(%s, .disabled(%s))" % (swift_string(display), swift_string(reason)))
                out.append("    func %s() {}" % ident)
                out.append("")
                continue
            counts["run"] += 1
            out.append("    @Test(%s)" % swift_string(display))
            out.append("    func %s() {" % ident)
            out.append("        GoldenSpacing.check(%s, from: { %s }, to: { %s }, horizontal: %s, vertical: %s)"
                       % (swift_string(case_id), SPACING_NODES[frm], SPACING_NODES[to], h, v))
            out.append("    }")
            out.append("")
    out.append("}")
    return "\n".join(out) + "\n", counts


# 07 §1.1 row names → SwiftUI text styles; weight class per style.
TABLE_ROWS = {"largeTitle": "largeTitle", "title1": "title", "title2": "title2", "title3": "title3",
              "headline (semibold)": "headline", "subheadline": "subheadline", "body": "body",
              "callout": "callout", "footnote": "footnote", "caption1": "caption", "caption2": "caption2"}
CATEGORIES = ["xSmall", "small", "medium", "large", "xLarge", "xxLarge", "xxxLarge", "ax1", "ax2", "ax3", "ax4", "ax5"]


def parse_point_sizes(path):
    sizes = {}
    with open(path, encoding="utf-8") as f:
        text = f.read()
    section = text[text.index("### 1.1"):text.index("### 1.2")]
    if True:
        for line in section.splitlines():
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if len(cells) == 13 and cells[0] in TABLE_ROWS:
                sizes[TABLE_ROWS[cells[0]]] = [float(c.strip("*")) for c in cells[1:]]
    if len(sizes) != len(TABLE_ROWS):
        raise SystemExit("07 §1.1 point-size table not found")
    return sizes


def emit_text_runs(rows, sizes):
    """Measured "Ag" widths per (point size, weight) from font.* and dyn.* rows."""
    runs = {}
    sources = {}
    def add(style, cat, width, source):
        size = sizes[style][CATEGORIES.index(cat)]
        weight = 600 if style == "headline" else 400
        key = (size, weight)
        if key in runs and abs(runs[key] - width) > 0.005:
            print("warning: Ag at %g/%d: %s gives %s, %s gave %s" % (size, weight, source, width, sources[key], runs[key]))
            return
        runs.setdefault(key, width)
        sources.setdefault(key, source)
    for case_id, source, placed, fits, frames_cell in rows:
        if case_id.startswith("font."):
            sz = size(fits[0])
            add(case_id[5:], "large", float(sz[0]), case_id)
        elif case_id.startswith("dyn."):
            frames, _ = parse_frames(frames_cell)
            for st, fr in frames.items():
                add(st, case_id[4:], float(fr[2]), case_id)
    out = ["// GENERATED by Scripts/gen_golden_tests.py from specs/frameworks/swiftui/golden-layout.md",
           "// (rows font.*, frames of dyn.*) and 07-text-images-color.md §1.1 (point sizes). Do not edit.",
           "// Measured widths of \"Ag\" per point size and weight class: inputs of the reference test font.",
           "",
           "enum GoldenTextRuns {",
           "    struct Key: Hashable {",
           "        var text: String",
           "        var size: Double",
           "        var weight: Int",
           "    }",
           "",
           "    static let widths: [Key: Double] = ["]
    for (size_, weight), w in sorted(runs.items()):
        thirds = round(w * 3)
        val = "%d.0 / 3" % thirds if abs(thirds / 3 - w) < 0.006 else repr(w)
        out.append("        Key(text: \"Ag\", size: %g, weight: %d): %s,  // %s" % (size_, weight, val, sources[(size_, weight)]))
    out.append("    ]")
    out.append("}")
    return "\n".join(out) + "\n", len(runs)


def main():
    spec = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SPEC
    with open(spec, encoding="utf-8") as f:
        lines = f.read().splitlines()
    spec_rel = "specs/frameworks/swiftui/golden-layout.md"
    rows = parse_table(lines)
    text, counts = emit_cases(rows, spec_rel)
    with open(OUT_CASES, "w", encoding="utf-8") as f:
        f.write(text)
    vtext, vcounts = emit_view_cases(rows, spec_rel)
    with open(OUT_VIEWS, "w", encoding="utf-8") as f:
        f.write(vtext)
    rtext, rcount = emit_text_runs(rows, parse_point_sizes(TEXT_SPEC))
    with open(OUT_RUNS, "w", encoding="utf-8") as f:
        f.write(rtext)
    print("text runs: %d" % rcount)
    header, srows = parse_spacing(lines)
    stext, scounts = emit_spacing(header, srows, spec_rel)
    with open(OUT_SPACING, "w", encoding="utf-8") as f:
        f.write(stext)
    print("golden cases: %d (%d run, %d disabled)" % (len(rows), counts["run"], counts["skip"]))
    print("view-built golden cases: %d" % vcounts["run"])
    print("spacing pairs: %d (%d run, %d disabled)" % (scounts["run"] + scounts["skip"], scounts["run"], scounts["skip"]))


if __name__ == "__main__":
    main()
