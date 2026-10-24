# HealthKit spec: units (`HKUnit`) and quantities (`HKQuantity`)

Part of `specs/frameworks/healthkit/`. Units are interop data: apps pass unit
strings to `unitFromString:`, store them, and expect `unitString` to round
trip. Everything in §2–§6 was measured with `HealthProbe -phase basic` on
iOS 27.1 and 27.0 (identical; level 3); constructor names are level 4.

## 1. Model

- A unit is a product of **factors**; each factor is an **atom** (a base
  unit symbol, optionally with a metric prefix, and for moles a molar mass)
  raised to a non-zero integer exponent. The empty product is the **null
  unit**, written `()`; `isNull` is YES only for it.
- Every atom belongs to a **dimension**. Two units are compatible when their
  dimension vectors are equal. Conversion multiplies by the ratio of the two
  units' scale factors to their dimension's reference unit; temperature
  (degC, degF) is affine (scale and offset) and so are no other atoms.
- `count` and `%` are both dimensionless and compatible: 1 % converts to
  1 count. Percent values are **fractions** (0.5 means 50 %); the walking
  steadiness ranges are 0 … 1 in `%` units.
- Equal unit strings give the **same object** (`unitFromString:` caches;
  identity and `isEqual:` both hold). `description` equals `unitString`.
- Quantities (`HKQuantity`) hold a double and a unit. `isEqual:` and
  `compare:` work across compatible units (1000 g equals 1 kg, compare 0);
  `description` prints the stored value and unit ("1000 g"). Converting or
  comparing incompatible quantities raises `NSInvalidArgumentException`
  (`errors.md` §3).

## 2. Unit-string grammar (observed)

    unit       := ws? product ( "/" denominator )?      | ""          (null unit)
    product    := term ( "*" term )*  | "1"
    denominator:= term ( "*" term )*  | "(" term ( "*" term )* ")"
    term       := atom ( "^" int )?  | "(" product ")" ( "^" int )?
    int        := "-"? digit+
    atom       := prefix? prefixable | fixed | molar
    molar      := prefix? "mol" "<" decimal ">"

- Everything after `/` is the denominator: `count/min*kg` parses as count
  per (minute·kilogram).
- A leading space is ignored; a **trailing space is an error**. Atoms are
  case sensitive (`KG`, `Kg` fail). Long names (`kilogram`, `diopter`,
  `prismDiopter`) fail; the symbols are short.
- `mol` without a molar mass (`mmol`) parses but is not convertible to mass.
- Exponents may be negative (`m^-1` → `1/m`). `1/min` is accepted.

### 2.1 Metric prefixes

| Prefix | Symbol | Factor | `HKMetricPrefix` |
|---|---|---|---|
| femto | f | 1e-15 | 13 (iOS 13) |
| pico | p | 1e-12 | 1 |
| nano | n | 1e-9 | 2 |
| micro | **mc** | 1e-6 | 3 |
| milli | m | 1e-3 | 4 |
| centi | c | 1e-2 | 5 |
| deci | d | 1e-1 | 6 |
| deca | da | 1e1 | 7 |
| hecto | h | 1e2 | 8 |
| kilo | k | 1e3 | 9 |
| mega | M | 1e6 | 10 |
| giga | G | 1e9 | 11 |
| tera | T | 1e12 | 12 |

`u` for micro is rejected (`ug`, `um`, `uS`, `uV` fail); peta (`P`) and atto
(`a`) do not exist.

### 2.2 Atoms

Prefixable (the classes with a `…WithMetricPrefix:` constructor, level 4):

| Symbol | Dimension | Reference scale |
|---|---|---|
| `g` | mass | 1 g |
| `m` | length | 1 m |
| `L` | volume | 1 L |
| `s` | time | 1 s |
| `J` | energy | 1 J |
| `Pa` | pressure | 1 Pa |
| `S` | conductance | 1 S (siemens) |
| `V` | electric potential | 1 V |
| `W` | power | 1 W |
| `Hz` | frequency (= count/s) | 1 Hz |
| `lx` | illuminance | 1 lx |
| `rad` | angle | 1 rad |
| `mol<M>` | amount; converts to mass with molar mass M g/mol | M g |

Fixed (no prefix):

| Symbol | Meaning | Value in reference units |
|---|---|---|
| `lb` | pound | 453.59237 g |
| `oz` | ounce | 28.349523125 g |
| `st` | stone | 6350.29318 g (14 lb) |
| `mi` | mile | 1609.344 m |
| `ft` | foot | 0.3048 m |
| `in` | inch | 0.0254 m |
| `yd` | yard | 0.9144 m |
| `fl_oz_us` | US fluid ounce | 0.0295735295625 L |
| `fl_oz_imp` | imperial fluid ounce | 0.0284130625 L |
| `pt_us` | US pint | 0.473176473 L |
| `pt_imp` | imperial pint | 0.56826125 L |
| `cup_us` | US cup | 0.2365882365 L |
| `cup_imp` | imperial cup | 0.284130625 L |
| `min`, `hr`, `d` | minute, hour, day | 60, 3600, 86400 s |
| `cal` | small calorie | 4.184 J |
| `kcal` | kilocalorie | 4184 J |
| `Cal` | large calorie (food calorie) | 4184 J (a distinct unit object from `kcal`, equal magnitude) |
| `degC` | degree Celsius | K = °C + 273.15 |
| `degF` | degree Fahrenheit | K = (°F − 32) × 5/9 + 273.15 |
| `K` | kelvin | 1 K |
| `count` | count | 1 |
| `%` | percent (fraction) | 1 count |
| `mmHg` | millimeter of mercury | 133.322368421 Pa (760 mmHg = 1 atm) |
| `cmAq` | centimeter of water | 98.066496063 Pa |
| `atm` | atmosphere | 101325 Pa |
| `inHg` | inch of mercury | 3386.38816 Pa |
| `dBASPL` | A-weighted sound pressure level | own dimension; not convertible to Pa |
| `dBHL` | hearing level | own dimension |
| `IU` | international unit | own dimension |
| `deg` | degree (angle) | π/180 rad |
| `D` | diopter | own dimension (optical power) |
| `pD` | prism diopter | own dimension |
| `appleEffortScore` | effort score | own dimension, unitless |

`kcal` and `Cal` are both accepted; `HKUnit.kilocalorieUnit` renders `kcal`,
`largeCalorieUnit` renders `Cal`, `smallCalorieUnit` and `calorieUnit` render
`cal` (level 3).

## 3. Canonical `unitString`

`unitFromString:` and the algebra methods produce a canonical string:

| Input / operation | `unitString` |
|---|---|
| `count/min` | `count/min` |
| `kg*m^2` | `m^2·kg` |
| `(kg*m)/s^2` | `m·kg/s^2` |
| `count/min*kg` | `count/min·kg` |
| `mL/(kg*min)` | `mL/min·kg` |
| `kcal/(kg*hr)` | `kcal/hr·kg` |
| `m^-1` | `1/m` |
| `1/min` | `1/min` |
| `""` | `()` |
| `mmol<180.15588000005408>/L` | `mmol<180.1558800000541>/L` |
| kg × m (algebra) | `m·kg` |
| m^3, m^0, m^-2 | `m^3`, `()`, `1/m^2` |
| reciprocal of min, of count/min | `1/min`, `min/count` |
| m / m, count / count | `()` (null), `()` |
| count × count | `count^2` |
| mole with milli prefix and the blood-glucose molar mass constant | `mmol<180.1558800000541>` |

Rules: positive-exponent factors form the numerator, negative ones the
denominator after a single `/`; factors within a side are joined with `·`
(U+00B7 MIDDLE DOT, not `*`); an empty numerator is written `1`; equal atoms
combine their exponents and vanish at 0; molar masses print as the shortest
decimal that round-trips the double. Factor order within a side: length and
time factors were printed before mass factors in every example; the full
ordering rule was not determined (open question, `plan.md` §5).

## 4. Algebra

`unitMultipliedByUnit:`, `unitDividedByUnit:`, `unitRaisedToPower:`,
`reciprocalUnit` (names level 4) combine factor lists as in §3. The
blood-glucose molar mass constant (`HKUnitMolarMassBloodGlucose`) is
180.15588 g/mol (from the rendered unit, level 3).

## 5. Formatter bridges

Names only (level 4): `unitFromMassFormatterUnit:`,
`massFormatterUnitFromUnit:`, and the length and energy pairs map between
Foundation's formatter unit enums and `HKUnit`. Behavior not probed.

## 6. Golden conversions (level 3)

| From | To | Result |
|---|---|---|
| 100 degC | degF | 212 |
| 0 degC | K | 273.15 |
| 98.6 degF | degC | 37.0000000000001 |
| 1 degC | K (reference) | 274.15 |
| 1 degF | K | 255.927777778 |
| 1 mi | m | 1609.344 |
| 1 lb | kg | 0.45359237 |
| 1 st | lb | 14 |
| 1 kcal | kJ | 4.184 |
| 1 Cal | cal | 1000 |
| 1 atm | mmHg | 760 |
| 1 inHg | mmHg | 25.4000000157908 |
| 1 cmAq | Pa | 98.0664960629921 |
| 1 fl_oz_us | mL | 29.5735295625 |
| 1 fl_oz_imp | mL | 28.4130625 |
| 1 cup_us / cup_imp | mL | 236.5882365 / 284.130625 |
| 1 pt_us / pt_imp | mL | 473.176473 / 568.26125 |
| 1 d | s | 86400 |
| 100 mg/dL | mmol<180.15588000005408>/L | 5.55074860726 |
| 1 deg | rad | 0.0174532925199433 |
| 1 count/min | count/s | 0.0166666666666667 |
| 60 count/min | Hz | 1 |
| 10 km/hr | m/s | 2.77777777777778 |
| 1 oz | g | 28.349523125 |
| 1 yd | m | 0.9144 |
| 50 % | count | 50 |
| 1 kcal/hr | J/s | 1.16222222222 |
| 1 g/dL | g/L | 10 |
| 1 mi/hr | m/s | 0.44704 |
| 1 dBASPL | Pa | incompatible |
| 1 g | m | exception "Attempt to convert incompatible units: g, m" |

Prefix scale checks: `Mg` = 1e6 g, `Gg` = 1e9 g, `Tm` = 1e12 m, `fs` = 1e-15 s,
`cs`/`ds`/`das`/`hs`/`ks`/`Ms`/`Gs`/`Ts` = 1e-2 … 1e12 s, `ps` = 1e-12 s,
`fJ` = 1e-15 J, `mcS` = 1e-6 S, `klx` = 1000 lx.

## 7. Per-type units

Each quantity type accepts exactly one dimension (`identifiers.md` lists it
per type). Saving a sample whose quantity has another dimension raises
`_HKObjectValidationFailureException` (`errors.md` §3). The user's preferred
display units (`preferredUnitsForQuantityTypes:completion:`) depend on the
region; for the simulator's default `en_US` region (level 3):

| Type | Preferred unit |
|---|---|
| step count | `count` |
| body mass | `lb` |
| height | `ft` |
| body temperature | `degF` |
| walking + running distance | `mi` |
| active energy, dietary energy | `Cal` |
| heart rate | `count/min` |
| blood pressure | `mmHg` |

The call fails with code 5 if any of the types was never requested.

## Evidence

| Claim | Level |
|---|---|
| Grammar, prefixes, atoms, canonical strings, conversions, caching, preferred units | 3 (HealthProbe `basic` and `data`, 27.1 and 27.0) |
| Constructor and algebra method names, `HKMetricPrefix` raw values, molar-mass constant name | 4 |
| Formatter bridges | 4 (names only) |
| Factor ordering rule | open (examples only) |
