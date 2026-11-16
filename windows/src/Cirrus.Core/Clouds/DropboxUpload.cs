using System.Security.Cryptography;
using System.Text.Json.Nodes;

namespace Cirrus.Core;

// Uploads (port of DropboxUpload.swift): small files in one files/upload request; larger ones through an upload session
// (start, append chunks, finish), resumed after interruptions from the offset Dropbox reports (incorrect_offset carries
// correct_offset). Always mode "add" with autorename off and strict conflicts: Cirrus chooses free names itself, so
// Dropbox must never replace, rename, or quietly reuse an identical file behind its back. The commit (the one-request
// upload, or finish) goes through the write gate; appending data doesn't need to.

public sealed partial class DropboxBackend
{
    public async Task<DriveNode> UploadAsync(string file, string name, string folderID, DateTimeOffset? modified, Action<long, long>? progress,
        CancellationToken ct = default)
    {
        name = CheckName(name);
        long size;
        try { size = new FileInfo(file).Length; } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { size = -1; }
        if (size < 0) throw CloudException.Server($"Cirrus couldn’t read “{name}” to upload it.");
        if (size > MaxFileSize) throw CloudException.Denied($"“{name}” is {size.ByteString()}, larger than the 350 GB Dropbox accepts from apps.");
        var report = progress ?? ((_, _) => { });
        return await DropboxHttp.Guarded(async () =>
        {
            var parent = await FolderPathAsync(folderID, ct).ConfigureAwait(false);
            var path = parent.Display + "/" + name;
            var commit = new JsonObject { ["path"] = path, ["mode"] = "add", ["autorename"] = false, ["mute"] = false, ["strict_conflict"] = true };
            if (modified is { } m) commit["client_modified"] = Timestamp(m);
            var limit = Math.Min(Math.Max(SimpleUploadLimit, 0), MaxSimpleUpload);
            var j = size <= limit
                ? await SimpleUploadAsync(file, name, size, commit, report, ct).ConfigureAwait(false)
                : await SessionUploadAsync(file, name, size, commit, report, ct).ConfigureAwait(false);
            var n = Node(j, folderID, "file") ?? throw CloudException.Server($"Dropbox didn’t confirm the upload of “{name}”.");
            report(size, size);
            return n;
        }).ConfigureAwait(false);
    }

    async Task<J> SimpleUploadAsync(string file, string name, long size, JsonObject commit, Action<long, long> progress, CancellationToken ct)
    {
        var req = DropboxHttp.ContentRequest("files/upload", commit, upload: true, new DropboxBody.File(file));
        var path = commit["path"]!.GetValue<string>();
        int failures = 0;
        bool ambiguous = false;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            progress(0, size);
            DropboxResponse r;
            try
            {
                r = await Writes.RunAsync(() => Http.SendAsync(req, DropboxRetry.Unsafe, sent: s => progress(Math.Min(s, size), size), ct: ct), ct)
                    .ConfigureAwait(false);
            }
            catch (Exception e) when (!ct.IsCancellationRequested && e is not CloudException && GoogleHttp.IsTransient(e, ambiguousOK: true)
                                      && failures < Http.MaxRetries)
            {
                // The answer was lost, but the file may have landed: look before sending it again.
                failures++;
                ambiguous = true;
                await DropboxHttp.SleepAsync(Http.Delay(failures, null), ct).ConfigureAwait(false);
                if (await LandedAsync(path, file, size, ct).ConfigureAwait(false) is { } got) return got;
                continue;
            }
            if (r.Ok) return r.Json;
            if (r.Status is >= 500 and <= 599 && failures < Http.MaxRetries)
            {
                failures++;
                ambiguous = true;
                await DropboxHttp.SleepAsync(Http.Delay(failures, null), ct).ConfigureAwait(false);
                if (await LandedAsync(path, file, size, ct).ConfigureAwait(false) is { } got) return got;
                continue;
            }
            if (r.Status == 409 && ambiguous && await LandedAsync(path, file, size, ct).ConfigureAwait(false) is { } j) return j;
            throw DropboxHttp.Error(r, name);
        }
    }

    /// <summary>
    /// After a lost answer: did the upload land anyway? A file at the path with the same size and the same Dropbox content
    /// hash is this upload (or one byte-for-byte equal to it).
    /// </summary>
    async Task<J?> LandedAsync(string path, string file, long size, CancellationToken ct)
    {
        if (await MetadataAsync(path, ct).ConfigureAwait(false) is not { } m || m[".tag"].Str != "file" || m["size"].Int64 != size
            || m["content_hash"].Str is not { } remote) return null;
        return remote == ContentHash(file) ? m : null;
    }

    /// <summary>Dropbox's content hash: SHA-256 of the concatenated SHA-256 digests of each 4 MiB block, as hex.</summary>
    internal static string ContentHash(string file)
    {
        using var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16);
        const int block = 4 * 1024 * 1024;
        var buf = new byte[block];
        using var digests = new MemoryStream();
        while (true)
        {
            var n = fs.ReadAtLeast(buf, block, throwOnEndOfStream: false);
            if (n == 0) break;
            digests.Write(SHA256.HashData(buf.AsSpan(0, n)));
            if (n < block) break;
        }
        return Convert.ToHexStringLower(SHA256.HashData(digests.ToArray()));
    }

    /// <summary>Where Dropbox says the session is, from an incorrect_offset error (append_v2, or finish's lookup_failed).</summary>
    internal static long? CorrectOffset(J j)
    {
        var e = j["error"];
        if (e[".tag"].Str == "incorrect_offset") return e["correct_offset"].Int64;
        if (e[".tag"].Str == "lookup_failed" && e["lookup_failed"][".tag"].Str == "incorrect_offset") return e["lookup_failed"]["correct_offset"].Int64;
        return null;
    }

    async Task<J> SessionUploadAsync(string file, string name, long size, JsonObject commit, Action<long, long> progress, CancellationToken ct)
    {
        var path = commit["path"]!.GetValue<string>();
        // A lost answer here only leaves an unused session behind (they expire), so this is safe to retry.
        var started = await Http.SendAsync(DropboxHttp.ContentRequest("files/upload_session/start", new JsonObject { ["close"] = false }, upload: true),
            DropboxRetry.Safe, ct: ct).ConfigureAwait(false);
        if (!started.Ok) throw DropboxHttp.Error(started, name);
        if (started.Json["session_id"].Str is not { Length: > 0 } sid) throw CloudException.Server($"Dropbox didn’t open an upload for “{name}”. Try again.");
        var chunk = Math.Max(4096, Math.Min((long)ChunkSize, MaxSimpleUpload));
        await using var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, useAsync: true);
        long offset = 0;
        int failures = 0;
        async Task BackOffAsync(Exception e)
        {
            failures++;
            if (failures > Http.MaxRetries) throw e;
            await DropboxHttp.SleepAsync(Http.Delay(failures, null), ct).ConfigureAwait(false);
        }
        while (offset < size)
        {
            ct.ThrowIfCancellationRequested();
            var len = Math.Min(chunk, size - offset);
            fs.Seek(offset, SeekOrigin.Begin);
            var data = new byte[len];
            var read = await fs.ReadAtLeastAsync(data, (int)len, throwOnEndOfStream: false, ct).ConfigureAwait(false);
            if (read != len) throw CloudException.Server($"“{name}” changed while Cirrus was uploading it. Try again.");
            var at = offset;
            progress(at, size);
            var arg = new JsonObject { ["cursor"] = new JsonObject { ["session_id"] = sid, ["offset"] = offset }, ["close"] = false };
            DropboxResponse r;
            try
            {
                r = await Http.SendAsync(DropboxHttp.ContentRequest("files/upload_session/append_v2", arg, upload: true, new DropboxBody.Bytes(data)),
                    DropboxRetry.Unsafe, sent: s => progress(at + Math.Min(s, len), size), ct: ct).ConfigureAwait(false);
            }
            catch (Exception e) when (!ct.IsCancellationRequested && e is not CloudException && GoogleHttp.IsTransient(e, ambiguousOK: true))
            {
                // Send the same chunk again: if Dropbox did get it, it answers with the offset it has.
                Log.Status($"dropbox upload interrupted ({e.GetType().Name}); resuming");
                await BackOffAsync(e).ConfigureAwait(false);
                continue;
            }
            if (r.Ok)
            {
                offset += len;
                failures = 0;
            }
            else if (r.Status == 409)
            {
                if (CorrectOffset(r.Json) is not { } correct)
                {
                    if (r.Summary.Contains("not_found", StringComparison.Ordinal))
                        throw CloudException.Server($"Dropbox ended the upload of “{name}” before it finished. Try again.");
                    throw DropboxHttp.Error(r, name);
                }
                if (correct < 0 || correct > size) throw CloudException.Server($"Dropbox’s upload of “{name}” got out of step. Try again.");
                if (correct <= offset) await BackOffAsync(DropboxHttp.Error(r, name)).ConfigureAwait(false);   // no progress: don't loop forever
                offset = correct;
            }
            else if (r.Status is >= 500 and <= 599) await BackOffAsync(DropboxHttp.Error(r, name)).ConfigureAwait(false);
            else throw DropboxHttp.Error(r, name);
        }
        progress(size, size);
        // Every byte is there: finishing only commits it.
        var finishArg = new JsonObject { ["cursor"] = new JsonObject { ["session_id"] = sid, ["offset"] = size }, ["commit"] = commit.DeepClone() };
        var req = DropboxHttp.ContentRequest("files/upload_session/finish", finishArg, upload: true);
        var ambiguous = false;
        failures = 0;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            DropboxResponse r;
            try
            {
                r = await Writes.RunAsync(() => Http.SendAsync(req, DropboxRetry.Unsafe, ct: ct), ct).ConfigureAwait(false);
            }
            catch (Exception e) when (!ct.IsCancellationRequested && e is not CloudException && GoogleHttp.IsTransient(e, ambiguousOK: true))
            {
                ambiguous = true;
                await BackOffAsync(e).ConfigureAwait(false);
                if (await LandedAsync(path, file, size, ct).ConfigureAwait(false) is { } got) return got;
                continue;
            }
            if (r.Ok) return r.Json;
            if (r.Status is >= 500 and <= 599)
            {
                ambiguous = true;
                await BackOffAsync(DropboxHttp.Error(r, name)).ConfigureAwait(false);
                if (await LandedAsync(path, file, size, ct).ConfigureAwait(false) is { } got) return got;
                continue;
            }
            if (r.Status == 409)
            {
                if (ambiguous && await LandedAsync(path, file, size, ct).ConfigureAwait(false) is { } got) return got;
                if (CorrectOffset(r.Json) is { } correct && correct != size)
                    throw CloudException.Server($"Dropbox’s upload of “{name}” got out of step. Try again.");
            }
            throw DropboxHttp.Error(r, name);
        }
    }
}
