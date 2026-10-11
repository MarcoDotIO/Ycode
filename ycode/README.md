# Ycode (implementation)

This is clean-room code. Read `../CLAUDE.md` before you make any change here.

```bash
swift build
swift test
.build/debug/ycode describe path/to/App.xcodeproj
.build/debug/ycode roundtrip path/to/App.xcodeproj    # also .xcscheme / contents.xcworkspacedata
.build/debug/ycode schemes path/to/App.xcworkspace
.build/debug/ycode settings path/to/App.xcodeproj -target App -configuration Debug [--assigned-only] [--json] [NAME=value]
```

Supported platforms: macOS and Linux (x86-64, tested with Swift 6.4).

## Corpus tests

`PBXProjCorpusTests` runs against real projects that are not checked in. It
reads a manifest from `../research/dirty/pbxproj-corpus.txt`, or from the path
in `YCODE_PBXPROJ_CORPUS`. The manifest has one path per line:

- `= /path/App.xcodeproj`: written by Xcode. The round trip must be
  byte-identical.
- `~ /path/App.xcodeproj`: edited by other tools. The round trip must be
  lossless and idempotent.

If there is no manifest, the suite is skipped.
