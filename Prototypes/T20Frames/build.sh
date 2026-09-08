#!/bin/bash
# Build the T20 frames harness against the checkout's own SimmerCore and the
# app's own MenuRowView.swift — no second copy of either.
#
# SwiftPM builds SimmerCore as object files rather than an archive, so they are
# passed one by one; `swift build` first is what puts them there. The harness
# lives outside `Sources/`, so no SwiftPM target compiles it and `make test`
# never sees it.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
LC_ALL=C swift build
out="$root/.build/T20Frames"
# shellcheck disable=SC2046
xcrun swiftc -O -o "$out" \
    "$root/Prototypes/T20Frames/main.swift" \
    "$root/Sources/SimmerApp/MenuRowView.swift" \
    -I "$root/.build/debug/Modules" \
    $(ls "$root"/.build/debug/SimmerCore.build/*.o)
echo "$out"
