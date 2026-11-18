#!/bin/zsh
# Builds build/Cirrus.app.
#   SIGN_IDENTITY=<sha1|name>  sign with that identity (default: ad-hoc "-")
#   UNIVERSAL=1                arm64 + x86_64
#   CONFIG=debug|release       (default release)
#   OUTPUT=build               output folder
#   BUNDLE_ID=...              (default io.github.zephyrsai.cirrus)
#   TESTER=1                   start in read-only iCloud mode (for handing to testers)
set -euo pipefail
cd "${0:A:h}/.."
CONFIG=${CONFIG:-release}
OUTPUT=${OUTPUT:-build}
BUNDLE_ID=${BUNDLE_ID:-io.github.zephyrsai.cirrus}
VERSION=${VERSION:-1.2.0}
BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
SIGN=${SIGN_IDENTITY:--}

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  swift build -c "$CONFIG" --arch arm64 --arch x86_64
  BIN=$(swift build -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path)/Cirrus
else
  swift build -c "$CONFIG"
  BIN=$(swift build -c "$CONFIG" --show-bin-path)/Cirrus
fi

[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift Resources

APP="$OUTPUT/Cirrus.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cirrus"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Cirrus</string>
  <key>CFBundleDisplayName</key><string>Cirrus</string>
  <key>CFBundleExecutable</key><string>Cirrus</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>Cirrus — a Finder for iCloud. Inspired by rclone and icloudpd.</string>
  <key>NSPhotoLibraryUsageDescription</key><string>Cirrus shows and exports the photos in this Mac’s Photos library (iCloud Photos when it’s on), and imports photos you drop into it.</string>
  <key>NSPhotoLibraryAddUsageDescription</key><string>Cirrus imports the photos and videos you drop into your Photos library.</string>
  <key>NSCameraUsageDescription</key><string>Cirrus browses and imports photos from connected iPhones, iPads and cameras.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Cirrus browses external drives and backs up iCloud to them.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>Cirrus can browse and back up to network drives.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Cirrus connects to the Nextcloud, Immich, WebDAV or S3 servers you add, including ones on your home network.</string>
  <key>NSDesktopFolderUsageDescription</key><string>Cirrus browses your Desktop like Finder.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Cirrus browses your Documents like Finder.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Cirrus saves downloads from iCloud to your Downloads folder.</string>
  <key>NSUserNotificationAlertStyle</key><string>banner</string>
  <key>CirrusTesterBuild</key><$([[ "${TESTER:-0}" == "1" ]] && echo true || echo false)/>
</dict></plist>
PLIST
codesign --force --sign "$SIGN" --timestamp=none "$APP"
codesign --verify --strict "$APP"
lipo -archs "$APP/Contents/MacOS/Cirrus" | sed 's/^/arch: /'
du -sh "$APP" | sed 's/^/size: /'
echo "built $APP ($CONFIG, signed: $SIGN)"
