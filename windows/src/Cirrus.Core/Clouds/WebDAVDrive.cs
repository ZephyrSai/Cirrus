using System.Globalization;
using System.Runtime.ExceptionServices;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace Cirrus.Core;

/// <summary>Where an item lives: the user's files, or (Nextcloud) its trash bin.</summary>
enum DAVSpace { Files, Trash }

/// <summary>
/// A Nextcloud account or a plain WebDAV folder (ownCloud, OpenCloud, Synology, QNAP, Apache…), browsed like iCloud Drive
/// (port of WebDAVDrive.swift).
/// <para>IDs are <c>"dav:" + path</c> relative to the account's DAV root, percent-decoded, folders ending in "/"
/// (<c>RootID == "dav:/"</c>). The path keeps the server's own spelling (so requests match byte for byte); <c>Name</c> is
/// NFC for display and comparison. Items in Nextcloud's trash bin are <c>"dav-trash:" + path</c> inside the bin.</para>
/// </summary>
public sealed class WebDAVDrive : ICloudDriveBackend
{
    /// <summary>Plain WebDAV servers have no trash, so Cirrus keeps deleted items in this top-level folder.</summary>
    public const string TrashFolderName = "Deleted by Cirrus";
    /// <summary>Inside that folder: where each item came from.</summary>
    public const string ManifestName = ".cirrus-deleted.json";
    internal const string TrashPath = "/" + TrashFolderName + "/";

    public CloudProvider Provider { get; }
    public CloudAccountRecord Record { get; }
    public string RootID => "dav:/";
    public bool CanListTrash => true;

    internal DAVClient Client { get; }
    /// <summary>Nextcloud: the server's base URL (no trailing slash).</summary>
    readonly string? _base;
    /// <summary>Plain WebDAV: the folder URL (ending in "/").</summary>
    readonly string? _plainRoot;
    readonly string _loginName;
    /// <summary>What a listing asks for (Nextcloud adds its file id, size, sharing and preview properties).</summary>
    readonly byte[] _listBody;

    readonly object _lock = new();
    Task<string>? _uidTask;
    bool? _trashbin;
    readonly Dictionary<string, bool> _previews = new(StringComparer.Ordinal);
    /// <summary>Serializes changes to the "Deleted by Cirrus" folder and its manifest.</summary>
    readonly SemaphoreSlim _manifestLock = new(1, 1);

    // Tuning (tests lower these).
    long _chunkSize = 10 << 20, _chunkThreshold = 10 << 20;
    /// <summary>Nextcloud chunked uploads: bytes per chunk (Nextcloud needs at least 5 MiB except for the last one).</summary>
    internal long ChunkSize { get { lock (_lock) return _chunkSize; } set { lock (_lock) _chunkSize = value; } }
    /// <summary>Nextcloud: files larger than this are uploaded in chunks.</summary>
    internal long ChunkThreshold { get { lock (_lock) return _chunkThreshold; } set { lock (_lock) _chunkThreshold = value; } }
    internal int ListConcurrency { get; set; } = 6;
    internal double RetryBase { get => Client.RetryBase; set => Client.RetryBase = value; }

    public WebDAVDrive(CloudAccountRecord record, string? password, HttpMessageHandler? transport = null)
    {
        if (record.Provider is not (CloudProvider.Nextcloud or CloudProvider.WebDAV))
            throw CloudException.Unsupported($"{record.Provider.DisplayName()} isn’t a WebDAV service.");
        Record = record;
        Provider = record.Provider;
        _loginName = record.Username ?? "";
        var s = record.Server?.Trim();
        if (string.IsNullOrEmpty(s))
            throw CloudException.NotConfigured($"This {record.Provider.DisplayName()} account has no server address. Remove it and add it again.");
        if (Provider == CloudProvider.Nextcloud)
        {
            if (_loginName.Length == 0) throw CloudException.NotConfigured("This Nextcloud account has no user name. Sign in again.");
            _base = NextcloudLoginFlow.BaseURL(s);
        }
        else _plainRoot = WebDAVCloud.FolderURL(s);
        _listBody = Provider == CloudProvider.Nextcloud
            ? PropfindBody(DavProps, ["fileid", "size", "share-types"], ["has-preview"])
            : PropfindBody(DavProps);
        var service = record.Title.Length == 0 ? Provider.DisplayName() : $"{Provider.DisplayName()} ({record.Title})";
        Client = new DAVClient(record.Username, password, service, transport);
    }

    static string NFC(string s) => DAVURL.NFC(s);

    // MARK: IDs and URLs

    internal static string ID(DAVSpace space, string path) => (space == DAVSpace.Trash ? "dav-trash:" : "dav:") + path;

    (DAVSpace Space, string Path) Locate(string id)
    {
        DAVSpace space;
        string path;
        if (id.StartsWith("dav-trash:", StringComparison.Ordinal)) { space = DAVSpace.Trash; path = id["dav-trash:".Length..]; }
        else if (id.StartsWith("dav:", StringComparison.Ordinal)) { space = DAVSpace.Files; path = id["dav:".Length..]; }
        else throw CloudException.NotFound();
        if (!path.StartsWith('/')) throw CloudException.NotFound();
        if (space == DAVSpace.Trash && Provider != CloudProvider.Nextcloud) throw CloudException.NotFound();
        return (space, path);
    }

    static string FolderPath(string p) => p.EndsWith('/') ? p : p + "/";

    string DavBase => _base + "/remote.php/dav/";

    async Task<string> RootAsync(DAVSpace space, CancellationToken ct)
    {
        if (Provider != CloudProvider.Nextcloud)
        {
            if (space != DAVSpace.Files || _plainRoot is null) throw CloudException.NotFound();
            return _plainRoot;
        }
        var uid = DAVURL.EncodeSegment(await UserIDAsync(ct).ConfigureAwait(false));
        return space == DAVSpace.Files ? _base + "/remote.php/dav/files/" + uid + "/" : _base + "/remote.php/dav/trashbin/" + uid + "/trash/";
    }

    async Task<string> UrlAsync(DAVSpace space, string path, CancellationToken ct) => DAVURL.Join(await RootAsync(space, ct).ConfigureAwait(false), path);

    /// <summary>
    /// Nextcloud's file paths use the user ID, which can differ from the login name (email logins, LDAP): ask the
    /// server once (current-user-principal).
    /// </summary>
    internal async Task<string> UserIDAsync(CancellationToken ct = default)
    {
        if (Provider != CloudProvider.Nextcloud) return _loginName;
        Task<string> task;
        lock (_lock) task = _uidTask ??= DiscoverUserIDAsync();
        try { return await task.WaitAsync(ct).ConfigureAwait(false); }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch
        {
            lock (_lock) if (ReferenceEquals(_uidTask, task)) _uidTask = null;
            throw;
        }
    }

    async Task<string> DiscoverUserIDAsync()
    {
        await Task.Yield();
        var u = DavBase;
        var body = Encoding.UTF8.GetBytes("""<?xml version="1.0" encoding="UTF-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:current-user-principal/></d:prop></d:propfind>""");
        var r = await Client.SendAsync("PROPFIND", u, PropfindHeaders("0"), new DAVBody.Bytes(body), DAVRetry.Safe).ConfigureAwait(false);
        if (r.Status == 207)
        {
            List<DAVResource>? res = null;
            try { res = DAVMultistatus.Parse(r.Data, u); } catch (CloudException) { }
            if (res?.FirstOrDefault(x => x.Dav("current-user-principal") is not null)?.Dav("current-user-principal") is { Length: > 0 } href)
            {
                var p = DAVMultistatus.Resolve(href, u);
                var uid = DAVURL.LastSegment(p);
                if (uid.Length > 0 && p.Contains("/principals/", StringComparison.Ordinal)) return uid;
            }
        }
        if (r.Status is 404 or 405 or 501)
            throw CloudException.NotConfigured($"{HostOf(_base) ?? "The server"} doesn’t look like a Nextcloud server (it has no remote.php/dav). Check the address.");
        if (r.Status >= 400 && r.Status != 403) throw Failure(r, "sign in");
        return _loginName;
    }

    static string? HostOf(string? url) => url is not null && Uri.TryCreate(url, UriKind.Absolute, out var u) ? u.Host : null;

    internal static Dictionary<string, string> PropfindHeaders(string depth) => new(StringComparer.OrdinalIgnoreCase)
    {
        ["Depth"] = depth, ["Content-Type"] = "application/xml; charset=utf-8", ["Accept"] = "application/xml, text/xml",
    };

    // MARK: PROPFIND

    internal static byte[] PropfindBody(IEnumerable<string> dav, IEnumerable<string>? oc = null, IEnumerable<string>? nc = null)
    {
        var s = new StringBuilder("""<?xml version="1.0" encoding="UTF-8"?>""").Append('\n');
        s.Append("""<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns"><d:prop>""");
        foreach (var p in dav) s.Append("<d:").Append(p).Append("/>");
        foreach (var p in oc ?? []) s.Append("<oc:").Append(p).Append("/>");
        foreach (var p in nc ?? []) s.Append("<nc:").Append(p).Append("/>");
        s.Append("</d:prop></d:propfind>");
        return Encoding.UTF8.GetBytes(s.ToString());
    }

    static readonly string[] DavProps = ["resourcetype", "getcontentlength", "getlastmodified", "getetag", "getcontenttype", "creationdate"];
    static readonly byte[] TrashBody = PropfindBody(DavProps, ["fileid", "size"], ["trashbin-filename", "trashbin-original-location", "trashbin-deletion-time"]);
    static readonly byte[] QuotaBody = PropfindBody(["resourcetype", "quota-used-bytes", "quota-available-bytes"]);

    async Task<List<DAVResource>> PropfindAsync(string url, string depth, byte[] body, string what, CancellationToken ct)
    {
        var r = await Client.SendAsync("PROPFIND", url, PropfindHeaders(depth), new DAVBody.Bytes(body), DAVRetry.Safe, ct: ct).ConfigureAwait(false);
        if (r.Status != 207) throw Failure(r, what);
        return DAVMultistatus.Parse(r.Data, url);
    }

    /// <summary>The account-relative path of a resolved href, or null when it isn't inside <paramref name="rootPath"/>.</summary>
    internal static string? Relative(string path, string rootPath)
    {
        var p = DAVURL.Clean(path);
        var root = DAVURL.FolderPathClean(rootPath);
        if (p.StartsWith(root, StringComparison.Ordinal)) return "/" + p[root.Length..];
        if (DAVURL.TrimmedSlash(p) == DAVURL.TrimmedSlash(root)) return "/";
        // Some servers change the case or Unicode form of the folder part.
        var pc = NFC(p);
        var rc = NFC(root);
        if (pc.StartsWith(rc, StringComparison.OrdinalIgnoreCase)) return "/" + pc[rc.Length..];
        if (string.Equals(pc, DAVURL.TrimmedSlash(rc), StringComparison.OrdinalIgnoreCase)) return "/";
        return null;
    }

    DriveNode Node(DAVResource r, DAVSpace space, string path, string? parentID)
    {
        var folder = r.IsCollection;
        var p = path;
        if (folder && !p.EndsWith('/')) p += "/";
        if (!folder && p.Length > 1 && p.EndsWith('/')) p = p[..^1];
        var raw = DAVURL.LastSegment(p);
        if (space == DAVSpace.Trash && p.Split('/', StringSplitOptions.RemoveEmptyEntries).Length == 1 && r.NC("trashbin-filename") is { Length: > 0 } tn) raw = tn;
        var n = new DriveNode
        {
            Id = ID(space, p), DocID = r.FileID, Zone = "dav", ParentID = parentID, Name = NFC(raw), Type = folder ? "FOLDER" : "FILE",
            Size = folder ? 0 : r.Size, Modified = r.Modified, Created = r.Created, Etag = r.Etag, IsShared = r.IsShared,
        };
        if (r.HasPreview is bool hp && !folder) NotePreview(n.Id, hp);
        return n;
    }

    void NotePreview(string id, bool has)
    {
        lock (_lock)
        {
            if (_previews.Count > 50_000) _previews.Clear();
            _previews[id] = has;
        }
    }

    /// <summary>
    /// Hidden from listings: the "Deleted by Cirrus" folder at the top (plain WebDAV, or Nextcloud without its trash
    /// app) and the manifest inside it.
    /// </summary>
    bool Hidden(DAVSpace space, string folder, string name)
    {
        if (space != DAVSpace.Files) return false;
        if (folder == "/" && name == TrashFolderName) return UsesFolderTrash;
        if (folder == TrashPath && name == ManifestName) return true;
        return false;
    }

    bool UsesFolderTrash { get { if (Provider != CloudProvider.Nextcloud) return true; lock (_lock) return _trashbin == false; } }

    // MARK: Listing

    public async Task<List<DriveNode>> ListAsync(string folderID, CancellationToken ct = default)
    {
        var (space, raw) = Locate(folderID);
        var path = FolderPath(raw);
        var rootURL = await RootAsync(space, ct).ConfigureAwait(false);
        var url = DAVURL.Join(rootURL, path);
        var res = await PropfindAsync(url, "1", space == DAVSpace.Trash ? TrashBody : _listBody, $"list “{Display(path, space)}”", ct).ConfigureAwait(false);
        var rootPath = DAVURL.DecodedPath(rootURL);
        var want = NFC(DAVURL.TrimmedSlash(path));
        var parentID = ID(space, path);
        // Nextcloud keeps a "Deleted by Cirrus" folder only when its trash app is off: find out before hiding one.
        bool unknown;
        lock (_lock) unknown = _trashbin is null;
        if (Provider == CloudProvider.Nextcloud && space == DAVSpace.Files && path == "/" && unknown
            && res.Any(x => DAVURL.LastSegment(x.Path) == TrashFolderName && x.IsCollection))
        {
            try { await TrashbinAvailableAsync(ct).ConfigureAwait(false); } catch (CloudException) { }
        }
        var output = new List<DriveNode>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var r in res)
        {
            if (r.Status is int s && s != 200)
            {
                if (s == 404) continue;          // vanished while listing
                throw CloudException.Server($"The server couldn’t read part of “{Display(path, space)}” ({s}). Nothing was changed; try again.");
            }
            // A listing we can't place would look like an empty or changed folder: stop instead.
            var rel = Relative(r.Path, rootPath) ?? throw CloudException.Server(
                $"The server listed “{Display(path, space)}” at an unexpected address, so Cirrus didn’t show it. "
                + "If the server is behind a proxy, check that the address in the account matches the server’s own.");
            var relTrim = DAVURL.TrimmedSlash(rel);
            if (NFC(relTrim) == want)
            {
                if (!r.IsCollection && space == DAVSpace.Files) throw CloudException.Unsupported($"“{Display(path, space)}” is a file, not a folder.");
                continue;
            }
            if (DAVURL.Parent(relTrim) is not { } par || NFC(DAVURL.TrimmedSlash(par)) != want) continue;
            var seg = DAVURL.LastSegment(relTrim);
            if (seg.Length == 0 || Hidden(space, path, seg)) continue;
            var child = path + seg + (r.IsCollection ? "/" : "");
            if (!seen.Add(NFC(child))) continue;
            output.Add(Node(r, space, child, parentID));
        }
        return output;
    }

    public async Task<Dictionary<string, List<DriveNode>>> ListManyAsync(IReadOnlyList<string> folderIDs, CancellationToken ct = default)
    {
        var unique = folderIDs.Distinct(StringComparer.Ordinal).ToList();
        if (unique.Count == 0) return [];
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        using var gate = new SemaphoreSlim(Math.Max(1, ListConcurrency));
        var tasks = unique.Select(async id =>
        {
            await gate.WaitAsync(cts.Token).ConfigureAwait(false);
            try { return (id, nodes: await ListAsync(id, cts.Token).ConfigureAwait(false)); }
            catch { cts.Cancel(); throw; }       // one failure: stop the rest
            finally { gate.Release(); }
        }).ToList();
        var done = await Task.WhenAll(tasks).ConfigureAwait(false);
        return done.ToDictionary(x => x.id, x => x.nodes, StringComparer.Ordinal);
    }

    string Display(string path, DAVSpace space = DAVSpace.Files)
    {
        if (path == "/") return space == DAVSpace.Trash ? Provider.DeletedTitle() : Record.Title.Length == 0 ? Provider.DisplayName() : Record.Title;
        return NFC(DAVURL.LastSegment(path));
    }

    /// <summary>One item's current properties, or null if it doesn't exist.</summary>
    async Task<DriveNode?> StatAsync(DAVSpace space, string path, string? parentID, CancellationToken ct)
    {
        var root = await RootAsync(space, ct).ConfigureAwait(false);
        var u = DAVURL.Join(root, path);
        var r = await Client.SendAsync("PROPFIND", u, PropfindHeaders("0"), new DAVBody.Bytes(space == DAVSpace.Trash ? TrashBody : _listBody),
            DAVRetry.Safe, ct: ct).ConfigureAwait(false);
        if (r.Status is 404 or 409) return null;
        if (r.Status != 207) throw Failure(r, $"read “{Display(path, space)}”");
        var first = DAVMultistatus.Parse(r.Data, u).FirstOrDefault(x => (x.Status ?? 200) == 200);
        if (first is null) return null;
        // Use the server's own spelling (e.g. decomposed Unicode) when it is the same name, so the ID matches the one a
        // listing gives (C# compares IDs ordinally; the Mac app's strings compare canonically).
        var spelled = path;
        if (Relative(first.Path, DAVURL.DecodedPath(root)) is { } rel && rel != "/"
            && NFC(DAVURL.TrimmedSlash(rel)) == NFC(DAVURL.TrimmedSlash(path)))
            spelled = rel;
        return Node(first, space, spelled, parentID);
    }

    /// <summary>Checks the sign-in and that the top folder is a folder (used when connecting).</summary>
    internal async Task ValidateAsync(CancellationToken ct = default)
    {
        var u = await RootAsync(DAVSpace.Files, ct).ConfigureAwait(false);
        var r = await Client.SendAsync("PROPFIND", u, PropfindHeaders("0"), new DAVBody.Bytes(_listBody), DAVRetry.Safe, ct: ct).ConfigureAwait(false);
        if (r.Status != 207)
        {
            if (r.Status == 404) throw CloudException.NotConfigured($"There’s no WebDAV folder at {HostOf(u) ?? "that address"}. Check the address.");
            throw Failure(r, "open the folder");
        }
        var first = DAVMultistatus.Parse(r.Data, u).FirstOrDefault(x => (x.Status ?? 200) == 200)
            ?? throw CloudException.Server("The server answered, but not with a folder Cirrus can open.");
        if (!first.IsCollection) throw CloudException.NotConfigured("That address is a file, not a folder.");
    }

    // MARK: Errors

    internal static CloudException Failure(DAVResponse r, string what)
    {
        var suffix = DAVErrorBody.Suffix(r.Data);
        return r.Status switch
        {
            403 => CloudException.Denied($"The server didn’t allow Cirrus to {what}{suffix}."),
            404 or 410 => CloudException.NotFound(),
            409 => CloudException.NotFound(),      // a folder on the way is gone
            413 => CloudException.Denied("The server doesn’t accept a file this large. Its administrator can raise the upload limit."),
            414 => CloudException.Denied("The name or folder path is too long for the server."),
            >= 300 and < 400 => CloudException.Server($"The server answered with a redirect ({r.Status}) instead of doing it. Check the server address in the account."),
            _ => CloudException.Server($"The server couldn’t {what} ({r.Status}{suffix})."),
        };
    }

    CloudException NameTaken(string name, string folder) =>
        CloudException.Denied($"There’s already an item named “{NFC(name)}” in “{Display(folder)}”. Choose a different name.");

    internal static void CheckName(string name)
    {
        if (name.Length == 0 || name is "." or "..") throw CloudException.Denied($"“{name}” can’t be used as a name.");
        if (name.Contains('/') || name.Contains('\0')) throw CloudException.Denied("Names on the server can’t contain “/”.");
        if (Encoding.UTF8.GetByteCount(name) > 250)
        {
            var si = new StringInfo(name);
            throw CloudException.Denied($"“{si.SubstringByTextElements(0, Math.Min(40, si.LengthInTextElements))}…” is too long a name for the server.");
        }
    }

    static DateTimeOffset Now => DateTimeOffset.FromUnixTimeSeconds(DateTimeOffset.UtcNow.ToUnixTimeSeconds());

    // MARK: Download

    public async Task DownloadAsync(DriveNode node, string destination, Action<long, long>? progress, CancellationToken ct = default)
    {
        if (node.IsFolder) throw CloudException.Unsupported($"“{node.Name}” is a folder; download the items in it instead.");
        var (space, path) = Locate(node.Id);
        var u = await UrlAsync(space, path, ct).ConfigureAwait(false);
        var r = await Client.DownloadAsync(u, destination, node.Size, progress, ct).ConfigureAwait(false);
        if (!r.Ok) throw Failure(r, $"download “{node.Name}”");
        long size;
        try { size = new FileInfo(destination).Length; } catch { size = node.Size; }
        progress?.Invoke(size, Math.Max(size, node.Size));
        if ((node.Modified ?? DAVDates.Http(r.Header("Last-Modified"))) is { } m)
            try { File.SetLastWriteTimeUtc(destination, m.UtcDateTime); } catch { }
    }

    // MARK: Upload

    public async Task<DriveNode> UploadAsync(string file, string name, string folderID, DateTimeOffset? modified, Action<long, long>? progress,
        CancellationToken ct = default)
    {
        CheckName(name);
        var (space, raw) = Locate(folderID);
        if (space != DAVSpace.Files) throw CloudException.Unsupported($"Items can’t be uploaded into {Provider.DeletedTitle()}.");
        var folder = FolderPath(raw);
        var path = folder + name;
        var parentID = ID(DAVSpace.Files, folder);
        var size = new FileInfo(file).Length;
        var dest = await UrlAsync(DAVSpace.Files, path, ct).ConfigureAwait(false);
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) { ["Content-Type"] = Mime.ForName(name) };
        if (modified is { } m) headers["X-OC-Mtime"] = m.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture);
        (string? Etag, string? FileID) fromHeaders;
        if (Provider == CloudProvider.Nextcloud && size > ChunkThreshold)
            fromHeaders = await ChunkedUploadAsync(file, size, dest, path, folder, name, headers, progress, ct).ConfigureAwait(false);
        else
        {
            // Never replace an existing item by accident: replacing is a separate, explicit step (upload, then trash the old one).
            headers["If-None-Match"] = "*";
            var r = await Client.SendAsync("PUT", dest, headers, new DAVBody.File(file), DAVRetry.Safe, TimeSpan.FromSeconds(300), progress, size, ct)
                .ConfigureAwait(false);
            switch (r.Status)
            {
                case 200 or 201 or 204: break;
                case 412:
                    // A retried PUT can find its own first attempt: that's not a clash if the sizes match.
                    if (r.Retried && await TryStatAsync(DAVSpace.Files, path, parentID, ct).ConfigureAwait(false) is { IsFolder: false } same && same.Size == size)
                        return same;
                    throw NameTaken(name, folder);
                case 405: throw NameTaken(name, folder);
                default: throw Failure(r, $"upload “{name}”");
            }
            fromHeaders = (r.Header("OC-ETag") ?? r.Header("ETag"), r.Header("OC-FileId"));
        }
        progress?.Invoke(size, size);
        if (await TryStatAsync(DAVSpace.Files, path, parentID, ct).ConfigureAwait(false) is { } n) return n;
        var etag = fromHeaders.Etag;
        if (etag is { Length: >= 2 } && etag[0] == '"' && etag[^1] == '"') etag = etag[1..^1];
        return new DriveNode
        {
            Id = ID(DAVSpace.Files, path), DocID = fromHeaders.FileID is { } f ? NumericFileID(f) : null, Zone = "dav", ParentID = parentID,
            Name = NFC(name), Type = "FILE", Size = size, Modified = modified ?? Now, Created = Now, Etag = etag,
        };
    }

    /// <summary>After the work is done: a failed (or cancelled) look-up must not turn a success into a failure.</summary>
    async Task<DriveNode?> TryStatAsync(DAVSpace space, string path, string? parentID, CancellationToken ct)
    {
        try { return await StatAsync(space, path, parentID, ct).ConfigureAwait(false); }
        catch (Exception e) when (e is CloudException or OperationCanceledException) { return null; }
    }

    /// <summary>OC-FileId is "00000042ocabcdef" (id + instance); oc:fileid and the preview endpoint use the number.</summary>
    internal static string? NumericFileID(string s)
    {
        var digits = new string(s.TakeWhile(char.IsAsciiDigit).ToArray());
        return long.TryParse(digits, NumberStyles.None, CultureInfo.InvariantCulture, out var n) ? n.ToString(CultureInfo.InvariantCulture) : null;
    }

    /// <summary>Nextcloud chunked upload v2: MKCOL uploads/&lt;user&gt;/&lt;id&gt;, PUT numbered chunks, MOVE .file into place.</summary>
    async Task<(string? Etag, string? FileID)> ChunkedUploadAsync(string file, long size, string dest, string path, string folder, string name,
        Dictionary<string, string> headers, Action<long, long>? progress, CancellationToken ct)
    {
        // MOVE .file must not replace an existing item either.
        if (await StatAsync(DAVSpace.Files, path, null, ct).ConfigureAwait(false) is not null) throw NameTaken(name, folder);
        var uid = DAVURL.EncodeSegment(await UserIDAsync(ct).ConfigureAwait(false));
        var dir = _base + "/remote.php/dav/uploads/" + uid + "/cirrus-" + Guid.NewGuid().ToString().ToLowerInvariant() + "/";
        var common = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["Destination"] = dest, ["OC-Total-Length"] = size.ToString(CultureInfo.InvariantCulture),
        };
        var mk = await Client.SendAsync("MKCOL", dir, common, null, DAVRetry.RateLimitOnly, ct: ct).ConfigureAwait(false);
        if (mk.Status is not (201 or 405)) throw Failure(mk, $"start uploading “{name}”");
        var finished = false;
        try
        {
            // At most 10,000 chunks.
            var chunk = Math.Min(Math.Max(ChunkSize, (size + 9_999) / 10_000), 5L << 30);
            long offset = 0;
            var index = 1;
            while (offset < size)
            {
                ct.ThrowIfCancellationRequested();
                var n = Math.Min(chunk, size - offset);
                if (new FileInfo(file).Length < offset + n) throw CloudException.Server($"“{name}” changed while it was being uploaded. Try again.");
                var done = offset;
                var part = DAVURL.Join(dir, "/" + index.ToString("D5", CultureInfo.InvariantCulture));
                var h = new Dictionary<string, string>(common, StringComparer.OrdinalIgnoreCase) { ["Content-Type"] = "application/octet-stream" };
                var r = await Client.SendAsync("PUT", part, h, new DAVBody.FileRange(file, offset, n), DAVRetry.Safe, TimeSpan.FromSeconds(300),
                    progress is null ? null : (sent, _) => progress(done + sent, size), n, ct).ConfigureAwait(false);
                if (!r.Ok) throw Failure(r, $"upload “{name}”");
                offset += n;
                index++;
                progress?.Invoke(offset, size);
            }
            var mh = new Dictionary<string, string>(common, StringComparer.OrdinalIgnoreCase) { ["Overwrite"] = "F" };
            if (headers.TryGetValue("X-OC-Mtime", out var mtime)) mh["X-OC-Mtime"] = mtime;
            var final = DAVURL.Join(dir, "/.file");
            DAVResponse fr;
            try
            {
                // Putting a big file together can take the server a while.
                fr = await Client.SendAsync("MOVE", final, mh, null, DAVRetry.RateLimitOnly, TimeSpan.FromMinutes(30), ct: ct).ConfigureAwait(false);
            }
            catch (CloudException)
            {
                // The answer got lost: if the file is there at its full size, the upload worked.
                if (await TryStatAsync(DAVSpace.Files, path, null, ct).ConfigureAwait(false) is { } there && there.Size == size)
                {
                    finished = true;
                    return (there.Etag, there.DocID);
                }
                throw;
            }
            switch (fr.Status)
            {
                case 200 or 201 or 204:
                    finished = true;
                    return (fr.Header("OC-ETag") ?? fr.Header("ETag"), fr.Header("OC-FileId"));
                case 412: throw NameTaken(name, folder);
                default: throw Failure(fr, $"finish uploading “{name}”");
            }
        }
        finally
        {
            if (!finished)
            {
                // Leave no half-finished upload on the server (best effort, outside the cancelled task).
                var c = Client;
                _ = Task.Run(async () =>
                {
                    try { await c.SendAsync("DELETE", dir, retry: DAVRetry.RateLimitOnly).ConfigureAwait(false); } catch { }
                });
            }
        }
    }

    // MARK: Folders, rename, move

    public async Task<DriveNode> CreateFolderAsync(string name, string folderID, CancellationToken ct = default)
    {
        CheckName(name);
        var (space, raw) = Locate(folderID);
        if (space != DAVSpace.Files) throw CloudException.Unsupported($"Folders can’t be made in {Provider.DeletedTitle()}.");
        var folder = FolderPath(raw);
        var path = folder + name + "/";
        var parentID = ID(DAVSpace.Files, folder);
        var r = await Client.SendAsync("MKCOL", await UrlAsync(DAVSpace.Files, path, ct).ConfigureAwait(false), retry: DAVRetry.RateLimitOnly, ct: ct)
            .ConfigureAwait(false);
        switch (r.Status)
        {
            case 201: break;
            case 405: throw NameTaken(name, folder);
            default: throw Failure(r, $"make the folder “{name}”");
        }
        if (await TryStatAsync(DAVSpace.Files, path, parentID, ct).ConfigureAwait(false) is { } n) return n;
        return new DriveNode
        {
            Id = ID(DAVSpace.Files, path), Zone = "dav", ParentID = parentID, Name = NFC(name), Type = "FOLDER", Size = 0, Modified = Now, Created = Now,
        };
    }

    /// <summary>MOVE without replacing anything at the destination. False when the name is taken there (412).</summary>
    async Task<bool> TryMoveAsync(string from, string to, CancellationToken ct)
    {
        var src = await UrlAsync(DAVSpace.Files, from, ct).ConfigureAwait(false);
        var dst = await UrlAsync(DAVSpace.Files, to, ct).ConfigureAwait(false);
        var r = await Client.SendAsync("MOVE", src, new Dictionary<string, string> { ["Destination"] = dst, ["Overwrite"] = "F" },
            retry: DAVRetry.RateLimitOnly, ct: ct).ConfigureAwait(false);
        return r.Status switch
        {
            200 or 201 or 204 => true,
            412 => false,
            _ => throw Failure(r, $"move “{Display(from)}”"),
        };
    }

    async Task MoveItemAsync(string from, string to, CancellationToken ct)
    {
        if (!await TryMoveAsync(from, to, ct).ConfigureAwait(false)) throw NameTaken(DAVURL.LastSegment(to), DAVURL.Parent(to) ?? "/");
    }

    public async Task<DriveNode> RenameAsync(DriveNode node, string name, CancellationToken ct = default)
    {
        CheckName(name);
        var (space, path) = Locate(node.Id);
        if (space != DAVSpace.Files || path == "/") throw CloudException.Unsupported("This item can’t be renamed.");
        var folder = DAVURL.Parent(path) ?? "/";
        var newPath = folder + name + (node.IsFolder || path.EndsWith('/') ? "/" : "");
        if (NFC(newPath) == NFC(path)) return node;
        var parentID = ID(DAVSpace.Files, folder);
        if (string.Equals(NFC(name), NFC(DAVURL.LastSegment(path)), StringComparison.OrdinalIgnoreCase))
        {
            // Only the case changes: case-insensitive servers see that as the same name, so go via a temporary one.
            var temp = folder + ".cirrus-rename-" + Guid.NewGuid().ToString("N")[..8] + "-" + name + (newPath.EndsWith('/') ? "/" : "");
            await MoveItemAsync(path, temp, ct).ConfigureAwait(false);
            try { await MoveItemAsync(temp, newPath, ct).ConfigureAwait(false); }
            catch
            {
                try { await MoveItemAsync(temp, path, CancellationToken.None).ConfigureAwait(false); } catch { }
                throw;
            }
        }
        else await MoveItemAsync(path, newPath, ct).ConfigureAwait(false);
        if (await TryStatAsync(DAVSpace.Files, newPath, parentID, ct).ConfigureAwait(false) is { } n) return n;
        var copy = node.Copy();
        copy.Id = ID(DAVSpace.Files, newPath);
        copy.Name = NFC(name);
        copy.ParentID = parentID;
        return copy;
    }

    public async Task MoveAsync(IReadOnlyList<DriveNode> nodes, string folderID, CancellationToken ct = default)
    {
        var (space, raw) = Locate(folderID);
        if (space != DAVSpace.Files) throw CloudException.Unsupported($"Use Delete to put items in {Provider.DeletedTitle()}.");
        var dest = FolderPath(raw);
        foreach (var n in nodes)
        {
            ct.ThrowIfCancellationRequested();
            var (s, path) = Locate(n.Id);
            if (s != DAVSpace.Files || path == "/") throw CloudException.Unsupported($"“{n.Name}” can’t be moved.");
            if (DAVURL.Parent(path) is { } p && NFC(p) == NFC(dest)) continue;
            if (path.EndsWith('/') && NFC(dest).StartsWith(NFC(path), StringComparison.Ordinal))
                throw CloudException.Denied($"“{n.Name}” can’t be moved into itself.");
            await MoveItemAsync(path, dest + DAVURL.LastSegment(path) + (path.EndsWith('/') ? "/" : ""), ct).ConfigureAwait(false);
        }
    }

    // MARK: Trash

    /// <summary>
    /// Whether Nextcloud's trash bin (the files_trashbin app) is there. Without it DELETE would erase for good, so Cirrus
    /// then uses the "Deleted by Cirrus" folder instead.
    /// </summary>
    async Task<bool> TrashbinAvailableAsync(CancellationToken ct)
    {
        if (Provider != CloudProvider.Nextcloud) return false;
        lock (_lock) if (_trashbin is bool known) return known;
        var u = await RootAsync(DAVSpace.Trash, ct).ConfigureAwait(false);
        var r = await Client.SendAsync("PROPFIND", u, PropfindHeaders("0"), new DAVBody.Bytes(PropfindBody(["resourcetype"])), DAVRetry.Safe, ct: ct)
            .ConfigureAwait(false);
        var v = r.Status switch
        {
            207 => true,
            404 or 405 or 501 => false,
            _ => throw Failure(r, $"open {Provider.DeletedTitle()}"),
        };
        lock (_lock) _trashbin = v;
        return v;
    }

    public async Task TrashAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default)
    {
        if (nodes.Count == 0) return;
        foreach (var n in nodes)
        {
            var (s, p) = Locate(n.Id);
            if (s != DAVSpace.Files || p == "/") throw CloudException.Unsupported($"“{n.Name}” is already in {Provider.DeletedTitle()}.");
        }
        if (!await TrashbinAvailableAsync(ct).ConfigureAwait(false))
        {
            await FolderTrashAsync(nodes, ct).ConfigureAwait(false);
            return;
        }
        var filesRoot = await RootAsync(DAVSpace.Files, ct).ConfigureAwait(false);
        foreach (var n in nodes)
        {
            ct.ThrowIfCancellationRequested();
            var path = Locate(n.Id).Path;
            // Nextcloud moves deleted items to its trash bin (checked just above: never an erase).
            var r = await Client.SendAsync("DELETE", DAVURL.Join(filesRoot, path), retry: DAVRetry.RateLimitOnly, ct: ct).ConfigureAwait(false);
            if (r.Ok || r.Status == 404) continue;   // 404: already gone
            throw Failure(r, $"move “{n.Name}” to {Provider.DeletedTitle()}");
        }
    }

    public async Task<List<DriveNode>> ListTrashAsync(CancellationToken ct = default)
    {
        var items = await TrashbinAvailableAsync(ct).ConfigureAwait(false)
            ? await ListAsync(ID(DAVSpace.Trash, "/"), ct).ConfigureAwait(false)
            : await FolderListTrashAsync(ct).ConfigureAwait(false);
        foreach (var n in items) n.ParentID = CloudConventions.TrashParent;
        return items;
    }

    public async Task RestoreAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default)
    {
        var (bin, folder) = SplitTrash(nodes);
        if (bin.Count > 0)
        {
            var uid = DAVURL.EncodeSegment(await UserIDAsync(ct).ConfigureAwait(false));
            var restoreRoot = _base + "/remote.php/dav/trashbin/" + uid + "/restore/";
            foreach (var (n, path) in bin)
            {
                ct.ThrowIfCancellationRequested();
                var dest = restoreRoot + DAVURL.EncodeSegment(DAVURL.LastSegment(path));
                var r = await Client.SendAsync("MOVE", await UrlAsync(DAVSpace.Trash, path, ct).ConfigureAwait(false),
                    new Dictionary<string, string> { ["Destination"] = dest }, retry: DAVRetry.RateLimitOnly, ct: ct).ConfigureAwait(false);
                if (!r.Ok) throw Failure(r, $"recover “{n.Name}”");
            }
        }
        if (folder.Count > 0) await FolderRestoreAsync(folder, ct).ConfigureAwait(false);
    }

    public async Task DeleteForeverAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default)
    {
        DriveBackendExtensions.GuardTrashOnly(nodes);
        var (bin, folder) = SplitTrash(nodes);
        foreach (var (n, path) in bin)
        {
            ct.ThrowIfCancellationRequested();
            var r = await Client.SendAsync("DELETE", await UrlAsync(DAVSpace.Trash, path, ct).ConfigureAwait(false), retry: DAVRetry.RateLimitOnly, ct: ct)
                .ConfigureAwait(false);
            if (r.Ok || r.Status == 404) continue;
            throw Failure(r, $"delete “{n.Name}”");
        }
        if (folder.Count > 0) await FolderDeleteForeverAsync(folder, ct).ConfigureAwait(false);
    }

    /// <summary>
    /// Items in Nextcloud's trash bin, and items in the "Deleted by Cirrus" folder. Anything else is refused: only deleted
    /// items can be recovered or erased.
    /// </summary>
    (List<(DriveNode Node, string Path)> Bin, List<(DriveNode Node, string Path)> Folder) SplitTrash(IReadOnlyList<DriveNode> nodes)
    {
        var bin = new List<(DriveNode, string)>();
        var folder = new List<(DriveNode, string)>();
        foreach (var n in nodes)
        {
            var (s, p) = Locate(n.Id);
            if (s == DAVSpace.Trash) { bin.Add((n, p)); continue; }
            if (!p.StartsWith(TrashPath, StringComparison.Ordinal) || p == TrashPath || DAVURL.LastSegment(p) == ManifestName)
                throw CloudException.Unsupported($"“{n.Name}” isn’t in {Provider.DeletedTitle()}. Delete it first.");
            folder.Add((n, p));
        }
        return (bin, folder);
    }

    // MARK: "Deleted by Cirrus" (servers without a trash)

    /// <summary>Where each deleted item came from; the same JSON the Mac app writes (dates in whole seconds).</summary>
    internal sealed class Manifest
    {
        internal sealed record Entry(string Name, string From, DateTimeOffset Deleted);
        public int Version { get; set; } = 1;
        /// <summary>Name inside the trash folder → entry.</summary>
        public SortedDictionary<string, Entry> Items { get; } = new(StringComparer.Ordinal);

        public string? KeyFor(string name)
        {
            if (Items.ContainsKey(name)) return name;
            var n = NFC(name);
            return Items.Keys.FirstOrDefault(k => NFC(k) == n);
        }

        public static Manifest Parse(byte[] data)
        {
            var j = J.Parse(data);
            var m = new Manifest();
            if (j["version"].Int is int v) m.Version = v;
            foreach (var (k, e) in j["items"].Object)
                if (e["name"].Str is { } name && e["from"].Str is { } from)
                    m.Items[k] = new Entry(name, from, e["deleted"].Date ?? DateTimeOffset.UnixEpoch);
            return m;
        }

        public byte[] Bytes()
        {
            using var ms = new MemoryStream();
            using (var w = new Utf8JsonWriter(ms, new JsonWriterOptions { Indented = true, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
            {
                w.WriteStartObject();
                w.WriteStartObject("items");
                foreach (var (k, e) in Items)
                {
                    w.WriteStartObject(k);
                    w.WriteString("deleted", DAVDates.IsoString(e.Deleted));
                    w.WriteString("from", e.From);
                    w.WriteString("name", e.Name);
                    w.WriteEndObject();
                }
                w.WriteEndObject();
                w.WriteNumber("version", Version);
                w.WriteEndObject();
            }
            return ms.ToArray();
        }
    }

    async Task<Manifest> ReadManifestAsync(CancellationToken ct)
    {
        var u = await UrlAsync(DAVSpace.Files, TrashPath + ManifestName, ct).ConfigureAwait(false);
        var r = await Client.SendAsync("GET", u, new Dictionary<string, string> { ["Accept"] = "application/json" }, retry: DAVRetry.Safe, ct: ct)
            .ConfigureAwait(false);
        if (r.Status == 404) return new Manifest();
        if (!r.Ok) throw Failure(r, "read the list of deleted items");
        return Manifest.Parse(r.Data);
    }

    /// <summary>Best effort, and not cancellable: items already moved keep their record.</summary>
    async Task WriteManifestAsync(Manifest m)
    {
        try
        {
            var u = await UrlAsync(DAVSpace.Files, TrashPath + ManifestName, CancellationToken.None).ConfigureAwait(false);
            var r = await Client.SendAsync("PUT", u, new Dictionary<string, string> { ["Content-Type"] = "application/json" }, new DAVBody.Bytes(m.Bytes()),
                DAVRetry.Safe).ConfigureAwait(false);
            if (!r.Ok) Log.Status($"dav trash manifest not saved ({r.Status})");
        }
        catch (Exception) { Log.Status("dav trash manifest not saved"); }
    }

    async Task EnsureTrashFolderAsync(CancellationToken ct)
    {
        var r = await Client.SendAsync("MKCOL", await UrlAsync(DAVSpace.Files, TrashPath, ct).ConfigureAwait(false), retry: DAVRetry.RateLimitOnly, ct: ct)
            .ConfigureAwait(false);
        if (r.Status is not (201 or 405)) throw Failure(r, $"make the “{TrashFolderName}” folder");
    }

    /// <summary>"Report.txt" → "Report 2.txt"; folders and names without an extension get " 2" at the end.</summary>
    internal static string Numbered(string name, int n, bool folder)
    {
        var dot = name.LastIndexOf('.');
        if (folder || dot <= 0 || dot == name.Length - 1) return $"{name} {n}";
        return $"{name[..dot]} {n}{name[dot..]}";
    }

    static string TakenKey(string name) => NFC(name).ToLowerInvariant();

    async Task FolderTrashAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct)
    {
        await _manifestLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await EnsureTrashFolderAsync(ct).ConfigureAwait(false);
            var manifest = await ReadManifestAsync(ct).ConfigureAwait(false);
            var current = await ListAsync(ID(DAVSpace.Files, TrashPath), ct).ConfigureAwait(false);
            var taken = new HashSet<string>(StringComparer.Ordinal);
            foreach (var n in current) taken.Add(TakenKey(DAVURL.LastSegment(Locate(n.Id).Path)));
            foreach (var k in manifest.Items.Keys) taken.Add(TakenKey(k));
            taken.Add(ManifestName.ToLowerInvariant());
            Exception? failure = null;
            foreach (var n in nodes)
            {
                try
                {
                    ct.ThrowIfCancellationRequested();
                    var path = Locate(n.Id).Path;
                    var folder = path.EndsWith('/');
                    var seg = DAVURL.LastSegment(path);
                    var candidate = seg;
                    var k = 2;
                    while (true)
                    {
                        while (taken.Contains(TakenKey(candidate))) candidate = Numbered(seg, k++, folder);
                        if (await TryMoveAsync(path, TrashPath + candidate + (folder ? "/" : ""), ct).ConfigureAwait(false)) break;
                        // Taken after all (someone else just deleted something): try the next name.
                        taken.Add(TakenKey(candidate));
                        if (k >= 500) throw NameTaken(candidate, TrashPath);
                    }
                    taken.Add(TakenKey(candidate));
                    manifest.Items[candidate] = new Manifest.Entry(seg, DAVURL.Parent(path) ?? "/", Now);
                }
                catch (CloudException e) when (e.Kind == CloudErrorKind.NotFound) { }   // already gone
                catch (Exception e) { failure = e; break; }
            }
            await WriteManifestAsync(manifest).ConfigureAwait(false);
            if (failure is not null) ExceptionDispatchInfo.Throw(failure);
        }
        finally { _manifestLock.Release(); }
    }

    async Task<List<DriveNode>> FolderListTrashAsync(CancellationToken ct)
    {
        List<DriveNode> nodes;
        try { nodes = await ListAsync(ID(DAVSpace.Files, TrashPath), ct).ConfigureAwait(false); }
        catch (CloudException e) when (e.Kind == CloudErrorKind.NotFound) { return []; }
        Manifest m;
        try { m = await ReadManifestAsync(ct).ConfigureAwait(false); } catch (CloudException) { m = new Manifest(); }
        foreach (var n in nodes)
            if (m.KeyFor(DAVURL.LastSegment(Locate(n.Id).Path)) is { } key) n.Name = NFC(m.Items[key].Name);
        return nodes;
    }

    async Task FolderRestoreAsync(List<(DriveNode Node, string Path)> items, CancellationToken ct)
    {
        await _manifestLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var manifest = await ReadManifestAsync(ct).ConfigureAwait(false);
            Exception? failure = null;
            foreach (var (_, path) in items)
            {
                try
                {
                    ct.ThrowIfCancellationRequested();
                    var seg = DAVURL.LastSegment(path);
                    var isFolder = path.EndsWith('/');
                    var key = manifest.KeyFor(seg);
                    var entry = key is null ? null : manifest.Items[key];
                    var dest = entry?.From ?? "/";
                    // The original folder is gone (or is itself deleted): put it back at the top.
                    if (dest != "/")
                    {
                        var there = dest.StartsWith(TrashPath, StringComparison.Ordinal) ? null : await StatAsync(DAVSpace.Files, dest, null, ct).ConfigureAwait(false);
                        if (there is null || !there.IsFolder) dest = "/";
                    }
                    var original = entry?.Name ?? seg;
                    var candidate = original;
                    var k = 2;
                    // Something new has the name meanwhile: keep both, like Explorer ("Report 2.txt").
                    while (!await TryMoveAsync(path, dest + candidate + (isFolder ? "/" : ""), ct).ConfigureAwait(false))
                    {
                        if (k >= 500) throw NameTaken(original, dest);
                        candidate = Numbered(original, k++, isFolder);
                    }
                    if (key is not null) manifest.Items.Remove(key);
                }
                catch (CloudException e) when (e.Kind == CloudErrorKind.NotFound)
                {
                    if (manifest.KeyFor(DAVURL.LastSegment(path)) is { } gone) manifest.Items.Remove(gone);
                    failure ??= e;
                }
                catch (Exception e) { failure = e; break; }
            }
            await WriteManifestAsync(manifest).ConfigureAwait(false);
            if (failure is not null) ExceptionDispatchInfo.Throw(failure);
        }
        finally { _manifestLock.Release(); }
    }

    async Task FolderDeleteForeverAsync(List<(DriveNode Node, string Path)> items, CancellationToken ct)
    {
        await _manifestLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var manifest = await ReadManifestAsync(ct).ConfigureAwait(false);
            Exception? failure = null;
            foreach (var (n, path) in items)
            {
                try
                {
                    ct.ThrowIfCancellationRequested();
                    var r = await Client.SendAsync("DELETE", await UrlAsync(DAVSpace.Files, path, ct).ConfigureAwait(false), retry: DAVRetry.RateLimitOnly, ct: ct)
                        .ConfigureAwait(false);
                    if (!r.Ok && r.Status != 404) throw Failure(r, $"delete “{n.Name}”");
                    if (manifest.KeyFor(DAVURL.LastSegment(path)) is { } key) manifest.Items.Remove(key);
                }
                catch (Exception e) { failure = e; break; }
            }
            await WriteManifestAsync(manifest).ConfigureAwait(false);
            if (failure is not null) ExceptionDispatchInfo.Throw(failure);
        }
        finally { _manifestLock.Release(); }
    }

    // MARK: Quota and thumbnails

    public async Task<StorageUsage?> QuotaAsync(CancellationToken ct = default)
    {
        var u = await RootAsync(DAVSpace.Files, ct).ConfigureAwait(false);
        var res = await PropfindAsync(u, "0", QuotaBody, "read the storage use", ct).ConfigureAwait(false);
        if (res.FirstOrDefault(x => (x.Status ?? 200) == 200) is not { } r) return null;
        if (Num(r.Dav("quota-used-bytes")) is not long used || Num(r.Dav("quota-available-bytes")) is not long avail || used < 0 || avail < 0) return null;
        return new StorageUsage(used + avail, used, []);

        static long? Num(string? s)
        {
            var t = s?.Trim();
            if (string.IsNullOrEmpty(t)) return null;
            if (long.TryParse(t, NumberStyles.Integer, CultureInfo.InvariantCulture, out var l)) return l;
            return double.TryParse(t, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? (long)d : null;
        }
    }

    public async Task<byte[]?> ThumbnailAsync(DriveNode node, int maxPixel, CancellationToken ct = default)
    {
        if (Provider != CloudProvider.Nextcloud || node.IsFolder || node.DocID is not { Length: > 0 } id || _base is null) return null;
        lock (_lock) if (_previews.TryGetValue(node.Id, out var has) && !has) return null;
        var px = Math.Max(16, Math.Min(maxPixel, 2048)).ToString(CultureInfo.InvariantCulture);
        var u = $"{_base}/index.php/core/preview?fileId={Uri.EscapeDataString(id)}&x={px}&y={px}&a=1&forceIcon=0";
        var r = await Client.SendAsync("GET", u, new Dictionary<string, string> { ["Accept"] = "image/*" }, retry: DAVRetry.Safe, ct: ct).ConfigureAwait(false);
        if (r.Status != 200 || r.Data.Length == 0) return null;
        if (r.Header("Content-Type") is { } type && !type.TrimStart().StartsWith("image/", StringComparison.OrdinalIgnoreCase)) return null;
        return r.Data;
    }
}
