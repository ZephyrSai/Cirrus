using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json.Nodes;

namespace Cirrus.Core;

public sealed record GoogleUser(string Id, string Email, string Name);   // Id: permissionId, stable for the account

public sealed record GoogleQuota(long? Limit, long Usage, long UsageInDrive, long UsageInTrash)   // Limit null = unlimited; Usage = Drive + Gmail + Photos
{
    public long? Free => Limit is { } l ? Math.Max(0, l - Usage) : null;

    /// <summary>For the storage bar: Drive, Gmail &amp; Photos, and (optionally) what this move adds.</summary>
    public StorageUsage? UsageBar(long pending)
    {
        if (Limit is not { } limit || limit <= 0) return null;
        var cats = new List<StorageUsage.Category>
        {
            new("drive", "Google Drive", UsageInDrive, "4285F4"),
            new("other", "Gmail & Google Photos", Math.Max(0, Usage - UsageInDrive), "FBBC04"),
        };
        if (pending > 0) cats.Add(new("move", "This move", pending, "34A853"));
        return new StorageUsage(limit, Usage + pending, cats);
    }
}

public static class StorageUsageExtensions
{
    /// <summary>The same usage with <paramref name="bytes"/> more, shown as its own segment (for "after this copy" bars).</summary>
    public static StorageUsage Adding(this StorageUsage u, long bytes, string label, string color = "34C759") =>
        bytes <= 0 ? u : u with { Used = u.Used + bytes, Categories = u.Categories.Concat([new StorageUsage.Category("added", label, bytes, color)]).ToList() };
}

/// <summary>A file or folder Cirrus created in Google Drive (drive.file scope).</summary>
public sealed class GDriveFile
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string MimeType { get; set; } = "";
    public long Size { get; set; }
    public DateTimeOffset? Modified { get; set; }
    public string? Md5 { get; set; }
    public bool Trashed { get; set; }
    public Dictionary<string, string> AppProperties { get; set; } = [];
    public bool IsFolder => MimeType == GoogleDrive.FolderMime;

    public GDriveFile() { }
    internal GDriveFile(J j)
    {
        Id = j["id"].Str ?? "";
        Name = j["name"].Str ?? "";
        MimeType = j["mimeType"].Str ?? "";
        Size = j["size"].Int64 ?? 0;
        Modified = j["modifiedTime"].Date;
        Md5 = j["md5Checksum"].Str;
        Trashed = j["trashed"].Bool ?? false;
        AppProperties = j["appProperties"].Object.Where(kv => kv.Value.Str is not null).ToDictionary(kv => kv.Key, kv => kv.Value.Str!);
    }
}

/// <summary>A file or folder in the user's Google Drive, as seen with the drive.readonly scope.</summary>
public sealed class GDriveItem
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string MimeType { get; set; } = "";
    /// <summary>null for Google Docs/Sheets/Slides (no stored bytes).</summary>
    public long? Size { get; set; }
    public DateTimeOffset? Modified { get; set; }
    public string? Md5 { get; set; }
    public List<string> Parents { get; set; } = [];
    public bool CanDownload { get; set; } = true;
    public Dictionary<string, string> ExportLinks { get; set; } = [];
    /// <summary>Set on folders Cirrus made ("From iCloud"); private to this OAuth client.</summary>
    public Dictionary<string, string> AppProperties { get; set; } = [];
    /// <summary>Public properties (any app can read them): Cirrus's "From iCloud" marker.</summary>
    public Dictionary<string, string> Properties { get; set; } = [];
    public bool IsFolder => MimeType == GoogleDrive.FolderMime;
    public bool IsGoogleNative => MimeType.StartsWith("application/vnd.google-apps.", StringComparison.Ordinal) && !IsFolder;
    /// <summary>Changes whenever the content does.</summary>
    public string Version => Md5 ?? (Modified is { } m ? m.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture) : "");

    public GDriveItem() { }
    internal GDriveItem(J j)
    {
        Id = j["id"].Str ?? "";
        Name = j["name"].Str ?? "";
        MimeType = j["mimeType"].Str ?? "";
        Size = j["size"].Int64;
        Modified = j["modifiedTime"].Date;
        Md5 = j["md5Checksum"].Str;
        Parents = j["parents"].Array.Select(p => p.Str).OfType<string>().ToList();
        CanDownload = j["capabilities"]["canDownload"].Bool ?? true;
        ExportLinks = j["exportLinks"].Object.Where(kv => kv.Value.Str is not null).ToDictionary(kv => kv.Key, kv => kv.Value.Str!);
        AppProperties = j["appProperties"].Object.Where(kv => kv.Value.Str is not null).ToDictionary(kv => kv.Key, kv => kv.Value.Str!);
        Properties = j["properties"].Object.Where(kv => kv.Value.Str is not null).ToDictionary(kv => kv.Key, kv => kv.Value.Str!);
    }
}

/// <summary>How Google Docs, Sheets and Slides come out (they have no file of their own).</summary>
public enum GoogleDocFormat { Office, Pdf }

public sealed record GoogleDocTarget(string Mime, string Ext);

public static class GoogleDocFormats
{
    /// <summary>null = Google can't export this kind (Forms, Sites, My Maps, shortcuts…).</summary>
    public static GoogleDocTarget? Target(this GoogleDocFormat f, string mime)
    {
        var pdf = new GoogleDocTarget("application/pdf", "pdf");
        return mime switch
        {
            "application/vnd.google-apps.document" => f == GoogleDocFormat.Pdf ? pdf : new("application/vnd.openxmlformats-officedocument.wordprocessingml.document", "docx"),
            "application/vnd.google-apps.spreadsheet" => f == GoogleDocFormat.Pdf ? pdf : new("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "xlsx"),
            "application/vnd.google-apps.presentation" => f == GoogleDocFormat.Pdf ? pdf : new("application/vnd.openxmlformats-officedocument.presentationml.presentation", "pptx"),
            "application/vnd.google-apps.drawing" or "application/vnd.google-apps.jam" => pdf,
            "application/vnd.google-apps.script" => new("application/vnd.google-apps.script+json", "json"),
            _ => null,
        };
    }

    public static string KindName(string mime) => mime switch
    {
        "application/vnd.google-apps.form" => "Google Forms",
        "application/vnd.google-apps.site" => "Google Sites",
        "application/vnd.google-apps.map" => "Google My Maps",
        "application/vnd.google-apps.shortcut" => "Shortcuts",
        "application/vnd.google-apps.fusiontable" => "Fusion Tables",
        "application/vnd.google-apps.vid" => "Google Vids videos",
        _ => "This kind of Google file",
    };
}

/// <summary>A resumable upload session (Drive keeps it for about a week).</summary>
public sealed record DriveUploadSession(string Url, long Total, DateTimeOffset Started);

/// <summary>
/// Google Drive v3 over raw HTTP (port of GoogleDrive.swift + GoogleDriveRead.swift): writing is limited to what the
/// drive.file scope allows (files Cirrus created); reading the whole of My Drive needs drive.readonly.
/// </summary>
public sealed class GoogleDrive
{
    public const string Base = "https://www.googleapis.com/drive/v3";
    public const string UploadBase = "https://www.googleapis.com/upload/drive/v3";
    public const string FolderMime = "application/vnd.google-apps.folder";
    /// <summary>Google Drive: files up to 5 TB.</summary>
    public const long MaxFileSize = 5L * 1024 * 1024 * 1024 * 1024;
    /// <summary>Google Drive: about 750 GB of uploads per user per day.</summary>
    public const long DailyUploadLimit = 750_000_000_000;
    const string FileFields = "id,name,mimeType,size,modifiedTime,md5Checksum,trashed,appProperties";
    public const string ReadFields = "id,name,mimeType,size,modifiedTime,md5Checksum,parents,capabilities/canDownload,exportLinks,appProperties,properties";
    /// <summary>Google exports Docs editors files up to 10 MB through files.export; bigger ones go through exportLinks.</summary>
    public const long ExportLimit = 10 * 1024 * 1024;

    public GoogleApi Api { get; }
    /// <summary>Bytes per upload request; must be a multiple of 256 KiB.</summary>
    public int ChunkSize { get; set; } = 8 << 20;
    /// <summary>Bytes per ranged download request (tests make it small).</summary>
    public static long DownloadChunk { get; set; } = 16 << 20;

    public GoogleDrive(GoogleApi api) { Api = api; }

    public async Task<(GoogleUser User, GoogleQuota Quota)> AboutAsync(CancellationToken ct = default)
    {
        var j = await Api.JsonAsync("GET", Base + "/about", new Dictionary<string, string> { ["fields"] = "user(displayName,emailAddress,permissionId),storageQuota" }, ct: ct).ConfigureAwait(false);
        var u = j["user"]; var q = j["storageQuota"];
        return (new GoogleUser(u["permissionId"].Str ?? "", u["emailAddress"].Str ?? "", u["displayName"].Str ?? ""),
                new GoogleQuota(q["limit"].Int64, q["usage"].Int64 ?? 0, q["usageInDrive"].Int64 ?? 0, q["usageInDriveTrash"].Int64 ?? 0));
    }

    /// <summary>null when the file doesn't exist (or Cirrus can no longer see it).</summary>
    public async Task<GDriveFile?> GetAsync(string id, CancellationToken ct = default)
    {
        try { return new GDriveFile(await Api.JsonAsync("GET", Base + "/files/" + Uri.EscapeDataString(id), new Dictionary<string, string> { ["fields"] = FileFields }, ct: ct).ConfigureAwait(false)); }
        catch (GoogleException e) when (e.Kind == GoogleErrorKind.Http && e.Status == 404) { return null; }
    }

    internal static string Quote(string s) => "'" + s.Replace("\\", "\\\\").Replace("'", "\\'") + "'";

    /// <summary>Children of a folder that aren't in the trash ("root" = My Drive).</summary>
    public async Task<List<GDriveFile>> ChildrenAsync(string parentID, CancellationToken ct = default)
    {
        var output = new List<GDriveFile>();
        string? token = null;
        do
        {
            ct.ThrowIfCancellationRequested();
            var q = new Dictionary<string, string>
            {
                ["q"] = $"{Quote(parentID)} in parents and trashed = false", ["fields"] = $"nextPageToken,files({FileFields})", ["pageSize"] = "1000", ["spaces"] = "drive",
            };
            if (token is not null) q["pageToken"] = token;
            var j = await Api.JsonAsync("GET", Base + "/files", q, ct: ct).ConfigureAwait(false);
            output.AddRange(j["files"].Array.Select(f => new GDriveFile(f)));
            token = j["nextPageToken"].Str;
        } while (token is not null);
        return output;
    }

    static JsonObject Props(IReadOnlyDictionary<string, string> p)
    {
        var o = new JsonObject();
        foreach (var (k, v) in p) o[k] = v;
        return o;
    }

    /// <param name="properties">Public properties (visible to every app the user allows): only non-identifying markers.</param>
    public async Task<GDriveFile> CreateFolderAsync(string name, string parent, IReadOnlyDictionary<string, string>? appProperties = null, CancellationToken ct = default,
        IReadOnlyDictionary<string, string>? properties = null)
    {
        var body = new JsonObject { ["name"] = name, ["mimeType"] = FolderMime, ["parents"] = new JsonArray(parent) };
        if (appProperties is { Count: > 0 }) body["appProperties"] = Props(appProperties);
        if (properties is { Count: > 0 }) body["properties"] = Props(properties);
        return new GDriveFile(await Api.JsonAsync("POST", Base + "/files", new Dictionary<string, string> { ["fields"] = FileFields }, body, idempotent: false, ct: ct).ConfigureAwait(false));
    }

    /// <summary>Moves a file Cirrus created to Google Drive's trash (recoverable for 30 days). Cirrus never deletes permanently.</summary>
    public async Task TrashAsync(string id, CancellationToken ct = default) =>
        await Api.JsonAsync("PATCH", Base + "/files/" + Uri.EscapeDataString(id), new Dictionary<string, string> { ["fields"] = "id,trashed" },
            new JsonObject { ["trashed"] = true }, ct: ct).ConfigureAwait(false);

    public static string MimeType(string name) => Mime.ForName(name);

    internal static string Iso(DateTimeOffset d) => d.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);

    /// <summary>Opens a resumable upload session for a new file.</summary>
    public async Task<DriveUploadSession> StartUploadAsync(string name, string parent, long size, DateTimeOffset? modified,
        IReadOnlyDictionary<string, string>? appProperties = null, CancellationToken ct = default)
    {
        var meta = new JsonObject { ["name"] = name, ["parents"] = new JsonArray(parent) };
        if (modified is { } m) meta["modifiedTime"] = Iso(m);
        if (appProperties is { Count: > 0 }) meta["appProperties"] = Props(appProperties);
        var req = GoogleApi.Request("POST", UploadBase + "/files", new Dictionary<string, string> { ["uploadType"] = "resumable", ["fields"] = FileFields }, meta,
            new Dictionary<string, string> { ["X-Upload-Content-Type"] = MimeType(name), ["X-Upload-Content-Length"] = size.ToString(CultureInfo.InvariantCulture) });
        // A lost answer only leaves an unused session behind, so this is safe to retry.
        var r = await Api.SendAsync(req, idempotent: true, ct: ct).ConfigureAwait(false);
        if (r.Header("Location") is not { } loc || !Uri.TryCreate(loc, UriKind.Absolute, out _)) throw GoogleException.BadResponse("Google didn’t open an upload session.");
        return new DriveUploadSession(loc, size, DateTimeOffset.UtcNow);
    }

    public abstract record UploadStatus
    {
        public sealed record Incomplete(long Next) : UploadStatus;
        public sealed record Complete(GDriveFile File) : UploadStatus;
        public sealed record Expired : UploadStatus;
    }

    /// <summary>Next byte Google expects, from a 308's <c>Range: bytes=0-N</c> (no header = nothing stored yet).</summary>
    static long NextOffset(GoogleResponse r)
    {
        if (r.Header("Range") is not { } range) return 0;
        var dash = range.LastIndexOf('-');
        return dash >= 0 && long.TryParse(range[(dash + 1)..].Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var end) ? end + 1 : 0;
    }

    static GoogleRequest ChunkRequest(DriveUploadSession s, string contentRange, byte[] data) => new()
    {
        Method = "PUT", Url = s.Url, Body = new GoogleBody.Bytes(data),
        Headers = new(StringComparer.OrdinalIgnoreCase) { ["Content-Range"] = contentRange },
    };

    /// <summary>Asks Google how much of an interrupted upload it already has.</summary>
    public async Task<UploadStatus> StatusAsync(DriveUploadSession s, CancellationToken ct = default)
    {
        int attempt = 0;
        while (true)
        {
            GoogleResponse r;
            try { r = await Api.PerformAsync(ChunkRequest(s, $"bytes */{s.Total}", []), ct: ct).ConfigureAwait(false); }
            catch (Exception e) when (!ct.IsCancellationRequested && e is not GoogleException && GoogleHttp.IsTransient(e, true) && attempt < Api.MaxRetries)
            {
                attempt++;
                await Api.SleepAsync(Api.Delay(attempt, null), ct).ConfigureAwait(false);
                continue;
            }
            switch (r.Status)
            {
                case 200 or 201: return new UploadStatus.Complete(new GDriveFile(r.Json));
                case 308: return new UploadStatus.Incomplete(NextOffset(r));
                case 404 or 410: return new UploadStatus.Expired();
            }
            var v = GoogleApi.Classify(r.Status, r.Data, r.Header("Retry-After"));
            if (v is GoogleApi.Verdict.Retry rt && attempt < Api.MaxRetries)
            {
                attempt++;
                await Api.SleepAsync(Api.Delay(attempt, rt.After), ct).ConfigureAwait(false);
                continue;
            }
            if (v is GoogleApi.Verdict.Fail f) throw f.Error;
            throw GoogleException.Http(r.Status, "Couldn’t check the upload.");
        }
    }

    /// <summary>
    /// Sends the file in chunks. With <paramref name="resume"/>, first asks Google where an earlier attempt stopped.
    /// Network drops and 5xx/429 answers resume from Google's last stored byte; a gone session throws UploadExpired.
    /// </summary>
    public async Task<GDriveFile> UploadAsync(string file, DriveUploadSession s, bool resume, Action<long, long>? progress, CancellationToken ct = default)
    {
        if (ChunkSize % (256 * 1024) != 0) throw new InvalidOperationException("Drive chunks must be multiples of 256 KiB");
        long offset = 0;
        if (resume)
        {
            switch (await StatusAsync(s, ct).ConfigureAwait(false))
            {
                case UploadStatus.Complete c: progress?.Invoke(s.Total, s.Total); return c.File;
                case UploadStatus.Incomplete i: offset = i.Next; break;
                default: throw GoogleException.UploadExpired();
            }
        }
        await using var fh = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, useAsync: true);
        int failures = 0;
        async Task<GDriveFile?> Recover(double? after)
        {
            failures++;
            if (failures > Api.MaxRetries) throw GoogleException.RateLimited();
            await Api.SleepAsync(Api.Delay(failures, after), ct).ConfigureAwait(false);
            switch (await StatusAsync(s, ct).ConfigureAwait(false))
            {
                case UploadStatus.Complete c: return c.File;
                case UploadStatus.Incomplete i: offset = i.Next; return null;
                default: throw GoogleException.UploadExpired();
            }
        }
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            progress?.Invoke(offset, s.Total);
            var len = (int)Math.Min(ChunkSize, s.Total - offset);
            if (fh.Length != s.Total) throw GoogleException.BadResponse("The file changed while Cirrus was uploading it.");
            var data = new byte[Math.Max(0, len)];
            if (len > 0)
            {
                fh.Position = offset;
                try { await fh.ReadExactlyAsync(data, ct).ConfigureAwait(false); }
                catch (EndOfStreamException) { throw GoogleException.BadResponse("The file changed while Cirrus was uploading it."); }
            }
            var range = len > 0 ? $"bytes {offset}-{offset + len - 1}/{s.Total}" : $"bytes */{s.Total}";
            var b = offset;
            GoogleResponse r;
            try { r = await Api.PerformAsync(ChunkRequest(s, range, data), sent => progress?.Invoke(b + Math.Min(sent, len), s.Total), ct: ct).ConfigureAwait(false); }
            catch (Exception e) when (!ct.IsCancellationRequested && e is not GoogleException && GoogleHttp.IsTransient(e, true))
            {
                Log.Status($"google upload interrupted ({e.GetType().Name}); resuming");
                if (await Recover(null).ConfigureAwait(false) is { } f) return f;
                continue;
            }
            switch (r.Status)
            {
                case 200 or 201:
                    progress?.Invoke(s.Total, s.Total);
                    return new GDriveFile(r.Json);
                case 308:
                    var next = NextOffset(r);
                    if (next > offset) failures = 0;
                    offset = next;
                    continue;
                case 404 or 410:
                    throw GoogleException.UploadExpired();
            }
            switch (GoogleApi.Classify(r.Status, r.Data, r.Header("Retry-After")))
            {
                case GoogleApi.Verdict.Retry rt:
                    if (await Recover(rt.After).ConfigureAwait(false) is { } f) return f;
                    break;
                case GoogleApi.Verdict.Fail fl: throw fl.Error;
                default: throw GoogleException.BadResponse($"Unexpected answer from Google ({r.Status}).");
            }
        }
    }

    // MARK: Reading (drive.readonly)

    /// <summary>The real id of My Drive's root folder.</summary>
    public async Task<string> RootFolderIDAsync(CancellationToken ct = default) =>
        (await Api.JsonAsync("GET", Base + "/files/root", new Dictionary<string, string> { ["fields"] = "id" }, ct: ct).ConfigureAwait(false))["id"].Str ?? "root";

    /// <summary>
    /// Everything in My Drive (not in the trash), one paged listing. Items shared with the user but not added to My
    /// Drive have no parent inside it and are left out by the caller.
    /// </summary>
    public async Task<List<GDriveItem>> ListAllAsync(Action<int>? progress = null, CancellationToken ct = default)
    {
        var output = new List<GDriveItem>();
        string? token = null;
        do
        {
            ct.ThrowIfCancellationRequested();
            var q = new Dictionary<string, string> { ["q"] = "trashed = false", ["fields"] = $"nextPageToken,files({ReadFields})", ["pageSize"] = "1000", ["spaces"] = "drive" };
            if (token is not null) q["pageToken"] = token;
            var j = await Api.JsonAsync("GET", Base + "/files", q, ct: ct).ConfigureAwait(false);
            output.AddRange(j["files"].Array.Select(f => new GDriveItem(f)));
            token = j["nextPageToken"].Str;
            progress?.Invoke(output.Count);
        } while (token is not null);
        return output;
    }

    /// <summary>
    /// Downloads a file's bytes in ranged chunks; a dropped connection continues from what's on disk. Checks the MD5
    /// Google reports when there is one.
    /// </summary>
    public async Task DownloadAsync(GDriveItem item, string dest, Action<long, long>? progress, CancellationToken ct = default)
    {
        long total = item.Size ?? -1;
        await using (var fh = new FileStream(dest, FileMode.OpenOrCreate, FileAccess.Write, FileShare.None, 1 << 16, useAsync: true))
        {
            long have = fh.Length;
            fh.Position = have;
            int failures = 0;
            while (total < 0 || have < total)
            {
                ct.ThrowIfCancellationRequested();
                var end = total < 0 ? have + DownloadChunk - 1 : Math.Min(total, have + DownloadChunk) - 1;
                var req = GoogleApi.Request("GET", Base + "/files/" + Uri.EscapeDataString(item.Id), new Dictionary<string, string> { ["alt"] = "media" },
                    headers: new Dictionary<string, string> { ["Range"] = $"bytes={have}-{end}", ["Accept"] = "*/*" });
                GoogleResponse r;
                try { r = await Api.SendAsync(req, idempotent: true, ct: ct).ConfigureAwait(false); }
                catch (Exception e) when (!ct.IsCancellationRequested && e is not GoogleException && GoogleHttp.IsTransient(e, true) && failures < Api.MaxRetries)
                {
                    failures++;
                    await Api.SleepAsync(Api.Delay(failures, null), ct).ConfigureAwait(false);
                    continue;
                }
                if (r.Status == 200)
                {
                    // Range ignored: this is the whole file.
                    fh.SetLength(0);
                    fh.Position = 0;
                    await fh.WriteAsync(r.Data, ct).ConfigureAwait(false);
                    have = r.Data.Length;
                    progress?.Invoke(have, Math.Max(have, total));
                    break;
                }
                if (r.Status != 206) throw GoogleException.Http(r.Status, "Unexpected download answer.");
                if (r.Data.Length == 0) throw GoogleException.BadResponse($"Google sent no data for {item.Name}.");
                await fh.WriteAsync(r.Data, ct).ConfigureAwait(false);
                have += r.Data.Length;
                progress?.Invoke(have, total);
                if (total < 0 && r.Data.Length < DownloadChunk) break;
            }
            await fh.FlushAsync(ct).ConfigureAwait(false);
        }
        if (item.Md5 is { Length: > 0 } want && !string.Equals(await Md5HexAsync(dest, ct).ConfigureAwait(false), want, StringComparison.OrdinalIgnoreCase))
        {
            try { new FileStream(dest, FileMode.Truncate).Dispose(); } catch { }   // our own staging copy
            throw GoogleException.BadResponse("The download didn’t match Google’s checksum; it will be tried again on the next run.");
        }
    }

    /// <summary>Exports a Google Docs/Sheets/Slides file. Returns the bytes written.</summary>
    public async Task<long> ExportAsync(GDriveItem item, GoogleDocTarget target, string dest, CancellationToken ct = default)
    {
        await using var fs = new FileStream(dest, FileMode.Create, FileAccess.ReadWrite, FileShare.None, 1 << 16, useAsync: true);
        var req = GoogleApi.Request("GET", Base + "/files/" + Uri.EscapeDataString(item.Id) + "/export", new Dictionary<string, string> { ["mimeType"] = target.Mime },
            headers: new Dictionary<string, string> { ["Accept"] = "*/*" });
        try { await Api.SendAsync(req, idempotent: true, sink: fs, ct: ct).ConfigureAwait(false); }
        catch (GoogleException e) when (e.Kind == GoogleErrorKind.Http && e.Status is 400 or 403 or 413
                                        && (e.Detail.Contains("too large", StringComparison.OrdinalIgnoreCase) || e.Detail.Contains("exportsizelimit", StringComparison.OrdinalIgnoreCase))
                                        && item.ExportLinks.TryGetValue(target.Mime, out var link) && Uri.TryCreate(link, UriKind.Absolute, out var u) && u.Scheme == "https")
        {
            // Too big for files.export: use the document's export link instead.
            fs.SetLength(0);
            fs.Position = 0;
            var big = new GoogleRequest { Method = "GET", Url = u.AbsoluteUri, Headers = new(StringComparer.OrdinalIgnoreCase) { ["Accept"] = "*/*" } };
            await Api.SendAsync(big, idempotent: true, sink: fs, ct: ct).ConfigureAwait(false);
        }
        await fs.FlushAsync(ct).ConfigureAwait(false);
        return fs.Length;
    }

    internal static async Task<string> Md5HexAsync(string path, CancellationToken ct = default)
    {
        await using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, useAsync: true);
        return Convert.ToHexStringLower(await MD5.HashDataAsync(fs, ct).ConfigureAwait(false));
    }
}
