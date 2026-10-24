# Contacts spec: name and address formatting, vCard

Part of `specs/frameworks/contacts/`. All golden values were produced by
`CNProbe -phase basic` on the iOS 27.1 simulator, locale en_US, region US,
from made-up input. They need no authorization. vCard grammar background:
RFC 2426 (vCard 3.0), RFC 6350 (vCard 4.0), level 1.

## 1. Name formatting (`CNContactFormatter`)

Styles: 0 full name, 1 phonetic full name. Class methods
`stringFromContact:style:`, `attributedStringFromContact:style:defaultAttributes:`,
`nameOrderForContact:` (`CNContactDisplayNameOrder`: 1 given first, 2 family
first), `delimiterForContact:`, and the key descriptors. The attributed
string tags each run with the attribute `CNContactPropertyAttribute` whose
value is the key of the part.

### 1.1 Rules (observed)

1. Order of parts for given-first: prefix, given, middle, family, suffix,
   joined by the delimiter " ".
2. A contact whose given **and** family names are both CJK (Han, Kana,
   Hangul) is family-first with delimiter "" (empty). Mixed scripts (one CJK
   part, one Latin) stay given-first with " ".
3. Arabic and Cyrillic names are given-first with " " (en_US locale).
4. Fallbacks when no name part is set: nickname, then organization name
   (for persons and organizations alike). An organization-type contact
   formats as its organization name even if it has name parts (only
   organization set in our case).
5. Nothing to show (empty contact; only an email) → nil.
6. Leading and trailing spaces inside parts are **kept**; the delimiter is
   not added next to a part that already ends with a space (F22).
7. Phonetic style: the phonetic parts joined the same way (" " Latin;
   one space between kana parts for the Japanese contact); nil when no
   phonetic part exists; for an organization its phonetic organization name.

### 1.2 Golden table

| # | Input (prefix/given/middle/family/suffix, other) | Full name | Order, delimiter | Runs (key) |
|---|---|---|---|---|
| F1 | Avery, Example | "Avery Example" | 1, " " | given, family |
| F2 | Dr./Avery/Quinn/Example/Jr. | "Dr. Avery Quinn Example Jr." | 1, " " | prefix, given, middle, family, suffix |
| F3 | given only | "Avery" | 1 | given |
| F4 | family only | "Example" | 1 | family |
| F5 | middle only | "Quinn" | 1 | middle |
| F6 | nickname only "Ave" | "Ave" | 1 | nickname |
| F7 | organization only (person) | "Example Widgets LLC" | 1 | organizationName |
| F8 | organization type | "Example Widgets LLC" | 1 | organizationName |
| F9 | Ms. + family | "Ms. Example" | 1 | prefix, family |
| F10 | given + suffix III | "Avery III" | 1 | given, suffix |
| F11 | 太郎 / 山田 (given/family) | "山田太郎" | 2, "" | family, given |
| F12 | 小明 / 王 | "王小明" | 2, "" | family, given |
| F13 | 민준 / 김 | "김민준" | 2, "" | family, given |
| F14 | José / Luis / García | "José Luis García" | 1, " " | given, middle, family |
| F15 | given 太郎, family Example | "太郎 Example" | 1, " " | given, family |
| F16 | given Avery, family 山田 | "Avery 山田" | 1, " " | given, family |
| F17 | empty | nil | 1, " " | — |
| F18 | email only | nil | 1, " " | — |
| F19 | F1 + phonetic AY-ver-ee / kwin / ig-ZAM-pul | full "Avery Example"; phonetic "AY-ver-ee kwin ig-ZAM-pul" | 1 | given, family |
| F20 | F11 + phonetic たろう / やまだ | phonetic "やまだ たろう" | 2, "" | family, given |
| F21 | organization + phonetic organization | phonetic "ig-ZAM-pul WID-jits" | 1 | organizationName |
| F22 | given " Avery ", family "Example " | " Avery Example " | 1 | given " Avery ", family "Example " |
| F23 | سارة / مثال | "سارة مثال" | 1, " " | given, family |
| F24 | Анна / Ивановна / Пример | "Анна Ивановна Пример" | 1, " " | given, middle, family |

## 2. Postal addresses (`CNPostalAddressFormatter`)

Style 0 (mailing address). The country's layout is chosen by
`ISOCountryCode` (lower or upper case; "DE" = "de"); without a code, by the
current region (US). Unknown codes fall back to the US layout. Empty fields
are skipped with their separators. Line separator "\n". The attributed form
tags runs with `CNPostalAddressPropertyAttribute` (value = the field key).

| # | Code | Formatted |
|---|---|---|
| P1 | us | "123 Example Street\nApt 4\nSpringfield IL 62701\nUnited States" |
| P1b | us, no country | "123 Example Street\nSpringfield IL 62701" |
| P1c | us + sub-locality + county | same as P1 (sub-locality and county are not printed for US) |
| P2 | de | "Beispielstraße 5\n10115 Berlin\nGermany" |
| P3 | jp | "100-0001\n東京都 千代田区\n千代田1-1\n日本" (postal code first, then state and city, then street, then country) |
| P4 | gb | "10 Example Road\nLondon\nSW1A 1AA\nUnited Kingdom" |
| P5 | fr | "5 rue Exemple\n75001 Paris\nFrance" |
| P6 | cn | "中国\n北京市\n北京市 东城区\n示例路1号\n100000" (country first, state, city + district, street, postal code) |
| P7 | none (Canada data) | "1 Example Ave\nToronto ON M5V 2T6\nCanada" |
| P8 | street only | "1 Example Ave" |
| P9 | br | "Rua Exemplo, 100\nCentro\nSão Paulo SP\n01000-000\nBrasil" |
| P10 | au | "1 Example St\nSydney NSW 2000\nAustralia" |
| P11 | in | "1 Example Marg\nNew Delhi 110001\nDelhi\nIndia" |
| P12 | kr | "대한민국\n서울특별시\n중구\n세종대로 1\n04524" |
| P13 | unknown code "xx" | "1 Example St\nExampleville EX 00000\nExampleland" |
| P14 | "DE" | same as P2 |

The country *name* printed is the stored `country` string, not a name
derived from the code. Ycode needs its own table of per-country layouts
(fields, order, separators); open data such as Google's libaddressinput
address metadata (Apache-2.0) is a permissible source and agrees with the
rows above (to be verified per row in plan R3).

## 3. vCard export (`dataWithContacts:error:`)

UTF-8, CRLF line endings, a trailing CRLF; one `BEGIN:VCARD` … `END:VCARD`
block per contact; an empty array gives empty data.

### 3.1 Line order and property mapping (vCard 3.0)

| Order | Line | Source |
|---|---|---|
| 1 | `BEGIN:VCARD` | |
| 2 | `VERSION:3.0` | |
| 3 | `PRODID:-//Apple Inc.//iPhone OS 27.1//EN` | OS version (Ycode writes its own product identifier, e.g. `-//Ycode//…//EN`; apps do not parse it) |
| 4 | `N:family;given;middle;prefix;suffix` | always present (`N:;;;;` when empty) |
| 5 | `FN:` formatted full name | omitted when the formatter gives nil |
| | `NICKNAME:` | |
| | `X-MAIDENNAME:` | previous family name |
| | `X-PHONETIC-FIRST-NAME:`, `X-PHONETIC-LAST-NAME:` (middle and organization phonetics likewise, level 1) | |
| | `ORG:organization;department` | (`ORG:Example Widgets LLC;` for organization without department) |
| | `TITLE:` | job title |
| | `EMAIL;type=INTERNET;type=<HOME|WORK>[;type=pref]:` | first value of a property gets `type=pref` |
| | `TEL;type=…:` | label → types: mobile `CELL;VOICE`, home `HOME;VOICE`, iPhone `IPHONE;CELL;VOICE`, work `WORK;VOICE`, home fax `HOME;FAX`, main `MAIN` |
| | `itemN.ADR;type=<HOME|WORK>[;type=pref]:;;street;city;state;postal;country` + `itemN.X-ABADR:<iso code>` | street newlines written as `\n` |
| | `X-SOCIALPROFILE;type=<service lower-cased for known services>[;x-user=…][;x-userid=…]:<url or x-apple:username>` | |
| | `itemN.URL[;type=pref]:` + `itemN.X-ABLabel:` / `URL;type=WORK:` | |
| | `BDAY:YYYY-MM-DD`; without year `BDAY;X-APPLE-OMIT-YEAR=1604:1604-MM-DD` | |
| | `X-ALTBDAY;CALSCALE=<calendar>:<signed number>` | non-Gregorian birthday (Hebrew 5750-07-18 → `-57500718`) |
| | `X-<SERVICE>;type=…:username` and `IMPP;X-SERVICE-TYPE=<Service>;type=…:<scheme>:username` | known services get both lines (Jabber: `X-JABBER` + `IMPP …:xmpp:`); unknown services only `IMPP` with `x-apple:` |
| | `itemN.X-ABDATE[;type=pref]:YYYY-MM-DD` + `itemN.X-ABLabel:` | dates; without year `X-APPLE-OMIT-YEAR=1604` |
| | `itemN.X-ABRELATEDNAMES[;type=pref]:name` + `itemN.X-ABLabel:` | relations |
| | `X-ABShowAs:COMPANY` | organization type |
| last | `END:VCARD` | |

Labels: a predefined label that has a vCard `type` is written as types;
others (custom strings, `iCloud`, homepage, anniversary, relation labels)
use an `itemN.` group with `X-ABLabel:` holding the raw label (`_$!<HomePage>!$_`).
Groups are numbered from 1 in order of appearance. Values escape `\n` (and,
by RFC 2426, `,` and `;` in structured fields).

Not exported: `note` (absent from the output even when set — observed with
and without the notes entitlement), `imageData` (no `PHOTO` line), contact
identifier, groups.

### 3.2 Import (`contactsWithData:error:`)

| # | Input | Result |
|---|---|---|
| I1 | rich vCard 3.0 (all properties above, `CATEGORIES`, `UID`, `REV`, an unknown `X-` line, a NOTE with escaped newline and comma) | 1 contact; all mapped properties restored; note "Line one\nLine two, with comma"; unlabeled `TEL` gets label nil→"" (empty); `item3.ADR` with an extended-address part puts it as a second street line; `X-AIM` becomes an AIM instant-message address; Twitter profile keeps its URL; categories/UID/REV/unknown lines ignored |
| I2 | vCard 4.0 (`TYPE="voice,cell"`, `VALUE=uri`, `PREF=1`, `BDAY:--0315`, `ANNIVERSARY`, `RELATED`, `KIND`, `GENDER`, `LANG`) | 1 contact, parsed leniently as 3.0: the phone's label becomes the first parameter name ("VALUE") and its value "tel:+1-555-010-0301"; the address's label "LABEL"; birthday month 3 day 15 without year; anniversary and related name dropped; email without label |
| I3 | vCard 2.1 with `CHARSET=UTF-8;ENCODING=QUOTED-PRINTABLE` | decoded ("José Examplé"); bare `CELL` / `WORK;FAX` types map to mobile / work fax |
| I4 | `X-ABShowAs:COMPANY` | organization-type contact |
| I5 | two cards, LF-only line endings | 2 contacts |
| I6 | folded line (CRLF + space) | unfolded |
| I7 | `FN` only | name parts derived from FN by splitting: "Only Formatted Name" → given "Only", middle "Formatted", family "Name" |
| I8 | missing `END:VCARD` | 0 contacts, **no error** |
| I9 | garbage text | 0 contacts, no error |
| I10 | empty data | 0 contacts, no error |
| I11 | `PHOTO;ENCODING=b;TYPE=PNG` | image data restored (324 bytes), no thumbnail, image available YES |
| I12 | no `VERSION` line | parsed |

Imported contacts get new identifiers of the form `<UUID>:ABPerson` and
have every key available. The framework logs "Incorrect NSStringEncoding
value 0x0000 detected…" warnings for 3.0/4.0 input (harmless console noise).

Round trip of the full contact (export → import): equal except that known
social services come back lower-cased ("twitter") with an empty label
instead of nil, and dates and birthdays gain the Gregorian calendar.

## Evidence

| Claim | Level |
|---|---|
| Formatter API and enum values | 4 |
| Formatting rules and golden table | 3 (rules are our reading of the 24 cases) |
| Postal layouts | 3; libaddressinput as an allowed source is 1 |
| vCard export lines, ordering, mapping | 3 (+ 1 for RFC grammar) |
| vCard import table, round trip | 3 |
