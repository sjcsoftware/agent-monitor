#!/usr/bin/env bash
# Runs the Swift Testing suite with only the Command Line Tools installed.
set -euo pipefail
cd "$(dirname "$0")/.."

CLT=/Library/Developer/CommandLineTools
FRAMEWORKS=$CLT/Library/Developer/Frameworks
if [[ -d "$CLT/usr/lib/swift/host/plugins/testing" ]]; then
  swift test \
    -Xswiftc -plugin-path -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing" \
    -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" "$@"
else
  swift test "$@"
fi
