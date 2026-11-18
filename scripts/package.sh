#!/bin/zsh
# Build a distributable: universal binary (Apple silicon + Intel) → ad-hoc signing → dist/Sparkling-<version>.dmg (+ .sha256)
# Usage: scripts/package.sh
# With an Apple Developer ID: SPARKLING_SIGN_ID="Developer ID Application: Your Name (TEAMID)" SPARKLING_NOTARY_PROFILE=<notarytool keychain profile> scripts/package.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
SIGN_ID=${SPARKLING_SIGN_ID:--}
STAGE=build/dist-stage
APP=$STAGE/Sparkling.app
DMG=dist/Sparkling-$VERSION.dmg

echo "▸ Building universal binary v$VERSION"
swift build -c release --product Sparkling --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Sparkling"

rm -rf "$STAGE" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist
cp "$BIN" "$APP/Contents/MacOS/Sparkling"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Signing ($SIGN_ID)"
if [[ "$SIGN_ID" == "-" ]]; then
  codesign --force --deep --sign - "$APP"
else
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi
codesign --verify --strict "$APP"

echo "▸ Creating DMG"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Sparkling $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

if [[ -n "${SPARKLING_NOTARY_PROFILE:-}" && "$SIGN_ID" != "-" ]]; then
  echo "▸ Notarizing"
  codesign --sign "$SIGN_ID" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$SPARKLING_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

(cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "✓ $DMG（$(lipo -archs "$APP/Contents/MacOS/Sparkling")）"
cat "$DMG.sha256"
