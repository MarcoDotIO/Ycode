#!/usr/bin/env python3 -I
"""Generate the HealthKit type registry from the clean-room spec.

Input:  specs/frameworks/healthkit/identifiers.md (the spec's identifier appendix).
Output: Sources/HealthKit/Generated/{TypeTables,Constants,Enumerations}.swift

Run from anywhere:  python3 -I frameworks/healthkit/Scripts/gen_types.py
The output is committed; re-run after the spec changes.

Swift member names follow the public Swift import rules for Objective-C names
(strip the common prefix, lower-case the leading word unless the whole name is
an initialism). The category-type -> value-enumeration mapping is not part of
identifiers.md; it is taken from Apple's public documentation (evidence level 1)
and listed below so that it can be reviewed.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(PKG))
SPEC = os.path.join(REPO, "specs", "frameworks", "healthkit", "identifiers.md")
OUT = os.path.join(PKG, "Sources", "HealthKit", "Generated")

# Level 1 (public documentation): which value enumeration each category type uses.
SEVERITY = """AbdominalCramps Acne Bloating BreastPain ChestTightnessOrPain Chills Constipation Coughing
Diarrhea Dizziness Fainting Fatigue Fever GeneralizedBodyAche Headache Heartburn HotFlashes LossOfSmell
LossOfTaste LowerBackPain Nausea PelvicPain RapidPoundingOrFlutteringHeartbeat RunnyNose ShortnessOfBreath
SinusCongestion SkippedHeartbeat SoreThroat Vomiting Wheezing BladderIncontinence DrySkin HairLoss
VaginalDryness NightSweats MemoryLapse""".split()
CATEGORY_ENUM = {name: "HKCategoryValueSeverity" for name in SEVERITY}
CATEGORY_ENUM.update({
    "SleepAnalysis": "HKCategoryValueSleepAnalysis",
    "AppleStandHour": "HKCategoryValueAppleStandHour",
    "CervicalMucusQuality": "HKCategoryValueCervicalMucusQuality",
    "OvulationTestResult": "HKCategoryValueOvulationTestResult",
    "PregnancyTestResult": "HKCategoryValuePregnancyTestResult",
    "ProgesteroneTestResult": "HKCategoryValueProgesteroneTestResult",
    "MenstrualFlow": "HKCategoryValueMenstrualFlow",
    "Contraceptive": "HKCategoryValueContraceptive",
    "LowCardioFitnessEvent": "HKCategoryValueLowCardioFitnessEvent",
    "AppleWalkingSteadinessEvent": "HKCategoryValueAppleWalkingSteadinessEvent",
    "HeadphoneAudioExposureEvent": "HKCategoryValueHeadphoneAudioExposureEvent",
    "EnvironmentalAudioExposureEvent": "HKCategoryValueEnvironmentalAudioExposureEvent",
    "AudioExposureEvent": "HKCategoryValueEnvironmentalAudioExposureEvent",
    "AppetiteChanges": "HKCategoryValueAppetiteChanges",
    "MoodChanges": "HKCategoryValuePresence",
    "SleepChanges": "HKCategoryValuePresence",
    "BleedingAfterPregnancy": "HKCategoryValueVaginalBleeding",
    "BleedingDuringPregnancy": "HKCategoryValueVaginalBleeding",
    "BleedingAfterMenopause": "HKCategoryValueVaginalBleeding",
    "MenopausalState": "HKCategoryValueMenopausalState",
})

DIMENSIONS = {
    "scalar (count)": "scalar", "mass": "mass", "length": "length", "volume": "volume",
    "time": "time", "energy": "energy", "temperature": "temperature", "pressure": "pressure",
    "speed": "speed", "frequency (count/time)": "frequency", "power": "power",
    "conductance": "conductance", "sound pressure level": "soundPressureLevel",
    "effort score": "effortScore", "pharmacology (IU)": "pharmacology", "volume flow": "volumeFlow",
    "energy rate per mass": "energyRatePerMass", "VO2 rate": "vo2Rate",
    "mass concentration": "massConcentration",
}
AGG = {"0": "cumulative", "1": "discreteArithmetic", "2": "discreteTemporallyWeighted",
       "3": "discreteEquivalentContinuousLevel"}

# Enumerations that are written by hand (option sets, the error code).
MANUAL_ENUMS = {"HKErrorCode", "HKQueryOptions", "HKStatisticsOptions",
                "HKWorkoutEffortRelationshipQueryOptions"}
# String-constant groups emitted as global `let`s.
CONST_GROUPS = {"HKMetadata", "HKObject", "HKSample", "HKQuantitySample", "HKCategorySample",
                "HKCumulativeQuantitySample", "HKDiscreteQuantitySample", "HKDevice", "HKDefines",
                "HKHealthStore", "HKSourceRevision", "HKTypeIdentifiers", "HKWorkout",
                "HKWorkoutActivity"}

WORD = re.compile(r"[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z]+|[A-Z]+|\d+")
SWIFT_KEYWORDS = {"default", "none", "self", "Type", "class", "func", "init", "in", "is", "as"}


def words(name):
    return WORD.findall(name)


def lower_first(name):
    """Swift import rule: lower-case the leading initialism unless the name is all caps."""
    if not re.search(r"[a-z]", name):
        return name
    m = re.match(r"[A-Z]+", name)
    if not m:
        return name
    run = m.group(0)
    rest = name[len(run):]
    if len(run) > 1 and rest and rest[0].islower():
        return run[:-1].lower() + run[-1] + rest
    return run.lower() + rest


def swift_member(name, prefix):
    assert name.startswith(prefix), (name, prefix)
    return lower_first(name[len(prefix):])


def rows(text, header):
    """Table rows (lists of cells) of the section that starts with `header`."""
    out = []
    start = text.index(header)
    for line in text[start:].splitlines()[1:]:
        if line.startswith("## "):
            break
        if line.startswith("| `"):
            out.append([c.strip() for c in line.strip().strip("|").split("|")])
    return out


def code(cell):
    m = re.match(r"`([^`]*)`", cell)
    return m.group(1) if m else cell


def seconds(cell):
    return "nil" if cell in ("none", "n/a") else cell


def main():
    text = open(SPEC, encoding="utf-8").read()
    os.makedirs(OUT, exist_ok=True)
    header = ("// Generated by Scripts/gen_types.py from specs/frameworks/healthkit/identifiers.md.\n"
              "// Do not edit by hand; edit the generator or the spec and re-run it.\n\n")

    # ---- type tables -------------------------------------------------------------
    t = [header, "import Foundation\n\n"]
    q = rows(text, "## Quantity types")
    t.append("extension HKQuantityTypeIdentifier {\n")
    for r in q:
        ident = code(r[0])
        dep = "deprecated" in r[1]
        if dep:
            t.append("    @available(*, deprecated)\n")
        t.append(f"    public static let {swift_member(ident, 'HKQuantityTypeIdentifier')} = "
                 f"HKQuantityTypeIdentifier(rawValue: \"{ident}\")\n")
    t.append("}\n\n")
    t.append("let quantityTypeTable: [QuantityTypeSpec] = [\n")
    for r in q:
        ident = code(r[0])
        agg = AGG[re.search(r"\[(\d)\]", r[2]).group(1)]
        dim = DIMENSIONS[r[3]]
        t.append(f"    QuantityTypeSpec(identifier: \"{ident}\", style: .{agg}, dimension: .{dim}, "
                 f"maximumDuration: {seconds(r[4])}, minimumDuration: {seconds(r[5])}),\n")
    t.append("]\n\n")

    kinds = [
        ("## Category types", "HKCategoryTypeIdentifier", "category"),
        ("## Characteristic types", "HKCharacteristicTypeIdentifier", "characteristic"),
        ("## Correlation types", "HKCorrelationTypeIdentifier", "correlation"),
        ("## Document types", "HKDocumentTypeIdentifier", "document"),
        ("## Clinical record types", "HKClinicalTypeIdentifier", "clinical"),
        ("## Scored assessment types", "HKScoredAssessmentTypeIdentifier", "scoredAssessment"),
    ]
    table = []
    for section, prefix, kind in kinds:
        rs = rows(text, section)
        t.append(f"extension {prefix} {{\n")
        for r in rs:
            ident, value = code(r[0]), code(r[1])
            if "deprecated" in r[2]:
                t.append("    @available(*, deprecated)\n")
            t.append(f"    public static let {swift_member(ident, prefix)} = {prefix}(rawValue: \"{value}\")\n")
            enum = "nil"
            if kind == "category":
                short = ident[len(prefix):]
                enum = f"\"{CATEGORY_ENUM.get(short, 'HKCategoryValue')}\""
            per_object = "true" if r[5] == "yes" else "false"
            table.append(f"    OtherTypeSpec(identifier: \"{value}\", kind: .{kind}, "
                         f"maximumDuration: {seconds(r[4])}, perObject: {per_object}, valueEnum: {enum}),\n")
        t.append("}\n\n")
    t.append("let otherTypeTable: [OtherTypeSpec] = [\n")
    seen = set()
    for line in table:
        key = re.search(r'identifier: "([^"]+)"', line).group(1)
        if key in seen:        # deprecated aliases share a string value
            continue
        seen.add(key)
        t.append(line)
    t.append("]\n")
    open(os.path.join(OUT, "TypeTables.swift"), "w", encoding="utf-8").write("".join(t))

    # ---- string constants --------------------------------------------------------
    c = [header]
    for r in rows(text, "## Other string constants"):
        sym, value, group = code(r[0]), code(r[1]), r[3]
        if group not in CONST_GROUPS:
            continue
        if "deprecated" in r[2]:
            c.append("@available(*, deprecated)\n")
        c.append(f"public let {sym}: String = \"{value}\"\n")
    open(os.path.join(OUT, "Constants.swift"), "w", encoding="utf-8").write("".join(c))

    # ---- enumerations ------------------------------------------------------------
    e = [header]
    sec = text[text.index("## Enumerations"):text.index("## Functions")]
    for m in re.finditer(r"### `(\w+)`[^\n]*\n\n([^\n]+)\n", sec):
        name, body = m.group(1), m.group(2)
        if name in MANUAL_ENUMS:
            continue
        cases = []
        for part in body.split("; "):
            mm = re.match(r"`(\w+)` = (\d+)(.*)", part.strip())
            if not mm:
                raise SystemExit(f"cannot parse {part!r} in {name}")
            avail = mm.group(3)
            if "unavailable" in avail:
                continue
            cases.append((mm.group(1), int(mm.group(2)), "deprecated" in avail))
        ws = [words(cn) for cn, _, _ in cases]
        if len(ws) == 1:
            prefix_words = words(name)
        else:
            prefix_words = []
            for i, w in enumerate(ws[0]):
                if all(len(x) > i and x[i] == w for x in ws):
                    prefix_words.append(w)
                else:
                    break
        e.append(f"public enum {name}: Int, Sendable, CaseIterable {{\n")
        aliases = []
        used = {}
        for cn, raw, dep in cases:
            pw = list(prefix_words)
            while True:
                stripped = cn[len("".join(pw)):]
                if stripped and not stripped[0].isdigit():
                    break
                pw = pw[:-1]
            member = lower_first(stripped)
            if member in SWIFT_KEYWORDS:
                member = f"`{member}`"
            if raw in used:
                aliases.append((member, used[raw], dep))
                continue
            used[raw] = member
            if dep:  # an attribute here would block CaseIterable synthesis
                e.append("    /// Deprecated in the SDK.\n")
            e.append(f"    case {member} = {raw}\n")
        for member, target, dep in aliases:
            if dep:
                e.append("    @available(*, deprecated)\n")
            e.append(f"    public static var {member}: {name} {{ .{target} }}\n")
        e.append("}\n\n")
    open(os.path.join(OUT, "Enumerations.swift"), "w", encoding="utf-8").write("".join(e))
    print("generated", OUT, file=sys.stderr)


if __name__ == "__main__":
    main()
