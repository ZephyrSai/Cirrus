using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Cirrus.Core;

namespace Cirrus.Fakes;

/// <summary>
/// A stateful stand-in for Dropbox's OAuth 2 endpoints and API v2 (www.dropbox.com's authorize page, api.dropboxapi.com
/// and content.dropboxapi.com), served as an HttpMessageHandler (port of FakeDropboxServer.swift). Unit tests use it as the
/// server; Debug builds in demo mode use it so Dropbox can be browsed without an account. It is strict where real clients
/// go wrong: exact redirect URIs, PKCE (S256) for a public client with no secret, one-time codes,
/// token_access_type=offline, expiring access tokens, Content-Type rules per endpoint style, ASCII-only Dropbox-API-Arg
/// headers, cursor paging with small pages (and cursor resets), upload sessions that insist on the right offset (and say
/// which one), conflicts for mode "add", case-insensitive names, write contention (too_many_write_operations) when writes
/// overlap, a deleted state that keeps files restorable, thumbnails, space usage, team spaces (Dropbox-API-Path-Root),
/// and 429s you can inject. Like Dropbox, writes create missing parent folders; it counts them so tests can make sure
/// Cirrus never relies on that. Never part of a Release build.
/// </summary>
public sealed class FakeDropboxServer : HttpMessageHandler, IFakeCloud
{
    public const string ApiHost = "api.dropboxapi.com";
    public const string ContentHost = "content.dropboxapi.com";
    public const string WwwHost = "www.dropbox.com";
    public static readonly DateTimeOffset SeedDate = DateTimeOffset.FromUnixTimeSeconds(1_788_000_000);
    public const int MaxRequestBody = 150 * 1024 * 1024;
    static readonly HashSet<string> WriteRoutes = ["files/create_folder_v2", "files/move_v2", "files/delete_v2", "files/upload", "files/upload_session/finish"];
    static readonly HashSet<string> ThumbnailExtensions = ["jpg", "jpeg", "png", "tiff", "tif", "gif", "webp", "ppm", "bmp"];
    static readonly HashSet<string> ThumbnailSizes = ["w32h32", "w64h64", "w128h128", "w256h256", "w480h320", "w640h480", "w960h640", "w1024h768", "w2048h1536"];

    public sealed class Item
    {
        public string Id { get; set; } = "";
        public string Name { get; set; } = "";
        /// <summary>The parent folder's id; "" for items at the top.</summary>
        public string Parent { get; set; } = "";
        public bool IsFolder { get; set; }
        public string Rev { get; set; } = "";
        public DateTimeOffset ClientModified { get; set; }
        public DateTimeOffset ServerModified { get; set; }
        public bool Deleted { get; set; }
        public string? SharedFolderID { get; set; }
        /// <summary>False: a Paper doc or other online-only file (export only).</summary>
        public bool Downloadable { get; set; } = true;
    }

    internal sealed class Session { public MemoryStream Data = new(); public bool Closed; }
    internal sealed record IssuedCode(string? Challenge, string? Redirect, HashSet<string> Scopes, bool Offline);
    internal sealed record Cursor(List<string> Ids, int Next);

    /// <summary>Everything the server knows. Tests read and tweak it between steps (through <see cref="Update"/>).</summary>
    public sealed class State
    {
        public string AppKey = "fk4bq2x9cirrus1";
        /// <summary>Redirect URIs registered in the App Console (matched exactly).</summary>
        public HashSet<string> RedirectURIs = [.. DropboxCloud.RedirectURIs];
        /// <summary>Settings › OAuth 2 › Allow public clients (PKCE).</summary>
        public bool AllowPublicClients = true;
        /// <summary>The permissions ticked in the App Console.</summary>
        public HashSet<string> AppScopes = [.. DropboxCloud.Scopes];
        /// <summary>What the token answer reports as granted (null: what was asked for).</summary>
        public HashSet<string>? GrantedScopes;
        public string AccountID = "dbid:AAH4f99T0taONIb-DemoAccountExample0";
        public string DisplayName = "Alex Morgan";
        public string Email = "alex@example.com";
        public string HomeNamespace = "3235641";
        /// <summary>A team with a team space: its root namespace, which requests must name in Dropbox-API-Path-Root.</summary>
        public string? TeamRootNamespace;
        public long Allocated = 2_199_023_255_552;
        /// <summary>A team allocation instead of an individual one.</summary>
        public (long Used, long Allocated, long MemberLimit)? Team;
        public double AccessTTL = 14_400;
        /// <summary>Entries per listing page at most (small, so clients must follow cursors).</summary>
        public int PageSize = 3;
        /// <summary>Hand out a new refresh token with each refresh (Dropbox normally doesn't).</summary>
        public bool RotateRefreshTokens;
        public double Latency;
        public Dictionary<string, Item> Items = [];
        public Dictionary<string, byte[]> Blobs = [];
        int _counter = 1000;
        internal Dictionary<string, IssuedCode> Codes = [];
        internal HashSet<string> RefreshTokens = [];
        internal Dictionary<string, DateTimeOffset> AccessTokens = [];
        internal Dictionary<string, Session> Sessions = [];
        internal Dictionary<string, Cursor> Cursors = [];
        internal int InflightWrites;
        internal int AppendCount;
        // Statistics for tests
        public List<string> Calls = [];
        public int Refreshes;
        /// <summary>Parameter names of each token request (never the values).</summary>
        public List<HashSet<string>> TokenRequestKeys = [];
        /// <summary>Every Dropbox-API-Arg header as received.</summary>
        public List<string> ArgHeaders = [];
        public int NonASCIIArgHeaders;
        /// <summary>API calls made without the Path-Root header while the account has a team space.</summary>
        public int MissingPathRoot;
        public int PathRootHeaders;
        public int SimpleUploads;
        public int SessionsStarted;
        public List<(long Offset, int Size)> Appends = [];
        public int Finishes;
        public J LastCommit;
        public List<J> ThumbnailArgs = [];
        public int MaxConcurrentWrites;
        public int Contentions;
        public int AutoCreatedFolders;
        public int Downloads;
        /// <summary>Authorization headers that reached a host other than Dropbox's API hosts (must stay empty).</summary>
        public List<string> TokensSentElsewhere = [];
        // Fault injection
        /// <summary>The next N API calls get 429 too_many_requests with Retry-After: 0.</summary>
        public int ThrottleNext;
        /// <summary>The next N writes get 429 too_many_write_operations.</summary>
        public int WriteContentionNext;
        /// <summary>A write that arrives while another is running gets too_many_write_operations, as on Dropbox.</summary>
        public bool ContentionOnConcurrentWrites = true;
        /// <summary>The Nth append (1-based, all sessions) is stored, then the connection drops before the answer.</summary>
        public int? LoseAppendAnswer;
        /// <summary>The Nth append breaks off before Dropbox stores any of it.</summary>
        public int? DropAppendBeforeStore;
        /// <summary>The next N commits (upload, or finish) are stored, but the answer is lost.</summary>
        public int LoseUploadAnswers;
        /// <summary>The next N downloads lose their connection.</summary>
        public int DropDownloadsNext;
        /// <summary>The next N list_folder/continue calls answer reset.</summary>
        public int ResetCursorsNext;

        // MARK: Seeding

        internal string NewID() { _counter++; return "id:FakeDbxAAAAAAAAAA" + _counter.ToString(CultureInfo.InvariantCulture); }
        internal string NewRev() { _counter++; return _counter.ToString("x", CultureInfo.InvariantCulture) + "0c10ce0dd78"; }

        internal string Add(string name, string parent, bool folder, byte[]? data, DateTimeOffset modified)
        {
            var id = NewID();
            Items[id] = new Item { Id = id, Name = name, Parent = parent, IsFolder = folder, Rev = NewRev(), ClientModified = modified, ServerModified = modified };
            if (data is not null) Blobs[id] = data;
            return id;
        }

        public string AddFolder(string name, string parent = "") => Add(name, parent, true, null, SeedDate);
        public string AddFile(string name, byte[] data, string parent = "", DateTimeOffset? modified = null) => Add(name, parent, false, data, modified ?? SeedDate);

        /// <summary>A Dropbox Paper doc: listed, but only exportable.</summary>
        public string AddPaperDoc(string name, string parent = "")
        {
            var id = Add(name, parent, false, new byte[2048], SeedDate);
            Items[id].Downloadable = false;
            return id;
        }

        public void Share(string folder) { if (Items.TryGetValue(folder, out var f)) f.SharedFolderID = "84528192421"; }

        /// <summary>Generic sample content for demo mode (the C# demo art is PNG, so the photos are .png).</summary>
        internal void SeedDemo()
        {
            var docs = AddFolder("Documents");
            AddFile("Meeting Notes.txt", Encoding.UTF8.GetBytes("Agenda\n- Welcome\n- Project updates\n- Next steps\n"), docs, DateTimeOffset.FromUnixTimeSeconds(1_789_200_000));
            AddFile("Budget.csv", Encoding.UTF8.GetBytes("Item,Q1,Q2,Q3\nTravel,1200,950,1100\nSoftware,400,400,450\nEvents,0,2500,800\n"), docs,
                DateTimeOffset.FromUnixTimeSeconds(1_789_500_000));
            var photos = AddFolder("Photos");
            var pics = new[] { ("Lake", 0.58), ("Market", 0.1) };
            for (int i = 0; i < pics.Length; i++)
                AddFile(pics[i].Item1 + ".png", DemoArt.Png(640, 427, pics[i].Item2, pics[i].Item1), photos, DateTimeOffset.FromUnixTimeSeconds(1_788_400_000 + i * 86_400L));
            AddFile("Read Me.txt", Encoding.UTF8.GetBytes("Sample files for trying Cirrus with Dropbox.\n"), "", DateTimeOffset.FromUnixTimeSeconds(1_788_100_000));
        }

        public string IssueRefreshToken()
        {
            var rt = "fake-dbx-refresh-" + Guid.NewGuid().ToString("N");
            RefreshTokens.Add(rt);
            return rt;
        }

        // MARK: Queries

        public List<string> ValidRefreshTokens => [.. RefreshTokens];
        public void ExpireAccessTokens() { foreach (var k in AccessTokens.Keys.ToList()) AccessTokens[k] = DateTimeOffset.MinValue; }
        public void RevokeRefreshTokens() { RefreshTokens.Clear(); AccessTokens.Clear(); }
        public int OpenUploadSessions => Sessions.Count;

        /// <summary>Deleted itself, or inside a deleted folder.</summary>
        internal bool IsGone(Item it)
        {
            Item? cur = it;
            while (cur is not null)
            {
                if (cur.Deleted) return true;
                cur = cur.Parent.Length == 0 ? null : Items.GetValueOrDefault(cur.Parent);
            }
            return false;
        }

        public Item? Live(string id) => Items.TryGetValue(id, out var it) && !IsGone(it) ? it : null;
        public List<Item> DeletedItems => Items.Values.Where(i => i.Deleted).ToList();
        public List<Item> Children(string id) => Items.Values.Where(i => i.Parent == id && !i.Deleted).ToList();

        /// <summary>Dropbox names are case-insensitive.</summary>
        public Item? Child(string name, string parent = "") =>
            Items.Values.FirstOrDefault(i => i.Parent == parent && !i.Deleted && string.Equals(i.Name, name, StringComparison.OrdinalIgnoreCase));

        public string PathOf(string id)
        {
            if (!Items.TryGetValue(id, out var it)) return "";
            return (it.Parent.Length == 0 ? "" : PathOf(it.Parent)) + "/" + it.Name;
        }

        internal bool IsInside(string id, string ancestor)
        {
            var cur = id;
            while (cur.Length > 0)
            {
                if (cur == ancestor) return true;
                cur = Items.TryGetValue(cur, out var it) ? it.Parent : "";
            }
            return false;
        }

        public long Used => Items.Values.Where(i => !i.IsFolder && !IsGone(i)).Sum(i => (long)(Blobs.GetValueOrDefault(i.Id)?.Length ?? 0));
    }

    readonly object _lock = new();
    State _state;
    string? _demoRefreshToken;

    public FakeDropboxServer(State? s = null) { _state = s ?? new State(); }

    /// <summary>The live state (read it when no request is in flight; change it through <see cref="Update"/>).</summary>
    public State S { get { lock (_lock) return _state; } }
    public void Reset(State? s = null) { lock (_lock) _state = s ?? new State(); }
    public void Update(Action<State> f) { lock (_lock) f(_state); }

    /// <summary>Demo mode: generic sample content (kept for the life of the fake) and a little latency.</summary>
    public static FakeDropboxServer Demo()
    {
        var s = new State { Latency = 0.01, PageSize = 100 };
        s.SeedDemo();
        return new FakeDropboxServer(s);
    }

    // MARK: IFakeCloud

    public bool Handles(Uri uri) => uri.Host is ApiHost or ContentHost or WwwHost;

    /// <summary>One Dropbox account the seeded content belongs to (its refresh token works with this fake's App key).</summary>
    public IReadOnlyList<CloudConnection> DemoAccounts()
    {
        lock (_lock)
        {
            _demoRefreshToken ??= _state.IssueRefreshToken();
            if (!_state.RefreshTokens.Contains(_demoRefreshToken)) _state.RefreshTokens.Add(_demoRefreshToken);
            var record = new CloudAccountRecord(CloudProvider.Dropbox, _state.Email, id: "cloud:dropbox:demo") { Added = DateTimeOffset.FromUnixTimeSeconds(1_790_000_000) };
            return [new CloudConnection(record, new CloudSecret { RefreshToken = _demoRefreshToken, ClientID = _state.AppKey })];
        }
    }

    // MARK: The browser step

    /// <summary>What Dropbox's authorize page does next.</summary>
    public abstract record Authorization
    {
        /// <summary>Where the browser goes next: the app's redirect URI with code and state, or with error.</summary>
        public sealed record Redirect(Uri Target) : Authorization;
        /// <summary>No redirect URI: Dropbox shows this code for the user to copy.</summary>
        public sealed record ShownCode(string Code) : Authorization;
        /// <summary>Dropbox shows an error page (bad app key, unregistered redirect URI…).</summary>
        public sealed record ErrorPage(string Message) : Authorization;
    }

    static Dictionary<string, string> QueryOf(Uri u)
    {
        var q = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var pair in u.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            // Strict like URLComponents: "+" stays a plus, so a client that forgets to encode it is caught.
            var kv = pair.Split('=', 2);
            q[Uri.UnescapeDataString(kv[0])] = kv.Length > 1 ? Uri.UnescapeDataString(kv[1]) : "";
        }
        return q;
    }

    static Uri Back(string redirect, IEnumerable<(string, string)> items) =>
        new(redirect + "?" + string.Join('&', items.Select(p => Uri.EscapeDataString(p.Item1) + "=" + Uri.EscapeDataString(p.Item2))));

    /// <summary>Plays Dropbox's authorize page for a signed-in user who chooses Allow (or Cancel, with <paramref name="deny"/>).</summary>
    public Authorization Authorize(Uri url, bool deny = false)
    {
        lock (_lock)
        {
            var q = QueryOf(url);
            if (url.Scheme != "https" || url.Host != WwwHost || url.AbsolutePath != "/oauth2/authorize") return new Authorization.ErrorPage("Not found");
            if (q.GetValueOrDefault("client_id") != _state.AppKey) return new Authorization.ErrorPage("Invalid client_id.");
            if (q.GetValueOrDefault("response_type") != "code") return new Authorization.ErrorPage("Invalid response_type.");
            var redirect = q.GetValueOrDefault("redirect_uri");
            if (redirect is not null && !_state.RedirectURIs.Contains(redirect))
                return new Authorization.ErrorPage("Invalid redirect_uri. It must exactly match one of the redirect URIs you’ve pre-configured for your app (including the path).");
            var challenge = q.GetValueOrDefault("code_challenge");
            if (challenge is not null && !_state.AllowPublicClients) return new Authorization.ErrorPage("This app doesn’t allow PKCE.");
            Authorization Fail(string error, string desc)
            {
                if (redirect is null) return new Authorization.ErrorPage(desc);
                var items = new List<(string, string)> { ("error", error), ("error_description", desc) };
                if (q.GetValueOrDefault("state") is { } s) items.Add(("state", s));
                return new Authorization.Redirect(Back(redirect, items));
            }
            if (challenge is not null && (q.GetValueOrDefault("code_challenge_method") != "S256" || challenge.Length != 43))
                return Fail("invalid_request", "Invalid code_challenge or code_challenge_method.");
            var asked = q.GetValueOrDefault("scope") is { } sc ? sc.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToHashSet() : null;
            if (asked is not null && !asked.IsSubsetOf(_state.AppScopes))
                return Fail("invalid_scope", "Your app doesn’t have the requested scopes: " + string.Join(' ', asked.Except(_state.AppScopes).Order(StringComparer.Ordinal)) + ".");
            if (deny) return Fail("access_denied", "The user chose not to give your app access to their Dropbox account.");
            var code = "fake-dbx-code-" + Guid.NewGuid().ToString("N");
            _state.Codes[code] = new IssuedCode(challenge, redirect, asked ?? [.. _state.AppScopes], q.GetValueOrDefault("token_access_type") == "offline");
            if (redirect is null) return new Authorization.ShownCode(code);
            var back = new List<(string, string)> { ("code", code) };
            if (q.GetValueOrDefault("state") is { } st) back.Add(("state", st));
            return new Authorization.Redirect(Back(redirect, back));
        }
    }

    /// <summary>Plays the browser: "signs in" on Dropbox's page and follows the redirect to the app's loopback listener.</summary>
    public async Task ApproveAsync(Uri authorizeURL, bool deny = false)
    {
        if (Authorize(authorizeURL, deny) is Authorization.Redirect r) await VisitAsync(r.Target).ConfigureAwait(false);
    }

    /// <summary>The code Dropbox shows when the sign-in has no redirect URI (null if it would show an error instead).</summary>
    public string? DisplayedCode(Uri authorizeURL) => Authorize(authorizeURL) is Authorization.ShownCode c ? c.Code : null;

    /// <summary>A GET over the real network stack (the app's loopback listener is a real socket, not this handler).</summary>
    public static async Task VisitAsync(Uri url)
    {
        using var http = new HttpClient(new SocketsHttpHandler { UseProxy = false }) { Timeout = TimeSpan.FromSeconds(20) };
        try { using var _ = await http.GetAsync(url).ConfigureAwait(false); } catch { }
    }

    // MARK: HttpMessageHandler

    sealed record Outcome(int Status, Dictionary<string, string> Headers, byte[] Data, bool Drop = false);
    static readonly Outcome DropOutcome = new(0, [], [], true);

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        var body = request.Content is null ? [] : await request.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
        var url = request.RequestUri!;
        Outcome o;
        if (url.Host == WwwHost) o = WwwPage(request);
        else
        {
            var route = url.AbsolutePath.StartsWith("/2/", StringComparison.Ordinal) ? url.AbsolutePath[3..] : "";
            var isWrite = WriteRoutes.Contains(route);
            Outcome? busy = null;
            double latency;
            // Dropbox locks the namespace for a write: one arriving while another runs is turned away.
            lock (_lock)
            {
                latency = _state.Latency;
                if (isWrite)
                {
                    _state.InflightWrites++;
                    _state.MaxConcurrentWrites = Math.Max(_state.MaxConcurrentWrites, _state.InflightWrites);
                    if (_state.ContentionOnConcurrentWrites && _state.InflightWrites > 1)
                    {
                        _state.InflightWrites--;
                        _state.Contentions++;
                        _state.Calls.Add($"{request.Method.Method} {url.Host}{url.AbsolutePath}");
                        busy = Contention();
                    }
                }
            }
            if (busy is not null) o = busy;
            else
            {
                try { if (latency > 0) await Task.Delay(TimeSpan.FromSeconds(latency), ct).ConfigureAwait(false); }
                catch { if (isWrite) lock (_lock) _state.InflightWrites--; throw; }
                lock (_lock)
                {
                    try { o = Handle(request, body); }
                    finally { if (isWrite) _state.InflightWrites--; }
                }
            }
        }
        if (o.Drop) throw new HttpRequestException(HttpRequestError.ResponseEnded, "The network connection was lost.", new IOException("connection lost"));
        var resp = new HttpResponseMessage((HttpStatusCode)o.Status) { RequestMessage = request, Content = new ByteArrayContent(o.Data) };
        var headers = new Dictionary<string, string>(o.Headers, StringComparer.OrdinalIgnoreCase);
        if (!headers.ContainsKey("Content-Type")) headers["Content-Type"] = "application/json";
        foreach (var (k, v) in headers)
            if (!resp.Headers.TryAddWithoutValidation(k, v)) resp.Content.Headers.TryAddWithoutValidation(k, v);
        return resp;
    }

    /// <summary>The authorize page itself, should anything fetch it: a redirect, the code to copy, or an error page.</summary>
    Outcome WwwPage(HttpRequestMessage r)
    {
        static Outcome Html(int status, string text) =>
            new(status, new() { ["Content-Type"] = "text/html; charset=utf-8" }, Encoding.UTF8.GetBytes("<!doctype html><title>Dropbox</title><p>" + WebUtility.HtmlEncode(text) + "</p>"));
        lock (_lock) _state.Calls.Add($"{r.Method.Method} {WwwHost}{r.RequestUri!.AbsolutePath}");
        if (r.Method != HttpMethod.Get) return Html(405, "Method not allowed");
        return Authorize(r.RequestUri!) switch
        {
            Authorization.Redirect back => new Outcome(302, new() { ["Location"] = back.Target.AbsoluteUri, ["Content-Type"] = "text/html" }, []),
            Authorization.ShownCode c => Html(200, "Enter this code into Cirrus to finish linking: " + c.Code),
            Authorization.ErrorPage e => Html(400, e.Message),
            _ => Html(500, "?"),
        };
    }

    static string? H(HttpRequestMessage r, string name)
    {
        if (r.Headers.TryGetValues(name, out var v)) return string.Join(", ", v);
        if (r.Content?.Headers.TryGetValues(name, out var cv) == true) return string.Join(", ", cv);
        return null;
    }

    // MARK: Helpers

    static Outcome Json(int status, JsonNode? j, Dictionary<string, string>? headers = null) =>
        new(status, headers ?? [], Encoding.UTF8.GetBytes(j?.ToJsonString() ?? "null"));

    /// <summary>A 400 "bad input" answer: plain text, as Dropbox sends it.</summary>
    static Outcome BadInput(string route, string why) =>
        new(400, new() { ["Content-Type"] = "text/plain; charset=utf-8" }, Encoding.UTF8.GetBytes($"Error in call to API function \"{route}\": {why}"));

    static Outcome Text(int status, string text) => new(status, new() { ["Content-Type"] = "text/plain" }, Encoding.UTF8.GetBytes(text));

    /// <summary>
    /// A route error (409): <paramref name="tags"/> is the union path, e.g. ["path", "conflict", "file"]; <paramref name="extra"/>
    /// goes into the innermost object (e.g. correct_offset).
    /// </summary>
    static Outcome RouteError(string[] tags, Dictionary<string, JsonNode?>? extra = null)
    {
        var inner = new JsonObject();
        foreach (var (k, v) in extra ?? []) inner[k] = v;
        inner[".tag"] = tags.Length > 0 ? tags[^1] : "other";
        JsonObject j = inner;
        for (int i = tags.Length - 2; i >= 0; i--) j = new JsonObject { [".tag"] = tags[i], [tags[i]] = j };
        return Json(409, new JsonObject { ["error_summary"] = string.Join('/', tags) + "/..", ["error"] = j });
    }

    static Outcome AuthError(string tag) =>
        Json(401, new JsonObject { ["error_summary"] = tag + "/..", ["error"] = new JsonObject { [".tag"] = tag } }, new() { ["WWW-Authenticate"] = "Bearer" });

    static Outcome RateLimited(string reason) =>
        Json(429, new JsonObject
        {
            ["error_summary"] = reason + "/..", ["error"] = new JsonObject { ["reason"] = new JsonObject { [".tag"] = reason }, ["retry_after"] = 0 },
        }, new() { ["Retry-After"] = "0" });

    static Outcome Contention() => RateLimited("too_many_write_operations");

    static string Iso(DateTimeOffset d) => d.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);

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

    /// <summary>Dropbox's content hash, computed independently of the client's.</summary>
    public static string ContentHash(byte[] d)
    {
        const int block = 4 * 1024 * 1024;
        using var digests = new MemoryStream();
        for (int i = 0; i < d.Length; i += block) digests.Write(SHA256.HashData(d.AsSpan(i, Math.Min(block, d.Length - i))));
        return Convert.ToHexStringLower(SHA256.HashData(digests.ToArray()));
    }

    /// <summary>
    /// Metadata as Dropbox sends it. <paramref name="tagged"/>: as a Metadata union (list_folder, get_metadata, move, delete);
    /// otherwise a bare FileMetadata/FolderMetadata struct (upload, create_folder, download's result header).
    /// </summary>
    JsonObject Meta(Item it, bool tagged)
    {
        var path = _state.PathOf(it.Id);
        var o = new JsonObject { ["name"] = it.Name, ["id"] = it.Id, ["path_display"] = path, ["path_lower"] = path.ToLowerInvariant() };
        if (it.IsFolder)
        {
            if (it.SharedFolderID is { } sf)
            {
                o["shared_folder_id"] = sf;
                o["sharing_info"] = new JsonObject { ["read_only"] = false, ["shared_folder_id"] = sf, ["traverse_only"] = false, ["no_access"] = false };
            }
        }
        else
        {
            var data = _state.Blobs.GetValueOrDefault(it.Id) ?? [];
            o["client_modified"] = Iso(it.ClientModified);
            o["server_modified"] = Iso(it.ServerModified);
            o["rev"] = it.Rev;
            o["size"] = (long)data.Length;
            o["is_downloadable"] = it.Downloadable;
            o["content_hash"] = ContentHash(data);
            if (!it.Downloadable) o["export_info"] = new JsonObject { ["export_as"] = "html", ["export_options"] = new JsonArray("html", "markdown") };
        }
        if (tagged) o[".tag"] = it.IsFolder ? "folder" : "file";
        return o;
    }

    enum Found { Root, Item, NotFound, Malformed }

    /// <summary>"" (the top), "id:…" or "/a/b" (case-insensitive).</summary>
    (Found Kind, Item? Item) Lookup(string path)
    {
        if (path.Length == 0) return (Found.Root, null);
        if (path.StartsWith("id:", StringComparison.Ordinal)) return _state.Live(path) is { } live ? (Found.Item, live) : (Found.NotFound, null);
        if (!path.StartsWith('/') || path == "/" || path.EndsWith('/')) return (Found.Malformed, null);
        var parent = "";
        Item? found = null;
        foreach (var part in path[1..].Split('/'))
        {
            if (part.Length == 0) return (Found.Malformed, null);
            if (_state.Child(part, parent) is not { } c) return (Found.NotFound, null);
            found = c;
            parent = c.Id;
        }
        return found is null ? (Found.NotFound, null) : (Found.Item, found);
    }

    /// <summary>
    /// The folder a new item at <paramref name="path"/> goes into; missing folders are created on the way, as Dropbox does.
    /// A null parent comes with the error to answer.
    /// </summary>
    (string? Parent, string Name, Outcome? Error) MakeParent(string path)
    {
        if (!path.StartsWith('/') || path.EndsWith('/')) return (null, "", RouteError(["path", "malformed_path"]));
        var parts = path[1..].Split('/').ToList();
        var name = parts[^1];
        parts.RemoveAt(parts.Count - 1);
        if (name.Length == 0 || name == "." || name == ".." || parts.Any(p => p.Length == 0)) return (null, name, RouteError(["path", "malformed_path"]));
        var parent = "";
        foreach (var part in parts)
        {
            if (_state.Child(part, parent) is { } c)
            {
                if (!c.IsFolder) return (null, name, RouteError(["path", "conflict", "file_ancestor"]));
                parent = c.Id;
            }
            else
            {
                parent = _state.Add(part, parent, true, null, DateTimeOffset.UtcNow);
                _state.AutoCreatedFolders++;
            }
        }
        return (parent, name, null);
    }

    static readonly Regex TimestampRx = new(@"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$", RegexOptions.CultureInvariant);

    // MARK: Routing

    Outcome Handle(HttpRequestMessage r, byte[] body)
    {
        var url = r.RequestUri!;
        var host = url.Host;
        _state.Calls.Add($"{r.Method.Method} {host}{url.AbsolutePath}");
        if (host is not (ApiHost or ContentHost))
        {
            if (r.Headers.Authorization is not null) _state.TokensSentElsewhere.Add(host);
            return Text(404, "Not a Dropbox API host");
        }
        if (url.Scheme != "https" || r.Method != HttpMethod.Post) return Text(405, "Method not allowed");
        if (host == ApiHost && url.AbsolutePath == "/oauth2/token") return Token(body);
        if (!url.AbsolutePath.StartsWith("/2/", StringComparison.Ordinal)) return Text(404, "Unknown endpoint");
        var route = url.AbsolutePath[3..];
        // Authentication.
        if (r.Headers.Authorization is not { Scheme: "Bearer", Parameter: { } token }) return AuthError("invalid_access_token");
        if (!_state.AccessTokens.TryGetValue(token, out var exp)) return AuthError("invalid_access_token");
        if (exp <= DateTimeOffset.UtcNow) return AuthError("expired_access_token");
        // Team spaces: requests name the root namespace.
        if (H(r, "Dropbox-API-Path-Root") is { } pr)
        {
            _state.PathRootHeaders++;
            var j = J.Parse(pr);
            if (_state.TeamRootNamespace is not { } ns || j[".tag"].Str != "root" || j["root"].Str != ns)
                return Json(422, new JsonObject
                {
                    ["error_summary"] = "invalid_root/..",
                    ["error"] = new JsonObject
                    {
                        [".tag"] = "invalid_root",
                        ["invalid_root"] = new JsonObject { [".tag"] = "user", ["root_namespace_id"] = _state.HomeNamespace, ["home_namespace_id"] = _state.HomeNamespace },
                    },
                });
        }
        else if (_state.TeamRootNamespace is not null) _state.MissingPathRoot++;
        if (_state.ThrottleNext > 0)
        {
            _state.ThrottleNext--;
            return RateLimited("too_many_requests");
        }
        if (WriteRoutes.Contains(route) && _state.WriteContentionNext > 0)
        {
            _state.WriteContentionNext--;
            _state.Contentions++;
            return Contention();
        }
        var contentType = r.Content?.Headers.ContentType?.ToString() ?? "";
        if (host == ApiHost)
        {
            // RPC: JSON in the body, or nothing at all for routes without arguments.
            var arg = J.Null;
            if (body.Length > 0)
            {
                if (!contentType.StartsWith("application/json", StringComparison.Ordinal))
                    return BadInput(route, $"Bad HTTP \"Content-Type\" header: \"{contentType}\". Expecting one of \"application/json\", \"application/json; charset=utf-8\", \"text/plain; charset=dropbox-cors-hack\".");
                try { arg = new J(JsonNode.Parse(body)); } catch (JsonException) { return BadInput(route, "request body: could not decode input as JSON"); }
            }
            else if (contentType.Length > 0) return BadInput(route, "request body: could not decode input as JSON");
            return Rpc(route, arg);
        }
        // Content: the argument in Dropbox-API-Arg, which must be HTTP-header safe (ASCII).
        if (H(r, "Dropbox-API-Arg") is not { } raw) return BadInput(route, "Missing Dropbox-API-Arg header.");
        _state.ArgHeaders.Add(raw);
        if (raw.Any(c => c >= 0x7F))
        {
            _state.NonASCIIArgHeaders++;
            return BadInput(route, "Dropbox-API-Arg header: non-ASCII characters must be escaped as \\uXXXX.");
        }
        var a = J.Parse(raw);
        if (a.Node is not JsonObject) return BadInput(route, "Dropbox-API-Arg: could not decode input as JSON");
        switch (route)
        {
            case "files/download" or "files/get_thumbnail_v2":
                if (body.Length > 0 || !(contentType.Length == 0 || contentType.StartsWith("text/plain", StringComparison.Ordinal)))
                    return BadInput(route, $"Bad HTTP \"Content-Type\" header: \"{contentType}\". Expecting one of \"text/plain\", \"text/plain; charset=utf-8\", \"application/octet-stream\", \"application/octet-stream; charset=utf-8\".");
                return route == "files/download" ? Download(a) : Thumbnail(a);
            default:
                if (contentType != "application/octet-stream")
                    return BadInput(route, $"Bad HTTP \"Content-Type\" header: \"{contentType}\". Expecting one of \"application/octet-stream\", \"text/plain; charset=dropbox-cors-hack\".");
                if (body.Length > MaxRequestBody) return Text(413, "Request body too large");
                return route switch
                {
                    "files/upload" => Upload(a, body),
                    "files/upload_session/start" => SessionStart(a, body),
                    "files/upload_session/append_v2" => SessionAppend(a, body),
                    "files/upload_session/finish" => SessionFinish(a, body),
                    _ => Text(404, "Unknown endpoint"),
                };
        }
    }

    // MARK: OAuth

    Outcome Token(byte[] body)
    {
        var f = Form(body);
        _state.TokenRequestKeys.Add([.. f.Keys]);
        static Outcome Bad(string error, string desc) => Json(400, new JsonObject { ["error"] = error, ["error_description"] = desc });
        if (f.GetValueOrDefault("client_id") != _state.AppKey) return Bad("invalid_client", "Invalid client_id or client_secret");
        // Cirrus is a public client: an app secret must never leave it.
        if (f.ContainsKey("client_secret")) return Bad("invalid_client", "This test app is a public client: no client_secret expected");
        switch (f.GetValueOrDefault("grant_type"))
        {
            case "authorization_code":
            {
                if (f.GetValueOrDefault("code") is not { } code || !_state.Codes.Remove(code, out var c)) return Bad("invalid_grant", "code doesn't exist or has expired");
                if (f.GetValueOrDefault("redirect_uri") != c.Redirect) return Bad("invalid_grant", "redirect_uri mismatch");
                if (c.Challenge is null) return Bad("invalid_request", "No client secret or code verifier provided");
                if (f.GetValueOrDefault("code_verifier") is not { Length: >= 43 and <= 128 } v || new Pkce(v).Challenge != c.Challenge)
                    return Bad("invalid_grant", "invalid code verifier");
                return Issue(c.Scopes, c.Offline ? _state.IssueRefreshToken() : null);
            }
            case "refresh_token":
            {
                if (f.GetValueOrDefault("refresh_token") is not { } t || !_state.RefreshTokens.Contains(t)) return Bad("invalid_grant", "refresh token is invalid or revoked");
                _state.Refreshes++;
                string? next = null;
                if (_state.RotateRefreshTokens)
                {
                    _state.RefreshTokens.Remove(t);
                    next = _state.IssueRefreshToken();
                }
                return Issue(_state.AppScopes, next);
            }
            default:
                return Bad("unsupported_grant_type", "grant_type must be authorization_code or refresh_token");
        }
    }

    Outcome Issue(HashSet<string> scopes, string? refresh)
    {
        var access = "sl.fake-dbx-access-" + Guid.NewGuid().ToString("N");
        _state.AccessTokens[access] = DateTimeOffset.UtcNow.AddSeconds(_state.AccessTTL);
        var o = new JsonObject
        {
            ["access_token"] = access, ["token_type"] = "bearer", ["expires_in"] = _state.AccessTTL,
            ["scope"] = string.Join(' ', (_state.GrantedScopes ?? scopes).Order(StringComparer.Ordinal)),
            ["account_id"] = _state.AccountID, ["uid"] = "1234567",
        };
        if (refresh is not null) o["refresh_token"] = refresh;
        return Json(200, o);
    }

    // MARK: RPC routes

    Outcome Rpc(string route, J a)
    {
        var s = _state;
        switch (route)
        {
            case "users/get_current_account":
            {
                if (!a.IsNull) return BadInput(route, "request body: expected null, got value");
                var root = s.TeamRootNamespace is { } team
                    ? new JsonObject { [".tag"] = "team", ["root_namespace_id"] = team, ["home_namespace_id"] = s.HomeNamespace, ["home_path"] = "/" + s.DisplayName }
                    : new JsonObject { [".tag"] = "user", ["root_namespace_id"] = s.HomeNamespace, ["home_namespace_id"] = s.HomeNamespace };
                var parts = s.DisplayName.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                return Json(200, new JsonObject
                {
                    ["account_id"] = s.AccountID,
                    ["name"] = new JsonObject
                    {
                        ["given_name"] = parts.FirstOrDefault() ?? "", ["surname"] = string.Join(' ', parts.Skip(1)), ["familiar_name"] = parts.FirstOrDefault() ?? "",
                        ["display_name"] = s.DisplayName, ["abbreviated_name"] = string.Concat(parts.Select(p => p[0])),
                    },
                    ["email"] = s.Email, ["email_verified"] = true, ["disabled"] = false, ["locale"] = "en", ["country"] = "US",
                    ["referral_link"] = "https://www.dropbox.com/referrals/fake", ["is_paired"] = false,
                    ["account_type"] = new JsonObject { [".tag"] = s.TeamRootNamespace is null ? "basic" : "business" }, ["root_info"] = root,
                });
            }
            case "users/get_space_usage":
            {
                if (!a.IsNull) return BadInput(route, "request body: expected null, got value");
                JsonObject allocation = s.Team is { } t
                    ? new JsonObject
                    {
                        [".tag"] = "team", ["used"] = t.Used, ["allocated"] = t.Allocated, ["user_within_team_space_allocated"] = t.MemberLimit,
                        ["user_within_team_space_limit_type"] = new JsonObject { [".tag"] = t.MemberLimit > 0 ? "stop_sync" : "off" },
                        ["user_within_team_space_used_cached"] = s.Used,
                    }
                    : new JsonObject { [".tag"] = "individual", ["allocated"] = s.Allocated };
                return Json(200, new JsonObject { ["used"] = s.Used, ["allocation"] = allocation });
            }
            case "files/list_folder": return ListFolder(a);
            case "files/list_folder/continue": return ListContinue(a);
            case "files/get_metadata":
            {
                if (a["path"].Str is not { } p) return BadInput(route, "missing required field 'path'");
                if (p.Length == 0) return BadInput(route, "request body: path: The root folder is unsupported.");
                var (kind, it) = Lookup(p);
                return kind switch
                {
                    Found.Item => Json(200, Meta(it!, tagged: true)),
                    Found.NotFound => RouteError(["path", "not_found"]),
                    _ => RouteError(["path", "malformed_path"]),
                };
            }
            case "files/create_folder_v2": return CreateFolder(a);
            case "files/move_v2": return Move(a);
            case "files/delete_v2": return Delete(a);
            default: return Text(404, "Unknown endpoint");
        }
    }

    Outcome ListFolder(J a)
    {
        const string route = "files/list_folder";
        if (a["path"].Str is not { } p) return BadInput(route, "missing required field 'path'");
        if (a["recursive"].Bool == true) return BadInput(route, "recursive listing isn't supported by this fake");
        if (a["limit"].Int is { } l && (l < 1 || l > 2000)) return BadInput(route, "limit: value outside range");
        string folder;
        var (kind, it) = Lookup(p);
        switch (kind)
        {
            case Found.Root: folder = ""; break;
            case Found.Item:
                if (!it!.IsFolder) return RouteError(["path", "not_folder"]);
                folder = it.Id;
                break;
            case Found.NotFound: return RouteError(["path", "not_found"]);
            default: return RouteError(["path", "malformed_path"]);
        }
        var ids = _state.Children(folder).OrderBy(i => i.Name.ToLowerInvariant(), StringComparer.Ordinal).ThenBy(i => i.Id, StringComparer.Ordinal).Select(i => i.Id).ToList();
        var size = Math.Min(a["limit"].Int ?? 2000, _state.PageSize);
        return Page(new Cursor(ids, 0), size);
    }

    Outcome Page(Cursor c, int size)
    {
        var slice = c.Ids.Skip(c.Next).Take(size).ToList();
        var next = c.Next + slice.Count;
        var entries = new JsonArray();
        foreach (var id in slice) if (_state.Live(id) is { } it) entries.Add(Meta(it, tagged: true));
        var cursor = "fake-cursor-" + Guid.NewGuid().ToString("N");
        _state.Cursors[cursor] = new Cursor(c.Ids, next);
        return Json(200, new JsonObject { ["entries"] = entries, ["cursor"] = cursor, ["has_more"] = next < c.Ids.Count });
    }

    Outcome ListContinue(J a)
    {
        if (a["cursor"].Str is not { } cursor || !_state.Cursors.TryGetValue(cursor, out var c)) return BadInput("files/list_folder/continue", "Invalid \"cursor\" parameter");
        if (_state.ResetCursorsNext > 0)
        {
            _state.ResetCursorsNext--;
            _state.Cursors.Clear();
            return RouteError(["reset"]);
        }
        return Page(c, _state.PageSize);
    }

    Outcome CreateFolder(J a)
    {
        const string route = "files/create_folder_v2";
        if (a["path"].Str is not { } p) return BadInput(route, "missing required field 'path'");
        // WritePath: a path, not an id.
        if (!p.StartsWith('/')) return BadInput(route, $"path: '{p}' did not match pattern '(/(.|[\\r\\n])*)|(ns:[0-9]+(/.*)?)'");
        var (parent, name, error) = MakeParent(p);
        if (error is not null) return error;
        if (parent is null) return RouteError(["path", "malformed_path"]);
        if (_state.Child(name, parent) is { } clash)
        {
            if (a["autorename"].Bool == true) return BadInput(route, "autorename isn't supported by this fake");
            return RouteError(["path", "conflict", clash.IsFolder ? "folder" : "file"]);
        }
        var id = _state.Add(name, parent, true, null, DateTimeOffset.UtcNow);
        return Json(200, new JsonObject { ["metadata"] = Meta(_state.Items[id], tagged: false) });
    }

    Outcome Move(J a)
    {
        const string route = "files/move_v2";
        if (a["from_path"].Str is not { } from || a["to_path"].Str is not { } to) return BadInput(route, "missing from_path or to_path");
        if (a["autorename"].Bool == true) return BadInput(route, "autorename isn't supported by this fake");
        var (kind, item) = Lookup(from);
        if (kind == Found.NotFound) return RouteError(["from_lookup", "not_found"]);
        if (kind != Found.Item) return RouteError(["from_lookup", "malformed_path"]);
        if (!to.StartsWith('/')) return RouteError(["to", "malformed_path"]);
        if (_state.PathOf(item!.Id) == to) return RouteError(["duplicated_or_nested_paths"]);
        // Where it would go, without creating anything yet.
        var parentPath = to[..to.LastIndexOf('/')];
        if (item.IsFolder && Lookup(parentPath) is (Found.Item, { } dest) && _state.IsInside(dest.Id, item.Id))
            return RouteError(["cant_move_folder_into_itself"]);
        var (parent, name, error) = MakeParent(to);
        if (error is not null) return error;
        if (parent is null) return RouteError(["to", "malformed_path"]);
        if (_state.Child(name, parent) is { } clash && clash.Id != item.Id) return RouteError(["to", "conflict", clash.IsFolder ? "folder" : "file"]);
        item.Parent = parent;
        item.Name = name;
        if (!item.IsFolder) { item.Rev = _state.NewRev(); item.ServerModified = DateTimeOffset.UtcNow; }
        return Json(200, new JsonObject { ["metadata"] = Meta(item, tagged: true) });
    }

    Outcome Delete(J a)
    {
        if (a["path"].Str is not { } p) return BadInput("files/delete_v2", "missing required field 'path'");
        var (kind, it) = Lookup(p);
        switch (kind)
        {
            case Found.Item:
                var m = Meta(it!, tagged: true);
                it!.Deleted = true;
                return Json(200, new JsonObject { ["metadata"] = m });
            case Found.NotFound: return RouteError(["path_lookup", "not_found"]);
            default: return RouteError(["path_lookup", "malformed_path"]);
        }
    }

    // MARK: Content routes

    Outcome Download(J a)
    {
        if (a["path"].Str is not { } p) return BadInput("files/download", "missing required field 'path'");
        if (Lookup(p) is not (Found.Item, { } it)) return RouteError(["path", "not_found"]);
        if (it.IsFolder) return RouteError(["path", "not_file"]);
        if (!it.Downloadable) return RouteError(["unsupported_file"]);
        if (_state.DropDownloadsNext > 0)
        {
            _state.DropDownloadsNext--;
            return DropOutcome;
        }
        _state.Downloads++;
        var data = _state.Blobs.GetValueOrDefault(it.Id) ?? [];
        // Default JSON escaping keeps the header ASCII, as Dropbox's is.
        return new Outcome(200, new()
        {
            ["Content-Type"] = "application/octet-stream", ["Dropbox-API-Result"] = Meta(it, tagged: false).ToJsonString(),
        }, data);
    }

    Outcome Thumbnail(J a)
    {
        const string route = "files/get_thumbnail_v2";
        _state.ThumbnailArgs.Add(a);
        if (a["resource"][".tag"].Str != "path" || a["resource"]["path"].Str is not { } p) return BadInput(route, "resource: expected path");
        var sizeOK = ThumbnailSizes.Contains(a["size"].Str ?? "w64h64");
        var formatOK = (a["format"].Str ?? "jpeg") is "jpeg" or "png";
        var modeOK = (a["mode"].Str ?? "strict") is "strict" or "bestfit" or "fitone_bestfit";
        if (!sizeOK || !formatOK || !modeOK) return BadInput(route, "unknown size, format or mode");
        if (Lookup(p) is not (Found.Item, { } it)) return RouteError(["path", "not_found"]);
        var ext = Path.GetExtension(it.Name).TrimStart('.').ToLowerInvariant();
        if (it.IsFolder || !ThumbnailExtensions.Contains(ext)) return RouteError(["unsupported_extension"]);
        var data = _state.Blobs.GetValueOrDefault(it.Id) ?? [];
        var isImage = data.AsSpan().StartsWith(new byte[] { 0xFF, 0xD8 }) || data.AsSpan().StartsWith(new byte[] { 0x89, 0x50, 0x4E, 0x47 });
        if (!isImage) return RouteError(["unsupported_image"]);
        return new Outcome(200, new()
        {
            ["Content-Type"] = a["format"].Str == "png" ? "image/png" : "image/jpeg", ["Dropbox-API-Result"] = Meta(it, tagged: false).ToJsonString(),
        }, data);
    }

    /// <summary>Mode "add" (the default) or "overwrite". Returns the stored item, or the error to answer.</summary>
    (Item? Item, Outcome? Error) Commit(J c, byte[] data, string route)
    {
        if (c["path"].Str is not { } p) return (null, BadInput(route, "missing required field 'path'"));
        if (!p.StartsWith('/')) return (null, BadInput(route, "path: this fake only accepts paths"));
        var mode = c["mode"].Str ?? c["mode"][".tag"].Str ?? "add";
        if (mode is not ("add" or "overwrite")) return (null, BadInput(route, "mode: unsupported by this fake"));
        if (c["autorename"].Bool == true) return (null, BadInput(route, "autorename isn't supported by this fake"));
        var modified = DateTimeOffset.UtcNow;
        if (c["client_modified"].Str is { } cm)
        {
            if (!TimestampRx.IsMatch(cm) || !DateTimeOffset.TryParseExact(cm, "yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture,
                    DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var d))
                return (null, BadInput(route, $"client_modified: '{cm}' is not a valid timestamp"));
            modified = d;
        }
        if (_state.Used + data.Length > (_state.Team?.Allocated ?? _state.Allocated)) return (null, RouteError(["path", "insufficient_space"]));
        var (parent, name, error) = MakeParent(p);
        if (error is not null) return (null, error);
        if (parent is null) return (null, RouteError(["path", "malformed_path"]));
        if (_state.Child(name, parent) is { } clash)
        {
            if (clash.IsFolder) return (null, RouteError(["path", "conflict", "folder"]));
            if (mode == "overwrite")
            {
                _state.Blobs[clash.Id] = data;
                clash.Rev = _state.NewRev();
                clash.ClientModified = modified;
                clash.ServerModified = DateTimeOffset.UtcNow;
                return (clash, null);
            }
            // Without strict_conflict, Dropbox treats the same bytes at the same path as success.
            if (c["strict_conflict"].Bool != true && _state.Blobs.GetValueOrDefault(clash.Id) is { } old && old.AsSpan().SequenceEqual(data)) return (clash, null);
            return (null, RouteError(["path", "conflict", "file"]));
        }
        var id = _state.Add(name, parent, false, data, modified);
        _state.Items[id].ServerModified = DateTimeOffset.UtcNow;
        return (_state.Items[id], null);
    }

    Outcome Upload(J a, byte[] body)
    {
        _state.LastCommit = a;
        var (item, error) = Commit(a, body, "files/upload");
        if (error is not null) return error;
        _state.SimpleUploads++;
        if (_state.LoseUploadAnswers > 0) { _state.LoseUploadAnswers--; return DropOutcome; }
        return Json(200, Meta(item!, tagged: false));
    }

    Outcome SessionStart(J a, byte[] body)
    {
        var sid = "fake-session-" + Guid.NewGuid().ToString("N");
        var s = new Session { Closed = a["close"].Bool == true };
        s.Data.Write(body);
        _state.Sessions[sid] = s;
        _state.SessionsStarted++;
        return Json(200, new JsonObject { ["session_id"] = sid });
    }

    Outcome SessionAppend(J a, byte[] body)
    {
        if (a["cursor"]["session_id"].Str is not { } sid || a["cursor"]["offset"].Int64 is not { } offset)
            return BadInput("files/upload_session/append_v2", "missing cursor");
        if (!_state.Sessions.TryGetValue(sid, out var s)) return RouteError(["not_found"]);
        if (s.Closed) return RouteError(["closed"]);
        if (offset != s.Data.Length) return RouteError(["incorrect_offset"], new() { ["correct_offset"] = s.Data.Length });
        _state.AppendCount++;
        if (_state.DropAppendBeforeStore == _state.AppendCount) return DropOutcome;
        s.Data.Write(body);
        s.Closed = a["close"].Bool == true;
        _state.Appends.Add((offset, body.Length));
        if (_state.LoseAppendAnswer == _state.AppendCount) return DropOutcome;
        return Json(200, null);
    }

    Outcome SessionFinish(J a, byte[] body)
    {
        const string route = "files/upload_session/finish";
        if (a["cursor"]["session_id"].Str is not { } sid || a["cursor"]["offset"].Int64 is not { } offset) return BadInput(route, "missing cursor");
        _state.LastCommit = a["commit"];
        if (!_state.Sessions.TryGetValue(sid, out var s)) return RouteError(["lookup_failed", "not_found"]);
        if (offset != s.Data.Length) return RouteError(["lookup_failed", "incorrect_offset"], new() { ["correct_offset"] = s.Data.Length });
        s.Data.Write(body);
        var (item, error) = Commit(a["commit"], s.Data.ToArray(), route);
        if (error is not null) return error;
        _state.Sessions.Remove(sid);
        _state.Finishes++;
        if (_state.LoseUploadAnswers > 0) { _state.LoseUploadAnswers--; return DropOutcome; }
        return Json(200, Meta(item!, tagged: false));
    }
}
