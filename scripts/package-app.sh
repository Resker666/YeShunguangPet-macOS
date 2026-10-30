#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -gt 1 ]; then echo 'Usage: bash scripts/package-app.sh [arm64|x86_64]' >&2; exit 2; fi
architecture=${1:-arm64}
case "$architecture" in
  arm64) app="$PWD/dist/YeShunguangPet.app" ;;
  x86_64) app="$PWD/dist/x86_64/YeShunguangPet.app" ;;
  *) echo 'Architecture must be arm64 or x86_64' >&2; exit 2 ;;
esac
metadata=$(python3 scripts/verify-app.py "$app" --expect-architecture "$architecture")
stem=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["artifactStem"])' <<< "$metadata")
version=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' <<< "$metadata")
mkdir -p .build
work=$(mktemp -d "$PWD/.build/package.XXXXXX")
trap 'rm -rf "$work"' EXIT
stage="$work/$stem"
mkdir "$stage"
ditto "$app" "$stage/YeShunguangPet.app"
ln -s /Applications "$stage/Applications"
{
  printf '本安装包架构：%s\n' "$architecture"
  if [ "$architecture" = x86_64 ]; then
    printf 'Intel兼容测试版：本版已交叉构建，尚无本版Intel／黑苹果实机结果。\n\n'
  else
    printf '适用于Apple Silicon（M系列）Mac。\n\n'
  fi
  cat docs/installation.txt
} > "$stage/安装说明.txt"
ditto "$app/Contents/Resources/Notices" "$stage/开源与素材说明"
ditto -c -k --sequesterRsrc --keepParent "$stage" "$work/$stem.zip"
hdiutil create -volname "叶瞬光桌宠 $version $architecture" -srcfolder "$stage" -format UDZO -ov "$work/$stem.dmg"
hdiutil verify "$work/$stem.dmg"
# Publish complete local artifacts after both formats succeeded.
mv "$work/$stem.zip" "$work/$stem.dmg" dist/
cd dist
for suffix in dmg zip; do
  shasum -a 256 "$stem.$suffix" > "$stem.$suffix.sha256"
  shasum -a 256 -c "$stem.$suffix.sha256"
done
