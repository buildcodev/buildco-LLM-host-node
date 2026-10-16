#!/usr/bin/env bash
# Runs the layout engine's tests: `swift test`, plus what the Command Line Tools need.
#   scripts/test.sh [swift test arguments]
# The Command Line Tools ship Swift Testing (not XCTest), but SwiftPM doesn't find it there
# by itself, and its Foundation cross-import overlay ships without a module. With Xcode
# selected, or on Linux, this is plain `swift test`.
set -euo pipefail
cd "$(dirname "$0")/.."

flags=()
if [[ "$(uname)" == "Darwin" && "$(xcode-select -p 2>/dev/null)" == */CommandLineTools ]]; then
  frameworks="$(xcode-select -p)/Library/Developer/Frameworks"
  flags=(
    -Xswiftc -F -Xswiftc "$frameworks"
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays
    -Xlinker -F -Xlinker "$frameworks"
    -Xlinker -rpath -Xlinker "$frameworks"
  )
fi

swift test ${flags[@]+"${flags[@]}"} "$@"
