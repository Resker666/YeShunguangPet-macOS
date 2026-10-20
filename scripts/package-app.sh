#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/dist/YeShunguangPet.app"
metadata=$(python3 scripts/verify-app.py "$app")
stem=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["artifactStem"])' <<< "$metadata")
version=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' <<< "$metadata")
mkdir -p .build
work=$(mktemp -d "$PWD/.build/package.XXXXXX")
trap 'rm -rf "$work"' EXIT
stage="$work/$stem"
mkdir "$stage"
ditto "$app" "$stage/YeShunguangPet.app"
ln -s /Applications "$stage/Applications"
cp docs/installation.txt "$stage/安装说明.txt"
ditto "$app/Contents/Resources/Notices" "$stage/开源与素材说明"
ditto -c -k --sequesterRsrc --keepParent "$stage" "$work/$stem.zip"
hdiutil create -volname "叶瞬光桌宠 $version" -srcfolder "$stage" -format UDZO -ov "$work/$stem.dmg"
hdiutil verify "$work/$stem.dmg"
# Publish complete local artifacts after both formats succeeded.
mv "$work/$stem.zip" "$work/$stem.dmg" dist/
cd dist
for suffix in dmg zip; do
  shasum -a 256 "$stem.$suffix" > "$stem.$suffix.sha256"
  shasum -a 256 -c "$stem.$suffix.sha256"
done
