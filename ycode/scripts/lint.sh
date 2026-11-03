#!/bin/sh
# Lints ycode/, frameworks/ and composer/ with the repository's .swiftlint.yml (SwiftLint must be installed).
cd "$(dirname "$0")/../.." && exec swiftlint lint --strict "$@"
