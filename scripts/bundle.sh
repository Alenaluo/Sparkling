#!/bin/zsh
# Build and assemble build/Sparkling.app. Usage: scripts/bundle.sh [debug|release] [--install]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-release}
INSTALL=0
[[ "${2:-}" == "--install" || "${1:-}" == "--install" ]] && INSTALL=1
[[ "$CONFIG" == "--install" ]] && CONFIG=release

swift build -c "$CONFIG" --product Sparkling
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Sparkling"
APP=build/Sparkling.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Sparkling"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Signing: SPARKLING_SIGN_ID names the certificate; otherwise use the self-signed "Sparkling Dev" certificate from the keychain if present; else ad-hoc
if [[ -n "${SPARKLING_SIGN_ID:-}" ]]; then SIGN_ID=$SPARKLING_SIGN_ID
elif security find-identity -p codesigning 2>/dev/null | grep -q '"Sparkling Dev"'; then SIGN_ID="Sparkling Dev"
else SIGN_ID=-; fi
codesign --force --sign "$SIGN_ID" --timestamp=none "$APP"
echo "built $APP ($CONFIG, sign: $SIGN_ID)"

if (( INSTALL )); then
  pkill -x Sparkling 2>/dev/null || true
  rm -rf /Applications/Sparkling.app
  cp -R "$APP" /Applications/Sparkling.app
  open /Applications/Sparkling.app
  echo "installed /Applications/Sparkling.app"
fi
