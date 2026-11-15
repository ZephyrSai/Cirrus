namespace Cirrus.Core;

/// <summary>MIME types for iCloud Drive uploads (stand-in for UTType.preferredMIMEType).</summary>
public static class Mime
{
    static readonly Dictionary<string, string> Map = new(StringComparer.OrdinalIgnoreCase)
    {
        ["txt"] = "text/plain", ["md"] = "text/markdown", ["csv"] = "text/csv", ["tsv"] = "text/tab-separated-values", ["rtf"] = "text/rtf",
        ["html"] = "text/html", ["htm"] = "text/html", ["css"] = "text/css", ["js"] = "text/javascript", ["json"] = "application/json",
        ["xml"] = "application/xml", ["pdf"] = "application/pdf", ["zip"] = "application/zip", ["gz"] = "application/gzip",
        ["7z"] = "application/x-7z-compressed", ["rar"] = "application/vnd.rar", ["tar"] = "application/x-tar",
        ["doc"] = "application/msword", ["docx"] = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        ["xls"] = "application/vnd.ms-excel", ["xlsx"] = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        ["ppt"] = "application/vnd.ms-powerpoint", ["pptx"] = "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        ["pages"] = "application/vnd.apple.pages", ["numbers"] = "application/vnd.apple.numbers", ["key"] = "application/vnd.apple.keynote",
        ["jpg"] = "image/jpeg", ["jpeg"] = "image/jpeg", ["png"] = "image/png", ["gif"] = "image/gif", ["heic"] = "image/heic",
        ["heif"] = "image/heif", ["tif"] = "image/tiff", ["tiff"] = "image/tiff", ["webp"] = "image/webp", ["avif"] = "image/avif",
        ["bmp"] = "image/bmp", ["svg"] = "image/svg+xml", ["dng"] = "image/x-adobe-dng", ["ico"] = "image/vnd.microsoft.icon",
        ["mov"] = "video/quicktime", ["mp4"] = "video/mp4", ["m4v"] = "video/x-m4v", ["avi"] = "video/x-msvideo", ["mkv"] = "video/x-matroska",
        ["mp3"] = "audio/mpeg", ["m4a"] = "audio/mp4", ["wav"] = "audio/wav", ["aac"] = "audio/aac", ["flac"] = "audio/flac",
        ["exe"] = "application/vnd.microsoft.portable-executable", ["msi"] = "application/x-msi", ["dmg"] = "application/x-apple-diskimage",
        ["epub"] = "application/epub+zip", ["ics"] = "text/calendar", ["vcf"] = "text/vcard",
    };

    public static string ForName(string name)
    {
        var ext = Path.GetExtension(name).TrimStart('.');
        return ext.Length > 0 && Map.TryGetValue(ext, out var m) ? m : "application/octet-stream";
    }

    public static bool IsImage(string name) => ForName(name).StartsWith("image/", StringComparison.Ordinal);
    public static bool IsVideo(string name) => ForName(name).StartsWith("video/", StringComparison.Ordinal);
}
