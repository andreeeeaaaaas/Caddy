#!/bin/zsh
# Builds, signs with Developer ID, notarises and staples Caddy, writes the
# Sparkle appcast, then (after asking) publishes both as a GitHub release, where
# the app's SUFeedURL finds them.
# Usage: ./release.sh 0.2   (version; the build number is the commit count)
# Release notes, if any: release-notes/0.2.md (shown in the update window).
# Needs the notary profile saved once: xcrun notarytool store-credentials caddy-notary …
# and the Sparkle key in the login Keychain (account caddy), made by generate_keys.
set -euo pipefail

version=${1:?Usage: ./release.sh <version>}
build=$(git rev-list --count HEAD)
profile=caddy-notary
repo=andreeeeaaaaas/Caddy
tag=v$version
cd "${0:A:h}"
packages=$PWD/build/SourcePackages
sparkle=$packages/artifacts/sparkle/Sparkle/bin
out=build/release/$version
rm -rf "$out"
mkdir -p "$out"

echo "Archiving $version ($build)…"
xcodebuild -project Caddy.xcodeproj -scheme Caddy -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$out/Caddy.xcarchive" \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
  -clonedSourcePackagesDirPath "$packages" \
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

# Only this release goes in the appcast: every older version updates straight to it.
updates=$out/updates
mkdir -p "$updates"
zip=$updates/Caddy-$version.zip
ditto -c -k --keepParent "$app" "$zip"
notes=release-notes/$version.md
[[ -f $notes ]] && cp "$notes" "$updates/Caddy-$version.md"

echo "Writing the appcast…"
"$sparkle/generate_appcast" --account caddy --embed-release-notes \
  --download-url-prefix "https://github.com/$repo/releases/download/$tag/" "$updates"
echo "Built: $zip"

read -q "?Publish $tag to GitHub Releases, where Caddy will offer it as an update? [y/N] " || { echo; exit 0; }
echo
if ! git branch -r --contains HEAD | grep -q .; then
  echo "Push this commit first: the release is tagged on it." >&2
  exit 1
fi
if [[ -f $notes ]]; then release_notes=(--notes-file "$notes"); else release_notes=(--generate-notes); fi
gh release create "$tag" "$zip" "$updates/appcast.xml" --repo "$repo" \
  --target "$(git rev-parse HEAD)" --title "Caddy $version" "${release_notes[@]}"
echo "Published: https://github.com/$repo/releases/tag/$tag"
