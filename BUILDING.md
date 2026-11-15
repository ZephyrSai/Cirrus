# Building Cirrus

Cirrus ships as two native apps that share one design:

| | macOS | Windows |
|---|---|---|
| UI | Swift / AppKit (`Sources/Cirrus`) | C# / WPF (`windows/src/Cirrus.App`) |
| Engine | `Sources/CirrusCore` (Swift) | `windows/src/Cirrus.Core` (C#, cross-platform port of CirrusCore) |
| Tests | `Tests/CirrusCoreTests` (Swift Testing) | `windows/tests/Cirrus.Core.Tests` (xUnit; runs on macOS, Linux and Windows) |
| Output | `build/Cirrus.app`, `build/dist/Cirrus-<version>[-tester]-mac.{dmg,zip}` | `build/dist/Cirrus-<version>[-tester]-win-{x64,arm64}.zip` |

Both apps reach iCloud the same way: they sign in like iCloud.com (SRP-6a, two-factor, Advanced Data Protection consent) or use the computer's own iCloud (the Mac's iCloud Drive and Photos, or the iCloud for Windows folders).

Both apps enforce the same safety rules in the engine:

- **Read-only mode.** Tester builds start with it on.
- **Recoverable removals only.** Removed items go to the Trash or Recycle Bin, or to iCloud's Recently Deleted.
- **Upload, then replace.** A replacement is uploaded under a temporary name before the old copy is retired.
- **Size preflight** before any transfer.

---

## macOS

Requirements: Xcode 16 or later (Swift 6 toolchain) on macOS 14 or later.

```bash
scripts/test.sh                      # swift test
scripts/build-app.sh                 # build/Cirrus.app (release, ad-hoc signed, this Mac's architecture)
scripts/package-mac.sh               # universal app → build/dist/Cirrus-<version>-mac.dmg and .zip, with SHA-256s
```

### `scripts/build-app.sh`

| Variable | Default | Meaning |
|---|---|---|
| `SIGN_IDENTITY` | `-` (ad-hoc) | Code-signing identity (SHA-1 or name). Use a *Developer ID Application* identity so other Macs open it without warnings. |
| `UNIVERSAL` | `0` | `1` builds arm64 + x86_64. |
| `CONFIG` | `release` | `debug` or `release`. |
| `OUTPUT` | `build` | Output folder for `Cirrus.app`. |
| `BUNDLE_ID` | `io.github.zephyrsai.cirrus` | Bundle identifier. |
| `VERSION` | `1.0.0` | `CFBundleShortVersionString`. |
| `TESTER` | `0` | `1` = tester build: starts in read-only iCloud mode. |

### `scripts/package-mac.sh`

Builds a universal app with `build-app.sh`, then writes `build/dist/Cirrus-<version>[-tester]-mac.zip` and `.dmg` and prints their SHA-256s. It accepts `SIGN_IDENTITY`, `TESTER` and `VERSION`, plus:

- `NOTARY_PROFILE=<name>` notarizes and staples with `xcrun notarytool`. This needs a Developer ID identity and a one-time `xcrun notarytool store-credentials <name>`.

Without notarization, other Macs need **System Settings › Privacy & Security › Open Anyway** the first time.

```bash
TESTER=1 SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=cirrus scripts/package-mac.sh
```

---

## Windows

The Windows app is a separate C#/.NET 10 WPF app. It needs Windows 10 version 2004 (build 19041) or later, or Windows 11, on x64 or Arm64. It is self-contained: the .NET runtime is bundled into one `Cirrus.exe`, so nothing needs installing.

### Building on a Mac (no Windows needed)

Requirements: the .NET 10 SDK (`brew install dotnet`, or the installer from dot.net). The WPF project sets `EnableWindowsTargeting=true`, so it compiles and publishes from macOS.

```bash
scripts/build-windows.sh                       # tests, then win-x64 + win-arm64 zips with SHA-256s
TESTER=1 VERSION=1.0.1 scripts/build-windows.sh
ARCHS=x64 SKIP_TESTS=1 scripts/build-windows.sh
```

| Variable | Default | Meaning |
|---|---|---|
| `VERSION` | `1.0.0` | Version stamped into `Cirrus.exe` and the zip names. |
| `TESTER` | `0` | `1` = tester build: starts in read-only iCloud mode. Zips are named `…-tester-win-<arch>.zip`. |
| `ARCHS` | `x64 arm64` | Windows architectures to publish. |
| `SKIP_TESTS` | `0` | `1` skips the Core unit tests. |
| `DOTNET` | `dotnet` on PATH | Path to the `dotnet` executable. |

The script runs these steps:

1. `dotnet test windows/tests/Cirrus.Core.Tests`.
2. `dotnet publish` for each architecture: `-r win-<arch> --self-contained`, `PublishSingleFile`, `IncludeNativeLibrariesForSelfExtract`, `EnableCompressionInSingleFile`.
3. Zips `Cirrus.exe` and a `README.txt` into `build/dist/`.
4. Prints SHA-256s.

Intermediate output goes to `build/windows/win-<arch>/`. Each `Cirrus.exe` is about 65 MB.

### Building on Windows

Requirements: the .NET 10 SDK (`winget install Microsoft.DotNet.SDK.10`). Code signing also needs the Windows SDK (for `signtool`).

```powershell
.\scripts\build-windows.ps1                              # tests, then both zips with SHA-256s
.\scripts\build-windows.ps1 -Tester -Version 1.0.1
.\scripts\build-windows.ps1 -Archs x64 -SkipTests -Run   # build and start it in demo mode
.\scripts\build-windows.ps1 -CertificateThumbprint <sha1> # also Authenticode-sign Cirrus.exe
```

The parameters match the shell script: `-Version`, `-Tester`, `-Archs`, `-SkipTests`. Three extras:

- `-CertificateThumbprint` and `-TimestampUrl`: sign with `signtool`.
- `-Run`: start the first architecture with `CIRRUS_DEMO=1`.

The script works in Windows PowerShell 5.1 and PowerShell 7. Unsigned builds trigger SmartScreen ("Windows protected your PC" › More info › Run anyway).

For day-to-day work, open `windows/Cirrus.Windows.sln` in Visual Studio 2022 17.14+ (or Rider), or run:

```powershell
dotnet run --project windows\src\Cirrus.App
dotnet test windows\tests\Cirrus.Core.Tests
```

### Project layout

```
windows/
  Cirrus.Windows.sln
  Directory.Build.props          shared settings (version, nullable, C# latest)
  src/Cirrus.Core/               net10.0, cross-platform engine (port of Sources/CirrusCore)
    Auth/    SRP.cs (Apple SRP-6a, s2k/s2k_fo), ICloudSession.cs (idmsa sign-in, 2FA, trust, accountLogin,
             cookie jar, re-auth on 401/421, ADP/PCS consent, back-off, network retries), Secrets.cs (DPAPI store,
             Windows Hello gate for saved passwords)
    Drive/   Drive.cs (drivews/docws; upload/web → multipart → update/documents; trash, restore, Delete Immediately)
    Photos/  Photos.cs, WebPhotos.cs (CloudKit queries, parallel startRank partitions, resources, records/modify)
    Sync/    SyncEngine.cs (planner: copy/mirror/two-way with baseline, conflicts keep both; runner; Local/Drive sides),
             Backup.cs (PhotoExporter, BackupEngine), Jobs.cs (job preview/run, scheduler), SyncModels.cs
    Transfers/ TransferManager.cs (queue, speed/ETA), Preflight.cs (size limits)
    Model/   Accounts.cs, Settings.cs, Demo.cs + DemoArt.cs (CIRRUS_DEMO backends), Errors.cs
    Util/    Safety.cs (read-only mode, SafeReplace), LocalFiles.cs (Recycle Bin, never-delete fallback, cloud
             placeholders), VolumeInfo.cs, Paths.cs (+ WinNames: reversible mapping for names NTFS can't store), Json.cs, Log.cs
  src/Cirrus.App/                net10.0-windows10.0.19041.0, WPF, Fluent theme following Windows light/dark
    UI/      MainWindow (sidebar, tabs, path bar, toolbar, status bar), BrowserTab (details / icons / photo grid by
             month), TransfersPanel, SignInWindow, LocationPicker (Copy/Move To…), BackupWindow, SyncJobsWindow, SettingsWindow
    Services/ Ops.cs (copy/move matrix with preflight and conflict handling), Thumbnails.cs
    Platform/ Native.cs (Windows Hello / Windows password, keep-awake, shell icons), DragOut.cs (lazy drag to Explorer)
  tests/Cirrus.Core.Tests/       xUnit; reuses Tests/CirrusCoreTests/Fixtures/{srp,bigint}-vectors.txt
```

### Runtime switches (both platforms)

| Variable | Effect |
|---|---|
| `CIRRUS_DEMO=1` | Adds a disk-backed demo iCloud (Drive + Photos), so everything can be tried without an Apple ID. It never touches real accounts. |
| `CIRRUS_DEMO_FAST=1` | Demo without simulated network delays. |
| `CIRRUS_DEBUG=1` | Verbose logging to stderr. The Windows log is always in `%LOCALAPPDATA%\Cirrus\Logs`. Logs are scrubbed of passwords, cookies, tokens and Apple IDs. |
| `CIRRUS_PROFILE=<name>` | Separate settings, caches and secrets (`Cirrus-<name>`). |
| `CIRRUS_NATIVE_DRIVE`, `CIRRUS_NATIVE_PHOTOS` | Windows: treat these folders as the iCloud for Windows iCloud Drive and Photos folders. They are read-only-protected like the real ones. |
| `CIRRUS_DATA_DIR` | Windows/Core: base folder for all Cirrus data. The tests point it at a temp folder. |

### Windows-specific behaviour

- **Saved passwords** are encrypted with DPAPI (current user) under `%LOCALAPPDATA%\Cirrus\Secrets`. File names are hashes, so no Apple IDs appear on disk. A saved password is only released after Windows Hello (`UserConsentVerifier`), or the Windows account password when Hello isn't set up. This can be turned off in Settings.
- **Removals.** Local removals go to the Recycle Bin. Windows deletes permanently instead of recycling in some cases: USB sticks, network shares, items bigger than the bin, and bins set to "don't move files to the Recycle Bin". In those cases Cirrus moves the item into `.cirrus\Removed\<date>\` next to it. iCloud removals go to Recently Deleted. "Delete Immediately" exists only inside iCloud Drive's Recently Deleted, and it asks first.
- **Names.** iCloud allows names that NTFS doesn't (`: * ? " < > | \`, trailing dots or spaces). Cirrus maps those characters to look-alike full-width characters on disk and back again, so syncs stay stable.
- **iCloud for Windows.** When it's installed, `%USERPROFILE%\iCloudDrive` and `Pictures\iCloud Photos` appear as native locations. They count as iCloud for read-only mode, and they offer "Always Keep on This Device" and "Free Up Space".

### What can be verified where

On the Mac: the Core tests (`dotnet test`) and that both Windows builds compile and publish. The tests cover:

- SRP against independent vectors.
- A full sign-in, two-factor, trust and re-auth flow against a fake Apple server, including that no secrets reach the log.
- Planner rules, a local two-way round trip, mirroring into the demo drive, and the photo export layout and incremental runs.
- Read-only mode, safe replace, and the removal and preflight rules.

These need a Windows PC: the whole WPF UI, Windows Hello and the Windows-password fallback, DPAPI, the Recycle Bin, drag and drop to and from Explorer, shell icons, and iCloud for Windows integration.
