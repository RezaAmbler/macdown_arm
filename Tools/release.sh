#!/bin/bash
#
# release.sh — build, sign, and publish an arm64 MacDown release to GitHub,
# and update the Sparkle appcast so existing installs auto-update.
#
# Usage:   Tools/release.sh v0.8.0  ["release notes line"]
#
# The version string is derived from the tag by Tools/utils.sh: tagging the
# commit "v0.8.0" makes the build stamp CFBundleShortVersionString = 0.8.0.
# Run this on the master branch with a clean working tree.
#
set -o errexit
set -o nounset
set -o pipefail

TAG="${1:?usage: Tools/release.sh vX.Y.Z [\"notes\"]}"
NOTES="${2:-Apple Silicon (arm64) build.}"
REPO="RezaAmbler/macdown_arm"
ASSET="MacDown-arm64.zip"
DEVELOPER_DIR_PATH="/Applications/Xcode.app/Contents/Developer"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Tagging $TAG"
git rev-parse "$TAG" >/dev/null 2>&1 || git tag "$TAG"

echo "==> Building Release (arm64)"
export DEVELOPER_DIR="$DEVELOPER_DIR_PATH"
export LANG=en_US.UTF-8
xcodebuild -workspace MacDown.xcworkspace -scheme MacDown \
    -configuration Release -arch arm64 ONLY_ACTIVE_ARCH=YES \
    MACOSX_DEPLOYMENT_TARGET=10.13 CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES build >/tmp/macdown_release_build.log 2>&1 \
    || { echo "BUILD FAILED — see /tmp/macdown_release_build.log"; exit 1; }

APP="$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/MacDown-*/Build/Products/Release/MacDown.app | head -1)"

# Xcode's version run-script phase doesn't reliably re-run on incremental
# builds, so derive the version from git (the same logic the project uses in
# Tools/utils.sh) and stamp it into the built bundle ourselves, before signing.
# shellcheck source=utils.sh
source "$ROOT/Tools/utils.sh"
SHORT="$(get_short_version)"
BUNDLE="$(get_bundle_version)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUNDLE" "$APP/Contents/Info.plist"
echo "    built version $SHORT (build $BUNDLE) — $(lipo -info "$APP/Contents/MacOS/MacDown" | sed 's/.*: //')"

echo "==> Ad-hoc signing and zipping"
codesign --force --deep --sign - "$APP"
ZIP="/tmp/$ASSET"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> EdDSA signing the zip"
SIGINFO="$(./Pods/Sparkle/bin/sign_update "$ZIP")"
EDSIG="$(printf '%s' "$SIGINFO" | sed -n 's/.*edSignature="\([^"]*\)".*/\1/p')"
LEN="$(printf '%s' "$SIGINFO" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
[ -n "$EDSIG" ] && [ -n "$LEN" ] || { echo "Failed to sign update"; exit 1; }

echo "==> Pushing tag and creating GitHub release $TAG"
git push origin "$TAG"
gh release create "$TAG" "$ZIP" --repo "$REPO" \
    --title "MacDown $SHORT (arm64)" \
    --notes "$NOTES

Ad-hoc signed (not notarized). On first launch right-click the app and choose Open, or run: xattr -dr com.apple.quarantine /Applications/MacDown.app"

echo "==> Updating appcast.xml"
URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
PUBDATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
cat > appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>MacDown (arm64 fork)</title>
    <link>https://raw.githubusercontent.com/$REPO/master/appcast.xml</link>
    <description>Updates for RezaAmbler's Apple Silicon MacDown fork.</description>
    <language>en</language>
    <item>
      <title>Version $SHORT (arm64)</title>
      <description><![CDATA[ $NOTES ]]></description>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUNDLE</sparkle:version>
      <sparkle:shortVersionString>$SHORT</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>10.13</sparkle:minimumSystemVersion>
      <enclosure
        url="$URL"
        sparkle:edSignature="$EDSIG"
        length="$LEN"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
XML
xmllint --noout appcast.xml

echo "==> Committing appcast"
git add appcast.xml
git commit -m "Release $SHORT" >/dev/null
git push origin HEAD

echo "==> Done: released $SHORT (build $BUNDLE) -> $URL"
