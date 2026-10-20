#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app=dist/YeShunguangPet.app
binary="$app/Contents/MacOS/YeShunguangPet"
test -s "$binary"
test "$(lipo -archs "$binary")" = arm64
test -s "$app/Contents/Frameworks/PetCore.framework/Versions/A/PetCore"
codesign --verify --strict --verbose=2 "$app"
python3 - "$app" <<'PY'
from pathlib import Path
import hashlib,sys,plistlib
app=Path(sys.argv[1])
for file,sha in [('pet.json','70052fd6a39c3cbe3396369f9b19d5501c236b4abb18a56d3705642ed3e08811'),('spritesheet.png','42fbb6129741a7468526ad0cad27df82ee3939be140c768d3f431cc0c9a45c2d')]:
    assert hashlib.sha256((app/'Contents/Resources/Pets/YeShunguang'/file).read_bytes()).hexdigest()==sha, file
info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier']=='io.github.resker666.yeshunguangpet.macos'
assert info['LSUIElement'] and info['LSMinimumSystemVersion']=='15.0'
PY
cd dist
ditto -c -k --sequesterRsrc --keepParent YeShunguangPet.app YeShunguangPet-macOS-arm64.zip
shasum -a 256 YeShunguangPet-macOS-arm64.zip > YeShunguangPet-macOS-arm64.zip.sha256
shasum -a 256 -c YeShunguangPet-macOS-arm64.zip.sha256
