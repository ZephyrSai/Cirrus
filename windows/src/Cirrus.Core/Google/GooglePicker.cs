using System.Globalization;
using System.Text.Json.Nodes;

namespace Cirrus.Core;

/// <summary>A photo the user picked with Google Photos' picker (see <see cref="GooglePicker"/>).</summary>
public sealed record GooglePickedItem(string Id, string FileName, string MimeType, string BaseURL, DateTimeOffset? Created, bool IsVideo);

/// <summary>
/// Google Photos Picker API (port of GooglePicker.swift): the user picks photos in Google's own picker (in the browser);
/// Cirrus then reads just those. The way to get specific Google Photos items since the 2025 API changes.
/// </summary>
public sealed class GooglePicker
{
    public const string Base = "https://photospicker.googleapis.com/v1";

    public sealed record Session(string Id, Uri PickerURL, double PollInterval, double Timeout, bool ItemsSet);

    readonly GoogleApi _api;
    public GooglePicker(GoogleApi api) { _api = api; }

    /// <summary>"5s" / "1800.5s" → seconds.</summary>
    static double? Seconds(J j) =>
        j.Str is { } s && double.TryParse(s.Replace("s", ""), NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? d : j.Double;

    static Session Parse(J j)
    {
        if (j["id"].Str is not { } id || j["pickerUri"].Str is not { } uri || !Uri.TryCreate(uri, UriKind.Absolute, out var u) || u.Scheme != Uri.UriSchemeHttps)
            throw GoogleException.BadResponse("Google Photos didn’t open a picker.");
        return new Session(id, u, Seconds(j["pollingConfig"]["pollInterval"]) ?? 5, Seconds(j["pollingConfig"]["timeoutIn"]) ?? 1800, j["mediaItemsSet"].Bool ?? false);
    }

    public async Task<Session> CreateAsync(int maxItems = 2000, CancellationToken ct = default) =>
        Parse(await _api.JsonAsync("POST", Base + "/sessions", body: new JsonObject { ["pickingConfig"] = new JsonObject { ["maxItemCount"] = maxItems.ToString(CultureInfo.InvariantCulture) } },
            idempotent: false, ct: ct).ConfigureAwait(false));

    public async Task<Session> GetAsync(string id, CancellationToken ct = default) =>
        Parse(await _api.JsonAsync("GET", Base + "/sessions/" + Uri.EscapeDataString(id), ct: ct).ConfigureAwait(false));

    public async Task DeleteAsync(string id)
    {
        try { await _api.SendAsync(GoogleApi.Request("DELETE", Base + "/sessions/" + Uri.EscapeDataString(id)), idempotent: true).ConfigureAwait(false); }
        catch (Exception e) { Log.Status("couldn’t close a Google Photos picker session: " + e.GetType().Name); }
    }

    /// <summary>The picker page; "/autoclose" closes it once the user is done.</summary>
    public static Uri BrowserURL(Session s) => new(s.PickerURL.AbsoluteUri.TrimEnd('/') + "/autoclose");

    /// <summary>Polls (at Google's suggested interval) until the user finished picking, or the session timed out.</summary>
    public async Task<Session> WaitForPickAsync(Session s, CancellationToken ct = default)
    {
        var deadline = DateTimeOffset.UtcNow.AddSeconds(s.Timeout);
        var cur = s;
        while (!cur.ItemsSet)
        {
            ct.ThrowIfCancellationRequested();
            if (DateTimeOffset.UtcNow >= deadline) throw GoogleException.TimedOut();
            await Task.Delay(TimeSpan.FromSeconds(Math.Max(0.05, cur.PollInterval)), ct).ConfigureAwait(false);
            cur = await GetAsync(s.Id, ct).ConfigureAwait(false);
        }
        return cur;
    }

    public async Task<List<GooglePickedItem>> ItemsAsync(string sessionID, CancellationToken ct = default)
    {
        var output = new List<GooglePickedItem>();
        string? token = null;
        do
        {
            var q = new Dictionary<string, string> { ["sessionId"] = sessionID, ["pageSize"] = "100" };
            if (token is not null) q["pageToken"] = token;
            var j = await _api.JsonAsync("GET", Base + "/mediaItems", q, ct: ct).ConfigureAwait(false);
            foreach (var i in j["mediaItems"].Array)
            {
                if (i["id"].Str is not { } id || i["mediaFile"]["baseUrl"].Str is not { } url) continue;
                // Videos are transcoded by Google; skip ones still processing (pick them again later).
                if (i["mediaFile"]["mediaFileMetadata"]["videoMetadata"]["processingStatus"].Str is { } st && st != "READY") continue;
                var mime = i["mediaFile"]["mimeType"].Str ?? "";
                var video = i["type"].Str == "VIDEO" || mime.StartsWith("video/", StringComparison.Ordinal);
                output.Add(new GooglePickedItem(id, i["mediaFile"]["filename"].Str ?? id + (video ? ".mp4" : ".jpg"), mime, url, i["createTime"].Date, video));
            }
            token = j["nextPageToken"].Str;
        } while (token is not null);
        return output;
    }

    /// <summary>
    /// "=d": the photo with its metadata (Google removes the location). "=dv": Google's high-quality transcode of a video,
    /// not the original. Base URLs last about an hour and need the access token (sent only to Google's hosts).
    /// </summary>
    public async Task DownloadAsync(GooglePickedItem item, string dest, CancellationToken ct = default)
    {
        if (!Uri.TryCreate(item.BaseURL + (item.IsVideo ? "=dv" : "=d"), UriKind.Absolute, out var u) || u.Scheme != Uri.UriSchemeHttps)
            throw GoogleException.BadResponse("Bad download link from Google Photos.");
        await using var fs = new FileStream(dest, FileMode.Create, FileAccess.ReadWrite, FileShare.None, 1 << 16, useAsync: true);
        var req = new GoogleRequest { Method = "GET", Url = u.AbsoluteUri, Headers = new(StringComparer.OrdinalIgnoreCase) { ["Accept"] = "*/*" } };
        await _api.SendAsync(req, idempotent: true, sink: fs, ct: ct).ConfigureAwait(false);
    }
}
