<#
.SYNOPSIS
  Builds Cirrus for Windows on Windows: runs the Core unit tests, publishes Cirrus.exe for win-x64 and
  win-arm64 (self-contained, single file), zips each to build\dist\Cirrus-<version>[-tester]-win-<arch>.zip
  and prints SHA-256s.

.EXAMPLE
  .\scripts\build-windows.ps1                         # release build, both architectures
  .\scripts\build-windows.ps1 -Tester -Version 1.0.1  # tester build (starts in read-only iCloud mode)
  .\scripts\build-windows.ps1 -Archs x64 -SkipTests
  .\scripts\build-windows.ps1 -CertificateThumbprint ABC123...   # also Authenticode-sign Cirrus.exe with signtool
  .\scripts\build-windows.ps1 -Run                    # build x64 and start it in demo mode (CIRRUS_DEMO=1)
#>
param(
  [string]$Version = "1.0.0",
  [switch]$Tester,
  [string[]]$Archs = @("x64", "arm64"),
  [switch]$SkipTests,
  [string]$CertificateThumbprint = "",
  [string]$TimestampUrl = "http://timestamp.digicert.com",
  [switch]$Run
)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"; $env:DOTNET_NOLOGO = "1"
$dotnetCmd = Get-Command dotnet -ErrorAction SilentlyContinue   # works in Windows PowerShell 5.1 and PowerShell 7
if (-not $dotnetCmd) { throw "dotnet not found; install the .NET 10 SDK (winget install Microsoft.DotNet.SDK.10)" }
$dotnet = $dotnetCmd.Source
$testerFlag = if ($Tester) { "true" } else { "false" }
$suffix = if ($Tester) { "-tester" } else { "" }
$out = Join-Path $Root "build\dist"
$stage = Join-Path $Root "build\windows"
New-Item -ItemType Directory -Force -Path $out, $stage | Out-Null

if (-not $SkipTests) {
  Write-Host "== Core tests"
  & $dotnet test windows\tests\Cirrus.Core.Tests\Cirrus.Core.Tests.csproj -c Release --nologo -v quiet
  if ($LASTEXITCODE -ne 0) { throw "tests failed" }
}

$zips = @()
foreach ($arch in $Archs) {
  $rid = "win-$arch"
  $pub = Join-Path $stage $rid
  Write-Host "== Publishing $rid ($(if ($Tester) {'tester'} else {'release'}) build, version $Version)"
  if (Test-Path $pub) { Remove-Item -Recurse -Force $pub }   # build output only
  & $dotnet publish windows\src\Cirrus.App\Cirrus.App.csproj -c Release -r $rid --self-contained true --nologo -v quiet `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true `
    -p:DebugType=none -p:Version=$Version -p:CirrusTester=$testerFlag -o $pub
  if ($LASTEXITCODE -ne 0) { throw "publish failed for $rid" }
  $exe = Join-Path $pub "Cirrus.exe"
  if (-not (Test-Path $exe)) { throw "publish produced no Cirrus.exe for $rid" }
  if ($CertificateThumbprint) {
    $signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
    if (-not $signtool) { throw "signtool.exe not found (install the Windows SDK)" }
    & $signtool.FullName sign /sha1 $CertificateThumbprint /fd SHA256 /tr $TimestampUrl /td SHA256 $exe
    if ($LASTEXITCODE -ne 0) { throw "signing failed" }
  }
  $readme = @"
Cirrus $Version for Windows ($arch)$(if ($Tester) {' - tester build'})

A Finder-style browser for iCloud Drive and iCloud Photos: drag and drop, transfers, sync jobs and
full iCloud backups. OneDrive, Google Drive, Dropbox, Nextcloud, WebDAV, S3-compatible storage and
Immich can sit beside it (Add Account in the sidebar), with copies and moves between any of them.
Requires Windows 10 (version 2004 or later) or Windows 11. No install needed:
unzip anywhere and run Cirrus.exe. Settings and logs live in %LOCALAPPDATA%\Cirrus.
Only one Cirrus runs at a time: opening it again (any copy or build) brings the running one forward.
$(if ($Tester) {"`r`nThis tester build starts in read-only mode: nothing in iCloud can change until you turn that`r`noff in Settings > Safety. Browsing, downloading, exporting and backing up still work.`r`n"})
$(if (-not $CertificateThumbprint) {"The app isn't code-signed, so Windows SmartScreen may say it ""protected your PC"". Choose`r`nMore info > Run anyway.`r`n"})
Try it without an Apple ID: quit Cirrus if it's open, then in a terminal run
    set CIRRUS_DEMO=1 && Cirrus.exe
"@
  Set-Content -Path (Join-Path $pub "README.txt") -Value $readme -Encoding UTF8
  $zip = Join-Path $out "Cirrus-$Version$suffix-win-$arch.zip"
  if (Test-Path $zip) { Remove-Item -Force $zip }   # previous build artefact
  Compress-Archive -Path $exe, (Join-Path $pub "README.txt") -DestinationPath $zip
  $zips += $zip
  "   {0:N1} MB Cirrus.exe -> {1}" -f ((Get-Item $exe).Length / 1MB), (Resolve-Path -Relative $zip)
}

Write-Host ""
Write-Host "== SHA-256"
foreach ($z in $zips) { "{0}  {1}" -f (Get-FileHash -Algorithm SHA256 $z).Hash.ToLower(), (Split-Path -Leaf $z) }

if ($Run) {
  # Only one Cirrus may run at a time (Cirrus enforces it too): never start a second one from here.
  if (Get-Process -Name Cirrus -ErrorAction SilentlyContinue) {
    Write-Host "Cirrus is already running; quit it first to try the new build (a second launch would only bring it forward)."
  } else {
    $exe = Join-Path $stage "win-$($Archs[0])\Cirrus.exe"
    $env:CIRRUS_DEMO = "1"
    Start-Process $exe
  }
}
