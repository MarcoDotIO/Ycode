# String Catalog editor

Ycode module: `YcodeUI` (`StringCatalog`, `OrderedJSON`,
`StringCatalogEditorController`). Selecting a `.xcstrings` file opens it
(file type `text.json.xcstrings` when added to a project).

## Format (from Apple's public description)

A JSON object: `sourceLanguage` (a language code), `strings` (an object
keyed by the string key), `version` (`"1.0"`). Each entry may have:

- `comment` (string), `extractionState` (`manual`, `stale`, …),
  `shouldTranslate` (`false` = don't translate);
- `localizations`: by language code, either `stringUnit` (`state`,
  `value`) or `variations` (`plural` → `zero`/`one`/`two`/`few`/`many`/
  `other`, `device` → `iphone`/`mac`/…, each holding a `stringUnit`).

`state` values: `translated`, `needs_review`, `new`, `stale`.

## Layout written

Two-space indentation, `"key" : value` separators, one member per line,
empty objects and arrays as `{`, an empty line, then `}` at the
container's indentation. Slashes and non-ASCII characters are not escaped;
`"`, `\`, and control characters are. Object members keep the order they
were read in; members Ycode adds are inserted in code-unit order (the
order catalogs are written in). Numbers keep their spelling. A final
newline is kept if the file had one.

Invariant (tested): reading and writing an untouched catalog gives the
same bytes; adding a translation and then removing it gives the original
bytes back.

## Editor

- Sidebar: the languages: the source language first, marked "(Source)",
  then the other languages that have a localization or were added, by
  code, each with its percentage translated (keys marked don't translate
  are left out; plural/device variations count as translated). The + pull-down
  adds a language from a fixed list of common codes; a language with no
  strings yet is not written to the file.
- Table: Key, Default Localization (the source `stringUnit` value, else the
  key), Comment (editable), the selected language's translation (editable;
  hidden for the source language), State: Translated, Needs Review, New
  (no unit), Stale (`extractionState = stale`), Don't Translate, Varies
  (variations present: shown read-only as `plural.one: …; plural.other: …`).
- Editing a translation writes `stringUnit` `{state: translated, value}`;
  clearing it removes the language's localization (and `localizations`
  when it becomes empty). Add Key adds an entry with
  `extractionState = manual`. Every edit is saved at once.

## Evidence

- Keys and values: Apple's public documentation for String Catalogs and
  localization (level 1); the layout matches files studied as a format
  (level 2).
- OPEN QUESTION: the exact sort the reference uses for new keys (Ycode uses
  code-unit order); whether it writes a final newline; the reference's
  column titles and state icons; editing plural/device variations and
  substitutions (read-only in Ycode).
- Adding a language also appends its code to the project's `knownRegions`
  (once) when the catalog is in a project: Apple's localization
  documentation (level 1).
