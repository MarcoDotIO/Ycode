# MapKit spec: geometry, projection, viewport and camera (golden values)

Part of `specs/frameworks/mapkit/`. Every number here was printed by our probe
`MKProbe -mode math` (and `-mode snap`, `-mode suicam`) on the iOS 27.1
simulator (iPhone Duo, 466 × 678 pt, scale 3, safe-area insets top 0,
left 0, bottom 34, right 84) on 2026-10-19 and re-run on 2026-10-20 with
identical digits. The formulas are **our own fits** to those numbers; they
are written so that a clean implementation can reproduce the digits, and
each says how well it fits. Where we found no closed form, the table is the
contract.

Notation: φ latitude, λ longitude in degrees; W = 2^28 = 268,435,456; a
region is printed as center (φ, λ) and span (Δφ, Δλ) — latitude delta first.

## 1. Map points (Web Mercator, 2^28 square)

### 1.1 Forward projection

x = (λ + 180) / 360 · W
y = (1/2 − ln((1 + sin φ) / (1 − sin φ)) / (4π)) · W

with φ first clamped to [−85, +85] (not to ±85.0511). This reproduces every
printed coordinate to the last printed digit (3 decimals).

| Input (φ, λ) | x | y | Coordinate back from the point |
|---|---|---|---|
| (0, 0) | 134217728.000 | 134217728.000 | (0, 0) |
| (37.3349, −122.009) | 43241223.691 | 104169776.187 | exact |
| (51.5074, −0.1278) | 134122433.413 | 89261640.295 | exact |
| (−33.8568, 151.2153) | 246972028.027 | 161075261.481 | exact |
| (85, 180) | 268435456.000 | 439674.402 | (85, 180) |
| (−85, −180) | 0.000 | 267995781.598 | (−85, −180) |
| (85.051129, 0), (89, 0), (90, 0) | 134217728.000 | 439674.402 | **(85, 0)** — clamped |
| (−90, 0) | 134217728.000 | 267995781.598 | (−85, 0) |
| (0, 180) | 268435456.000 | 134217728.000 | (0, 180) |
| (0, −180) | 0.000 | 134217728.000 | (0, −180) |
| (0, 190), (100, 0) — invalid coordinates | −1.000 | −1.000 | (85.051128895, 179.998658895…) i.e. the inverse of (−1, −1) |

Invariants: a coordinate is valid when |φ| ≤ 90 and |λ| ≤ 180; an invalid
one maps to the sentinel point (−1, −1). Latitudes beyond ±85 are clamped,
not rejected.

### 1.2 Inverse projection

λ = x / W · 360 − 180; φ = the Mercator inverse of y **without** clamping:

| Map point | Coordinate |
|---|---|
| (0, 0) | (85.051128780, −180) |
| (W/2, W/2) | (0, 0) |
| (W, W) | (−85.051128780, 180) |
| (−1000, −1000) | (85.051244471, 179.998658895) — x below 0 wraps to the east end |
| (W + 10,000,000, 0) | (85.051128780, −166.588954926) — x beyond W wraps west |

So x wraps modulo W (λ is normalized into (−180, 180]) and y is not clamped.

## 2. Scale and distance

### 2.1 Meters per map point

`MKMetersPerMapPointAtLatitude` / `MKMapPointsPerMeterAtLatitude` (the
reciprocal). No exact closed form found. For |φ| ≤ 60° it agrees to
≈1·10⁻⁵ relative with 2π·M(φ)·cos φ / W, where M is the WGS-84 meridional
radius of curvature a(1 − e²)/(1 − e² sin² φ)^{3/2} (a = 6,378,137 m,
e² = 0.00669438); it drifts lower towards the poles. The table is the
contract (12 significant decimals printed):

| φ | m per map point | φ | m per map point |
|---|---|---|---|
| 0 | 0.148289773338 | 44 | 0.107187145792 |
| 2 | 0.148201247086 | 46 | 0.103545456826 |
| 4 | 0.147935756532 | 48 | 0.099774889909 |
| 6 | 0.147493566379 | 50 | 0.095879792041 |
| 8 | 0.146875118136 | 52 | 0.091864693245 |
| 10 | 0.146081030604 | 54 | 0.087734303255 |
| 12 | 0.145112100559 | 56 | 0.083493507541 |
| 14 | 0.143969303589 | 58 | 0.079147362637 |
| 16 | 0.142653795081 | 60 | 0.074701090708 |
| 18 | 0.141166911339 | 62 | 0.070160073279 |
| 20 | 0.139510170788 | 64 | 0.065529844015 |
| 22 | 0.137685275255 | 66 | 0.060816080374 |
| 24 | 0.135694111272 | 68 | 0.056024593825 |
| 26 | 0.133538751387 | 70 | 0.051161318090 |
| 28 | 0.131221455419 | 72 | 0.046232294354 |
| 30 | 0.128744671638 | 74 | 0.041243651361 |
| 32 | 0.126111037815 | 76 | 0.036201575844 |
| 34 | 0.123323382097 | 78 | 0.031112262685 |
| 36 | 0.120384723665 | 80 | 0.025981817045 |
| 37.3349 | 0.118340868336 | 82 | 0.020816024896 |
| 38 | 0.117298273132 | 84 | 0.015619683436 |
| 40 | 0.114067432629 | 84.5 | 0.014316135906 |
| 42 | 0.110695795531 | 84.9 | 0.023034357291 |
| −37.3349 | 0.118340868336 (even function) | 84.99 | 0.026877494044 |
| −60 | 0.074701090708 | 85.01 | 0.027923075327 |

**Polar anomalies (reproduce them):** 85.0 → 0.027389837; 85.5, 86, 88 and
89 → **+∞** (points per meter 0); 89.9 → 0.254037212975; 89.99 →
0.254037220719; 90 → 0.254037221. The function is not monotonic above 84.5°.

### 2.2 Distance between map points

`MKMetersBetweenMapPoints(a, b)` (Swift `a.distance(to: b)`) is a great-circle
distance on a sphere whose radius depends on the latitude of the **first**
point (fit exact to 9 significant digits on 16 pairs):

d = 2·R₁·asin(√(sin²(Δφ/2) + cos φ₁ cos φ₂ sin²(Δλ/2))), R₁ = 6,378,160 − 21,000·|sin φ₁| m

(the coefficient 21,000 fits as 0.0032924856 × 6,378,160).

| From → to | Meters |
|---|---|
| (0,0) → (0,1) and (0,0) → (1,0) | 111319.892219 |
| (0,0) → (0,10) and (0,0) → (10,0) | 1113198.922190 |
| (0,0) → (0,90) | 10018790.299710 |
| (30,0) → (30,1) | 96246.841756 |
| (30,0) → (31,0) | 111136.632648 |
| (60,0) → (60,1) | 55500.710330 |
| (60,0) → (61,0) | 111002.477330 |
| (60,0) → (60,0.01) | 555.012386 |
| (37.3349,−122.009) → (37.3349,−122.0) | 795.007588 |
| (37.3349,−122.009) → (37.3449,−122.009) | 1110.976083 |
| (−45,170) → (−45,−170) (across the 180th meridian, short way) | 1566627.489026 |
| (0,0) → (45,45) | 6679193.533140 |
| (80,0) → (80,1) | 19267.580777 |
| (10,10) → (20,30) | 2416574.293928 |
| Apple Park (37.3349,−122.009) → Stanford (37.4275,−122.1697) | 17524.0828 (Core Location: 17555.1516) |
| San Francisco (37.7749,−122.4194) → Tokyo (35.6762,139.6503) | 8267206.947 (Core Location: 8293443.174) |

`CLLocation.distance(from:)` is a different (ellipsoidal) function; it is
Core Location's and is not specified here.

## 3. Regions

### 3.1 Region from meters (`MKCoordinateRegionMakeWithDistance`)

| Center | Meters (lat, lon) | Span (Δφ, Δλ) |
|---|---|---|
| (0, 0) | 1000, 1000 | (0.0090437, 0.0089832) |
| (37.3349, −122.009) | 1000, 1000 | (0.0090103, 0.0112842) |
| (60, 0) | 1000, 1000 | (0.0089757, 0.0179212) |
| (37.3349, −122.009) | 100000, 50000 | (0.9010316, 0.5642084) |
| (0, 0) | 40,000,000 both | (361.7478010, 359.3262195) — not clamped |
| (89, 0) | 1000, 1000 | (0.0089531, 0.5129979) |

### 3.2 Region from a map rect (`MKCoordinateRegionForMapRect`)

| Map rect (x, y, w, h) | Region |
|---|---|
| (1e8, 1e8, 1e6, 1e6) | center (41.145020, −45.218997), span (1.0099111, 1.3411045) |
| the world (0, 0, W, W) | center (0, 0), span (170.1022576, 360) |
| (0, 0, W/2, W/2) | center (66.513260, −90), span (85.0511288, 180) |
| (43241223.691, 104169776.187, 10000, 10000) | center (37.329568, −122.002294), span (0.0106639, 0.0134110) |

Rule: Δλ = w/W·360; Δφ = φ(top) − φ(bottom) using the unclamped inverse
(§1.2); center = (φ of the rect's vertical **mid-point in map points**,
λ of its horizontal mid-point) — so the center latitude is not the mean of
the edge latitudes.

## 4. Map rect algebra

Rects (x, y, w, h): r1 = (0, 0, 100, 100), r2 = (50, 50, 100, 100).

| Operation | Result |
|---|---|
| union(r1, r2) | (0, 0, 150, 150) |
| intersection(r1, r2) | (50, 50, 50, 50) |
| inset r1 by 10 | (10, 10, 80, 80) |
| offset r1 by (5, −5) | (5, −5, 100, 100) |
| r1 intersects r2 | YES |
| r1 contains point (50, 50); (100, 100) | YES; **YES** (max edge inclusive) |
| r1 contains rect (10, 10, 20, 20) | YES |
| intersection of disjoint rects | the null rect (x = y = +∞, w = h = 0), `isNull` YES |
| union(null, r1) | r1 |
| (0, 0, 0, 0) `isEmpty` | YES |
| min/mid/max of r2 | minX 50, midX 100, maxX 150 (same for y) |
| world rect | (0, 0, W, W), `isEmpty` NO |
| rect (W − 100, 1000, 200, 10) `spans180thMeridian` | YES; the world rect: NO |
| `remainder` of that rect | (0, 1000, 100, 10): the part beyond x = W, shifted by −W; remainder of the world rect: null |

## 5. Overlay shapes

| Shape | Result |
|---|---|
| polyline Apple Park → Stanford → SF downtown (37.7946, −122.3999) | 3 points; bounding (42949747.525, 103737337.229, 291476.166, 432438.958); `coordinate` = center of the bounding rect (37.565105, −122.204450); `locations(at:)` for indexes 0 and 2 = 0 and 1 (fraction of distance); location at index 1 = 0.277265 |
| circle r = 1000 m at Apple Park | bounding (43232773.525, 104161326.021, 16900.332, 16900.332): side = 2·r·(map points per meter at the center latitude) = 2000 × 8.450166 |
| circle r = 0 | zero-size rect at the center point |
| circle r = 100 km | side 1690033.230 (same linear rule) |
| circle from map rect (1000, 1000, 200, 100) (near the world's top-left corner) | center (85.051007301, −179.998524785) = the rect's center; radius 1.283697 m; bounding (1057.715, 439632.117, 84.571, 84.571) — the y origin lands at the clamped ±85° band and the side is 2·r in map points at that latitude, so the circle is **not** the rect's inscribed circle there |
| polygon (Apple Park, Stanford, (37.3, −122.2)) | bounding (43098803.769, 104082881.680, 142419.922, 119616.362); `coordinate` (37.363777, −122.104500); `interiorPolygons` nil |
| polyline across the 180th meridian ((0, 170) → (0, −170)) | points (260978915.556, W/2) and (275891996.444, W/2): the second point is **unwrapped** to x > W so the line takes the short way; bounding width 14913080.889 |
| multi-polyline of the two above | bounding = union (42949747.525, 103737337.229, 232942248.919, 30480390.771) |
| geodesic polyline SF → Tokyo | 8295 points; bounding (−30086916.997, 92491749.259, 73022124.269, 13216852.572) — negative x, spans the 180th meridian; middle point (48.6969, −172.2847) |
| geodesic Apple Park → Stanford | 19 points |
| geodesic across the 180th meridian ((0, 170) → (0, −170)) | 2228 points, first x 260978915.556, last x 275891996.444 (unwrapped), height 0 |

Geodesic densification: the point count grows with length (≈1 point per
1 km for SF–Tokyo, 19 for 17.5 km, 2228 for 2,226 km along the equator) —
roughly one point per kilometer plus end points; the exact rule is open
(R2 must match the three counts).

## 6. Viewport of `MKMapView`

The map's **viewport is the view's safe-area rectangle** (here 382 × 644 pt
at origin (0, 0)). Every fitting rule below works on it; the camera
distance uses the full view height.

### 6.1 Fitting a region (`setRegion`, `regionThatFits`)

The requested span is enlarged in one direction so that its map-point
aspect equals the viewport's: the dimension that already fills is kept.

| Requested span (Δφ, Δλ) at center | Fitted (and applied) span | Visible map rect | Camera distance |
|---|---|---|---|
| (0.05, 0.05) at Apple Park | (0.0670219, 0.0500000) | (43222582.340, 104138349.408, 37282.702, 62853.561) | 14612.550 |
| (0.0090103, 0.0112842) | (0.0151257, 0.0112842) | w 8414.086, h 14185.003 | 3297.810 |
| (1, 1) at (0, 0) | (1.6858031, 1.0) | w 745654.041, h 1257071.217 | 366211.908 |
| (0.00001, 0.00001) | fits (0.0001857, 0.0001385); **applied (0.0003434, 0.0002562)** at center (37.334904, −122.009013) | w 191, h 322 (0.5 map point per screen point: maximum zoom) | 74.860 |
| (170, 360) | fits (140.8483888, 134.2968750); applied (124.1599845, 108.6972649) | w 81050555.170, h 136640203.549 | 31766884.955 (maximum) |
| (0.01, 1.0) | (1.3404247, 1.0) | w 745654.041 | 292251.004 |

Visible map rect height / width = 644 / 382 = 1.68586 (map points are
square). Map points per screen point = 37282.702 / 382 = 97.5987.

Inset-free views (off-screen map views of the given size, `setRegion`
with span (0.01, 0.01) at Apple Park):

| View size | Region after | Distance |
|---|---|---|
| 200 × 200 | (0.0100000, 0.0125770) | 2070.931 |
| 200 × 400 | (0.0159021, 0.0100000) | 3293.212 |
| 300 × 150 | (0.0100000, 0.0251539) | 2070.931 |
| 100 × 300 | (0.0238531, 0.0100000) | 4939.818 |
| 300 × 300 | (0.0100000, 0.0125770) | 2070.931 |

### 6.2 Camera distance from the viewport

distance = (H/2 · s · m(φc)) / tan 15°, with H the **full** view height in
points, s the map points per screen point and m the meters per map point
at the center latitude (§2.1): a 30° vertical field of view over the whole
view. Checks: 678/2 × 97.5987 × 0.118341 / 0.267949 = 14612.6 (printed
14612.550); with `setCamera` distance 1000 the visible width is 2551.417
map points on 382 pt (6.679 per pt) and 678/2 × 6.679 × 0.118341 / tan 15° =
1000.0.

### 6.3 Other viewport methods (466 × 678 view, insets (0, 0, 34, 84))

| Call | Result |
|---|---|
| default state before any change, on screen | region center (38.893879, −101.308311), span (64.3365407, 50.2305529); camera center (37.132840, −95.785580) distance 14718826.309; off screen (no window): region span (97.6217252, 61.2760150), distance 21893099.094 |
| convert Apple Park (the center) → view point | (191, 322) = the safe-area center |
| convert view point (0, 0) → coordinate | (37.3684035, −122.0340000) |
| convert (466, 678) → coordinate | (37.2978415, −121.9730052) — outside the safe area, extrapolated linearly in x and by Mercator in y |
| convert (191, 0) → coordinate | (37.3684035, −122.0035026) |
| convert a region → view rect | (152.80, 273.96, 76.40, 96.09); and back: center (37.363202, −122.027455), span (0.0104032, 0.0130890) |
| `mapRectThatFits` (43241223.691, 104169776.187, 20000, 20000) | (43241223.691, 104162917.548, 20000, 33717.277): width kept, height × 1.68586, centered |
| same with edge padding 20 on all sides | (43240054.101, 104160945.778, 22339.181, 37660.819): fit into the inner 342 × 604 pt, then expand to the full safe area |
| `setVisibleMapRect` with that 20000 × 20000 rect | visible (43241223.691, 104162917.549, 20000, 33717.277); region center (37.324236, −121.995589), span (0.0359584, 0.0268221); distance 7839.881 |
| same with top padding 100 | visible y moves up by 2617.8 map points (center (37.327028, −121.995589)) |
| heading 90° with the 0.05 region | region span (0.0397552, 0.0842932); visible rect (43209796.910, 104151134.836, 62853.561, 37282.702) — width and height swap; a point 0.01° north of the center appears at (94.906, 322): north is to the **left** |

## 7. Camera (`MKMapCamera`)

### 7.1 Value relations (no view involved)

altitude = distance · cos(pitch). Setting `altitude` on a pitched camera
keeps the pitch and sets distance = altitude / cos(pitch). Heading is stored
as given (400 stays 400) until a map view normalizes it.

| Constructor / change | center | distance | altitude | pitch | heading |
|---|---|---|---|---|---|
| `init()` | (0, 0) | 0 | 0 | 0 | 0 |
| looking at Apple Park, 1000 m, pitch 0, heading 0 | AP | 1000 | 1000 | 0 | 0 |
| same, pitch 45, heading 90 | AP | 1000 | 707.107 | 45 | 90 |
| same, pitch 60, heading −30 | AP | 1000 | 500.000 | 60 | −30 |
| same, pitch 89, heading 400 | AP | 1000 | 17.452 | 89 | 400 |
| from an eye 0.01° south, eye altitude 1000 | AP | 1493.901 | 1000 | 47.980 | 0 |
| from an eye at the center, altitude 500 | AP | 500 | 500 | 0 | 0 |
| from an eye 0.01° west, altitude 300 | AP | 935.599 | 300 | 71.298 | 90 |
| pitch-0 camera, set altitude 2000 | AP | 2000 | 2000 | 0 | 0 |
| then set pitch 60 | AP | 4000 | 2000 | 60 | 0 |

(From-eye: ground distance g from the eye to the center by the distance of
§2.2-like geometry; pitch = atan(g / altitude); distance = √(g² + altitude²);
heading = the bearing from the eye to the center. 0.01° of latitude is
≈1111 m: atan(1111/1000) = 47.98°.)

### 7.2 Camera on a map view (466 × 678, insets as above)

| `setCamera` request (distance, pitch, heading) | Applied |
|---|---|
| 1000, 0, 0 | 1000, 0, 0; region span (0.0045866, 0.0034217) |
| 1000, 60, 45 | 1000, 60, 45 (altitude 500); region span (0.0112571, 0.0135410); visible (43238453.768, 104162115.092, 10096.903, 10557.328) |
| 300, **80**, 0 | 300, **70**, 0 (altitude 102.606) — pitch limited |
| **30**, 0, 0 | **74.860**, 0, 0 — minimum distance (0.5 map point per point); center snapped to (37.334905, −122.009017) |
| 1,000,000,000, 0, 0 | **31766884.955** — maximum distance |
| 100,000, **60**, 0 | 100,000, **35**, heading normalized to 360 |
| 5,000,000, 45, 0 | 5,000,000, **35** |
| zoom range 2000…4000 then distance 1000 | **1607.297** |
| zoom range 2000…4000 then distance 9000 | **3214.594** |

Pitch limit: ≥ 60° at 1 km, 70° at 300 m, 35° at 100 km and beyond (the
curve in between is open; R3 needs more samples). Zoom range: the clamped
distances are 0.80365 × the range limits on this view (the range is
evaluated on a different distance measure than `camera.centerCoordinateDistance`;
the ratio is a golden value for this view size).

### 7.3 Zoom range and boundary objects

| Object | Result |
|---|---|
| `CameraZoomRange(min 500, max 5000)` | min 500, max 5000; `MKMapCameraZoomDefault` = −1 |
| min > max | nil (failable) |
| min only | min 500, max −1 |
| `CameraBoundary(coordinateRegion:)` 2 km region at Apple Park | stores region span (0.0180206, 0.0225683) and map rect (43232809.606, 104161326.247, 16828.172, 16899.868) |
| `CameraBoundary(mapRect:)` 5000 × 5000 at the AP point | region center (37.332234, −122.005647), span (0.0053318, 0.0067055) |
| map view with the 2 km boundary, `setCenter(Stanford)` | center clamped to (37.343910, −122.020284) |

## 8. Overlay and annotation placement

- Renderer space: `point(for:)` of Apple Park for a polyline overlay whose
  bounding origin is (43236749.767, 104164149.122) = (4473.924, 5627.065),
  i.e. map point − origin; `rect(for: boundingMapRect)` = (0, 0, 5965.23,
  11253.68); `path.boundingBox` the same; circle (r 200 m) rect
  (0, 0, 3379.93, 3379.93).
- Marker view frame: 31.33 × 34.94 pt; with `centerOffset` (0, −17.471) the
  frame's bottom-center is on the annotation's point. A marker at the map
  center (191, 322) has origin (175.33, 287.06) after the first layout and
  (175.33, 287.00) once settled (sub-point snapping).

## 9. Snapshots

Options at 300 × 200 pt for the region center Apple Park span
(0.02, 0.02) (latitude-first; the probe sets `region`):

| Case | `point(for:)` |
|---|---|
| center (37.3349, −122.0090) | (150.000, 100.000) |
| (37.3449, −122.0190) | (70.490, −0.007) |
| (37.3249, −121.9990) | (229.510, 199.993) |

The snapshot **aspect-fits** the requested region into the image, like the
map view (§6.1) but with no safe area: the dimension that fills is kept and
the other is extended, centered. For the 0.02 × 0.02 region on 300 × 200,
latitude fills the height (0.01° above the center is at y ≈ 0) and the
0.02° of longitude covers 159.02 of the 300 points. With span
(0.02 lat, 0.1 lon) on 300 × 300 ("aspect mismatch"), longitude fills the
width (center + 0.05° lon at x = 300) and 0.01° of latitude is 37.73 pt
(y = 112.267). A `mapRect` snapshot (300 × 300) of the AP-origin
10000 × 10000 rect puts its origin at (0, 0) and its center (37.3296,
−122.0023) at (150, 150). A camera snapshot (400 × 300, center SF
downtown) puts the camera center at the image center. A 6000 × 6000 pt
snapshot fails at once with `MKErrorDomain` 1 and a userInfo key `Reason`;
a zero size raises when set (`interface.md` §8).

Option defaults: size 256 × 256; region center (37.132840, −95.785580), span
(24.0982720, 61.2760150); map rect (39949468.667, 93052810.264, 45690708.412,
22612410.253); camera distance 10116479.440. Setting the 0.02 region updates
the map rect to (43233767.151, 104160398.115, 14913.081, 18756.134) and
camera distance to 4141.862.

## 10. SwiftUI `Map` framing

A full-screen `Map` (466 × 678, the same safe area) with content markers at
Apple Park and nearby, initial position `.automatic`:

| Position | First `onMapCameraChange(.onEnd)` context |
|---|---|
| `.automatic` (framing the probe's content) | camera center (37.335246, −122.010500), distance 3469.020, pitch 0, heading 0; region span (0.0167510, 0.0144802); rect (43234706.591, 104161596.938, 10797.239, 15709.288); `positionedByUser` NO; reported twice at start |
| `.camera(MapCamera(center AP, distance 1000))` | same camera; region span (0.0048287, 0.0041741); rect w 3112.461 h 4528.430 |
| `.camera(center SF downtown, distance 1000, heading 45, pitch 60)` | applied as given; region span (0.0116932, 0.0147981); rect 11034.281 square |
| `.region(AP, 0.05 × 0.05)` | distance 11978.528, region span (0.0578413, 0.0500000); rect (43222582.340, 104142654.221, 37282.702, 54243.932) |
| `.rect(AP point, 10000 × 10000)` | center (37.329568, −122.002294), distance 3213.117, rect w 10000 h 14549.356 |
| `.userLocation(fallback: .camera(Stanford…))` | first the fallback camera (Stanford, 5406.765), then ≈30 ms later the user location (AP, distance 4791.065) |
| back to `.automatic` | identical to the first row |

Note the SwiftUI map frames with a different aspect than the UIKit view
(rect h / w = 1.4549 for `.region`, vs 1.68586 in §6.1): the SwiftUI map's
viewport differs (it ignores the right inset or uses another safe area);
the exact rule is open. `MapProxy.convert(AP, to: .local)` = (281.273,
353.010) under the automatic position; local (0, 0) → (37.3436212,
−122.0177401). An animated camera change produced 83 `.continuous`
callbacks.

## 11. Distance formatter (`MKDistanceFormatter`)

Default units, default style, by locale:

| Meters | en_US | en_GB | de_DE / fr_FR | ja_JP |
|---|---|---|---|---|
| 0 | 0 feet | 0 yards | 0 m | 0 m |
| 10 | 30 feet | 10 yards | 10 m | 10 m |
| 99 | 300 feet | 110 yards | 100 m | 100 m |
| 100 | 350 feet | 110 yards | 100 m | 100 m |
| 160 | 500 feet | 170 yards | 150 m | 150 m |
| 805 | 0.5 miles | 0.5 miles | 800 m | 800 m |
| 1000 | 0.6 miles | 0.6 miles | 1 km | 1 km |
| 1609.344 | 1.0 miles | 1 mile | 1,6 km | 1.6 km |
| 15000 | 9.3 miles | 9.3 miles | 15 km | 15 km |
| 123456 | 77 miles | 77 miles | 123 km | 123 km |

en_US with explicit units and styles (10, 100, 1000, 1609.344, 15000 m):

| Units / style | Strings |
|---|---|
| metric default | 10 m, 100 m, 1.0 km, 1.6 km, 15 km |
| metric abbreviated | same as default |
| metric full | 10 meters, 100 meters, 1.0 kilometers, 1.6 kilometers, 15 kilometers |
| imperial default / full | 30 feet, 350 feet, 0.6 miles, 1.0 miles, 9.3 miles |
| imperial abbreviated | 30 ft, 350 ft, 0.6 mi, 1.0 mi, 9.3 mi |
| imperial-with-yards default / full | 10 yards, 110 yards, 0.6 miles, 1.0 miles, 9.3 miles |
| imperial-with-yards abbreviated | 10 yd, 110 yd, 0.6 mi, 1.0 mi, 9.3 mi |

Parsing (`distance(from:)`): "5 km" 5000; "3 mi" 4828.032; "100 m" 100;
"250 ft" 76.2; "1.5 miles" 2414.016; "10 yards" 9.144; "abc" and "12"
(no unit) −1.

Observed rounding rules (ours): feet are rounded to "nice" steps (10 m →
32.8 ft → 30; 100 m → 328 ft → 350; 160 m → 525 → 500); yards to 10s;
miles to one decimal below 10 and integers above; metric to 10 m below
1 km (99 → 100, 160 → 150: step 50 above 100 m), one decimal km below
10 km in en_US but integer km in de/fr/ja ("1 km", "1,6 km").

## Evidence

| Claim | Level |
|---|---|
| Function and type names (`MKMapPoint`, `MKMetersPerMapPointAtLatitude`, …) | 4 |
| Every printed number and string in §§1–11 | 3 (`MKProbe -mode math`, `snap`, `suicam`, iOS 27.1, two runs; `snap` also on iOS 27.0 with identical numbers) |
| The formulas of §1.1, §2.2 and §6.2 | 3 (our fits to the level-3 numbers; checked in Python against every row) |
| WGS-84 constants used for comparison in §2.1 | 1 (public geodesy) |
