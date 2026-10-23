#!/bin/bash
# E2E tests skip themselves unless PROPERFINDER_E2E=1 (see scripts/test-e2e.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

# Same Command Line Tools gaps as build-app.sh, plus swift-testing's macro plugin living outside the default search path.
if [[ "$(xcode-select -p)" == /Library/Developer/CommandLineTools* ]]; then
    CLT=/Library/Developer/CommandLineTools
    [ -z "${SDKROOT:-}" ] && [ -d "$CLT/SDKs/MacOSX26.sdk" ] && export SDKROOT="$CLT/SDKs/MacOSX26.sdk"
    exec swift test -Xswiftc -plugin-path -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing" "$@"
fi
exec swift test "$@"
