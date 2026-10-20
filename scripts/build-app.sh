#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build dist
xcodebuild -project YeShunguangPet.xcodeproj -scheme YeShunguangPet -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/release CODE_SIGNING_ALLOWED=NO build
app=dist/YeShunguangPet.app
if [ -d "$app" ]; then rm -rf "$app"; fi
/usr/bin/ditto .build/release/Build/Products/Release/YeShunguangPet.app "$app"
codesign --force --sign - --timestamp=none "$app/Contents/Frameworks/PetCore.framework"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict --verbose=2 "$app"
