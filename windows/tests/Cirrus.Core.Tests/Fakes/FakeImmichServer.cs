using System.Collections.Concurrent;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using Cirrus.Core;

namespace Cirrus.Fakes;

/// <summary>
/// A stateful stand-in for an Immich v3 server (photos.example.com, plus LAN addresses), served as an HttpMessageHandler
/// (port of FakeImmichServer.swift). Unit tests use it as the mock server; Debug builds of the app in demo mode can route
/// the demo Immich account to it. It is strict about the v3 wire protocol so it catches client mistakes: the
/// <c>x-api-key</c> header and the key's permissions (403 "Missing required permission"), unknown or removed request fields
/// (400, e.g. <c>deviceAssetId</c> on uploads), the structured search shape of 3.2+ (<c>filter</c> / <c>orderBy</c> /
/// <c>cursor</c>, never mixed with the deprecated flat fields) or the flat one before 3.2, cursor paging, v3 response and
/// error shapes, albums with <c>albumUsers</c> roles, favorites, the archive, the trash (and <c>force</c> deletes, counted),
/// multipart uploads with SHA-1 duplicate detection, Live Photo linking, thumbnails and originals. Never part of a Release build.
/// </summary>
public sealed class FakeImmichServer : HttpMessageHandler, IFakeCloud
{
    public sealed class User
    {
        public string Id { get; set; } = "";
        public string Email { get; set; } = "";
        public string Name { get; set; } = "";
    }

    public sealed class Asset
    {
        public string Id { get; set; } = "";
        public string OwnerID { get; set; } = "";
        public string OriginalFileName { get; set; } = "";
        public string MimeType { get; set; } = "";
        /// <summary>"IMAGE" or "VIDEO".</summary>
        public string Type { get; set; } = "IMAGE";
        [JsonIgnore] public byte[] Data { get; set; } = [];
        /// <summary>The edited render (Immich's non-destructive edits), served for <c>edited=true</c>.</summary>
        [JsonIgnore] public byte[]? EditedData { get; set; }
        public DateTimeOffset FileCreatedAt { get; set; }
        public DateTimeOffset FileModifiedAt { get; set; }
        public DateTimeOffset CreatedAt { get; set; }
        public DateTimeOffset UpdatedAt { get; set; }
        public bool IsFavorite { get; set; }
        /// <summary>"timeline", "archive", "hidden" (a Live Photo's motion part) or "locked".</summary>
        public string Visibility { get; set; } = "timeline";
        public DateTimeOffset? DeletedAt { get; set; }
        public string? LivePhotoVideoID { get; set; }
        public int? Width { get; set; }
        public int? Height { get; set; }
        public int? DurationMS { get; set; }
        public string Checksum { get; set; } = "";
        public string Thumbhash { get; set; } = "";
        /// <summary>Seeded pictures: how to draw them again at thumbnail size (uploads have none: their own bytes are served).</summary>
        public double? ArtHue { get; set; }
        public string? ArtLabel { get; set; }
        public bool HasEdit { get; set; }
        [JsonIgnore] public bool IsEdited => EditedData is not null;
        [JsonIgnore] public bool IsTrashed => DeletedAt is not null;
    }

    public sealed class Album
    {
        public string Id { get; set; } = "";
        public string Name { get; set; } = "";
        public string OwnerID { get; set; } = "";
        /// <summary>Other users: id → "editor" / "viewer".</summary>
        public Dictionary<string, string> Members { get; set; } = [];
        public List<string> AssetIDs { get; set; } = [];
        public DateTimeOffset CreatedAt { get; set; }
        public DateTimeOffset UpdatedAt { get; set; }
    }

    /// <summary>Everything the server knows. Tests read and tweak it between steps (through <see cref="Update"/>).</summary>
    public sealed class State
    {
        public HashSet<string> Hosts = ["photos.example.com", "192.168.1.20", "immich.local", "localhost"];
        /// <summary>Hosts that answer every request with a web page (not Immich).</summary>
        public HashSet<string> HtmlHosts = ["www.example.com"];
        /// <summary>Hosts that redirect every request to another one (old address → new).</summary>
        public Dictionary<string, string> RedirectHosts = new() { ["old.example.com"] = "photos.example.com" };
        public ImmichVersion Version = new(3, 4, 1);
        public User Me = new() { Id = "8a6f3c2e-5b1d-4e7a-9c3f-2d1e0b9a8c7d", Email = "alex@example.com", Name = "Alex Morgan" };
        public User Partner = new() { Id = "3c9b1d7e-2a4f-4b8c-8e1d-6f5a4b3c2d1e", Email = "sam@example.com", Name = "Sam Rivera" };
        /// <summary>The partner shares their library with "show in timeline" on, so Immich's search mixes their photos in.</summary>
        public bool PartnerInTimeline = true;
        /// <summary>API key → permissions ("all" or Immich permission names).</summary>
        public Dictionary<string, List<string>> ApiKeys = new() { [TestAPIKey] = ["all"] };
        public Dictionary<string, Asset> Assets = [];
        public Dictionary<string, Album> Albums = [];
        public bool TrashEnabled = true;
        public double Latency;
        // Fault injection
        /// <summary>The next N API requests get 429 with Retry-After: 0.</summary>
        public int RateLimitNext;
        /// <summary>The next N API requests get 503.</summary>
        public int UnavailableNext;
        /// <summary>The next N API requests get 500.</summary>
        public int FailNext;
        /// <summary>The next N API requests lose the connection.</summary>
        public int DropNext;
        // Statistics for tests
        /// <summary>"POST /search/metadata" (paths under /api; ids shown as ":id").</summary>
        public List<string> Calls = [];
        public List<JsonObject> SearchBodies = [];
        public List<JsonObject> DeleteBodies = [];
        /// <summary>Text fields of each upload, in order.</summary>
        public List<Dictionary<string, string>> UploadFields = [];
        public int Uploads, ForceDeletes, OriginalRequests;
        public List<string> ThumbnailRequests = [];
        /// <summary>Requests that carried an x-api-key header, per path.</summary>
        public List<string> KeyedPaths = [];
        public string? LastUserAgent;

        public Asset? AssetNamed(string name) => Assets.Values.FirstOrDefault(a => a.OriginalFileName == name);
        public Album? AlbumNamed(string name) => Albums.Values.FirstOrDefault(a => a.Name == name);

        /// <summary>The demo content (also a good starting point for tests).</summary>
        public static State Seeded()
        {
            var s = new State();
            Seed(s);
            return s;
        }
    }

    public const string TestAPIKey = "test-immich-api-key-0123456789abcdef";
    public const string DemoAPIKey = "demo-immich-api-key";
    public const string DemoServer = "https://photos.example.com";

    readonly object _lock = new();
    State _state;
    string? _persistDir;

    public FakeImmichServer(State? s = null) { _state = s ?? new State(); }

    /// <summary>The live state (read it when no request is in flight; change it through <see cref="Update"/>).</summary>
    public State S { get { lock (_lock) return _state; } }
    public void Reset(State? s = null) { lock (_lock) _state = s ?? new State(); }
    public void Update(Action<State> f) { lock (_lock) f(_state); }

    /// <summary>
    /// Demo mode: the seeded library behind photos.example.com only (so it shares a router with other fakes), accepting
    /// <see cref="DemoAPIKey"/>. With <paramref name="storageDir"/>, imports and edits are kept there across runs.
    /// </summary>
    public static FakeImmichServer Demo(string? storageDir = null)
    {
        var s = State.Seeded();
        s.ApiKeys = new() { [DemoAPIKey] = ["all"] };
        s.Latency = Env.Flag("CIRRUS_DEMO_FAST") ? 0 : 0.02;
        s.Hosts = ["photos.example.com"];
        s.HtmlHosts = [];
        s.RedirectHosts = [];
        var fake = new FakeImmichServer(s);
        if (storageDir is not null) fake.UseStorage(storageDir);
        return fake;
    }

    public static CloudConnection DemoConnection(string email = "alex@example.com") => new(
        new CloudAccountRecord(CloudProvider.Immich, email, DemoServer, email,
            new Dictionary<string, string> { ["permissions"] = "all", ["version"] = "3.4.1" }, id: "cloud:immich:demo")
        { Added = DateTimeOffset.FromUnixTimeSeconds(1_790_000_000) },
        new CloudSecret { Password = DemoAPIKey });

    // MARK: IFakeCloud

    public bool Handles(Uri uri)
    {
        var h = uri.Host.ToLowerInvariant();
        lock (_lock) return _state.Hosts.Contains(h) || _state.HtmlHosts.Contains(h) || _state.RedirectHosts.ContainsKey(h);
    }

    public IReadOnlyList<CloudConnection> DemoAccounts()
    {
        string email;
        lock (_lock) email = _state.Me.Email;
        return [DemoConnection(email)];
    }

    // MARK: Persistence (demo mode)

    sealed class Saved
    {
        public Dictionary<string, Asset> Assets { get; set; } = [];
        public Dictionary<string, Album> Albums { get; set; } = [];
    }

    void UseStorage(string dir)
    {
        lock (_lock)
        {
            Directory.CreateDirectory(Path.Combine(dir, "blobs"));
            _persistDir = dir;
            try
            {
                var file = Path.Combine(dir, "immich-state-v1.json");
                if (File.Exists(file) && JsonSerializer.Deserialize<Saved>(File.ReadAllBytes(file)) is { } saved)
                {
                    foreach (var a in saved.Assets.Values)
                    {
                        a.Data = File.ReadAllBytes(Path.Combine(dir, "blobs", a.Id));
                        var edited = Path.Combine(dir, "blobs", a.Id + ".edited");
                        if (a.HasEdit && File.Exists(edited)) a.EditedData = File.ReadAllBytes(edited);
                    }
                    _state.Assets = saved.Assets;
                    _state.Albums = saved.Albums;
                }
            }
            catch { }
            Persist();
        }
    }

    void Persist()
    {
        if (_persistDir is not { } dir) return;
        try
        {
            var blobs = Path.Combine(dir, "blobs");
            var keep = new HashSet<string>();
            foreach (var a in _state.Assets.Values)
            {
                a.HasEdit = a.EditedData is not null;
                var p = Path.Combine(blobs, a.Id);
                keep.Add(a.Id);
                if (!File.Exists(p)) File.WriteAllBytes(p, a.Data);
                if (a.EditedData is { } e)
                {
                    keep.Add(a.Id + ".edited");
                    if (!File.Exists(p + ".edited")) File.WriteAllBytes(p + ".edited", e);
                }
            }
            foreach (var f in Directory.EnumerateFiles(blobs)) if (!keep.Contains(Path.GetFileName(f))) File.Delete(f);   // the fake's own blobs
            var tmp = Path.Combine(dir, "immich-state-v1.json.tmp");
            File.WriteAllBytes(tmp, JsonSerializer.SerializeToUtf8Bytes(new Saved { Assets = _state.Assets, Albums = _state.Albums }));
            File.Move(tmp, Path.Combine(dir, "immich-state-v1.json"), true);
        }
        catch { }
    }

    // MARK: Seed

    public static string NewID() => Guid.NewGuid().ToString().ToLowerInvariant();
    public static string Sha1(byte[] d) => Convert.ToBase64String(SHA1.HashData(d));

    static readonly ConcurrentDictionary<(int, int, double, string), byte[]> ArtCache = new();

    /// <summary>A generated picture (PNG), drawn once per size and kept for the process.</summary>
    public static byte[] Art(int width, int height, double hue, string label) =>
        ArtCache.GetOrAdd((width, height, Math.Round(hue, 4), label), k => DemoArt.Png(k.Item1, k.Item2, k.Item3, k.Item4));

    /// <summary>A little fake movie: an MP4/QuickTime file type box and padding (enough for downloads and checksums).</summary>
    public static byte[] Movie(string brand, int bytes, int seed)
    {
        var d = new List<byte> { 0, 0, 0, 0x18 };
        d.AddRange(Encoding.ASCII.GetBytes("ftyp" + brand));
        d.AddRange(new byte[] { 0, 0, 0, 0 });
        d.AddRange(Encoding.ASCII.GetBytes(brand + "isom"));
        for (int i = 0; i < bytes; i++) d.Add(unchecked((byte)(i * 31 + seed)));
        return d.ToArray();
    }

    static readonly string[] Scenes = ["Beach", "Hike", "City", "Dinner", "Sunset", "Garden", "Snow", "Lake", "Market", "Concert", "Bridge", "Cafe"];

    static void Seed(State s)
    {
        var me = s.Me.Id;
        var partner = s.Partner.Id;
        var baseDate = DateTimeOffset.FromUnixTimeSeconds(1_790_000_000);   // late September 2026
        void Add(Asset a) => s.Assets[a.Id] = a;
        Asset Image(string name, string owner, int seed, DateTimeOffset created, bool portrait = false)
        {
            var (w, h) = portrait ? (360, 480) : (480, 360);
            var hue = (seed * 37 % 100) / 100.0;
            var label = Scenes[seed % Scenes.Length];
            var data = Art(w, h, hue, label);
            return new Asset
            {
                Id = NewID(), OwnerID = owner, OriginalFileName = name, MimeType = "image/png", Type = "IMAGE", Data = data,
                FileCreatedAt = created, FileModifiedAt = created, CreatedAt = baseDate, UpdatedAt = baseDate, Width = w, Height = h,
                Checksum = Sha1(data), Thumbhash = NewID()[..12], ArtHue = hue, ArtLabel = label,
            };
        }
        var mine = new List<Asset>();
        for (int i = 0; i < 20; i++)
        {
            // Spread over four months, newest first.
            var created = baseDate.AddSeconds(-(i * 86400 * 6.2) - (i * 3571 % 86400));
            var a = Image($"IMG_{1000 + i:0000}.PNG", me, i, created, portrait: i % 7 == 0);
            a.IsFavorite = i is 0 or 4 or 9;
            if (i == 7) a.Visibility = "archive";
            if (i == 12) a.DeletedAt = baseDate.AddSeconds(-3600);
            if (i == 9) a.EditedData = Art(480, 360, (a.ArtHue!.Value + 0.5) % 1, "Edited");
            mine.Add(a);
        }
        // A Live Photo: IMG_1003's motion part is a hidden video asset.
        var motionData = Movie("qt  ", 24_000, 3);
        var motion = new Asset
        {
            Id = NewID(), OwnerID = me, OriginalFileName = "IMG_1003.MOV", MimeType = "video/quicktime", Type = "VIDEO", Data = motionData,
            FileCreatedAt = mine[3].FileCreatedAt, FileModifiedAt = mine[3].FileCreatedAt, CreatedAt = baseDate, UpdatedAt = baseDate,
            Visibility = "hidden", Width = 480, Height = 360, DurationMS = 2500, Checksum = Sha1(motionData), Thumbhash = "motion",
        };
        mine[3].LivePhotoVideoID = motion.Id;
        Add(motion);
        // A short video.
        var videoData = Movie("mp42", 60_000, 7);
        var video = new Asset
        {
            Id = NewID(), OwnerID = me, OriginalFileName = "VID_2001.MP4", MimeType = "video/mp4", Type = "VIDEO", Data = videoData,
            FileCreatedAt = baseDate.AddDays(-2), FileModifiedAt = baseDate.AddDays(-2), CreatedAt = baseDate, UpdatedAt = baseDate,
            Width = 1920, Height = 1080, DurationMS = 4000, Checksum = Sha1(videoData), Thumbhash = "video",
        };
        Add(video);
        foreach (var a in mine) Add(a);
        // The partner's photos (in the timeline through partner sharing, and one in an album shared with Alex).
        var p1 = Image("PXL_3001.PNG", partner, 301, baseDate.AddDays(-1));
        var p2 = Image("PXL_3002.PNG", partner, 302, baseDate.AddDays(-40));
        Add(p1);
        Add(p2);
        var trip = new Album
        {
            Id = NewID(), Name = "Summer Trip", OwnerID = me, CreatedAt = baseDate, UpdatedAt = baseDate,
            AssetIDs = [.. mine.Where((_, i) => i % 3 == 0).Select(a => a.Id), video.Id],
        };
        var family = new Album
        {
            Id = NewID(), Name = "Family", OwnerID = me, CreatedAt = baseDate, UpdatedAt = baseDate,
            AssetIDs = mine.Where((_, i) => i % 5 == 1).Select(a => a.Id).ToList(), Members = { [partner] = "editor" },
        };
        var garden = new Album
        {
            Id = NewID(), Name = "Sam’s Garden", OwnerID = partner, CreatedAt = baseDate, UpdatedAt = baseDate, AssetIDs = [p1.Id], Members = { [me] = "viewer" },
        };
        foreach (var al in new[] { trip, family, garden }) s.Albums[al.Id] = al;
    }

    // MARK: HttpMessageHandler

    sealed record Outcome(int Status, Dictionary<string, string> Headers, byte[] Data, bool Drop = false);
    static readonly Outcome DropOutcome = new(0, [], [], true);

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        var body = request.Content is null ? [] : await request.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
        Outcome o;
        double latency;
        lock (_lock) { o = Handle(request, body); latency = _state.Latency; }
        if (latency > 0) await Task.Delay(TimeSpan.FromSeconds(latency), ct).ConfigureAwait(false);
        if (o.Drop) throw new HttpRequestException(HttpRequestError.ResponseEnded, "The network connection was lost.", new IOException("connection lost"));
        var resp = new HttpResponseMessage((HttpStatusCode)o.Status) { RequestMessage = request, Content = new ByteArrayContent(o.Data) };
        foreach (var (k, v) in o.Headers)
            if (!resp.Headers.TryAddWithoutValidation(k, v)) resp.Content.Headers.TryAddWithoutValidation(k, v);
        return resp;
    }

    static string? Header(HttpRequestMessage r, string name)
    {
        if (r.Headers.TryGetValues(name, out var v)) return string.Join(", ", v);
        if (r.Content?.Headers.TryGetValues(name, out var cv) == true) return string.Join(", ", cv);
        return null;
    }

    // MARK: Replies

    static Outcome Json(int status, JsonNode? j) =>
        new(status, new() { ["Content-Type"] = "application/json; charset=utf-8" }, Encoding.UTF8.GetBytes(j?.ToJsonString() ?? "null"));

    /// <summary>v3 error body: a message string, validation problems in <c>errors</c>, the correlation id in a header.</summary>
    static Outcome Error(int status, string message, params (string Path, string Message)[] errors)
    {
        var body = new JsonObject { ["message"] = message };
        if (errors.Length > 0)
            body["errors"] = new JsonArray(errors.Select(e => (JsonNode)new JsonObject
            {
                ["path"] = Jx.Strings(e.Path.Split('.')), ["message"] = e.Message,
            }).ToArray());
        return new(status, new() { ["Content-Type"] = "application/json; charset=utf-8", ["X-Correlation-ID"] = NewID() }, Encoding.UTF8.GetBytes(body.ToJsonString()));
    }

    static Outcome Invalid(string path, string message) => Error(400, "Validation failed", (path, message));

    static Outcome Html(string text) => new(200, new() { ["Content-Type"] = "text/html" }, Encoding.UTF8.GetBytes(text));

    static string Iso(DateTimeOffset d) => d.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
    static JsonNode? Date(DateTimeOffset? d) => d is { } x ? JsonValue.Create(Iso(x)) : null;
    static DateTimeOffset? ParseDate(string? s) =>
        s is not null && DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var d) ? d : null;

    static bool IsUUID(string s) => s.Length == 36 && Guid.TryParseExact(s, "D", out _);

    static JsonValueKind KindOf(JsonNode? n) => n switch
    {
        null => JsonValueKind.Null,
        JsonObject => JsonValueKind.Object,
        JsonArray => JsonValueKind.Array,
        JsonValue v => v.GetValueKind(),
        _ => JsonValueKind.Undefined,
    };
    static bool IsBool(JsonNode? n) => KindOf(n) is JsonValueKind.True or JsonValueKind.False;
    static string? Str(JsonNode? n) => KindOf(n) == JsonValueKind.String ? n!.GetValue<string>() : null;
    static bool? BoolOf(JsonNode? n) => IsBool(n) ? n!.GetValue<bool>() : null;
    static long? IntOf(JsonNode? n)
    {
        if (KindOf(n) != JsonValueKind.Number) return null;
        if (!double.TryParse(n!.ToJsonString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var d)) return null;
        return d == Math.Round(d) ? (long)d : null;
    }
    static IEnumerable<string> Keys(JsonNode? n) => n is JsonObject o ? o.Select(kv => kv.Key).ToList() : [];
    static bool Has(JsonObject o, string key) => o.ContainsKey(key);

    // MARK: Routing

    Outcome Handle(HttpRequestMessage req, byte[] body)
    {
        var s = _state;
        if (req.RequestUri is not { } url) return DropOutcome;
        var host = url.Host.ToLowerInvariant();
        var method = req.Method.Method.ToUpperInvariant();
        if (s.RedirectHosts.TryGetValue(host, out var target))
            return new(308, new() { ["Location"] = "https://" + target + url.PathAndQuery }, []);
        if (s.HtmlHosts.Contains(host)) return Html("<!doctype html><title>Welcome</title><p>It works!</p>");
        var path = url.AbsolutePath;
        // Immich's web app answers every other path with its single page.
        if (!(path == "/api" || path.StartsWith("/api/", StringComparison.Ordinal))) return Html("<!doctype html><title>Immich</title><div id=app></div>");
        if (s.DropNext > 0) { s.DropNext--; return DropOutcome; }
        var segs = path[4..].Split('/', StringSplitOptions.RemoveEmptyEntries).Select(Uri.UnescapeDataString).ToArray();
        var template = "/" + string.Join('/', segs.Select(x => IsUUID(x) ? ":id" : x));
        s.Calls.Add($"{method} {template}");
        s.LastUserAgent = Header(req, "User-Agent");
        if (Header(req, "x-api-key") is not null) s.KeyedPaths.Add(template);
        if (s.RateLimitNext > 0) { s.RateLimitNext--; return new(429, new() { ["Retry-After"] = "0", ["Content-Type"] = "text/plain" }, Encoding.UTF8.GetBytes("Too Many Requests")); }
        if (s.UnavailableNext > 0) { s.UnavailableNext--; return Error(503, "Service Unavailable"); }
        if (s.FailNext > 0) { s.FailNext--; return Error(500, "Failed to process the request"); }
        var query = QueryOf(url);

        // Public endpoints.
        switch (method, template)
        {
            case ("GET", "/server/ping"): return Json(200, new JsonObject { ["res"] = "pong" });
            case ("GET", "/server/version"):
                return Json(200, new JsonObject { ["major"] = s.Version.Major, ["minor"] = s.Version.Minor, ["patch"] = s.Version.Patch, ["prerelease"] = null });
            case ("GET", "/server/features"):
                return Json(200, new JsonObject
                {
                    ["trash"] = s.TrashEnabled, ["search"] = true, ["map"] = true, ["smartSearch"] = true, ["duplicateDetection"] = true,
                    ["facialRecognition"] = true, ["oauth"] = false, ["oauthAutoLaunch"] = false, ["passwordLogin"] = true, ["sidecar"] = true,
                    ["reverseGeocoding"] = true, ["importFaces"] = false, ["configFile"] = false, ["email"] = false, ["ocr"] = false,
                    ["realtimeTranscoding"] = false, ["backups"] = false,
                });
        }

        // Everything else needs the API key.
        if (Header(req, "x-api-key") is not { } key) return Error(401, "Authentication required");
        if (!s.ApiKeys.TryGetValue(key, out var perms)) return Error(401, "Invalid API key");
        bool Allowed(string p) => perms.Contains("all") || perms.Contains(p);
        Outcome? Need(string p) => Allowed(p) ? null : Error(403, "Missing required permission: " + p);

        JsonObject? json = null;
        if (method is "POST" or "PUT" or "PATCH" or "DELETE" && !(method == "POST" && template == "/assets"))
        {
            if (!(Header(req, "Content-Type") ?? "").StartsWith("application/json", StringComparison.Ordinal))
                return Error(400, "Content-Type must be application/json");
            try { json = JsonNode.Parse(body) as JsonObject; } catch (JsonException) { }
            if (json is null) return Invalid("", "Expected an object");
        }
        Outcome outcome = (method, template) switch
        {
            ("GET", "/users/me") => Need("user.read") ?? Json(200, UserAdmin(s.Me)),
            ("GET", "/api-keys/me") => Json(200, new JsonObject
            {
                ["id"] = "5f0e1d2c-3b4a-4596-8877-665544332211", ["name"] = "Cirrus", ["permissions"] = Jx.Strings(perms),
                ["createdAt"] = "2026-07-01T00:00:00.000Z", ["updatedAt"] = "2026-07-01T00:00:00.000Z",
            }),
            ("GET", "/assets/statistics") => Need("asset.statistics") ?? Statistics(query),
            ("POST", "/search/metadata") => Need("asset.read") ?? Search(json!),
            ("GET", "/albums") => Need("album.read") ?? ListAlbums(query),
            ("POST", "/albums") => Need("album.create") ?? CreateAlbum(json!),
            ("PUT", "/albums/:id/assets") => Need("albumAsset.create") ?? AddToAlbum(segs[1], json!, Allowed("asset.share")),
            ("PUT", "/assets") or ("PATCH", "/assets") => Need("asset.update") ?? BulkUpdate(json!),
            ("DELETE", "/assets") => Need("asset.delete") ?? DeleteAssets(json!),
            ("POST", "/trash/restore/assets") => Need("asset.delete") ?? Restore(json!),
            ("POST", "/assets/bulk-upload-check") => Need("asset.upload") ?? BulkUploadCheck(json!),
            ("POST", "/assets") => Need("asset.upload") ?? Upload(req, body, Allowed("asset.update")),
            ("GET", "/assets/:id/thumbnail") => Need("asset.view") ?? Thumbnail(segs[1], query),
            ("GET", "/assets/:id/original") => Need("asset.download") ?? Original(segs[1], query),
            _ => Error(404, $"Cannot {method} {path}"),
        };
        if (method != "GET") Persist();
        return outcome;
    }

    static Dictionary<string, string> QueryOf(Uri u)
    {
        var q = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var pair in u.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var kv = pair.Split('=', 2);
            q[Uri.UnescapeDataString(kv[0])] = kv.Length > 1 ? Uri.UnescapeDataString(kv[1]) : "";
        }
        return q;
    }

    static JsonObject UserJSON(User u) => new()
    {
        ["id"] = u.Id, ["email"] = u.Email, ["name"] = u.Name, ["avatarColor"] = "primary", ["profileImagePath"] = "",
        ["profileChangedAt"] = "2026-07-01T00:00:00.000Z",
    };

    static JsonObject UserAdmin(User u)
    {
        var o = UserJSON(u);
        o["isAdmin"] = true; o["createdAt"] = "2026-07-01T00:00:00.000Z"; o["updatedAt"] = "2026-07-01T00:00:00.000Z"; o["deletedAt"] = null;
        o["oauthId"] = ""; o["quotaSizeInBytes"] = null; o["quotaUsageInBytes"] = 0; o["shouldChangePassword"] = false; o["status"] = "active";
        o["storageLabel"] = "admin"; o["license"] = null; o["clusterGroupId"] = null;
        return o;
    }

    // MARK: Assets

    static JsonObject AssetJSON(Asset a, bool withExif)
    {
        var o = new JsonObject
        {
            ["id"] = a.Id, ["ownerId"] = a.OwnerID, ["type"] = a.Type, ["originalFileName"] = a.OriginalFileName, ["originalMimeType"] = a.MimeType,
            ["originalPath"] = $"/data/upload/{a.OwnerID}/{a.Id}", ["checksum"] = a.Checksum, ["thumbhash"] = a.Thumbhash,
            ["fileCreatedAt"] = Date(a.FileCreatedAt), ["fileModifiedAt"] = Date(a.FileModifiedAt), ["localDateTime"] = Date(a.FileCreatedAt),
            ["createdAt"] = Date(a.CreatedAt), ["updatedAt"] = Date(a.UpdatedAt),
            ["isFavorite"] = a.IsFavorite, ["isArchived"] = a.Visibility == "archive", ["isTrashed"] = a.IsTrashed, ["isOffline"] = false,
            ["isEdited"] = a.IsEdited, ["hasMetadata"] = true, ["visibility"] = a.Visibility,
            ["duration"] = a.DurationMS, ["width"] = a.Width, ["height"] = a.Height, ["livePhotoVideoId"] = a.LivePhotoVideoID,
            ["duplicateId"] = null, ["libraryId"] = null,
        };
        if (withExif)
            o["exifInfo"] = new JsonObject
            {
                ["fileSizeInByte"] = a.Data.Length, ["exifImageWidth"] = a.Width, ["exifImageHeight"] = a.Height, ["dateTimeOriginal"] = Date(a.FileCreatedAt),
                ["make"] = null, ["model"] = null, ["city"] = null, ["country"] = null, ["rating"] = null,
            };
        return o;
    }

    /// <summary>Who may see an asset: its owner, a partner sharing with them, or anyone in an album holding it.</summary>
    bool CanView(Asset a)
    {
        var s = _state;
        var me = s.Me.Id;
        if (a.OwnerID == me) return a.Visibility != "locked";
        if (a.OwnerID == s.Partner.Id && s.PartnerInTimeline && a.Visibility != "locked") return true;
        return s.Albums.Values.Any(al => (al.OwnerID == me || al.Members.ContainsKey(me)) && al.AssetIDs.Contains(a.Id));
    }

    Outcome Statistics(Dictionary<string, string> q)
    {
        foreach (var k in q.Keys) if (k is not ("isFavorite" or "isTrashed" or "visibility")) return Invalid(k, "Unrecognized key");
        if (q.TryGetValue("visibility", out var v) && v is not ("archive" or "timeline" or "hidden" or "locked")) return Invalid("visibility", "Invalid option");
        var trashed = q.GetValueOrDefault("isTrashed") == "true";
        var list = _state.Assets.Values.Where(a =>
        {
            if (a.OwnerID != _state.Me.Id || a.IsTrashed != trashed) return false;
            if (q.TryGetValue("visibility", out var vis)) { if (a.Visibility != vis) return false; }
            else if (a.Visibility is not ("archive" or "timeline")) return false;
            if (q.TryGetValue("isFavorite", out var f) && a.IsFavorite != (f == "true")) return false;
            return true;
        }).ToList();
        var videos = list.Count(a => a.Type == "VIDEO");
        return Json(200, new JsonObject { ["images"] = list.Count - videos, ["videos"] = videos, ["total"] = list.Count });
    }

    static readonly HashSet<string> NewShapeKeys = ["filter", "orderBy", "cursor"];
    static readonly HashSet<string> SharedSearchKeys = ["size", "withExif", "withPeople", "withStacked"];
    /// <summary>The deprecated flat fields this fake implements (the real list is longer; the rest answer 400 here).</summary>
    static readonly HashSet<string> LegacyKeys = ["page", "order", "visibility", "isFavorite", "withDeleted", "trashedAfter", "trashedBefore", "albumIds", "type", "updatedAfter"];
    static readonly HashSet<string> FilterKeysImplemented = ["visibility", "isFavorite", "trashedAt", "type", "albumIds", "updatedAt"];
    static readonly HashSet<string> FilterKeysValid =
    [
        "albumIds", "checksum", "city", "country", "createdAt", "description", "encodedVideoPath", "fileSizeInBytes", "hasAlbums", "hasPeople",
        "hasTags", "id", "isEncoded", "isFavorite", "isMotion", "isOffline", "lensModel", "libraryId", "make", "model", "ocr", "or",
        "originalFileName", "originalPath", "personIds", "rating", "state", "tagIds", "takenAt", "trashedAt", "type", "updatedAt", "visibility",
    ];

    static int CompareByDate(Asset a, Asset b, bool asc)
    {
        var c = a.FileCreatedAt != b.FileCreatedAt ? a.FileCreatedAt.CompareTo(b.FileCreatedAt) : string.CompareOrdinal(a.Id, b.Id);
        return asc ? c : -c;
    }

    Outcome Search(JsonObject o)
    {
        var s = _state;
        s.SearchBodies.Add((JsonObject)o.DeepClone());
        var structured = s.Version.HasStructuredSearch;
        var keys = Keys(o).ToList();
        var newKeys = keys.Where(NewShapeKeys.Contains).ToList();
        foreach (var k in keys)
            if (!NewShapeKeys.Contains(k) && !SharedSearchKeys.Contains(k) && !LegacyKeys.Contains(k))
                return Invalid(k, "Unrecognized key (or a search field this fake doesn’t implement)");
        long size = 250;
        if (Has(o, "size")) { if (IntOf(o["size"]) is not long sz) return Invalid("size", "Expected integer"); size = sz; }
        if (size is < 1 or > 1000) return Invalid("size", "Number must be between 1 and 1000");
        var me = s.Me.Id;
        var withExif = BoolOf(o["withExif"]) == true;
        List<Asset> list;
        if (newKeys.Count > 0)
        {
            if (!structured) return Invalid(newKeys[0], "Unrecognized key");   // before 3.2
            if (keys.FirstOrDefault(LegacyKeys.Contains) is { } old)
                return Invalid(old, $"Deprecated field {old} cannot be combined with {string.Join('/', newKeys.Order(StringComparer.Ordinal))}");
            var filterNode = Has(o, "filter") ? o["filter"] : new JsonObject();
            if (filterNode is not JsonObject f) return Invalid("filter", "Expected object");
            foreach (var k in Keys(f))
            {
                if (!FilterKeysValid.Contains(k)) return Invalid("filter." + k, "Unrecognized key");
                if (!FilterKeysImplemented.Contains(k)) return Invalid("filter." + k, "Not implemented by the fake server");
            }
            var albumIDs = new List<string>();
            if (Has(f, "albumIds"))
            {
                var ids = f["albumIds"];
                foreach (var k in Keys(ids)) if (k is not ("any" or "all" or "none")) return Invalid("filter.albumIds." + k, "Unrecognized key");
                if (ids is not JsonObject idObj || !Keys(idObj).All(k => k == "any")) return Invalid("filter.albumIds", "Only `any` is implemented by the fake server");
                albumIDs = (idObj["any"] as JsonArray ?? []).Select(Str).OfType<string>().ToList();
                if (albumIDs.Count == 0 || albumIDs.Count != (idObj["any"] as JsonArray)?.Count || !albumIDs.All(IsUUID))
                    return Invalid("filter.albumIds.any", "Expected non-empty array of uuids");
            }
            if (Has(f, "visibility") && EnumFilterProblem(f["visibility"], ["archive", "timeline", "hidden", "locked"]) is { } bad) return Invalid("filter.visibility", bad);
            if (Has(f, "type") && EnumFilterProblem(f["type"], ["IMAGE", "VIDEO", "AUDIO", "OTHER"]) is { } badType) return Invalid("filter.type", badType);
            if (Has(f, "isFavorite") && (!Keys(f["isFavorite"]).SequenceEqual(["eq"]) || !IsBool(f["isFavorite"]!["eq"])))
                return Invalid("filter.isFavorite", "Expected { eq: boolean }");
            if (Has(f, "trashedAt"))
                foreach (var k in Keys(f["trashedAt"]))
                    if (k is not ("eq" or "ne" or "gt" or "gte" or "lt" or "lte")) return Invalid("filter.trashedAt." + k, "Unrecognized key");
            if (Has(o, "orderBy"))
            {
                var ob = o["orderBy"];
                foreach (var k in Keys(ob)) if (k is not ("field" or "direction")) return Invalid("orderBy." + k, "Unrecognized key");
                if (Str(ob?["field"]) is { } fld && fld is not ("fileCreatedAt" or "localDateTime")) return Invalid("orderBy.field", "Invalid option");
                if (Str(ob?["direction"]) is { } d && d is not ("asc" or "desc")) return Invalid("orderBy.direction", "Invalid option");
            }
            if (albumIDs.Count == 0)
                list = s.Assets.Values.Where(a => a.OwnerID == me || (a.OwnerID == s.Partner.Id && s.PartnerInTimeline)).ToList();
            else
            {
                foreach (var id in albumIDs)
                    if (!s.Albums.TryGetValue(id, out var al) || !(al.OwnerID == me || al.Members.ContainsKey(me))) return Error(400, "Not found or no album.read access");
                var ids = albumIDs.SelectMany(id => s.Albums[id].AssetIDs).ToHashSet();
                list = s.Assets.Values.Where(a => ids.Contains(a.Id)).ToList();
            }
            list = list.Where(a =>
            {
                if (Has(f, "visibility") && !EnumMatches(f["visibility"], a.Visibility)) return false;
                if (!Has(f, "visibility") && a.Visibility == "locked") return false;
                if (Has(f, "type") && !EnumMatches(f["type"], a.Type)) return false;
                if (Has(f, "isFavorite") && BoolOf(f["isFavorite"]!["eq"]) is bool fav && a.IsFavorite != fav) return false;
                if (f["trashedAt"] is JsonObject t)
                {
                    if (t.ContainsKey("eq") && t["eq"] is null && a.DeletedAt is not null) return false;
                    if (t.ContainsKey("ne") && t["ne"] is null && a.DeletedAt is null) return false;
                }
                if (f["updatedAt"] is JsonObject u && ParseDate(Str(u["gt"])) is { } after && a.UpdatedAt <= after) return false;
                return true;
            }).ToList();
            var asc = Str(o["orderBy"]?["direction"]) == "asc";
            list.Sort((a, b) => CompareByDate(a, b, asc));
            long offset = 0;
            if (Has(o, "cursor"))
            {
                JsonObject? cj = null;
                if (Str(o["cursor"]) is { } c && FromBase64URL(c) is { } raw) { try { cj = JsonNode.Parse(raw) as JsonObject; } catch (JsonException) { } }
                if (cj is null || cj.Count != 1 || IntOf(cj["offset"]) is not long n || n < 0) return Error(400, "Invalid cursor");
                offset = n;
            }
            var pageItems = list.Skip((int)offset).Take((int)size).ToList();
            var more = list.Count > offset + size;
            JsonNode? next = more ? JsonValue.Create(Base64URL(Encoding.UTF8.GetBytes($"{{\"offset\":{offset + size}}}"))) : null;
            return Json(200, SearchResponse(pageItems, withExif, null, next, withCursor: true));
        }
        // The flat (deprecated) shape.
        if (Has(o, "page") && (IntOf(o["page"]) ?? 0) < 1) return Invalid("page", "Number must be greater than or equal to 1");
        if (Str(o["visibility"]) is { } vis)
        {
            if (vis is not ("archive" or "timeline" or "hidden" or "locked")) return Invalid("visibility", "Invalid option");
            if (vis == "locked") return Error(401, "Elevated permission is required");
        }
        if (Str(o["order"]) is { } ord && ord is not ("asc" or "desc")) return Invalid("order", "Invalid option");
        var page = IntOf(o["page"]) ?? 1;
        var legacyAlbums = (o["albumIds"] as JsonArray ?? []).Select(Str).OfType<string>().ToList();
        if (legacyAlbums.Count == 0)
            list = s.Assets.Values.Where(a => a.OwnerID == me || (a.OwnerID == s.Partner.Id && s.PartnerInTimeline)).ToList();
        else
        {
            foreach (var id in legacyAlbums)
                if (!s.Albums.TryGetValue(id, out var al) || !(al.OwnerID == me || al.Members.ContainsKey(me))) return Error(400, "Not found or no album.read access");
            var ids = legacyAlbums.SelectMany(id => s.Albums[id].AssetIDs).ToHashSet();
            list = s.Assets.Values.Where(a => ids.Contains(a.Id)).ToList();
        }
        var trashedAfter = ParseDate(Str(o["trashedAfter"]));
        var withDeleted = BoolOf(o["withDeleted"]) == true || trashedAfter is not null;
        list = list.Where(a =>
        {
            if (Str(o["visibility"]) is { } v) { if (a.Visibility != v) return false; }
            else if (a.Visibility == "locked") return false;
            if (BoolOf(o["isFavorite"]) is bool fav && a.IsFavorite != fav) return false;
            if (Str(o["type"]) is { } t && a.Type != t) return false;
            if (!withDeleted && a.DeletedAt is not null) return false;
            if (trashedAfter is { } after && !(a.DeletedAt is { } d && d >= after)) return false;
            return true;
        }).ToList();
        var ascending = Str(o["order"]) == "asc";
        list.Sort((a, b) => CompareByDate(a, b, ascending));
        var start = (page - 1) * size;
        var items = list.Skip((int)start).Take((int)size).ToList();
        var hasMore = list.Count > start + size;
        // 3.0–3.1 responses have no nextCursor.
        return Json(200, SearchResponse(items, withExif, hasMore ? (page + 1).ToString(CultureInfo.InvariantCulture) : null, null, withCursor: structured));
    }

    static string? EnumFilterProblem(JsonNode? v, string[] allowed)
    {
        if (v is not JsonObject o || o.Count == 0) return "Expected object";
        foreach (var (k, x) in o)
        {
            switch (k)
            {
                case "eq" or "ne":
                    if (!allowed.Contains(Str(x) ?? "")) return "Invalid option for " + k;
                    break;
                case "in" or "notIn":
                    var items = x as JsonArray;
                    if (items is null || items.Count == 0 || !items.All(i => allowed.Contains(Str(i) ?? ""))) return "Invalid options for " + k;
                    break;
                default:
                    return "Unrecognized key " + k;
            }
        }
        return null;
    }

    static bool EnumMatches(JsonNode? v, string value)
    {
        if (Str(v?["eq"]) is { } e && e != value) return false;
        if (Str(v?["ne"]) is { } n && n == value) return false;
        if (v?["in"] is JsonArray a && !a.Any(x => Str(x) == value)) return false;
        if (v?["notIn"] is JsonArray b && b.Any(x => Str(x) == value)) return false;
        return true;
    }

    static JsonObject SearchResponse(List<Asset> items, bool withExif, string? nextPage, JsonNode? nextCursor, bool withCursor)
    {
        var assets = new JsonObject
        {
            ["total"] = items.Count, ["count"] = items.Count, ["items"] = new JsonArray(items.Select(a => (JsonNode)AssetJSON(a, withExif)).ToArray()),
            ["facets"] = new JsonArray(), ["nextPage"] = nextPage,
        };
        if (withCursor) assets["nextCursor"] = nextCursor;
        return new JsonObject
        {
            ["albums"] = new JsonObject { ["total"] = 0, ["count"] = 0, ["items"] = new JsonArray(), ["facets"] = new JsonArray() },
            ["assets"] = assets,
        };
    }

    static Outcome? IdList(JsonObject body, HashSet<string> allowed, out List<string> ids)
    {
        ids = [];
        foreach (var k in Keys(body)) if (!allowed.Contains(k)) return Invalid(k, "Unrecognized key");
        if (body["ids"] is not JsonArray a) return Invalid("ids", "Required");
        ids = a.Select(Str).OfType<string>().ToList();
        if (ids.Count != a.Count || !ids.All(IsUUID)) return Invalid("ids", "Invalid uuid");
        return null;
    }

    Outcome BulkUpdate(JsonObject body)
    {
        var s = _state;
        if (IdList(body, ["ids", "isFavorite", "visibility", "dateTimeOriginal", "dateTimeRelative", "description", "duplicateId", "latitude", "longitude", "rating", "timeZone"],
            out var ids) is { } bad) return bad;
        if (Has(body, "isFavorite") && !IsBool(body["isFavorite"])) return Invalid("isFavorite", "Expected boolean");
        if (Has(body, "visibility"))
        {
            if (Str(body["visibility"]) is not { } v || v is not ("archive" or "timeline" or "hidden" or "locked")) return Invalid("visibility", "Invalid option");
            if (v == "locked") return Error(401, "Elevated permission is required");
        }
        foreach (var id in ids)
            if (!s.Assets.TryGetValue(id, out var a) || a.OwnerID != s.Me.Id) return Error(400, "Not found or no asset.update access");
        var now = DateTimeOffset.UtcNow;
        foreach (var id in ids)
        {
            var a = s.Assets[id];
            if (BoolOf(body["isFavorite"]) is bool f) a.IsFavorite = f;
            if (Str(body["visibility"]) is { } v) a.Visibility = v;
            a.UpdatedAt = now;
        }
        return new(204, [], []);
    }

    Outcome DeleteAssets(JsonObject body)
    {
        var s = _state;
        s.DeleteBodies.Add((JsonObject)body.DeepClone());
        if (IdList(body, ["ids", "force"], out var ids) is { } bad) return bad;
        if (Has(body, "force") && !IsBool(body["force"])) return Invalid("force", "Expected boolean");
        foreach (var id in ids)
            if (!s.Assets.TryGetValue(id, out var a) || a.OwnerID != s.Me.Id) return Error(400, "Not found or no asset.delete access");
        var force = BoolOf(body["force"]) == true;
        if (force) s.ForceDeletes++;
        foreach (var id in ids)
        {
            if (force || !s.TrashEnabled)
            {
                // Gone for good (with the trash off, the server's nightly job removes trashed photos at once).
                s.Assets.Remove(id);
                foreach (var al in s.Albums.Values) al.AssetIDs.RemoveAll(x => x == id);
            }
            else
            {
                s.Assets[id].DeletedAt = DateTimeOffset.UtcNow;
                s.Assets[id].UpdatedAt = DateTimeOffset.UtcNow;
            }
        }
        return new(204, [], []);
    }

    Outcome Restore(JsonObject body)
    {
        var s = _state;
        if (IdList(body, ["ids"], out var ids) is { } bad) return bad;
        foreach (var id in ids)
            if (!s.Assets.TryGetValue(id, out var a) || a.OwnerID != s.Me.Id) return Error(400, "Not found or no asset.delete access");
        var n = 0;
        foreach (var id in ids)
        {
            if (s.Assets[id].DeletedAt is null) continue;
            s.Assets[id].DeletedAt = null;
            s.Assets[id].UpdatedAt = DateTimeOffset.UtcNow;
            n++;
        }
        return Json(200, new JsonObject { ["count"] = n });
    }

    // MARK: Albums

    JsonObject AlbumJSON(Album al)
    {
        var s = _state;
        var me = s.Me.Id;
        User UserOf(string id) => id == s.Me.Id ? s.Me : s.Partner;
        var users = new JsonArray(new JsonObject { ["user"] = UserJSON(UserOf(al.OwnerID)), ["role"] = "owner" });
        if (al.OwnerID != me && al.Members.TryGetValue(me, out var myRole)) users.Add(new JsonObject { ["user"] = UserJSON(s.Me), ["role"] = myRole });
        foreach (var (id, role) in al.Members.OrderBy(kv => kv.Key, StringComparer.Ordinal))
            if (id != me) users.Add(new JsonObject { ["user"] = UserJSON(UserOf(id)), ["role"] = role });
        var live = al.AssetIDs.Select(id => s.Assets.GetValueOrDefault(id)).OfType<Asset>().Where(a => !a.IsTrashed).ToList();
        return new JsonObject
        {
            ["id"] = al.Id, ["albumName"] = al.Name, ["description"] = "", ["createdAt"] = Date(al.CreatedAt), ["updatedAt"] = Date(al.UpdatedAt),
            ["albumThumbnailAssetId"] = live.FirstOrDefault()?.Id, ["shared"] = al.Members.Count > 0, ["albumUsers"] = users,
            ["hasSharedLink"] = false, ["assetCount"] = live.Count, ["isActivityEnabled"] = true, ["order"] = "desc",
        };
    }

    Outcome ListAlbums(Dictionary<string, string> q)
    {
        foreach (var k in q.Keys) if (k is not ("id" or "name" or "isOwned" or "isShared" or "assetId")) return Invalid(k, "Unrecognized key");
        var me = _state.Me.Id;
        var list = _state.Albums.Values.Where(a => a.OwnerID == me || a.Members.ContainsKey(me));
        if (q.TryGetValue("isOwned", out var owned)) list = list.Where(a => (a.OwnerID == me) == (owned == "true"));
        if (q.TryGetValue("isShared", out var shared)) list = list.Where(a => (a.Members.Count > 0) == (shared == "true"));
        return Json(200, new JsonArray(list.OrderByDescending(a => a.CreatedAt).Select(a => (JsonNode)AlbumJSON(a)).ToArray()));
    }

    Outcome CreateAlbum(JsonObject body)
    {
        var s = _state;
        foreach (var k in Keys(body)) if (k is not ("albumName" or "description" or "albumUsers" or "assetIds")) return Invalid(k, "Unrecognized key");
        if (Str(body["albumName"]) is not { } name) return Invalid("albumName", "Required");
        var now = DateTimeOffset.UtcNow;
        var al = new Album { Id = NewID(), Name = name, OwnerID = s.Me.Id, CreatedAt = now, UpdatedAt = now };
        foreach (var id in (body["assetIds"] as JsonArray ?? []).Select(Str).OfType<string>())
            if (s.Assets.TryGetValue(id, out var a) && a.OwnerID == s.Me.Id) al.AssetIDs.Add(id);
        s.Albums[al.Id] = al;
        return Json(201, AlbumJSON(al));
    }

    Outcome AddToAlbum(string albumID, JsonObject body, bool canShare)
    {
        var s = _state;
        var me = s.Me.Id;
        if (!s.Albums.TryGetValue(albumID, out var al) || !(al.OwnerID == me || al.Members.GetValueOrDefault(me) == "editor"))
            return Error(400, "Not found or no albumAsset.create access");
        if (IdList(body, ["ids"], out var ids) is { } bad) return bad;
        var results = new JsonArray();
        var added = false;
        foreach (var id in ids)
        {
            if (al.AssetIDs.Contains(id)) { results.Add(new JsonObject { ["id"] = id, ["success"] = false, ["error"] = "duplicate" }); continue; }
            if (!s.Assets.TryGetValue(id, out var a)) { results.Add(new JsonObject { ["id"] = id, ["success"] = false, ["error"] = "not_found" }); continue; }
            if (a.OwnerID != me || !canShare) { results.Add(new JsonObject { ["id"] = id, ["success"] = false, ["error"] = "no_permission" }); continue; }
            al.AssetIDs.Add(id);
            added = true;
            results.Add(new JsonObject { ["id"] = id, ["success"] = true });
        }
        if (added) al.UpdatedAt = DateTimeOffset.UtcNow;
        return Json(200, results);
    }

    // MARK: Uploads

    static readonly HashSet<string> Uploadable =
        ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "avif", "tif", "tiff", "dng", "cr2", "cr3", "nef", "arw", "raf", "rw2", "orf", "mov", "mp4", "m4v", "3gp", "avi", "mkv", "webm"];
    static readonly HashSet<string> VideoExts = ["mov", "mp4", "m4v", "3gp", "avi", "mkv", "webm"];

    Outcome BulkUploadCheck(JsonObject body)
    {
        var s = _state;
        foreach (var k in Keys(body)) if (k != "assets") return Invalid(k, "Unrecognized key");
        if (body["assets"] is not JsonArray items) return Invalid("assets", "Required");
        var results = new JsonArray();
        foreach (var it in items)
        {
            if (it is not JsonObject io || Str(io["id"]) is not { } id || Str(io["checksum"]) is not { } sum || io.Count != 2) return Invalid("assets", "Expected { id, checksum }");
            var normalized = sum.Length == 40 && FromHex(sum) is { } raw ? Convert.ToBase64String(raw) : sum;
            if (s.Assets.Values.FirstOrDefault(a => a.OwnerID == s.Me.Id && a.Checksum == normalized) is { } found)
                results.Add(new JsonObject { ["id"] = id, ["action"] = "reject", ["reason"] = "duplicate", ["assetId"] = found.Id, ["isTrashed"] = found.IsTrashed });
            else
                results.Add(new JsonObject { ["id"] = id, ["action"] = "accept" });
        }
        return Json(200, new JsonObject { ["results"] = results });
    }

    Outcome Upload(HttpRequestMessage req, byte[] body, bool canLink)
    {
        var s = _state;
        var me = s.Me.Id;
        // The checksum header lets Immich answer "duplicate" before reading the file.
        if (Header(req, "x-immich-checksum") is { } headerSum && s.Assets.Values.FirstOrDefault(a => a.OwnerID == me && a.Checksum == headerSum) is { } dup)
            return Json(200, new JsonObject { ["id"] = dup.Id, ["status"] = "duplicate" });
        var ct = Header(req, "Content-Type") ?? "";
        var bi = ct.IndexOf("boundary=", StringComparison.Ordinal);
        if (!ct.StartsWith("multipart/form-data", StringComparison.Ordinal) || bi < 0) return Error(400, "Expected multipart/form-data");
        var boundary = ct[(bi + 9)..].Trim('"', ' ');
        if (ParseMultipart(body, boundary) is not { } parts) return Error(400, "Malformed multipart body");
        var fields = new Dictionary<string, string>();
        (string Name, byte[] Data)? file = null;
        foreach (var p in parts)
        {
            if (p.Name == "assetData")
            {
                if (p.Filename is not { } fn) return Invalid("assetData", "Expected a file");
                file = (fn, p.Data);
            }
            else if (p.Name == "sidecarData") continue;
            else
            {
                if (p.Filename is not null) return Invalid(p.Name, "Unexpected file");
                fields[p.Name] = Encoding.UTF8.GetString(p.Data);
            }
        }
        s.UploadFields.Add(new Dictionary<string, string>(fields));
        foreach (var k in fields.Keys)
            if (k is not ("fileCreatedAt" or "fileModifiedAt" or "duration" or "filename" or "isFavorite" or "visibility" or "livePhotoVideoId" or "metadata"))
                return Invalid(k, "Unrecognized key");   // deviceAssetId / deviceId were removed in v3
        if (file is not { } f || f.Data.Length == 0) return Error(400, "File is empty: assetData");
        if (ParseDate(fields.GetValueOrDefault("fileCreatedAt")) is not { } created) return Invalid("fileCreatedAt", "Invalid ISO datetime");
        if (ParseDate(fields.GetValueOrDefault("fileModifiedAt")) is not { } modified) return Invalid("fileModifiedAt", "Invalid ISO datetime");
        if (fields.TryGetValue("visibility", out var vis) && vis is not ("archive" or "timeline" or "hidden" or "locked")) return Invalid("visibility", "Invalid option");
        var name = fields.GetValueOrDefault("filename") is { Length: > 0 } given ? given : f.Name;
        var ext = Path.GetExtension(name).TrimStart('.').ToLowerInvariant();
        if (!Uploadable.Contains(ext)) return Error(400, "Unsupported file type " + name);
        if (fields.TryGetValue("livePhotoVideoId", out var live))
        {
            if (!canLink) return Error(403, "Missing required permission: asset.update");
            if (!IsUUID(live) || !s.Assets.TryGetValue(live, out var v) || v.OwnerID != me) return Error(400, "Not found or no asset.update access");
            if (v.Type != "VIDEO") return Error(400, "Live photo video must be a video");
            if (v.Visibility == "timeline") v.Visibility = "hidden";
        }
        var sum = Sha1(f.Data);
        if (s.Assets.Values.FirstOrDefault(a => a.OwnerID == me && a.Checksum == sum) is { } same)
            return Json(200, new JsonObject { ["id"] = same.Id, ["status"] = "duplicate" });
        var isVideo = VideoExts.Contains(ext);
        var dims = isVideo ? null : ImageSize(f.Data);
        var now = DateTimeOffset.UtcNow;
        var asset = new Asset
        {
            Id = NewID(), OwnerID = me, OriginalFileName = name, MimeType = Mime.ForName(name), Type = isVideo ? "VIDEO" : "IMAGE", Data = f.Data,
            FileCreatedAt = created, FileModifiedAt = modified, CreatedAt = now, UpdatedAt = now, IsFavorite = fields.GetValueOrDefault("isFavorite") == "true",
            Visibility = vis ?? "timeline", LivePhotoVideoID = live, Width = dims?.Width, Height = dims?.Height,
            DurationMS = int.TryParse(fields.GetValueOrDefault("duration"), out var dms) ? dms : null, Checksum = sum, Thumbhash = NewID()[..12],
        };
        s.Assets[asset.Id] = asset;
        s.Uploads++;
        return Json(201, new JsonObject { ["id"] = asset.Id, ["status"] = "created" });
    }

    /// <summary>Pixel size from a PNG or JPEG header.</summary>
    static (int Width, int Height)? ImageSize(byte[] d)
    {
        if (d.Length >= 24 && d[0] == 0x89 && d[1] == 'P' && d[2] == 'N' && d[3] == 'G')
            return ((d[16] << 24) | (d[17] << 16) | (d[18] << 8) | d[19], (d[20] << 24) | (d[21] << 16) | (d[22] << 8) | d[23]);
        if (d.Length >= 4 && d[0] == 0xFF && d[1] == 0xD8)
        {
            var i = 2;
            while (i + 9 < d.Length)
            {
                if (d[i] != 0xFF) return null;
                var marker = d[i + 1];
                var len = (d[i + 2] << 8) | d[i + 3];
                if (marker is >= 0xC0 and <= 0xCF and not 0xC4 and not 0xC8 and not 0xCC)
                    return ((d[i + 7] << 8) | d[i + 8], (d[i + 5] << 8) | d[i + 6]);
                i += 2 + len;
            }
        }
        return null;
    }

    sealed record Part(string Name, string? Filename, string? ContentType, byte[] Data);

    static int IndexOf(byte[] hay, byte[] needle, int from)
    {
        if (needle.Length == 0) return from;
        for (int i = from; i <= hay.Length - needle.Length; i++)
        {
            if (hay[i] != needle[0]) continue;
            var ok = true;
            for (int j = 1; j < needle.Length; j++) if (hay[i + j] != needle[j]) { ok = false; break; }
            if (ok) return i;
        }
        return -1;
    }

    static bool StartsAt(byte[] hay, int pos, byte[] prefix) => pos + prefix.Length <= hay.Length && hay.AsSpan(pos, prefix.Length).SequenceEqual(prefix);

    static List<Part>? ParseMultipart(byte[] body, string boundary)
    {
        var delim = Encoding.ASCII.GetBytes("--" + boundary);
        var crlf = "\r\n"u8.ToArray();
        var headerEnd = "\r\n\r\n"u8.ToArray();
        var next = Encoding.ASCII.GetBytes("\r\n--" + boundary);
        var parts = new List<Part>();
        var first = IndexOf(body, delim, 0);
        if (first < 0) return null;
        var pos = first + delim.Length;
        while (true)
        {
            // After a delimiter: "--" ends the body, otherwise CRLF then a part.
            if (StartsAt(body, pos, "--"u8.ToArray())) return parts;
            if (!StartsAt(body, pos, crlf)) return null;
            pos += 2;
            var he = IndexOf(body, headerEnd, pos);
            if (he < 0) return null;
            var headers = Encoding.UTF8.GetString(body, pos, he - pos);
            var contentStart = he + headerEnd.Length;
            var end = IndexOf(body, next, contentStart);
            if (end < 0) return null;
            string name = "";
            string? filename = null, contentType = null;
            foreach (var line in headers.Split("\r\n"))
            {
                if (line.StartsWith("content-disposition:", StringComparison.OrdinalIgnoreCase))
                {
                    name = Param(line, "name") ?? "";
                    filename = Param(line, "filename");
                }
                else if (line.StartsWith("content-type:", StringComparison.OrdinalIgnoreCase)) contentType = line["content-type:".Length..].Trim();
            }
            if (name.Length == 0) return null;
            parts.Add(new Part(name, filename, contentType, body[contentStart..end]));
            pos = end + next.Length;
        }
    }

    static string? Param(string header, string key)
    {
        foreach (var piece in header.Split(';').Skip(1))
        {
            var kv = piece.Trim();
            if (!kv.StartsWith(key + "=\"", StringComparison.Ordinal)) continue;
            return kv[(key.Length + 2)..^1];
        }
        return null;
    }

    // MARK: Media

    Outcome Thumbnail(string id, Dictionary<string, string> q)
    {
        var s = _state;
        foreach (var k in q.Keys) if (k is not ("size" or "edited" or "c" or "key" or "slug")) return Invalid(k, "Unrecognized key");
        var size = q.GetValueOrDefault("size") ?? "thumbnail";
        if (size is not ("thumbnail" or "preview" or "fullsize")) return Invalid("size", "Invalid option");
        if (!s.Assets.TryGetValue(id, out var a) || !CanView(a)) return Error(400, "Not found or no asset.view access");
        s.ThumbnailRequests.Add(size);
        var px = size == "thumbnail" ? 250 : 1440;
        var edited = q.GetValueOrDefault("edited") == "true" && a.EditedData is not null;
        byte[] image;
        if (a.Type == "IMAGE" && a.ArtLabel is { } label && a.ArtHue is { } hue)
        {
            int w = a.Width ?? 480, h = a.Height ?? 360;
            var scale = Math.Min(1.0, (double)px / Math.Max(w, h));
            image = Art(Math.Max(1, (int)Math.Round(w * scale)), Math.Max(1, (int)Math.Round(h * scale)), edited ? (hue + 0.5) % 1 : hue, edited ? "Edited" : label);
        }
        else if (a.Type == "IMAGE") image = (edited ? a.EditedData : null) ?? a.Data;   // an upload: its own picture
        else image = Art(Math.Min(px, 320), Math.Min(px, 180), 0.6, "Video");   // a poster frame for videos
        return new(200, new() { ["Content-Type"] = a.Type == "IMAGE" && a.ArtLabel is null ? a.MimeType : "image/png", ["Cache-Control"] = "private, max-age=86400" }, image);
    }

    Outcome Original(string id, Dictionary<string, string> q)
    {
        var s = _state;
        foreach (var k in q.Keys) if (k is not ("edited" or "key" or "slug")) return Invalid(k, "Unrecognized key");
        if (!s.Assets.TryGetValue(id, out var a) || !CanView(a)) return Error(400, "Not found or no asset.download access");
        s.OriginalRequests++;
        var data = (q.GetValueOrDefault("edited") == "true" ? a.EditedData : null) ?? a.Data;
        return new(200, new() { ["Content-Type"] = a.MimeType, ["Content-Disposition"] = $"attachment; filename=\"{a.OriginalFileName}\"" }, data);
    }

    // MARK: Encoding helpers

    public static byte[]? FromBase64URL(string s)
    {
        var t = s.Replace('-', '+').Replace('_', '/');
        while (t.Length % 4 != 0) t += "=";
        try { return Convert.FromBase64String(t); } catch (FormatException) { return null; }
    }

    public static string Base64URL(byte[] d) => Convert.ToBase64String(d).Replace('+', '-').Replace('/', '_').TrimEnd('=');

    static byte[]? FromHex(string hex)
    {
        try { return Convert.FromHexString(hex); } catch (FormatException) { return null; }
    }
}
