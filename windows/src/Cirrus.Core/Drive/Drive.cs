using System.IO.Compression;
using System.Text;
using System.Text.Json.Nodes;

namespace Cirrus.Core;

public sealed class DriveNode : IEquatable<DriveNode>
{
    public string Id { get; set; } = "";            // drivewsid: TYPE::zone::docid
    public string? DocID { get; set; }
    public string Zone { get; set; } = "";
    public string? ParentID { get; set; }
    public string Name { get; set; } = "";          // full name including extension
    public string Type { get; set; } = "FILE";      // FILE, FOLDER, APP_LIBRARY, APP_CONTAINER
    public long Size { get; set; }
    public DateTimeOffset? Modified { get; set; }
    public DateTimeOffset? Created { get; set; }
    public string? Etag { get; set; }
    public int? ChildCount { get; set; }
    public bool IsShared { get; set; }

    public bool IsFolder => Type != "FILE";
    public bool IsAppLibrary => Type is "APP_LIBRARY" or "APP_CONTAINER";
    /// <summary>Listed from Recently Deleted (the only place Delete Immediately is allowed).</summary>
    public bool IsInTrash => ParentID == "TRASH_ROOT" || Id.StartsWith("TRASH::", StringComparison.Ordinal);

    public DriveNode Copy() => (DriveNode)MemberwiseClone();

    public bool Equals(DriveNode? o) => o is not null && Id == o.Id && Etag == o.Etag && Name == o.Name;
    public override bool Equals(object? obj) => Equals(obj as DriveNode);
    public override int GetHashCode() => Id.GetHashCode();
}

public interface IDriveBackend
{
    string RootID { get; }
    Task<List<DriveNode>> ListAsync(string folderID, CancellationToken ct = default);
    Task<Dictionary<string, List<DriveNode>>> ListManyAsync(IReadOnlyList<string> folderIDs, CancellationToken ct = default);
    Task DownloadAsync(DriveNode node, string destination, Action<long, long>? progress, CancellationToken ct = default);
    Task<DriveNode> UploadAsync(string file, string name, string folderID, DateTimeOffset? modified, Action<long, long>? progress, CancellationToken ct = default);
    Task<DriveNode> CreateFolderAsync(string name, string folderID, CancellationToken ct = default);
    Task<DriveNode> RenameAsync(DriveNode node, string name, CancellationToken ct = default);
    Task MoveAsync(IReadOnlyList<DriveNode> nodes, string folderID, CancellationToken ct = default);
    /// <summary>Moves to Recently Deleted (recoverable for 30 days).</summary>
    Task TrashAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default);
    Task<List<DriveNode>> ListTrashAsync(CancellationToken ct = default);
    Task RestoreAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default);
    /// <summary>The one permanent removal: only for items already in Recently Deleted (UI confirms first).</summary>
    Task DeleteForeverAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default);
}

public static class DriveBackendExtensions
{
    /// <summary>Recursively walk a folder (breadth-first, batched). Returns relative path → node.</summary>
    public static async Task<List<(string Path, DriveNode Node)>> WalkAsync(this IDriveBackend drive, string rootFolderID, Action<int>? progress = null, CancellationToken ct = default)
    {
        var output = new List<(string, DriveNode)>();
        var frontier = new List<(string Id, string Prefix)> { (rootFolderID, "") };
        while (frontier.Count > 0)
        {
            ct.ThrowIfCancellationRequested();
            var batch = frontier.Take(16).ToList();
            frontier.RemoveRange(0, batch.Count);
            var listed = await drive.ListManyAsync(batch.Select(b => b.Id).ToList(), ct).ConfigureAwait(false);
            foreach (var (fid, prefix) in batch)
            {
                // A folder missing from the answer must not look empty (that would read as "everything deleted").
                if (!listed.TryGetValue(fid, out var items))
                    throw ICloudException.Server($"iCloud Drive didn’t list “{(prefix.Length == 0 ? "iCloud Drive" : prefix)}”. Nothing was changed; try again.");
                foreach (var node in items)
                {
                    var rel = prefix.Length == 0 ? node.Name : prefix + "/" + node.Name;
                    output.Add((rel, node));
                    if (node.IsFolder) frontier.Add((node.Id, rel));
                }
            }
            progress?.Invoke(output.Count);
        }
        return output;
    }

    internal static void GuardTrashOnly(IReadOnlyList<DriveNode> nodes)
    {
        if (nodes.Any(n => !n.IsInTrash))
            throw new InvalidOperationException("Only items in Recently Deleted can be deleted immediately.");
    }
}

/// <summary>iCloud Drive via iCloud.com web services (drivews + docws). Port of Drive.swift.</summary>
public sealed class WebDrive : IDriveBackend
{
    public ICloudSession Session { get; }
    public string RootID => "FOLDER::com.apple.CloudDocs::root";
    static readonly (string app, string ws) Pcs = ("iclouddrive", "drivews");

    public WebDrive(ICloudSession session) { Session = session; }

    string Drivews() => Session.WebserviceURL("drivews") ?? throw ICloudException.Unavailable("iCloud Drive");
    string Docws() => Session.WebserviceURL("docws") ?? throw ICloudException.Unavailable("iCloud Drive");

    internal static (string Type, string Zone, string Doc) Parts(string drivewsid)
    {
        var s = drivewsid.Split("::");
        if (s.Length >= 3) return (s[0], s[1], string.Join("::", s.Skip(2)));
        return ("", "com.apple.CloudDocs", drivewsid);
    }

    internal static DriveNode? Node(J j, string? parent)
    {
        if (j["drivewsid"].Str is not string id) return null;
        var type = j["type"].Str ?? (id.StartsWith("FILE", StringComparison.Ordinal) ? "FILE" : "FOLDER");
        var name = (j["name"].Str ?? "").Normalize(NormalizationForm.FormC);
        if (j["extension"].Str is { Length: > 0 } ext && type == "FILE") name += "." + ext.Normalize(NormalizationForm.FormC);
        var p = Parts(id);
        return new DriveNode
        {
            Id = id, DocID = j["docwsid"].Str ?? p.Doc, Zone = j["zone"].Str ?? p.Zone, ParentID = j["parentId"].Str ?? parent,
            Name = name, Type = type, Size = j["size"].Int64 ?? 0, Modified = j["dateModified"].Date ?? j["dateChanged"].Date,
            Created = j["dateCreated"].Date, Etag = j["etag"].Str, ChildCount = j["directChildrenCount"].Int ?? j["numberOfItems"].Int,
            IsShared = (j["shareCount"].Int ?? 0) > 0 || (j["shareAliasCount"].Int ?? 0) > 0,
        };
    }

    public async Task<List<DriveNode>> ListAsync(string folderID, CancellationToken ct = default) =>
        (await ListManyAsync([folderID], ct).ConfigureAwait(false)).TryGetValue(folderID, out var l) ? l : [];

    public async Task<Dictionary<string, List<DriveNode>>> ListManyAsync(IReadOnlyList<string> folderIDs, CancellationToken ct = default)
    {
        if (folderIDs.Count == 0) return [];
        var body = new JsonArray();
        foreach (var id in folderIDs) body.Add(new JsonObject { ["drivewsid"] = id, ["partialData"] = false, ["includeHierarchy"] = false });
        var resp = await Session.RequestAsync(Drivews() + "/retrieveItemDetailsInFolders", json: body, pcs: Pcs, ct: ct).ConfigureAwait(false);
        var output = new Dictionary<string, List<DriveNode>>();
        var arr = resp.Array;
        for (int i = 0; i < arr.Count; i++)
        {
            var folder = arr[i];
            var fid = folder["drivewsid"].Str ?? (i < folderIDs.Count ? folderIDs[i] : "");
            if (folder["status"].Str == "NOT_FOUND") throw ICloudException.NotFound();
            if (folder["status"].Str is { } st && st != "OK") throw ICloudException.Server($"iCloud Drive couldn’t list a folder ({st}). Nothing was changed.");
            if (!folder["errorCode"].IsNull) throw ICloudException.Server("iCloud Drive couldn’t list a folder. Nothing was changed; try again.");
            if (folder["items"].IsNull && (folder["directChildrenCount"].Int ?? folder["numberOfItems"].Int ?? 0) > 0)
                throw ICloudException.Server("iCloud Drive returned an incomplete folder listing. Nothing was changed; try again.");
            output[fid] = folder["items"].Array.Select(x => Node(x, fid)).OfType<DriveNode>().ToList();
        }
        return output;
    }

    public async Task DownloadAsync(DriveNode node, string destination, Action<long, long>? progress, CancellationToken ct = default)
    {
        var p = Parts(node.Id);
        var info = await Session.RequestAsync(Docws() + $"/ws/{(node.Zone.Length == 0 ? p.Zone : node.Zone)}/download/by_id", "GET",
            new Dictionary<string, string> { ["document_id"] = node.DocID ?? p.Doc }, pcs: Pcs, ct: ct).ConfigureAwait(false);
        if (info["data_token"]["url"].Str is { } url)
        {
            await Session.DownloadAsync(url, destination, node.Size, progress, ct).ConfigureAwait(false);
        }
        else if (info["package_token"]["url"].Str is { } purl)
        {
            // Packages (Pages/Keynote bundles…) come as a zip of the bundle.
            var zip = Paths.TempFile(node.Name + ".zip");
            await Session.DownloadAsync(purl, zip, node.Size, progress, ct).ConfigureAwait(false);
            Unzip.ExpandPackage(zip, destination);
        }
        else if (node.Size == 0)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            await File.WriteAllBytesAsync(destination, [], ct).ConfigureAwait(false);
        }
        else throw ICloudException.Server($"iCloud didn’t return a download link for “{node.Name}”.");
        if (node.Modified is { } m && File.Exists(destination)) { try { File.SetLastWriteTimeUtc(destination, m.UtcDateTime); } catch { } }
    }

    public async Task<DriveNode> UploadAsync(string file, string name, string folderID, DateTimeOffset? modified, Action<long, long>? progress, CancellationToken ct = default)
    {
        SafetyPolicy.CheckWrite();
        var zone = Parts(folderID).Zone;
        var size = new FileInfo(file).Length;
        if (size > Limits.ICloudDriveMax) throw ICloudException.Server($"“{name}” is {size.ByteString()}, larger than iCloud Drive’s 50 GB file limit.");
        var mime = Mime.ForName(name);
        var docs = Docws();
        var create = await Session.RequestAsync(docs + $"/ws/{zone}/upload/web",
            json: new JsonObject { ["filename"] = name, ["type"] = "FILE", ["size"] = size.ToString(), ["content_type"] = mime },
            pcs: Pcs, idempotent: false, ct: ct).ConfigureAwait(false);
        if (create[0]["url"].Str is not string uploadURL || create[0]["document_id"].Str is not string documentID)
            throw ICloudException.Server($"iCloud didn’t accept the upload of “{name}”.");
        var sent = await Session.UploadAsync(uploadURL, null, file, name, mime, progress, ct).ConfigureAwait(false);
        var single = sent["singleFile"];
        var mtime = (modified ?? DateTimeOffset.UtcNow).ToUnixTimeMilliseconds();
        var data = new JsonObject { ["size"] = single["size"].Int64 ?? size };
        if (single["receipt"].Str is { } rc) data["receipt"] = rc;
        if (single["fileChecksum"].Str is { } fc) data["signature"] = fc;
        if (single["referenceChecksum"].Str is { } rf) data["reference_signature"] = rf;
        if (single["wrappingKey"].Str is { } wk) data["wrapping_key"] = wk;
        var update = new JsonObject
        {
            ["allow_conflict"] = true, ["btime"] = mtime, ["command"] = "add_file", ["create_short_guid"] = true,
            ["data"] = data, ["document_id"] = documentID,
            ["file_flags"] = new JsonObject { ["is_executable"] = true, ["is_hidden"] = false, ["is_writable"] = true }, // matches rclone's known-good payload
            ["mtime"] = mtime,
            ["path"] = new JsonObject { ["path"] = name, ["starting_document_id"] = Parts(folderID).Doc },
        };
        var result = await Session.RequestAsync(docs + $"/ws/{zone}/update/documents", json: update, pcs: Pcs, idempotent: false, ct: ct).ConfigureAwait(false);
        var doc = result["results"][0]["document"];
        var docID = doc["document_id"].Str ?? documentID;
        var finalName = name;
        if (doc["name"].Str is { } n)
            finalName = doc["extension"].Str is { Length: > 0 } ext && !n.EndsWith("." + ext, StringComparison.Ordinal) ? n + "." + ext : n;
        return new DriveNode
        {
            Id = $"FILE::{zone}::{docID}", DocID = docID, Zone = zone, ParentID = folderID, Name = finalName, Type = "FILE",
            Size = doc["size"].Int64 ?? size, Modified = modified ?? DateTimeOffset.UtcNow, Created = DateTimeOffset.UtcNow, Etag = doc["etag"].Str,
        };
    }

    public async Task<DriveNode> CreateFolderAsync(string name, string folderID, CancellationToken ct = default)
    {
        SafetyPolicy.CheckWrite();
        var r = await Session.RequestAsync(Drivews() + "/createFolders",
            json: new JsonObject
            {
                ["destinationDrivewsId"] = folderID,
                ["folders"] = new JsonArray(new JsonObject { ["clientId"] = "FOLDER::UNKNOWN_ZONE::TempId-" + Guid.NewGuid().ToString().ToUpperInvariant(), ["name"] = name }),
            }, pcs: Pcs, idempotent: false, ct: ct).ConfigureAwait(false);
        var f = r["folders"][0];
        if (f["status"].Str is { } s && s != "OK") throw ICloudException.Server($"Couldn’t create folder ({s}).");
        return Node(f, folderID) ?? throw ICloudException.Server("Couldn’t create folder.");
    }

    async Task<J> ItemOp(string path, IReadOnlyList<DriveNode> items, JsonObject? extra, Func<DriveNode, JsonObject>? itemExtra, CancellationToken ct)
    {
        var body = extra ?? new JsonObject();
        var arr = new JsonArray();
        foreach (var n in items)
        {
            var o = new JsonObject { ["drivewsid"] = n.Id, ["etag"] = n.Etag ?? "", ["clientId"] = n.Id };
            if (itemExtra is not null) foreach (var (k, v) in itemExtra(n).ToList()) o[k] = v?.DeepClone();
            arr.Add(o);
        }
        body["items"] = arr;
        return await Session.RequestAsync(Drivews() + path, json: body, pcs: Pcs, idempotent: false, ct: ct).ConfigureAwait(false);
    }

    static async Task CheckStatuses(J r, Func<Dictionary<string, string>, Task> retry)
    {
        var conflicts = new Dictionary<string, string>();
        foreach (var item in r["items"].Array)
        {
            if (item["status"].Str is not string s || s == "OK") continue;
            if (s == "ETAG_CONFLICT" && item["drivewsid"].Str is { } id && item["etag"].Str is { } etag) { conflicts[id] = etag; continue; }
            throw ICloudException.Server($"iCloud Drive refused the change ({s}).");
        }
        if (conflicts.Count > 0) await retry(conflicts).ConfigureAwait(false);
    }

    public async Task<DriveNode> RenameAsync(DriveNode node, string name, CancellationToken ct = default)
    {
        SafetyPolicy.CheckWrite();
        var target = node.Copy();
        for (int attempt = 0; attempt < 2; attempt++)
        {
            var r = await ItemOp("/renameItems", [target], null, _ => new JsonObject { ["name"] = name }, ct).ConfigureAwait(false);
            var item = r["items"][0];
            if (item["status"].Str == "ETAG_CONFLICT" && attempt == 0 && item["etag"].Str is { } e) { target.Etag = e; continue; }
            if (item["status"].Str is { } s && s != "OK") throw ICloudException.Server($"Couldn’t rename ({s}).");
            if (Node(item, node.ParentID) is { } renamed) return renamed;
            var copy = node.Copy(); copy.Name = name; return copy;
        }
        throw ICloudException.Conflict();
    }

    async Task WithEtagRetry(string path, IReadOnlyList<DriveNode> nodes, Func<JsonObject?> extra, CancellationToken ct)
    {
        var r = await ItemOp(path, nodes, extra(), null, ct).ConfigureAwait(false);
        await CheckStatuses(r, async conflicts =>
        {
            var fixedNodes = nodes.Where(n => conflicts.ContainsKey(n.Id)).Select(n => { var m = n.Copy(); m.Etag = conflicts[n.Id]; return m; }).ToList();
            var r2 = await ItemOp(path, fixedNodes, extra(), null, ct).ConfigureAwait(false);
            await CheckStatuses(r2, _ => throw ICloudException.Conflict()).ConfigureAwait(false);
        }).ConfigureAwait(false);
    }

    public Task MoveAsync(IReadOnlyList<DriveNode> nodes, string folderID, CancellationToken ct = default)
    {
        SafetyPolicy.CheckWrite();
        return WithEtagRetry("/moveItems", nodes, () => new JsonObject { ["destinationDrivewsId"] = folderID }, ct);
    }

    public Task TrashAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default)
    {
        SafetyPolicy.CheckWrite();
        return WithEtagRetry("/moveItemsToTrash", nodes, () => null, ct);
    }

    public async Task<List<DriveNode>> ListTrashAsync(CancellationToken ct = default)
    {
        var body = new JsonArray(new JsonObject { ["drivewsid"] = "TRASH_ROOT", ["partialData"] = false, ["includeHierarchy"] = false });
        var r = await Session.RequestAsync(Drivews() + "/retrieveItemDetailsInFolders", json: body, pcs: Pcs, ct: ct).ConfigureAwait(false);
        return r[0]["items"].Array.Select(x => Node(x, "TRASH_ROOT")).OfType<DriveNode>().Select(n => { n.ParentID = "TRASH_ROOT"; return n; }).ToList();
    }

    public async Task RestoreAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default)
    {
        SafetyPolicy.CheckWrite();
        var r = await ItemOp("/putBackItemsFromTrash", nodes, null, null, ct).ConfigureAwait(false);
        await CheckStatuses(r, _ => throw ICloudException.Conflict()).ConfigureAwait(false);
    }

    public async Task DeleteForeverAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default)
    {
        SafetyPolicy.CheckWrite();
        DriveBackendExtensions.GuardTrashOnly(nodes);
        var r = await ItemOp("/deleteItems", nodes, null, null, ct).ConfigureAwait(false);
        await CheckStatuses(r, _ => throw ICloudException.Conflict()).ConfigureAwait(false);
    }
}

static class Unzip
{
    /// <summary>Expands a package zip (Pages/Keynote/Numbers bundle) into <paramref name="destination"/>.</summary>
    public static void ExpandPackage(string zip, string destination)
    {
        var staging = Paths.TempFile("pkg");
        Directory.CreateDirectory(staging);
        bool ok = true;
        try { ZipFile.ExtractToDirectory(zip, staging, overwriteFiles: true); } catch { ok = false; }
        var items = ok ? Directory.GetFileSystemEntries(staging) : [];
        if (LocalFiles.Exists(destination)) LocalFiles.SafeTrash(destination, null);
        if (ok && items.Length == 1) { LocalFiles.MoveItem(items[0], destination); File.Delete(zip); }
        else if (ok) { Directory.Move(staging, destination); File.Delete(zip); }
        else File.Move(zip, destination + ".zip", overwrite: false);
    }
}
