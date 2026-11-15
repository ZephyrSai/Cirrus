using System.Formats.Tar;
using System.IO.Compression;
using System.Text.Json.Nodes;
using Cirrus.Core;

namespace Cirrus.Fakes;

/// <summary>
/// A small synthetic Google Takeout export (port of TakeoutFixture.swift; tests and Debug demo only). It covers the awkward
/// cases: classic and "supplemental-metadata" sidecars, a 51-character truncated sidecar, "(1)" duplicates, an "-edited"
/// copy, a Live Photo (HEIC-style still + MP4), an album that repeats a year-folder photo, a sidecar in a different part
/// than its photo, a trashed item, an unsupported file, a photo with no sidecar, and a non-Photos product folder.
/// Archives are written in-process (zip: System.IO.Compression, tgz: System.Formats.Tar + GZip).
/// </summary>
public static class TakeoutFixture
{
    static byte[] Image(string label, double hue) => DemoArt.Png(240, 160, hue, label);

    public static byte[] Sidecar(string title, DateTimeOffset taken, string description = "", bool favorite = false, bool trashed = false, double lat = 0, double lon = 0)
    {
        var o = new JsonObject
        {
            ["title"] = title, ["description"] = description, ["imageViews"] = "3",
            ["creationTime"] = new JsonObject { ["timestamp"] = (taken.ToUnixTimeSeconds() + 86_400).ToString(), ["formatted"] = "" },
            ["photoTakenTime"] = new JsonObject { ["timestamp"] = taken.ToUnixTimeSeconds().ToString(), ["formatted"] = "" },
            ["geoData"] = new JsonObject { ["latitude"] = lat, ["longitude"] = lon, ["altitude"] = 0.0, ["latitudeSpan"] = 0.0, ["longitudeSpan"] = 0.0 },
            ["url"] = "https://photos.google.com/photo/fake", ["googlePhotosOrigin"] = new JsonObject { ["mobileUpload"] = new JsonObject { ["deviceType"] = "IOS_PHONE" } },
        };
        if (favorite) o["favorited"] = true;
        if (trashed) o["trashed"] = true;
        return Jx.Bytes(o);
    }

    /// <summary>The date each test photo should end up with.</summary>
    public static readonly Dictionary<string, DateTimeOffset> Dates = new()
    {
        ["IMG_0001.JPG"] = DateTimeOffset.FromUnixTimeSeconds(1_683_000_000),   // May 2023
        ["IMG_0002.JPG"] = DateTimeOffset.FromUnixTimeSeconds(1_684_000_000),
        ["IMG_0003.HEIC"] = DateTimeOffset.FromUnixTimeSeconds(1_685_000_000),
        ["IMG_0004.JPG"] = DateTimeOffset.FromUnixTimeSeconds(1_686_000_000),
        ["IMG_0004(1).JPG"] = DateTimeOffset.FromUnixTimeSeconds(1_686_500_000),
        ["IMG_0005.JPG"] = DateTimeOffset.FromUnixTimeSeconds(1_687_000_000),
        ["Screenshot_20230701_a_very_long_camera_file_name.png"] = DateTimeOffset.FromUnixTimeSeconds(1_688_200_000),
        ["IMG_0007.JPG"] = DateTimeOffset.FromUnixTimeSeconds(1_717_000_000),   // May 2024
    };

    public const string LongName = "Screenshot_20230701_a_very_long_camera_file_name.png";

    /// <summary>Writes the export as two .zip parts, two .tgz parts, or a folder. Returns what to choose.</summary>
    public static List<string> Make(string dir, string format = "zip")
    {
        Directory.CreateDirectory(dir);
        const string y23 = "Takeout/Google Photos/Photos from 2023", y24 = "Takeout/Google Photos/Photos from 2024", album = "Takeout/Google Photos/Lisbon trip";
        var part1 = new List<(string, byte[])>();
        var part2 = new List<(string, byte[])>();
        DateTimeOffset D(string k) => Dates[k];
        // Classic sidecar, favorite, with place and caption; also in the album.
        var one = Image("Tram 28", 0.05);
        part1.Add(($"{y23}/IMG_0001.JPG", one));
        part1.Add(($"{y23}/IMG_0001.JPG.json", Sidecar("IMG_0001.JPG", D("IMG_0001.JPG"), "Tram 28", favorite: true, lat: 38.7139, lon: -9.1394)));
        part2.Add(($"{album}/IMG_0001.JPG", one));
        part2.Add(($"{album}/IMG_0001.JPG.json", Sidecar("IMG_0001.JPG", D("IMG_0001.JPG"), "Tram 28", favorite: true, lat: 38.7139, lon: -9.1394)));
        // New-style sidecar name.
        part1.Add(($"{y23}/IMG_0002.JPG", Image("Alfama", 0.15)));
        part1.Add(($"{y23}/IMG_0002.JPG.supplemental-metadata.json", Sidecar("IMG_0002.JPG", D("IMG_0002.JPG"))));
        // Live Photo: still + MP4 with one sidecar named after the still.
        part1.Add(($"{y23}/IMG_0003.HEIC", Image("Live", 0.25)));
        part1.Add(($"{y23}/IMG_0003.MP4", new byte[3000]));
        part1.Add(($"{y23}/IMG_0003.HEIC.supplemental-metadata.json", Sidecar("IMG_0003.HEIC", D("IMG_0003.HEIC"))));
        // Two different photos called IMG_0004.JPG: "(1)" goes after the extension in the sidecar name.
        part1.Add(($"{y23}/IMG_0004.JPG", Image("Belém", 0.35)));
        part1.Add(($"{y23}/IMG_0004.JPG.json", Sidecar("IMG_0004.JPG", D("IMG_0004.JPG"))));
        part1.Add(($"{y23}/IMG_0004(1).JPG", Image("Belém again", 0.45)));
        part1.Add(($"{y23}/IMG_0004.JPG(1).json", Sidecar("IMG_0004.JPG", D("IMG_0004(1).JPG"))));
        // An edited copy shares the original's sidecar.
        part1.Add(($"{y23}/IMG_0005.JPG", Image("Sintra", 0.55)));
        part1.Add(($"{y23}/IMG_0005-edited.JPG", Image("Sintra (edited)", 0.6)));
        part1.Add(($"{y23}/IMG_0005.JPG.json", Sidecar("IMG_0005.JPG", D("IMG_0005.JPG"))));
        // Long name: the sidecar name is cut at 51 characters including ".json".
        var cut = (LongName + ".supplemental-metadata")[..46] + ".json";
        part1.Add(($"{y23}/{LongName}", Image("Screenshot", 0.7)));
        part1.Add(($"{y23}/{cut}", Sidecar(LongName, D(LongName))));
        // Trashed in Google Photos: not copied. Unsupported type: listed as skipped. No sidecar at all.
        part1.Add(($"{y23}/IMG_0009.JPG", Image("Trashed", 0.8)));
        part1.Add(($"{y23}/IMG_0009.JPG.json", Sidecar("IMG_0009.JPG", D("IMG_0005.JPG"), trashed: true)));
        part1.Add(($"{y23}/clip.avi", new byte[2000]));
        part1.Add(($"{y23}/NOSIDECAR.PNG", Image("No sidecar", 0.9)));
        // Album metadata; a 2024 photo only in the album and its year folder, with the sidecar in the other part.
        part2.Add(($"{album}/metadata.json", Jx.Bytes(new JsonObject
        {
            ["title"] = "Lisbon trip", ["description"] = "", ["access"] = "protected", ["date"] = new JsonObject { ["timestamp"] = "1683000000", ["formatted"] = "" },
        })));
        var seven = Image("Miradouro", 0.95);
        part2.Add(($"{album}/IMG_0007.JPG", seven));
        part2.Add(($"{album}/IMG_0007.JPG.json", Sidecar("IMG_0007.JPG", D("IMG_0007.JPG"))));
        part2.Add(($"{y24}/IMG_0007.JPG", seven));
        part1.Add(($"{y24}/IMG_0007.JPG.json", Sidecar("IMG_0007.JPG", D("IMG_0007.JPG"))));
        // Another product in the same export: never treated as photos.
        part2.Add(("Takeout/Drive/holiday.jpg", Image("Not a photo export", 0.3)));

        if (format == "folder")
        {
            var output = Path.Combine(dir, "Takeout export");
            foreach (var (p, data) in part1.Concat(part2))
            {
                var u = Path.Combine(output, p.Replace('/', Path.DirectorySeparatorChar));
                Directory.CreateDirectory(Path.GetDirectoryName(u)!);
                File.WriteAllBytes(u, data);
            }
            return [output];
        }
        var parts = new List<string>();
        foreach (var (files, i) in new[] { part1, part2 }.Select((f, i) => (f, i)))
        {
            var name = $"takeout-20261115T101500Z-{i + 1:000}.{(format == "tgz" ? "tgz" : "zip")}";
            var path = Path.Combine(dir, name);
            WriteArchive(path, files, format);
            parts.Add(path);
        }
        return parts;
    }

    public static void WriteArchive(string path, IEnumerable<(string Name, byte[] Data)> files, string format)
    {
        if (File.Exists(path)) File.Delete(path);   // test output only
        if (format == "tgz")
        {
            using var fs = File.Create(path);
            using var gz = new GZipStream(fs, CompressionLevel.Fastest);
            using var tar = new TarWriter(gz, TarEntryFormat.Pax);
            foreach (var (n, data) in files) tar.WriteEntry(new PaxTarEntry(TarEntryType.RegularFile, n) { DataStream = new MemoryStream(data) });
        }
        else
        {
            using var zip = ZipFile.Open(path, ZipArchiveMode.Create);
            foreach (var (n, data) in files)
            {
                using var s = zip.CreateEntry(n, CompressionLevel.Fastest).Open();
                s.Write(data);
            }
        }
    }
}
