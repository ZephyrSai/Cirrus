using System.Globalization;
using System.Text.Json.Nodes;

namespace Cirrus.Core;

// Uploads (port of OneDriveUpload.swift): small files in one PUT, larger ones through an upload session (fragments that are
// multiples of 320 KiB, resumed from the session's nextExpectedRanges after failures). Always conflictBehavior=fail: Cirrus
// chooses free names itself, so OneDrive must never replace or rename behind its back.

public sealed partial class OneDriveBackend
{
    public async Task<DriveNode> UploadAsync(string file, string name, string folderID, DateTimeOffset? modified, Action<long, long>? progress,
        CancellationToken ct = default)
    {
        var n = CheckName(name);
        var info = new FileInfo(file);
        if (!info.Exists) throw CloudException.Server($"Cirrus couldn’t read “{n}” to upload it.");
        var size = info.Length;
        if (size > MaxFileSize) throw CloudException.Denied($"“{n}” is {size.ByteString()}, larger than OneDrive’s 250 GB file limit.");
        var report = progress ?? ((_, _) => { });
        var target = OneDriveRef.Parse(folderID).ContentPath + ":/" + EncodeName(n);
        return await OneDriveHttp.Guarded(async () =>
        {
            if (size > SimpleUploadLimit) return await SessionUploadAsync(file, n, size, target, folderID, modified, report, ct).ConfigureAwait(false);
            var node = await SimpleUploadAsync(file, n, size, target, folderID, report, ct).ConfigureAwait(false);
            // A one-request upload can't carry the file's date; set it afterwards (best effort: the file is there).
            if (modified is not { } m) return node;
            try { return await SetModifiedAsync(node, m, ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { throw; }
            catch (Exception)
            {
                Log.Status("onedrive: couldn’t set the modification date after upload");
                return node;
            }
        }).ConfigureAwait(false);
    }

    async Task<DriveNode> SetModifiedAsync(DriveNode n, DateTimeOffset date, CancellationToken ct)
    {
        var j = await Http.JsonAsync("PATCH", OneDriveRef.Parse(n.Id).SelfPath,
            body: new JsonObject { ["fileSystemInfo"] = new JsonObject { ["lastModifiedDateTime"] = Iso(date) } }, name: n.Name, ct: ct).ConfigureAwait(false);
        var output = n.Copy();
        output.Modified = j["fileSystemInfo"]["lastModifiedDateTime"].Date ?? date;
        output.Etag = j["eTag"].Str ?? n.Etag;
        return output;
    }

    async Task<DriveNode> SimpleUploadAsync(string file, string name, long size, string target, string folderID, Action<long, long> progress,
        CancellationToken ct)
    {
        var started = DateTimeOffset.UtcNow;
        var req = GraphRequest.Make("PUT", OneDriveHttp.Graph + target + ":/content", [("@microsoft.graph.conflictBehavior", "fail")])
            .With(new OneDriveBody.File(file), new Dictionary<string, string> { ["Content-Type"] = "application/octet-stream" });
        int failures = 0;
        bool ambiguous = false;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            progress(0, size);
            GraphResponse r;
            try
            {
                r = await Http.SendAsync(req, retry: GraphRetry.Unsafe, sent: s => progress(Math.Min(s, size), size), ct: ct).ConfigureAwait(false);
            }
            catch (Exception e) when (!ct.IsCancellationRequested && e is not OperationCanceledException && OneDriveHttp.IsNetwork(e)
                                      && GoogleHttp.IsTransient(e, ambiguousOK: true) && failures < Http.MaxRetries)
            {
                // The answer was lost, but the file may have landed: look before sending it again.
                failures++;
                ambiguous = true;
                await OneDriveHttp.SleepAsync(Http.Delay(failures, null), ct).ConfigureAwait(false);
                if (await LandedAsync(target, size, started, folderID, ct).ConfigureAwait(false) is { } done) { progress(size, size); return done; }
                continue;
            }
            if (r.Status == 409 && ambiguous && await LandedAsync(target, size, started, folderID, ct).ConfigureAwait(false) is { } landed)
            {
                progress(size, size);
                return landed;
            }
            if (!r.Ok) throw OneDriveHttp.Error(r, name);
            var node = Node(r.Json, folderID) ?? throw CloudException.Server($"OneDrive didn’t confirm the upload of “{name}”.");
            progress(size, size);
            return node;
        }
    }

    /// <summary>
    /// After a lost answer: did the upload land anyway? Same name, same size, created since this upload began. (With
    /// conflictBehavior=fail nothing of that name existed when it began, or the first try had failed.)
    /// </summary>
    async Task<DriveNode?> LandedAsync(string target, long size, DateTimeOffset since, string folderID, CancellationToken ct)
    {
        var r = await Http.SendAsync(GraphRequest.Make("GET", OneDriveHttp.Graph + target, [("$select", Select)]), ct: ct).ConfigureAwait(false);
        if (r.Status != 200 || Node(r.Json, folderID) is not { IsFolder: false } n || n.Size != size) return null;
        if (r.Json["createdDateTime"].Date is not { } created || created < since.AddSeconds(-300)) return null;
        return n;
    }

    /// <summary>Where an upload session wants the next byte (no Authorization header: the URL is pre-authenticated). Null: the session is gone.</summary>
    async Task<long?> SessionStatusAsync(string url, CancellationToken ct)
    {
        var r = await Http.SendAsync(new GraphRequest { Method = "GET", Url = url }, auth: false, ct: ct).ConfigureAwait(false);
        if (r.Status is 404 or 410) return null;
        if (!r.Ok) throw OneDriveHttp.Error(r);
        return NextOffset(r.Json);
    }

    /// <summary>The start of the first missing range, from <c>nextExpectedRanges</c> (["12345-"] or ["0-999", "2000-"]).</summary>
    internal static long? NextOffset(J j)
    {
        if (j["nextExpectedRanges"][0].Str is not { } first) return null;
        var dash = first.IndexOf('-');
        if (dash < 0) return null;
        return long.TryParse(first[..dash], NumberStyles.None, CultureInfo.InvariantCulture, out var o) ? o : null;
    }

    async Task<DriveNode> SessionUploadAsync(string file, string name, long size, string target, string folderID, DateTimeOffset? modified,
        Action<long, long> progress, CancellationToken ct)
    {
        var started = DateTimeOffset.UtcNow;
        var item = new JsonObject { ["@microsoft.graph.conflictBehavior"] = "fail", ["name"] = name, ["fileSize"] = size };
        if (modified is { } m) item["fileSystemInfo"] = new JsonObject { ["lastModifiedDateTime"] = Iso(m) };
        // A lost answer here only leaves an unused session behind (it expires), so this is safe to retry.
        var created = await Http.JsonAsync("POST", target + ":/createUploadSession", body: new JsonObject { ["item"] = item }, name: name, ct: ct)
            .ConfigureAwait(false);
        if (created["uploadUrl"].Str is not { } link || !Uri.TryCreate(link, UriKind.Absolute, out var uploadURL) || uploadURL.Scheme != Uri.UriSchemeHttps)
            throw CloudException.Server($"OneDrive didn’t open an upload for “{name}”. Try again.");
        var url = uploadURL.AbsoluteUri;
        long unit = FragmentUnit;
        var fragment = Math.Max(unit, ChunkSize / unit * unit);
        var offset = NextOffset(created) ?? 0;
        int failures = 0;
        try
        {
            await using var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, useAsync: true);
            while (true)
            {
                ct.ThrowIfCancellationRequested();
                var len = Math.Min(fragment, size - offset);
                if (len <= 0) throw CloudException.Server($"OneDrive’s upload of “{name}” got out of step. Try again.");
                var data = new byte[len];
                fs.Position = offset;
                int read = 0;
                while (read < len)
                {
                    var got = await fs.ReadAsync(data.AsMemory(read), ct).ConfigureAwait(false);
                    if (got <= 0) break;
                    read += got;
                }
                if (read != len) throw CloudException.Server($"“{name}” changed while Cirrus was uploading it. Try again.");
                var req = new GraphRequest
                {
                    Method = "PUT", Url = url, Body = new OneDriveBody.Bytes(data),
                    Headers = new(StringComparer.OrdinalIgnoreCase) { ["Content-Range"] = $"bytes {offset}-{offset + len - 1}/{size}" },
                };
                var start = offset;
                var isLast = offset + len == size;
                progress(start, size);
                GraphResponse r;
                try
                {
                    // Pre-authenticated: never with the Authorization header (OneDrive answers 401 to it).
                    r = await Http.TransportAsync(req, sent: s => progress(start + Math.Min(s, len), size), ct: ct).ConfigureAwait(false);
                }
                catch (Exception e) when (!ct.IsCancellationRequested && e is not OperationCanceledException && OneDriveHttp.IsNetwork(e)
                                          && GoogleHttp.IsTransient(e, ambiguousOK: true))
                {
                    failures++;
                    if (failures > Http.MaxRetries) throw;
                    Log.Status($"onedrive upload interrupted ({e.GetType().Name}); resuming");
                    await OneDriveHttp.SleepAsync(Http.Delay(failures, null), ct).ConfigureAwait(false);
                    var (done, at) = await ResumeAsync(url, isLast, target, size, started, folderID, name, ct).ConfigureAwait(false);
                    if (done is not null) { progress(size, size); return done; }
                    offset = at;
                    continue;
                }
                switch (r.Status)
                {
                    case 200 or 201:
                    {
                        var node = Node(r.Json, folderID) ?? throw CloudException.Server($"OneDrive didn’t confirm the upload of “{name}”.");
                        progress(size, size);
                        return node;
                    }
                    case 202:
                    {
                        var next = NextOffset(r.Json) ?? offset + len;
                        if (next > offset) failures = 0;
                        offset = next;
                        break;
                    }
                    case 416 or 429 or 500 or 502 or 503 or 504 or 509:
                    {
                        // 416: OneDrive already has (part of) this range. Otherwise busy: wait, then ask where to go on.
                        failures++;
                        if (failures > Http.MaxRetries) throw OneDriveHttp.Error(r, name);
                        if (r.Status != 416) await OneDriveHttp.SleepAsync(Http.Delay(failures, r.RetryAfter), ct).ConfigureAwait(false);
                        var (done, at) = await ResumeAsync(url, isLast, target, size, started, folderID, name, ct).ConfigureAwait(false);
                        if (done is not null) { progress(size, size); return done; }
                        offset = at;
                        break;
                    }
                    case 401 or 403 or 404 or 410:
                    {
                        // The session is gone (finished, expired, or its pre-authenticated URL no longer valid).
                        if (isLast && await LandedAsync(target, size, started, folderID, ct).ConfigureAwait(false) is { } landed)
                        {
                            progress(size, size);
                            return landed;
                        }
                        throw CloudException.Server($"OneDrive ended the upload of “{name}” before it finished. Try again.");
                    }
                    default:
                        throw OneDriveHttp.Error(r, name);
                }
            }
        }
        catch
        {
            // Free the half-finished upload on OneDrive (best effort, never with the sign-in), even when the transfer was cancelled.
            await CancelSessionAsync(url).ConfigureAwait(false);
            throw;
        }
    }

    /// <summary>Continues from where the session says it is; returns the item if the last fragment had in fact landed.</summary>
    async Task<(DriveNode? Done, long Offset)> ResumeAsync(string url, bool isLast, string target, long size, DateTimeOffset since, string folderID,
        string name, CancellationToken ct)
    {
        if (await SessionStatusAsync(url, ct).ConfigureAwait(false) is { } next) return (null, next);
        if (isLast && await LandedAsync(target, size, since, folderID, ct).ConfigureAwait(false) is { } n) return (n, size);
        throw CloudException.Server($"OneDrive ended the upload of “{name}” before it finished. Try again.");
    }

    async Task CancelSessionAsync(string url)
    {
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            await Http.TransportAsync(new GraphRequest { Method = "DELETE", Url = url }, ct: cts.Token).ConfigureAwait(false);
        }
        catch { }
    }
}
