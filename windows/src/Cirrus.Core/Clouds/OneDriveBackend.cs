using System.Collections.Concurrent;
using System.Globalization;
using System.Runtime.ExceptionServices;
using System.Text;
using System.Text.Json.Nodes;

namespace Cirrus.Core;

/// <summary>
/// Where a DriveNode id points (port of OneDriveRef). Most items live in the user's own drive and use Graph's driveItem id
/// as is ("root" is the top folder). Folders other people shared, once added to "My files", appear as shortcuts (a
/// driveItem with a <c>remoteItem</c> facet): browsing them lists the owner's drive, while renaming, moving or trashing the
/// shortcut must only touch the shortcut — never the owner's folder.
/// </summary>
readonly record struct OneDriveRef
{
    public enum Kinds { Own, InDrive, Shortcut }

    public Kinds Kind { get; }
    /// <summary>Own: the item. InDrive / Shortcut: the target item in <see cref="Drive"/>.</summary>
    public string Item { get; }
    public string? Drive { get; }
    /// <summary>Shortcut: the shortcut itself, in the user's drive.</summary>
    public string? Local { get; }

    OneDriveRef(Kinds kind, string item, string? drive, string? local) { Kind = kind; Item = item; Drive = drive; Local = local; }

    public static OneDriveRef Parse(string id)
    {
        var p = id.Split('|');
        if (p.Length == 3 && p[0] == "drive") return new(Kinds.InDrive, p[2], p[1], null);
        if (p.Length == 4 && p[0] == "shortcut") return new(Kinds.Shortcut, p[3], p[2], p[1]);
        return new(Kinds.Own, id, null, null);
    }

    public static string InDriveID(string drive, string item) => $"drive|{drive}|{item}";
    public static string ShortcutID(string local, string drive, string item) => $"shortcut|{local}|{drive}|{item}";

    static string Enc(string s) => OneDriveHttp.Encode(s, "!");

    /// <summary>The item whose contents this id stands for (a shortcut's target).</summary>
    public string ContentPath => Kind == Kinds.Own
        ? (Item == "root" ? "/me/drive/root" : "/me/drive/items/" + Enc(Item))
        : $"/drives/{Enc(Drive!)}/items/{Enc(Item)}";

    /// <summary>The item itself (for a shortcut: the shortcut in the user's drive).</summary>
    public string SelfPath => Kind == Kinds.Shortcut ? "/me/drive/items/" + Enc(Local!) : ContentPath;

    /// <summary>The drive that items inside this folder live in (null: the user's own).</summary>
    public string? ContentDrive => Kind == Kinds.Own ? null : Drive;

    /// <summary>The drive this item itself lives in (null: the user's own; shortcuts live in the user's drive).</summary>
    public string? SelfDrive => Kind == Kinds.InDrive ? Drive : null;
}

/// <summary>OneDrive as Cirrus browses it (port of OneDriveBackend.swift). See <see cref="OneDriveCloud"/> for sign-in.</summary>
public sealed partial class OneDriveBackend : ICloudDriveBackend, ICloudTokenRotating
{
    public CloudProvider Provider => CloudProvider.OneDrive;
    public string RootID => "root";
    /// <summary>OneDrive's recycle bin isn't available through Microsoft Graph for personal accounts, so Cirrus doesn't list it.</summary>
    public bool CanListTrash => false;
    public string AccountID { get; }

    internal OneDriveHttp Http { get; }
    readonly OneDriveTokens _tokens;
    readonly object _lock = new();
    string? _realRoot;

    /// <summary>Files up to this size go up in one request; larger ones through an upload session.</summary>
    public long SimpleUploadLimit { get; set; } = 4 * 1024 * 1024;
    /// <summary>Upload-session fragment size, rounded down to a multiple of 320 KiB as Microsoft requires.</summary>
    public int ChunkSize { get; set; } = 16 * FragmentUnit;
    /// <summary>Items per listing page.</summary>
    public int PageSize { get; set; } = 200;
    /// <summary>Folders listed at once by ListManyAsync, and items changed at once by MoveAsync / TrashAsync.</summary>
    public int Concurrency { get; set; } = 6;

    internal const int FragmentUnit = 327_680;
    internal const long MaxFileSize = 250L * 1_000_000_000;
    internal const string Select = "id,name,size,folder,file,package,remoteItem,root,parentReference,fileSystemInfo,createdDateTime,lastModifiedDateTime,eTag,cTag,shared";

    internal OneDriveBackend(string accountID, string clientID, string refreshToken, HttpMessageHandler? transport, OneDriveTokenSet? initial = null)
    {
        AccountID = accountID;
        var http = CloudBackends.Http(transport);
        _tokens = new OneDriveTokens(clientID, refreshToken, http, initial);
        Http = new OneDriveHttp(http, _tokens);
    }

    /// <summary>
    /// Called with every new refresh token Microsoft hands out (they rotate). Save it, e.g. with
    /// <c>CloudStore.SetSecret(record.Id, backend.Secret)</c>; the old one may stop working.
    /// </summary>
    public Action<string>? OnNewRefreshToken
    {
        get => _tokens.OnNewRefreshToken;
        set => _tokens.OnNewRefreshToken = value;
    }

    /// <summary>What to keep in the secret store for this account right now (the latest refresh token).</summary>
    public CloudSecret Secret => new() { RefreshToken = _tokens.CurrentRefreshToken, ClientID = _tokens.ClientID };

    /// <summary>Back-off base in seconds (tests make it tiny).</summary>
    public double RetryBase
    {
        get => Http.RetryBase;
        set => Http.RetryBase = value;
    }

    // MARK: Nodes

    /// <summary>OneDrive's naming rules, checked before anything is sent (a "/" would otherwise address a subfolder).</summary>
    internal static string CheckName(string raw)
    {
        var name = (raw ?? "").Normalize(NormalizationForm.FormC);
        if (name.Length == 0 || name == "." || name == "..") throw CloudException.Denied("OneDrive needs a name for the item.");
        if (HasInvalidCharacters(name))
            throw CloudException.Denied($"OneDrive doesn’t allow these characters in names: \" * : < > ? / \\ |. Rename “{name}” and try again.");
        return name;
    }

    /// <summary><c>" * : &lt; &gt; ? / \ |</c> and control or format characters (Swift's CharacterSet.controlCharacters).</summary>
    internal static bool HasInvalidCharacters(string name)
    {
        foreach (var r in name.EnumerateRunes())
        {
            if (r.IsAscii && "\"*:<>?/\\|".Contains((char)r.Value)) return true;
            if (Rune.GetUnicodeCategory(r) is UnicodeCategory.Control or UnicodeCategory.Format) return true;
        }
        return false;
    }

    /// <summary>
    /// One path segment for Graph's <c>items/{parent}:/{name}:</c> addressing: everything but unreserved ASCII is
    /// percent-encoded (UTF-8), so #, %, ?, +, spaces and non-Latin names reach OneDrive intact.
    /// </summary>
    internal static string EncodeName(string name) => OneDriveHttp.Encode(name);

    internal static string Iso(DateTimeOffset d) => d.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);

    /// <summary>"root" for the real root's id (Graph reports the top folder by its real id).</summary>
    internal string Normalize(string id)
    {
        lock (_lock) return id == _realRoot ? RootID : id;
    }

    internal async Task<string> RealRootIDAsync(CancellationToken ct)
    {
        lock (_lock) if (_realRoot is { } r) return r;
        var j = await Http.JsonAsync("GET", "/me/drive/root", [("$select", "id")], ct: ct).ConfigureAwait(false);
        if (j["id"].Str is not { Length: > 0 } id) throw CloudException.Server("OneDrive didn’t say which folder is the top of your drive.");
        lock (_lock) _realRoot = id;
        return id;
    }

    /// <summary>A driveItem as a DriveNode inside <paramref name="folderID"/>.</summary>
    internal DriveNode? Node(J j, string folderID)
    {
        if (j["id"].Str is not { Length: > 0 } raw || j["name"].Str is not { } rawName) return null;
        if (!j["root"].IsNull) lock (_lock) _realRoot ??= raw;
        var remote = j["remoteItem"];
        var folder = OneDriveRef.Parse(folderID);
        var id = folder.ContentDrive is { } cd ? OneDriveRef.InDriveID(cd, raw) : raw;
        var isFolder = !j["folder"].IsNull || !j["root"].IsNull;
        var childCount = j["folder"]["childCount"].Int;
        if (!remote.IsNull && folder.ContentDrive is null && remote["id"].Str is { } rid && remote["parentReference"]["driveId"].Str is { } rdrive)
        {
            id = OneDriveRef.ShortcutID(raw, rdrive, rid);
            isFolder = !remote["folder"].IsNull || isFolder;
            childCount = remote["folder"]["childCount"].Int ?? childCount;
        }
        // Packages (OneNote notebooks…) are shown as files: OneDrive can't list or zip their insides.
        var fs = j["fileSystemInfo"];
        return new DriveNode
        {
            Id = id, DocID = null, Zone = "onedrive", ParentID = Normalize(folderID), Name = rawName.Normalize(NormalizationForm.FormC),
            Type = isFolder ? "FOLDER" : "FILE", Size = isFolder ? 0 : j["size"].Int64 ?? remote["size"].Int64 ?? 0,
            Modified = fs["lastModifiedDateTime"].Date ?? j["lastModifiedDateTime"].Date, Created = fs["createdDateTime"].Date ?? j["createdDateTime"].Date,
            Etag = j["eTag"].Str ?? j["cTag"].Str, ChildCount = isFolder ? childCount : null, IsShared = !j["shared"].IsNull || !remote.IsNull,
        };
    }

    // MARK: Listing

    public Task<List<DriveNode>> ListAsync(string folderID, CancellationToken ct = default) => OneDriveHttp.Guarded(async () =>
    {
        var output = new List<DriveNode>();
        var url = OneDriveHttp.Graph + OneDriveRef.Parse(folderID).ContentPath + "/children";
        IReadOnlyList<(string, string)> query = [("$top", PageSize.ToString(CultureInfo.InvariantCulture)), ("$select", Select)];
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var j = await Http.JsonAsync("GET", url, query, ct: ct).ConfigureAwait(false);
            // A page without its item list would look like an empty folder ("everything deleted"): stop instead.
            if (j["value"].Node is not JsonArray)
                throw CloudException.Server("OneDrive didn’t list a folder completely. Nothing was changed; try again.");
            output.AddRange(j["value"].Array.Select(x => Node(x, folderID)).OfType<DriveNode>());
            if (j["@odata.nextLink"].Str is not { } next) return output;
            if (!OneDriveHttp.IsGraph(next))
                throw CloudException.Server("OneDrive’s next page pointed somewhere other than Microsoft Graph, so Cirrus stopped listing.");
            url = next;
            query = [];   // the next link already carries the query
        }
    });

    public async Task<Dictionary<string, List<DriveNode>>> ListManyAsync(IReadOnlyList<string> folderIDs, CancellationToken ct = default)
    {
        var unique = folderIDs.Distinct().ToList();
        var output = new ConcurrentDictionary<string, List<DriveNode>>();
        // Any failed folder throws (and cancels the rest): a missing folder must never look empty.
        await ForEachAsync(unique, async (id, t) => output[id] = await ListAsync(id, t).ConfigureAwait(false), ct).ConfigureAwait(false);
        return new Dictionary<string, List<DriveNode>>(output);
    }

    /// <summary>Runs <paramref name="op"/> for each item, a few at a time; the first failure cancels the rest and is thrown.</summary>
    internal async Task ForEachAsync<T>(IReadOnlyList<T> items, Func<T, CancellationToken, Task> op, CancellationToken ct)
    {
        if (items.Count == 0) return;
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        Exception? first = null;
        int next = -1;
        async Task Worker()
        {
            while (true)
            {
                var i = Interlocked.Increment(ref next);
                if (i >= items.Count) return;
                cts.Token.ThrowIfCancellationRequested();
                try { await op(items[i], cts.Token).ConfigureAwait(false); }
                catch (Exception e)
                {
                    Interlocked.CompareExchange(ref first, e, null);
                    try { cts.Cancel(); } catch (ObjectDisposedException) { }
                    throw;
                }
            }
        }
        var workers = Enumerable.Range(0, Math.Max(1, Math.Min(Concurrency, items.Count))).Select(_ => Task.Run(Worker, CancellationToken.None)).ToArray();
        try { await Task.WhenAll(workers).ConfigureAwait(false); }
        catch when (first is not null && !ct.IsCancellationRequested) { ExceptionDispatchInfo.Throw(first); }
    }

    // MARK: Download

    static readonly int[] Redirects = [301, 302, 303, 307, 308];

    public async Task DownloadAsync(DriveNode node, string destination, Action<long, long>? progress, CancellationToken ct = default)
    {
        if (node.IsFolder) throw CloudException.Unsupported($"“{node.Name}” is a folder; Cirrus downloads the files inside it one by one.");
        var r = OneDriveRef.Parse(node.Id);
        var dir = Path.GetDirectoryName(Path.GetFullPath(destination))!;
        Directory.CreateDirectory(dir);
        // Written next to the destination, then moved into place: a failed download never leaves half a file there.
        var part = Path.Combine(dir, ".cirrus-dl-" + Guid.NewGuid().ToString("N")[..8]);
        var expected = node.Size;
        void Report(long got, long total) => progress?.Invoke(got, total > 0 ? total : expected);
        try
        {
            await OneDriveHttp.Guarded(async () =>
            {
                int linkFailures = 0;
                while (true)
                {
                    ct.ThrowIfCancellationRequested();
                    // Graph answers 302 with a short-lived pre-authenticated URL on another host.
                    var first = await Http.SendAsync(GraphRequest.Make("GET", OneDriveHttp.Graph + r.ContentPath + "/content"), toFile: part,
                        received: Report, ct: ct).ConfigureAwait(false);
                    var final = first;
                    if (Redirects.Contains(first.Status))
                    {
                        if (first.Header("Location") is not { } loc || !Uri.TryCreate(first.Url, loc, out var u) || u.Scheme != Uri.UriSchemeHttps)
                            throw CloudException.Server($"OneDrive didn’t give a usable download address for “{node.Name}”.");
                        // No Authorization header: the URL itself carries the permission.
                        var hop = new GraphRequest { Method = "GET", Url = u.AbsoluteUri, Headers = new(StringComparer.OrdinalIgnoreCase) { ["Accept"] = "*/*" } };
                        final = await Http.SendAsync(hop, auth: false, toFile: part, received: Report, ct: ct).ConfigureAwait(false);
                        if (final.Status is 401 or 403 or 410 && linkFailures < 2)
                        {
                            // The link expired (they last minutes): ask Graph for a fresh one.
                            linkFailures++;
                            continue;
                        }
                    }
                    if (!final.Ok || final.File is null)
                    {
                        if (!OneDriveHttp.IsGraph(final.Url) && final.Status is 401 or 403 or 410)
                            throw CloudException.Server($"OneDrive’s download link for “{node.Name}” stopped working. Try again.");
                        if (final.Status is not 401 and not 404 and >= 400 and < 500 && await IsPackageAsync(r, ct).ConfigureAwait(false))
                            throw CloudException.Unsupported($"“{node.Name}” is a OneNote notebook or another package that OneDrive can’t download as a file. Open it on onedrive.com.");
                        throw OneDriveHttp.Error(final, node.Name);
                    }
                    File.Move(part, destination, overwrite: true);
                    var size = new FileInfo(destination).Length;
                    progress?.Invoke(size, Math.Max(size, expected));
                    if (node.Modified is { } m) { try { File.SetLastWriteTimeUtc(destination, m.UtcDateTime); } catch { } }
                    return;
                }
            }).ConfigureAwait(false);
        }
        finally { try { if (File.Exists(part)) File.Delete(part); } catch { } }
    }

    async Task<bool> IsPackageAsync(OneDriveRef r, CancellationToken ct)
    {
        try { return !(await Http.JsonAsync("GET", r.ContentPath, [("$select", "id,package")], ct: ct).ConfigureAwait(false))["package"].IsNull; }
        catch (OperationCanceledException) { throw; }
        catch { return false; }
    }

    // MARK: Changes

    public Task<DriveNode> CreateFolderAsync(string name, string folderID, CancellationToken ct = default)
    {
        var n = CheckName(name);
        return OneDriveHttp.Guarded(async () =>
        {
            // conflictBehavior fail: Cirrus picks free names itself, so a clash is an error, never a silent rename.
            var body = new JsonObject { ["name"] = n, ["folder"] = new JsonObject(), ["@microsoft.graph.conflictBehavior"] = "fail" };
            var j = await Http.JsonAsync("POST", OneDriveRef.Parse(folderID).ContentPath + "/children", body: body, retry: GraphRetry.Unsafe, name: n, ct: ct)
                .ConfigureAwait(false);
            return Node(j, folderID) ?? throw CloudException.Server($"OneDrive didn’t confirm the new folder “{n}”.");
        });
    }

    public Task<DriveNode> RenameAsync(DriveNode node, string name, CancellationToken ct = default)
    {
        var n = CheckName(name);
        return OneDriveHttp.Guarded(async () =>
        {
            var j = await Http.JsonAsync("PATCH", OneDriveRef.Parse(node.Id).SelfPath, [("@microsoft.graph.conflictBehavior", "fail")],
                new JsonObject { ["name"] = n }, name: n, ct: ct).ConfigureAwait(false);
            var copy = node.Copy();
            copy.Name = (j["name"].Str ?? n).Normalize(NormalizationForm.FormC);
            copy.Etag = j["eTag"].Str ?? copy.Etag;
            copy.Modified = j["fileSystemInfo"]["lastModifiedDateTime"].Date ?? copy.Modified;
            return copy;
        });
    }

    public async Task MoveAsync(IReadOnlyList<DriveNode> nodes, string folderID, CancellationToken ct = default)
    {
        if (nodes.Count == 0) return;
        var target = OneDriveRef.Parse(folderID);
        foreach (var n in nodes)
            if (OneDriveRef.Parse(n.Id).SelfDrive != target.ContentDrive)
                throw CloudException.Unsupported($"OneDrive can’t move “{n.Name}” between your files and a folder someone shared with you. Copy it instead.");
        await OneDriveHttp.Guarded(async () =>
        {
            // OneDrive wants the top folder's real id; "root" is Cirrus's name for it.
            var parent = target.Kind == OneDriveRef.Kinds.Own
                ? new JsonObject { ["id"] = target.Item == RootID ? await RealRootIDAsync(ct).ConfigureAwait(false) : target.Item }
                : new JsonObject { ["driveId"] = target.Drive, ["id"] = target.Item };
            await ForEachAsync(nodes, async (n, t) =>
            {
                await Http.JsonAsync("PATCH", OneDriveRef.Parse(n.Id).SelfPath, [("@microsoft.graph.conflictBehavior", "fail")],
                    new JsonObject { ["parentReference"] = parent.DeepClone() }, name: n.Name, ct: t).ConfigureAwait(false);
            }, ct).ConfigureAwait(false);
        }).ConfigureAwait(false);
    }

    /// <summary>OneDrive's DELETE moves items to its recycle bin (kept 30 days personal, 93 days work/school).</summary>
    public Task TrashAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default) => OneDriveHttp.Guarded(() =>
        ForEachAsync(nodes, async (n, t) =>
        {
            var r = await Http.SendAsync(GraphRequest.Make("DELETE", OneDriveHttp.Graph + OneDriveRef.Parse(n.Id).SelfPath), ct: t).ConfigureAwait(false);
            // 404: already gone (or an earlier attempt whose answer was lost got there first).
            if (!r.Ok && r.Status != 404) throw OneDriveHttp.Error(r, n.Name);
        }, ct));

    public Task<List<DriveNode>> ListTrashAsync(CancellationToken ct = default) => Task.FromResult(new List<DriveNode>());

    public const string RecycleBinMessage = "Cirrus can’t open OneDrive’s Recycle Bin. To restore or permanently delete items, use the Recycle Bin on onedrive.com.";

    public Task RestoreAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default) => throw CloudException.Unsupported(RecycleBinMessage);

    public Task DeleteForeverAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default)
    {
        DriveBackendExtensions.GuardTrashOnly(nodes);
        throw CloudException.Unsupported(RecycleBinMessage);
    }

    // MARK: Extras

    public Task<StorageUsage?> QuotaAsync(CancellationToken ct = default) => OneDriveHttp.Guarded(async () =>
    {
        var q = (await Http.JsonAsync("GET", "/me/drive", [("$select", "quota")], ct: ct).ConfigureAwait(false))["quota"];
        if (q["total"].Int64 is not { } total || total <= 0) return (StorageUsage?)null;
        var used = q["used"].Int64 ?? Math.Max(0, total - (q["remaining"].Int64 ?? total));
        var cats = new List<StorageUsage.Category>();
        if (q["deleted"].Int64 is { } deleted && deleted > 0)
        {
            cats.Add(new StorageUsage.Category("files", "Files", Math.Max(0, used - deleted), "0078D4"));
            cats.Add(new StorageUsage.Category("deleted", "Recycle Bin", deleted, "8A8886"));
        }
        else cats.Add(new StorageUsage.Category("files", "Files", used, "0078D4"));
        return new StorageUsage(total, used, cats);
    });

    public async Task<byte[]?> ThumbnailAsync(DriveNode node, int maxPixel, CancellationToken ct = default)
    {
        if (node.IsFolder) return null;
        var px = Math.Max(16, Math.Min(maxPixel, 1600));
        var named = px <= 96 ? "small" : px <= 176 ? "medium" : "large";
        var baseURL = OneDriveHttp.Graph + OneDriveRef.Parse(node.Id).ContentPath + "/thumbnails/0/";
        return await OneDriveHttp.Guarded(async () =>
        {
            // c{w}x{h}: fits in the box, aspect ratio kept. Accounts without custom sizes get the nearest named one.
            foreach (var size in new[] { $"c{px}x{px}", named })
            {
                var r = await Http.SendAsync(GraphRequest.Make("GET", baseURL + size + "/content"), ct: ct).ConfigureAwait(false);
                if (Redirects.Contains(r.Status))
                {
                    if (r.Header("Location") is not { } loc || !Uri.TryCreate(r.Url, loc, out var u)) return null;
                    r = await Http.SendAsync(new GraphRequest { Method = "GET", Url = u.AbsoluteUri }, auth: false, ct: ct).ConfigureAwait(false);
                }
                switch (r.Status)
                {
                    case >= 200 and < 300: return r.Data.Length == 0 ? null : r.Data;
                    case 404: return null;
                    case 400 or 406 or 415: continue;   // this size (or a thumbnail for this type) isn't offered
                    default: throw OneDriveHttp.Error(r, node.Name);
                }
            }
            return (byte[]?)null;
        }).ConfigureAwait(false);
    }
}
