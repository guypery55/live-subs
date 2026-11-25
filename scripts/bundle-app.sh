#!/usr/bin/env bash
# Builds LiveSubs.app (universal: Intel + Apple Silicon) and a zip in dist/. Runs on macOS
# (GitHub Actions or a Mac). Signing:
#   - SIGN_P12_BASE64 + SIGN_P12_PASSWORD set: signs with that (self-signed) certificate, so
#     the friend's permission survives updates.
#   - otherwise: ad-hoc signature (works, but macOS asks for the permission again after updates).
# Usage: scripts/bundle-app.sh [version] [build-number]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
BUILD="${2:-1}"
APP="dist/LiveSubs.app"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/LiveSubs"

rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LiveSubs"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" App/Resources/Info.plist > "$APP/Contents/Info.plist"
if [ -f App/Resources/AppIcon.icns ]; then
  cp App/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi
lipo -info "$APP/Contents/MacOS/LiveSubs"

if [ -n "${SIGN_P12_BASE64:-}" ]; then
  KEYCHAIN="$RUNNER_TEMP/livesubs-signing.keychain-db"
  KC_PASS="$(uuidgen)"
  echo "$SIGN_P12_BASE64" | base64 --decode > "$RUNNER_TEMP/sign.p12"
  security create-keychain -p "$KC_PASS" "$KEYCHAIN"
  security set-keychain-settings -lut 3600 "$KEYCHAIN"
  security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"
  security import "$RUNNER_TEMP/sign.p12" -k "$KEYCHAIN" -P "$SIGN_P12_PASSWORD" -T /usr/bin/codesign
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null
  security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
  rm -f "$RUNNER_TEMP/sign.p12"
  # Self-signed, so it isn't "trusted": pick it by its SHA-1 hash rather than by name.
  IDENTITY="$(security find-identity -p codesigning "$KEYCHAIN" | awk '/\)/ {print $2; exit}')"
  echo "Signing with certificate $IDENTITY"
  codesign --force --timestamp=none --keychain "$KEYCHAIN" --sign "$IDENTITY" \
    --identifier app.livesubs.LiveSubs "$APP"
else
  echo "No signing certificate given: ad-hoc signature."
  codesign --force --sign - --identifier app.livesubs.LiveSubs "$APP"
fi
codesign --verify --verbose=2 "$APP"
codesign --display --requirements - "$APP" 2>&1 | tail -2

( cd dist && ditto -c -k --keepParent LiveSubs.app "LiveSubs-$VERSION.zip" )
echo "Built dist/LiveSubs-$VERSION.zip"
