using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Cirrus.Core;

namespace Cirrus.Fakes;

/// <summary>
/// A stateful stand-in for Microsoft's identity platform and Microsoft Graph's OneDrive endpoints, served as an
/// HttpMessageHandler (port of FakeGraphServer.swift). Unit tests use it as the server; Debug builds in demo mode use it so
/// OneDrive can be browsed without an account. It is strict where real clients go wrong: PKCE at the token endpoint, the
/// loopback redirect form, refresh-token rotation (the old one stops working), access-token expiry, small listing pages,
/// 302 downloads to a separate host that refuses Authorization headers, upload sessions that insist on 320 KiB fragments,
/// contiguous ranges and the declared size, conflictBehavior, OneDrive's naming rules, a recycle bin behind DELETE,
/// thumbnails, quota and /me. Never part of a Release build.
/// </summary>
public sealed class FakeGraphServer : HttpMessageHandler, IFakeCloud
{
    public const string GraphHost = "graph.microsoft.com";
    public const string LoginHost = "login.microsoftonline.com";
    /// <summary>Pre-authenticated download, thumbnail and upload-session URLs live here.</summary>
    public const string ContentHost = "content.onedrive.example";
    public static readonly IReadOnlySet<string> Hosts = new HashSet<string> { GraphHost, LoginHost, ContentHost };
    public const int FragmentUnit = 327_680;
    public const int SimpleUploadLimit = 4 * 1024 * 1024;
    /// <summary>The drive behind the shared folder that <see cref="State.AddSharedFolder"/> puts in the user's root.</summary>
    public const string SharedDriveID = "f0e1d2c3b4a59687";
    /// <summary>The client ID the fake accepts (a GUID, like a real Application (client) ID).</summary>
    public const string DemoClientID = "11111111-2222-4333-8444-555555555555";
    public static readonly DateTimeOffset SeedDate = DateTimeOffset.FromUnixTimeSeconds(1_788_000_000);

    public sealed class Item
    {
        public string Id { get; set; } = "";
        public string Drive { get; set; } = "";
        public string Name { get; set; } = "";
        public string? Parent { get; set; }
        public bool IsFolder { get; set; }
        public string? Package { get; set; }
        public string? Mime { get; set; }
        public DateTimeOffset Created { get; set; }
        public DateTimeOffset Modified { get; set; }
        public DateTimeOffset FsCreated { get; set; }
        public DateTimeOffset FsModified { get; set; }
        public int Version { get; set; } = 1;
        public bool Deleted { get; set; }
        /// <summary>A shortcut to an item in another drive ("Add to My files").</summary>
        public string? RemoteDrive { get; set; }
        public string? RemoteID { get; set; }
        public bool HasThumbnail { get; set; }
        public Item Clone() => (Item)MemberwiseClone();
    }

    internal sealed class UploadSession
    {
        public string Parent = "", Name = "", Behavior = "replace";
        public long? Total;
        public MemoryStream Data = new();
        public DateTimeOffset? FsModified;
        public DateTimeOffset Expires;
    }
    internal sealed record Code(string Challenge, string Redirect, string Scope);
    internal sealed record Link(string Item, bool Thumbnail);

    /// <summary>Everything the server knows. Tests read it between steps and change it through <see cref="Update"/>.</summary>
    public sealed class State
    {
        public string ClientID = DemoClientID;
        public string DisplayName = "Alex Example";
        public string? Mail = "alex@example.com";
        public string UserPrincipalName = "alex@example.com";
        public string UserID = "a1b2c3d4e5f60708";
        public readonly string DriveID = "a1b2c3d4e5f60708";
        /// <summary>False: a work account without a OneDrive (GET /me/drive → 404).</summary>
        public bool HasDrive = true;
        public long Total = 5_368_709_120;
        public double AccessTTL = 3600;
        /// <summary>Listing page size cap (small, so clients must follow @odata.nextLink).</summary>
        public int PageSize = 3;
        /// <summary>False: only the named thumbnail sizes (small, medium, large…) are offered.</summary>
        public bool CustomThumbnails = true;
        public double Latency;
        public Dictionary<string, Item> Items = [];
        public Dictionary<string, byte[]> Blobs = [];
        public string RootID { get; private set; }
        int _counter = 100;
        internal Dictionary<string, string> Roots = [];
        internal Dictionary<string, Code> Codes = [];
        internal Dictionary<string, string> RefreshTokens = [];
        internal Dictionary<string, DateTimeOffset> AccessTokens = [];
        internal Dictionary<string, UploadSession> Sessions = [];
        internal Dictionary<string, Link> Links = [];
        internal bool IsDemo;
        // Statistics for tests
        public List<string> Calls = [];
        public int Refreshes;
        /// <summary>Parameter names of each token request (never the values).</summary>
        public List<HashSet<string>> TokenRequestKeys = [];
        /// <summary>Requests to the pre-authenticated host and whether they carried an Authorization header.</summary>
        public List<(string Path, bool HadAuth)> ContentRequests = [];
        public int AuthLeaks, SimpleUploads, SessionsCreated, SessionsCancelled, SessionStatusQueries;
        public List<int> ChunkSizes = [];
        public J LastSessionItem = J.Null;
        public List<string> ThumbnailSizes = [];
        public List<J> Patches = [];
        internal int ChunkPuts;
        // Fault injection
        /// <summary>The Nth upload-session fragment (1-based, all sessions) arrives partly, then the connection drops.</summary>
        public int? DropChunk;
        /// <summary>The next N Graph API calls get 429 with Retry-After: 0.</summary>
        public int ThrottleNext;
        /// <summary>The next N Graph API calls get 401 even with a valid token.</summary>
        public int UnauthorizedNext;
        /// <summary>The next N pre-authenticated downloads lose their connection.</summary>
        public int DropDownloadsNext;
        /// <summary>The next N finished uploads (simple PUT or last fragment) are stored, but the answer is lost.</summary>
        public int LoseUploadAnswers;

        public State() { RootID = MakeRoot(DriveID); }

        // MARK: Seeding

        string NewID(string drive) => drive.ToUpperInvariant() + "!" + (++_counter).ToString(CultureInfo.InvariantCulture);

        string MakeRoot(string drive)
        {
            var id = NewID(drive);
            Items[id] = new Item { Id = id, Drive = drive, Name = "root", IsFolder = true, Created = SeedDate, Modified = SeedDate, FsCreated = SeedDate, FsModified = SeedDate };
            Roots[drive] = id;
            return id;
        }

        internal string Add(string name, string parent, bool folder, byte[]? data, DateTimeOffset at, DateTimeOffset? fsModified = null, string? package = null)
        {
            var drive = Items.TryGetValue(parent, out var p) ? p.Drive : DriveID;
            var id = NewID(drive);
            var mime = folder || package is not null ? null : Mime.ForName(name);
            Items[id] = new Item
            {
                Id = id, Drive = drive, Name = name, Parent = parent, IsFolder = folder, Package = package, Mime = mime, Created = at, Modified = at,
                FsCreated = fsModified ?? at, FsModified = fsModified ?? at, HasThumbnail = mime?.StartsWith("image/", StringComparison.Ordinal) ?? false,
            };
            if (data is not null) Blobs[id] = data;
            return id;
        }

        public string AddFolder(string name, string? parent = null) => Add(name, parent ?? RootID, true, null, SeedDate);

        public string AddFile(string name, byte[] data, string? parent = null, DateTimeOffset? modified = null) =>
            Add(name, parent ?? RootID, false, data, SeedDate, modified ?? SeedDate);

        /// <summary>A OneNote notebook: a package, not a folder or a downloadable file.</summary>
        public string AddPackage(string name, string? parent = null) => Add(name, parent ?? RootID, false, new byte[4096], SeedDate, package: "oneNote");

        /// <summary>A folder in someone else's drive, added to the user's root as a shortcut.</summary>
        public (string Shortcut, string Folder) AddSharedFolder(string name, IEnumerable<(string Name, byte[] Data)> files)
        {
            var sharedRoot = Roots.TryGetValue(SharedDriveID, out var r) ? r : MakeRoot(SharedDriveID);
            var folder = Add(name, sharedRoot, true, null, SeedDate);
            foreach (var (n, d) in files) Add(n, folder, false, d, SeedDate);
            var shortcut = NewID(DriveID);
            Items[shortcut] = new Item
            {
                Id = shortcut, Drive = DriveID, Name = name, Parent = RootID, Created = SeedDate, Modified = SeedDate, FsCreated = SeedDate, FsModified = SeedDate,
                RemoteDrive = SharedDriveID, RemoteID = folder,
            };
            return (shortcut, folder);
        }

        /// <summary>Generic sample content for demo mode.</summary>
        internal void SeedDemo()
        {
            var docs = AddFolder("Documents");
            AddFile("Meeting Notes.txt", Encoding.UTF8.GetBytes("Agenda\n- Welcome\n- Project updates\n- Next steps\n"), docs, DateTimeOffset.FromUnixTimeSeconds(1_789_200_000));
            AddFile("Budget.csv", Encoding.UTF8.GetBytes("Item,Q1,Q2,Q3\nTravel,1200,950,1100\nSoftware,400,400,450\nEvents,0,2500,800\n"), docs,
                DateTimeOffset.FromUnixTimeSeconds(1_789_500_000));
            var pics = AddFolder("Pictures");
            (string Name, double Hue)[] art = [("Sunrise", 0.08), ("Harbor", 0.55)];
            for (int i = 0; i < art.Length; i++)
                AddFile(art[i].Name + ".png", DemoArt.Png(800, 533, art[i].Hue, art[i].Name), pics, DateTimeOffset.FromUnixTimeSeconds(1_788_400_000 + i * 86_400L));
            AddFile("Read Me.txt", Encoding.UTF8.GetBytes("Sample files for trying Cirrus with OneDrive.\n"), modified: DateTimeOffset.FromUnixTimeSeconds(1_788_100_000));
        }

        public string IssueRefreshToken()
        {
            var rt = "M.C540_BAY.fake-refresh-" + Guid.NewGuid().ToString().ToUpperInvariant();
            RefreshTokens[rt] = ClientID;
            return rt;
        }

        // MARK: Queries

        public List<string> ValidRefreshTokens => RefreshTokens.Keys.ToList();
        public void ExpireAccessTokens() { foreach (var k in AccessTokens.Keys.ToList()) AccessTokens[k] = DateTimeOffset.MinValue; }
        public void RevokeRefreshTokens() => RefreshTokens.Clear();
        public int OpenUploadSessions => Sessions.Count;

        /// <summary>In the recycle bin itself or inside a folder that is.</summary>
        internal bool IsGone(Item it)
        {
            for (Item? c = it; c is not null; c = c.Parent is { } p && Items.TryGetValue(p, out var pi) ? pi : null)
                if (c.Deleted) return true;
            return false;
        }

        public Item? Live(string id) => Items.TryGetValue(id, out var it) && !IsGone(it) ? it : null;
        public List<Item> RecycleBin => Items.Values.Where(i => i.Deleted).ToList();
        public List<Item> Children(string id) => Items.Values.Where(i => i.Parent == id && !i.Deleted).ToList();

        /// <summary>OneDrive names are case-insensitive.</summary>
        public Item? Child(string name, string? parent = null)
        {
            var p = parent ?? RootID;
            return Items.Values.FirstOrDefault(i => i.Parent == p && !i.Deleted && string.Equals(i.Name, name, StringComparison.OrdinalIgnoreCase));
        }

        internal long SizeOf(Item it)
        {
            if (it.RemoteID is not null) return 0;
            if (!it.IsFolder) return Blobs.TryGetValue(it.Id, out var b) ? b.Length : 0;
            return Children(it.Id).Sum(SizeOf);
        }

        public long Used => Items.Values.Where(i => i.Drive == DriveID && !i.IsFolder).Sum(i => Blobs.TryGetValue(i.Id, out var b) ? (long)b.Length : 0);
        public long DeletedBytes => Items.Values.Where(i => i.Drive == DriveID && !i.IsFolder && IsGone(i)).Sum(i => Blobs.TryGetValue(i.Id, out var b) ? (long)b.Length : 0);

        internal bool IsInside(string id, string ancestor)
        {
            for (string? c = id; c is not null; c = Items.TryGetValue(c, out var it) ? it.Parent : null)
                if (c == ancestor) return true;
            return false;
        }

        internal string FreeName(string name, string parent)
        {
            var ext = Path.GetExtension(name);
            var stem = ext.Length > 1 ? name[..^ext.Length] : name;
            if (ext.Length <= 1) ext = "";
            for (int i = 1; ; i++)
            {
                var candidate = $"{stem} {i}{ext}";
                if (Child(candidate, parent) is null) return candidate;
            }
        }
    }

    readonly object _lock = new();
    State _state;

    public FakeGraphServer(State? s = null) { _state = s ?? new State(); }

    /// <summary>The live state (read it when no request is in flight; change it through <see cref="Update"/>).</summary>
    public State S { get { lock (_lock) return _state; } }
    public void Reset(State? s = null) { lock (_lock) _state = s ?? new State(); }
    public void Update(Action<State> f) { lock (_lock) f(_state); }
    public string ClientID { get { lock (_lock) return _state.ClientID; } }

    /// <summary>Demo mode: generic sample content, kept for the life of this server.</summary>
    public static FakeGraphServer Demo()
    {
        var s = new State { IsDemo = true, Latency = 0.01, PageSize = 100 };
        s.SeedDemo();
        return new FakeGraphServer(s);
    }

    public bool Handles(Uri uri) => Hosts.Contains(uri.Host.ToLowerInvariant());

    /// <summary>One OneDrive account on this server, with a fresh refresh token of its own (it rotates: save each new one).</summary>
    public IReadOnlyList<CloudConnection> DemoAccounts()
    {
        lock (_lock)
        {
            var rt = _state.IssueRefreshToken();
            var record = new CloudAccountRecord(CloudProvider.OneDrive, _state.Mail ?? _state.UserPrincipalName, id: "cloud:onedrive:demo")
            {
                Added = DateTimeOffset.FromUnixTimeSeconds(1_790_000_000),
            };
            return [new CloudConnection(record, new CloudSecret { RefreshToken = rt, ClientID = _state.ClientID })];
        }
    }

    // MARK: The browser step

    static readonly Regex LoopbackRedirect = new(@"^http://localhost:[0-9]{1,5}/?$", RegexOptions.CultureInvariant);

    /// <summary>
    /// Plays Microsoft's authorize page: checks the request as Entra does for a public client with the redirect URI
    /// <c>http://localhost</c> (any port), then returns where the browser would be sent — the loopback redirect with
    /// <c>code</c> and <c>state</c>, or with <c>error</c>. Null when Microsoft would show an error page instead.
    /// </summary>
    public Uri? Authorize(Uri url, bool deny = false)
    {
        lock (_lock)
        {
            if (url.Host != LoginHost || url.AbsolutePath != "/common/oauth2/v2.0/authorize") return null;
            var q = Query(url);
            if (q.GetValueOrDefault("client_id") != _state.ClientID) return null;                                  // AADSTS700016
            if (q.GetValueOrDefault("redirect_uri") is not { } redirect || !LoopbackRedirect.IsMatch(redirect)) return null;   // AADSTS50011
            var scopes = (q.GetValueOrDefault("scope") ?? "").Split(' ', StringSplitOptions.RemoveEmptyEntries).ToHashSet();
            var items = new List<(string, string)>();
            if (deny)
                items.AddRange([("error", "access_denied"), ("error_description", "AADSTS65004: User declined to consent to access the app.")]);
            else if (q.GetValueOrDefault("response_type") != "code" || q.GetValueOrDefault("code_challenge_method") != "S256"
                     || (q.GetValueOrDefault("code_challenge") ?? "").Length != 43)
                items.AddRange([("error", "invalid_request"), ("error_description", "AADSTS9002325: Proof Key for Code Exchange (S256) is required.")]);
            else if (!scopes.IsSupersetOf(["Files.ReadWrite.All", "User.Read", "offline_access"]))
                items.AddRange([("error", "invalid_scope"), ("error_description", "AADSTS70011: The provided request must include the needed scopes.")]);
            else
            {
                var code = "M.C540_BAY.fake-code-" + Guid.NewGuid().ToString().ToUpperInvariant();
                _state.Codes[code] = new Code(q.GetValueOrDefault("code_challenge") ?? "", redirect, q.GetValueOrDefault("scope") ?? "");
                items.Add(("code", code));
            }
            items.Add(("state", q.GetValueOrDefault("state") ?? ""));
            var back = redirect.EndsWith('/') ? redirect : redirect + "/";
            return new Uri(back + "?" + string.Join('&', items.Select(p => Uri.EscapeDataString(p.Item1) + "=" + Uri.EscapeDataString(p.Item2))));
        }
    }

    /// <summary>
    /// Plays the browser: "signs in" on Microsoft's page and follows the redirect to the app's loopback listener. Demo mode
    /// passes this as the sign-in's <c>open</c> callback.
    /// </summary>
    public async Task ApproveAsync(Uri authorizeURL, bool deny = false)
    {
        if (Authorize(authorizeURL, deny) is { } target) await VisitAsync(target).ConfigureAwait(false);
    }

    /// <summary>A GET to the app's loopback listener over a real socket (only loopback addresses: never the network).</summary>
    public static async Task VisitAsync(Uri url)
    {
        if (url.Scheme != Uri.UriSchemeHttp || url.Host is not ("localhost" or "127.0.0.1" or "[::1]")) return;
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        try { using var _ = await http.GetAsync(url).ConfigureAwait(false); } catch { }
    }

    // MARK: HttpMessageHandler

    sealed record Outcome(int Status, Dictionary<string, string> Headers, byte[] Data, bool Drop = false);
    static Outcome DropOutcome => new(0, [], [], true);

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        var body = request.Content is null ? [] : await request.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
        Outcome o;
        double latency;
        lock (_lock) { o = Handle(request, body); latency = _state.Latency; }
        if (latency > 0) await Task.Delay(TimeSpan.FromSeconds(latency), ct).ConfigureAwait(false);
        if (o.Drop) throw new HttpRequestException(HttpRequestError.ResponseEnded, "The network connection was lost.", new IOException("connection lost"));
        var resp = new HttpResponseMessage((HttpStatusCode)o.Status) { RequestMessage = request, Content = new ByteArrayContent(o.Data) };
        var headers = new Dictionary<string, string>(o.Headers, StringComparer.OrdinalIgnoreCase);
        if (!headers.ContainsKey("Content-Type")) headers["Content-Type"] = "application/json; odata.metadata=minimal; charset=utf-8";
        foreach (var (k, v) in headers)
            if (!resp.Headers.TryAddWithoutValidation(k, v)) resp.Content.Headers.TryAddWithoutValidation(k, v);
        return resp;
    }

    static string? H(HttpRequestMessage r, string name)
    {
        if (r.Headers.TryGetValues(name, out var v)) return string.Join(", ", v);
        if (r.Content?.Headers.TryGetValues(name, out var cv) == true) return string.Join(", ", cv);
        return null;
    }

    // MARK: Helpers

    static Outcome Json(int status, JsonNode j, Dictionary<string, string>? headers = null) =>
        new(status, headers ?? [], Encoding.UTF8.GetBytes(j.ToJsonString(Jx.Wire)));

    static Outcome Error(int status, string code, string message, Dictionary<string, string>? headers = null) =>
        Json(status, new JsonObject
        {
            ["error"] = new JsonObject
            {
                ["code"] = code, ["message"] = message,
                ["innerError"] = new JsonObject { ["date"] = Iso(DateTimeOffset.UtcNow), ["request-id"] = Guid.NewGuid().ToString() },
            },
        }, headers);

    static Outcome Redirect(string location) => new(302, new() { ["Location"] = location }, []);

    public static string Iso(DateTimeOffset d) => d.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);

    static Dictionary<string, string> Form(byte[] d)
    {
        var output = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var pair in Encoding.UTF8.GetString(d).Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var kv = pair.Split('=', 2).Select(s => Uri.UnescapeDataString(s.Replace('+', ' '))).ToArray();
            if (kv.Length == 2) output[kv[0]] = kv[1];
        }
        return output;
    }

    /// <summary>Strict like URLComponents: "+" stays a plus, so a client that forgets to encode it is caught.</summary>
    static Dictionary<string, string> Query(Uri u)
    {
        var q = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var pair in u.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var kv = pair.Split('=', 2);
            q[Uri.UnescapeDataString(kv[0])] = kv.Length > 1 ? Uri.UnescapeDataString(kv[1]) : "";
        }
        return q;
    }

    /// <summary>OneDrive's naming rules.</summary>
    static bool BadName(string n) => n.Length == 0 || n == "." || n == ".." || n.Any(c => "\"*:<>?/\\|".Contains(c) || char.IsControl(c));

    JsonObject ItemJSON(Item it, HashSet<string>? select = null)
    {
        var s = _state;
        var o = new JsonObject
        {
            ["id"] = it.Id, ["name"] = it.Name,
            ["eTag"] = $"\"{{{it.Id}}},{it.Version}\"", ["cTag"] = $"\"c:{{{it.Id}}},{it.Version}\"",
            ["createdDateTime"] = Iso(it.Created), ["lastModifiedDateTime"] = Iso(it.Modified),
            ["fileSystemInfo"] = new JsonObject { ["createdDateTime"] = Iso(it.FsCreated), ["lastModifiedDateTime"] = Iso(it.FsModified) },
            ["size"] = s.SizeOf(it),
        };
        var parent = new JsonObject { ["driveId"] = it.Drive, ["driveType"] = "personal" };
        if (it.Parent is { } p) parent["id"] = p; else o["root"] = new JsonObject();
        o["parentReference"] = parent;
        if (it.RemoteDrive is { } rd && it.RemoteID is { } rid && s.Items.TryGetValue(rid, out var target))
        {
            var r = new JsonObject
            {
                ["id"] = rid, ["name"] = target.Name, ["size"] = s.SizeOf(target),
                ["parentReference"] = new JsonObject { ["driveId"] = rd, ["driveType"] = "personal" },
            };
            if (target.IsFolder) r["folder"] = new JsonObject { ["childCount"] = s.Children(rid).Count };
            else r["file"] = new JsonObject { ["mimeType"] = target.Mime ?? "application/octet-stream" };
            o["remoteItem"] = r;
            o["shared"] = new JsonObject { ["scope"] = "users" };
        }
        else if (it.IsFolder) o["folder"] = new JsonObject { ["childCount"] = s.Children(it.Id).Count };
        else if (it.Package is { } pk) o["package"] = new JsonObject { ["type"] = pk };
        else
        {
            o["file"] = new JsonObject { ["mimeType"] = it.Mime ?? "application/octet-stream" };
            if (it.HasThumbnail) o["image"] = new JsonObject();
        }
        if (select is not null) foreach (var k in o.Select(kv => kv.Key).Where(k => !select.Contains(k)).ToList()) o.Remove(k);
        return o;
    }

    // MARK: Routing

    Outcome Handle(HttpRequestMessage r, byte[] body)
    {
        var url = r.RequestUri!;
        var host = url.Host.ToLowerInvariant();
        var method = r.Method.Method;
        var hadAuth = r.Headers.Authorization is not null;
        _state.Calls.Add($"{method} {host}{Uri.UnescapeDataString(url.AbsolutePath)}");
        if (url.Scheme != Uri.UriSchemeHttps) return Error(400, "invalidRequest", "https only");
        switch (host)
        {
            case LoginHost:
                return Token(method, url.AbsolutePath, body);
            case ContentHost:
                _state.ContentRequests.Add((url.AbsolutePath, hadAuth));
                // Real OneDrive answers 401 when a pre-authenticated URL also gets a bearer token.
                if (hadAuth) { _state.AuthLeaks++; return Error(401, "unauthenticated", "Pre-authenticated URLs must not get an Authorization header."); }
                return ContentHostRequest(method, url, r, body);
            default:
                return Graph(method, url, r, body);
        }
    }

    // MARK: Identity platform

    Outcome Token(string method, string path, byte[] body)
    {
        if (method != "POST" || path != "/common/oauth2/v2.0/token") return new Outcome(404, [], []);
        var f = Form(body);
        _state.TokenRequestKeys.Add(f.Keys.ToHashSet());
        static Outcome Bad(int status, string error, string desc)
        {
            var digits = new string(desc.Skip("AADSTS".Length).TakeWhile(char.IsAsciiDigit).ToArray());
            var code = int.TryParse(digits, NumberStyles.None, CultureInfo.InvariantCulture, out var c) ? c : 0;
            return Json(status, new JsonObject
            {
                ["error"] = error, ["error_codes"] = new JsonArray(code),
                ["error_description"] = desc + $"\r\nTrace ID: {Guid.NewGuid()}\r\nCorrelation ID: {Guid.NewGuid()}\r\nTimestamp: {Iso(DateTimeOffset.UtcNow)}",
            });
        }
        if (f.GetValueOrDefault("client_id") != _state.ClientID)
            return Bad(400, "unauthorized_client", $"AADSTS700016: Application with identifier '{f.GetValueOrDefault("client_id")}' was not found in the directory.");
        if (f.ContainsKey("client_secret") || f.ContainsKey("client_assertion"))
            return Bad(401, "invalid_client", "AADSTS700025: Client is public so neither 'client_assertion' nor 'client_secret' should be presented.");
        switch (f.GetValueOrDefault("grant_type"))
        {
            case "authorization_code":
            {
                if (f.GetValueOrDefault("code") is not { } code || !_state.Codes.Remove(code, out var c))
                    return Bad(400, "invalid_grant", "AADSTS70000: The provided authorization code is invalid or has expired.");
                if (f.GetValueOrDefault("redirect_uri") != c.Redirect)
                    return Bad(400, "invalid_grant", "AADSTS70000: The redirect URI doesn't match the one the code was issued for.");
                if (f.GetValueOrDefault("code_verifier") is not { Length: >= 43 and <= 128 } v || new Pkce(v).Challenge != c.Challenge)
                    return Bad(400, "invalid_grant", "AADSTS501481: The Code_Verifier does not match the code_challenge supplied in the authorization request.");
                return Issue(c.Scope);
            }
            case "refresh_token":
                // Rotation, strictly: a refresh token works once.
                if (f.GetValueOrDefault("refresh_token") is not { } t || !_state.RefreshTokens.Remove(t))
                    return Bad(400, "invalid_grant", "AADSTS70000: The provided value for the input parameter 'refresh_token' or 'assertion' is not valid.");
                _state.Refreshes++;
                return Issue(f.GetValueOrDefault("scope") ?? "");
            default:
                return Bad(400, "unsupported_grant_type", "AADSTS70003: The app requested an unsupported grant type.");
        }
    }

    Outcome Issue(string scope)
    {
        var access = "EwB4A8l6BAAU.fake-access-" + Guid.NewGuid().ToString().ToUpperInvariant();
        _state.AccessTokens[access] = DateTimeOffset.UtcNow.AddSeconds(_state.AccessTTL);
        var o = new JsonObject
        {
            ["token_type"] = "Bearer", ["scope"] = "Files.ReadWrite.All User.Read", ["access_token"] = access,
            ["expires_in"] = _state.AccessTTL, ["ext_expires_in"] = _state.AccessTTL,
        };
        if (scope.Split(' ').Contains("offline_access")) o["refresh_token"] = _state.IssueRefreshToken();
        return Json(200, o);
    }

    // MARK: Graph

    Outcome Graph(string method, Uri url, HttpRequestMessage r, byte[] body)
    {
        if (r.Headers.Authorization is not { Scheme: "Bearer", Parameter: { } token } || !_state.AccessTokens.TryGetValue(token, out var exp)
            || exp <= DateTimeOffset.UtcNow)
            return Error(401, "InvalidAuthenticationToken", "Access token has expired or is not yet valid.", new() { ["WWW-Authenticate"] = "Bearer error=\"invalid_token\"" });
        if (_state.UnauthorizedNext > 0)
        {
            _state.UnauthorizedNext--;
            return Error(401, "InvalidAuthenticationToken", "Access token validation failure.", new() { ["WWW-Authenticate"] = "Bearer error=\"invalid_token\"" });
        }
        if (_state.ThrottleNext > 0)
        {
            _state.ThrottleNext--;
            return Error(429, "activityLimitReached", "The request has been throttled", new() { ["Retry-After"] = "0" });
        }
        var raw = url.AbsolutePath;
        if (!raw.StartsWith("/v1.0/", StringComparison.Ordinal)) return Error(404, "itemNotFound", "Unknown API version.");
        var p = raw["/v1.0".Length..];
        var q = Query(url);
        var select = q.TryGetValue("$select", out var sel) ? sel.Split(',').Select(x => x.Trim()).ToHashSet() : null;
        var s = _state;
        if (p == "/me")
        {
            if (method != "GET") return Error(405, "invalidRequest", "Method not allowed.");
            var o = new JsonObject { ["id"] = s.UserID, ["displayName"] = s.DisplayName, ["userPrincipalName"] = s.UserPrincipalName, ["mail"] = s.Mail };
            if (select is not null) foreach (var k in o.Select(kv => kv.Key).Where(k => !select.Contains(k)).ToList()) o.Remove(k);
            return Json(200, o);
        }
        if (!s.HasDrive) return Error(404, "itemNotFound", "User's mysite not found.");
        if (p == "/me/drive")
        {
            var o = new JsonObject
            {
                ["id"] = s.DriveID, ["driveType"] = "personal", ["owner"] = new JsonObject { ["user"] = new JsonObject { ["displayName"] = s.DisplayName } },
                ["quota"] = new JsonObject
                {
                    ["total"] = s.Total, ["used"] = s.Used, ["remaining"] = Math.Max(0, s.Total - s.Used), ["deleted"] = s.DeletedBytes, ["state"] = "normal",
                },
            };
            if (select is not null) foreach (var k in o.Select(kv => kv.Key).Where(k => !select.Contains(k)).ToList()) o.Remove(k);
            return Json(200, o);
        }
        var drive = s.DriveID;
        if (p.StartsWith("/me/drive/", StringComparison.Ordinal)) p = p["/me/drive".Length..];
        else if (p.StartsWith("/drives/", StringComparison.Ordinal))
        {
            var rest = p["/drives/".Length..];
            var slash = rest.IndexOf('/');
            if (slash < 0) return Error(400, "invalidRequest", "Bad drive path.");
            drive = Uri.UnescapeDataString(rest[..slash]);
            p = rest[slash..];
        }
        else return Error(400, "BadRequest", "Unsupported segment.");
        string itemID;
        if (p.StartsWith("/root", StringComparison.Ordinal))
        {
            if (!s.Roots.TryGetValue(drive, out var root)) return Error(404, "itemNotFound", "Drive not found.");
            itemID = root;
            p = p["/root".Length..];
        }
        else if (p.StartsWith("/items/", StringComparison.Ordinal))
        {
            var rest = p["/items/".Length..];
            var end = rest.IndexOfAny(['/', ':']);
            if (end < 0) end = rest.Length;
            itemID = Uri.UnescapeDataString(rest[..end]);
            p = rest[end..];
        }
        else return Error(400, "BadRequest", "Unsupported segment.");
        // Path addressing: "{item}:/{name}" then nothing, ":", ":/content" or ":/createUploadSession".
        string? name = null;
        if (p.StartsWith(":/", StringComparison.Ordinal))
        {
            var rest = p[2..];
            var end = rest.IndexOf(':');
            if (end < 0) end = rest.Length;
            var encoded = rest[..end];
            var decoded = Uri.UnescapeDataString(encoded);
            if (encoded.Contains('/') || decoded.Length == 0) return Error(400, "invalidRequest", "Only one name segment is supported here.");
            name = decoded;
            p = rest[end..];
            if (p == ":") p = "";
            else if (p.StartsWith(":/", StringComparison.Ordinal)) p = p[1..];
            else if (p.Length > 0) return Error(400, "invalidRequest", "Bad path.");
        }
        if (s.Live(itemID) is not { } item || item.Drive != drive) return Error(404, "itemNotFound", "The resource could not be found.");
        if (name is not null)
        {
            if (!item.IsFolder || item.RemoteID is not null) return Error(400, "invalidRequest", "The parent isn't a folder.");
            return (method, p) switch
            {
                ("GET", "") => s.Child(name, item.Id) is { } c ? Json(200, ItemJSON(c, select)) : Error(404, "itemNotFound", "The resource could not be found."),
                ("PUT", "/content") => SimpleUpload(item, name, q, body),
                ("POST", "/createUploadSession") => CreateSession(item, name, body),
                _ => Error(400, "invalidRequest", "Unsupported request."),
            };
        }
        return (method, p) switch
        {
            ("GET", "") => Json(200, ItemJSON(item, select)),
            ("GET", "/children") => ListChildren(item, url, q, select),
            ("POST", "/children") => CreateFolder(item, body),
            ("PATCH", "") => Patch(item, q, body),
            ("DELETE", "") => Remove(item),
            ("GET", "/content") => DownloadRedirect(item),
            ("GET", _) when p.StartsWith("/thumbnails/", StringComparison.Ordinal) => Thumbnail(item, p),
            _ => Error(400, "invalidRequest", $"Unsupported request: {method} {p}"),
        };
    }

    Outcome ListChildren(Item item, Uri url, Dictionary<string, string> q, HashSet<string>? select)
    {
        if (item.RemoteID is not null) return Error(400, "invalidRequest", "A shortcut's contents are listed in the drive it points to.");
        var all = _state.Children(item.Id).OrderBy(i => i.Name.ToLowerInvariant(), StringComparer.Ordinal).ThenBy(i => i.Id, StringComparer.Ordinal).ToList();
        var top = int.TryParse(q.GetValueOrDefault("$top"), NumberStyles.None, CultureInfo.InvariantCulture, out var t) ? t : 200;
        if (top is < 1 or > 999) return Error(400, "invalidRequest", "$top must be between 1 and 999.");
        var size = Math.Min(top, _state.PageSize);
        var skip = int.TryParse(q.GetValueOrDefault("$skiptoken"), NumberStyles.None, CultureInfo.InvariantCulture, out var sk) ? sk : 0;
        var page = all.Skip(skip).Take(size).ToList();
        var output = new JsonObject { ["value"] = new JsonArray(page.Select(i => (JsonNode)ItemJSON(i, select)).ToArray()) };
        if (skip + page.Count < all.Count)
        {
            var keep = url.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries)
                .Where(pair => Uri.UnescapeDataString(pair.Split('=', 2)[0]) != "$skiptoken");
            output["@odata.nextLink"] = url.GetLeftPart(UriPartial.Path) + "?" + string.Join('&', keep.Append("$skiptoken=" + (skip + page.Count)));
        }
        return Json(200, output);
    }

    Outcome CreateFolder(Item parent, byte[] body)
    {
        var j = J.Parse(body);
        if (!parent.IsFolder || parent.RemoteID is not null) return Error(400, "invalidRequest", "The parent isn't a folder.");
        if (j["name"].Str is not { } name || j["folder"].Node is not JsonObject) return Error(400, "invalidRequest", "name and folder are required.");
        if (BadName(name)) return Error(400, "invalidRequest", "The name contains invalid characters.");
        var finalName = name;
        if (_state.Child(name, parent.Id) is { } existing)
        {
            switch (j["@microsoft.graph.conflictBehavior"].Str ?? "fail")
            {
                case "rename": finalName = _state.FreeName(name, parent.Id); break;
                case "replace": existing.Deleted = true; break;
                default: return Error(409, "nameAlreadyExists", "An item with the same name already exists under the parent.");
            }
        }
        var id = _state.Add(finalName, parent.Id, true, null, DateTimeOffset.UtcNow);
        return Json(201, ItemJSON(_state.Items[id]));
    }

    Outcome Patch(Item item, Dictionary<string, string> q, byte[] body)
    {
        if (item.Parent is null) return Error(403, "accessDenied", "The root folder can't be changed.");
        var j = J.Parse(body);
        if (j.Node is not JsonObject o || o.Count == 0) return Error(400, "invalidRequest", "Empty update.");
        _state.Patches.Add(j);
        var it = item.Clone();
        if (j["parentReference"].Node is JsonObject)
        {
            var pr = j["parentReference"];
            if (pr["id"].Str is not { } pid) return Error(400, "invalidRequest", "parentReference.id is required.");
            if (pr["driveId"].Str is { } d && d != it.Drive) return Error(400, "invalidRequest", "Moving items between drives isn't supported.");
            if (_state.Live(pid) is not { } target || target.Drive != it.Drive || !target.IsFolder || target.RemoteID is not null)
                return Error(400, "invalidRequest", "parentReference.id must be the id of a folder in this drive.");
            if (_state.IsInside(target.Id, it.Id)) return Error(400, "invalidRequest", "A folder can't be moved into itself.");
            it.Parent = pid;
        }
        if (j["name"].Str is { } n)
        {
            if (BadName(n)) return Error(400, "invalidRequest", "The name contains invalid characters.");
            it.Name = n;
        }
        if ((it.Parent != item.Parent || it.Name != item.Name) && _state.Child(it.Name, it.Parent) is { } clash && clash.Id != it.Id)
        {
            if (q.GetValueOrDefault("@microsoft.graph.conflictBehavior") != "replace")
                return Error(409, "nameAlreadyExists", "An item with the same name already exists under the parent.");
            clash.Deleted = true;
        }
        if (j["fileSystemInfo"]["lastModifiedDateTime"].Date is { } fm) it.FsModified = fm;
        if (j["fileSystemInfo"]["createdDateTime"].Date is { } fc) it.FsCreated = fc;
        it.Version++;
        it.Modified = DateTimeOffset.UtcNow;
        _state.Items[it.Id] = it;
        return Json(200, ItemJSON(it));
    }

    /// <summary>DELETE moves the item to the recycle bin (a shortcut: only the shortcut).</summary>
    Outcome Remove(Item item)
    {
        if (item.Parent is null) return Error(403, "accessDenied", "The root folder can't be deleted.");
        item.Deleted = true;
        return new Outcome(204, [], []);
    }

    static string Token8(string token) => token[..8];

    Outcome DownloadRedirect(Item item)
    {
        if (item.IsFolder || item.RemoteID is not null) return Error(400, "invalidRequest", "Folders have no content.");
        if (item.Package is not null) return Error(406, "notSupported", "Packages can't be downloaded as a file.");
        var token = Guid.NewGuid().ToString();
        _state.Links[token] = new Link(item.Id, false);
        return Redirect($"https://{ContentHost}/dl/{token}?tempauth=fake-{Token8(token)}");
    }

    static readonly Regex CustomThumb = new(@"^c[1-9][0-9]{0,4}x[1-9][0-9]{0,4}(_crop)?$", RegexOptions.CultureInvariant);
    static readonly HashSet<string> NamedThumbs = ["small", "medium", "large", "smallSquare", "mediumSquare", "largeSquare"];

    Outcome Thumbnail(Item item, string p)
    {
        var parts = p.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length != 4 || parts[0] != "thumbnails" || parts[1] != "0" || parts[3] != "content") return Error(400, "invalidRequest", "Bad thumbnail path.");
        var size = parts[2];
        _state.ThumbnailSizes.Add(size);
        if (!NamedThumbs.Contains(size) && !(CustomThumb.IsMatch(size) && _state.CustomThumbnails)) return Error(400, "invalidRequest", "Invalid thumbnail size.");
        if (!item.HasThumbnail || !_state.Blobs.ContainsKey(item.Id)) return Error(404, "itemNotFound", "The item has no thumbnail.");
        var token = Guid.NewGuid().ToString();
        _state.Links[token] = new Link(item.Id, true);
        return Redirect($"https://{ContentHost}/thumb/{token}?tempauth=fake-{Token8(token)}");
    }

    Outcome SimpleUpload(Item parent, string name, Dictionary<string, string> q, byte[] body)
    {
        if (BadName(name)) return Error(400, "invalidRequest", "The name contains invalid characters.");
        if (body.Length > SimpleUploadLimit) return Error(413, "requestTooLarge", "Use an upload session for files over 4 MB.");
        var finalName = name;
        if (_state.Child(name, parent.Id) is { } existing)
        {
            switch (q.GetValueOrDefault("@microsoft.graph.conflictBehavior") ?? "replace")
            {
                case "fail": return Error(409, "nameAlreadyExists", "The specified item name already exists.");
                case "rename": finalName = _state.FreeName(name, parent.Id); break;
                default:
                    if (existing.IsFolder) return Error(409, "nameAlreadyExists", "A folder with that name exists.");
                    _state.Blobs[existing.Id] = body;
                    existing.Version++;
                    existing.Modified = existing.FsModified = DateTimeOffset.UtcNow;
                    _state.SimpleUploads++;
                    return Json(200, ItemJSON(existing));
            }
        }
        if (_state.Used + body.Length > _state.Total) return Error(507, "quotaLimitReached", "Insufficient Space Available");
        var id = _state.Add(finalName, parent.Id, false, body, DateTimeOffset.UtcNow);
        _state.SimpleUploads++;
        if (_state.LoseUploadAnswers > 0) { _state.LoseUploadAnswers--; return DropOutcome; }
        return Json(201, ItemJSON(_state.Items[id]));
    }

    Outcome CreateSession(Item parent, string name, byte[] body)
    {
        if (BadName(name)) return Error(400, "invalidRequest", "The name contains invalid characters.");
        var item = J.Parse(body)["item"];
        if (item["name"].Str is { } n && n != name) return Error(400, "invalidRequest", "The name in the body doesn't match the path.");
        var behavior = item["@microsoft.graph.conflictBehavior"].Str ?? "replace";
        if (behavior == "fail" && _state.Child(name, parent.Id) is not null) return Error(409, "nameAlreadyExists", "The specified item name already exists.");
        var total = item["fileSize"].Int64;
        if (total is { } tt && _state.Used + tt > _state.Total) return Error(507, "quotaLimitReached", "Insufficient Space Available");
        var sid = Guid.NewGuid().ToString();
        var expires = DateTimeOffset.UtcNow.AddHours(1);
        _state.Sessions[sid] = new UploadSession
        {
            Parent = parent.Id, Name = name, Total = total, Behavior = behavior, FsModified = item["fileSystemInfo"]["lastModifiedDateTime"].Date, Expires = expires,
        };
        _state.SessionsCreated++;
        _state.LastSessionItem = new J(item.Node?.DeepClone());
        return Json(200, new JsonObject
        {
            ["uploadUrl"] = $"https://{ContentHost}/up/{sid}?tempauth=fake-{Token8(sid)}", ["expirationDateTime"] = Iso(expires),
            ["nextExpectedRanges"] = new JsonArray("0-"),
        });
    }

    // MARK: Pre-authenticated host

    Outcome ContentHostRequest(string method, Uri url, HttpRequestMessage r, byte[] body)
    {
        var parts = url.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);   // [kind, token]
        if (parts.Length != 2) return Error(404, "itemNotFound", "Not found.");
        var token = parts[1];
        switch (parts[0])
        {
            case "dl" or "thumb":
            {
                if (method != "GET" || !_state.Links.TryGetValue(token, out var link) || link.Thumbnail != (parts[0] == "thumb")
                    || !_state.Blobs.TryGetValue(link.Item, out var data) || !_state.Items.TryGetValue(link.Item, out var it))
                    return Error(404, "itemNotFound", "The link expired.");
                if (!link.Thumbnail && _state.DropDownloadsNext > 0)
                {
                    _state.DropDownloadsNext--;
                    return DropOutcome;
                }
                return new Outcome(200, new() { ["Content-Type"] = it.Mime ?? "application/octet-stream" }, data);
            }
            case "up":
                return SessionRequest(method, token, r, body);
            default:
                return Error(404, "itemNotFound", "Not found.");
        }
    }

    Outcome SessionRequest(string method, string sid, HttpRequestMessage r, byte[] body)
    {
        if (!_state.Sessions.TryGetValue(sid, out var s)) return Error(404, "itemNotFound", "The upload session was not found.");
        JsonObject Status() => new() { ["expirationDateTime"] = Iso(s.Expires), ["nextExpectedRanges"] = new JsonArray($"{s.Data.Length}-") };
        switch (method)
        {
            case "GET":
                _state.SessionStatusQueries++;
                return Json(200, Status());
            case "DELETE":
                _state.Sessions.Remove(sid);
                _state.SessionsCancelled++;
                return new Outcome(204, [], []);
            case "PUT":
                break;
            default:
                return Error(405, "invalidRequest", "Method not allowed.");
        }
        var cr = H(r, "Content-Range") ?? "";
        var spec = cr.StartsWith("bytes ", StringComparison.Ordinal) ? cr["bytes ".Length..].Split('/') : [];
        var ab = spec.Length > 0 ? spec[0].Split('-').Select(x => long.TryParse(x, NumberStyles.None, CultureInfo.InvariantCulture, out var v) ? v : (long?)null).ToArray() : [];
        if (spec.Length != 2 || ab.Length != 2 || ab[0] is not { } a || ab[1] is not { } b
            || !long.TryParse(spec[1], NumberStyles.None, CultureInfo.InvariantCulture, out var total) || a > b || b >= total)
            return Error(400, "invalidRequest", "Invalid Content-Range.");
        var len = b - a + 1;
        if (body.Length != len) return Error(400, "invalidRequest", "Content-Range doesn't match the body length.");
        if (s.Total is { } t && t != total) return Error(400, "invalidRequest", "The file size doesn't match the size given for this upload.");
        s.Total = total;
        if (a != s.Data.Length) return Error(416, "invalidRange", $"Expected the fragment to start at {s.Data.Length}.");
        var last = b + 1 == total;
        if (!last && len % FragmentUnit != 0) return Error(400, "invalidRequest", "Fragments must be a multiple of 320 KiB.");
        if (len > 60 * 1024 * 1024) return Error(413, "requestTooLarge", "Fragments must be at most 60 MiB.");
        _state.ChunkPuts++;
        _state.ChunkSizes.Add((int)len);
        if (_state.DropChunk == _state.ChunkPuts)
        {
            // Only part of the fragment arrived before the connection broke.
            s.Data.Write(body, 0, (int)(len / 2 / FragmentUnit * FragmentUnit));
            return DropOutcome;
        }
        s.Data.Write(body);
        if (!last) return Json(202, Status());
        _state.Sessions.Remove(sid);
        var name = s.Name;
        if (_state.Child(s.Name, s.Parent) is { } existing)
        {
            switch (s.Behavior)
            {
                case "fail": return Error(409, "nameAlreadyExists", "The specified item name already exists.");
                case "rename": name = _state.FreeName(s.Name, s.Parent); break;
                default: existing.Deleted = true; break;
            }
        }
        if (_state.Used + total > _state.Total) return Error(507, "quotaLimitReached", "Insufficient Space Available");
        var id = _state.Add(name, s.Parent, false, s.Data.ToArray(), DateTimeOffset.UtcNow, s.FsModified);
        if (_state.LoseUploadAnswers > 0) { _state.LoseUploadAnswers--; return DropOutcome; }
        return Json(201, ItemJSON(_state.Items[id]));
    }
}
