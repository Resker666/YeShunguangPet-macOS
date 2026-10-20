#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build dist
xcodebuild -project YeShunguangPet.xcodeproj -scheme YeShunguangPet -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/release CODE_SIGNING_ALLOWED=NO build
app=dist/YeShunguangPet.app
if [ -d "$app" ]; then rm -rf "$app"; fi
/usr/bin/ditto .build/release/Build/Products/Release/YeShunguangPet.app "$app"
python3 - "$app" <<'BUILDINFO'
from pathlib import Path
import json,subprocess,sys
app=Path(sys.argv[1])
info={'commit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'trackedChanges':bool(subprocess.check_output(['git','status','--porcelain','--untracked-files=no'],text=True).strip())}
(app/'Contents/Resources/build-info.json').write_text(json.dumps(info,indent=2)+'\n')
BUILDINFO
codesign --force --sign - --timestamp=none "$app/Contents/Frameworks/PetCore.framework"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict --verbose=2 "$app"
