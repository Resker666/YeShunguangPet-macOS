#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -gt 1 ]; then echo 'Usage: bash scripts/build-app.sh [arm64|x86_64]' >&2; exit 2; fi
architecture=${1:-arm64}
case "$architecture" in
  arm64) derived=.build/release; app=dist/YeShunguangPet.app ;;
  x86_64) derived=.build/release-x86_64; app=dist/x86_64/YeShunguangPet.app ;;
  *) echo 'Architecture must be arm64 or x86_64' >&2; exit 2 ;;
esac
mkdir -p .build "$(dirname "$app")"
xcodebuild -project YeShunguangPet.xcodeproj -scheme YeShunguangPet -configuration Release -destination 'generic/platform=macOS' ARCHS="$architecture" ONLY_ACTIVE_ARCH=NO -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO build
if [ -d "$app" ]; then rm -rf "$app"; fi
/usr/bin/ditto "$derived/Build/Products/Release/YeShunguangPet.app" "$app"
mkdir -p "$app/Contents/Resources/Notices"
cp LICENSE "$app/Contents/Resources/Notices/LICENSE.txt"
cp ASSET_NOTICE.md docs/resource-provenance.md "$app/Contents/Resources/Notices/"
python3 - "$app" "$architecture" <<'BUILDINFO'
from pathlib import Path
import json,subprocess,sys
app=Path(sys.argv[1])
info={'commit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'trackedChanges':bool(subprocess.check_output(['git','status','--porcelain','--untracked-files=no'],text=True).strip()),'architecture':sys.argv[2]}
(app/'Contents/Resources/build-info.json').write_text(json.dumps(info,indent=2)+'\n')
BUILDINFO
codesign --force --sign - --timestamp=none "$app/Contents/Frameworks/PetCore.framework"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict --verbose=2 "$app"
