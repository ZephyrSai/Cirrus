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
    Google/  GoogleAuth.cs (loopback PKCE sign-in), GoogleApi.cs (tokens, retries, back-off), GoogleCredentials.cs (DPAPI
             store, Windows Hello gate), GoogleDrive.cs, GooglePhotos.cs (+ capture-date probe), GooglePicker.cs,
             Takeout.cs (in-process .zip/.tgz reader), JournalStore.cs (crash-safe manifests), Migration.cs (iCloud → Google),
             GoogleImport.cs (Google → iCloud)
  src/Cirrus.App/                net10.0-windows10.0.19041.0, WPF, Fluent theme following Windows light/dark
    UI/      MainWindow (sidebar, tabs, path bar, toolbar, status bar), BrowserTab (details / icons / photo grid by
             month), TransfersPanel, SignInWindow, LocationPicker (Copy/Move To…), BackupWindow, SyncJobsWindow, SettingsWindow,
             MigrationWindow (Move to or from Google), GoogleSetupWindow (the Google Cloud console steps)
    Services/ Ops.cs (copy/move matrix with preflight and conflict handling), Thumbnails.cs, GoogleAccounts.cs
    Platform/ Native.cs (Windows Hello / Windows password, keep-awake, shell icons), DragOut.cs (lazy drag to Explorer)
  tests/Cirrus.Core.Tests/       xUnit; reuses Tests/CirrusCoreTests/Fixtures/{srp,bigint}-vectors.txt
    Fakes/   FakeGoogle.cs (fake OAuth/Drive/Photos/Picker server as an HttpMessageHandler; also linked into Debug app
             builds for the demo), TakeoutFixture.cs (synthetic Takeout export as .zip, .tgz or a folder)
```

### Runtime switches (both platforms)

Release builds honour only the user-facing switches, `CIRRUS_DEMO` and `CIRRUS_PROFILE`. Every other `CIRRUS_*` variable is a test or automation hook and works only in Debug builds and the unit tests. Another process therefore can't redirect, script or eavesdrop on a signed-in Cirrus.

| Variable | Builds | Effect |
|---|---|---|
| `CIRRUS_DEMO=1` | all | Adds a disk-backed demo iCloud (Drive + Photos), so everything can be tried without an Apple ID. It never touches real accounts. Windows Debug builds also get a demo Google account (the tests' fake server) for Move to or from Google; Release builds always talk to the real Google. |
| `CIRRUS_PROFILE=<name>` | all | Separate settings, caches and secrets (`Cirrus-<name>`). |
| `CIRRUS_DEMO_FAST=1`, `CIRRUS_DEMO_PHOTOS=<n>` | Debug | Demo without simulated network delays; size of the demo library. |
| `CIRRUS_DEBUG=1` | Debug | Verbose logging to stderr, including lines that may name files. |
| `CIRRUS_NATIVE_DRIVE`, `CIRRUS_NATIVE_PHOTOS` | Debug | Windows: treat these folders as the iCloud for Windows iCloud Drive and Photos folders. They are read-only-protected like the real ones. |
| `CIRRUS_DATA_DIR` | Debug | Windows/Core: base folder for all Cirrus data. The tests point it at a temp folder. |

### Windows-specific behaviour

- **One Cirrus at a time.** Before any window, setting or account exists, `App.OnStartup` takes a per-user named mutex, `Local\Cirrus.SingleInstance.<user SID>`. It is the same for every build, tester flavour and `CIRRUS_PROFILE`, and it isn't a file in a profile folder. A second launch lets the running Cirrus take the foreground, asks it through a named pipe only the same user can open (`PipeOptions.CurrentUserOnly`) to restore and focus its window, and quits without touching settings or logs. A Cirrus.exe from before the lock existed, running in the same session, is brought forward the same way. There is no override. The tests use private lock names and never start Cirrus.exe; `build-windows.ps1 -Run` doesn't start one while another is running.

- **Saved passwords** are encrypted with DPAPI (current user) under `%LOCALAPPDATA%\Cirrus\Secrets`. File names are hashes, so no Apple IDs appear on disk. A saved password is only released after Windows Hello (`UserConsentVerifier`), or the Windows account password when Hello isn't set up. This can be turned off in Settings.
- **Removals.** Local removals go to the Recycle Bin, through Explorer's own dialogs, so Windows asks before anything would be deleted permanently. Windows deletes permanently instead of recycling in some cases: USB sticks, network shares, items bigger than the bin, paths that are too long, and bins or policies set to "don't move files to the Recycle Bin". In those cases Cirrus moves the item into `.cirrus\Removed\<date>\` next to it. iCloud removals go to Recently Deleted. "Delete Immediately" exists only inside iCloud Drive's Recently Deleted, and it asks first.
- **Names.** iCloud allows names that NTFS doesn't (`: * ? " < > | \`, trailing dots or spaces, `CON` and other device names). On disk, Cirrus stores each such character as U+F000 plus its code (the mapping WSL and Cygwin use), and maps it back for iCloud. The mapping is exactly reversible, and real full-width names such as `メモ：会議.txt` are left untouched, so syncs stay stable.
- **Sync safety.** Names match case-insensitively, so a case-only rename is never a delete. A folder that can't be read, or an incomplete iCloud listing, stops the run instead of looking empty. A two-way side that suddenly empties trips the delete guard. The guard counts every item inside removed folders, and also applies to backups that don't keep deleted files. A file edited after the scan is never overwritten.
- **iCloud for Windows.** When it's installed, `%USERPROFILE%\iCloudDrive` and `Pictures\iCloud Photos` appear as native locations. They count as iCloud for read-only mode, including when Pictures is redirected. So does any folder that *contains* one of them, so removing or moving such a folder is refused while read-only mode is on. They offer "Always Keep on This Device" and "Free Up Space".

- **Caching.** Opening a place never starts from scratch.
  - iCloud Drive listings stay in memory for 60 s, album lists for 300 s.
  - iCloud Drive folders are also cached on disk and shown at once while they refresh.
  - Album contents are cached on disk with their CloudKit sync token. Within 5 minutes they open with no network at all. After that, one `changes/zone` call decides whether the cached copy is still current.
  - Album lists are trusted for 10 minutes, library lists for a day.
  - F5 (or Ctrl+R / Refresh) skips every cache.
  - Favorite, hide and delete edits patch the cached listings in place. Favorites, Hidden and Recently Deleted are listed again.
- **Privacy.**
  - The log file holds only content-free status lines (HTTP status lines, timings, counts, error types), never file or album names. Lines that may name files go to stderr only, in Debug builds with `CIRRUS_DEBUG`.
  - `%LOCALAPPDATA%\Cirrus` is owner-only: inheritance off, access for the current user and SYSTEM.
  - Caches use hashed names. Thumbnails are kept per account and cache version (`v2`); older versions are pruned.
  - Preview, relay and temporary copies are removed after a day. Copies of iCloud files that were opened are recycled after two weeks, since they may hold edits.
  - Signing out wipes that account's listings, thumbnails and preview copies, recycles its opened copies, and forgets the Apple ID. Opened and preview copies are kept per account, so other accounts are untouched.
  - Drag-out copies are also recycled rather than deleted, because apps often edit a dropped file in place.
- **Network.**
  - 30-second request and stall timeouts.
  - Dropped connections and server errors are retried only for safe calls: GETs, listings and lookups. A change is repeated only after `429 Too Many Requests`, which means it wasn't processed. An upload is repeated only when it never left this PC (name lookup or TLS failure). Moves, deletions, photo edits and uploads are never sent twice.
  - Photo imports record each file as done right after its own upload, so a Retry never imports a photo twice.
  - iCloud cookies are sent only to Apple's own hosts.
  - Downloads stream with real progress.
  - The shared Photos library is looked up in parallel, with a 6-second limit.
- **Previews.**
  - iCloud Drive images and PDFs up to 25 MB are downloaded once into the preview cache and shown in the list and icon views (Settings › Browsing). iCloud.com has no thumbnail API.
  - PDFs, videos and other files use Explorer's own thumbnails.
  - Large photo previews fall back to the original (≤ 20 MB, cached as JPEG) when iCloud has no medium rendition.

- **Move to or from Google** (port of the Mac's Google move).
  - *Sign-in.* Bring your own "Desktop app" OAuth client (the setup window walks through the eight Google Cloud console steps). Google's page opens in the default browser and answers on a one-shot listener bound to `127.0.0.1` only (exclusive port), with PKCE S256 and a random state.
  - *Secrets.* The client ID and secret, the account list and refresh tokens are DPAPI-encrypted in the same store as saved Apple ID passwords. A refresh token is released only after Windows Hello or the Windows password, under the same Settings switch. Reconnecting replaces the saved token without revoking the old one (a revoke would end the whole grant); Disconnect revokes it.
  - *Privacy.* The access token is attached only to Google's own hosts (`*.googleapis.com`, `*.googleusercontent.com`, `accounts/docs/drive.google.com`). Redirects are followed only for downloads (GET, https, at most three hops). Logs carry method, host, path and status, never tokens, codes, secrets or addresses.
  - *Safety.* iCloud → Google only reads iCloud. Google → iCloud only adds: a replaced copy goes to the Recycle Bin (iCloud for Windows folder) or Recently Deleted (iCloud.com), and read-only mode stops the run before the first write (checked again inside the engine and the backends). Drive replacements in Google go to Google Drive's trash. The two directions skip each other's output ("From Google Drive", "From Google Photos", Cirrus's "From iCloud" folder, and photos the other direction sent).
  - *Takeout.* Read in-process: `.zip` with System.IO.Compression, `.tgz`/`.tar.gz`/`.tar` with System.Formats.Tar over GZipStream (no tar.exe). `.tbz`/`.bz2` parts are refused with a hint to choose .zip or .tgz. Sidecars are read while listing; media are unpacked a batch at a time (about 1 GB, or the largest item), each under a name Cirrus chooses; members with `..`, absolute or drive-letter paths are left out, and a member that inflates beyond its header is refused.
  - *State.* Resumable journals (one per iCloud + Google account pair) in `%LOCALAPPDATA%\Cirrus\migration`; staging per pair in `Cache\migration-staging`, cleared at the start and end of every run. Only one run per pair and direction at a time (a reopened window or a Retry can't start a second), and the limits are checked again at the start of every run against what's still left.
  - *This PC's disk.* With iCloud for Windows, Check Space also counts this PC: a Google → iCloud copy must fit on the drive of the iCloud Drive folder, and files that are only in iCloud count when moving to Google (iCloud for Windows downloads them and keeps them).
  - *Loop markers.* The "From iCloud" folder carries a private tag and a public `cirrusRole` property, since private tags can't be read by a Cirrus using another Google Cloud project; an untagged root folder named "From iCloud" is also left out, with a warning. Photos are recorded one by one as iCloud takes them, so a later failure never sends one twice.
  - *Capture dates — different from the Mac.* The Mac writes Google's capture date, place and caption into the staged copy (ImageIO/AVFoundation). No small, MIT-licensed, well-maintained managed EXIF/XMP writer was found, so Windows doesn't rewrite files: the staged copy's modification time is set to Google's capture date, and iCloud.com's upload sends it as `lastModDate`, which iCloud uses for files without a date of their own. Files that carry their own date (most camera originals) keep it. Places and captions from Google are not written; the check warns when the export has any. For iCloud → Google, a read-only probe (EXIF in JPEG/PNG/TIFF/HEIC, the movie header in MOV/MP4) decides whether the date also goes into the Google Photos description, as on the Mac.
  - *Accounts.* Photos need an Apple ID signed in inside Cirrus (iCloud for Windows has no Photos API Cirrus can write to); the iCloud for Windows iCloud Drive folder works for Drive in both directions.

### What can be verified where

On the Mac: the Core tests (`dotnet test`) and that both Windows builds compile and publish. The tests cover:

- SRP against independent vectors.
- A full sign-in, two-factor, trust and re-auth flow against a fake Apple server, including that no secrets reach the log.
- Planner rules, a local two-way round trip, mirroring into the demo drive, and the photo export layout and incremental runs.
- Read-only mode, safe replace, and the removal and preflight rules.
- Regression tests from two independent safety audits: case-only renames, vanished sides, unreadable folders, reversible names, and edits made during a run.
- Mac-parity behaviour:
  - 24 concurrent downloads each keep their own bytes.
  - Album caches with sync-token checks, in-place patching, Drive and list caches.
  - The log file stays free of names, caches are owner-only, and sign-out wipes them. Opened copies are recycled after two weeks.
  - Release lock-down of `CIRRUS_*` switches.
  - Retries only for safe calls.
  - Shared-library lookup can't stall discovery.
- Move to or from Google, against the fake Google server: loopback PKCE sign-in, denied consent and forged state, token refresh and reconnect, back-off and daily caps, resumable Drive and Photos uploads that survive dropped connections, 50-item batches and albums, quotas, interrupted runs that resume the same session, Takeout parsing as .zip, .tgz and a folder (sidecar naming generations, duplicates, edited copies, Live Photo pairs, trashed items), the Takeout and picker imports, Drive copies with Docs exports and Recycle-Bin replacement, read-only mode, loop protection between the directions, hostile archive names, token host scoping, log hygiene and the DPAPI-store layout. A headless demo runs both directions end to end against the demo iCloud (`dotnet test --filter GoogleDemoTests --logger "console;verbosity=detailed"`).

These need real Google: the consent flow in a browser, real quotas and rate limits, export-link redirects and picker downloads from Google's content servers.

These need a Windows PC: the whole WPF UI, Windows Hello and the Windows-password fallback, DPAPI, the owner-only folder permissions, the Recycle Bin, drag and drop to and from Explorer, shell icons and thumbnails, JPEG re-encoding of large previews, iCloud for Windows integration, and the Move to or from Google window (browser hand-off, file pickers, progress).
