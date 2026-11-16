using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;

namespace Cirrus.Core;

/// <summary>
/// Dropbox as Cirrus browses it (port of DropboxBackend.swift). See <see cref="DropboxCloud"/> for sign-in and the App
/// Console setup.
/// <para>
/// Items are addressed by Dropbox's file ids ("id:…"), which survive renames and moves; <see cref="RootID"/> ("root") is
/// the top of the Dropbox (path "" to the API). <see cref="DriveNode.DocID"/> carries the item's path_display as listed
/// (for display only: paths change when a folder above is renamed). Changes that need a destination path (new folders,
/// uploads, renames, moves) look the folder's current path up first, so a folder renamed or deleted elsewhere is never
/// recreated under its old name. Every change goes through a one-at-a-time gate, as Dropbox recommends, and is retried
/// when Dropbox reports write contention.
/// </para>
/// </summary>
public sealed partial class DropboxBackend : ICloudDriveBackend, ICloudTokenRotating
{
    public CloudProvider Provider => CloudProvider.Dropbox;
    public string RootID => "root";
    /// <summary>
    /// Dropbox's API can't list deleted files account-wide (only per folder, without dates or ids), so Cirrus leaves
    /// Deleted files to dropbox.com.
    /// </summary>
    public bool CanListTrash => false;
    public string AccountID { get; }

    internal DropboxHttp Http { get; }
    internal DropboxTokens Tokens { get; }
    internal DropboxGate Writes { get; }

    /// <summary>
    /// Files up to this size go up in one request (capped at Dropbox's 150 MB); larger ones through an upload session that
    /// resumes after interruptions.
    /// </summary>
    public long SimpleUploadLimit { get; set; } = 8 * 1024 * 1024;
    /// <summary>Upload-session chunk size (Dropbox recommends multiples of 4 MiB; at most 150 MB).</summary>
    public int ChunkSize { get; set; } = 16 * 1024 * 1024;
    /// <summary>Entries per listing page (Dropbox treats it as approximate; 1…2000).</summary>
    public int PageSize { get; set; } = 1000;
    /// <summary>Folders listed at once by <see cref="ListManyAsync"/>.</summary>
    public int Concurrency { get; set; } = 6;
    /// <summary>
    /// Changes (new folders, upload commits, renames, moves, deletions) sent at once. Dropbox locks the namespace for each
    /// one, so more than one mostly produces too_many_write_operations.
    /// </summary>
    public int WriteConcurrency { get => Writes.Limit; set => Writes.Limit = value; }

    internal const long MaxSimpleUpload = 150 * 1024 * 1024;
    /// <summary>Dropbox's limit for a file uploaded through the API (upload sessions).</summary>
    internal const long MaxFileSize = 350_000_000_000;

    internal DropboxBackend(string accountID, string appKey, string refreshToken, string? pathRoot, HttpMessageHandler? transport,
        DropboxTokenSet? initial = null)
    {
        AccountID = accountID;
        var client = CloudBackends.Http(transport);
        Tokens = new DropboxTokens(appKey, refreshToken, client, initial);
        Http = new DropboxHttp(client, Tokens, pathRoot);
        Writes = new DropboxGate(1);
    }

    /// <summary>
    /// Called if Dropbox ever hands out a new refresh token (it normally keeps the first one). Save it, e.g. with
    /// <c>CloudStore.SetSecret(record.Id, backend.Secret)</c>.
    /// </summary>
    public Action<string>? OnNewRefreshToken
    {
        get => Tokens.OnNewRefreshToken;
        set => Tokens.OnNewRefreshToken = value;
    }

    /// <summary>What to keep in the secret store for this account right now.</summary>
    public CloudSecret Secret => new() { RefreshToken = Tokens.CurrentRefreshToken, ClientID = Tokens.AppKey };

    /// <summary>Back-off base in seconds (tests make it tiny).</summary>
    public double RetryBase { get => Http.RetryBase; set => Http.RetryBase = value; }

    // MARK: Nodes

    /// <summary>Dropbox's path for an id ("" is the top of the Dropbox).</summary>
    string ApiPath(string id) => id == RootID || id.Length == 0 ? "" : id;

    /// <summary>Names Dropbox can't take, caught before anything is sent (a "/" would address a subfolder).</summary>
    internal static string CheckName(string raw)
    {
        var name = (raw ?? "").Normalize(NormalizationForm.FormC);
        if (name.Length == 0 || name == "." || name == "..") throw CloudException.Denied("Dropbox needs a name for the item.");
        if (name.Contains('/') || name.Any(char.IsControl))
            throw CloudException.Denied($"Dropbox doesn’t allow “/” or control characters in names. Rename “{name}” and try again.");
        return name;
    }

    /// <summary>Dropbox timestamps: UTC, whole seconds ("2026-11-16T09:30:00Z").</summary>
    internal static string Timestamp(DateTimeOffset d) =>
        DateTimeOffset.FromUnixTimeSeconds((long)Math.Floor(d.ToUnixTimeMilliseconds() / 1000.0)).UtcDateTime
            .ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);

    /// <summary>The folder part of a Dropbox path ("" for items at the top).</summary>
    internal static string ParentPath(string path)
    {
        var i = path.LastIndexOf('/');
        return i < 0 ? "" : path[..i];
    }

    /// <summary>
    /// A file or folder entry as a DriveNode inside <paramref name="folderID"/>. <paramref name="tag"/> for answers that are a
    /// FileMetadata or FolderMetadata struct (no ".tag"); deleted entries are skipped.
    /// </summary>
    internal DriveNode? Node(J j, string folderID, string? tag = null)
    {
        var kind = j[".tag"].Str ?? tag;
        if (kind is not ("file" or "folder") || j["id"].Str is not { Length: > 0 } id || j["name"].Str is not { } rawName) return null;
        var isFolder = kind == "folder";
        return new DriveNode
        {
            Id = id, DocID = j["path_display"].Str, Zone = "dropbox", ParentID = folderID.Length == 0 ? RootID : folderID,
            Name = rawName.Normalize(NormalizationForm.FormC), Type = isFolder ? "FOLDER" : "FILE", Size = isFolder ? 0 : j["size"].Int64 ?? 0,
            Modified = isFolder ? null : j["client_modified"].Date ?? j["server_modified"].Date, Etag = isFolder ? null : j["rev"].Str,
            IsShared = isFolder && (!j["sharing_info"]["shared_folder_id"].IsNull || !j["shared_folder_id"].IsNull),
        };
    }

    /// <summary>files/get_metadata; null when there's nothing at <paramref name="path"/> (deleted items count as nothing).</summary>
    internal async Task<J?> MetadataAsync(string path, CancellationToken ct)
    {
        var r = await Http.SendAsync(DropboxHttp.RpcRequest("files/get_metadata", new JsonObject { ["path"] = path, ["include_deleted"] = false }),
            DropboxRetry.Safe, ct: ct).ConfigureAwait(false);
        if (r.Status == 409 && r.Summary.Contains("not_found", StringComparison.Ordinal)) return null;
        if (!r.Ok) throw DropboxHttp.Error(r);
        return r.Json;
    }

    /// <summary>A folder's current path, looked up by id (paths change when folders above are renamed or moved).</summary>
    internal async Task<(string Display, string Lower)> FolderPathAsync(string id, CancellationToken ct)
    {
        if (id == RootID || id.Length == 0) return ("", "");
        if (await MetadataAsync(id, ct).ConfigureAwait(false) is not { } m) throw CloudException.NotFound();
        if (m[".tag"].Str != "folder") throw CloudException.Denied("That item isn’t a folder on Dropbox.");
        if (m["path_display"].Str is not { } display || m["path_lower"].Str is not { } lower)
            throw CloudException.Server("Dropbox didn’t say where that folder is. Try again.");
        return (display, lower);
    }

    static J Wrap(J metadata) => new(new JsonObject { ["metadata"] = metadata.Node?.DeepClone() });

    // MARK: Listing

    const string Incomplete = "Dropbox didn’t list a folder completely. Nothing was changed; try again.";

    public Task<List<DriveNode>> ListAsync(string folderID, CancellationToken ct = default)
    {
        var folder = string.IsNullOrEmpty(folderID) ? RootID : folderID;
        return DropboxHttp.Guarded(async () =>
        {
            int restarts = 0;
            while (true)
            {
                var output = new List<DriveNode>();
                var j = await Http.RpcAsync("files/list_folder", new JsonObject
                {
                    ["path"] = ApiPath(folder), ["recursive"] = false, ["include_deleted"] = false, ["include_mounted_folders"] = true,
                    ["include_non_downloadable_files"] = true, ["limit"] = Math.Max(1, Math.Min(PageSize, 2000)),
                }, DropboxRetry.Safe, ct: ct).ConfigureAwait(false);
                var restart = false;
                while (true)
                {
                    ct.ThrowIfCancellationRequested();
                    // A page without its entries would look like an empty folder ("everything deleted"): stop instead.
                    if (j["entries"].Node is not JsonArray) throw CloudException.Server(Incomplete);
                    output.AddRange(j["entries"].Array.Select(e => Node(e, folder)).OfType<DriveNode>());
                    if (j["has_more"].Bool != true) return output;
                    if (j["cursor"].Str is not { Length: > 0 } cursor) throw CloudException.Server(Incomplete);
                    var r = await Http.SendAsync(DropboxHttp.RpcRequest("files/list_folder/continue", new JsonObject { ["cursor"] = cursor }),
                        DropboxRetry.Safe, ct: ct).ConfigureAwait(false);
                    if (r.Status == 409 && r.Summary.StartsWith("reset", StringComparison.Ordinal) && restarts < 2)
                    {
                        // Dropbox invalidated the cursor: list the folder again from the start.
                        restarts++;
                        restart = true;
                        break;
                    }
                    if (!r.Ok) throw DropboxHttp.Error(r);
                    j = r.Json;
                }
                if (!restart) return output;
            }
        });
    }

    public async Task<Dictionary<string, List<DriveNode>>> ListManyAsync(IReadOnlyList<string> folderIDs, CancellationToken ct = default)
    {
        var unique = folderIDs.Distinct(StringComparer.Ordinal).ToList();
        if (unique.Count == 0) return [];
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        using var slots = new SemaphoreSlim(Math.Max(1, Math.Min(Concurrency, unique.Count)));
        var tasks = unique.Select(async id =>
        {
            await slots.WaitAsync(cts.Token).ConfigureAwait(false);
            try { return (Id: id, Nodes: await ListAsync(id, cts.Token).ConfigureAwait(false)); }
            catch (Exception e) when (e is not OperationCanceledException)
            {
                // Any failed folder throws (and cancels the rest): a missing folder must never look empty.
                try { cts.Cancel(); } catch (ObjectDisposedException) { }
                throw;
            }
            finally { slots.Release(); }
        }).ToList();
        var done = await Task.WhenAll(tasks).ConfigureAwait(false);
        return done.ToDictionary(x => x.Id, x => x.Nodes, StringComparer.Ordinal);
    }

    // MARK: Download

    public Task DownloadAsync(DriveNode node, string destination, Action<long, long>? progress, CancellationToken ct = default)
    {
        if (node.IsFolder) throw CloudException.Unsupported($"“{node.Name}” is a folder; Cirrus downloads the files inside it one by one.");
        return DropboxHttp.Guarded(async () =>
        {
            var expected = node.Size;
            var dir = Path.GetDirectoryName(Path.GetFullPath(destination))!;
            Directory.CreateDirectory(dir);
            var part = Path.Combine(dir, ".cirrus-dl-" + Guid.NewGuid().ToString("N")[..8]);
            try
            {
                var r = await Http.SendAsync(DropboxHttp.ContentRequest("files/download", new JsonObject { ["path"] = ApiPath(node.Id) }, upload: false),
                    DropboxRetry.Safe, sinkPath: part, received: (got, total) => progress?.Invoke(got, total > 0 ? total : expected), ct: ct).ConfigureAwait(false);
                if (!r.Ok) throw DropboxHttp.Error(r, node.Name);
                var meta = J.Parse(r.Header("Dropbox-API-Result"));
                var size = File.Exists(part) ? new FileInfo(part).Length : 0;
                if (!File.Exists(part)) await File.WriteAllBytesAsync(part, [], ct).ConfigureAwait(false);
                if (meta["size"].Int64 is { } want && want != size)
                    throw CloudException.Server($"The download of “{node.Name}” from Dropbox was incomplete. Try again.");
                File.Move(part, destination, overwrite: true);
                progress?.Invoke(size, Math.Max(size, expected));
                if ((meta["client_modified"].Date ?? node.Modified) is { } m)
                {
                    try { File.SetLastWriteTimeUtc(destination, m.UtcDateTime); } catch { }
                }
            }
            finally { try { if (File.Exists(part)) File.Delete(part); } catch { } }
        });
    }

    // MARK: Changes

    /// <summary>
    /// One change through the write gate. Dropbox's "busy" answers are retried inside SendAsync; after a lost answer (or a
    /// 5xx, where the change may or may not have happened) it is sent again, and if Dropbox then refuses it (409),
    /// <paramref name="landed"/> decides whether the first attempt did it after all.
    /// </summary>
    internal async Task<J> WriteAsync(string route, JsonNode arg, string? name, Func<Task<J?>>? landed, CancellationToken ct)
    {
        int failures = 0;
        bool ambiguous = false;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            DropboxResponse r;
            try
            {
                r = await Writes.RunAsync(() => Http.SendAsync(DropboxHttp.RpcRequest(route, arg), DropboxRetry.Unsafe, ct: ct), ct).ConfigureAwait(false);
            }
            catch (Exception e) when (!ct.IsCancellationRequested && e is not CloudException && GoogleHttp.IsTransient(e, ambiguousOK: true)
                                      && failures < Http.MaxRetries)
            {
                failures++;
                ambiguous = true;
                await DropboxHttp.SleepAsync(Http.Delay(failures, null), ct).ConfigureAwait(false);
                continue;
            }
            if (r.Ok) return r.Json;
            if (r.Status is >= 500 and <= 599 && failures < Http.MaxRetries)
            {
                failures++;
                ambiguous = true;
                await DropboxHttp.SleepAsync(Http.Delay(failures, null), ct).ConfigureAwait(false);
                continue;
            }
            if (ambiguous && r.Status == 409 && landed is not null && await landed().ConfigureAwait(false) is { } j) return j;
            throw DropboxHttp.Error(r, name);
        }
    }

    public Task<DriveNode> CreateFolderAsync(string name, string folderID, CancellationToken ct = default)
    {
        name = CheckName(name);
        return DropboxHttp.Guarded(async () =>
        {
            var parent = await FolderPathAsync(folderID, ct).ConfigureAwait(false);
            var path = parent.Display + "/" + name;
            // autorename false: Cirrus picks free names itself, so a clash is an error, never a silent rename.
            var j = await WriteAsync("files/create_folder_v2", new JsonObject { ["path"] = path, ["autorename"] = false }, name, async () =>
            {
                if (await MetadataAsync(path, ct).ConfigureAwait(false) is { } m && m[".tag"].Str == "folder") return Wrap(m);
                return null;
            }, ct).ConfigureAwait(false);
            return Node(j["metadata"], folderID, "folder") ?? throw CloudException.Server($"Dropbox didn’t confirm the new folder “{name}”.");
        });
    }

    public Task<DriveNode> RenameAsync(DriveNode node, string name, CancellationToken ct = default)
    {
        name = CheckName(name);
        if (node.Id == RootID) throw CloudException.Denied("The top of your Dropbox can’t be renamed.");
        return DropboxHttp.Guarded(async () =>
        {
            if (await MetadataAsync(node.Id, ct).ConfigureAwait(false) is not { } current || current["path_display"].Str is not { } path)
                throw CloudException.NotFound();
            var parentID = node.ParentID ?? RootID;
            if (current["name"].Str == name && Node(current, parentID) is { } same) return same;
            var to = ParentPath(path) + "/" + name;
            var currentParent = ParentPath(current["path_lower"].Str ?? "");
            var j = await WriteAsync("files/move_v2", new JsonObject
            {
                ["from_path"] = node.Id, ["to_path"] = to, ["autorename"] = false, ["allow_ownership_transfer"] = false,
            }, name, async () =>
            {
                if (await MetadataAsync(node.Id, ct).ConfigureAwait(false) is { } m && m["name"].Str == name
                    && ParentPath(m["path_lower"].Str ?? "") == currentParent) return Wrap(m);
                return null;
            }, ct).ConfigureAwait(false);
            return Node(j["metadata"], parentID) ?? throw CloudException.Server($"Dropbox didn’t confirm renaming “{name}”.");
        });
    }

    public Task MoveAsync(IReadOnlyList<DriveNode> nodes, string folderID, CancellationToken ct = default)
    {
        if (nodes.Count == 0) return Task.CompletedTask;
        return DropboxHttp.Guarded(async () =>
        {
            var target = await FolderPathAsync(folderID, ct).ConfigureAwait(false);
            // One at a time: Dropbox does one change per namespace at a time anyway.
            foreach (var n in nodes)
            {
                ct.ThrowIfCancellationRequested();
                if (n.Id == RootID) throw CloudException.Denied("The top of your Dropbox can’t be moved.");
                // The item's current name (it may have been renamed elsewhere since it was listed).
                if (await MetadataAsync(n.Id, ct).ConfigureAwait(false) is not { } m || m["name"].Str is not { } name || m["path_lower"].Str is not { } lower)
                    throw CloudException.NotFound();
                if (ParentPath(lower) == target.Lower) continue;   // already there
                await WriteAsync("files/move_v2", new JsonObject
                {
                    ["from_path"] = n.Id, ["to_path"] = target.Display + "/" + name, ["autorename"] = false, ["allow_ownership_transfer"] = false,
                }, name, async () =>
                {
                    if (await MetadataAsync(n.Id, ct).ConfigureAwait(false) is { } now && ParentPath(now["path_lower"].Str ?? "") == target.Lower) return Wrap(now);
                    return null;
                }, ct).ConfigureAwait(false);
            }
        });
    }

    /// <summary>
    /// Dropbox keeps deleted files and folders restorable (30 days or more, depending on the plan) under Deleted files on
    /// dropbox.com. Never permanently_delete.
    /// </summary>
    public Task TrashAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default) =>
        DropboxHttp.Guarded(async () =>
        {
            foreach (var n in nodes)
            {
                ct.ThrowIfCancellationRequested();
                if (n.Id == RootID) throw CloudException.Denied("The top of your Dropbox can’t be deleted.");
                try
                {
                    await WriteAsync("files/delete_v2", new JsonObject { ["path"] = ApiPath(n.Id) }, n.Name, null, ct).ConfigureAwait(false);
                }
                catch (CloudException e) when (e.Kind == CloudErrorKind.NotFound)
                {
                    // Already gone (or an earlier attempt whose answer was lost got there first).
                }
            }
        });

    public Task<List<DriveNode>> ListTrashAsync(CancellationToken ct = default) => Task.FromResult(new List<DriveNode>());

    public const string DeletedFilesMessage = "Cirrus can’t open Dropbox’s deleted files. To restore or permanently delete items, use Deleted files on dropbox.com.";

    public Task RestoreAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default) => throw CloudException.Unsupported(DeletedFilesMessage);

    public Task DeleteForeverAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default)
    {
        DriveBackendExtensions.GuardTrashOnly(nodes);
        throw CloudException.Unsupported(DeletedFilesMessage);
    }

    // MARK: Extras

    public Task<StorageUsage?> QuotaAsync(CancellationToken ct = default) =>
        DropboxHttp.Guarded(async () =>
        {
            var j = await Http.RpcAsync("users/get_space_usage", null, DropboxRetry.Safe, ct: ct).ConfigureAwait(false);
            var mine = j["used"].Int64 ?? 0;
            var a = j["allocation"];
            switch (a[".tag"].Str)
            {
                case "individual":
                {
                    if (a["allocated"].Int64 is not { } total || total <= 0) return null;
                    return new StorageUsage(total, mine, [new StorageUsage.Category("files", "Files", mine, "0061FE")]);
                }
                case "team":
                {
                    // A member limit, when the team set one, is what this user can fill; otherwise the team's pool.
                    if (a["user_within_team_space_allocated"].Int64 is { } limit && limit > 0)
                        return new StorageUsage(limit, mine, [new StorageUsage.Category("files", "Files", mine, "0061FE")]);
                    if (a["allocated"].Int64 is not { } total || total <= 0) return null;
                    var team = Math.Max(a["used"].Int64 ?? mine, mine);
                    var cats = new List<StorageUsage.Category> { new("files", "Your Files", mine, "0061FE") };
                    if (team > mine) cats.Add(new StorageUsage.Category("team", "Rest of Team", team - mine, "8A8886"));
                    return new StorageUsage(total, team, cats);
                }
                default:
                    return (StorageUsage?)null;
            }
        });

    /// <summary>The file types Dropbox makes thumbnails for (larger photos, over 20 MB, it doesn't).</summary>
    internal static readonly HashSet<string> ThumbnailExtensions = ["jpg", "jpeg", "png", "tiff", "tif", "gif", "webp", "ppm", "bmp", "heic", "heif"];
    internal static readonly (string Name, int Side)[] ThumbnailSizes =
    [
        ("w32h32", 32), ("w64h64", 64), ("w128h128", 128), ("w256h256", 256), ("w480h320", 480), ("w640h480", 640), ("w960h640", 960),
        ("w1024h768", 1024), ("w2048h1536", 2048),
    ];

    /// <summary>The smallest size whose longer side covers <paramref name="maxPixel"/> (mode bestfit turns it for portrait images).</summary>
    internal static string ThumbnailSize(int maxPixel) => ThumbnailSizes.FirstOrDefault(s => s.Side >= maxPixel).Name ?? "w2048h1536";

    public Task<byte[]?> ThumbnailAsync(DriveNode node, int maxPixel, CancellationToken ct = default)
    {
        if (node.IsFolder) return Task.FromResult<byte[]?>(null);
        var ext = Path.GetExtension(node.Name).TrimStart('.').ToLowerInvariant();
        if (!ThumbnailExtensions.Contains(ext)) return Task.FromResult<byte[]?>(null);
        var arg = new JsonObject
        {
            ["resource"] = new JsonObject { [".tag"] = "path", ["path"] = ApiPath(node.Id) },
            ["format"] = ext is "png" or "gif" ? "png" : "jpeg", ["size"] = ThumbnailSize(maxPixel), ["mode"] = "bestfit",
        };
        return DropboxHttp.Guarded(async () =>
        {
            var r = await Http.SendAsync(DropboxHttp.ContentRequest("files/get_thumbnail_v2", arg, upload: false), DropboxRetry.Safe, ct: ct).ConfigureAwait(false);
            if (r.Ok) return r.Data.Length == 0 ? null : r.Data;
            if (r.Status == 409) return null;   // unsupported_extension, unsupported_image, conversion_error, or gone
            throw DropboxHttp.Error(r, node.Name);
        });
    }
}
