using System.IO;
using System.Net.Http;
using System.Globalization;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Cirrus.Core;

namespace Cirrus.Fakes;

/// <summary>
/// A stateful stand-in for Google's OAuth, Drive v3, Photos Library and Photos Picker endpoints, served as an
/// HttpMessageHandler (port of FakeGoogleServer.swift). Unit tests use it as the mock Google server; Debug builds of the
/// app in demo mode use it so both directions of the move run without a Google account. It follows the documented wire
/// protocol strictly (PKCE, per-token scopes, 256 KiB chunks, 50-item batches, app-created-only visibility for drive.file)
/// so it catches client mistakes. With the full <c>drive</c> scope it is also Google Drive as a browsable cloud (every file
/// visible and changeable, trash, shortcuts, thumbnails): <see cref="DriveDemo"/> is demo mode's "Google Drive" account,
/// served through <see cref="FakeCloudRouter"/>. Never part of a Release build.
/// </summary>
public sealed class FakeGoogle : HttpMessageHandler, IFakeCloud
{
    public sealed class FileRec
    {
        public string Id { get; set; } = "";
        public string Name { get; set; } = "";
        public string MimeType { get; set; } = "";
        public List<string> Parents { get; set; } = [];
        public long Size { get; set; }
        public string? Md5 { get; set; }
        public string? ModifiedTime { get; set; }
        public bool Trashed { get; set; }
        public Dictionary<string, string> AppProperties { get; set; } = [];
        public Dictionary<string, string> Properties { get; set; } = [];
        public bool ByApp { get; set; }
        public bool CanDownload { get; set; } = true;
        public bool ExportTooLarge { get; set; }
        public string? CreatedTime { get; set; }
        /// <summary>Shortcuts (mimeType application/vnd.google-apps.shortcut): the file or folder they point to.</summary>
        public string? ShortcutTarget { get; set; }
        public bool IsNative => MimeType.StartsWith("application/vnd.google-apps.", StringComparison.Ordinal) && MimeType != GoogleDrive.FolderMime;
        /// <summary>Google makes thumbnails for pictures, videos, PDFs and Docs editors files.</summary>
        public bool HasThumbnail => MimeType.StartsWith("image/", StringComparison.Ordinal) || MimeType.StartsWith("video/", StringComparison.Ordinal)
            || MimeType == "application/pdf" || MimeType is "application/vnd.google-apps.document" or "application/vnd.google-apps.spreadsheet"
                or "application/vnd.google-apps.presentation" or "application/vnd.google-apps.drawing";
    }
    public sealed class MediaItem { public string Id { get; set; } = ""; public string FileName { get; set; } = ""; public string? Description { get; set; } public long Size { get; set; } public string Md5 { get; set; } = ""; }
    public sealed class AlbumRec { public string Id { get; set; } = ""; public string Title { get; set; } = ""; public List<string> Items { get; set; } = []; }
    public sealed record PickerPhoto(string Id, string FileName, string Mime, byte[] Data, DateTimeOffset Created, bool IsVideo);
    public sealed record Blob(string Md5, long Size);
    internal sealed record Code(string Challenge, string Redirect, List<string> Scopes);
    internal sealed class DriveSession { public JsonObject Meta = new(); public long Total; public MemoryStream Data = new(); public string? FileID; public bool KeepData; }
    internal sealed class PhotoSession { public long Total; public MemoryStream Data = new(); public string? Token; }
    internal sealed class PickerSession { public List<string> Items = []; public bool Set; }

    public const string RootID = "0AFakeMyDriveRoot";
    const string ShortcutMime = "application/vnd.google-apps.shortcut";

    /// <summary>Everything the server knows. Tests read and tweak it between steps (through <see cref="Update"/>).</summary>
    public sealed class State
    {
        public string ClientID = "demo-client.apps.googleusercontent.com";
        public string? ClientSecret = "demo-secret";
        /// <summary>What the user ticks on the consent page (each sign-in gets the requested ones among these).</summary>
        public List<string> GrantedScopes = [.. GoogleScopes.Import, GoogleScopes.Drive];
        public string UserID = "demo-google-user";
        public string Email = "demo.person@gmail.example";
        public string Name = "Demo Person";
        public long? Limit = 15_000_000_000;
        public long Usage = 2_300_000_000;
        public double AccessTTL = 3600;
        public Dictionary<string, FileRec> Files = [];
        public Dictionary<string, byte[]> Blobs = [];          // content of the user's own Drive files
        public Dictionary<string, MediaItem> Media = [];
        public Dictionary<string, AlbumRec> Albums = [];
        public List<PickerPhoto> PickerLibrary = [];
        internal Dictionary<string, List<string>> RefreshTokens = [];   // refresh token → scopes
        internal Dictionary<string, (DateTimeOffset Expires, List<string> Scopes)> AccessTokens = [];
        internal Dictionary<string, Code> Codes = [];
        internal Dictionary<string, Blob> UploadTokens = [];
        internal Dictionary<string, string> MediaByHash = [];
        internal Dictionary<string, DriveSession> DriveSessions = [];
        internal Dictionary<string, PhotoSession> PhotoSessions = [];
        internal Dictionary<string, PickerSession> PickerSessions = [];
        // Statistics for tests
        public List<string> Calls = [];
        public int PermanentDeletes, DriveSessionsStarted, PhotoSessionsStarted, StatusQueries, Refreshes, ChunkPuts, RangedGets, ExportLinkUses, PickerSessionsDeleted;
        public List<int> BatchCreateSizes = [], AlbumAddSizes = [];
        /// <summary>Pixel sizes asked of the Drive thumbnail endpoint (<c>…=s&lt;px&gt;</c>).</summary>
        public List<int> ThumbnailSizes = [];
        /// <summary>Authorization headers that reached a host other than Google's (must stay empty).</summary>
        public List<string> TokensSentElsewhere = [];
        // Fault injection
        /// <summary>The Nth Drive chunk (1-based) arrives half-way, then the connection drops.</summary>
        public int? DropDriveChunk;
        /// <summary>The Nth Photos resumable chunk drops the same way.</summary>
        public int? DropPhotoChunk;
        /// <summary>After this many Drive chunks, every further chunk gets 503 (Google being down).</summary>
        public int? FailDriveChunksAfter;
        /// <summary>The Nth ranged download request loses its connection.</summary>
        public int? DropDownloadAt;
        /// <summary>The next N Drive/Photos API calls get 429 with Retry-After: 0.</summary>
        public int RateLimitNext;
        /// <summary>Photos Library requests left today (null = unlimited).</summary>
        public int? PhotosRequestsLeft;
        /// <summary>batchCreate rejects items with these file names.</summary>
        public HashSet<string> RejectFileNames = [];
        /// <summary>Each refresh hands out a new refresh token and retires the old one (Google may rotate them).</summary>
        public bool RotateRefreshTokens;
        public double Latency;

        public IEnumerable<FileRec> VisibleFiles => Files.Values.Where(f => f.ByApp);
        public FileRec? FileNamed(string name) => Files.Values.FirstOrDefault(f => f.Name == name && !f.Trashed);
        public List<string> RefreshTokenList => RefreshTokens.Keys.ToList();
        public void RevokeAllRefreshTokens() => RefreshTokens.Clear();

        // Seeding the user's own Google Drive (files Cirrus didn't create).
        public string AddUserFolder(string name, string parent = RootID, Dictionary<string, string>? properties = null)
        {
            var id = NewID("d");
            Files[id] = new FileRec { Id = id, Name = name, MimeType = GoogleDrive.FolderMime, Parents = [parent], Properties = properties ?? [] };
            return id;
        }
        public string AddUserFile(string name, byte[] data, string parent = RootID, DateTimeOffset? modified = null, bool canDownload = true)
        {
            var id = NewID("u");
            Files[id] = new FileRec
            {
                Id = id, Name = name, MimeType = GoogleDrive.MimeType(name), Parents = [parent], Size = data.Length, Md5 = Md5(data),
                ModifiedTime = Iso(modified ?? DateTimeOffset.FromUnixTimeSeconds(1_700_000_000)), CanDownload = canDownload,
            };
            Blobs[id] = data;
            return id;
        }
        public string AddUserDoc(string name, string kind = "document", string parent = RootID, bool tooLarge = false, DateTimeOffset? modified = null)
        {
            var id = NewID("g");
            Files[id] = new FileRec
            {
                Id = id, Name = name, MimeType = "application/vnd.google-apps." + kind, Parents = [parent],
                ModifiedTime = Iso(modified ?? DateTimeOffset.FromUnixTimeSeconds(1_700_000_000)), ExportTooLarge = tooLarge,
            };
            return id;
        }
        /// <summary>Simulates editing a file in Google Drive.</summary>
        public void ChangeUserFile(string id, byte[] data)
        {
            Blobs[id] = data;
            Files[id].Size = data.Length;
            Files[id].Md5 = Md5(data);
            Files[id].ModifiedTime = Iso(DateTimeOffset.UtcNow);
        }
        /// <summary>A Drive shortcut to another file or folder.</summary>
        public string AddUserShortcut(string name, string target, string parent = RootID, DateTimeOffset? modified = null)
        {
            var id = NewID("s");
            Files[id] = new FileRec
            {
                Id = id, Name = name, MimeType = ShortcutMime, Parents = [parent], ShortcutTarget = target,
                ModifiedTime = Iso(modified ?? DateTimeOffset.FromUnixTimeSeconds(1_700_000_000)),
            };
            return id;
        }
        /// <summary>In the trash itself, or inside a folder that is (as Google reports <c>trashed</c>).</summary>
        public bool IsTrashed(string id)
        {
            var seen = new HashSet<string>();
            var cur = Files.GetValueOrDefault(id);
            while (cur is not null)
            {
                if (cur.Trashed) return true;
                if (cur.Parents.Count == 0 || !seen.Add(cur.Parents[0])) return false;
                cur = Files.GetValueOrDefault(cur.Parents[0]);
            }
            return false;
        }
        /// <summary>Whether <paramref name="id"/> is <paramref name="ancestor"/> or somewhere inside it.</summary>
        public bool IsInside(string id, string ancestor)
        {
            var seen = new HashSet<string>();
            string? cur = id;
            while (cur is not null && seen.Add(cur))
            {
                if (cur == ancestor) return true;
                cur = Files.GetValueOrDefault(cur)?.Parents.FirstOrDefault();
            }
            return false;
        }
    }

    readonly object _lock = new();
    State _state = new();
    string? _persistPath;

    public static readonly HashSet<string> Hosts = ["oauth2.googleapis.com", "accounts.google.com", "www.googleapis.com", "photoslibrary.googleapis.com",
        "docs.google.com", "photospicker.googleapis.com", "lh3.googleusercontent.com"];

    public FakeGoogle(State? s = null) { if (s is not null) _state = s; }

    /// <summary>The live state (read it when no request is in flight; change it through <see cref="Update"/>).</summary>
    public State S { get { lock (_lock) return _state; } }
    public void Reset(State? s = null) { lock (_lock) _state = s ?? new State(); }
    public void Update(Action<State> f) { lock (_lock) f(_state); }

    /// <summary>Demo mode: a persistent fake account with its own Drive files (readable only with drive.readonly) and a few photos to pick.</summary>
    public void StartDemo(string dir)
    {
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, "google-state-v2.json");
        lock (_lock)
        {
            _persistPath = path;
            var s = new State { Latency = 0.01 };
            try { if (File.Exists(path) && JsonSerializer.Deserialize<Saved>(File.ReadAllBytes(path)) is { } saved) saved.Restore(s); } catch { }
            if (!s.Files.Values.Any(f => !f.ByApp))
            {
                s.AddUserFile("Résumé.pdf", Encoding.UTF8.GetBytes("%PDF-1.4 demo résumé\n" + new string('x', 18_000)));
                s.AddUserFile("Notes.txt", Encoding.UTF8.GetBytes("Things to move off Google.\n"));
                var trip = s.AddUserFolder("Lisbon Trip");
                s.AddUserFile("Itinerary.pdf", Encoding.UTF8.GetBytes("%PDF-1.4 itinerary\n" + new string('y', 42_000)), trip);
                s.AddUserFile("Packing list.txt", Encoding.UTF8.GetBytes("Passport\nCharger\n"), trip);
                s.AddUserDoc("Meeting notes");
                s.AddUserDoc("Budget 2026", "spreadsheet");
                s.AddUserDoc("Pitch deck", "presentation", trip);
                s.AddUserDoc("RSVP", "form");
                // Shared with the user but not in My Drive: not part of the copy.
                s.AddUserFile("Someone else’s file.pdf", Encoding.UTF8.GetBytes("%PDF shared"), "shared-folder-elsewhere");
            }
            if (s.PickerLibrary.Count == 0)
                for (int i = 0; i < 4; i++)
                    s.PickerLibrary.Add(new PickerPhoto($"pk{i}", $"PXL_2025080{i}_120000.png", "image/png", DemoArt.Png(900, 600, i / 4.0 + 0.05, $"Picked {i + 1}"),
                        DateTimeOffset.FromUnixTimeSeconds(1_754_000_000 + i * 86_400L), false));
            _state = s;
        }
    }

    // MARK: Google Drive demo account (IFakeCloud)

    /// <summary>The demo Google Drive account's id in demo mode.</summary>
    public const string DriveDemoAccountID = "cloud:googleDrive:demo";
    /// <summary>The demo account's long-lived sign-in (the fake knows it; no browser round trip).</summary>
    public const string DriveDemoRefreshToken = "1//fake-drive-demo-refresh";
    bool _driveDemo;

    /// <summary>
    /// A fake Google account seeded as demo mode's Google Drive (Alex Morgan, alex@example.com): folders, a Doc, a Sheet,
    /// pictures, a PDF, shortcuts, a Form and something in the trash. A separate instance from the migration demo's
    /// (<see cref="StartDemo"/>), so neither disturbs the other. Hand it to <see cref="FakeCloudRouter"/>; its
    /// <see cref="DemoAccounts"/> then lists the account. With <paramref name="dir"/>, changes are kept across launches;
    /// without, they last for this run.
    /// </summary>
    public static FakeGoogle DriveDemo(string? dir = null, double latency = 0.02)
    {
        var g = new FakeGoogle();
        g.StartDriveDemo(dir, latency);
        return g;
    }

    /// <summary>Seeds this instance as the demo Google Drive account (see <see cref="DriveDemo"/>).</summary>
    public void StartDriveDemo(string? dir = null, double latency = 0.02)
    {
        string? path = null;
        if (dir is not null)
        {
            Directory.CreateDirectory(dir);
            path = Path.Combine(dir, "google-drive-demo-v1.json");
        }
        lock (_lock)
        {
            var s = new State
            {
                Latency = latency, UserID = "demo-drive-user", Email = "alex@example.com", Name = "Alex Morgan", Usage = 3_400_000_000,
                GrantedScopes = [GoogleScopes.Drive],
            };
            try { if (path is not null && File.Exists(path) && JsonSerializer.Deserialize<Saved>(File.ReadAllBytes(path)) is { } saved) saved.Restore(s); } catch { }
            if (s.Files.Count == 0) SeedDriveDemo(s);
            s.RefreshTokens[DriveDemoRefreshToken] = [GoogleScopes.Drive];
            _state = s;
            _persistPath = path;
            _driveDemo = true;
        }
    }

    static void SeedDriveDemo(State s)
    {
        static DateTimeOffset Day(double n) => DateTimeOffset.FromUnixTimeSeconds(1_760_000_000 + (long)(n * 86_400));
        var documents = s.AddUserFolder("Documents");
        var photos = s.AddUserFolder("Photos");
        var projects = s.AddUserFolder("Projects");
        var website = s.AddUserFolder("Website refresh", projects);
        s.AddUserFile("Welcome.txt", Encoding.UTF8.GetBytes("Welcome to the Google Drive demo.\nEverything here lives in a pretend account.\n"), modified: Day(1));
        s.AddUserDoc("Project plan", parent: projects, modified: Day(12));
        var budget = s.AddUserDoc("Budget 2026", "spreadsheet", documents, modified: Day(20));
        s.AddUserFile("Quarterly report.pdf", DemoPdf("Quarterly Report", ["Revenue up 12%", "Two new regions", "Hiring plan"]), documents, Day(18));
        string[] scenes = ["Harbor at dawn", "Mountain trail", "City lights"];
        for (int i = 0; i < scenes.Length; i++)
            s.AddUserFile(scenes[i] + ".png", DemoArt.Png(960, 640, 0.1 * i + 0.05, scenes[i]), photos, Day(5 + i));
        s.AddUserFile("Notes.md", Encoding.UTF8.GetBytes("# Website refresh\n- New colors\n- Faster pages\n"), website, Day(22));
        s.AddUserShortcut("Photos", photos, website, Day(23));
        s.AddUserShortcut("Budget 2026", budget, projects, Day(21));
        s.AddUserDoc("Team survey", "form", modified: Day(15));
        var old = s.AddUserFile("Old draft.txt", Encoding.UTF8.GetBytes("An earlier draft.\n"), modified: Day(2));
        s.Files[old].Trashed = true;
        foreach (var f in s.Files.Values)
        {
            f.ModifiedTime ??= Iso(Day(0));
            f.CreatedTime = f.ModifiedTime;
        }
    }

    /// <summary>A small one-page PDF with a title and a few lines (Helvetica).</summary>
    public static byte[] DemoPdf(string title, IReadOnlyList<string> lines)
    {
        static string Esc(string t) => t.Replace("\\", "\\\\").Replace("(", "\\(").Replace(")", "\\)");
        var text = new StringBuilder($"BT /F1 24 Tf 72 720 Td ({Esc(title)}) Tj /F1 14 Tf");
        foreach (var l in lines) text.Append($" 0 -32 Td ({Esc(l)}) Tj");
        text.Append(" ET");
        var content = text.ToString();
        string[] objects =
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            $"<< /Length {content.Length} >>\nstream\n{content}\nendstream",
        ];
        var pdf = new StringBuilder("%PDF-1.4\n");
        var offsets = new List<int>();
        for (int i = 0; i < objects.Length; i++)
        {
            offsets.Add(pdf.Length);
            pdf.Append($"{i + 1} 0 obj\n{objects[i]}\nendobj\n");
        }
        var xref = pdf.Length;
        pdf.Append($"xref\n0 {objects.Length + 1}\n0000000000 65535 f \n");
        foreach (var o in offsets) pdf.Append(o.ToString("D10", CultureInfo.InvariantCulture)).Append(" 00000 n \n");
        pdf.Append($"trailer\n<< /Size {objects.Length + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n");
        return Encoding.ASCII.GetBytes(pdf.ToString());
    }

    /// <summary>Google's hosts (OAuth, Drive, Docs export links, thumbnails, Photos).</summary>
    public bool Handles(Uri uri) => Hosts.Contains(uri.Host);

    /// <summary>The demo Google Drive account, once <see cref="StartDriveDemo"/> has seeded this instance (otherwise none).</summary>
    public IReadOnlyList<CloudConnection> DemoAccounts()
    {
        lock (_lock)
        {
            if (!_driveDemo) return [];
            var record = new CloudAccountRecord(CloudProvider.GoogleDrive, _state.Email, id: DriveDemoAccountID) { Added = DateTimeOffset.FromUnixTimeSeconds(1_760_000_000) };
            return [new CloudConnection(record, new CloudSecret { RefreshToken = DriveDemoRefreshToken, ClientID = _state.ClientID, ClientSecret = _state.ClientSecret })];
        }
    }

    sealed class Saved
    {
        public Dictionary<string, FileRec> Files { get; set; } = [];
        public Dictionary<string, byte[]> Blobs { get; set; } = [];
        public Dictionary<string, MediaItem> Media { get; set; } = [];
        public Dictionary<string, AlbumRec> Albums { get; set; } = [];
        public long Usage { get; set; }
        public Dictionary<string, List<string>> Refresh { get; set; } = [];
        public Dictionary<string, Blob> UploadTokens { get; set; } = [];
        public Dictionary<string, string> MediaByHash { get; set; } = [];
        public void Restore(State s)
        {
            s.Files = Files; s.Blobs = Blobs; s.Media = Media; s.Albums = Albums; s.Usage = Usage; s.RefreshTokens = Refresh;
            s.UploadTokens = UploadTokens; s.MediaByHash = MediaByHash;
        }
    }

    void Persist()
    {
        if (_persistPath is null) return;
        var s = _state;
        var saved = new Saved { Files = s.Files, Blobs = s.Blobs, Media = s.Media, Albums = s.Albums, Usage = s.Usage, Refresh = s.RefreshTokens, UploadTokens = s.UploadTokens, MediaByHash = s.MediaByHash };
        try { var tmp = _persistPath + ".tmp"; File.WriteAllBytes(tmp, JsonSerializer.SerializeToUtf8Bytes(saved)); File.Move(tmp, _persistPath, true); } catch { }
    }

    static Dictionary<string, string> QueryOf(Uri u)
    {
        var q = new Dictionary<string, string>(StringComparer.Ordinal);
        var s = u.Query.TrimStart('?');
        foreach (var pair in s.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            // Strict like URLComponents: "+" stays a plus, so a client that forgets to encode it is caught.
            var kv = pair.Split('=', 2);
            q[Uri.UnescapeDataString(kv[0])] = kv.Length > 1 ? Uri.UnescapeDataString(kv[1]) : "";
        }
        return q;
    }

    /// <summary>Plays the browser: "approves" the consent page and calls the app's loopback redirect (a real socket, not this handler).</summary>
    public async Task ApproveAsync(Uri url, bool deny = false)
    {
        var q = QueryOf(url);
        if (!q.TryGetValue("redirect_uri", out var redirect)) return;
        var items = new List<(string, string)> { ("state", q.GetValueOrDefault("state") ?? "") };
        bool known;
        lock (_lock) known = q.GetValueOrDefault("client_id") == _state.ClientID;
        if (deny || !known || q.GetValueOrDefault("code_challenge_method") != "S256")
            items.Add(("error", known ? "access_denied" : "invalid_client"));
        else
        {
            var code = "4/fake-" + Guid.NewGuid();
            var asked = (q.GetValueOrDefault("scope") ?? "").Split(' ', StringSplitOptions.RemoveEmptyEntries);
            List<string> granted;
            lock (_lock)
            {
                granted = asked.Where(_state.GrantedScopes.Contains).ToList();
                _state.Codes[code] = new Code(q.GetValueOrDefault("code_challenge") ?? "", redirect, granted);
            }
            items.Add(("code", code));
            items.Add(("scope", string.Join(' ', granted)));
        }
        var target = redirect + "?" + string.Join('&', items.Select(p => Uri.EscapeDataString(p.Item1) + "=" + Uri.EscapeDataString(p.Item2)));
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        try { using var _ = await http.GetAsync(target).ConfigureAwait(false); } catch { }
    }

    /// <summary>Plays the user in Google Photos' picker: picks <paramref name="count"/> photos (all by default) for that session.</summary>
    public void Pick(Uri pickerURL, int? count = null)
    {
        var parts = pickerURL.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        var i = Array.IndexOf(parts, "picker");
        if (i < 0 || parts.Length <= i + 1) return;
        var id = parts[i + 1];
        Update(s =>
        {
            if (!s.PickerSessions.TryGetValue(id, out var ps)) return;
            ps.Items = s.PickerLibrary.Take(count ?? s.PickerLibrary.Count).Select(p => p.Id).ToList();
            ps.Set = true;
        });
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
        if (!headers.ContainsKey("Content-Type")) headers["Content-Type"] = "application/json; charset=UTF-8";
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

    static Outcome Json(int status, JsonNode j, Dictionary<string, string>? headers = null) => new(status, headers ?? [], Encoding.UTF8.GetBytes(j.ToJsonString()));
    static Outcome Error(int status, string message, string? reason = null, string? statusText = null)
    {
        var e = new JsonObject { ["code"] = status, ["message"] = message };
        if (reason is not null) e["errors"] = new JsonArray(new JsonObject { ["domain"] = "global", ["reason"] = reason, ["message"] = message });
        if (statusText is not null) e["status"] = statusText;
        return Json(status, new JsonObject { ["error"] = e });
    }
    /// <summary>Drive's md5Checksum: lowercase hex.</summary>
    public static string Md5(byte[] d) => Convert.ToHexStringLower(MD5.HashData(d));
    public static string NewID(string prefix) => prefix + Guid.NewGuid().ToString("N")[..20];
    public static string Iso(DateTimeOffset d) => d.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
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
    static readonly Dictionary<string, string> ExportExts = new()
    {
        ["docx"] = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        ["xlsx"] = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        ["pptx"] = "application/vnd.openxmlformats-officedocument.presentationml.presentation", ["pdf"] = "application/pdf",
    };
    static List<string> Exportable(FileRec f) => f.MimeType switch
    {
        "application/vnd.google-apps.document" => [ExportExts["docx"], ExportExts["pdf"]],
        "application/vnd.google-apps.spreadsheet" => [ExportExts["xlsx"], ExportExts["pdf"]],
        "application/vnd.google-apps.presentation" => [ExportExts["pptx"], ExportExts["pdf"]],
        "application/vnd.google-apps.drawing" or "application/vnd.google-apps.jam" => [ExportExts["pdf"]],
        "application/vnd.google-apps.script" => ["application/vnd.google-apps.script+json"],
        _ => [],
    };
    static byte[] ExportBytes(FileRec f, string mime)
    {
        var head = Encoding.UTF8.GetBytes($"FAKE-EXPORT {mime} of {f.Name} [{f.ModifiedTime}]\n");
        return [.. head, .. Enumerable.Repeat((byte)0x20, 3000)];
    }
    JsonObject FileJson(FileRec f)
    {
        var props = new JsonObject();
        foreach (var (k, v) in f.AppProperties) props[k] = v;
        var pub = new JsonObject();
        foreach (var (k, v) in f.Properties) pub[k] = v;
        // `trashed` is true inside a trashed folder too; `explicitlyTrashed` only for what was trashed itself.
        var o = new JsonObject
        {
            ["kind"] = "drive#file", ["id"] = f.Id, ["name"] = f.Name, ["mimeType"] = f.MimeType, ["parents"] = Jx.Strings(f.Parents),
            ["trashed"] = _state.IsTrashed(f.Id), ["explicitlyTrashed"] = f.Trashed, ["appProperties"] = props, ["properties"] = pub,
            ["capabilities"] = new JsonObject { ["canDownload"] = f.CanDownload, ["canRename"] = true, ["canTrash"] = true }, ["hasThumbnail"] = f.HasThumbnail,
        };
        if (f.MimeType != GoogleDrive.FolderMime && !f.IsNative) o["size"] = f.Size.ToString(CultureInfo.InvariantCulture);
        if (f.Md5 is not null) o["md5Checksum"] = f.Md5;
        if (f.ModifiedTime is not null) o["modifiedTime"] = f.ModifiedTime;
        if ((f.CreatedTime ?? f.ModifiedTime) is { } created) o["createdTime"] = created;
        if (f.HasThumbnail) o["thumbnailLink"] = $"https://lh3.googleusercontent.com/drive-storage/{f.Id}=s220";
        if (f.ShortcutTarget is { } t)
            o["shortcutDetails"] = new JsonObject { ["targetId"] = t, ["targetMimeType"] = _state.Files.GetValueOrDefault(t)?.MimeType ?? "application/octet-stream" };
        var ex = Exportable(f);
        if (ex.Count > 0)
        {
            var links = new JsonObject();
            foreach (var m in ex) links[m] = $"https://docs.google.com/feeds/download/export?id={f.Id}&mime={Uri.EscapeDataString(m)}";
            o["exportLinks"] = links;
        }
        return o;
    }

    (DateTimeOffset Expires, List<string> Scopes)? Bearer(HttpRequestMessage r)
    {
        if (r.Headers.Authorization is not { Scheme: "Bearer", Parameter: { } t }) return null;
        return _state.AccessTokens.TryGetValue(t, out var v) ? v : null;
    }
    /// <summary>Bearer check: 401 for unknown or expired access tokens.</summary>
    bool Authorized(HttpRequestMessage r) => Bearer(r) is { } b && b.Expires > DateTimeOffset.UtcNow;
    /// <summary>Scopes travel with each access token, as they do at Google.</summary>
    bool HasScope(string scope, HttpRequestMessage r) => Bearer(r)?.Scopes.Contains(scope) ?? false;
    static Outcome Insufficient() => Error(403, "Request had insufficient authentication scopes.", "insufficientPermissions", "PERMISSION_DENIED");

    // MARK: Routing

    Outcome Handle(HttpRequestMessage r, byte[] body)
    {
        var url = r.RequestUri!;
        var host = url.Host;
        var method = r.Method.Method;
        _state.Calls.Add($"{method} {host}{url.AbsolutePath}");
        if (!Hosts.Contains(host))
        {
            if (r.Headers.Authorization is not null) _state.TokensSentElsewhere.Add(host);
            return Error(404, "Not a Google host");
        }
        if (host == "oauth2.googleapis.com") return OAuth(url.AbsolutePath, body);
        if (!Authorized(r)) return Error(401, "Request had invalid authentication credentials.", "authError", "UNAUTHENTICATED");
        if (_state.RateLimitNext > 0)
        {
            _state.RateLimitNext--;
            return Json(429, new JsonObject { ["error"] = new JsonObject { ["code"] = 429, ["message"] = "Rate Limit Exceeded", ["errors"] = new JsonArray(new JsonObject { ["reason"] = "rateLimitExceeded" }) } },
                new() { ["Retry-After"] = "0" });
        }
        Outcome output;
        switch (host)
        {
            case "photoslibrary.googleapis.com":
                if (!HasScope(GoogleScopes.PhotosAppend, r)) return Insufficient();
                if (_state.PhotosRequestsLeft is { } left)
                {
                    if (left <= 0)
                        return Error(429, "Quota exceeded for quota metric 'All requests' and limit 'All requests per day' of service 'photoslibrary.googleapis.com'.", statusText: "RESOURCE_EXHAUSTED");
                    _state.PhotosRequestsLeft = left - 1;
                }
                output = Photos(method, url, r, body);
                break;
            case "photospicker.googleapis.com":
                if (!HasScope(GoogleScopes.PhotosPicker, r)) return Insufficient();
                output = Picker(method, url);
                break;
            case "lh3.googleusercontent.com" when url.AbsolutePath.StartsWith("/drive-storage/", StringComparison.Ordinal):
                return DriveThumbnail(url, r);
            case "lh3.googleusercontent.com":
            {
                if (!HasScope(GoogleScopes.PhotosPicker, r)) return Error(403, "Forbidden");
                var last = url.AbsolutePath.Split('/').Last();
                var id = last.Split('=')[0];
                var p = _state.PickerLibrary.FirstOrDefault(x => x.Id == id);
                return p is null ? Error(404, "Not found") : new Outcome(200, new() { ["Content-Type"] = p.Mime }, p.Data);
            }
            case "docs.google.com":
            {
                // exportLinks: works past files.export's 10 MB cap.
                if (!HasScope(GoogleScopes.DriveReadonly, r) && !HasScope(GoogleScopes.Drive, r)) return Error(403, "Forbidden");
                var q = QueryOf(url);
                if (!q.TryGetValue("id", out var id) || !_state.Files.TryGetValue(id, out var f) || !q.TryGetValue("mime", out var mime) || !Exportable(f).Contains(mime))
                    return Error(404, "Not found");
                _state.ExportLinkUses++;
                return new Outcome(200, new() { ["Content-Type"] = mime }, [.. ExportBytes(f, mime), .. Enumerable.Repeat((byte)0x2E, 120_000)]);
            }
            default:
                if (!HasScope(GoogleScopes.DriveFile, r) && !HasScope(GoogleScopes.DriveReadonly, r) && !HasScope(GoogleScopes.Drive, r))
                    return Error(403, "Insufficient Permission: Request had insufficient authentication scopes.", "insufficientPermissions");
                output = Drive(method, url, r, body);
                break;
        }
        if (method != "GET") Persist();
        return output;
    }

    Outcome OAuth(string path, byte[] body)
    {
        var f = Form(body);
        static Outcome Bad(string e, string d) => Json(400, new JsonObject { ["error"] = e, ["error_description"] = d });
        if (path == "/revoke")
        {
            if (f.TryGetValue("token", out var t)) { _state.RefreshTokens.Remove(t); _state.AccessTokens.Remove(t); }
            Persist();
            return new Outcome(200, [], []);
        }
        if (path != "/token") return Bad("invalid_request", "Unknown endpoint");
        if (f.GetValueOrDefault("client_id") != _state.ClientID) return Json(401, new JsonObject { ["error"] = "invalid_client", ["error_description"] = "The OAuth client was not found." });
        if (_state.ClientSecret is { } secret)
        {
            if (!f.TryGetValue("client_secret", out var given)) return Bad("invalid_request", "client_secret is missing.");
            if (given != secret) return Json(401, new JsonObject { ["error"] = "invalid_client", ["error_description"] = "Unauthorized" });
        }
        var access = "ya29.fake-" + Guid.NewGuid();
        switch (f.GetValueOrDefault("grant_type"))
        {
            case "authorization_code":
            {
                if (!f.TryGetValue("code", out var code) || !_state.Codes.Remove(code, out var c)) return Bad("invalid_grant", "Malformed auth code.");
                if (f.GetValueOrDefault("redirect_uri") != c.Redirect) return Bad("redirect_uri_mismatch", "Bad Request");
                if (!f.TryGetValue("code_verifier", out var v) || v.Length < 43 || v.Length > 128 || new Pkce(v).Challenge != c.Challenge)
                    return Bad("invalid_grant", "Invalid code verifier.");
                var refresh = "1//fake-refresh-" + Guid.NewGuid();
                _state.RefreshTokens[refresh] = c.Scopes;
                _state.AccessTokens[access] = (DateTimeOffset.UtcNow.AddSeconds(_state.AccessTTL), c.Scopes);
                Persist();
                return Json(200, new JsonObject
                {
                    ["access_token"] = access, ["expires_in"] = _state.AccessTTL, ["refresh_token"] = refresh, ["scope"] = string.Join(' ', c.Scopes), ["token_type"] = "Bearer",
                });
            }
            case "refresh_token":
            {
                if (!f.TryGetValue("refresh_token", out var t) || !_state.RefreshTokens.TryGetValue(t, out var scopes)) return Bad("invalid_grant", "Token has been expired or revoked.");
                _state.Refreshes++;
                _state.AccessTokens[access] = (DateTimeOffset.UtcNow.AddSeconds(_state.AccessTTL), scopes);
                var reply = new JsonObject { ["access_token"] = access, ["expires_in"] = _state.AccessTTL, ["scope"] = string.Join(' ', scopes), ["token_type"] = "Bearer" };
                if (_state.RotateRefreshTokens)
                {
                    var next = "1//fake-refresh-" + Guid.NewGuid();
                    _state.RefreshTokens[next] = scopes;
                    _state.RefreshTokens.Remove(t);
                    reply["refresh_token"] = next;
                    Persist();
                }
                return Json(200, reply);
            }
            default:
                return Bad("unsupported_grant_type", "Invalid grant_type");
        }
    }

    // MARK: Drive

    static string Resolve(string id) => id == "root" ? RootID : id;

    /// <summary>A folder new items may go into: drive.file only into folders Cirrus made; the full drive scope into any.</summary>
    bool FolderOK(string id, bool full = false)
    {
        id = Resolve(id);
        return id == RootID || (_state.Files.TryGetValue(id, out var f) && f.MimeType == GoogleDrive.FolderMime && (f.ByApp || full) && !_state.IsTrashed(f.Id));
    }

    // MARK: Drive search queries (`q`)

    abstract record QToken { public sealed record Str(string Value) : QToken; public sealed record Word(string Value) : QToken; }

    /// <summary>
    /// Splits a query into words and string literals. Inside quotes only \' and \\ are valid escapes; anything else (a
    /// stray quote, a lone backslash) makes the query invalid, as at Google.
    /// </summary>
    static List<QToken>? Tokenize(string s)
    {
        var output = new List<QToken>();
        int i = 0;
        while (i < s.Length)
        {
            var c = s[i];
            if (c == ' ') { i++; continue; }
            if (c == '\'')
            {
                var lit = new StringBuilder();
                var closed = false;
                i++;
                while (i < s.Length)
                {
                    var d = s[i];
                    if (d == '\\')
                    {
                        if (i + 1 >= s.Length || (s[i + 1] != '\'' && s[i + 1] != '\\')) return null;
                        lit.Append(s[i + 1]);
                        i += 2;
                        continue;
                    }
                    i++;
                    if (d == '\'') { closed = true; break; }
                    lit.Append(d);
                }
                if (!closed) return null;
                output.Add(new QToken.Str(lit.ToString()));
                continue;
            }
            if (c == '=') { output.Add(new QToken.Word("=")); i++; continue; }
            if (c == '!')
            {
                if (i + 1 >= s.Length || s[i + 1] != '=') return null;
                output.Add(new QToken.Word("!="));
                i += 2;
                continue;
            }
            var w = new StringBuilder();
            while (i < s.Length && !" =!'".Contains(s[i])) w.Append(s[i++]);
            output.Add(new QToken.Word(w.ToString()));
        }
        return output;
    }

    /// <summary>
    /// The <c>q</c> subset Cirrus uses, joined with <c>and</c>: <c>'&lt;id&gt;' in parents</c>, <c>trashed = true|false</c>,
    /// <c>name = | != | contains '&lt;text&gt;'</c>, <c>mimeType = | != '&lt;type&gt;'</c>. null = invalid (Google answers 400).
    /// </summary>
    Func<FileRec, bool>? Filter(string qs)
    {
        if (Tokenize(qs) is not { } toks) return null;
        if (toks.Count == 0) return _ => true;
        var clauses = new List<List<QToken>> { new() };
        foreach (var t in toks)
        {
            if (t is QToken.Word { Value: "and" }) clauses.Add([]);
            else clauses[^1].Add(t);
        }
        var preds = new List<Func<FileRec, bool>>();
        foreach (var c in clauses)
        {
            if (c.Count != 3) return null;
            switch (c[0], c[1], c[2])
            {
                case (QToken.Str id, QToken.Word { Value: "in" }, QToken.Word { Value: "parents" }):
                    var p = Resolve(id.Value);
                    preds.Add(f => f.Parents.Contains(p));
                    break;
                case (QToken.Word { Value: "trashed" }, QToken.Word { Value: "=" or "!=" } op, QToken.Word { Value: "true" or "false" } v):
                    var want = (v.Value == "true") == (op.Value == "=");
                    preds.Add(f => _state.IsTrashed(f.Id) == want);
                    break;
                case (QToken.Word { Value: "name" }, QToken.Word { Value: "=" }, QToken.Str n): preds.Add(f => f.Name == n.Value); break;
                case (QToken.Word { Value: "name" }, QToken.Word { Value: "!=" }, QToken.Str n): preds.Add(f => f.Name != n.Value); break;
                case (QToken.Word { Value: "name" }, QToken.Word { Value: "contains" }, QToken.Str n):
                    preds.Add(f => f.Name.Contains(n.Value, StringComparison.CurrentCultureIgnoreCase)); break;
                case (QToken.Word { Value: "mimeType" }, QToken.Word { Value: "=" }, QToken.Str m): preds.Add(f => f.MimeType == m.Value); break;
                case (QToken.Word { Value: "mimeType" }, QToken.Word { Value: "!=" }, QToken.Str m): preds.Add(f => f.MimeType != m.Value); break;
                default: return null;
            }
        }
        return f => preds.All(p => p(f));
    }

    /// <summary>Removes a file or folder and everything inside it (files.delete on a folder).</summary>
    void DeleteTree(string id)
    {
        foreach (var d in _state.Files.Keys.Where(k => _state.IsInside(k, id)).ToList())
        {
            if (_state.Files[d] is { } f && f.MimeType != GoogleDrive.FolderMime && !f.IsNative) _state.Usage = Math.Max(0, _state.Usage - f.Size);
            _state.Files.Remove(d);
            _state.Blobs.Remove(d);
        }
    }

    /// <summary><c>thumbnailLink</c> targets: https://lh3.googleusercontent.com/drive-storage/&lt;id&gt;=s&lt;px&gt;</summary>
    Outcome DriveThumbnail(Uri url, HttpRequestMessage r)
    {
        var full = HasScope(GoogleScopes.Drive, r) || HasScope(GoogleScopes.DriveReadonly, r);
        if (!full && !HasScope(GoogleScopes.DriveFile, r)) return Error(403, "Forbidden");
        var parts = url.AbsolutePath.Split('/').Last().Split('=');
        var size = parts.Length > 1 && parts[1].StartsWith('s') && int.TryParse(parts[1][1..], NumberStyles.Integer, CultureInfo.InvariantCulture, out var px) ? px : 220;
        if (!_state.Files.TryGetValue(parts[0], out var f) || !(f.ByApp || full) || !f.HasThumbnail) return Error(404, "Not found");
        _state.ThumbnailSizes.Add(size);
        if (f.MimeType.StartsWith("image/", StringComparison.Ordinal) && _state.Blobs.TryGetValue(f.Id, out var d) && d.Length > 0)
            return new Outcome(200, new() { ["Content-Type"] = f.MimeType }, d);
        var side = Math.Clamp(size, 16, 1600);
        var hue = (f.Id.Aggregate(7, (h, ch) => (h * 31 + ch) & 0x7FFFFFFF) % 100) / 100.0;
        return new Outcome(200, new() { ["Content-Type"] = "image/png" }, DemoArt.Png(side, Math.Max(1, side * 3 / 4), hue, Path.GetFileNameWithoutExtension(f.Name)));
    }

    static Dictionary<string, string> Props(JsonNode? n) =>
        n is JsonObject o ? o.Where(kv => kv.Value is JsonValue).ToDictionary(kv => kv.Key, kv => kv.Value!.ToString()) : [];

    Outcome Drive(string method, Uri url, HttpRequestMessage r, byte[] body)
    {
        var path = url.AbsolutePath;
        var q = QueryOf(url);
        // drive.file: only what Cirrus created. drive.readonly: read everything. drive: read and change everything.
        var full = HasScope(GoogleScopes.Drive, r);
        var readAll = HasScope(GoogleScopes.DriveReadonly, r) || full;
        var canWrite = HasScope(GoogleScopes.DriveFile, r) || full;
        bool Visible(FileRec f) => f.ByApp || readAll;
        bool Editable(FileRec f) => canWrite && (f.ByApp || full);
        if (path == "/drive/v3/about")
        {
            if (!q.ContainsKey("fields")) return Error(400, "The 'fields' parameter is required for this method.", "required");
            var quota = new JsonObject
            {
                ["usage"] = _state.Usage.ToString(CultureInfo.InvariantCulture), ["usageInDrive"] = _state.Files.Values.Sum(f => f.Size).ToString(CultureInfo.InvariantCulture), ["usageInDriveTrash"] = "0",
            };
            if (_state.Limit is { } l) quota["limit"] = l.ToString(CultureInfo.InvariantCulture);
            return Json(200, new JsonObject
            {
                ["user"] = new JsonObject { ["permissionId"] = _state.UserID, ["emailAddress"] = _state.Email, ["displayName"] = _state.Name }, ["storageQuota"] = quota,
            });
        }
        if (path == "/drive/v3/files" && method == "GET")
        {
            if (Filter(q.GetValueOrDefault("q") ?? "") is not { } matches) return Error(400, "Invalid Value", "invalid");
            var list = _state.Files.Values.Where(Visible).Where(matches).ToList();   // drive.file: only what Cirrus created
            list = list.OrderBy(f => f.Id, StringComparer.Ordinal).ToList();
            var size = int.TryParse(q.GetValueOrDefault("pageSize"), out var ps) ? ps : 100;
            var start = int.TryParse(q.GetValueOrDefault("pageToken"), out var st) ? st : 0;
            var page = list.Skip(start).Take(Math.Min(size, 1000)).ToList();
            var output = new JsonObject { ["files"] = new JsonArray(page.Select(f => (JsonNode)FileJson(f)).ToArray()) };
            if (start + page.Count < list.Count) output["nextPageToken"] = (start + page.Count).ToString(CultureInfo.InvariantCulture);
            return Json(200, output);
        }
        if (path == "/drive/v3/files" && method == "POST")
        {
            if (!canWrite) return Insufficient();
            var j = JsonNode.Parse(body) as JsonObject ?? [];
            var parents = (j["parents"] as JsonArray ?? []).Select(x => Resolve(x!.ToString())).ToList();
            if (parents.Count != 1 || !FolderOK(parents[0], full)) return Error(404, "File not found: parent.", "notFound");
            var f = new FileRec
            {
                Id = NewID("f"), Name = j["name"]?.ToString() ?? "Untitled", MimeType = j["mimeType"]?.ToString() ?? "application/octet-stream", Parents = parents,
                ModifiedTime = j["modifiedTime"]?.ToString(), AppProperties = Props(j["appProperties"]), Properties = Props(j["properties"]), ByApp = true,
                CreatedTime = Iso(DateTimeOffset.UtcNow),
            };
            _state.Files[f.Id] = f;
            return Json(200, FileJson(f));
        }
        if ((path == "/drive/v3/files/root" || path == "/drive/v3/files/" + RootID) && method == "GET")
            return Json(200, new JsonObject
            {
                ["id"] = RootID, ["name"] = "My Drive", ["mimeType"] = GoogleDrive.FolderMime, ["trashed"] = false, ["parents"] = new JsonArray(),
                ["capabilities"] = new JsonObject { ["canDownload"] = true, ["canRename"] = false, ["canTrash"] = false },
            });
        if (path.StartsWith("/drive/v3/files/", StringComparison.Ordinal) && path.EndsWith("/export", StringComparison.Ordinal) && method == "GET")
        {
            var id = path["/drive/v3/files/".Length..^"/export".Length];
            if (!_state.Files.TryGetValue(id, out var f) || !Visible(f)) return Error(404, $"File not found: {id}.", "notFound");
            if (!q.TryGetValue("mimeType", out var mime) || !Exportable(f).Contains(mime)) return Error(403, "Export only supports Docs Editors files.", "fileNotExportable");
            if (f.ExportTooLarge) return Error(400, "This file is too large to be exported.", "badRequest");
            return new Outcome(200, new() { ["Content-Type"] = mime }, ExportBytes(f, mime));
        }
        if (path.StartsWith("/drive/v3/files/", StringComparison.Ordinal))
        {
            var id = Resolve(Uri.UnescapeDataString(path["/drive/v3/files/".Length..]));
            if (!_state.Files.TryGetValue(id, out var f) || !Visible(f)) return Error(404, $"File not found: {id}.", "notFound");
            switch (method)
            {
                case "GET":
                {
                    if (q.GetValueOrDefault("alt") != "media") return Json(200, FileJson(f));
                    if (f.IsNative) return Error(403, "Only files with binary content can be downloaded. Use Export with Docs Editors files.", "fileNotDownloadable");
                    if (!f.CanDownload) return Error(403, "The user doesn't have permission to download this file.", "cannotDownloadFile");
                    var data = _state.Blobs.GetValueOrDefault(id) ?? new byte[f.Size];
                    if (H(r, "Range") is not { } range || !range.StartsWith("bytes=", StringComparison.Ordinal)) return new Outcome(200, new() { ["Content-Type"] = f.MimeType }, data);
                    _state.RangedGets++;
                    if (_state.DropDownloadAt == _state.RangedGets) return DropOutcome;
                    var ab = range[6..].Split('-').Select(s => int.TryParse(s, out var n) ? n : (int?)null).ToList();
                    if (ab.Count == 0 || ab[0] is not { } a || a >= data.Length) return Error(416, "Requested range not satisfiable");
                    var b = Math.Min(ab.Count > 1 && ab[1] is { } bb ? bb : data.Length - 1, data.Length - 1);
                    return new Outcome(206, new() { ["Content-Type"] = f.MimeType, ["Content-Range"] = $"bytes {a}-{b}/{data.Length}" }, data[a..(b + 1)]);
                }
                case "PATCH":
                {
                    if (!Editable(f)) return Insufficient();
                    var j = JsonNode.Parse(body) as JsonObject ?? [];
                    if (q.ContainsKey("addParents") || q.ContainsKey("removeParents"))
                    {
                        // Moving: parents not listed in removeParents stay; a file may have only one parent.
                        var parents = f.Parents.ToList();
                        foreach (var p in (q.GetValueOrDefault("removeParents") ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries).Select(Resolve)) parents.Remove(p);
                        foreach (var p in (q.GetValueOrDefault("addParents") ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries).Select(Resolve))
                        {
                            if (!FolderOK(p, full)) return Error(404, $"File not found: {p}.", "notFound");
                            if (f.MimeType == GoogleDrive.FolderMime && _state.IsInside(p, id))
                                return Error(403, "A folder can’t be moved into itself or one of its subfolders.", "invalidParent");
                            if (!parents.Contains(p)) parents.Add(p);
                        }
                        if (parents.Count > 1) return Error(403, "Increasing the number of parents is not allowed.", "cannotAddParent");
                        f.Parents = parents;
                    }
                    if (j["trashed"] is JsonValue tv && tv.TryGetValue(out bool t)) f.Trashed = t;
                    if (j["name"]?.ToString() is { } n) f.Name = n;
                    return Json(200, FileJson(f));
                }
                case "DELETE":
                    if (!Editable(f)) return Insufficient();
                    _state.PermanentDeletes++;
                    DeleteTree(id);
                    return new Outcome(204, [], []);
                default: return Error(405, "Method not allowed");
            }
        }
        if (path == "/upload/drive/v3/files")
        {
            if (!canWrite) return Insufficient();
            if (method == "POST" && q.GetValueOrDefault("uploadType") == "resumable")
            {
                var meta = JsonNode.Parse(body) as JsonObject ?? [];
                var parents = (meta["parents"] as JsonArray ?? []).Select(x => Resolve(x!.ToString())).ToList();
                if (parents.Count != 1 || !FolderOK(parents[0], full)) return Error(404, "File not found: parent.", "notFound");
                if (!long.TryParse(H(r, "X-Upload-Content-Length"), out var total)) return Error(400, "Cirrus always sends X-Upload-Content-Length", "badRequest");
                if (_state.Limit is { } l && _state.Usage + total > l) return Error(403, "The user's Drive storage quota has been exceeded.", "storageQuotaExceeded");
                var sid = NewID("u");
                meta["parents"] = Jx.Strings(parents);
                meta["x-content-type"] = H(r, "X-Upload-Content-Type");
                // Content is kept only for full-drive-scope uploads (Google Drive accounts read them back); the move's
                // uploads are never downloaded, and the migration demo's saved state stays small.
                _state.DriveSessions[sid] = new DriveSession { Meta = meta, Total = total, KeepData = full };
                _state.DriveSessionsStarted++;
                return new Outcome(200, new() { ["Location"] = $"https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id={sid}" }, []);
            }
            if (method == "PUT" && q.TryGetValue("upload_id", out var upid)) return DriveChunk(upid, r, body);
        }
        return Error(404, $"Not found: {method} {path}");
    }

    static Dictionary<string, string> RangeHeader(long n) => n > 0 ? new() { ["Range"] = $"bytes=0-{n - 1}" } : [];

    Outcome DriveChunk(string sid, HttpRequestMessage r, byte[] body)
    {
        if (!_state.DriveSessions.TryGetValue(sid, out var s)) return Error(404, "Upload session not found", "notFound");
        var cr = H(r, "Content-Range") ?? "";
        Outcome Finish()
        {
            if (s.FileID is { } id && _state.Files.TryGetValue(id, out var done)) return Json(200, FileJson(done));
            var name = s.Meta["name"]?.ToString() ?? "Untitled";
            var data = s.Data.ToArray();
            var f = new FileRec
            {
                Id = NewID("f"), Name = name, MimeType = s.Meta["x-content-type"]?.ToString() ?? GoogleDrive.MimeType(name),
                Parents = (s.Meta["parents"] as JsonArray ?? []).Select(x => x!.ToString()).ToList(), Size = s.Total, Md5 = Md5(data),
                ModifiedTime = s.Meta["modifiedTime"]?.ToString(), AppProperties = Props(s.Meta["appProperties"]), ByApp = true,
                CreatedTime = Iso(DateTimeOffset.UtcNow),
            };
            _state.Files[f.Id] = f;
            _state.Usage += s.Total;
            if (s.KeepData) _state.Blobs[f.Id] = data;
            s.FileID = f.Id;
            s.Data = new MemoryStream();
            return Json(200, FileJson(f));
        }
        if (cr.StartsWith("bytes */", StringComparison.Ordinal))
        {
            _state.StatusQueries++;
            if (s.FileID is not null || (s.Total == 0 && cr == "bytes */0")) return Finish();
            return new Outcome(308, RangeHeader(s.Data.Length), []);
        }
        // bytes a-b/total
        var spec = cr.StartsWith("bytes ", StringComparison.Ordinal) ? cr[6..] : "";
        var parts = spec.Split('/');
        var ab = parts[0].Split('-').Select(x => long.TryParse(x, out var n) ? n : (long?)null).ToList();
        if (parts.Length != 2 || ab.Count != 2 || ab[0] is not { } a || ab[1] is not { } b || !long.TryParse(parts[1], out var tot) || tot != s.Total)
            return Error(400, $"Invalid Content-Range: {cr}", "badContent");
        if (body.Length != b - a + 1) return Error(400, "Content-Range doesn’t match the body length", "badContent");
        if (b + 1 < s.Total && (b - a + 1) % 262_144 != 0) return Error(400, "Chunk size must be a multiple of 256 KiB", "badContent");
        _state.ChunkPuts++;
        var n = _state.ChunkPuts;
        if (_state.FailDriveChunksAfter is { } after && n > after) return Error(503, "Backend Error", "backendError");
        if (a > s.Data.Length) return new Outcome(308, RangeHeader(s.Data.Length), []);
        var chunk = body[(int)(s.Data.Length - a)..];
        if (_state.DropDriveChunk == n)
        {
            // Only part of the chunk arrived before the connection broke.
            var keep = chunk.Length / 2 / 262_144 * 262_144;
            s.Data.Write(chunk, 0, keep);
            return DropOutcome;
        }
        s.Data.Write(chunk);
        if (s.Data.Length >= s.Total) return Finish();
        return new Outcome(308, RangeHeader(s.Data.Length), []);
    }

    // MARK: Photos Picker

    static JsonObject PickerSessionJson(string id, PickerSession s)
    {
        var o = new JsonObject { ["id"] = id, ["pickerUri"] = $"https://photos.google.com/picker/{id}", ["mediaItemsSet"] = s.Set, ["expireTime"] = Iso(DateTimeOffset.UtcNow.AddHours(1)) };
        if (!s.Set) o["pollingConfig"] = new JsonObject { ["pollInterval"] = "0.05s", ["timeoutIn"] = "120s" };
        return o;
    }

    Outcome Picker(string method, Uri url)
    {
        var path = url.AbsolutePath;
        if (path == "/v1/sessions" && method == "POST")
        {
            var id = NewID("ps");
            _state.PickerSessions[id] = new PickerSession();
            return Json(200, PickerSessionJson(id, _state.PickerSessions[id]));
        }
        if (path.StartsWith("/v1/sessions/", StringComparison.Ordinal))
        {
            var id = path["/v1/sessions/".Length..];
            if (!_state.PickerSessions.TryGetValue(id, out var s)) return Error(404, "Session not found", statusText: "NOT_FOUND");
            if (method == "DELETE") { _state.PickerSessions.Remove(id); _state.PickerSessionsDeleted++; return Json(200, new JsonObject()); }
            return Json(200, PickerSessionJson(id, s));
        }
        if (path == "/v1/mediaItems" && method == "GET")
        {
            var q = QueryOf(url);
            if (!q.TryGetValue("sessionId", out var sid) || !_state.PickerSessions.TryGetValue(sid, out var s)) return Error(400, "Missing session", statusText: "INVALID_ARGUMENT");
            if (!s.Set) return Error(400, "The user hasn’t picked yet.", statusText: "FAILED_PRECONDITION");
            var size = int.TryParse(q.GetValueOrDefault("pageSize"), out var ps) ? ps : 50;
            if (size > 100) return Error(400, "pageSize must be at most 100", statusText: "INVALID_ARGUMENT");
            var start = int.TryParse(q.GetValueOrDefault("pageToken"), out var st) ? st : 0;
            var picked = s.Items.Select(id => _state.PickerLibrary.FirstOrDefault(p => p.Id == id)).OfType<PickerPhoto>().ToList();
            var page = picked.Skip(start).Take(size).ToList();
            var items = new JsonArray();
            foreach (var p in page)
                items.Add(new JsonObject
                {
                    ["id"] = p.Id, ["createTime"] = Iso(p.Created), ["type"] = p.IsVideo ? "VIDEO" : "PHOTO",
                    ["mediaFile"] = new JsonObject
                    {
                        ["baseUrl"] = $"https://lh3.googleusercontent.com/fake/{p.Id}", ["mimeType"] = p.Mime, ["filename"] = p.FileName,
                        ["mediaFileMetadata"] = p.IsVideo ? new JsonObject { ["videoMetadata"] = new JsonObject { ["processingStatus"] = "READY" } } : new JsonObject { ["width"] = 900, ["height"] = 600 },
                    },
                });
            var output = new JsonObject { ["mediaItems"] = items };
            if (start + page.Count < picked.Count) output["nextPageToken"] = (start + page.Count).ToString(CultureInfo.InvariantCulture);
            return Json(200, output);
        }
        return Error(404, $"Not found: {method} {path}", statusText: "NOT_FOUND");
    }

    // MARK: Photos Library

    Outcome Photos(string method, Uri url, HttpRequestMessage r, byte[] body)
    {
        var path = url.AbsolutePath;
        var q = QueryOf(url);
        static Outcome Text(int status, string s, Dictionary<string, string>? h = null)
        {
            var hh = h ?? [];
            hh["Content-Type"] = "text/plain";
            return new Outcome(status, hh, Encoding.UTF8.GetBytes(s));
        }
        if (path == "/v1/uploads" && method == "POST")
        {
            if (q.TryGetValue("upload_id", out var upid)) return PhotoChunk(upid, r, body);
            var proto = H(r, "X-Goog-Upload-Protocol");
            if (proto == "raw")
            {
                if (H(r, "Content-Type") != "application/octet-stream") return Error(400, "Expected application/octet-stream");
                if (body.Length == 0) return Error(400, "Empty upload");
                var token = "upl-" + Guid.NewGuid();
                _state.UploadTokens[token] = new Blob(Md5(body), body.Length);
                return Text(200, token);
            }
            if (proto == "resumable" && H(r, "X-Goog-Upload-Command") == "start")
            {
                if (!long.TryParse(H(r, "X-Goog-Upload-Raw-Size"), out var size)) return Error(400, "Missing X-Goog-Upload-Raw-Size");
                var sid = NewID("p");
                _state.PhotoSessions[sid] = new PhotoSession { Total = size };
                _state.PhotoSessionsStarted++;
                return Text(200, "", new()
                {
                    ["X-Goog-Upload-URL"] = $"https://photoslibrary.googleapis.com/v1/uploads?upload_id={sid}&upload_protocol=resumable",
                    ["X-Goog-Upload-Chunk-Granularity"] = "262144", ["X-Goog-Upload-Status"] = "active",
                });
            }
            return Error(400, "Unsupported upload protocol");
        }
        if (path == "/v1/mediaItems:batchCreate" && method == "POST")
        {
            var j = JsonNode.Parse(body) as JsonObject ?? [];
            var items = j["newMediaItems"] as JsonArray ?? [];
            if (items.Count == 0 || items.Count > 50) return Error(400, "Request must contain between 1 and 50 media items.", statusText: "INVALID_ARGUMENT");
            var albumId = j["albumId"]?.ToString();
            if (albumId is not null && !_state.Albums.ContainsKey(albumId)) return Error(400, "Invalid album ID.", statusText: "INVALID_ARGUMENT");
            _state.BatchCreateSizes.Add(items.Count);
            var results = new JsonArray();
            var allOK = true;
            foreach (var i in items)
            {
                var token = i?["simpleMediaItem"]?["uploadToken"]?.ToString() ?? "";
                var name = i?["simpleMediaItem"]?["fileName"]?.ToString() ?? "file";
                if (!_state.UploadTokens.TryGetValue(token, out var blob) || _state.RejectFileNames.Contains(name))
                {
                    allOK = false;
                    results.Add(new JsonObject { ["uploadToken"] = token, ["status"] = new JsonObject { ["code"] = 3, ["message"] = "Failed: There was an error while trying to create this media item." } });
                    continue;
                }
                // The same bytes are one media item, whatever token refers to them.
                if (!_state.MediaByHash.TryGetValue(blob.Md5, out var id))
                {
                    id = NewID("m");
                    _state.Media[id] = new MediaItem { Id = id, FileName = name, Description = i?["description"]?.ToString(), Size = blob.Size, Md5 = blob.Md5 };
                    _state.MediaByHash[blob.Md5] = id;
                    _state.Usage += blob.Size;
                }
                if (albumId is not null) _state.Albums[albumId].Items.Add(id);
                results.Add(new JsonObject { ["uploadToken"] = token, ["status"] = new JsonObject { ["message"] = "Success" }, ["mediaItem"] = new JsonObject { ["id"] = id, ["filename"] = name } });
            }
            return Json(allOK ? 200 : 207, new JsonObject { ["newMediaItemResults"] = results });
        }
        if (path == "/v1/albums" && method == "POST")
        {
            var j = JsonNode.Parse(body) as JsonObject ?? [];
            var title = j["album"]?["title"]?.ToString();
            if (string.IsNullOrEmpty(title) || title.Length > 500) return Error(400, "Invalid album title", statusText: "INVALID_ARGUMENT");
            var id = NewID("a");
            _state.Albums[id] = new AlbumRec { Id = id, Title = title };
            return Json(200, new JsonObject { ["id"] = id, ["title"] = title, ["isWriteable"] = true, ["productUrl"] = $"https://photos.google.com/lr/album/{id}" });
        }
        if (path.StartsWith("/v1/albums/", StringComparison.Ordinal) && path.EndsWith(":batchAddMediaItems", StringComparison.Ordinal) && method == "POST")
        {
            var id = Uri.UnescapeDataString(path["/v1/albums/".Length..^":batchAddMediaItems".Length]);
            if (!_state.Albums.TryGetValue(id, out var album)) return Error(400, "Invalid album ID.", statusText: "INVALID_ARGUMENT");
            var ids = ((JsonNode.Parse(body) as JsonObject)?["mediaItemIds"] as JsonArray ?? []).Select(x => x!.ToString()).ToList();
            if (ids.Count == 0 || ids.Count > 50) return Error(400, "Request must contain between 1 and 50 media items.", statusText: "INVALID_ARGUMENT");
            if (!ids.All(_state.Media.ContainsKey)) return Error(400, "Request contains an invalid media item id.", statusText: "INVALID_ARGUMENT");
            if (album.Items.Count + ids.Count > GooglePhotos.AlbumLimit) return Error(400, "Album is full", statusText: "INVALID_ARGUMENT");
            foreach (var i in ids) if (!album.Items.Contains(i)) album.Items.Add(i);
            _state.AlbumAddSizes.Add(ids.Count);
            return Json(200, new JsonObject());
        }
        return Error(404, $"Not found: {method} {path}", statusText: "NOT_FOUND");
    }

    Outcome PhotoChunk(string sid, HttpRequestMessage r, byte[] body)
    {
        if (!_state.PhotoSessions.TryGetValue(sid, out var s)) return Error(404, "Upload session not found", statusText: "NOT_FOUND");
        var cmd = (H(r, "X-Goog-Upload-Command") ?? "").Replace(" ", "");
        Outcome Status(int code, byte[]? d = null) => new(code, new()
        {
            ["X-Goog-Upload-Status"] = s.Token is null ? "active" : "final", ["X-Goog-Upload-Size-Received"] = s.Data.Length.ToString(CultureInfo.InvariantCulture), ["Content-Type"] = "text/plain",
        }, d ?? []);
        if (cmd == "query") return Status(200, Encoding.UTF8.GetBytes(s.Token ?? ""));
        if (cmd is not ("upload" or "upload,finalize")) return Error(400, "Unknown upload command");
        if (s.Token is not null) return Error(400, "Upload already finalized");
        if (!long.TryParse(H(r, "X-Goog-Upload-Offset"), out var offset) || offset != s.Data.Length)
            return Error(400, "Offset doesn’t match what was received", statusText: "INVALID_ARGUMENT");
        var finalize = cmd == "upload,finalize";
        if (!finalize && body.Length % 262_144 != 0) return Error(400, "Chunk isn’t a multiple of the granularity", statusText: "INVALID_ARGUMENT");
        _state.ChunkPuts++;
        if (_state.DropPhotoChunk == _state.ChunkPuts)
        {
            s.Data.Write(body, 0, body.Length / 2 / 262_144 * 262_144);
            return DropOutcome;
        }
        s.Data.Write(body);
        if (finalize)
        {
            if (s.Data.Length != s.Total) return Error(400, "Size doesn’t match X-Goog-Upload-Raw-Size", statusText: "INVALID_ARGUMENT");
            var token = "upl-" + Guid.NewGuid();
            _state.UploadTokens[token] = new Blob(Md5(s.Data.ToArray()), s.Total);
            s.Token = token;
            s.Data = new MemoryStream();
            return Status(200, Encoding.UTF8.GetBytes(token));
        }
        return Status(200);
    }
}
