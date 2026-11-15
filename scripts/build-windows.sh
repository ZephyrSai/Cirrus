#!/bin/zsh
# Builds Cirrus for Windows from this Mac (no Windows machine needed):
#   1. runs the cross-platform Core unit tests (windows/tests/Cirrus.Core.Tests),
#   2. publishes Cirrus.exe for win-x64 and win-arm64 (self-contained, single file, .NET runtime included),
#   3. zips each to build/dist/Cirrus-<version>[-tester]-win-<arch>.zip and prints SHA-256s.
#
#   VERSION=1.0.0       version stamped into Cirrus.exe and the zip names
#   TESTER=1            tester build: starts in read-only iCloud mode (recommended when handing it to testers)
#   ARCHS="x64 arm64"   Windows architectures to build
#   SKIP_TESTS=1        skip the unit tests
#   DOTNET=<path>       dotnet to use (default: dotnet on PATH, else /opt/homebrew/bin/dotnet); needs the .NET 10 SDK
set -euo pipefail
cd "${0:A:h}/.."
ROOT=$PWD
DOTNET=${DOTNET:-$(command -v dotnet 2>/dev/null || echo /opt/homebrew/bin/dotnet)}
VERSION=${VERSION:-1.0.0}
ARCHS=(${=ARCHS:-x64 arm64})
if [[ "${TESTER:-0}" == "1" ]]; then TESTER_FLAG=true; SUFFIX="-tester"; else TESTER_FLAG=false; SUFFIX=""; fi
OUT=$ROOT/build/dist
STAGE=$ROOT/build/windows
mkdir -p "$OUT" "$STAGE"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1

"$DOTNET" --version >/dev/null || { echo "dotnet not found; install the .NET 10 SDK (brew install dotnet)"; exit 1; }

if [[ "${SKIP_TESTS:-0}" != "1" ]]; then
  echo "== Core tests"
  "$DOTNET" test windows/tests/Cirrus.Core.Tests/Cirrus.Core.Tests.csproj -c Release --nologo -v quiet
fi

typeset -a ZIPS
for ARCH in $ARCHS; do
  RID=win-$ARCH
  PUB=$STAGE/$RID
  echo "== Publishing $RID ($([[ $TESTER_FLAG == true ]] && echo tester || echo release) build, version $VERSION)"
  rm -rf "$PUB"
  "$DOTNET" publish windows/src/Cirrus.App/Cirrus.App.csproj -c Release -r "$RID" --self-contained true --nologo -v quiet \
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true \
    -p:DebugType=none -p:Version="$VERSION" -p:CirrusTester=$TESTER_FLAG -o "$PUB"
  [[ -f "$PUB/Cirrus.exe" ]] || { echo "publish produced no Cirrus.exe for $RID"; exit 1; }
  cat > "$PUB/README.txt" <<TXT
Cirrus $VERSION for Windows ($ARCH)$([[ $TESTER_FLAG == true ]] && echo " — tester build")

A Finder-style browser for iCloud Drive and iCloud Photos: drag and drop, transfers, sync jobs and
full iCloud backups. Requires Windows 10 (version 2004 or later) or Windows 11. No install needed:
unzip anywhere and run Cirrus.exe. Settings and logs live in %LOCALAPPDATA%\\Cirrus.

$([[ $TESTER_FLAG == true ]] && echo "This tester build starts in read-only mode: nothing in iCloud can change until you turn that
off in Settings > Safety. Browsing, downloading, exporting and backing up still work.
")
The app isn't code-signed, so Windows SmartScreen may say it "protected your PC". Choose
More info > Run anyway.

Try it without an Apple ID: in a terminal, run
    set CIRRUS_DEMO=1 && Cirrus.exe
TXT
  ZIP=$OUT/Cirrus-$VERSION$SUFFIX-win-$ARCH.zip
  rm -f "$ZIP"
  (cd "$PUB" && zip -q -X -r "$ZIP" Cirrus.exe README.txt)
  ZIPS+=("$ZIP")
  echo "   $(du -h "$PUB/Cirrus.exe" | cut -f1) Cirrus.exe -> ${ZIP#$ROOT/}"
done

echo
echo "== SHA-256"
(cd "$OUT" && shasum -a 256 ${ZIPS:t})
echo
echo "Built on $(uname -s); WPF UI, Windows Hello/DPAPI and drag and drop need a Windows PC to test."
