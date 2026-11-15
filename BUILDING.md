# Building Cirrus

Cirrus ships as native apps that share one design:

| | macOS | iPhone and iPad | Windows |
|---|---|---|---|
| UI | Swift / AppKit (`Sources/Cirrus`) | SwiftUI (`ios/Cirrus`) | C# / WPF (`windows/src/Cirrus.App`) |
| Engine | `Sources/CirrusCore` (Swift) | the same `Sources/CirrusCore`, as a Swift package product | `windows/src/Cirrus.Core` (C#, cross-platform port of CirrusCore) |
| Tests | `Tests/CirrusCoreTests` (Swift Testing) | the engine tests (run on the Mac) | `windows/tests/Cirrus.Core.Tests` (xUnit; runs on macOS, Linux and Windows) |
| Output | `build/Cirrus.app`, `build/dist/Cirrus-<version>[-tester]-mac.{dmg,zip}` | `build/ios/Cirrus.app`, optionally `build/dist/Cirrus-<version>[-tester]-ios.ipa` | `build/dist/Cirrus-<version>[-tester]-win-{x64,arm64}.zip` |

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

## iPhone and iPad

Cirrus for iOS isn't on the App Store. You build it yourself and install it on your own devices, or hand it to testers as an ad hoc build or through internal TestFlight.

Requirements:
- Xcode 26 or later, with the iOS 26 SDK. That SDK has `BGContinuedProcessingTask`; it was built and tested here with Xcode 27.2.
- Devices: iOS or iPadOS 17 or later.

The project is `ios/Cirrus.xcodeproj`, which is hand-maintained and committed:
- The app target, `CirrusMobile`, uses a *synchronized folder*: every file under `ios/Cirrus/` is compiled, with no project edits needed.
- It links the engine as the `CirrusCore` product of the local Swift package at the repository root, the same sources as the Mac app.
- `Info.plist` is `ios/Support/Info.plist`.

### Build and install from Xcode

1. Open `ios/Cirrus.xcodeproj`, choose the **Cirrus** scheme and your iPhone or iPad.
2. In **CirrusMobile › Signing & Capabilities**, choose a **Team**:
   - **Free Apple ID.** Add it in Xcode › Settings › Accounts; it appears as "*Your Name* (Personal Team)".
     - Change the **Bundle Identifier** to one nobody has used, e.g. `io.github.<you>.cirrus`.
     - Apps signed this way expire after **7 days**. Run from Xcode again to re-sign; your data stays.
     - At most 3 such apps per device. No ad hoc or TestFlight.
   - **Paid Apple Developer Program** account. Builds last a year, and you get ad hoc and TestFlight distribution.
3. On the device:
   - Turn on **Settings › Privacy & Security › Developer Mode** and restart when asked.
   - With a free account, also trust yourself once in **Settings › General › VPN & Device Management**.
4. Press **Run**.

### `scripts/build-ios.sh`

| Variable | Default | Meaning |
|---|---|---|
| `TEAM_ID` | none: unsigned | Your team ID (Xcode › Settings › Accounts, or developer.apple.com › Membership). Without it, the device build is unsigned: a compile check that won't install. |
| `SIGN_IDENTITY` | Xcode's choice | Signing identity (SHA-1 or name). |
| `BUNDLE_ID` | `io.github.zephyrsai.cirrus.ios` | Bundle identifier. |
| `CONFIG` | `Release` | `Debug` adds the Simulator screenshot hooks (see below). |
| `TESTER` | `0` | `1` = tester build: starts in read-only iCloud mode. |
| `VERSION` | `1.0.0` | `CFBundleShortVersionString`. The build number is the git commit count. |
| `SIMULATOR` | `0` | `1` also builds `build/ios/Simulator/Cirrus.app`. |
| `IPA` | none | Also archive and export `build/dist/Cirrus-<version>[-tester]-ios.ipa`. The value is the export method: `development`, `release-testing` (ad hoc) or `app-store-connect` (TestFlight). |
| `INSTALL` | `0` | `1` installs on the connected iPhone or iPad with `xcrun devicectl`. |
| `ALLOW_PROVISIONING` | `0` | `1` passes `-allowProvisioningUpdates`, so Xcode can create or refresh profiles using the account signed in to Xcode. |

```bash
scripts/build-ios.sh                                            # unsigned device build: does it compile?
SIMULATOR=1 CONFIG=Debug scripts/build-ios.sh                   # plus a Simulator build
TEAM_ID=ABCDE12345 ALLOW_PROVISIONING=1 INSTALL=1 scripts/build-ios.sh
TESTER=1 TEAM_ID=ABCDE12345 IPA=release-testing ALLOW_PROVISIONING=1 scripts/build-ios.sh
```

Release builds are checked for the Debug-only hooks: the script fails if `CIRRUS_SCREEN` appears in the binary.

### Giving it to others

- **Ad hoc** (paid account, up to 100 devices of each kind a year):
  1. Register each tester's device UDID under developer.apple.com › Certificates, IDs & Profiles › Devices.
  2. Build with `IPA=release-testing`, which embeds a profile listing those devices.
  3. Testers install the `.ipa` with Apple Configurator, Finder (drag it onto the device's window), or `xcrun devicectl device install app`.
- **Internal TestFlight** (paid account, up to 100 testers on your App Store Connect team, no App Review):
  1. Create the app record in App Store Connect; it's never published.
  2. Build with `IPA=app-store-connect` and upload with Transporter.
  3. Testers install from the TestFlight app. Builds expire after 90 days.
- **Tester builds** (`TESTER=1`) start in read-only mode, so nothing in iCloud can change until a tester turns it off in Settings.

### Simulator and demo mode

The Simulator needs an iOS Simulator runtime (Xcode › Settings › Components). The demo account works without an Apple ID: turn on **Settings › Demo account** in the app, or set `CIRRUS_DEMO=1` in the scheme.

Debug builds open a given screen at launch, so screenshots can be taken headlessly:

```bash
xcrun simctl boot "iPhone 17 Pro"
xcrun simctl install booted build/ios/Simulator/Cirrus.app
SIMCTL_CHILD_CIRRUS_DEMO=1 SIMCTL_CHILD_CIRRUS_SCREEN=photos xcrun simctl launch booted io.github.zephyrsai.cirrus.ios
xcrun simctl io booted screenshot photos.png
```

Available screens:
- Drive: `drive`, `drive-grid`, `drive-folder`, `quicklook`, `trash`, `upload` (stages two sample files, one with a name that's already taken)
- Photos: `photos`, `photo`, `albums`, `album`, `export`, `device-photos`
- Everything else: `sidebar`, `transfers`, `backup`, `accounts`, `settings`, `signin`, `code`

`CIRRUS_READ_ONLY=0` or `1` sets read-only mode. `CIRRUS_AUTO=1` confirms the staged upload (Keep Both) and starts the export or backup after its check, so the runs can be checked on disk with `xcrun simctl get_app_container booted io.github.zephyrsai.cirrus.ios data`; their output lands in `Documents/Exports` and `Documents/Backup Drive`. All of these are compiled out of Release builds.

### iOS-specific behaviour

- **Accounts.**
  - Sign in to any number of Apple IDs the way iCloud.com does, with two-factor codes (SMS codes AutoFill) and Advanced Data Protection approval.
  - Passwords AutoFill from the Passwords app. A saved password stays in this device's keychain (`ThisDeviceOnly`, never synced) and is released only after Face ID, Touch ID or the passcode.
    - Turning that off in Settings needs Face ID or the passcode itself.
    - Unlocked passwords are dropped from memory when the setting changes, and when Cirrus goes to the background with nothing running.
  - iOS keeps keychain items after an app is deleted, so a fresh install first removes any Cirrus sessions and saved passwords left from an earlier one.
  - Signing out stops that account's transfers and previews. Its session can't store itself again, and its caches are wiped a second time once in-flight work has stopped.
  - **This iPhone/iPad** shows the device's own Photos library through PhotoKit. iOS doesn't let apps read the device's iCloud Drive folder, so iCloud Drive always comes from an Apple ID signed in to Cirrus.
- **Downloads keep going in the background.** Files of 4 MB or more download through a background `URLSession`. That session never carries iCloud cookies: the system follows redirects for it, so Cirrus couldn't keep cookies away from other hosts. When a download there is refused (401/403), it's retried in the normal session. Uploads ask for the usual background grace period.
- **Long runs.**
  - Back Up iCloud and Export use `BGContinuedProcessingTask` on iOS 26 and later (identifiers `<bundle id>.run.*`). The system shows their progress and lets you stop them; running again continues where it stopped.
  - That progress can appear on the Lock Screen, so it shows only counts and sizes, never file, album or account names.
  - On iOS 17–25 they get the background grace period, and the screen stays awake while Cirrus is in front.
- **Files and drives.**
  - Downloads, exports and backups go to a folder you pick with the document picker: this device, a USB drive or SD card, or a file server. Cirrus remembers it as a bookmark.
  - Nothing already there is overwritten: new files get " 2" names, and a re-run skips files that are already complete.
  - Photo exports also check every companion file (Live Photo `.MOV`, `-edited`, RAW) and give the whole item a suffixed name if any of its paths is taken. When Cirrus's own earlier copy has changed, the old copy goes to the Trash or `.cirrus/Removed` rather than being deleted. This fix is in the shared engine, so the Mac app gets it too.
  - Backups refuse folders in iCloud Drive. In read-only mode, exports refuse them too, and the engine checks again when the work runs.
  - Before anything starts:
    - a space check at the destination (free space minus queued transfers)
    - the FAT32 4 GB check
    - a check that this device has room to stage the largest file (downloads land in Cirrus's caches first; uploads are staged as one request body)
- **Packages** from iCloud Drive (Pages, Keynote, Numbers bundles) arrive as zips. On iOS they're expanded in-process by `ZipReader`, which refuses unsafe paths and checks every CRC. The Mac keeps using `ditto`.
- **Caches** live in `Library/Caches/Cirrus` with the Mac's layout: listings, hashed thumbnails, and per-account Open and Preview copies.
  - Quick Look editing is off, so preview copies never hold edits. On iOS they're always removed outright, never moved to a Trash outside the caches.
  - Signing out wipes that account's caches. **Settings › Clear Caches** wipes them all.
  - `Documents` (Files › On My iPhone › Cirrus) holds only what you save there.
- **Not in this version** (possible later phases):
  - scheduled or automatic syncs
  - two-way folder sync
  - importing from cameras and other devices
  - a File Provider extension showing iCloud Drive inside the Files app
  - folder uploads
  - Live Photo pairs from the Photos picker (the still is uploaded)
  - Moving to or from Google. Takeout reading uses `bsdtar`, and the OAuth flow would need an iOS client with `ASWebAuthenticationSession`.

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
