#!/bin/zsh
# Builds a universal Cirrus.app and packages it as build/dist/Cirrus-<version>-mac.{dmg,zip}.
#   SIGN_IDENTITY=<sha1|name>   signing identity (Developer ID Application for others to open it without warnings)
#   TESTER=1                    start in read-only iCloud mode (recommended when handing to testers)
#   NOTARY_PROFILE=<name>       if set, notarize + staple via `xcrun notarytool` (needs a Developer ID identity
#                               and `xcrun notarytool store-credentials <name>` run once)
#   VERSION=1.0.0
set -euo pipefail
cd "${0:A:h}/.."
VERSION=${VERSION:-1.0.0}
SUFFIX=$([[ "${TESTER:-0}" == "1" ]] && echo "-tester" || echo "")
STAGE=build/dist/stage
OUT=build/dist
rm -rf "$STAGE"; mkdir -p "$STAGE" "$OUT"

UNIVERSAL=1 OUTPUT="$STAGE" VERSION="$VERSION" scripts/build-app.sh
APP="$STAGE/Cirrus.app"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  ZIP_N="$OUT/notarize.zip"
  ditto -c -k --keepParent "$APP" "$ZIP_N"
  xcrun notarytool submit "$ZIP_N" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP_N"
fi

ZIP="$OUT/Cirrus-$VERSION$SUFFIX-mac.zip"
DMG="$OUT/Cirrus-$VERSION$SUFFIX-mac.dmg"
rm -f "$ZIP" "$DMG"
ditto -c -k --keepParent "$APP" "$ZIP"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Cirrus" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -f "$STAGE/Applications"
shasum -a 256 "$ZIP" "$DMG"
echo
if [[ -z "${NOTARY_PROFILE:-}" ]]; then
  echo "Not notarized: on another Mac, open it once via System Settings › Privacy & Security › Open Anyway."
fi
