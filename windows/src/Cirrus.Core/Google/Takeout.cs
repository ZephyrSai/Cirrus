using System.Formats.Tar;
using System.IO.Compression;
using System.Text.RegularExpressions;

namespace Cirrus.Core;

/// <summary>One photo or video found in a Google Takeout export, with what its JSON sidecar says.</summary>
public sealed class TakeoutItem
{
    /// <summary>Stable across exports and formats: name|taken|size.</summary>
    public string Key { get; init; } = "";
    /// <summary>The .zip/.tgz part, or null for an extracted folder.</summary>
    public string? Archive { get; init; }
    /// <summary>Member path in the archive, or the file's full path.</summary>
    public string Path { get; init; } = "";
    /// <summary>The name it gets in iCloud.</summary>
    public string FileName { get; init; } = "";
    public long Size { get; init; }
    public DateTimeOffset? Taken { get; init; }
    public string? Caption { get; init; }
    public double? Latitude { get; init; }
    public double? Longitude { get; init; }
    public bool Favorite { get; set; }
    public List<string> Albums { get; init; } = [];
    public bool IsVideo { get; init; }
    public bool IsEdited { get; init; }
    /// <summary>The video half of a Live Photo / motion photo.</summary>
    public bool IsCompanion { get; init; }
    /// <summary>A Live Photo's still and video share a group.</summary>
    public string Group { get; init; } = "";
}

/// <summary>
/// Reads Google Photos out of Takeout exports (port of Takeout.swift): .zip parts (System.IO.Compression), .tgz/.tar
/// parts (System.Formats.Tar over GZipStream), or a folder the user already extracted. Everything runs in-process;
/// nothing is shelled out. Sidecars are read into memory while listing; media are unpacked later, a batch at a time,
/// each into a file Cirrus names itself (member paths never decide where anything is written).
/// </summary>
public sealed class TakeoutReader
{
    public sealed class Result
    {
        public List<TakeoutItem> Items { get; set; } = [];
        public List<MigrationSkipped> Skipped { get; set; } = [];
        public List<string> Warnings { get; set; } = [];
        public int Parts { get; set; }
        public int Sidecars { get; set; }
        public int WithoutSidecar { get; set; }
    }

    internal readonly record struct Entry(string? Archive, string Path, long Size)
    {
        /// <summary>The path with forward slashes.</summary>
        public string Logical => Path.Replace('\\', '/');
        public string Name => System.IO.Path.GetFileName(Logical.TrimEnd('/'));
    }

    public IReadOnlyList<string> Inputs { get; }
    public TakeoutReader(IReadOnlyList<string> inputs) { Inputs = inputs; }

    const long SidecarMax = 4 << 20;

    static readonly string[] ArchiveSuffixes = [".zip", ".tgz", ".tar.gz", ".gz", ".tar", ".tbz", ".tbz2", ".bz2"];
    public static bool IsArchive(string path) => ArchiveSuffixes.Any(s => path.EndsWith(s, StringComparison.OrdinalIgnoreCase));
    static bool IsZip(string path) => path.EndsWith(".zip", StringComparison.OrdinalIgnoreCase);
    static bool IsGzip(string path) => path.EndsWith(".tgz", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".gz", StringComparison.OrdinalIgnoreCase);
    static bool IsTar(string path) => path.EndsWith(".tar", StringComparison.OrdinalIgnoreCase);

    /// <summary>Media types iCloud Photos takes (the same list Cirrus uses for drops), plus Pixel motion-photo videos.</summary>
    static readonly HashSet<string> VideoExts = new(StringComparer.OrdinalIgnoreCase) { "mov", "mp4", "m4v", "mp", "mv" };
    static readonly HashSet<string> OtherMedia = new(StringComparer.OrdinalIgnoreCase)
    { "avi", "mkv", "3gp", "3g2", "wmv", "mpg", "mpeg", "mts", "m2ts", "asf", "divx", "mod", "tod", "bmp", "ico", "psd", "svg" };
    static readonly HashSet<string> PhotosFolders = new(StringComparer.Ordinal)
    {
        "google photos", "google fotos", "google foto", "google zdjęcia", "google фото", "google fotky", "google fotók", "google kuvat",
        "google φωτογραφίες", "google 포토", "google フォト", "google 相册", "google 相簿", "google 相片",
    };
    static readonly string[] EditedSuffixes =
    [
        "-edited", "-bearbeitet", "-modifié", "-editado", "-modificato", "-bewerkt", "-redigerad", "-redigeret", "-muokattu",
        "-edytowane", "-upraveno", "-szerkesztett", "-изменено", "-編集済み", "-已修改", "-편집됨",
    ];
    static readonly HashSet<string> SpecialFolders = new(StringComparer.Ordinal)
    { "trash", "bin", "papierkorb", "corbeille", "papelera", "cestino", "prullenbak", "archive", "failed videos" };

    static string Ext(string name) { var e = System.IO.Path.GetExtension(name); return e.Length > 0 ? e[1..] : ""; }
    static string Stem(string name) => System.IO.Path.GetFileNameWithoutExtension(name);

    // MARK: Listing

    public async Task<Result> ScanAsync(Action<string>? progress, CancellationToken ct = default)
    {
        var entries = new List<Entry>();
        var jsons = new Dictionary<Entry, byte[]>();
        var result = new Result();
        foreach (var input in Inputs)
        {
            ct.ThrowIfCancellationRequested();
            var display = System.IO.Path.GetFileName(input.TrimEnd('\\', '/'));
            if (Directory.Exists(input))
            {
                progress?.Invoke($"Reading {display}…");
                await Task.Run(() => ListFolder(input, entries, jsons, ct), ct).ConfigureAwait(false);
            }
            else if (File.Exists(input) && IsArchive(input))
            {
                result.Parts++;
                progress?.Invoke($"Reading {display} (part {result.Parts})…");
                await Task.Run(() => ListArchive(input, entries, jsons, ct), ct).ConfigureAwait(false);
            }
            else if (!File.Exists(input)) throw SyncException.Unavailable($"“{display}” isn’t there any more.");
            else throw SyncException.Unavailable($"“{display}” isn’t a Takeout export. Choose the .zip or .tgz files Google sent, or the folder you unpacked them into.");
        }
        progress?.Invoke("Matching photos with their Google details…");
        Build(entries, jsons, result);
        return result;
    }

    static void ListFolder(string root, List<Entry> entries, Dictionary<Entry, byte[]> jsons, CancellationToken ct)
    {
        var opts = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.Hidden | FileAttributes.System };
        foreach (var f in new DirectoryInfo(root).EnumerateFiles("*", opts))
        {
            ct.ThrowIfCancellationRequested();
            if (f.Name.StartsWith('.') || f.LinkTarget is not null) continue;
            var e = new Entry(null, f.FullName, f.Length);
            entries.Add(e);
            if (f.Extension.Equals(".json", StringComparison.OrdinalIgnoreCase) && f.Length < SidecarMax)
                try { jsons[e] = File.ReadAllBytes(f.FullName); } catch (IOException) { }
        }
    }

    /// <summary>
    /// Member names with ".." parts, absolute paths or drive letters aren't part of a real export (and tar tools refuse
    /// them); they're left out rather than guessed at.
    /// </summary>
    internal static bool SafeMember(string name)
    {
        var p = name.Replace('\\', '/');
        if (p.StartsWith('/') || (p.Length > 1 && p[1] == ':')) return false;
        return !p.Split('/').Any(seg => seg is ".." or ".");
    }

    static Exception Unreadable(string archive) => SyncException.Unavailable(
        $"Couldn’t read “{System.IO.Path.GetFileName(archive)}”. If the download didn’t finish, download that part again from Google Takeout.");

    static void ListArchive(string archive, List<Entry> entries, Dictionary<Entry, byte[]> jsons, CancellationToken ct)
    {
        try
        {
            if (IsZip(archive))
            {
                using var zip = ZipFile.OpenRead(archive);
                foreach (var z in zip.Entries)
                {
                    ct.ThrowIfCancellationRequested();
                    if (z.FullName.EndsWith('/') || z.FullName.EndsWith('\\')) continue;
                    if (!SafeMember(z.FullName)) { Log.Status("takeout: left out a member with an unsafe path"); continue; }
                    var e = new Entry(archive, z.FullName, z.Length);
                    entries.Add(e);
                    if (z.FullName.EndsWith(".json", StringComparison.OrdinalIgnoreCase) && z.Length < SidecarMax)
                    {
                        using var s = z.Open();
                        jsons[e] = ReadBounded(s, z.Length);
                    }
                }
                return;
            }
            if (!IsGzip(archive) && !IsTar(archive))
                throw SyncException.Unavailable($"“{System.IO.Path.GetFileName(archive)}” is compressed in a way Cirrus can’t read. In Google Takeout, choose .zip or .tgz.");
            using var fs = new FileStream(archive, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20);
            using var raw = IsGzip(archive) ? (Stream)new GZipStream(fs, CompressionMode.Decompress) : fs;
            using var tar = new TarReader(raw);
            while (tar.GetNextEntry() is { } t)
            {
                ct.ThrowIfCancellationRequested();
                if (t.EntryType is not (TarEntryType.RegularFile or TarEntryType.V7RegularFile or TarEntryType.ContiguousFile)) continue;
                if (!SafeMember(t.Name)) { Log.Status("takeout: left out a member with an unsafe path"); continue; }
                var e = new Entry(archive, t.Name, t.Length);
                entries.Add(e);
                if (t.Name.EndsWith(".json", StringComparison.OrdinalIgnoreCase) && t.Length < SidecarMax && t.DataStream is { } ds)
                    jsons[e] = ReadBounded(ds, t.Length);
            }
        }
        catch (Exception e) when (e is InvalidDataException or EndOfStreamException or FormatException or IOException && e is not FileNotFoundException)
        {
            throw Unreadable(archive);
        }
    }

    /// <summary>At most the declared length (and not a byte more: a member that inflates beyond its header is refused).</summary>
    static byte[] ReadBounded(Stream s, long declared)
    {
        using var ms = new MemoryStream();
        CopyBounded(s, ms, declared);
        return ms.ToArray();
    }

    static void CopyBounded(Stream src, Stream dst, long declared)
    {
        var buf = new byte[1 << 20];
        long done = 0;
        while (true)
        {
            var n = src.Read(buf, 0, (int)Math.Min(buf.Length, declared - done + 1));
            if (n <= 0) break;
            done += n;
            if (done > declared) throw new InvalidDataException("An archive member is larger than its header says.");
            dst.Write(buf, 0, n);
        }
    }

    // MARK: Matching

    sealed class Sidecar
    {
        public string? Title;
        public DateTimeOffset? Taken;
        public string? Caption;
        public double? Lat, Lon;
        public bool Favorite, Trashed;

        public static Sidecar? Parse(byte[] data)
        {
            var j = J.Parse(data);
            if (j.Node is not System.Text.Json.Nodes.JsonObject) return null;
            var s = new Sidecar { Title = j["title"].Str ?? j["albumData"]["title"].Str };   // older album metadata nests it
            if ((j["photoTakenTime"]["timestamp"].Double ?? j["creationTime"]["timestamp"].Double) is { } t && t > 0)
                s.Taken = DateTimeOffset.FromUnixTimeSeconds((long)t);
            var c = j["description"].Str;
            s.Caption = string.IsNullOrWhiteSpace(c) ? null : c;
            foreach (var g in new[] { j["geoData"], j["geoDataExif"] })
                if (g["latitude"].Double is { } a && g["longitude"].Double is { } o && (a != 0 || o != 0)) { s.Lat = a; s.Lon = o; break; }
            s.Favorite = j["favorited"].Bool ?? false;
            s.Trashed = j["trashed"].Bool ?? false;
            return s;
        }
    }

    /// <summary>
    /// Path inside the export, the same whichever part (or unpacked folder) it came from: sidecars and Live Photo halves
    /// can land in a different part than their photo.
    /// </summary>
    internal static string ExportPath(Entry e)
    {
        var p = e.Logical;
        if (e.Archive is not null) return p;
        var i = p.IndexOf("/Takeout/", StringComparison.Ordinal);
        return i >= 0 ? p[(i + 1)..] : p;
    }

    static string Dir(string p) { var i = p.LastIndexOf('/'); return i < 0 ? "" : p[..i]; }
    static string Last(string p) { var i = p.LastIndexOf('/'); return i < 0 ? p : p[(i + 1)..]; }
    static string FolderKey(Entry e) => Dir(ExportPath(e));

    /// <summary>Splits "IMG_1234(1).JPG" into ("IMG_1234", "(1)", ".JPG").</summary>
    internal static (string Stem, string Dup, string Ext) SplitDuplicate(string name)
    {
        var ext = Ext(name);
        var stem = ext.Length > 0 ? name[..^(ext.Length + 1)] : name;
        var dup = "";
        var open = stem.LastIndexOf('(');
        if (stem.EndsWith(')') && open >= 0 && stem.Length - open > 2 && stem[(open + 1)..^1].All(char.IsAsciiDigit))
        {
            dup = stem[open..];
            stem = stem[..open];
        }
        return (stem, dup, ext.Length == 0 ? "" : "." + ext);
    }

    internal static string? EditedBase(string stem)
    {
        foreach (var s in EditedSuffixes)
            if (stem.EndsWith(s, StringComparison.OrdinalIgnoreCase)) return stem[..^s.Length];
        return null;
    }

    /// <summary>
    /// Finds the sidecar for a media file among the folder's JSON names (classic, supplemental-metadata, truncated at
    /// 46–51 characters, and "(n)" duplicates in either position).
    /// </summary>
    public static string? SidecarName(string name, IReadOnlySet<string> jsonNames)
    {
        var (stem0, dup, ext) = SplitDuplicate(name);
        var stem = EditedBase(stem0) ?? stem0;
        var full = stem + ext;
        var supp = full + ".supplemental-metadata";
        var candidates = new List<string> { full + dup + ".json", full + ".json" + dup, full + ".supplemental-metadata" + dup + ".json", stem + dup + ".json", supp + ".json" };
        if (dup.Length == 0) candidates.Add(stem + ".json");
        foreach (var c in candidates) if (jsonNames.Contains(c)) return c;
        var lowered = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var j in jsonNames) lowered.TryAdd(j.ToLowerInvariant(), j);
        foreach (var c in candidates) if (lowered.TryGetValue(c.ToLowerInvariant(), out var hit)) return hit;
        // Truncated names: the JSON's stem is a prefix of "<name>.supplemental-metadata" (or of the name itself).
        string? best = null;
        foreach (var j in jsonNames)
        {
            if (!j.EndsWith(".json", StringComparison.OrdinalIgnoreCase)) continue;
            var s = j[..^5];
            var jdup = "";
            var open = s.LastIndexOf('(');
            if (s.EndsWith(')') && open >= 0 && s[(open + 1)..^1].All(char.IsAsciiDigit)) { jdup = s[open..]; s = s[..open]; }
            if (jdup != dup || s.Length < 30) continue;
            if (supp.StartsWith(s, StringComparison.Ordinal) || full.StartsWith(s, StringComparison.Ordinal))
                if (best is null || s.Length > best.Length - 5) best = j;
        }
        return best;
    }

    static readonly Regex YearRx = new(@"(19|20)\d{2}$", RegexOptions.Compiled);

    void Build(List<Entry> entries, Dictionary<Entry, byte[]> jsons, Result result)
    {
        // Only Google Photos content when the export holds other products too.
        static bool IsPhotosPath(Entry e) => ExportPath(e).Split('/').Any(c => PhotosFolders.Contains(c.ToLowerInvariant()));
        Func<Entry, bool> inPhotos = entries.Any(IsPhotosPath) ? IsPhotosPath : _ => true;

        var folders = new Dictionary<string, List<Entry>>(StringComparer.Ordinal);
        foreach (var e in entries.Where(inPhotos))
        {
            var k = FolderKey(e);
            if (!folders.TryGetValue(k, out var l)) folders[k] = l = [];
            l.Add(e);
        }
        var byKey = new Dictionary<string, TakeoutItem>(StringComparer.Ordinal);
        var order = new List<string>();
        foreach (var (_, list) in folders.OrderBy(kv => kv.Key, StringComparer.Ordinal))
        {
            var folderName = Last(Dir(ExportPath(list[0])));
            var jsonEntries = list.Where(e => e.Logical.EndsWith(".json", StringComparison.OrdinalIgnoreCase)).ToList();
            var jsonByName = new Dictionary<string, Entry>(StringComparer.Ordinal);
            foreach (var je in jsonEntries) jsonByName.TryAdd(je.Name, je);
            var names = jsonByName.Keys.ToHashSet(StringComparer.Ordinal);
            var media = list.Where(e => PhotoFormats.IsImportable(e.Name) || VideoExts.Contains(Ext(e.Name)) || OtherMedia.Contains(Ext(e.Name))).ToList();
            // Album or year folder? Albums carry a metadata JSON that isn't any photo's sidecar.
            var used = media.Select(m => SidecarName(m.Name, names)).OfType<string>().ToHashSet(StringComparer.Ordinal);
            string? albumTitle = null;
            foreach (var (name, je) in jsonByName)
            {
                if (used.Contains(name)) continue;
                if (jsons.TryGetValue(je, out var d) && Sidecar.Parse(d) is { Taken: null, Title: { Length: > 0 } t }) { albumTitle = t; break; }
            }
            var isYear = YearRx.IsMatch(folderName) && albumTitle is null;
            var special = SpecialFolders.Contains(folderName.ToLowerInvariant());
            string? album = special || isYear || PhotosFolders.Contains(folderName.ToLowerInvariant()) ? null : albumTitle ?? folderName;
            // Live Photos: a still and a .MOV with the same stem.
            var stems = media.GroupBy(m => Stem(m.Name).ToLowerInvariant()).ToDictionary(g => g.Key, g => g.ToList());
            foreach (var e in media)
            {
                var name = e.Name;
                var ext = Ext(name).ToLowerInvariant();
                if (OtherMedia.Contains(ext))
                {
                    result.Skipped.Add(new MigrationSkipped(name, e.Size, $"iCloud Photos doesn’t accept .{ext} files"));
                    continue;
                }
                var stem = Stem(name).ToLowerInvariant();
                var isVideo = VideoExts.Contains(ext);
                var sibling = stems.TryGetValue(stem, out var sl) ? sl.FirstOrDefault(x => x != e && !VideoExts.Contains(Ext(x.Name))) : default;
                var hasSibling = sibling != default;
                var isCompanion = isVideo && (hasSibling || ext is "mp" or "mv");
                Sidecar? sc = null;
                if (SidecarName(name, names) is { } n && jsonByName.TryGetValue(n, out var je) && jsons.TryGetValue(je, out var d)) sc = Sidecar.Parse(d);
                if (sc is null && isCompanion && hasSibling && SidecarName(sibling.Name, names) is { } sn && jsonByName.TryGetValue(sn, out var sje) && jsons.TryGetValue(sje, out var sd))
                    sc = Sidecar.Parse(sd);
                if (sc is null) result.WithoutSidecar++; else result.Sidecars++;
                if (sc?.Trashed == true) continue;
                var (stem0, _, _) = SplitDuplicate(name);
                var edited = EditedBase(stem0) is not null;
                var fileName = name;
                if (ext is "mp" or "mv") fileName = Stem(name) + ".MP4";
                else if (!edited && !isCompanion && sc?.Title is { } t && Ext(t).Equals(ext, StringComparison.OrdinalIgnoreCase) && !t.Contains('/') && !t.Contains('\\'))
                    fileName = t;
                var taken = sc?.Taken;
                var key = $"{(edited ? "edited:" : isCompanion ? "video:" : "")}{fileName.ToLowerInvariant()}|{(taken is { } tk ? tk.ToUnixTimeSeconds().ToString() : "-")}|{e.Size}";
                var group = FolderKey(e) + "|" + stem;
                if (byKey.TryGetValue(key, out var existing))
                {
                    if (album is not null && !existing.Albums.Contains(album)) existing.Albums.Add(album);
                    existing.Favorite = existing.Favorite || (sc?.Favorite ?? false);
                    continue;
                }
                byKey[key] = new TakeoutItem
                {
                    Key = key, Archive = e.Archive, Path = e.Path, FileName = fileName, Size = e.Size, Taken = taken, Caption = sc?.Caption,
                    Latitude = sc?.Lat, Longitude = sc?.Lon, Favorite = sc?.Favorite ?? false, Albums = album is null ? [] : [album],
                    IsVideo = isVideo, IsEdited = edited, IsCompanion = isCompanion, Group = group,
                };
                order.Add(key);
            }
        }
        result.Items = order.Select(k => byKey[k]).ToList();
        if (result.Items.Count == 0) result.Warnings.Add("No photos or videos were found in this export. Make sure Google Photos was selected in Takeout.");
        else if (result.WithoutSidecar > 0 && result.Sidecars == 0) result.Warnings.Add("This export has no JSON details, so dates come from the files themselves.");
    }

    // MARK: Extraction

    /// <summary>
    /// Unpacks these items (from their archives, or copies loose files) into <paramref name="dir"/>, each under a name
    /// Cirrus chooses. Returns key → file. The user's export is only read.
    /// </summary>
    public Task<Dictionary<string, string>> ExtractAsync(IReadOnlyList<TakeoutItem> items, string dir, CancellationToken ct = default) => Task.Run(() =>
    {
        Directory.CreateDirectory(dir);
        var output = new Dictionary<string, string>(StringComparer.Ordinal);
        string Dest(TakeoutItem i) => System.IO.Path.Combine(dir, Guid.NewGuid().ToString("N") + System.IO.Path.GetExtension(Last(i.Path.Replace('\\', '/'))));
        foreach (var i in items.Where(i => i.Archive is null))
        {
            ct.ThrowIfCancellationRequested();
            var dest = Dest(i);
            File.Copy(i.Path, dest);
            output[i.Key] = dest;
        }
        foreach (var group in items.Where(i => i.Archive is not null).GroupBy(i => i.Archive!))
        {
            ct.ThrowIfCancellationRequested();
            var archive = group.Key;
            var wanted = new Dictionary<string, List<TakeoutItem>>(StringComparer.Ordinal);
            foreach (var i in group) { if (!wanted.TryGetValue(i.Path, out var l)) wanted[i.Path] = l = []; l.Add(i); }
            try
            {
                if (IsZip(archive))
                {
                    using var zip = ZipFile.OpenRead(archive);
                    foreach (var z in zip.Entries)
                    {
                        if (!wanted.TryGetValue(z.FullName, out var list)) continue;
                        ct.ThrowIfCancellationRequested();
                        foreach (var i in list) output[i.Key] = WriteMember(() => z.Open(), z.Length, Dest(i));
                        wanted.Remove(z.FullName);
                    }
                }
                else
                {
                    using var fs = new FileStream(archive, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20);
                    using var raw = IsGzip(archive) ? (Stream)new GZipStream(fs, CompressionMode.Decompress) : fs;
                    using var tar = new TarReader(raw);
                    while (wanted.Count > 0 && tar.GetNextEntry() is { } t)
                    {
                        ct.ThrowIfCancellationRequested();
                        if (t.DataStream is not { } ds || !wanted.TryGetValue(t.Name, out var list)) continue;
                        // A member wanted twice (rare) is read once and copied.
                        var first = WriteMember(() => ds, t.Length, Dest(list[0]));
                        output[list[0].Key] = first;
                        foreach (var i in list.Skip(1)) { var d = Dest(i); File.Copy(first, d); output[i.Key] = d; }
                        wanted.Remove(t.Name);
                    }
                }
            }
            catch (Exception e) when (e is InvalidDataException or EndOfStreamException or FormatException)
            {
                Log.Status("takeout: a part couldn’t be unpacked (" + e.GetType().Name + ")");
            }
        }
        return output;
    }, ct);

    static string WriteMember(Func<Stream> open, long declared, string dest)
    {
        try
        {
            using var src = open();
            using var dst = new FileStream(dest, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1 << 20);
            CopyBounded(src, dst, declared);
            return dest;
        }
        catch { try { File.Delete(dest); } catch { } throw; }   // our own partial staging file
    }
}
