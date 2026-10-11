# Spec: OpenStep ASCII property lists

Status: **implemented** in `ycode/Sources/YcodePlist`.

This is the NeXTSTEP/OpenStep text serialization of property lists. Today it
is used by `.pbxproj`, legacy `.strings` files, and some defaults domains.

## Data model

There are four value types: string, array, dictionary (with string keys), and
data. The format has no number, boolean, or date type. A value such as `1` or
`YES` is a string. Ycode keeps dictionary insertion order. The format itself
does not define an order.

## Grammar

    document   := BOM? trivia value trivia EOF
    value      := dictionary | array | data | string
    dictionary := '{' trivia (string trivia '=' trivia value trivia ';' trivia)* '}'
    array      := '(' trivia (value trivia (',' trivia value trivia)* (',' trivia)?)? ')'
    data       := '<' (hexdigit | whitespace)* '>'      -- an even number of digits
    string     := unquoted | quoted
    unquoted   := [A-Za-z0-9_$+/:.-]+
    quoted     := '"' (char | escape)* '"'               -- single quotes are also accepted
    trivia     := (whitespace | '//' ... EOL | '/*' ... '*/')*

The escapes in quoted strings are:

- `\a \b \f \n \r \t \v`
- `\\ \" \'`
- `\Uxxxx` (1 to 4 hex digits, a UTF-16 code unit, so surrogate pairs combine)
- `\ooo` (1 to 3 octal digits)

A backslash before any other character stands for that character.

## Writing

The general writer quotes a string by the same rule as `pbxproj.md`. It
indents with tabs and writes every container entry on its own line.

## Evidence

- Level 1/2: this format is publicly known from NeXT/Apple documentation
  (the "Old-Style ASCII Property Lists" section of Apple's Property List
  Programming Guide). The escape and quoting behavior was checked against the
  corpus.
