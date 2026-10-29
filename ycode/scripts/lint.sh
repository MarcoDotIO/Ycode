#!/bin/sh
# Lints ycode/ and frameworks/ with the repository's .swiftlint.yml (SwiftLint must be installed).
cd "$(dirname "$0")/../.." && exec swiftlint lint --strict "$@"
