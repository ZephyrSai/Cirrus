#!/bin/zsh
# Builds Cirrus for iPhone and iPad from ios/Cirrus.xcodeproj (no App Store; build from source).
#
#   TEAM_ID=<team id>          sign for devices with this Apple developer team (a free Apple ID works; see BUILDING.md)
#   SIGN_IDENTITY=<sha1|name>  signing identity (default: Xcode picks "Apple Development" for TEAM_ID)
#   BUNDLE_ID=...              (default io.github.zephyrsai.cirrus.ios; a free account needs an ID nobody else has used)
#   CONFIG=Release|Debug       (default Release; Debug adds the Simulator screenshot hooks)
#   TESTER=1                   tester build: starts in read-only iCloud mode
#   VERSION=1.0.0              CFBundleShortVersionString (build number = git commit count)
#   SIMULATOR=1                also build for the iOS Simulator → build/ios/Simulator/Cirrus.app
#   IPA=<method>               also archive and export an .ipa: development | release-testing (ad hoc) | app-store-connect (TestFlight)
#   INSTALL=1                  install the signed app on the connected iPhone or iPad (xcrun devicectl)
#   ALLOW_PROVISIONING=1       let xcodebuild create or refresh provisioning profiles (uses the account signed in to Xcode)
#
# Without TEAM_ID the device build is unsigned: it proves the code compiles but won't install.
set -euo pipefail
cd "${0:A:h}/.."

CONFIG=${CONFIG:-Release}
VERSION=${VERSION:-1.0.0}
BUNDLE_ID=${BUNDLE_ID:-io.github.zephyrsai.cirrus.ios}
BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
OUT=build/ios
DERIVED=$OUT/DerivedData
TESTER_FLAG=$([[ "${TESTER:-0}" == "1" ]] && echo YES || echo NO)
SUFFIX=$([[ "${TESTER:-0}" == "1" ]] && echo "-tester" || echo "")

common=(-project ios/Cirrus.xcodeproj -scheme Cirrus -configuration "$CONFIG" -derivedDataPath "$DERIVED"
        PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
        CIRRUS_TESTER="$TESTER_FLAG")
signing=()
if [[ -n "${TEAM_ID:-}" ]]; then
  signing=(DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic)
  [[ -n "${SIGN_IDENTITY:-}" ]] && signing+=(CODE_SIGN_IDENTITY="$SIGN_IDENTITY")
else
  signing=(CODE_SIGNING_ALLOWED=NO)
  [[ -n "${IPA:-}${INSTALL:-}" ]] && { echo "IPA and INSTALL need TEAM_ID (your Apple developer team ID)." >&2; exit 1; }
fi
provisioning=()
[[ "${ALLOW_PROVISIONING:-0}" == "1" ]] && provisioning=(-allowProvisioningUpdates)

mkdir -p "$OUT"
echo "== iPhone/iPad ($CONFIG, ${TEAM_ID:+team $TEAM_ID}${TEAM_ID:-unsigned}, tester: $TESTER_FLAG)"
xcodebuild "${common[@]}" -destination 'generic/platform=iOS' "${signing[@]}" "${provisioning[@]}" build | grep -E "error:|warning: .*ios/Cirrus|BUILD" || true
APP="$DERIVED/Build/Products/$CONFIG-iphoneos/Cirrus.app"
[[ -d "$APP" ]] || { echo "build failed" >&2; exit 1; }
rm -rf "$OUT/Cirrus.app"; cp -R "$APP" "$OUT/Cirrus.app"

# Release builds must not contain the Debug-only screenshot hooks.
if [[ "$CONFIG" == "Release" ]] && strings "$OUT/Cirrus.app/Cirrus" | grep -q "CIRRUS_SCREEN"; then
  echo "error: Release build contains Debug screenshot hooks" >&2; exit 1
fi
echo "tester flag: $(/usr/libexec/PlistBuddy -c 'Print :CirrusTesterBuild' "$OUT/Cirrus.app/Info.plist")"
if [[ -n "${TEAM_ID:-}" ]]; then codesign --verify --strict "$OUT/Cirrus.app" && codesign -dv "$OUT/Cirrus.app" 2>&1 | grep -E "^(Authority|TeamIdentifier)=" | head -2; fi
echo "built $OUT/Cirrus.app ($(du -sh "$OUT/Cirrus.app" | cut -f1))"

if [[ "${SIMULATOR:-0}" == "1" ]]; then
  echo "== Simulator"
  xcodebuild "${common[@]}" -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build | grep -E "error:|BUILD" || true
  SIM="$DERIVED/Build/Products/$CONFIG-iphonesimulator/Cirrus.app"
  [[ -d "$SIM" ]] || { echo "simulator build failed" >&2; exit 1; }
  mkdir -p "$OUT/Simulator"; rm -rf "$OUT/Simulator/Cirrus.app"; cp -R "$SIM" "$OUT/Simulator/Cirrus.app"
  echo "built $OUT/Simulator/Cirrus.app"
fi

if [[ -n "${IPA:-}" ]]; then
  echo "== Archive and export ($IPA)"
  ARCHIVE="$OUT/Cirrus.xcarchive"
  rm -rf "$ARCHIVE"
  xcodebuild "${common[@]}" -destination 'generic/platform=iOS' "${signing[@]}" "${provisioning[@]}" archive -archivePath "$ARCHIVE" | grep -E "error:|ARCHIVE" || true
  [[ -d "$ARCHIVE" ]] || { echo "archive failed" >&2; exit 1; }
  OPTS="$OUT/ExportOptions.plist"
  /usr/libexec/PlistBuddy -c "Clear dict" -c "Add :method string $IPA" -c "Add :teamID string $TEAM_ID" \
    -c "Add :signingStyle string automatic" -c "Add :stripSwiftSymbols bool true" "$OPTS" >/dev/null 2>&1 || {
    plutil -create xml1 "$OPTS"
    plutil -insert method -string "$IPA" "$OPTS"; plutil -insert teamID -string "$TEAM_ID" "$OPTS"
    plutil -insert signingStyle -string automatic "$OPTS"; plutil -insert stripSwiftSymbols -bool true "$OPTS"
  }
  rm -rf "$OUT/export"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" -exportOptionsPlist "$OPTS" "${provisioning[@]}" | grep -E "error:|EXPORT" || true
  mkdir -p build/dist
  IPA_OUT="build/dist/Cirrus-$VERSION$SUFFIX-ios.ipa"
  mv "$OUT/export/"*.ipa "$IPA_OUT"
  shasum -a 256 "$IPA_OUT"
fi

if [[ "${INSTALL:-0}" == "1" ]]; then
  echo "== Install on a connected device"
  DEVICE=$(xcrun devicectl list devices 2>/dev/null | awk '/(iPhone|iPad)/ && /available|connected/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-/) {print $i; exit}}')
  [[ -n "$DEVICE" ]] || { echo "No connected iPhone or iPad found (unlock it, trust this Mac, and turn on Developer Mode)." >&2; exit 1; }
  xcrun devicectl device install app --device "$DEVICE" "$OUT/Cirrus.app"
fi
