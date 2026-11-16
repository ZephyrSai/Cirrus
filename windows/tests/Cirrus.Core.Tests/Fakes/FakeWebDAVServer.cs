using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Xml;
using System.Xml.Linq;
using Cirrus.Core;

namespace Cirrus.Fakes;

/// <summary>
/// A stateful stand-in for a Nextcloud server (cloud.example.com) and a plain Apache-style WebDAV server
/// (dav.example.com), served as an HttpMessageHandler (port of FakeWebDAVServer.swift). Unit tests use it as the mock
/// server; Debug builds in demo mode use it for the demo Nextcloud and WebDAV accounts. It is strict about the wire
/// protocol so it catches client mistakes: Depth headers, 207 Multi-Status XML with 404 propstats for unknown
/// properties, ETags, Destination/Overwrite on MOVE, If-None-Match on PUT, Nextcloud's chunked upload v2 (Destination on
/// every request, numbered chunks of at least 5 MiB, OC-Total-Length), Login Flow v2, the trash bin, the preview
/// endpoint, quota properties, and Basic auth with 401. Never part of a Release build.
/// </summary>
public sealed class FakeWebDAVServer : HttpMessageHandler, IFakeCloud
{
    public sealed class Item
    {
        public bool IsFolder { get; set; }
        public byte[] Data { get; set; } = [];
        public DateTimeOffset Modified { get; set; }
        public DateTimeOffset Created { get; set; }
        public string Etag { get; set; } = "";
        public int FileID { get; set; }
        public string ContentType { get; set; } = "";
    }

    /// <summary>One entry of Nextcloud's trash bin: the deleted item and (for a folder) what was inside it.</summary>
    public sealed class TrashEntry
    {
        public string Name { get; set; } = "";
        /// <summary>The original parent folder, relative to the user's files ("Documents", or "" for the top).</summary>
        public string Location { get; set; } = "";
        public long Deleted { get; set; }
        /// <summary>"" is the deleted item itself; "sub/" and "sub/x.txt" are its contents.</summary>
        public Dictionary<string, Item> Items { get; set; } = new(StringComparer.Ordinal);
        [JsonIgnore] public bool IsFolder => Items.TryGetValue("", out var it) && it.IsFolder;
    }

    public sealed class Account
    {
        public string LoginName { get; set; } = "";
        public string Uid { get; set; } = "";
        public string Password { get; set; } = "";
        public List<string> AppPasswords { get; set; } = [];
        /// <summary>"/" is the top folder; folders end in "/". Keys are NFC.</summary>
        public Dictionary<string, Item> Files { get; set; } = new(StringComparer.Ordinal);
        public Dictionary<string, TrashEntry> Trash { get; set; } = new(StringComparer.Ordinal);
        /// <summary>Bytes; null = unlimited.</summary>
        public long? Quota { get; set; }
        public string DisplayName { get; set; } = "Alex Morgan";

        public Account() { }

        public Account(string loginName, string uid, string password)
        {
            LoginName = loginName; Uid = uid; Password = password;
            Files["/"] = new Item { IsFolder = true, Modified = SeedDate, Created = SeedDate, Etag = NewETag(), FileID = 1 };
        }

        public Item? ItemAt(string path) => Files.GetValueOrDefault(NFC(path));
        [JsonIgnore] public long UsedBytes => Files.Values.Sum(i => i.IsFolder ? 0L : i.Data.Length);
    }

    public enum HrefStyle { Path, AbsoluteURL, Relative }

    internal sealed class Upload { public string Destination = ""; public Dictionary<int, byte[]> Chunks = []; }
    internal sealed class Flow { public string LoginID = ""; public int Polls; public bool Approved; }

    static readonly DateTimeOffset SeedDate = DateTimeOffset.FromUnixTimeSeconds(1_790_000_000);

    /// <summary>Everything the servers know. Tests read and tweak it between steps (through <see cref="Update"/>).</summary>
    public sealed class State
    {
        public string NextcloudHost = "cloud.example.com";
        /// <summary>For a Nextcloud installed in a subfolder ("/nextcloud").</summary>
        public string NextcloudBasePath = "";
        public string DavHost = "dav.example.com";
        /// <summary>The plain server's WebDAV folder.</summary>
        public string DavRootPath = "/webdav/";
        public Account Nextcloud = new("alex", "alex", "nextcloud-password");
        public Account Plain = new("alex", "alex", "webdav-password");
        public bool TrashbinEnabled = true;
        /// <summary>status.php answers 404 (some hosts block it).</summary>
        public bool HideStatusPage;
        /// <summary>The Nextcloud host plays an ownCloud server instead (its status.php, no Nextcloud properties).</summary>
        public bool OwnCloud;
        public HrefStyle Hrefs = HrefStyle.Path;
        /// <summary>Hrefs spell names in decomposed Unicode (as some servers on Apple file systems do).</summary>
        public bool HrefNFD;
        /// <summary>Depth-1 listings include the folder itself (RFC 4918; on by default).</summary>
        public bool EchoSelf = true;
        /// <summary>The plain server reports quota properties.</summary>
        public bool PlainHasQuota;
        /// <summary>The plain server's file system ignores case.</summary>
        public bool PlainCaseInsensitive;
        /// <summary>Login Flow v2: the user approves in the browser after this many polls (null: only via <see cref="Approve"/>).</summary>
        public int? ApproveAfterPolls = 2;
        /// <summary>Smallest chunk Nextcloud accepts in a chunked upload, except the last one.</summary>
        public int MinChunkSize = 5 * 1024 * 1024;
        public double Latency;
        // Fault injection
        /// <summary>PROPFIND on these paths (relative to the user's files, e.g. "/Documents/") answers 500.</summary>
        public HashSet<string> FailPropfind = [];
        /// <summary>PROPFIND on these paths answers 207 with a cut-off body.</summary>
        public HashSet<string> TruncatePropfind = [];
        /// <summary>The next N requests get 429 with Retry-After: 0.</summary>
        public int RateLimitNext;
        /// <summary>The next N requests get 503 with Retry-After: 0.</summary>
        public int UnavailableNext;
        /// <summary>The next N requests are processed, then the connection drops before the answer arrives.</summary>
        public int DropNext;
        /// <summary>Nextcloud: paths shared with others (oc:share-types lists a link share).</summary>
        public HashSet<string> SharedPaths = [];
        /// <summary>Paths (relative to the user's files) that are locked (423).</summary>
        public HashSet<string> LockedPaths = [];
        // Statistics for tests
        public List<string> Calls = [];
        public int PermanentDeletes, ChunkPuts, ChunkAssemblies, PreviewRequests, LoginPolls, Unauthorized;
        public string? LastUserAgent;
        internal Dictionary<string, Upload> Uploads = [];
        internal Dictionary<string, Flow> Flows = [];
        internal int NextFileID = 100;

        public Item? File(string path, bool plain = false) => (plain ? Plain : Nextcloud).ItemAt(path);

        /// <summary>Adds a file (and its folders) to an account. <paramref name="path"/> like "/Documents/a.txt"; a trailing "/" adds a folder.</summary>
        public void Add(string path, byte[] data, bool plain = false, DateTimeOffset? modified = null)
        {
            var acct = plain ? Plain : Nextcloud;
            var when = modified ?? SeedDate;
            var p = NFC(path);
            var folder = "/";
            var segs = p.Split('/', StringSplitOptions.RemoveEmptyEntries);
            foreach (var seg in segs.Take(segs.Length - 1))
            {
                folder += seg + "/";
                if (!acct.Files.ContainsKey(folder)) acct.Files[folder] = NewItem(true, when);
            }
            if (p.EndsWith('/'))
            {
                if (!acct.Files.ContainsKey(p)) acct.Files[p] = NewItem(true, when);
            }
            else
            {
                var it = NewItem(false, when);
                it.Data = data;
                it.ContentType = Mime.ForName(p);
                acct.Files[p] = it;
            }
        }

        public void AddFolder(string path, bool plain = false) => Add(path.EndsWith('/') ? path : path + "/", [], plain);

        internal Item NewItem(bool folder, DateTimeOffset? modified = null)
        {
            NextFileID++;
            var when = modified ?? Now;
            return new Item
            {
                IsFolder = folder, Modified = when, Created = when, Etag = NewETag(), FileID = NextFileID, ContentType = folder ? "" : "application/octet-stream",
            };
        }

        /// <summary>The demo content (also a good starting point for tests).</summary>
        public static State Seeded()
        {
            var s = new State();
            Seed(s);
            return s;
        }
    }

    readonly object _lock = new();
    State _state;
    string? _persistPath;

    public FakeWebDAVServer(State? s = null) { _state = s ?? new State(); }

    /// <summary>The live state (read it when no request is in flight; change it through <see cref="Update"/>).</summary>
    public State S { get { lock (_lock) return _state; } }
    public void Reset(State? s = null) { lock (_lock) _state = s ?? new State(); }
    public void Update(Action<State> f) { lock (_lock) f(_state); }

    public const string DemoNextcloudPassword = "demo-app-password-nextcloud";
    public const string DemoWebDAVPassword = "demo-password";

    /// <summary>Demo mode: the seeded Nextcloud and WebDAV accounts, in memory.</summary>
    public static FakeWebDAVServer Demo() => Demo(null);

    /// <summary>Demo mode: the seeded accounts, kept on disk in <paramref name="storageDir"/> (null: in memory only).</summary>
    public static FakeWebDAVServer Demo(string? storageDir)
    {
        var s = State.Seeded();
        s.Latency = Env.Flag("CIRRUS_DEMO_FAST") ? 0 : 0.02;
        var f = new FakeWebDAVServer(s);
        if (storageDir is not null)
        {
            Directory.CreateDirectory(storageDir);
            f._persistPath = Path.Combine(storageDir, "webdav-state-v1.json");
            try
            {
                if (System.IO.File.Exists(f._persistPath) && JsonSerializer.Deserialize<Saved>(System.IO.File.ReadAllBytes(f._persistPath)) is { } saved)
                {
                    s.Nextcloud = saved.Nextcloud;
                    s.Plain = saved.Plain;
                    s.NextFileID = Math.Max(s.NextFileID, saved.NextFileID);
                }
            }
            catch { }
        }
        if (!s.Nextcloud.AppPasswords.Contains(DemoNextcloudPassword)) s.Nextcloud.AppPasswords.Add(DemoNextcloudPassword);
        s.Plain.Password = DemoWebDAVPassword;
        return f;
    }

    /// <summary>The demo account records (stable ids) with the passwords <see cref="Demo()"/> accepts.</summary>
    public IReadOnlyList<CloudConnection> DemoAccounts()
    {
        string ncHost, davHost, basePath, root, ncUser, davUser;
        lock (_lock)
        {
            (ncHost, davHost, basePath, root) = (_state.NextcloudHost, _state.DavHost, _state.NextcloudBasePath, _state.DavRootPath);
            (ncUser, davUser) = (_state.Nextcloud.LoginName, _state.Plain.LoginName);
        }
        var nc = new CloudAccountRecord(CloudProvider.Nextcloud, $"{ncUser}@{ncHost}", $"https://{ncHost}{basePath}", ncUser, id: "cloud:nextcloud:demo")
        {
            Added = SeedDate,
        };
        var dav = new CloudAccountRecord(CloudProvider.WebDAV, $"{davUser}@{davHost}", $"https://{davHost}{EncodeLoose(root)}", davUser, id: "cloud:webdav:demo")
        {
            Added = SeedDate,
        };
        return [new CloudConnection(nc, new CloudSecret { Password = DemoNextcloudPassword }), new CloudConnection(dav, new CloudSecret { Password = DemoWebDAVPassword })];
    }

    public bool Handles(Uri uri)
    {
        var h = uri.Host.ToLowerInvariant();
        lock (_lock) return h == _state.NextcloudHost || h == _state.DavHost;
    }

    /// <summary>Plays the user approving Cirrus on the login page the app opened.</summary>
    public void Approve(Uri loginURL)
    {
        var id = loginURL.AbsolutePath.TrimEnd('/').Split('/')[^1];
        Update(s => { foreach (var f in s.Flows.Values) if (f.LoginID == id) f.Approved = true; });
    }

    sealed class Saved
    {
        public Account Nextcloud { get; set; } = new();
        public Account Plain { get; set; } = new();
        public int NextFileID { get; set; }
    }

    void Persist()
    {
        if (_persistPath is null) return;
        var saved = new Saved { Nextcloud = _state.Nextcloud, Plain = _state.Plain, NextFileID = _state.NextFileID };
        try
        {
            var tmp = _persistPath + ".tmp";
            System.IO.File.WriteAllBytes(tmp, JsonSerializer.SerializeToUtf8Bytes(saved));
            System.IO.File.Move(tmp, _persistPath, true);
        }
        catch { }
    }

    // MARK: HttpMessageHandler

    sealed record Outcome(int Status, Dictionary<string, string> Headers, byte[] Data, bool Drop = false);

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        var body = request.Content is null ? [] : await request.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
        Outcome o;
        double latency;
        lock (_lock) { o = Handle(request, body); latency = _state.Latency; }
        if (latency > 0) await Task.Delay(TimeSpan.FromSeconds(latency), ct).ConfigureAwait(false);
        if (o.Drop) throw new HttpRequestException(HttpRequestError.ResponseEnded, "The network connection was lost.", new IOException("connection lost"));
        var data = request.Method == HttpMethod.Head ? [] : o.Data;
        var resp = new HttpResponseMessage((HttpStatusCode)o.Status) { RequestMessage = request, Content = new ByteArrayContent(data) };
        foreach (var (k, v) in o.Headers)
        {
            if (k.Equals("Content-Length", StringComparison.OrdinalIgnoreCase)) continue;
            if (!resp.Headers.TryAddWithoutValidation(k, v)) resp.Content.Headers.TryAddWithoutValidation(k, v);
        }
        return resp;
    }

    static string? H(HttpRequestMessage r, string name)
    {
        if (r.Headers.TryGetValues(name, out var v)) return string.Join(", ", v);
        if (r.Content?.Headers.TryGetValues(name, out var cv) == true) return string.Join(", ", cv);
        return null;
    }

    // MARK: Helpers

    static DateTimeOffset Now => DateTimeOffset.FromUnixTimeSeconds(DateTimeOffset.UtcNow.ToUnixTimeSeconds());
    static string NewETag() => Guid.NewGuid().ToString("N")[..16];
    static string NFC(string s) => s.Normalize(NormalizationForm.FormC);
    static string HttpDate(DateTimeOffset d) => d.UtcDateTime.ToString("r", CultureInfo.InvariantCulture);
    static string IsoDate(DateTimeOffset d) => d.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);

    static bool Previewable(Item it) =>
        !it.IsFolder && (it.ContentType.StartsWith("image/", StringComparison.Ordinal) || it.ContentType == "application/pdf" || it.ContentType.StartsWith("text/", StringComparison.Ordinal));

    static string Xml(string s) => s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace("\"", "&quot;");

    /// <summary>Like PHP's rawurlencode (Sabre/Nextcloud): everything but ASCII letters, digits and - . _ ~.</summary>
    static string EncodeStrict(string path) => string.Join('/', path.Split('/').Select(Uri.EscapeDataString));

    /// <summary>Like Apache: only what must be encoded (keeps &amp; + ' ( ) = , ; @ …).</summary>
    static string EncodeLoose(string path)
    {
        var sb = new StringBuilder();
        Span<byte> buf = stackalloc byte[4];
        foreach (var rune in path.EnumerateRunes())
        {
            if (rune.IsAscii && (char.IsAsciiLetterOrDigit((char)rune.Value) || "-._~!$&'()*+,;=:@/".Contains((char)rune.Value))) { sb.Append((char)rune.Value); continue; }
            var n = rune.EncodeToUtf8(buf);
            for (int i = 0; i < n; i++) sb.Append('%').Append(buf[i].ToString("X2", CultureInfo.InvariantCulture));
        }
        return sb.ToString();
    }

    static (string User, string Password)? Basic(HttpRequestMessage r)
    {
        if (H(r, "Authorization") is not { } h || !h.StartsWith("Basic ", StringComparison.Ordinal)) return null;
        try
        {
            var s = Encoding.UTF8.GetString(Convert.FromBase64String(h[6..]));
            var i = s.IndexOf(':');
            return i < 0 ? null : (s[..i], s[(i + 1)..]);
        }
        catch (FormatException) { return null; }
    }

    static bool Authorized(HttpRequestMessage r, Account a, bool nextcloud) =>
        Basic(r) is { } b && b.User == a.LoginName && (b.Password == a.Password || (nextcloud && a.AppPasswords.Contains(b.Password)));

    static Outcome Reply(int status, Dictionary<string, string>? headers = null, byte[]? data = null) => new(status, headers ?? [], data ?? []);

    static Outcome SabreError(int status, string exception, string message)
    {
        var body = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<d:error xmlns:d=\"DAV:\" xmlns:s=\"http://sabredav.org/ns\">"
            + $"<s:exception>Sabre\\DAV\\Exception\\{exception}</s:exception><s:message>{Xml(message)}</s:message></d:error>";
        return Reply(status, new() { ["Content-Type"] = "application/xml; charset=utf-8" }, Encoding.UTF8.GetBytes(body));
    }

    static Outcome ApacheError(int status, string title)
    {
        var body = $"<!DOCTYPE HTML PUBLIC \"-//IETF//DTD HTML 2.0//EN\">\n<html><head><title>{status} {title}</title></head><body><h1>{title}</h1></body></html>\n";
        return Reply(status, new() { ["Content-Type"] = "text/html; charset=iso-8859-1" }, Encoding.UTF8.GetBytes(body));
    }

    static Outcome Fail(int status, string message, bool plain)
    {
        if (plain) return ApacheError(status, message);
        var ex = status switch
        {
            400 => "BadRequest", 401 => "NotAuthenticated", 403 => "Forbidden", 404 => "NotFound", 405 => "MethodNotAllowed", 409 => "Conflict",
            412 => "PreconditionFailed", 415 => "UnsupportedMediaType", 423 => "Locked", 507 => "InsufficientStorage", _ => "ServiceUnavailable",
        };
        return SabreError(status, ex, message);
    }

    Outcome Unauthorized(bool plain)
    {
        _state.Unauthorized++;
        var o = Fail(401, "No public access to this resource., No 'Authorization: Basic' header found.", plain);
        o.Headers["WWW-Authenticate"] = $"Basic realm=\"{(plain ? "WebDAV" : "Nextcloud")}\", charset=\"UTF-8\"";
        return o;
    }

    static Outcome Json(int status, JsonNode j) => Reply(status, new() { ["Content-Type"] = "application/json; charset=utf-8" }, Encoding.UTF8.GetBytes(j.ToJsonString()));

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

    static string LastSegment(string path)
    {
        var p = path.EndsWith('/') ? path[..^1] : path;
        var i = p.LastIndexOf('/');
        return i < 0 ? p : p[(i + 1)..];
    }

    static string ParentKey(string p)
    {
        if (p == "/") return "/";
        var t = p.EndsWith('/') ? p[..^1] : p;
        var i = t.LastIndexOf('/');
        return i < 0 ? "/" : t[..(i + 1)];
    }

    // MARK: Routing

    /// <summary>A request on one account's files.</summary>
    /// <param name="RootHref">Encoded path of the files root as it appears in hrefs ("/remote.php/dav/files/alex/").</param>
    /// <param name="RequestPath">Encoded path of this request.</param>
    sealed record Ctx(bool Plain, string Host, string RootHref, string RequestPath);

    Account Acct(Ctx ctx) => ctx.Plain ? _state.Plain : _state.Nextcloud;

    Outcome Handle(HttpRequestMessage r, byte[] body)
    {
        var s = _state;
        if (r.RequestUri is not { IsAbsoluteUri: true } url || string.IsNullOrEmpty(url.Host)) return ApacheError(400, "Bad Request");
        var host = url.Host.ToLowerInvariant();
        var method = r.Method.Method;
        var encPath = url.AbsolutePath;
        var path = Uri.UnescapeDataString(encPath);
        if (s.Calls.Count > 20_000) s.Calls.RemoveRange(0, 10_000);   // demo sessions run long
        s.Calls.Add($"{method} {path}");
        s.LastUserAgent = r.Headers.UserAgent.Count > 0 ? r.Headers.UserAgent.ToString() : H(r, "User-Agent");
        if (s.RateLimitNext > 0)
        {
            s.RateLimitNext--;
            return Reply(429, new() { ["Retry-After"] = "0", ["Content-Type"] = "text/plain" }, "Too Many Requests"u8.ToArray());
        }
        if (s.UnavailableNext > 0)
        {
            s.UnavailableNext--;
            return Reply(503, new() { ["Retry-After"] = "0", ["Content-Type"] = "text/plain" }, "Service Unavailable"u8.ToArray());
        }
        var o = host == s.NextcloudHost ? NextcloudServer(method, url, path, encPath, r, body) : PlainServer(method, path, encPath, r, body);
        if (method is "PUT" or "MKCOL" or "MOVE" or "DELETE" or "COPY") Persist();
        if (s.DropNext > 0)
        {
            // Processed, but the answer never arrives.
            s.DropNext--;
            return o with { Drop = true };
        }
        return o;
    }

    Outcome PlainServer(string method, string path, string encPath, HttpRequestMessage r, byte[] body)
    {
        var s = _state;
        var root = s.DavRootPath;
        if (path == "/status.php") return ApacheError(404, "Not Found");
        var rootNoSlash = root[..^1];
        if (!path.StartsWith(root, StringComparison.Ordinal) && path != rootNoSlash) return ApacheError(404, "Not Found");
        if (!Authorized(r, s.Plain, nextcloud: false)) return Unauthorized(plain: true);
        if (path == rootNoSlash) return Reply(301, new() { ["Location"] = $"https://{s.DavHost}{EncodeLoose(root)}" });
        var rel = "/" + path[root.Length..];
        return Files(method, rel, r, body, new Ctx(true, s.DavHost, EncodeLoose(root), encPath));
    }

    Outcome NextcloudServer(string method, Uri url, string fullPath, string encPath, HttpRequestMessage r, byte[] body)
    {
        var s = _state;
        var basePath = s.NextcloudBasePath;
        if (!fullPath.StartsWith(basePath, StringComparison.Ordinal)) return Fail(404, "Not found", false);
        var path = fullPath[basePath.Length..];
        var uid = s.Nextcloud.Uid;
        var host = s.NextcloudHost;
        if (path == "/status.php")
        {
            if (s.HideStatusPage) return Fail(404, "Not found", false);
            return s.OwnCloud
                ? Json(200, new JsonObject
                {
                    ["installed"] = true, ["maintenance"] = false, ["needsDbUpgrade"] = false, ["version"] = "10.15.0.2", ["versionstring"] = "10.15.0",
                    ["edition"] = "Community", ["productname"] = "ownCloud", ["product"] = "ownCloud",
                })
                : Json(200, new JsonObject
                {
                    ["installed"] = true, ["maintenance"] = false, ["needsDbUpgrade"] = false, ["version"] = "30.0.2.2", ["versionstring"] = "30.0.2",
                    ["edition"] = "", ["productname"] = "Nextcloud", ["extendedSupport"] = false,
                });
        }
        if (path == "/index.php/login/v2")
        {
            if (method != "POST") return Fail(405, "Method not allowed", false);
            var token = Guid.NewGuid().ToString("N") + Guid.NewGuid().ToString("N");
            var loginID = Guid.NewGuid().ToString("N");
            s.Flows[token] = new Flow { LoginID = loginID };
            return Json(200, new JsonObject
            {
                ["poll"] = new JsonObject { ["token"] = token, ["endpoint"] = $"https://{host}{basePath}/login/v2/poll" },
                ["login"] = $"https://{host}{basePath}/login/v2/flow/{loginID}",
            });
        }
        if (path is "/login/v2/poll" or "/index.php/login/v2/poll")
        {
            if (method != "POST") return Fail(405, "Method not allowed", false);
            s.LoginPolls++;
            if (!Form(body).TryGetValue("token", out var token) || !s.Flows.TryGetValue(token, out var f)) return Json(404, new JsonObject());
            f.Polls++;
            if (!f.Approved && s.ApproveAfterPolls is int n && f.Polls >= n) f.Approved = true;
            if (!f.Approved) return Json(404, new JsonObject());
            s.Flows.Remove(token);    // a token works once
            var app = "app-" + Guid.NewGuid().ToString("N");
            s.Nextcloud.AppPasswords.Add(app);
            return Json(200, new JsonObject { ["server"] = $"https://{host}{basePath}", ["loginName"] = s.Nextcloud.LoginName, ["appPassword"] = app });
        }
        if (path.StartsWith("/login/v2/flow/", StringComparison.Ordinal))
            return Reply(200, new() { ["Content-Type"] = "text/html" }, "<html>Connect to your account</html>"u8.ToArray());
        if (path == "/index.php/core/preview") return Preview(method, url, r);

        if (!path.StartsWith("/remote.php/", StringComparison.Ordinal)) return Fail(404, "Not found", false);
        if (!Authorized(r, s.Nextcloud, nextcloud: true)) return Unauthorized(plain: false);
        var encBase = EncodeStrict(basePath);
        if (path is "/remote.php/dav" or "/remote.php/dav/")
        {
            if (method != "PROPFIND") return Fail(405, "Method not allowed", false);
            if (H(r, "Depth") is null) return Fail(400, "Cirrus always sends a Depth header", false);
            var href = Xml(encBase + "/remote.php/dav/");
            var principal = Xml(encBase + "/remote.php/dav/principals/users/" + EncodeStrict(uid) + "/");
            var x = MultistatusHead(false) + $"<d:response><d:href>{href}</d:href><d:propstat><d:prop>"
                + $"<d:current-user-principal><d:href>{principal}</d:href></d:current-user-principal></d:prop>"
                + "<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>";
            return Reply(207, new() { ["Content-Type"] = "application/xml; charset=utf-8" }, Encoding.UTF8.GetBytes(x));
        }
        const string filesPrefix = "/remote.php/dav/files/";
        if (path.StartsWith(filesPrefix, StringComparison.Ordinal))
        {
            var rest = path[filesPrefix.Length..];
            var slash = rest.IndexOf('/');
            var user = slash < 0 ? rest : rest[..slash];
            if (user != uid) return Fail(404, $"Principal with name {user} not found", false);
            var rel = rest[user.Length..];
            return Files(method, rel.Length == 0 ? "/" : rel, r, body, new Ctx(false, host, encBase + filesPrefix + EncodeStrict(uid) + "/", encPath));
        }
        if (path.StartsWith("/remote.php/webdav", StringComparison.Ordinal))
        {
            var rel = path["/remote.php/webdav".Length..];
            return Files(method, rel.Length == 0 ? "/" : rel, r, body, new Ctx(false, host, encBase + "/remote.php/webdav/", encPath));
        }
        var trashPrefix = "/remote.php/dav/trashbin/" + uid + "/trash";
        if (path.StartsWith("/remote.php/dav/trashbin/", StringComparison.Ordinal))
        {
            if (!s.TrashbinEnabled) return Fail(404, "File with name trashbin could not be located", false);
            if (!path.StartsWith(trashPrefix, StringComparison.Ordinal)) return Fail(404, "Not found", false);
            var rel = path[trashPrefix.Length..];
            return Trashbin(method, rel.Length == 0 ? "/" : rel, r, body, encPath, encBase);
        }
        var uploadsPrefix = "/remote.php/dav/uploads/" + uid + "/";
        if (path.StartsWith(uploadsPrefix, StringComparison.Ordinal)) return Uploads(method, path[uploadsPrefix.Length..], r, body);
        return Fail(404, "Not found", false);
    }

    // MARK: Files

    static string? Find(Dictionary<string, Item> files, string path, bool ci)
    {
        var p = NFC(path);
        if (files.ContainsKey(p)) return p;
        if (!p.EndsWith('/') && files.ContainsKey(p + "/")) return p + "/";
        if (p.EndsWith('/') && p != "/" && files.ContainsKey(p[..^1])) return null;
        if (!ci) return null;
        var l = p.ToLowerInvariant();
        var lf = (p.EndsWith('/') ? p : p + "/").ToLowerInvariant();
        return files.Keys.FirstOrDefault(k => k.ToLowerInvariant() == l || k.ToLowerInvariant() == lf);
    }

    static List<string> Children(Dictionary<string, Item> files, string folder) =>
        files.Keys.Where(k =>
        {
            if (k == folder || !k.StartsWith(folder, StringComparison.Ordinal)) return false;
            var rest = k[folder.Length..];
            var trimmed = rest.EndsWith('/') ? rest[..^1] : rest;
            return trimmed.Length > 0 && !trimmed.Contains('/');
        }).OrderBy(k => k, StringComparer.Ordinal).ToList();

    static List<string> Subtree(Dictionary<string, Item> files, string key) =>
        key.EndsWith('/') ? files.Keys.Where(k => k.StartsWith(key, StringComparison.Ordinal)).ToList() : [key];

    bool IsLocked(string key) => _state.LockedPaths.Any(p => NFC(p) == key || NFC(p) + "/" == key);

    string Href(Ctx ctx, string key, bool isFolder)
    {
        var k = key;
        if (_state.HrefNFD) k = k.Normalize(NormalizationForm.FormD);
        if (isFolder && !k.EndsWith('/')) k += "/";
        var rel = k[1..];
        var full = ctx.RootHref + (ctx.Plain ? EncodeLoose(rel) : EncodeStrict(rel));
        switch (_state.Hrefs)
        {
            case HrefStyle.AbsoluteURL: return "https://" + ctx.Host + full;
            case HrefStyle.Relative:
                // Relative to the folder of the request (RFC 3986 reference).
                var reqDir = ctx.RequestPath.EndsWith('/') ? ctx.RequestPath : ctx.RequestPath[..(ctx.RequestPath.LastIndexOf('/') + 1)];
                if (full.StartsWith(reqDir, StringComparison.Ordinal))
                {
                    var rr = full[reqDir.Length..];
                    return rr.Length == 0 ? "./" : rr;
                }
                return full;
            default: return full;
        }
    }

    static string MultistatusHead(bool plain) => plain
        ? "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:multistatus xmlns:D=\"DAV:\" xmlns:ns0=\"DAV:\">"
        : "<?xml version=\"1.0\"?>\n<d:multistatus xmlns:d=\"DAV:\" xmlns:s=\"http://sabredav.org/ns\" xmlns:oc=\"http://owncloud.org/ns\" xmlns:nc=\"http://nextcloud.org/ns\">";

    /// <summary>The properties a PROPFIND asked for (null: allprop / empty body). Not OK for malformed XML.</summary>
    static (bool Ok, List<(string Ns, string Name)>? Props) RequestedProps(byte[] body)
    {
        if (body.Length == 0) return (true, null);
        XDocument doc;
        try
        {
            using var reader = XmlReader.Create(new MemoryStream(body), new XmlReaderSettings { DtdProcessing = DtdProcessing.Ignore, XmlResolver = null });
            doc = XDocument.Load(reader);
        }
        catch (XmlException) { return (false, null); }
        if (doc.Root is not { } root || root.Name.LocalName != "propfind") return (false, null);
        if (doc.Descendants().Any(e => e.Name.LocalName == "allprop")) return (true, null);
        return (true, root.Elements().Where(e => e.Name.LocalName == "prop").SelectMany(p => p.Elements())
            .Select(e => (e.Name.NamespaceName, e.Name.LocalName)).ToList());
    }

    static readonly List<(string Ns, string Name)> DefaultProps =
        [("DAV:", "resourcetype"), ("DAV:", "getcontentlength"), ("DAV:", "getlastmodified"), ("DAV:", "getetag"), ("DAV:", "getcontenttype"), ("DAV:", "creationdate")];

    /// <summary>Property values (inner XML) for one item.</summary>
    Dictionary<string, string> Values(Item it, string key, Ctx ctx, (string Name, string Location, long Deleted)? trash = null)
    {
        var D = ctx.Plain ? "D:" : "d:";
        var v = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["DAV: resourcetype"] = it.IsFolder ? $"<{D}collection/>" : "",
            ["DAV: getlastmodified"] = HttpDate(it.Modified),
            ["DAV: getetag"] = Xml($"\"{it.Etag}\""),
            ["DAV: creationdate"] = IsoDate(it.Created),
        };
        if (!it.IsFolder)
        {
            v["DAV: getcontentlength"] = it.Data.Length.ToString(CultureInfo.InvariantCulture);
            v["DAV: getcontenttype"] = Xml(it.ContentType);
        }
        var acct = Acct(ctx);
        if (it.IsFolder && (!ctx.Plain || _state.PlainHasQuota) && trash is null)
        {
            var used = acct.UsedBytes;
            v["DAV: quota-used-bytes"] = used.ToString(CultureInfo.InvariantCulture);
            v["DAV: quota-available-bytes"] = acct.Quota is long q ? Math.Max(0, q - used).ToString(CultureInfo.InvariantCulture) : "-3";
        }
        if (!ctx.Plain)
        {
            var size = it.IsFolder ? acct.Files.Where(kv => kv.Key.StartsWith(key, StringComparison.Ordinal) && !kv.Value.IsFolder).Sum(kv => (long)kv.Value.Data.Length) : it.Data.Length;
            v["http://owncloud.org/ns fileid"] = it.FileID.ToString(CultureInfo.InvariantCulture);
            v["http://owncloud.org/ns id"] = it.FileID.ToString("D8", CultureInfo.InvariantCulture) + "ocfake";
            v["http://owncloud.org/ns size"] = size.ToString(CultureInfo.InvariantCulture);
            v["http://owncloud.org/ns permissions"] = it.IsFolder ? "RGDNVCK" : "RGDNVW";
            v["http://owncloud.org/ns share-types"] = _state.SharedPaths.Any(p => NFC(p) == key) ? "<oc:share-type>3</oc:share-type>" : "";
            if (!_state.OwnCloud)
            {
                v["http://nextcloud.org/ns has-preview"] = Previewable(it) ? "true" : "false";
                if (trash is { } t)
                {
                    v["http://nextcloud.org/ns trashbin-filename"] = Xml(t.Name);
                    v["http://nextcloud.org/ns trashbin-original-location"] = Xml(t.Location.Length == 0 ? t.Name : t.Location + "/" + t.Name);
                    v["http://nextcloud.org/ns trashbin-deletion-time"] = t.Deleted.ToString(CultureInfo.InvariantCulture);
                }
            }
        }
        return v;
    }

    static string ResponseXML(string href, Dictionary<string, string> values, List<(string Ns, string Name)>? requested, bool plain)
    {
        var want = requested ?? DefaultProps;
        var found = new List<string>();
        var missing = new List<string>();
        var prefixes = new Dictionary<string, string> { ["DAV:"] = plain ? "lp1" : "d", ["http://owncloud.org/ns"] = "oc", ["http://nextcloud.org/ns"] = "nc" };
        foreach (var (ns, name) in want)
        {
            var known = plain ? (ns == "DAV:" ? "lp1" : null) : prefixes.GetValueOrDefault(ns);
            string open, close, empty;
            if (known is not null) { open = $"<{known}:{name}>"; close = $"</{known}:{name}>"; empty = $"<{known}:{name}/>"; }
            else { open = $"<x:{name} xmlns:x=\"{Xml(ns)}\">"; close = $"</x:{name}>"; empty = $"<x:{name} xmlns:x=\"{Xml(ns)}\"/>"; }
            if (values.TryGetValue(ns + " " + name, out var val)) found.Add(val.Length == 0 ? empty : open + val + close); else missing.Add(empty);
        }
        var D = plain ? "D" : "d";
        var sb = new StringBuilder(plain ? "<D:response xmlns:lp1=\"DAV:\" xmlns:lp2=\"http://apache.org/dav/props/\">" : "<d:response>");
        sb.Append($"<{D}:href>{Xml(href)}</{D}:href>");
        if (found.Count > 0) sb.Append($"<{D}:propstat><{D}:prop>").Append(string.Concat(found)).Append($"</{D}:prop><{D}:status>HTTP/1.1 200 OK</{D}:status></{D}:propstat>");
        if (missing.Count > 0) sb.Append($"<{D}:propstat><{D}:prop>").Append(string.Concat(missing)).Append($"</{D}:prop><{D}:status>HTTP/1.1 404 Not Found</{D}:status></{D}:propstat>");
        sb.Append($"</{D}:response>");
        return sb.ToString();
    }

    enum DestKind { Files, Restore, Other }

    (DestKind Kind, string Path, bool Ok) Destination(HttpRequestMessage r, Ctx ctx)
    {
        if (H(r, "Destination") is not { } d || !Uri.TryCreate(d, UriKind.Absolute, out var u)) return (DestKind.Other, "", false);
        if (!string.IsNullOrEmpty(u.Host) && u.Host.ToLowerInvariant() != ctx.Host) return (DestKind.Other, "", false);
        var p = Uri.UnescapeDataString(u.AbsolutePath);
        var rootDecoded = Uri.UnescapeDataString(ctx.RootHref);
        if (p.StartsWith(rootDecoded, StringComparison.Ordinal)) return (DestKind.Files, "/" + p[rootDecoded.Length..], true);
        if (!ctx.Plain)
        {
            var b = _state.NextcloudBasePath;
            var files = b + "/remote.php/dav/files/" + _state.Nextcloud.Uid + "/";
            if (p.StartsWith(files, StringComparison.Ordinal)) return (DestKind.Files, "/" + p[files.Length..], true);
            if (p.StartsWith(b + "/remote.php/dav/trashbin/" + _state.Nextcloud.Uid + "/restore/", StringComparison.Ordinal)) return (DestKind.Restore, "", true);
        }
        return (DestKind.Other, "", true);
    }

    Outcome Files(string method, string rel, HttpRequestMessage r, byte[] body, Ctx ctx)
    {
        var s = _state;
        var acct = Acct(ctx);
        var plain = ctx.Plain;
        var ci = plain && s.PlainCaseInsensitive;
        var found = Find(acct.Files, rel, ci);
        switch (method)
        {
            case "OPTIONS":
                return Reply(200, new() { ["DAV"] = "1, 2, 3", ["Allow"] = "OPTIONS, GET, HEAD, DELETE, PROPFIND, PUT, PROPPATCH, COPY, MOVE, MKCOL" });
            case "PROPFIND":
            {
                if (H(r, "Depth") is not { } depth) return Fail(400, "Cirrus always sends a Depth header", plain);
                if (depth is not ("0" or "1")) return Fail(403, "Depth infinity is not allowed", plain);
                if (found is null) return Fail(404, $"File with name {rel} could not be located", plain);
                var it = acct.Files[found];
                if (plain && it.IsFolder && !rel.EndsWith('/')) return Reply(301, new() { ["Location"] = "https://" + ctx.Host + Href(ctx, found, true) });
                if (s.FailPropfind.Any(p => NFC(p) == found)) return Fail(500, "Internal Server Error", plain);
                var req = RequestedProps(body);
                if (!req.Ok) return Fail(400, "The request body is not valid XML", plain);
                var keys = new List<string> { found };
                if (depth == "1" && it.IsFolder)
                {
                    keys.AddRange(Children(acct.Files, found));
                    if (!s.EchoSelf) keys.RemoveAt(0);
                }
                var x = new StringBuilder(MultistatusHead(plain));
                foreach (var key in keys)
                {
                    var item = acct.Files[key];
                    x.Append(ResponseXML(Href(ctx, key, item.IsFolder), Values(item, key, ctx), req.Props, plain));
                }
                x.Append(plain ? "</D:multistatus>" : "</d:multistatus>");
                var data = Encoding.UTF8.GetBytes(x.ToString());
                if (s.TruncatePropfind.Any(p => NFC(p) == found)) data = data[..(data.Length / 2)];
                return Reply(207, new() { ["Content-Type"] = "application/xml; charset=utf-8" }, data);
            }
            case "GET" or "HEAD":
            {
                if (found is null) return Fail(404, "File not found", plain);
                var it = acct.Files[found];
                if (it.IsFolder)
                    return plain ? Reply(200, new() { ["Content-Type"] = "text/html" }, "<html>Index</html>"u8.ToArray()) : Fail(501, "GET is not implemented on this endpoint", false);
                return Reply(200, new() { ["Content-Type"] = it.ContentType, ["ETag"] = $"\"{it.Etag}\"", ["Last-Modified"] = HttpDate(it.Modified) }, it.Data);
            }
            case "PUT":
            {
                if (rel.EndsWith('/')) return Fail(409, "PUT is not allowed on a collection", plain);
                if (IsLocked(NFC(rel)) || (found is not null && IsLocked(found))) return Fail(423, "The resource you tried to edit is locked", plain);
                if (Find(acct.Files, ParentKey(NFC(rel)), ci) is not { } parent || !acct.Files[parent].IsFolder) return Fail(409, "Parent folder doesn't exist", plain);
                if (found is not null && acct.Files[found].IsFolder) return Fail(405, "A folder with this name exists", plain);
                if (H(r, "If-None-Match") == "*" && found is not null) return Fail(412, "An If-None-Match header was specified, but the ETag matched", plain);
                if (acct.Quota is long q && acct.UsedBytes - (found is null ? 0 : acct.Files[found].Data.Length) + body.Length > q)
                    return Fail(507, $"Insufficient space in {rel}", plain);
                return Store(found ?? parent + LastSegment(NFC(rel)), body, r, ctx, created: found is null);
            }
            case "MKCOL":
            {
                if (body.Length > 0) return Fail(415, "The request body for the MKCOL request must have an xml Content-Type", plain);
                if (found is not null) return Fail(405, "The resource you tried to create already exists", plain);
                if (Find(acct.Files, ParentKey(NFC(rel)), ci) is not { } parent || !acct.Files[parent].IsFolder) return Fail(409, "Parent node does not exist", plain);
                acct.Files[parent + LastSegment(NFC(rel)) + "/"] = s.NewItem(true);
                return Reply(201, plain ? [] : new() { ["Content-Length"] = "0" });
            }
            case "DELETE":
            {
                if (found is null) return Fail(404, "File not found", plain);
                if (found == "/") return Fail(403, "The top folder can't be deleted", plain);
                if (IsLocked(found)) return Fail(423, "Locked", plain);
                if (!plain && s.TrashbinEnabled) MoveToTrash(found);
                else
                {
                    foreach (var key in Subtree(acct.Files, found)) acct.Files.Remove(key);
                    s.PermanentDeletes++;
                }
                return Reply(204);
            }
            case "MOVE":
            {
                if (found is null) return Fail(404, "File not found", plain);
                if (found == "/") return Fail(403, "The top folder can't be moved", plain);
                var (kind, destRaw, ok) = Destination(r, ctx);
                if (!ok) return Fail(plain ? 400 : 502, "The destination header is missing or points to another server", plain);
                if (kind != DestKind.Files) return Fail(403, "Destination is outside this account", plain);
                var overwrite = !(H(r, "Overwrite") ?? "T").Equals("F", StringComparison.OrdinalIgnoreCase);
                var isFolder = acct.Files[found].IsFolder;
                var destRel = NFC(destRaw);
                if (IsLocked(found) || IsLocked(destRel)) return Fail(423, "Locked", plain);
                if (Find(acct.Files, ParentKey(destRel), ci) is not { } parent || !acct.Files[parent].IsFolder) return Fail(409, "The destination node is not found", plain);
                var newKey = parent + LastSegment(destRel) + (isFolder ? "/" : "");
                if (newKey == found) return Fail(403, "Source and destination uri are identical.", plain);
                if (isFolder && newKey.StartsWith(found, StringComparison.Ordinal)) return Fail(409, "Cannot move a node into its own child", plain);
                var existing = Find(acct.Files, destRel, ci);
                if (existing is not null && !overwrite) return Fail(412, "The destination node already exists, and the overwrite header is set to false", plain);
                if (existing is not null && existing != found)
                    foreach (var key in Subtree(acct.Files, existing)) acct.Files.Remove(key);
                var moved = new Dictionary<string, Item>();
                foreach (var key in Subtree(acct.Files, found))
                {
                    moved[newKey + key[found.Length..]] = acct.Files[key];
                    acct.Files.Remove(key);
                }
                foreach (var (key, it) in moved) acct.Files[key] = it;
                return Reply(existing is null || existing == found ? 201 : 204);
            }
            default:
                return Fail(405, $"Method {method} is not allowed", plain);
        }
    }

    /// <summary>PUT or the end of a chunked upload: writes a file and answers like Nextcloud / Apache.</summary>
    Outcome Store(string key, byte[] data, HttpRequestMessage r, Ctx ctx, bool created)
    {
        var acct = Acct(ctx);
        var old = acct.Files.GetValueOrDefault(key);
        var it = old ?? _state.NewItem(false);
        it.IsFolder = false;
        it.Data = data;
        it.Etag = NewETag();
        it.ContentType = H(r, "Content-Type") is { } ct && ct != "application/octet-stream" ? ct : Mime.ForName(key);
        var headers = new Dictionary<string, string> { ["ETag"] = $"\"{it.Etag}\"" };
        it.Modified = Now;
        if (!ctx.Plain && H(r, "X-OC-Mtime") is { } m && double.TryParse(m, NumberStyles.Float, CultureInfo.InvariantCulture, out var secs))
        {
            it.Modified = DateTimeOffset.FromUnixTimeMilliseconds((long)(secs * 1000));
            headers["X-OC-MTime"] = "accepted";
        }
        if (old is null) it.Created = it.Modified;
        acct.Files[key] = it;
        if (!ctx.Plain)
        {
            headers["OC-ETag"] = $"\"{it.Etag}\"";
            headers["OC-FileId"] = it.FileID.ToString("D8", CultureInfo.InvariantCulture) + "ocfake";
        }
        return Reply(created ? 201 : 204, headers);
    }

    // MARK: Nextcloud trash bin

    void MoveToTrash(string key)
    {
        var files = _state.Nextcloud.Files;
        var seg = LastSegment(key);
        var ts = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        while (_state.Nextcloud.Trash.ContainsKey($"{seg}.d{ts}")) ts++;
        var items = new Dictionary<string, Item>(StringComparer.Ordinal);
        foreach (var k in Subtree(files, key))
        {
            items[k == key ? "" : k[key.Length..]] = files[k];
            files.Remove(k);
        }
        var location = ParentKey(key)[1..];
        if (location.EndsWith('/')) location = location[..^1];
        _state.Nextcloud.Trash[$"{seg}.d{ts}"] = new TrashEntry { Name = seg, Location = location, Deleted = ts, Items = items };
    }

    Outcome Trashbin(string method, string rel, HttpRequestMessage r, byte[] body, string encPath, string encBase)
    {
        var s = _state;
        var uid = s.Nextcloud.Uid;
        var ctx = new Ctx(false, s.NextcloudHost, encBase + "/remote.php/dav/trashbin/" + EncodeStrict(uid) + "/trash/", encPath);
        var parts = rel.Split('/', 2, StringSplitOptions.RemoveEmptyEntries);
        var top = parts.Length > 0 ? NFC(parts[0]) : null;
        var inner = parts.Length > 1 ? NFC(parts[1]) : "";
        switch (method)
        {
            case "PROPFIND":
            {
                if (H(r, "Depth") is not { } depth) return Fail(400, "Cirrus always sends a Depth header", false);
                if (depth is not ("0" or "1")) return Fail(403, "Depth infinity is not allowed", false);
                var req = RequestedProps(body);
                var x = new StringBuilder(MultistatusHead(false));
                if (top is null)
                {
                    var rootItem = new Item { IsFolder = true, Modified = Now, Created = Now, Etag = "trash" };
                    if (s.EchoSelf || depth == "0") x.Append(ResponseXML(Href(ctx, "/", true), Values(rootItem, "/", ctx), req.Props, false));
                    if (depth == "1")
                        foreach (var (name, e) in s.Nextcloud.Trash.OrderBy(kv => kv.Key, StringComparer.Ordinal))
                        {
                            if (!e.Items.TryGetValue("", out var it)) continue;
                            x.Append(ResponseXML(Href(ctx, "/" + name, it.IsFolder), Values(it, "/" + name + "/", ctx, (e.Name, e.Location, e.Deleted)), req.Props, false));
                        }
                    return Reply(207, new() { ["Content-Type"] = "application/xml; charset=utf-8" }, Encoding.UTF8.GetBytes(x + "</d:multistatus>"));
                }
                if (!s.Nextcloud.Trash.TryGetValue(top, out var entry)) return Fail(404, "Not found", false);
                var innerKey = inner.EndsWith('/') || inner.Length == 0 ? inner : (entry.Items.ContainsKey(inner) ? inner : inner + "/");
                if (!entry.Items.TryGetValue(innerKey, out var self)) return Fail(404, "Not found", false);
                var selfKey = innerKey.Length == 0 ? "/" + top : "/" + top + "/" + innerKey;
                x.Append(ResponseXML(Href(ctx, selfKey, self.IsFolder), Values(self, selfKey, ctx, innerKey.Length == 0 ? (entry.Name, entry.Location, entry.Deleted) : null),
                    req.Props, false));
                if (depth == "1" && self.IsFolder)
                    foreach (var (k, child) in entry.Items.OrderBy(kv => kv.Key, StringComparer.Ordinal))
                    {
                        if (k.Length == 0 || k == innerKey || !k.StartsWith(innerKey, StringComparison.Ordinal)) continue;
                        var restK = k[innerKey.Length..];
                        var trimmed = restK.EndsWith('/') ? restK[..^1] : restK;
                        if (trimmed.Contains('/')) continue;
                        x.Append(ResponseXML(Href(ctx, "/" + top + "/" + k, child.IsFolder), Values(child, "/" + top + "/" + k, ctx), req.Props, false));
                    }
                return Reply(207, new() { ["Content-Type"] = "application/xml; charset=utf-8" }, Encoding.UTF8.GetBytes(x + "</d:multistatus>"));
            }
            case "GET":
            {
                if (top is null || !s.Nextcloud.Trash.TryGetValue(top, out var e) || !e.Items.TryGetValue(inner, out var it) || it.IsFolder)
                    return Fail(404, "Not found", false);
                return Reply(200, new() { ["Content-Type"] = it.ContentType, ["ETag"] = $"\"{it.Etag}\"" }, it.Data);
            }
            case "DELETE":
            {
                if (top is null)
                {
                    s.PermanentDeletes += s.Nextcloud.Trash.Count;
                    s.Nextcloud.Trash.Clear();
                    return Reply(204);
                }
                if (!s.Nextcloud.Trash.TryGetValue(top, out var e)) return Fail(404, "Not found", false);
                if (inner.Length == 0) s.Nextcloud.Trash.Remove(top);
                else
                {
                    var prefix = inner.EndsWith('/') ? inner : inner + "/";
                    foreach (var k in e.Items.Keys.Where(k => k == inner || k.StartsWith(prefix, StringComparison.Ordinal) || k == inner + "/").ToList()) e.Items.Remove(k);
                }
                s.PermanentDeletes++;
                return Reply(204);
            }
            case "MOVE":
            {
                if (top is null) return Fail(403, "Only deleted items can be restored", false);
                if (inner.Length > 0 || !s.Nextcloud.Trash.TryGetValue(top, out var e)) return Fail(404, "Only deleted items can be restored", false);
                var (kind, _, ok) = Destination(r, new Ctx(false, s.NextcloudHost, "/-none-/", encPath));
                if (!ok || kind != DestKind.Restore) return Fail(403, "Deleted items can only be moved to the restore folder", false);
                var folder = e.Location.Length == 0 ? "/" : "/" + e.Location + "/";
                if (s.Nextcloud.Files.GetValueOrDefault(folder)?.IsFolder != true) folder = "/";
                var name = e.Name;
                if (s.Nextcloud.Files.ContainsKey(folder + name) || s.Nextcloud.Files.ContainsKey(folder + name + "/"))
                {
                    var dot = e.Name.LastIndexOf('.');
                    name = e.IsFolder || dot <= 0 ? $"{e.Name} (restored)" : $"{e.Name[..dot]} (restored){e.Name[dot..]}";
                }
                var newKey = folder + name + (e.IsFolder ? "/" : "");
                foreach (var (k, it) in e.Items) s.Nextcloud.Files[newKey + k] = it;
                s.Nextcloud.Trash.Remove(top);
                return Reply(201);
            }
            default:
                return Fail(405, "Method not allowed", false);
        }
    }

    // MARK: Chunked upload v2

    Outcome Uploads(string method, string rel, HttpRequestMessage r, byte[] body)
    {
        var s = _state;
        var parts = rel.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0) return Fail(403, "Not allowed", false);
        var id = parts[0];
        var ctx = new Ctx(false, s.NextcloudHost, "/-none-/", "");
        string? Dest()
        {
            var (kind, p, ok) = Destination(r, ctx);
            return ok && kind == DestKind.Files ? NFC(p) : null;
        }
        switch (method, parts.Length)
        {
            case ("MKCOL", 1):
            {
                if (Dest() is not { } d) return Fail(400, "Chunked upload v2 needs a Destination header on MKCOL", false);
                if (s.Uploads.ContainsKey(id)) return Fail(405, "The upload folder already exists", false);
                s.Uploads[id] = new Upload { Destination = d };
                return Reply(201);
            }
            case ("PUT", 2):
            {
                if (!s.Uploads.TryGetValue(id, out var u)) return Fail(404, "Upload not found", false);
                if (Dest() is not { } d || d != u.Destination) return Fail(400, "Each chunk needs the same Destination header as the MKCOL", false);
                if (!int.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out var n) || n is < 1 or > 10_000)
                    return Fail(400, "Chunk names must be numbers from 1 to 10000", false);
                u.Chunks[n] = body;
                s.ChunkPuts++;
                return Reply(201, new() { ["ETag"] = $"\"{NewETag()}\"" });
            }
            case ("MOVE", 2) when parts[1] == ".file":
            {
                if (!s.Uploads.TryGetValue(id, out var u)) return Fail(404, "Upload not found", false);
                if (Dest() is not { } d || d != u.Destination) return Fail(400, "The final MOVE must go to the upload's Destination", false);
                var numbers = u.Chunks.Keys.Order().ToList();
                if (numbers.Count == 0 || !numbers.SequenceEqual(Enumerable.Range(1, numbers.Count))) return Fail(400, "Chunks are missing", false);
                foreach (var n in numbers.SkipLast(1))
                    if (u.Chunks[n].Length < s.MinChunkSize) return Fail(400, $"Chunk {n} is smaller than the 5 MiB minimum", false);
                var data = numbers.SelectMany(n => u.Chunks[n]).ToArray();
                if (!int.TryParse(H(r, "OC-Total-Length"), NumberStyles.None, CultureInfo.InvariantCulture, out var total) || total != data.Length)
                    return Fail(400, "OC-Total-Length is missing or doesn't match the chunks", false);
                var fctx = new Ctx(false, s.NextcloudHost, "/", "");
                var existing = Find(s.Nextcloud.Files, d, false);
                if (existing is not null && (H(r, "Overwrite") ?? "T").Equals("F", StringComparison.OrdinalIgnoreCase))
                    return Fail(412, "The destination node already exists, and the overwrite header is set to false", false);
                if (Find(s.Nextcloud.Files, ParentKey(d), false) is not { } parent || !s.Nextcloud.Files[parent].IsFolder)
                    return Fail(409, "Parent folder doesn't exist", false);
                if (s.Nextcloud.Quota is long q && s.Nextcloud.UsedBytes + data.Length > q) return Fail(507, "Insufficient space", false);
                s.Uploads.Remove(id);
                s.ChunkAssemblies++;
                return Store(existing ?? parent + LastSegment(d), data, r, fctx, created: existing is null);
            }
            case ("DELETE", _):
                s.Uploads.Remove(id);
                return Reply(204);
            default:
                return Fail(405, "Method not allowed", false);
        }
    }

    // MARK: Previews

    Outcome Preview(string method, Uri url, HttpRequestMessage r)
    {
        var s = _state;
        if (method != "GET") return Fail(405, "Method not allowed", false);
        if (!Authorized(r, s.Nextcloud, nextcloud: true)) return Reply(401, new() { ["Content-Type"] = "application/json" }, "{}"u8.ToArray());
        s.PreviewRequests++;
        var q = Query(url);
        if (!int.TryParse(q.GetValueOrDefault("fileId"), out var id) || !int.TryParse(q.GetValueOrDefault("x"), out var x) || !int.TryParse(q.GetValueOrDefault("y"), out var y)
            || x <= 0 || y <= 0)
            return Reply(400, new() { ["Content-Type"] = "application/json" }, "{}"u8.ToArray());
        if (s.Nextcloud.Files.Values.FirstOrDefault(i => i.FileID == id) is not { } it || !Previewable(it))
            return Reply(404, new() { ["Content-Type"] = "application/json" }, "[]"u8.ToArray());
        return Reply(200, new() { ["Content-Type"] = "image/png" }, DemoArt.Png(Math.Min(x, 64), Math.Min(y, 64), id % 10 / 10.0, ""));
    }

    // MARK: Demo content

    static readonly Lazy<byte[]> Harbor = new(() => DemoArt.Png(960, 640, 0.58, "Harbor at dusk"));
    static readonly Lazy<byte[]> Lake = new(() => DemoArt.Png(960, 640, 0.45, "Mountain lake"));
    static readonly Lazy<byte[]> Beach = new(() => DemoArt.Png(960, 640, 0.12, "Beach"));
    static readonly Lazy<byte[]> Forest = new(() => DemoArt.Png(960, 640, 0.3, "Forest"));
    static readonly Lazy<byte[]> Logo = new(() => DemoArt.Png(128, 128, 0.6, ""));

    /// <summary>A small one-page PDF with a coloured band, a title and a few lines (no PDF library needed).</summary>
    static byte[] Pdf(string title, string[] lines, double hue)
    {
        static string Esc(string t) => t.Replace("\\", "\\\\").Replace("(", "\\(").Replace(")", "\\)");
        var (r, g, b) = (0.35 + 0.5 * Math.Abs(Math.Sin(hue * Math.PI)), 0.45, 0.85 - 0.5 * hue);
        var content = new StringBuilder();
        content.Append(CultureInfo.InvariantCulture, $"q {r:0.00} {g:0.00} {b:0.00} rg 0 732 612 60 re f Q\n");
        content.Append(CultureInfo.InvariantCulture, $"BT /F1 26 Tf 72 680 Td ({Esc(title)}) Tj ET\n");
        var y = 640;
        foreach (var l in lines) { content.Append(CultureInfo.InvariantCulture, $"BT /F1 14 Tf 72 {y} Td ({Esc(l)}) Tj ET\n"); y -= 26; }
        var stream = content.ToString();
        string[] objects =
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            $"<< /Length {Encoding.ASCII.GetByteCount(stream)} >>\nstream\n{stream}endstream",
        ];
        var sb = new StringBuilder("%PDF-1.4\n");
        var offsets = new List<int>();
        for (int i = 0; i < objects.Length; i++)
        {
            offsets.Add(sb.Length);
            sb.Append(CultureInfo.InvariantCulture, $"{i + 1} 0 obj\n{objects[i]}\nendobj\n");
        }
        var xref = sb.Length;
        sb.Append(CultureInfo.InvariantCulture, $"xref\n0 {objects.Length + 1}\n0000000000 65535 f \n");
        foreach (var off in offsets) sb.Append(CultureInfo.InvariantCulture, $"{off:D10} 00000 n \n");
        sb.Append(CultureInfo.InvariantCulture, $"trailer\n<< /Size {objects.Length + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n");
        return Encoding.ASCII.GetBytes(sb.ToString());
    }

    static void Seed(State s)
    {
        s.Nextcloud.Quota = 10_000_000_000;
        static DateTimeOffset D(double n) => SeedDate.AddDays(n);
        static byte[] T(string t) => Encoding.UTF8.GetBytes(t);
        // Nextcloud
        s.Add("/Readme.md", T("# Welcome\n\nThis is a demo Nextcloud account for Cirrus. Nothing here is real.\n"), modified: D(30));
        s.Add("/Documents/Budget 2026.csv", T("Month,Income,Expenses\nJanuary,4200,3100\nFebruary,4200,2950\nMarch,4350,3300\n"), modified: D(12));
        s.Add("/Documents/Meeting notes.txt", T("Agenda\n- Roadmap review\n- Launch checklist\n- Next steps\n"), modified: D(20));
        s.Add("/Documents/Project brief.pdf", Pdf("Project brief", ["Goals", "Scope", "Timeline", "Owner: Alex Morgan"], 0.58), modified: D(8));
        s.Add("/Documents/Q&A #1 (draft).md", T("Questions and answers, first draft.\n"), modified: D(25));
        s.Add("/Photos/Harbor at dusk.jpg", Harbor.Value, modified: D(3));
        s.Add("/Photos/Mountain lake.jpg", Lake.Value, modified: D(4));
        s.Add("/Photos/Logo.png", Logo.Value, modified: D(5));
        s.Add("/Projects/Roadmap.md", T("# Roadmap\n\n1. Prototype\n2. Beta\n3. Launch\n"), modified: D(18));
        s.Add("/Projects/Website/index.html", T("<!doctype html><title>Demo</title><h1>Hello</h1>\n"), modified: D(15));
        s.Add("/Projects/Website/style.css", T("body { font-family: system-ui; }\n"), modified: D(15));
        s.Add("/Projects/Tasks.csv", T("Task,Owner,Done\nWireframes,Alex Morgan,yes\nCopy,Alex Morgan,no\n"), modified: D(22));
        s.SharedPaths = ["/Projects/"];
        s.Nextcloud.Trash["Old draft.txt.d1791000000"] = new TrashEntry
        {
            Name = "Old draft.txt", Location = "Documents", Deleted = 1_791_000_000,
            Items = new(StringComparer.Ordinal)
            {
                [""] = new Item { IsFolder = false, Data = T("An older draft.\n"), Modified = D(1), Created = D(1), Etag = NewETag(), FileID = 90, ContentType = "text/plain" },
            },
        };
        // Plain WebDAV
        s.Add("/Documents/Notes.txt", T("Shopping list\n- Coffee\n- Bread\n"), plain: true, modified: D(10));
        s.Add("/Documents/Inventory.csv", T("Item,Count\nCables,12\nAdapters,4\n"), plain: true, modified: D(11));
        s.Add("/Documents/Manual.pdf", Pdf("User manual", ["Setup", "Daily use", "Troubleshooting"], 0.1), plain: true, modified: D(6));
        s.Add("/Photos/Beach.jpg", Beach.Value, plain: true, modified: D(2));
        s.Add("/Photos/Forest.jpg", Forest.Value, plain: true, modified: D(2));
        s.Add("/Backups/settings-backup.json", T("{\"theme\": \"dark\", \"version\": 3}\n"), plain: true, modified: D(14));
        s.Add("/Projects/Garden plan.md", T("# Garden plan\n\nTomatoes by the fence, herbs by the door.\n"), plain: true, modified: D(16));
    }
}
