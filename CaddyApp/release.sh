#!/bin/zsh
# Builds, signs with Developer ID, notarises and staples Caddy.
# Usage: ./release.sh 0.2   (version; the build number is the commit count)
# Needs the notary profile saved once: xcrun notarytool store-credentials caddy-notary …
set -euo pipefail

version=${1:?Usage: ./release.sh <version>}
build=$(git rev-list --count HEAD)
profile=caddy-notary
cd "${0:A:h}"
out=build/release/$version
rm -rf "$out"
mkdir -p "$out"

echo "Archiving $version ($build)…"
xcodebuild -project Caddy.xcodeproj -scheme Caddy -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$out/Caddy.xcarchive" \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
  -allowProvisioningUpdates -quiet archive

echo "Exporting with Developer ID…"
xcodebuild -exportArchive -archivePath "$out/Caddy.xcarchive" \
  -exportPath "$out" -exportOptionsPlist ExportOptions.plist \
  -allowProvisioningUpdates -quiet

app=$out/Caddy.app
codesign --verify --deep --strict "$app"

echo "Notarising (usually a few minutes)…"
ditto -c -k --keepParent "$app" "$out/upload.zip"
xcrun notarytool submit "$out/upload.zip" --keychain-profile "$profile" --wait
rm "$out/upload.zip"

xcrun stapler staple "$app"
spctl --assess --type execute -vv "$app"

zip=$out/Caddy-$version.zip
ditto -c -k --keepParent "$app" "$zip"
echo "Done: $zip"
