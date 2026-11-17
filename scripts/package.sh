#!/bin/zsh
# 打分发包：通用二进制（Apple 芯片 + Intel）→ ad-hoc 签名 → dist/Sparkling-<版本>.dmg（+ .sha256）
# 用法：scripts/package.sh
# 有 Apple Developer ID 时：SPARKLING_SIGN_ID="Developer ID Application: 名字 (TEAMID)" SPARKLING_NOTARY_PROFILE=<notarytool 钥匙串配置名> scripts/package.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
SIGN_ID=${SPARKLING_SIGN_ID:--}
STAGE=build/dist-stage
APP=$STAGE/Sparkling.app
DMG=dist/Sparkling-$VERSION.dmg

echo "▸ 构建通用二进制 v$VERSION"
swift build -c release --product Sparkling --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Sparkling"

rm -rf "$STAGE" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist
cp "$BIN" "$APP/Contents/MacOS/Sparkling"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "▸ 签名（$SIGN_ID）"
if [[ "$SIGN_ID" == "-" ]]; then
  codesign --force --deep --sign - "$APP"
else
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi
codesign --verify --strict "$APP"

echo "▸ 生成 DMG"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Sparkling $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

if [[ -n "${SPARKLING_NOTARY_PROFILE:-}" && "$SIGN_ID" != "-" ]]; then
  echo "▸ 公证"
  codesign --sign "$SIGN_ID" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$SPARKLING_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

(cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "✓ $DMG（$(lipo -archs "$APP/Contents/MacOS/Sparkling")）"
cat "$DMG.sha256"
