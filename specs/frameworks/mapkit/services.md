# MapKit spec: search, completion, directions, geocoding — request and response models

Part of `specs/frameworks/mapkit/`. Type and member names are interop facts
(level 1/4, full list in `api-inventory.md`); behavior is level 3 from
`MKProbe -mode search|dir|geo` on iOS 27.1 (and 27.0, `simulator-baseline.md`
§8), with the simulated location at Apple Park (37.3349, −122.0090). Result
*content* comes from Apple's servers and is not reproduced here; only its
shape, counts and rules are.

## 1. Map items (`MKMapItem`)

A map item is a place: a location plus optional descriptive fields.

| Member | Meaning / observed rule |
|---|---|
| `location` (26.0) | `CLLocation` of the place; replaces `placemark.coordinate` |
| `address` (26.0) | `MKAddress` with `fullAddress` (multi-part, comma-separated, may contain the venue name first, e.g. "<venue>, <street>, <city>, <state>  <zip>, <country>"; two spaces between US state and ZIP) and `shortAddress` ("<street>, <city>") |
| `addressRepresentations` (26.0) | derived forms: `cityName`, `cityWithContext` ("City, ST" in the US, "City, Country" elsewhere), `regionName` (country name), `region` (Swift: `Locale.Region`, e.g. "US"), `fullAddress(includingRegion:singleLine:)` |
| `name` | venue name, or the street address for address results, or a feature name ("North Pacific Ocean") |
| `phoneNumber`, `url`, `timeZone` | present for businesses; `timeZone` is present for every land result, a fixed-offset zone ("GMT-0900") for ocean results |
| `pointOfInterestCategory` | one of the `MKPointOfInterestCategory` strings (`interface.md` §11); nil for addresses and physical features |
| `identifier` (18.0) | `MKMapItem.Identifier`; present for businesses, absent for addresses and geocoding results; raw value 17 characters beginning "I" in our samples; `alternateIdentifiers` empty |
| `isCurrentLocation` | YES only for `forCurrentLocation()` |
| `placemark` (deprecated 26.0) | `MKPlacemark` still populated: locality, administrative area (two-letter state in the US), ISO country code, postal code, thoroughfare; `region` is a `CLCircularRegion` |

`MKMapItem(location:address:)` (26.0) creates an item with only a location;
`name` is settable. `forCurrentLocation()` read directly is a placeholder
(name "Unknown Location", coordinate (−180, −180), observed after
`simctl location clear`); as a directions source it is resolved to the
device's current simulated fix at request time (§4.2).

`MKMapItemRequest(mapItemIdentifier:)` resolves an identifier to a map item
(same name as the search result) in ≈0.07 s; an unknown identifier fails with
`MKErrorDomain` code 5. `MKMapItem.Identifier(rawValue:)` accepts any
non-empty string.

## 2. Local search (`MKLocalSearch`)

### 2.1 Request

`MKLocalSearch.Request` defaults: `resultTypes` = 0 (empty set, meaning
"addresses and points of interest"), `pointOfInterestFilter` nil, `region`
all zeros (no region), `regionPriority` `.default` (0), `addressFilter` nil.
Other request kinds: `MKLocalSearch.Request(completion:)` from a completer
result, and `MKLocalPointsOfInterestRequest(center:radius:)` /
`(coordinateRegion:)` (category browsing without a query).

### 2.2 Observed behavior

| Request | Result |
|---|---|
| "coffee", region 5 km around the center | 25 items in ≈0.4–0.8 s; categories cafe, bakery, restaurant; every item has an address and identifier; nearest item ≈0.5 km from the center; `boundingRegion` encloses the results (span ≈0.09° × 0.09°) |
| same with `regionPriority = .required` | 25 items all inside the region; `boundingRegion` shrinks (≈0.05° × 0.07°) |
| "1 Apple Park Way, Cupertino", `resultTypes = .address` | 1 item, no category, no identifier, 6 m from the true point; `boundingRegion` ≈ 1 km square around it |
| "restaurant" + filter including only `.cafe` | 25 items, all category cafe, spread over a larger area (bounding span ≈0.16° × 0.19°) |
| gibberish query | error `MKErrorDomain` 4 (`placemarkNotFound`), userInfo key `MKErrorGEOError` only, ≈0.2 s |
| no query (region only) | error 4, ≈0.05 s |
| "museum" with a Paris region | 25 items in Paris (categories landmark, museum), localized street names, time zone Europe/Paris |
| "coffee", `resultTypes = .physicalFeature` | 4 items **outside the requested region**, near the host's approximate network location (≈3,500 km away), mixing businesses and named natural features with address "United States" only; the region is not honored for this result type |
| POI request, center, radius 1000 m | 43 items in ≈0.15 s, all within 412 m, categories EV charger, landmark, restaurant, store; the same 43 with radius 100 km (the server caps the set) |
| `start` then `cancel` on one search | `isSearching` YES right after `start`, still YES 1 s after `cancel`; the completion handler was not called within 1 s |

Result order is by the server's relevance, not strictly by distance (the
"required" variant reordered the first two items).

### 2.3 Response

`MKLocalSearch.Response`: `mapItems` (array, max 25 observed),
`boundingRegion` (`MKCoordinateRegion` that encloses the items).

## 3. Completion (`MKLocalSearchCompleter`)

Defaults: `resultTypes` 0, `region` = whole world (center 0,0, span 180 ×
360), `regionPriority` 0, `pointOfInterestFilter` nil, `addressFilter` nil,
`isSearching` NO. Setting `queryFragment` sets `isSearching` YES at once;
the delegate's `completerDidUpdateResults` arrives after ≈0.06–0.13 s
(0.3–0.7 s under typing), with `isSearching` NO again (YES when a newer
fragment is pending).

| Fragment | Results |
|---|---|
| "App" | 12 results; title highlight ranges mark the matching prefix (location 0, length 3); query suggestions have subtitle "Search Nearby" |
| "Apple Park" | 15; highlights per matching word plus the whole match (`0+5`, `6+4`, `0+10`); one suggestion row with subtitle "No Results Nearby"; a result can have an empty subtitle |
| "coffee" | 9: category queries first ("Coffee Shops", "Coffee"), then businesses; highlight may be inside the title (`6+6` for "… Coffee") or absent |
| "" (empty) | **error** delegate call, `MKErrorDomain` 5 |
| gibberish | update with 0 results (no error) |
| `resultTypes = .address`, "1 Infinite" | 2 results, street and city rows only; with default types 3 (includes a POI) |
| `resultTypes = .query`, "pizza near" | 1 query suggestion "Pizza" / "Search Nearby" |
| typing "s"…"stanf" 0.1 s apart | 3 updates (fragments "s", "stan", "stanf"), i.e. requests are throttled/coalesced; the last update is for the final fragment |

`MKLocalSearch(request: .init(completion:))` for a POI completion returns
exactly 1 item (the completed place) in ≈0.07 s.

`MKLocalSearchCompletion`: `title`, `subtitle`, `titleHighlightRanges`,
`subtitleHighlightRanges` (array of `NSValue` ranges in UTF-16 units).

## 4. Directions (`MKDirections`)

### 4.1 Request

`MKDirections.Request` defaults: `transportType` = `.any`
(0x0FFFFFFF), `requestsAlternateRoutes` NO, `departureDate`/`arrivalDate`
nil, `tollPreference` and `highwayPreference` 0 (`.any`), `source` and
`destination` nil. Source nil means the current location (the server-side
"Route information is not available at this moment" error appears when both
are nil, §7).

### 4.2 Observed behavior (Apple Park → Stanford, ≈17.5 km apart)

| Variant | Result |
|---|---|
| automobile | 1 route in ≈0.6 s: distance 25,912 m, expected travel time ≈1,750 s, 17 steps, 386 polyline points, 1 advisory notice, `hasHighways` YES, `hasTolls` NO; the route starts at the nearest road point (≈200 m from the requested source), ends ≈10 m from the destination |
| automobile + alternates | 3 routes, first identical to the single-route answer; others longer in time |
| walking | 1 route, 19,708 m, ≈20,981 s (≈0.94 m/s), 35 steps, `transportType` walking |
| cycling | 1 route, 19,739 m, ≈4,187 s; route `transportType` reported as 1 (automobile) while steps mix walking (2) and automobile (1); the ETA response reports `transportType` 0 |
| transit | `calculate` fails **immediately (0.000 s, no network)** with code 5 and empty userInfo; `calculateETA` succeeds (`transportType` 4, departure ≈6 min in the future) |
| `.any` | like automobile |
| avoid tolls and highways (to San Francisco) | 1 route without highways (`hasHighways` NO), 1,343 points; the ETA for the same request reports a different, shorter distance (it ignores the preferences) |
| departure + 1 day | same geometry, different travel time and advisories; ETA `expectedDepartureDate` = request date |
| San Francisco → Honolulu | `calculate`: code 2 (`serverFailure`) "Directions Not Available", reason "Directions are not available between these locations."; `calculateETA`: code 4 with reason "A route could not be determined between these locations." |
| source = destination | 1 route, distance 0, time 0, name "", 2 walking steps, 2 identical points |
| source = `forCurrentLocation()` | same as the explicit coordinate (uses the simulated fix) |
| empty request | code 1 (`unknown`), reason "Route information is not available at this moment." |

Route names are the main road's name. The first step of a driving route has
distance 0, one point and an **empty** instruction; walking routes start
with a non-empty instruction. Step distances sum to the route distance
(±0.5 m rounding). Distances and times are whole numbers.

### 4.3 Response

`MKDirections.Response`: `source`, `destination` (map items, with the
requested coordinates), `routes`. `MKRoute`: `name`, `advisoryNotices`,
`distance` (m), `expectedTravelTime` (s), `transportType`, `polyline`
(`MKPolyline` in map points), `steps`, `hasTolls` (16.0), `hasHighways`
(16.0). `MKRoute.Step`: `polyline`, `instructions`, `notice`, `distance`,
`transportType`. `MKDirections.ETAResponse`: `source`, `destination`,
`expectedTravelTime`, `distance`, `expectedArrivalDate`,
`expectedDepartureDate`, `transportType`; arrival − departure =
travel time.

`isCalculating` was NO immediately after `calculate(completionHandler:)`; a
`cancel` right after did not suppress the completion, which arrived ≈2.4 s
later with no error.

## 5. Geocoding

### 5.1 `CLGeocoder` (deprecated in 26.0, still functional)

| Call | Result |
|---|---|
| forward "1 Infinite Loop, Cupertino, CA" | 1 placemark, ≈0.14 s: name "1 Infinite Loop", thoroughfare/subThoroughfare split, sub-administrative area (county), postal code, time zone, `region` = `CLCircularRegion` (radius ≈280 m), areas of interest list |
| reverse at Apple Park | 1 placemark named for the venue, ≈0.08 s, region radius ≈71 m |
| reverse in the open ocean (0, −140) | 1 placemark: name and `ocean` "North Pacific Ocean", no country, time zone "GMT-0900", region centered on (23.28, 0.0) with radius ≈18,534 km |
| forward gibberish | `kCLErrorDomain` 8 (`geocodeFoundNoResult`) |
| reverse with `preferredLocale` de_DE (Berlin) | localized country "Deutschland", sub-locality filled |
| two requests on one geocoder | the first completes; the second's completion was **not** called within 3 s (no error either) |
| 12 sequential reverse lookups | all succeed, ≈0.08 s each (no throttling at this rate) |

### 5.2 `MKGeocodingRequest` / `MKReverseGeocodingRequest` (26.0)

Initializers are failable: an empty address string and an invalid
coordinate both give nil. `getMapItems` / Swift `mapItems` return arrays of
map items (1 in every success we saw) without category or identifier:

| Call | Result |
|---|---|
| forward "1 Infinite Loop, Cupertino, CA" | same point as `CLGeocoder`; address full/short as §1 |
| forward "Apple Park" (no region) | 1 result **near the host's network location**, not the famous venue: without a region the server biases to the device's network position |
| reverse at Apple Park | name "Apple Park", full address prefixed with the venue name |
| reverse in the ocean | name "North Pacific Ocean", coordinate snapped to (21.9466, −140.1711), region code nil, `cityWithContext` = the ocean name, `cityName` empty |
| forward gibberish | `MKErrorDomain` 4 |
| 12 sequential reverse requests | all succeed in 0.95 s total |

## 6. Look Around requests

See `interface.md` §9 for the model; behavior in `simulator-baseline.md` §4.6.

## 7. Errors

`MKErrorDomain` (`"MKErrorDomain"`) codes, with the userInfo keys observed:

| Code | Name | Observed for | userInfo keys |
|---|---|---|---|
| 1 | `unknown` | directions with neither source nor destination | `MKDirectionsErrorCode`, `MKErrorGEOError`, `MKErrorGEOErrorUserInfo`, `NSLocalizedDescription`, `NSLocalizedFailureReason` |
| 2 | `serverFailure` | directions between unconnected places | the above plus `MKErrorDirectionsErrorInfoKey`, `MKErrorGEOTransitIncidentKey` |
| 3 | `loadingThrottled` | (not reproduced) | — |
| 4 | `placemarkNotFound` | search with no results or no query; geocoding with no results; ETA with no route | `MKErrorGEOError` (search, geocoding); directions keys (ETA) |
| 5 | `directionsNotFound` | transit `calculate` (client-side); completer with an empty fragment; unknown map item identifier | none (transit) or `MKErrorGEOError` |
| 6 | `decodingFailed` | (GeoJSON decoding, not exercised) | — |

Directions errors carry `localizedDescription` "Directions Not Available"
and a failure reason sentence; search and geocoding errors carry only the
generic description. `kCLErrorDomain` 8 is `CLGeocoder`'s "no result".
Errors with an underlying GEO error expose it under `MKErrorGEOError` (an
`NSError` from the GeoServices domain; its codes are not part of the public
contract).

## Evidence

| Claim | Level |
|---|---|
| Type/member names, enum values, defaults' types | 4 |
| Purpose of each API | 1 |
| Every behavior, count, timing, default value and error code in §§1–7 | 3 (`MKProbe`, `research/notes/mapkit-simulator-observations-2026-10-19.md`) |
| Error code names | 4 (enum case names) |
