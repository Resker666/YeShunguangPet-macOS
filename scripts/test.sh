#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcodebuild -project YeShunguangPet.xcodeproj -scheme YeShunguangPet -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/tests CODE_SIGNING_ALLOWED=NO test "$@"
