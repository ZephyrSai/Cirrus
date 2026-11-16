using System.Collections.Concurrent;
using System.Runtime.ExceptionServices;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Cirrus.Core;

/// <summary>
/// Google Drive (My Drive) as a Cirrus account, over Drive v3 with the full <c>drive</c> scope and the user's own OAuth
/// client (port of GoogleDriveBackend.swift). Built on the migration's <see cref="GoogleApi"/> (tokens, retries,
/// back-off, the token only for Google's hosts) and <see cref="GoogleDrive"/> (uploads, downloads, exports).
/// <para>How Google's items appear:</para>
/// <list type="bullet">
/// <item>ids are Drive file ids; <see cref="RootID"/> is "root" (children of My Drive's real root get <c>ParentID == "root"</c>);</item>
/// <item>Docs, Sheets, Slides and Drawings are files named with their export extension (“Budget” → “Budget.xlsx”, size 0,
///   <see cref="DriveNode.Zone"/> = their Google MIME type); downloading exports them (<see cref="ExportFormat"/>); renaming
///   leaves that extension off Google's title. Forms, Sites, My Maps… are listed, but downloading them throws Unsupported;</item>
/// <item>shortcuts keep their own id (renaming, moving or trashing one changes the shortcut, never what it points to). A
///   shortcut to a folder is a folder that shows the target's contents; a shortcut to a file is that file (downloading
///   fetches the target). Items reached through folder shortcuts get ids of the form "&lt;id&gt;~&lt;shortcut&gt;~…" (the
///   shortcuts followed on the way), so a shortcut that leads back into itself shows as empty instead of making a walk
///   go round forever;</item>
/// <item>My Drive only: shared drives and “Shared with me” aren't listed yet.</item>
/// </list>
/// Every node keeps what downloads need: <see cref="DriveNode.DocID"/> is the id whose content to fetch (a shortcut's
/// target), <see cref="DriveNode.Zone"/> that item's MIME type, <see cref="DriveNode.Etag"/> its MD5 (or modified time
/// when Google keeps no MD5).
/// </summary>
public sealed class GoogleDriveBackend : ICloudDriveBackend, ICloudTokenRotating
{
    public CloudProvider Provider => CloudProvider.GoogleDrive;
    public string RootID => "root";
    public bool CanListTrash => true;

    /// <summary>What Google lets this account do with an item (from the latest listing).</summary>
    public sealed record Capabilities(bool CanDownload, bool CanRename, bool CanTrash);

    internal const string ShortcutMime = "application/vnd.google-apps.shortcut";
    internal const string ListFields = "id,name,mimeType,size,modifiedTime,createdTime,parents,md5Checksum,hasThumbnail,thumbnailLink,shared,"
        + "capabilities(canDownload,canRename,canTrash),shortcutDetails(targetId,targetMimeType)";
    const string ContentFields = "id,name,mimeType,size,modifiedTime,md5Checksum";
    const int ListConcurrency = 6;
    const int WriteConcurrency = 4;
    const int InfoCacheLimit = 50_000;

    public GoogleApi Api { get; }
    internal GoogleDrive Drive { get; }
    readonly GoogleOAuthClient _client;
    readonly object _lock = new();
    string _refreshToken;
    Action<string>? _onNewRefreshToken;
    GoogleDocFormat _exportFormat = GoogleDocFormat.Office;
    string? _realRoot;
    readonly Dictionary<string, (string Id, string Mime)> _shortcuts = [];
    readonly Dictionary<string, string> _thumbnails = [];          // file id → thumbnailLink ("" = none)
    readonly Dictionary<string, Capabilities> _capabilities = [];

    /// <param name="accountID">Only for logs and Google's per-account bookkeeping (the record id).</param>
    public GoogleDriveBackend(string accountID, GoogleOAuthClient client, string refreshToken, HttpMessageHandler? transport = null)
    {
        _client = client;
        _refreshToken = refreshToken;
        var oauth = new GoogleOAuth(client, transport);
        Api = new GoogleApi(accountID, oauth, [GoogleScopes.Drive], _ => Task.FromResult(CurrentRefreshToken), transport) { OnNewRefreshToken = Rotated };
        Drive = new GoogleDrive(Api);
    }

    string CurrentRefreshToken { get { lock (_lock) return _refreshToken; } }

    /// <summary>What the account needs to sign back in (changes only when Google hands out a new refresh token).</summary>
    public CloudSecret Secret => new() { RefreshToken = CurrentRefreshToken, ClientID = _client.ClientID, ClientSecret = _client.ClientSecret };

    /// <summary>
    /// Called with the new refresh token when Google hands one out, so it can be saved (the rest of <see cref="Secret"/>
    /// stays the same). Google rarely does; the old token may stop working when it does.
    /// </summary>
    public Action<string>? OnNewRefreshToken { get { lock (_lock) return _onNewRefreshToken; } set { lock (_lock) _onNewRefreshToken = value; } }

    /// <summary>How Docs, Sheets and Slides are named and downloaded (Office files by default, or PDF).</summary>
    public GoogleDocFormat ExportFormat { get { lock (_lock) return _exportFormat; } set { lock (_lock) _exportFormat = value; } }

    void Rotated(string t)
    {
        lock (_lock)
        {
            if (t.Length == 0 || t == _refreshToken) return;
            _refreshToken = t;
        }
        Log.Status("google drive: new refresh token");
        OnNewRefreshToken?.Invoke(t);
    }

    /// <summary>Can-download/rename/trash for an item listed earlier (null when not listed in this run).</summary>
    public Capabilities? CapabilitiesOf(DriveNode node)
    {
        lock (_lock) return _capabilities.GetValueOrDefault(Ref.Parse(node.Id).Real);
    }

    // MARK: Ids

    /// <summary>A node id: the Drive id, then the folder shortcuts followed to reach it ("&lt;id&gt;~&lt;shortcut&gt;~…").</summary>
    internal readonly record struct Ref(string Real, IReadOnlyList<string> Via)
    {
        public static Ref Parse(string id)
        {
            var p = id.Split('~');
            return new Ref(p[0], p[1..]);
        }
        public static string Id(string real, IReadOnlyList<string> via) => via.Count == 0 ? real : real + "~" + string.Join('~', via);
    }

    static readonly string[] ExportableKinds = ["document", "spreadsheet", "presentation", "drawing", "script", "jam"];

    internal static bool IsNative(string mime) =>
        mime.StartsWith(CloudConventions.GoogleNativePrefix, StringComparison.Ordinal) && mime != GoogleDrive.FolderMime && mime != ShortcutMime;

    static bool IsMD5(string s) => s.Length == 32 && s.All(Uri.IsHexDigit);

    static string FileURL(string id) => GoogleDrive.Base + "/files/" + Uri.EscapeDataString(id);

    /// <summary>My Drive's real root id (fetched once).</summary>
    async Task<string> MyDriveRootAsync(CancellationToken ct)
    {
        lock (_lock) if (_realRoot is { } r) return r;
        var root = await Drive.RootFolderIDAsync(ct).ConfigureAwait(false);
        lock (_lock) _realRoot = root;
        return root;
    }

    (string Id, string Mime)? Shortcut(string id)
    {
        lock (_lock) return _shortcuts.TryGetValue(id, out var t) ? t : null;
    }

    Task<J> MetadataAsync(string id, string fields, CancellationToken ct) =>
        Api.JsonAsync("GET", FileURL(id), new Dictionary<string, string> { ["fields"] = fields }, idempotent: true, ct: ct);

    /// <summary>The real folder new items go into: a folder shortcut leads to its target, "root" to My Drive.</summary>
    async Task<string> DestinationAsync(string folderID, CancellationToken ct)
    {
        var r = Ref.Parse(folderID);
        if (r.Real == RootID) return await MyDriveRootAsync(ct).ConfigureAwait(false);
        if (Shortcut(r.Real) is { } t)
        {
            if (t.Mime != GoogleDrive.FolderMime) throw CloudException.Unsupported("That shortcut points to a file, not a folder.");
            return t.Id;
        }
        return r.Real;
    }

    /// <summary>The shortcuts followed to reach items inside <paramref name="folderID"/>.</summary>
    IReadOnlyList<string> ViaForChildren(string folderID)
    {
        var r = Ref.Parse(folderID);
        if (Shortcut(r.Real) is { Mime: GoogleDrive.FolderMime }) return [.. r.Via, r.Real];
        return r.Via;
    }

    // MARK: Nodes

    /// <summary>Drive file resources → nodes, remembering shortcut targets, thumbnail links and capabilities.</summary>
    List<DriveNode> Nodes(IEnumerable<J> files, IReadOnlyList<string> via, Func<J, string?> parent)
    {
        var format = ExportFormat;
        var output = new List<DriveNode>();
        var found = new List<(string, (string, string))>();
        var thumbs = new List<(string, string)>();
        var caps = new List<(string, Capabilities)>();
        foreach (var j in files)
        {
            if (j["id"].Str is not { Length: > 0 } id) continue;
            var mime = j["mimeType"].Str ?? "";
            string contentID = id, contentMime = mime;
            if (mime == ShortcutMime && j["shortcutDetails"]["targetId"].Str is { Length: > 0 } target)
            {
                contentID = target;
                contentMime = j["shortcutDetails"]["targetMimeType"].Str ?? "";
                found.Add((id, (target, contentMime)));
            }
            var isFolder = contentMime == GoogleDrive.FolderMime;
            var name = (j["name"].Str ?? "").Normalize(NormalizationForm.FormC);
            var size = j["size"].Int64 ?? 0;
            if (IsNative(contentMime))
            {
                size = 0;
                if (format.Target(contentMime)?.Ext is { } ext && !name.EndsWith("." + ext, StringComparison.OrdinalIgnoreCase)) name += "." + ext;
            }
            if (contentID != id) size = 0;      // a shortcut: the target's size isn't in the listing
            output.Add(new DriveNode
            {
                Id = Ref.Id(id, via), DocID = contentID, Zone = contentMime, ParentID = parent(j), Name = name,
                Type = isFolder ? "FOLDER" : "FILE", Size = size, Modified = j["modifiedTime"].Date, Created = j["createdTime"].Date,
                Etag = j["md5Checksum"].Str ?? j["modifiedTime"].Str, IsShared = j["shared"].Bool ?? false,
            });
            if (contentID == id && !isFolder)
                thumbs.Add((id, j["hasThumbnail"].Bool == true ? j["thumbnailLink"].Str ?? "" : ""));
            var c = j["capabilities"];
            caps.Add((id, new Capabilities(c["canDownload"].Bool ?? true, c["canRename"].Bool ?? true, c["canTrash"].Bool ?? true)));
        }
        lock (_lock)
        {
            foreach (var (k, v) in found) _shortcuts[k] = v;
            if (_thumbnails.Count > InfoCacheLimit) _thumbnails.Clear();
            if (_capabilities.Count > InfoCacheLimit) _capabilities.Clear();
            foreach (var (k, v) in thumbs) _thumbnails[k] = v;
            foreach (var (k, v) in caps) _capabilities[k] = v;
        }
        return output;
    }

    /// <summary>Node for a file Cirrus just uploaded or created.</summary>
    static DriveNode NodeFor(GDriveFile f, string parentID, IReadOnlyList<string> via, DateTimeOffset? fallbackModified)
    {
        var folder = f.MimeType == GoogleDrive.FolderMime;
        var modified = f.Modified ?? fallbackModified ?? DateTimeOffset.UtcNow;
        return new DriveNode
        {
            Id = Ref.Id(f.Id, via), DocID = f.Id, Zone = f.MimeType, ParentID = parentID, Name = f.Name.Normalize(NormalizationForm.FormC),
            Type = folder ? "FOLDER" : "FILE", Size = folder ? 0 : f.Size, Modified = modified, Created = DateTimeOffset.UtcNow,
            Etag = f.Md5 ?? GoogleDrive.Iso(modified),
        };
    }

    // MARK: Listing

    static CloudException Incomplete() => CloudException.Server("Google Drive sent an incomplete folder listing. Nothing was changed; try again.");

    /// <summary>Every page of a files.list query. A failed or partial page throws; it never looks like an empty folder.</summary>
    async Task<List<DriveNode>> QueryAsync(string q, string extraFields, IReadOnlyList<string> via, Func<J, bool> keep, Func<J, string?> parent,
        CancellationToken ct)
    {
        var output = new List<DriveNode>();
        string? page = null;
        do
        {
            ct.ThrowIfCancellationRequested();
            var query = new Dictionary<string, string>
            {
                ["q"] = q, ["fields"] = $"nextPageToken,incompleteSearch,files({ListFields}{extraFields})", ["pageSize"] = "1000", ["spaces"] = "drive",
            };
            if (page is not null) query["pageToken"] = page;
            var j = await Api.JsonAsync("GET", GoogleDrive.Base + "/files", query, idempotent: true, ct: ct).ConfigureAwait(false);
            if (j["files"].Node is not JsonArray || j["incompleteSearch"].Bool == true) throw Incomplete();
            output.AddRange(Nodes(j["files"].Array.Where(keep), via, parent));
            page = j["nextPageToken"].Str is { Length: > 0 } next ? next : null;
        } while (page is not null);
        return output;
    }

    /// <summary>One folder's children (every page).</summary>
    Task<List<DriveNode>> ChildrenAsync(string parent, string parentID, IReadOnlyList<string> via, CancellationToken ct) =>
        QueryAsync($"{GoogleDrive.Quote(parent)} in parents and trashed = false", "", via, _ => true, _ => parentID, ct);

    async Task<List<DriveNode>> ListFolderAsync(string folderID, CancellationToken ct)
    {
        var r = Ref.Parse(folderID);
        if (Shortcut(r.Real) is { } t) return await ListShortcutAsync(r, t, folderID, ct).ConfigureAwait(false);
        var parentID = folderID;
        if (r.Real != RootID && r.Via.Count == 0 && await MyDriveRootAsync(ct).ConfigureAwait(false) == r.Real) parentID = RootID;
        var items = await ChildrenAsync(r.Real, parentID, r.Via, ct).ConfigureAwait(false);
        if (items.Count > 0 || parentID == RootID) return items;
        // Google lists nothing for a folder that's gone or in the trash, and for a shortcut: check before saying “empty”.
        var meta = await MetadataAsync(r.Real, "id,mimeType,trashed,shortcutDetails(targetId,targetMimeType)", ct).ConfigureAwait(false);
        if (meta["trashed"].Bool == true) throw CloudException.NotFound();
        var mime = meta["mimeType"].Str ?? "";
        if (mime == ShortcutMime && meta["shortcutDetails"]["targetId"].Str is { } target)
        {
            var found = (target, meta["shortcutDetails"]["targetMimeType"].Str ?? "");
            lock (_lock) _shortcuts[r.Real] = found;
            return await ListShortcutAsync(r, found, folderID, ct).ConfigureAwait(false);
        }
        if (mime != GoogleDrive.FolderMime) throw CloudException.NotFound();
        return [];
    }

    Task<List<DriveNode>> ListShortcutAsync(Ref r, (string Id, string Mime) target, string folderID, CancellationToken ct)
    {
        if (target.Mime != GoogleDrive.FolderMime) throw CloudException.NotFound();   // a shortcut to a file isn't a folder
        // Followed on the way here already: it leads back into itself, and following it again would never end.
        if (r.Via.Contains(r.Real)) return Task.FromResult(new List<DriveNode>());
        return ChildrenAsync(target.Id, folderID, [.. r.Via, r.Real], ct);
    }

    public Task<List<DriveNode>> ListAsync(string folderID, CancellationToken ct = default) =>
        Mapped(() => ListFolderAsync(folderID, ct), ct);

    public Task<Dictionary<string, List<DriveNode>>> ListManyAsync(IReadOnlyList<string> folderIDs, CancellationToken ct = default) =>
        Mapped(async () =>
        {
            var output = new ConcurrentDictionary<string, List<DriveNode>>();
            await EachAsync(folderIDs.Distinct().ToList(), ListConcurrency, async (id, c) => output[id] = await ListFolderAsync(id, c).ConfigureAwait(false), ct)
                .ConfigureAwait(false);
            return new Dictionary<string, List<DriveNode>>(output);
        }, ct);

    /// <summary>
    /// Items called <paramref name="name"/> in a folder (Google Drive allows several). Docs, Sheets and Slides match by
    /// their listed name, export extension included.
    /// </summary>
    public Task<List<DriveNode>> ItemsNamedAsync(string name, string folderID, CancellationToken ct = default) =>
        Mapped(async () =>
        {
            var parent = await DestinationAsync(folderID, ct).ConfigureAwait(false);
            var via = ViaForChildren(folderID);
            var titles = new List<string> { name };
            var dot = name.LastIndexOf('.');
            var ext = dot > 0 ? name[(dot + 1)..].ToLowerInvariant() : "";
            var stem = dot > 0 ? name[..dot] : name;
            var format = ExportFormat;
            var exportExts = ExportableKinds.Select(k => format.Target(CloudConventions.GoogleNativePrefix + k)?.Ext).OfType<string>().ToHashSet();
            if (stem.Length > 0 && ext.Length > 0 && exportExts.Contains(ext)) titles.Add(stem);   // a Doc/Sheet/Slides is titled without it
            var output = new List<DriveNode>();
            foreach (var title in titles)
                output.AddRange(await QueryAsync($"name = {GoogleDrive.Quote(title)} and {GoogleDrive.Quote(parent)} in parents and trashed = false", "", via,
                    _ => true, _ => folderID, ct).ConfigureAwait(false));
            var want = name.Normalize(NormalizationForm.FormC);
            var seen = new HashSet<string>();
            return output.Where(n => n.Name == want && seen.Add(n.Id)).ToList();
        }, ct);

    // MARK: Transfers

    /// <summary>Downloads a file (or exports a Doc/Sheet/Slides) next to the destination, moves it into place and sets its date.</summary>
    public Task DownloadAsync(DriveNode node, string destination, Action<long, long>? progress, CancellationToken ct = default) =>
        Mapped<bool>(async () =>
        {
            if (node.IsFolder) throw CloudException.Unsupported($"“{node.Name}” is a folder; download what's inside it instead.");
            var r = Ref.Parse(node.Id);
            var contentID = node.DocID ?? r.Real;
            var dir = Path.GetDirectoryName(Path.GetFullPath(destination))!;
            Directory.CreateDirectory(dir);
            var temp = Path.Combine(dir, "." + Guid.NewGuid().ToString("N")[..12] + ".cirrus-download");
            try
            {
                var modified = node.Modified;
                if (contentID != r.Real)
                {
                    // A shortcut: what it points to isn't in the listing, so ask for it.
                    var meta = await MetadataAsync(contentID, ContentFields, ct).ConfigureAwait(false);
                    if (meta["mimeType"].Str == GoogleDrive.FolderMime) throw CloudException.Unsupported($"“{node.Name}” is a shortcut to a folder.");
                    modified = meta["modifiedTime"].Date ?? modified;
                    await FetchAsync(new GDriveItem(meta), node.Name, temp, progress, ct).ConfigureAwait(false);
                }
                else
                {
                    var item = new GDriveItem { Id = contentID, Name = node.Name, MimeType = node.Zone, Size = IsNative(node.Zone) ? null : node.Size };
                    if (node.Etag is { } e && IsMD5(e)) item.Md5 = e.ToLowerInvariant();
                    await FetchAsync(item, node.Name, temp, progress, ct).ConfigureAwait(false);
                }
                File.Move(temp, destination, overwrite: true);
                if (modified is { } m) { try { File.SetLastWriteTimeUtc(destination, m.UtcDateTime); } catch { } }
            }
            finally
            {
                try { if (File.Exists(temp)) File.Delete(temp); } catch { }
            }
            return true;
        }, ct);

    static bool TooLargeToExport(GoogleException e) =>
        e.Kind == GoogleErrorKind.Http && e.Status is 400 or 403 or 413
        && (e.Detail.Contains("too large", StringComparison.OrdinalIgnoreCase) || e.Detail.Contains("exportsizelimit", StringComparison.OrdinalIgnoreCase));

    /// <summary>The listing was out of date (the file changed since): sizes or checksums no longer match.</summary>
    static bool StaleListing(GoogleException e) => e.Kind switch
    {
        GoogleErrorKind.Http => e.Status == 416,
        GoogleErrorKind.BadResponse => e.Detail.Contains("checksum", StringComparison.Ordinal) || e.Detail.Contains("sent no data", StringComparison.Ordinal),
        _ => false,
    };

    async Task FetchAsync(GDriveItem item, string name, string dest, Action<long, long>? progress, CancellationToken ct)
    {
        if (item.IsGoogleNative)
        {
            var target = ExportFormat.Target(item.MimeType)
                ?? throw CloudException.Unsupported($"“{name}” can’t be downloaded: {GoogleDocFormats.KindName(item.MimeType)} can’t be exported from Google Drive. Open it in Google Drive on the web.");
            long n;
            try { n = await Drive.ExportAsync(item, target, dest, ct).ConfigureAwait(false); }
            catch (GoogleException e) when (item.ExportLinks.Count == 0 && TooLargeToExport(e))
            {
                // Over files.export's 10 MB: the file's export links take bigger ones.
                var withLinks = new GDriveItem(await MetadataAsync(item.Id, "id,name,mimeType,exportLinks", ct).ConfigureAwait(false));
                n = await Drive.ExportAsync(withLinks, target, dest, ct).ConfigureAwait(false);
            }
            progress?.Invoke(n, n);
            return;
        }
        try { await Drive.DownloadAsync(item, dest, progress, ct).ConfigureAwait(false); }
        catch (GoogleException e) when (StaleListing(e))
        {
            var fresh = new GDriveItem(await MetadataAsync(item.Id, ContentFields, ct).ConfigureAwait(false));
            try { File.Delete(dest); } catch { }
            await Drive.DownloadAsync(fresh, dest, progress, ct).ConfigureAwait(false);
        }
    }

    /// <summary>
    /// Uploads a new file (resumable, in chunks) with its modification date. Google Drive keeps same-named files side by
    /// side; replacing one is the caller's choice.
    /// </summary>
    public Task<DriveNode> UploadAsync(string file, string name, string folderID, DateTimeOffset? modified, Action<long, long>? progress,
        CancellationToken ct = default) =>
        Mapped(async () =>
        {
            var size = new FileInfo(file).Length;
            if (size > GoogleDrive.MaxFileSize) throw CloudException.Denied($"“{name}” is {size.ByteString()}, larger than Google Drive’s 5 TB file limit.");
            var parent = await DestinationAsync(folderID, ct).ConfigureAwait(false);
            var restarted = false;
            while (true)
            {
                var session = await Drive.StartUploadAsync(name, parent, size, modified, ct: ct).ConfigureAwait(false);
                try
                {
                    var f = await Drive.UploadAsync(file, session, resume: false, progress, ct).ConfigureAwait(false);
                    return NodeFor(f, folderID, ViaForChildren(folderID), modified);
                }
                catch (GoogleException e) when (e.Kind == GoogleErrorKind.UploadExpired && !restarted)
                {
                    restarted = true;   // Google dropped the session: start over once
                }
            }
        }, ct);

    public Task<DriveNode> CreateFolderAsync(string name, string folderID, CancellationToken ct = default) =>
        Mapped(async () =>
        {
            var f = await Drive.CreateFolderAsync(name, await DestinationAsync(folderID, ct).ConfigureAwait(false), ct: ct).ConfigureAwait(false);
            return NodeFor(f, folderID, ViaForChildren(folderID), null);
        }, ct);

    // MARK: Changes

    /// <summary>Renames on Google. For Docs/Sheets/Slides the export extension Cirrus shows isn't part of Google's title.</summary>
    public Task<DriveNode> RenameAsync(DriveNode node, string name, CancellationToken ct = default) =>
        Mapped(async () =>
        {
            var r = Ref.Parse(node.Id);
            var title = name;
            if (!node.IsFolder && IsNative(node.Zone) && ExportFormat.Target(node.Zone)?.Ext is { } ext
                && title.EndsWith("." + ext, StringComparison.OrdinalIgnoreCase) && title.Length > ext.Length + 1)
                title = title[..^(ext.Length + 1)];
            var j = await Api.JsonAsync("PATCH", FileURL(r.Real), new Dictionary<string, string> { ["fields"] = ListFields }, new JsonObject { ["name"] = title },
                idempotent: true, ct: ct).ConfigureAwait(false);
            return Nodes([j], r.Via, _ => node.ParentID).FirstOrDefault()
                ?? throw CloudException.Server($"Google Drive didn’t confirm the new name of “{node.Name}”.");
        }, ct);

    /// <summary>Runs <paramref name="body"/> for each item, a few at a time; the first failure stops the rest and is thrown.</summary>
    static async Task EachAsync<T>(IReadOnlyList<T> items, int width, Func<T, CancellationToken, Task> body, CancellationToken ct)
    {
        if (items.Count == 0) return;
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        int next = -1;
        Exception? first = null;
        async Task Worker()
        {
            while (true)
            {
                var i = Interlocked.Increment(ref next);
                if (i >= items.Count || cts.IsCancellationRequested) return;
                try { await body(items[i], cts.Token).ConfigureAwait(false); }
                catch (Exception e)
                {
                    Interlocked.CompareExchange(ref first, e, null);
                    try { cts.Cancel(); } catch { }
                    return;
                }
            }
        }
        await Task.WhenAll(Enumerable.Range(0, Math.Min(width, items.Count)).Select(_ => Task.Run(Worker, CancellationToken.None))).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        if (first is not null) ExceptionDispatchInfo.Throw(first);
    }

    /// <summary>Moves items into <paramref name="folderID"/> (from wherever they are now: Google's own parents, not the listing's).</summary>
    public Task MoveAsync(IReadOnlyList<DriveNode> nodes, string folderID, CancellationToken ct = default) =>
        Mapped<bool>(async () =>
        {
            var dest = await DestinationAsync(folderID, ct).ConfigureAwait(false);
            await EachAsync(nodes, WriteConcurrency, async (n, c) =>
            {
                var id = Ref.Parse(n.Id).Real;
                if (id == dest) throw CloudException.Denied($"“{n.Name}” can’t be moved into itself.");
                var parents = (await MetadataAsync(id, "id,parents", c).ConfigureAwait(false))["parents"].Array.Select(p => p.Str).OfType<string>().ToList();
                if (parents.Count == 1 && parents[0] == dest) return;
                var q = new Dictionary<string, string> { ["addParents"] = dest, ["fields"] = "id,parents" };
                if (parents.Count > 0) q["removeParents"] = string.Join(',', parents);
                await Api.JsonAsync("PATCH", FileURL(id), q, new JsonObject(), idempotent: true, ct: c).ConfigureAwait(false);
            }, ct).ConfigureAwait(false);
            return true;
        }, ct);

    Task SetTrashedAsync(IReadOnlyList<DriveNode> nodes, bool trashed, CancellationToken ct) =>
        EachAsync(nodes, WriteConcurrency, (n, c) => Api.JsonAsync("PATCH", FileURL(Ref.Parse(n.Id).Real), new Dictionary<string, string> { ["fields"] = "id,trashed" },
            new JsonObject { ["trashed"] = trashed }, idempotent: true, ct: c), ct);

    /// <summary>Moves items to Google Drive's trash (kept there 30 days). Never deletes.</summary>
    public Task TrashAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default) =>
        Mapped<bool>(async () => { await SetTrashedAsync(nodes, true, ct).ConfigureAwait(false); return true; }, ct);

    /// <summary>
    /// What's in Google Drive's trash: the items trashed themselves, not everything inside a trashed folder. Each has
    /// <c>ParentID == CloudConventions.TrashParent</c>.
    /// </summary>
    public Task<List<DriveNode>> ListTrashAsync(CancellationToken ct = default) =>
        Mapped(() => QueryAsync("trashed = true", ",explicitlyTrashed", [], f => f["explicitlyTrashed"].Bool ?? true, _ => CloudConventions.TrashParent, ct), ct);

    public Task RestoreAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default) =>
        Mapped<bool>(async () => { await SetTrashedAsync(nodes, false, ct).ConfigureAwait(false); return true; }, ct);

    /// <summary>Deletes for good (folders with everything inside). Only for items in the trash, which the user chose to delete permanently.</summary>
    public Task DeleteForeverAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default)
    {
        DriveBackendExtensions.GuardTrashOnly(nodes);
        return Mapped<bool>(async () =>
        {
            await EachAsync(nodes, WriteConcurrency, async (n, c) =>
            {
                try { await Api.SendAsync(GoogleApi.Request("DELETE", FileURL(Ref.Parse(n.Id).Real)), idempotent: true, ct: c).ConfigureAwait(false); }
                catch (GoogleException e) when (e.Kind == GoogleErrorKind.Http && e.Status == 404)
                {
                    // Already gone (a retried request that went through the first time).
                }
            }, ct).ConfigureAwait(false);
            return true;
        }, ct);
    }

    // MARK: Extras

    /// <summary>Space used and the plan's limit. With no limit (some Workspace plans) the total is 0: used is known, free isn't.</summary>
    public Task<StorageUsage?> QuotaAsync(CancellationToken ct = default) =>
        Mapped<StorageUsage?>(async () =>
        {
            var (_, q) = await Drive.AboutAsync(ct).ConfigureAwait(false);
            return q.UsageBar(0) ?? new StorageUsage(0, q.Usage,
            [
                new StorageUsage.Category("drive", "Google Drive", q.UsageInDrive, "4285F4"),
                new StorageUsage.Category("other", "Gmail & Google Photos", Math.Max(0, q.Usage - q.UsageInDrive), "FBBC04"),
            ]);
        }, ct);

    /// <summary>
    /// Google's own thumbnail, sized to <paramref name="maxPixel"/> (<c>=s&lt;px&gt;</c>), or null when it has none. The
    /// sign-in goes only to Google's hosts over https; a thumbnail link anywhere else is ignored.
    /// </summary>
    public async Task<byte[]?> ThumbnailAsync(DriveNode node, int maxPixel, CancellationToken ct = default)
    {
        if (node.IsFolder) return null;
        return await Mapped<byte[]?>(async () =>
        {
            var id = node.DocID ?? Ref.Parse(node.Id).Real;
            string? link;
            lock (_lock) link = _thumbnails.GetValueOrDefault(id);
            link ??= await ThumbnailLinkAsync(id, ct).ConfigureAwait(false);
            if (link is null || SizedThumbnail(link, maxPixel) is not { } url || !Allowed(url)) return null;
            try { return await ThumbnailBytesAsync(url, ct).ConfigureAwait(false); }
            catch (GoogleException e) when (e.Kind == GoogleErrorKind.Http && e.Status is 403 or 404)
            {
                // Thumbnail links last a few hours: get a fresh one and try once more.
                if (await ThumbnailLinkAsync(id, ct).ConfigureAwait(false) is not { } fresh || SizedThumbnail(fresh, maxPixel) is not { } u
                    || u == url || !Allowed(u)) return null;
                return await ThumbnailBytesAsync(u, ct).ConfigureAwait(false);
            }
        }, ct).ConfigureAwait(false);
    }

    static bool Allowed(Uri u) => u.Scheme == Uri.UriSchemeHttps && GoogleHttp.IsGoogleHost(u.Host);

    /// <summary>Remembers a thumbnail link as if a listing had sent it (tests).</summary>
    internal void RememberThumbnailLink(string id, string link) { lock (_lock) _thumbnails[id] = link; }

    async Task<string?> ThumbnailLinkAsync(string id, CancellationToken ct)
    {
        var j = await MetadataAsync(id, "id,hasThumbnail,thumbnailLink", ct).ConfigureAwait(false);
        var link = j["hasThumbnail"].Bool == true ? j["thumbnailLink"].Str ?? "" : "";
        lock (_lock) _thumbnails[id] = link;
        return link.Length == 0 ? null : link;
    }

    async Task<byte[]?> ThumbnailBytesAsync(Uri url, CancellationToken ct)
    {
        var req = new GoogleRequest { Method = "GET", Url = url.AbsoluteUri, Headers = new(StringComparer.OrdinalIgnoreCase) { ["Accept"] = "image/*" } };
        var r = await Api.SendAsync(req, idempotent: true, ct: ct).ConfigureAwait(false);
        var type = (r.Header("Content-Type") ?? "").ToLowerInvariant();
        if (r.Data.Length == 0 || !(type.Length == 0 || type.StartsWith("image/", StringComparison.Ordinal))) return null;
        return r.Data;
    }

    static readonly Regex SizeSuffix = new(@"=s\d+(-[A-Za-z0-9-]*)?$", RegexOptions.Compiled);

    /// <summary>thumbnailLink with the size asked for: lh3 links end in "=s220", older ones carry "sz=s220".</summary>
    internal static Uri? SizedThumbnail(string link, int maxPixel)
    {
        if (string.IsNullOrEmpty(link) || !Uri.TryCreate(link, UriKind.Absolute, out _)) return null;
        var px = Math.Clamp(maxPixel, 16, 2048);
        var hash = link.IndexOf('#');
        var fragment = hash >= 0 ? link[hash..] : "";
        var s = hash >= 0 ? link[..hash] : link;
        var qi = s.IndexOf('?');
        var path = qi >= 0 ? s[..qi] : s;
        var query = qi >= 0 ? s[(qi + 1)..] : null;
        if (query is not null)
        {
            var parts = query.Split('&');
            var i = Array.FindIndex(parts, p => p == "sz" || p.StartsWith("sz=", StringComparison.Ordinal));
            if (i >= 0)
            {
                parts[i] = "sz=s" + px;
                return Uri.TryCreate(path + "?" + string.Join('&', parts) + fragment, UriKind.Absolute, out var q) ? q : null;
            }
        }
        path = SizeSuffix.Replace(path, "=s" + px, 1);
        return Uri.TryCreate(path + (query is null ? "" : "?" + query) + fragment, UriKind.Absolute, out var u) ? u : null;
    }

    /// <summary>Runs <paramref name="body"/>, turning Google's errors into <see cref="CloudException"/>s.</summary>
    static async Task<T> Mapped<T>(Func<Task<T>> body, CancellationToken ct)
    {
        try { return await body().ConfigureAwait(false); }
        catch (Exception e) when (GoogleDriveCloud.CloudError(e, ct) is var mapped && !ReferenceEquals(mapped, e)) { throw mapped; }
    }
}
