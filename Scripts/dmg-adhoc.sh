#!/usr/bin/env bash
# Release build + drag-to-Applications dmg, ad-hoc signed (no Apple Developer ID).
# Fine for trying on your own Mac; other machines may block it via Gatekeeper.
set -euo pipefail
cd "$(dirname "$0")/.."

app="TokNotch"
version="$(awk -F'"' '/MARKETING_VERSION:/ {print $2}' project.yml)"
root="build/adhoc-dmg"
app_path="$root/Build/Products/Release/$app.app"
dmg="$root/$app.dmg"

rm -rf "$root"
mkdir -p "$root"
touch build/.metadata_never_index

./Scripts/fetch-tokscale.sh
xcodegen generate

xcodebuild -project "$app.xcodeproj" -scheme "$app" -destination 'platform=macOS,arch=arm64' \
  -configuration Release -derivedDataPath "$root" \
  -clonedSourcePackagesDirPath build/SourcePackages \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
  ENABLE_HARDENED_RUNTIME=YES build -quiet

test -d "$app_path"

for nested in "$app_path/Contents/Resources/tokscale/libFoundationModels.dylib" \
              "$app_path/Contents/Resources/tokscale/tokscale"; do
  codesign --force --sign - "$nested"
done
codesign --force --deep --sign - "$app_path"

stage="$root/stage"
mkdir -p "$stage"
ditto "$app_path" "$stage/$app.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -ov -volname "$app" -srcfolder "$stage" -format UDZO "$dmg"
rm -rf "$stage"

echo "$app $version ad-hoc dmg: $dmg"
echo "Right-click → Open the first time if macOS blocks it."
