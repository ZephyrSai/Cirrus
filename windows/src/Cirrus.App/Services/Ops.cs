using System.Diagnostics;
using System.IO;
using System.Windows;
using Cirrus.App.Model;
using Cirrus.App.UI;
using Cirrus.Core;

namespace Cirrus.App.Services;

/// <summary>
/// The copy/move matrix and item operations (port of Operations.swift). Every operation runs size preflight
/// first, removals are always recoverable, and replacing a file uploads the new copy before the old one goes.
/// </summary>
static class Ops
{
    static TransferManager TM => TransferManager.Shared;
    static Preflight Pre => Preflight.Default;
    static Settings Prefs => Settings.Current;

    // MARK: Destinations

    public static async Task<Destination?> DestinationFor(Location loc)
    {
        switch (loc.Kind)
        {
            case LocKind.Local: return Catalog.Shared.Caps(loc).AcceptsDrops ? new Destination.Local(loc.Path!) : null;
            case LocKind.Drive: return loc.AccountRef is { } a ? new Destination.Drive(a, loc.Id!) : null;
            case LocKind.Photos:
                if (loc.AccountRef is not { } pa) return null;
                return new Destination.Photos(pa, await Catalog.Shared.Library(pa, loc.Library!), null);
            case LocKind.Album:
                if (loc.AccountRef is not { } aa) return null;
                var album = await Catalog.Shared.Album(aa, loc.Library!, loc.Id!);
                if (album is { Kind: PhotoAlbumKind.Smart } && !album.IsAllPhotos) return null;
                return new Destination.Photos(aa, await Catalog.Shared.Library(aa, loc.Library!), album is { Kind: PhotoAlbumKind.Album } ? album : null);
            default: return null;
        }
    }

    public static string Title(Destination d) => d switch
    {
        Destination.Local l => Catalog.Shared.Title(Location.Local(l.Dir)),
        Destination.Drive dr => Catalog.Shared.Title(Location.Drive(dr.Account.Id, dr.FolderID)),
        Destination.Photos p => p.Album?.Name ?? "Photos",
        _ => "",
    };

    public static void Refresh(Destination d)
    {
        switch (d)
        {
            case Destination.Local l: Catalog.Shared.Invalidate(Location.Local(l.Dir)); break;
            case Destination.Drive dr: Catalog.Shared.Invalidate(Location.Drive(dr.Account.Id, dr.FolderID)); break;
            case Destination.Photos p:
                Catalog.Shared.Invalidate(Location.Album(p.Account.Id, p.Library.Id, p.Album?.Id ?? "smart:All Photos"));
                Catalog.Shared.Invalidate(Location.Photos(p.Account.Id, p.Library.Id));
                break;
        }
    }

    // MARK: Errors and confirmations

    public static void ShowError(Exception e, string title, DependencyObject? owner)
    {
        if (e is OperationCanceledException || e is ICloudException { Kind: ICloudErrorKind.Cancelled }) return;
        Log.Error(title + ": " + e.Message);
        Dialogs.Error(owner, title, e.Message);
    }

    /// <summary>Shows the preflight summary when something is off or the batch is large. Returns false to cancel.</summary>
    public static bool Confirm(PreflightResult r, string verb, string destination, DependencyObject? owner)
    {
        if (!r.NeedsConfirmation) return true;
        var p = r.Describe(verb, destination);
        var cancel = p.ProceedButton == 0 ? 1 : 0;
        // Default button: the action normally, Cancel when space is short (buttons are then [Cancel, Verb Anyway]).
        var answer = Dialogs.Ask(owner, p.Title, p.Body, p.Buttons, 0, p.ProceedButton < 0 ? 0 : cancel, p.Severity);
        return p.ProceedButton >= 0 && answer == p.ProceedButton;
    }

    enum ConflictChoice { KeepBoth, Replace, Skip, Stop }

    static async Task<HashSet<string>> ExistingNames(Destination d) => d switch
    {
        Destination.Local l => Directory.Exists(l.Dir) ? Directory.EnumerateFileSystemEntries(l.Dir).Select(p => Path.GetFileName(p).ToLowerInvariant()).ToHashSet() : [],
        Destination.Drive dr => dr.Account.Drive is { } drive ? (await SafeList(drive, dr.FolderID)).Select(n => n.Name.ToLowerInvariant()).ToHashSet() : [],
        _ => [],
    };

    static async Task<List<DriveNode>> SafeList(IDriveBackend d, string id) { try { return await d.ListAsync(id); } catch { return []; } }

    public static string UniqueName(string name, ISet<string> taken)
    {
        if (!taken.Contains(name.ToLowerInvariant())) return name;
        var stem = Path.GetFileNameWithoutExtension(name);
        var ext = Path.GetExtension(name);
        for (int i = 2; i < 10_000; i++)
        {
            var n = $"{stem} ({i}){ext}";
            if (!taken.Contains(n.ToLowerInvariant())) return n;
        }
        return $"{stem} {Guid.NewGuid().ToString("N")[..6]}{ext}";
    }

    /// <summary>
    /// Asks about clashes with existing items. Returns one final name per input (same order): null = skip,
    /// "!replace:" + name = replace; null overall = stop. Two items of the same batch with the same name are
    /// never merged: the later ones get a number.
    /// </summary>
    static async Task<List<string?>?> ResolveNames(IReadOnlyList<string> names, Destination dest, DependencyObject? owner)
    {
        var existing = await ExistingNames(dest);
        var taken = new HashSet<string>(existing);
        var claimed = new HashSet<string>();
        var output = new List<string?>();
        ConflictChoice? all = null;
        for (int i = 0; i < names.Count; i++)
        {
            var n = names[i];
            var key = n.ToLowerInvariant();
            if (claimed.Contains(key))
            {
                var u = UniqueName(n, taken);
                taken.Add(u.ToLowerInvariant()); claimed.Add(u.ToLowerInvariant());
                output.Add(u);
                continue;
            }
            if (!existing.Contains(key)) { taken.Add(key); claimed.Add(key); output.Add(n); continue; }
            ConflictChoice choice;
            if (all is { } remembered) choice = remembered;
            else
            {
                choice = AskConflict(n, Title(dest), owner, names.Skip(i + 1).Any(x => existing.Contains(x.ToLowerInvariant())), out var applyAll);
                if (applyAll) all = choice;
            }
            switch (choice)
            {
                case ConflictChoice.Stop: return null;
                case ConflictChoice.Skip: output.Add(null); break;
                case ConflictChoice.Replace: output.Add("!replace:" + n); claimed.Add(key); break;
                default:
                    var u = UniqueName(n, taken);
                    taken.Add(u.ToLowerInvariant()); claimed.Add(u.ToLowerInvariant());
                    output.Add(u);
                    break;
            }
        }
        return output;
    }

    static ConflictChoice AskConflict(string name, string dest, DependencyObject? owner, bool more, out bool applyAll)
    {
        applyAll = false;
        var buttons = more ? new[] { "Keep Both", "Replace", "Skip", "Keep Both for All", "Stop" } : ["Keep Both", "Replace", "Skip", "Stop"];
        var r = Dialogs.Ask(owner, $"An item named “{name}” already exists in “{dest}”.",
            "Keep Both adds a number to the new item's name. Replace moves the existing item to the Recycle Bin (or Recently Deleted in iCloud) after the new one is copied.",
            buttons, 0, buttons.Length - 1, PreflightSeverity.Warning);
        if (more && r == 3) { applyAll = true; return ConflictChoice.KeepBoth; }
        return r switch { 0 => ConflictChoice.KeepBoth, 1 => ConflictChoice.Replace, 2 => ConflictChoice.Skip, _ => ConflictChoice.Stop };
    }

    // MARK: Local files → anywhere

    /// <summary>Local files (from Explorer, another app, or a local tab) into a destination.</summary>
    /// <param name="retire">
    /// With <paramref name="move"/>: what replaces moving a delivered file to the Recycle Bin (a cross-service move retires the
    /// original in its own service instead of the relay copy). Called only once that file or folder is fully at the destination.
    /// </param>
    public static async Task Deliver(IReadOnlyList<string> files, Destination dest, bool move, DependencyObject? owner, string? cleanupTemp = null,
        Func<string, Transfer, CancellationToken, Task>? retire = null)
    {
        if (files.Count == 0) return;
        var list = files.ToList();
        if (cleanupTemp is null)
        {
            var verb = dest switch { Destination.Local => move ? "Move" : "Copy", Destination.Drive => "Upload", _ => "Import" };
            PreflightResult pre;
            try { pre = await Pre.CheckUpload(list, dest, move); } catch (Exception e) { ShowError(e, "Couldn’t check the size", owner); return; }
            if (!Confirm(pre, verb, $"“{Title(dest)}”", owner)) return;
            var blocked = pre.BlockedNames;
            list = list.Where(f => !blocked.Contains(Path.GetFileName(f))).ToList();
            if (list.Count == 0) return;
        }
        string? group = cleanupTemp is null ? null : "relay:" + Path.GetFileName(cleanupTemp);
        try
        {
            switch (dest)
            {
                case Destination.Local l: await DeliverLocal(list, l, move, cleanupTemp is not null, group, owner); break;
                case Destination.Drive d: await DeliverDrive(list, d, move, group, owner, retire); break;
                case Destination.Photos p: DeliverPhotos(list, p, group, owner); break;
            }
        }
        finally
        {
            if (cleanupTemp is not null && group is not null)
                _ = Task.Run(async () => { await TM.WaitForGroup(group); try { Directory.Delete(cleanupTemp, true); } catch { } });   // our own relay folder
        }
    }

    static async Task DeliverLocal(List<string> files, Destination.Local dest, bool move, bool fromRelay, string? group, DependencyObject? owner)
    {
        try { SafetyPolicy.CheckLocalWrite(dest.Dir); } catch (Exception e) { ShowError(e, "iCloud is read-only", owner); return; }
        var names = await ResolveNames(files.Select(f => Path.GetFileName(f)!).ToList(), dest, owner);
        if (names is null) return;
        for (int idx = 0; idx < files.Count; idx++)
        {
            var f = files[idx];
            if (names[idx] is not { } target) continue;
            var replace = target.StartsWith("!replace:");
            var finalName = replace ? target[9..] : target;
            var dst = Path.Combine(dest.Dir, finalName);
            if (string.Equals(Path.GetFullPath(f), Path.GetFullPath(dst), StringComparison.OrdinalIgnoreCase)) continue;
            var sameVolume = Preflight.SameVolume(f, dest.Dir);
            var isMove = move || fromRelay;
            if (move) { try { SafetyPolicy.CheckLocalWrite(f); } catch (Exception e) { ShowError(e, "iCloud is read-only", owner); return; } }
            var size = File.Exists(f) ? new FileInfo(f).Length : LocalFiles.TreeSize(f);
            TM.Enqueue(Path.GetFileName(f), async (t, ct) =>
            {
                await Task.Run(async () =>
                {
                    if (File.Exists(f)) await LocalFiles.EnsureDownloadedAsync(f, ct);
                    // Copy (or move) first, then retire what it replaces: the old item is only ever moved aside.
                    var staging = replace ? Path.Combine(dest.Dir, ".cirrus-" + Guid.NewGuid().ToString("N")[..8] + "-" + finalName) : dst;
                    if (isMove && sameVolume) LocalFiles.MoveItem(f, staging);
                    else
                    {
                        LocalFiles.CopyItem(f, staging);
                        if (move) LocalFiles.SafeTrash(f, null);
                    }
                    if (replace)
                    {
                        LocalFiles.SafeTrash(dst, null);
                        LocalFiles.MoveItem(staging, dst);
                    }
                }, ct);
                t.Report(size, size);
                t.ResultPath = dst;
                Refresh(dest);
                if (move) Catalog.Shared.Invalidate(Location.Local(Path.GetDirectoryName(f)!));
            }, (isMove && sameVolume ? "Moving to " : "Copying to ") + Title(dest), TransferDirection.Copy, size, group,
            isMove && sameVolume ? null : Preflight.VolumeKey(dest.Dir));
        }
    }

    static async Task DeliverDrive(List<string> files, Destination.Drive dest, bool move, string? group, DependencyObject? owner,
        Func<string, Transfer, CancellationToken, Task>? retire = null)
    {
        if (dest.Account.Drive is not { } drive) return;
        Task Retire(string f, Transfer t, CancellationToken ct) => retire is null ? Task.Run(() => LocalFiles.SafeTrash(f, null), ct) : retire(f, t, ct);
        var names = await ResolveNames(files.Select(f => WinNames.FromLocal(Path.GetFileName(f))).ToList(), dest, owner);
        if (names is null) return;
        var existing = await SafeList(drive, dest.FolderID);
        var quota = Preflight.ICloudKey(dest.Account);
        for (int idx = 0; idx < files.Count; idx++)
        {
            var f = files[idx];
            if (names[idx] is not { } target) continue;
            if (move) { try { SafetyPolicy.CheckLocalWrite(f); } catch (Exception e) { ShowError(e, "iCloud is read-only", owner); return; } }
            var replace = target.StartsWith("!replace:");
            var finalName = replace ? target[9..] : target;
            var old = existing.FirstOrDefault(n => n.Name.Equals(finalName, StringComparison.OrdinalIgnoreCase));
            if (Directory.Exists(f))
            {
                TM.Enqueue(finalName, async (t, ct) =>
                {
                    DriveNode folder;
                    DriveNode? retire = null;
                    if (old is { IsFolder: true } && !replace) folder = old;
                    else if (replace && old is not null)
                    {
                        // Build the replacement beside the old folder; retire the old one only after it uploads.
                        folder = await drive.CreateFolderAsync(".cirrus-upload-" + Guid.NewGuid().ToString("N")[..8] + "-" + finalName, dest.FolderID, ct);
                        retire = old;
                    }
                    else folder = await drive.CreateFolderAsync(finalName, dest.FolderID, ct);
                    var runner = new SyncRunner(new LocalSide(f, new SyncOptions().Excludes), new DriveSide(drive, folder.Id, finalName, []));
                    var (sa, sb) = await runner.ScanAsync(p => t.SetDetail(p.Phase), ct);
                    var plan = SyncPlanner.Plan(SyncMode.Copy, sa, sb, null);
                    t.Report(0, plan.Bytes);
                    var (rep, _) = await runner.RunAsync(plan, sa, sb, p => { t.Report(p.BytesDone, p.BytesTotal); t.SetDetail($"{p.FilesDone} of {p.FilesTotal} items"); }, ct);
                    if (rep.Failed.Count > 0) throw ICloudException.Server($"{rep.Failed.Count} items failed: {rep.Failed[0]}");
                    if (retire is not null)
                    {
                        await drive.TrashAsync([retire], ct);
                        await drive.RenameAsync(folder, finalName, ct);
                    }
                    if (move)
                    {
                        // Only retire the original when every item in it is now in iCloud: excluded names (desktop.ini, ._*),
                        // links, skipped clashes and files left alone because iCloud's copy differs keep it in place.
                        var copied = plan.Actions.Where(x => x.Kind == SyncActionKind.CopyAB).Select(x => x.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
                        var allThere = rep.Skipped == 0 && sa.All(kv => kv.Value.IsDir || copied.Contains(kv.Key) || (sb.TryGetValue(kv.Key, out var there) && there.Size == kv.Value.Size));
                        int onDisk;
                        try { onDisk = Directory.EnumerateFileSystemEntries(f, "*", new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = false, AttributesToSkip = 0 }).Count(); }
                        catch { onDisk = -1; }
                        if (allThere && onDisk == sa.Count) await Retire(f, t, ct);
                        else t.SetDetail($"Uploaded. The original folder was kept because some of its items weren’t uploaded (excluded, links or already different in {dest.Account.DriveTitle}).");
                    }
                    Refresh(dest);
                }, "Uploading folder to " + Title(dest), TransferDirection.Upload, LocalFiles.TreeSize(f), group, quota);
            }
            else
            {
                var size = new FileInfo(f).Length;
                TM.Enqueue(finalName, async (t, ct) =>
                {
                    await LocalFiles.EnsureDownloadedAsync(f, ct);
                    var mtime = new DateTimeOffset(File.GetLastWriteTimeUtc(f), TimeSpan.Zero);
                    // Upload first; only then retire the old copy (SafeReplace).
                    await drive.SafeReplaceAsync(f, finalName, dest.FolderID, replace ? old : null, mtime, (d, tot) => t.Report(d, tot), ct);
                    if (move) await Retire(f, t, ct);
                    Refresh(dest);
                }, "Uploading to " + Title(dest), TransferDirection.Upload, size, group, quota);
            }
        }
    }

    static void DeliverPhotos(List<string> files, Destination.Photos dest, string? group, DependencyObject? owner)
    {
        if (dest.Account.Photos is not { } photos) return;
        var all = files.SelectMany(ImportableFiles).ToList();
        if (all.Count == 0) { Dialogs.Error(owner, "Nothing to import", "None of these files are photos or videos."); return; }
        var total = all.Sum(f => new FileInfo(f).Length);
        // Remembered across Retry (same work delegate): what was already imported is never uploaded again.
        var imported = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        TM.Enqueue($"Importing {all.Count} item{(all.Count == 1 ? "" : "s")}", async (t, ct) =>
        {
            long done = 0;
            try
            {
                foreach (var g in LivePairing.GroupFiles(all))
                {
                    ct.ThrowIfCancellationRequested();
                    var group = (g.PairedVideo is { } v ? new[] { g.Primary, v } : [g.Primary]).Where(f => !imported.Contains(f)).ToArray();
                    if (group.Length == 0) continue;
                    foreach (var f in group) await LocalFiles.EnsureDownloadedAsync(f, ct);
                    var before = done;
                    await photos.ImportFilesAsync(group, dest.Album, dest.Library, (d, _) => t.Report(before + d, total), ct);
                    foreach (var f in group) { imported.Add(f); done += new FileInfo(f).Length; }
                    t.Report(done, total);
                }
            }
            finally { Refresh(dest); }
        }, "To " + (dest.Album?.Name ?? "Photos"), TransferDirection.Upload, total, group, Preflight.ICloudKey(dest.Account));
    }

    static IEnumerable<string> ImportableFiles(string path)
    {
        if (File.Exists(path)) return PhotoFormats.IsImportable(path) ? [path] : [];
        if (!Directory.Exists(path)) return [];
        return Directory.EnumerateFiles(path, "*", new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true }).Where(PhotoFormats.IsImportable);
    }

    // MARK: Items shown in Cirrus → anywhere

    public static async Task Transfer(IReadOnlyList<Item> items, Destination dest, bool move, DependencyObject? owner)
    {
        var local = items.Where(i => i.LocalPath is not null && i.Volume is null).Select(i => i.LocalPath!).ToList();
        if (local.Count > 0) await Deliver(local, dest, move, owner);
        var remote = items.Where(i => i.LocalPath is null).ToList();
        if (remote.Count == 0) return;
        // Same-service fast paths.
        if (dest is Destination.Drive dd && dd.Account.Drive is { } drive)
        {
            var same = remote.Where(i => i.Node is not null && i.AccountID == dd.Account.Id).ToList();
            if (same.Count > 0)
            {
                var nodes = same.Select(i => i.Node!).Where(n => n.Id != dd.FolderID && n.ParentID != dd.FolderID).ToList();
                if (nodes.Count > 0)
                {
                    if (!move && !Dialogs.Confirm(owner, $"Move {(nodes.Count == 1 ? $"“{nodes[0].Name}”" : $"{nodes.Count} items")} to “{Title(dest)}”?",
                            $"Inside the same {dd.Account.DriveTitle}, items are moved rather than copied.", "Move")) return;
                    TM.Enqueue(nodes.Count == 1 ? nodes[0].Name : $"{nodes.Count} items", async (_, ct) =>
                    {
                        await drive.MoveAsync(nodes, dd.FolderID, ct);
                        Refresh(dest);
                        foreach (var p in nodes.Select(n => n.ParentID).OfType<string>().Distinct()) Catalog.Shared.Invalidate(Location.Drive(dd.Account.Id, p));
                    }, "Moving to " + Title(dest));
                }
                var rest = remote.Except(same).ToList();
                if (rest.Count > 0) await ViaTemp(rest, dest, owner, move);
                return;
            }
        }
        if (dest is Destination.Photos dp && dp.Account.Photos is { } photos)
        {
            var same = remote.Where(i => i.Photo is not null && i.AccountID == dp.Account.Id).ToList();
            if (same.Count > 0)
            {
                if (dp.Album is { } album)
                {
                    var assets = same.Select(i => i.Photo!).ToList();
                    TM.Enqueue($"Adding {assets.Count} to “{album.Name}”", async (_, ct) => { await photos.AddAsync(assets, album, dp.Library, ct); Refresh(dest); });
                }
                var rest = remote.Except(same).ToList();
                if (rest.Count > 0) await ViaTemp(rest, dest, owner, move);
                return;
            }
        }
        if (dest is Destination.Local l) { await Download(remote, l.Dir, owner, move); return; }
        await ViaTemp(remote, dest, owner, move);
    }

    /// <summary>
    /// Remote → remote across services: materialise into a relay folder, then deliver. A move (Shift-drag, Cut and Paste)
    /// retires each original in its own service (its trash) only after that item fully arrived at the destination; items
    /// that were skipped, excluded or failed stay where they were.
    /// </summary>
    static async Task ViaTemp(List<Item> items, Destination dest, DependencyObject? owner, bool move = false)
    {
        // Only drive items can be retired after a move; photos are copied (their library keeps them).
        move = move && dest is Destination.Drive && items.Any(i => i.Node is not null);
        var pre = new PreflightResult { Files = items.Count, Bytes = items.Sum(i => i.TransferSize) };
        switch (dest)
        {
            case Destination.Drive d:
                pre.Available = await Pre.ICloudFree(d.Account); pre.AvailableLabel = Preflight.SpaceLabel(d.Account);
                var (max, reason) = Preflight.DriveLimit(d.Account);
                if (max is long mx) foreach (var i in items.Where(i => i.TransferSize > mx)) pre.Blocked.Add(new BlockedItem(i.Name, i.TransferSize, reason));
                break;
            case Destination.Photos p when p.Account.Kind is AccountKind.Web or AccountKind.Cloud:
                pre.Available = await Pre.ICloudFree(p.Account); pre.AvailableLabel = Preflight.SpaceLabel(p.Account);
                break;
        }
        var relayRoot = Paths.CacheDir("relay");
        pre.Available = pre.Available is long a ? Math.Min(a, Pre.LocalFree(relayRoot) ?? long.MaxValue) : pre.Available;
        if (!Confirm(pre, move ? "Move" : "Copy", $"“{Title(dest)}”", owner)) return;
        var blocked = pre.BlockedNames;
        items = items.Where(i => !blocked.Contains(i.Name)).ToList();
        if (items.Count == 0) return;
        var tmp = Path.Combine(relayRoot, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tmp);
        var exportLive = Prefs.ExportLive;
        var t = TM.Enqueue($"Preparing {items.Count} item{(items.Count == 1 ? "" : "s")}", async (t, ct) =>
        {
            long done = 0;
            foreach (var item in items)
            {
                var b = done;
                await Materialize(item, tmp, exportLive, null, (d, _) => t.Report(b + d, 0), ct);
                done += item.TransferSize;
            }
        }, "Downloading before sending to " + Title(dest), TransferDirection.Download, items.Sum(i => i.TransferSize), quotaKey: Preflight.VolumeKey(relayRoot));
        await TM.WaitFor(t);
        if (t.State != TransferState.Done) { try { Directory.Delete(tmp, true); } catch { } return; }
        var files = Directory.EnumerateFileSystemEntries(tmp).ToList();
        if (!move) { await Deliver(files, dest, false, owner, cleanupTemp: tmp); return; }
        // Each relay entry back to the item it came from (by the name it was written under).
        var origin = new Dictionary<string, Item>(StringComparer.OrdinalIgnoreCase);
        foreach (var i in items.Where(i => i.Node is not null)) origin.TryAdd(OutputName(i), i);
        await Deliver(files, dest, true, owner, cleanupTemp: tmp, retire: (f, t, ct) => RetireMovedSource(origin, f, t, ct));
    }

    /// <summary>A cross-service move's last step: the original goes to its own service's trash (never deleted for good).</summary>
    static async Task RetireMovedSource(Dictionary<string, Item> origin, string relayPath, Transfer t, CancellationToken ct)
    {
        if (!origin.TryGetValue(Path.GetFileName(relayPath), out var item) || item.Node is not { } n) return;
        var acct = AccountManager.Shared.Account(item.AccountID);
        if (acct?.Drive is not { } drive) return;
        try
        {
            await drive.TrashAsync([n], ct);
            if (n.ParentID is { } parent) Catalog.Shared.Invalidate(Location.Drive(acct.Id, parent));
            if (acct.CanListTrash) Catalog.Shared.Invalidate(Location.DriveTrash(acct.Id));
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception e)
        {
            // The copy arrived; only the clean-up failed. Never fail (and so retry) the upload for it.
            Log.Status("couldn’t retire a moved original: " + e.GetType().Name);
            t.SetDetail($"Copied. The original is still in {acct.DriveTitle}: {e.Message}");
        }
    }

    public static string OutputName(Item item)
    {
        if (item.Photo is { } p)
            return Paths.SafeName(Prefs.ExportEdited && p.Resource(PhotoResourceKind.Edited) is { } e ? e.Filename : p.Filename);
        return Paths.SafeName(item.Name);
    }

    /// <summary>Remote items (Drive, Photos, albums) into a local folder, with preflight and conflict handling.</summary>
    public static async Task Download(IReadOnlyList<Item> input, string dir, DependencyObject? owner, bool moveSource = false)
    {
        var dest = new Destination.Local(dir);
        try { SafetyPolicy.CheckLocalWrite(dir); } catch (Exception e) { ShowError(e, "iCloud is read-only", owner); return; }
        PreflightResult pre;
        try { pre = await Pre.CheckDownload(input.Select(i => i.AsTransferItem()).ToList(), dir, Prefs.ExportLive, Prefs.ExportEdited); }
        catch (Exception e) { ShowError(e, "Couldn’t check the size", owner); return; }
        if (!Confirm(pre, "Download", $"“{Title(dest)}”", owner)) return;
        var blocked = pre.BlockedNames;
        var items = input.Where(i => !blocked.Contains(i.Name)).ToList();
        if (items.Count == 0) return;
        var vol = Preflight.VolumeKey(dir);
        var names = await ResolveNames(items.Select(OutputName).ToList(), dest, owner);
        if (names is null) return;
        var exportLive = Prefs.ExportLive; var edited = Prefs.ExportEdited;
        var photoBatch = new List<(PhotoAsset Asset, string Name, bool Replace, Account Acct)>();
        for (int idx = 0; idx < items.Count; idx++)
        {
            var item = items[idx];
            if (names[idx] is not { } target) continue;
            var replace = target.StartsWith("!replace:");
            var finalName = replace ? target[9..] : target;
            if (item.Photo is { } p && AccountManager.Shared.Account(item.AccountID) is { } acct) { photoBatch.Add((p, finalName, replace, acct)); continue; }
            TM.Enqueue(finalName, async (t, ct) =>
            {
                // Stage next to the target (same drive), so moving it into place can't fail after the old copy was retired.
                var staging = Path.Combine(dir, ".cirrus-dl-" + Guid.NewGuid().ToString("N")[..8]);
                bool retired = false, placed = false;
                try
                {
                    Directory.CreateDirectory(staging);
                    try { File.SetAttributes(staging, File.GetAttributes(staging) | FileAttributes.Hidden); } catch { }
                    await Materialize(item, staging, exportLive, finalName, (d, tot) => t.Report(d, tot), ct);
                    var target = Path.Combine(dir, finalName);
                    if (replace && LocalFiles.Exists(target)) { LocalFiles.SafeTrash(target, null); retired = true; }
                    foreach (var f in Directory.EnumerateFileSystemEntries(staging).ToList())
                    {
                        var dst = Path.Combine(dir, Path.GetFileName(f));
                        if (LocalFiles.Exists(dst) && Path.GetFileName(f) != finalName) continue;   // a companion (Live .MOV) that's already there
                        LocalFiles.MoveItem(f, dst);
                    }
                    placed = true;
                    t.ResultPath = target;
                    if (moveSource && item.Node is { } n && AccountManager.Shared.Account(item.AccountID)?.Drive is { } drive)
                    {
                        await drive.TrashAsync([n], ct);
                        if (n.ParentID is { } parent) Catalog.Shared.Invalidate(Location.Drive(item.AccountID!, parent));
                    }
                    Refresh(dest);
                }
                finally
                {
                    // The staging folder only ever holds Cirrus' fresh download. If the old copy was retired but the new one
                    // couldn't be put in place, keep the download where it is rather than lose both.
                    if (!retired || placed) { try { if (Directory.Exists(staging)) Directory.Delete(staging, true); } catch { } }
                    else Log.Status("download left in its .cirrus-dl staging folder after it couldn’t be moved into place");
                }
            }, "Downloading to " + Title(dest), TransferDirection.Download, item.TransferSize, quotaKey: vol);
        }
        if (photoBatch.Count > 0)
        {
            var total = photoBatch.Sum(b => b.Asset.ExportSize(exportLive, edited, false));
            TM.Enqueue(photoBatch.Count == 1 ? photoBatch[0].Name : $"Exporting {photoBatch.Count} photos", async (t, ct) =>
            {
                long done = 0;
                var gate = new object();
                using var sem = new SemaphoreSlim(3);
                var tasks = photoBatch.Select(async b =>
                {
                    await sem.WaitAsync(ct);
                    try
                    {
                        if (b.Acct.Photos is not { } backend) return;
                        var target = Path.Combine(dir, b.Name);
                        var kind = edited && b.Asset.Resource(PhotoResourceKind.Edited) is not null ? PhotoResourceKind.Edited : PhotoResourceKind.Original;
                        var tmp = Path.Combine(dir, ".cirrus-part-" + Guid.NewGuid().ToString("N")[..8] + "-" + b.Name);
                        long baseDone; lock (gate) baseDone = done;
                        await backend.ExportAsync(b.Asset, kind, tmp, (d, _) => t.Report(baseDone + d, 0), ct);
                        if (b.Replace) LocalFiles.SafeTrash(target, null);
                        File.Move(tmp, target);
                        lock (gate) done += b.Asset.Resource(kind)?.Size ?? b.Asset.Size;
                        if (exportLive && b.Asset.Resource(PhotoResourceKind.LiveVideo) is { } lv)
                        {
                            var mov = Path.Combine(dir, Path.GetFileNameWithoutExtension(b.Name) + ".MOV");
                            if (!File.Exists(mov)) await backend.ExportAsync(b.Asset, PhotoResourceKind.LiveVideo, mov, null, ct);
                            lock (gate) done += lv.Size;
                        }
                        lock (gate) t.Report(done, 0);
                        t.ResultPath = target;
                    }
                    finally { sem.Release(); }
                });
                await Task.WhenAll(tasks);
                Refresh(dest);
            }, "To " + Title(dest), TransferDirection.Download, total, quotaKey: vol);
        }
    }

    /// <summary>Produce a local copy of any item inside <paramref name="dir"/>. Returns the main file/folder.</summary>
    public static async Task<string> Materialize(Item item, string dir, bool exportLive, string? nameOverride, Action<long, long>? progress, CancellationToken ct)
    {
        Directory.CreateDirectory(dir);
        var name = nameOverride ?? Paths.SafeName(item.Name);
        var target = Path.Combine(dir, name);
        var account = AccountManager.Shared.Account(item.AccountID);
        if (item.LocalPath is { } lp)
        {
            await LocalFiles.EnsureDownloadedAsync(lp, ct);
            await Task.Run(() => LocalFiles.CopyItem(lp, target), ct);
            return target;
        }
        if (item.Node is { } n)
        {
            var drive = account?.Drive ?? throw ICloudException.NeedsSignIn();
            if (n.IsFolder)
            {
                var runner = new SyncRunner(new DriveSide(drive, n.Id, n.Name, []), new LocalSide(target, [], allowMissing: true));
                var (a, b) = await runner.ScanAsync(null, ct);
                var plan = SyncPlanner.Plan(SyncMode.Copy, a, b, null);
                var (rep, _) = await runner.RunAsync(plan, a, b, p => progress?.Invoke(p.BytesDone, p.BytesTotal), ct);
                Directory.CreateDirectory(target);
                if (rep.Failed.Count > 0) throw ICloudException.Server($"{rep.Failed.Count} files couldn’t be downloaded.");
            }
            else await drive.DownloadAsync(n, target, progress, ct);
            return target;
        }
        if (item.Photo is { } p)
        {
            var photos = account?.Photos ?? throw ICloudException.NeedsSignIn();
            await photos.ExportAsync(p, PhotoResourceKind.Original, target, progress, ct);
            if (exportLive && p.Resource(PhotoResourceKind.LiveVideo) is not null)
                await photos.ExportAsync(p, PhotoResourceKind.LiveVideo, Path.Combine(dir, Path.GetFileNameWithoutExtension(name) + ".MOV"), null, ct);
            return target;
        }
        if (item.Album is { } al && item.Target is { Library: { } libID })
        {
            var photos = account?.Photos ?? throw ICloudException.NotFound();
            var lib = await Catalog.Shared.Library(account!, libID, ct);
            var assets = await photos.AssetsAsync(al, lib, null, ct);
            Directory.CreateDirectory(target);
            var taken = new HashSet<string>();
            long total = assets.Sum(a => a.Size), done = 0;
            foreach (var a in assets)
            {
                ct.ThrowIfCancellationRequested();
                var nm = UniqueName(Paths.SafeName(a.Filename), taken);
                taken.Add(nm.ToLowerInvariant());
                await photos.ExportAsync(a, PhotoResourceKind.Original, Path.Combine(target, nm), null, ct);
                if (exportLive && a.Resource(PhotoResourceKind.LiveVideo) is not null)
                    try { await photos.ExportAsync(a, PhotoResourceKind.LiveVideo, Path.Combine(target, Path.GetFileNameWithoutExtension(nm) + ".MOV"), null, ct); } catch { }
                done += a.Size;
                progress?.Invoke(done, total);
            }
            return target;
        }
        throw ICloudException.Server("Can’t copy a whole drive this way.");
    }

    // MARK: Open

    static string StableKey(string s)
    {
        ulong h = 1469598103934665603;
        foreach (var b in System.Text.Encoding.UTF8.GetBytes(s)) h = unchecked((h ^ b) * 1099511628211);
        return h.ToString("x");
    }

    /// <summary>
    /// A local path for opening, downloading into the account's "open" cache when needed. A copy that changed since it
    /// was downloaded (the user edited it) is never overwritten: it's retired to the Recycle Bin, and if that isn't
    /// possible the new download goes into a separate folder.
    /// </summary>
    public static async Task<string> LocalCopy(Item item, string? progressTitle)
    {
        if (item.LocalPath is { } lp) { await LocalFiles.EnsureDownloadedAsync(lp); return lp; }
        var root = Paths.AccountCacheDir("open", item.AccountID ?? "");
        var dir = Path.Combine(root, StableKey(item.Key));
        var target = Path.Combine(dir, Paths.SafeName(item.Name));
        // Reuse a cached copy only when it's the same version (size and modified time match).
        if (File.Exists(target) && (item.Size is null || new FileInfo(target).Length == item.Size || item.IsPhoto)
            && (item.IsPhoto || item.Modified is not { } m || Math.Abs((File.GetLastWriteTimeUtc(target) - m.UtcDateTime).TotalSeconds) < 2)) return target;
        if (Directory.Exists(dir))
        {
            try { LocalFiles.SafeTrash(dir, root); }
            catch (Exception e) { Log.Status("couldn’t retire an old opened copy: " + e.GetType().Name); }
            if (Directory.Exists(dir))
            {
                dir = Path.Combine(root, StableKey(item.Key) + "-" + Guid.NewGuid().ToString("N")[..8]);   // never overwrite it
                target = Path.Combine(dir, Paths.SafeName(item.Name));
            }
        }
        var into = dir;
        var t = TM.Enqueue(progressTitle ?? item.Name, async (t, ct) => { await Materialize(item, into, false, null, (d, tot) => t.Report(d, tot), ct); },
            "Downloading to open", TransferDirection.Download, item.TransferSize);
        await TM.WaitFor(t);
        if (t.State == TransferState.Failed) throw ICloudException.Server(t.Error ?? "Download failed");
        if (t.State == TransferState.Cancelled) throw new OperationCanceledException();
        return target;
    }

    public static async Task Open(IReadOnlyList<Item> items, DependencyObject? owner)
    {
        foreach (var item in items.Take(8))
        {
            try
            {
                var path = await LocalCopy(item, "Opening " + item.Name);
                Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
            }
            catch (Exception e) { ShowError(e, $"Couldn’t open “{item.Name}”", owner); }
        }
    }

    public static void ShowInExplorer(string path)
    {
        try { Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true }); } catch { }
    }

    // MARK: Folders, renames and removals

    public static async Task<string?> NewFolder(Location loc, DependencyObject? owner)
    {
        var caps = Catalog.Shared.Caps(loc);
        var name = Dialogs.Prompt(owner, caps.NewFolderTitle, caps.NewFolderTitle == "New Album" ? "Album name:" : "Folder name:", caps.NewFolderTitle == "New Album" ? "New Album" : "New folder", "Create");
        if (name is null) return null;
        try
        {
            switch (loc.Kind)
            {
                case LocKind.Local:
                    SafetyPolicy.CheckLocalWrite(loc.Path!);
                    var p = Path.Combine(loc.Path!, name);
                    if (LocalFiles.Exists(p)) throw new IOException($"“{name}” already exists.");
                    Directory.CreateDirectory(p);
                    break;
                case LocKind.Drive:
                    var drive = loc.AccountRef?.Drive ?? throw ICloudException.NeedsSignIn();
                    Catalog.Shared.RememberDrive(loc.Account!, await drive.CreateFolderAsync(name, loc.Id!));
                    break;
                case LocKind.Photos:
                    var acct = loc.AccountRef ?? throw ICloudException.NeedsSignIn();
                    await acct.Photos!.CreateAlbumAsync(name, await Catalog.Shared.Library(acct, loc.Library!));
                    break;
            }
            Catalog.Shared.Invalidate(loc);
            return name;
        }
        catch (Exception e) { ShowError(e, $"Couldn’t create “{name}”", owner); return null; }
    }

    public static async Task Rename(Item item, Location loc, DependencyObject? owner)
    {
        var newName = Dialogs.Prompt(owner, "Rename", $"New name for “{item.Name}”:", item.Name, "Rename", selectStem: !item.IsContainer);
        if (newName is null || newName == item.Name) return;
        try
        {
            if (item.LocalPath is { } lp)
            {
                SafetyPolicy.CheckLocalWrite(lp);
                var dst = Path.Combine(Path.GetDirectoryName(lp)!, newName);
                if (LocalFiles.Exists(dst) && !string.Equals(dst, lp, StringComparison.OrdinalIgnoreCase)) throw new IOException($"“{newName}” already exists.");
                LocalFiles.MoveItem(lp, dst);
            }
            else if (item.Node is { } n && loc.AccountRef?.Drive is { } drive)
                Catalog.Shared.RememberDrive(loc.Account!, await drive.RenameAsync(n, newName));
            Catalog.Shared.Invalidate(loc);
        }
        catch (Exception e) { ShowError(e, $"Couldn’t rename “{item.Name}”", owner); }
    }

    /// <summary>Recoverable removal: Recycle Bin for local files, Recently Deleted for iCloud Drive and Photos.</summary>
    public static async Task Trash(IReadOnlyList<Item> items, Location loc, DependencyObject? owner)
    {
        if (items.Count == 0) return;
        var local = items.Where(i => i.LocalPath is not null && i.Volume is null && !i.Key.StartsWith("native")).Select(i => i.LocalPath!).ToList();
        if (SafetyPolicy.ReadOnlyICloud && local.Any(SafetyPolicy.TouchesICloud)) { ShowError(new ReadOnlyException(), "iCloud is read-only", owner); return; }
        if (local.Count > 0)
        {
            var aside = new List<string>();
            await Task.Run(() =>
            {
                foreach (var p in local)
                {
                    try { if (LocalFiles.SafeTrash(p, null) is { } moved) aside.Add(moved); }
                    catch (Exception e) { Application.Current.Dispatcher.Invoke(() => ShowError(e, $"Couldn’t move “{Path.GetFileName(p)}” to the Recycle Bin", owner)); }
                }
            });
            if (aside.Count > 0)
                Notifier.Show($"{aside.Count} item{(aside.Count == 1 ? " was" : "s were")} moved into a “.cirrus\\Removed” folder because this drive has no Recycle Bin.");
            Catalog.Shared.Invalidate(loc);
        }
        var nodes = items.Where(i => i.Node is not null).Select(i => i.Node!).ToList();
        if (nodes.Count > 0 && loc.AccountRef?.Drive is { } drive)
        {
            try { await drive.TrashAsync(nodes); Catalog.Shared.Invalidate(loc); Catalog.Shared.Invalidate(Location.DriveTrash(loc.Account!)); }
            catch (Exception e) { ShowError(e, "Couldn’t move to " + (loc.AccountRef?.DeletedTitle ?? "Recently Deleted"), owner); }
        }
        var assets = items.Where(i => i.Photo is not null).Select(i => i.Photo!).ToList();
        if (assets.Count > 0 && loc.AccountRef is { Photos: { } photos } pa)
        {
            if (!Dialogs.Confirm(owner, assets.Count == 1 ? "Delete this photo?" : $"Delete {assets.Count} photos?",
                    pa.IsICloud ? "They’ll move to Recently Deleted in iCloud Photos, on all your devices, and can be recovered for 30 days."
                        : $"They’ll move to {pa.DriveTitle}’s {pa.DeletedTitle}, where you can put them back.", "Delete", destructive: true)) return;
            try
            {
                await photos.DeleteAsync(assets);
                PatchAndShow(loc, [], assets.Select(a => a.Id).ToHashSet());
            }
            catch (Exception e) { ShowError(e, "Couldn’t delete", owner); }
        }
    }

    public static async Task Restore(IReadOnlyList<Item> items, Location loc, DependencyObject? owner)
    {
        try
        {
            if (loc.Kind == LocKind.DriveTrash && loc.AccountRef?.Drive is { } drive)
            {
                await drive.RestoreAsync(items.Where(i => i.Node is not null).Select(i => i.Node!).ToList());
                if (drive.RootID is { } root) Catalog.Shared.Invalidate(Location.Drive(loc.Account!, root));
            }
            else if (loc.AccountRef?.Photos is { } photos)
            {
                await photos.RestoreAsync(items.Where(i => i.Photo is not null).Select(i => i.Photo!).ToList());
                Catalog.Shared.Invalidate(Location.Album(loc.Account!, loc.Library!, "smart:All Photos"));
            }
            Catalog.Shared.Invalidate(loc);
        }
        catch (Exception e) { ShowError(e, "Couldn’t recover", owner); }
    }

    /// <summary>The single permanent removal in Cirrus: only inside iCloud Drive's Recently Deleted, after a confirmation.</summary>
    public static async Task DeleteForever(IReadOnlyList<Item> items, Location loc, DependencyObject? owner)
    {
        if (loc.Kind != LocKind.DriveTrash || loc.AccountRef?.Drive is not { } drive) return;
        var nodes = items.Where(i => i.Node is { IsInTrash: true }).Select(i => i.Node!).ToList();
        if (nodes.Count == 0) return;
        var acct = loc.AccountRef!;
        // Re-check the trash right now: act only on items still there and unchanged (not restored elsewhere).
        try
        {
            var current = await drive.ListTrashAsync();
            nodes = nodes.Select(n => current.FirstOrDefault(c => c.Id == n.Id && c.Etag == n.Etag)).OfType<DriveNode>().ToList();
        }
        catch (Exception e) { ShowError(e, "Couldn’t check " + acct.DeletedTitle, owner); return; }
        if (nodes.Count == 0) { Catalog.Shared.Invalidate(loc); Dialogs.Info(owner, "Nothing to delete", $"Those items are no longer in {acct.DeletedTitle}."); return; }
        if (!Dialogs.Confirm(owner, $"Delete {nodes.Count} item{(nodes.Count == 1 ? "" : "s")} immediately?",
                acct.IsICloud ? "They’ll be removed from iCloud for good, on all your devices. You can’t undo this."
                    : $"They’ll be removed from {acct.DriveTitle} for good. You can’t undo this.", "Delete Immediately", destructive: true)) return;
        try { await drive.DeleteForeverAsync(nodes); Catalog.Shared.Invalidate(loc); }
        catch (Exception e) { ShowError(e, "Couldn’t delete", owner); }
    }

    public static async Task SetFavorite(IReadOnlyList<Item> items, bool value, Location loc, DependencyObject? owner)
    {
        if (loc.AccountRef?.Photos is not { } photos) return;
        try
        {
            var updated = await photos.SetFavoriteAsync(items.Where(i => i.Photo is not null).Select(i => i.Photo!).ToList(), value);
            foreach (var u in updated) if (items.FirstOrDefault(i => i.Photo?.Id == u.Id) is { } it) { it.Photo = u; it.Refresh(); }
            PatchAndShow(loc, updated, new HashSet<string>());
        }
        catch (Exception e) { ShowError(e, "Couldn’t update favorites", owner); }
    }

    public static async Task SetHidden(IReadOnlyList<Item> items, bool value, Location loc, DependencyObject? owner)
    {
        if (loc.AccountRef?.Photos is not { } photos) return;
        try
        {
            var updated = await photos.SetHiddenAsync(items.Where(i => i.Photo is not null).Select(i => i.Photo!).ToList(), value);
            PatchAndShow(loc, updated, updated.Select(u => u.Id).ToHashSet());   // hiding or unhiding takes it out of this view
        }
        catch (Exception e) { ShowError(e, "Couldn’t update", owner); }
    }

    /// <summary>Our own photo edits: patch every cached listing in place instead of re-downloading them.</summary>
    static void PatchAndShow(Location loc, IReadOnlyList<PhotoAsset> updated, IReadOnlySet<string> removed)
    {
        if (loc.Kind != LocKind.Album || loc.Account is not { } a || loc.Library is not { } lib) { Catalog.Shared.Invalidate(loc); return; }
        Catalog.Shared.PatchPhotos(a, lib, updated, removed);
        if (ListingCache.EditSensitive.Contains(loc.Id)) Catalog.Shared.Invalidate(loc);
    }

    // iCloud for Windows folders
    public static void KeepOnDevice(IReadOnlyList<Item> items, DependencyObject? owner)
    {
        foreach (var p in items.Select(i => i.LocalPath).OfType<string>())
            try { LocalFiles.Pin(p); } catch (Exception e) { ShowError(e, "Couldn’t download it", owner); return; }
    }

    public static void FreeUpSpace(IReadOnlyList<Item> items, DependencyObject? owner)
    {
        foreach (var p in items.Select(i => i.LocalPath).OfType<string>())
            try { LocalFiles.Unpin(p); } catch (Exception e) { ShowError(e, "Couldn’t remove the download", owner); return; }
    }
}
