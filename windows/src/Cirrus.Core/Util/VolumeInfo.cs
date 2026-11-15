using System.Runtime.InteropServices;
using System.Text;

namespace Cirrus.Core;

/// <summary>A mounted volume: drive letter, USB stick, network share…</summary>
public sealed record VolumeInfo
{
    public required string Root { get; init; }          // "C:\", "E:\", "\\server\share\" or "/" elsewhere
    public required string Name { get; init; }
    public bool IsRemovable { get; init; }
    public bool IsNetwork { get; init; }
    public bool IsFixed { get; init; }
    /// <summary>The system (startup) drive, e.g. C:.</summary>
    public bool IsRoot { get; init; }
    public long Available { get; init; }
    public long Total { get; init; }
    /// <summary>File system: NTFS, ReFS, exFAT, FAT32…</summary>
    public string? Format { get; init; }
    /// <summary>Stable id for "run when this drive is connected" (volume GUID on Windows).</summary>
    public string? Id { get; init; }

    public bool IsFat32 => Format is { } f && f.Contains("fat", StringComparison.OrdinalIgnoreCase) && !f.Contains("exfat", StringComparison.OrdinalIgnoreCase);

    public string DisplayName => string.IsNullOrEmpty(Name)
        ? Root.TrimEnd('\\')
        : (Root.Length <= 3 && Root.EndsWith(":\\") ? $"{Name} ({Root.TrimEnd('\\')})" : Name);

    /// <summary>Volume holding an arbitrary path (walks up to the nearest existing folder first).</summary>
    public static VolumeInfo? Info(string path)
    {
        try
        {
            var p = ExistingAncestor(path);
            if (p is null) return null;
            return OperatingSystem.IsWindows() ? Win.Info(p) : Unix(p);
        }
        catch (Exception e) { Log.Debug("volume info failed: " + e.GetType().Name); return null; }
    }

    public static long? FreeSpace(string path) => Info(path)?.Available;

    /// <summary>Removable, fixed and network volumes that are ready, system drive first.</summary>
    public static List<VolumeInfo> All()
    {
        var list = new List<VolumeInfo>();
        foreach (var d in DriveInfo.GetDrives())
        {
            try
            {
                if (!d.IsReady) continue;
                if (!OperatingSystem.IsWindows() && d.DriveType is DriveType.Ram or DriveType.Unknown) continue;
                if (!OperatingSystem.IsWindows() && d.RootDirectory.FullName != "/" && !d.RootDirectory.FullName.StartsWith("/Volumes/")) continue;
                if (Info(d.RootDirectory.FullName) is { } v) list.Add(v);
            }
            catch { }
        }
        return list.OrderBy(v => v.IsRoot ? 0 : 1).ThenBy(v => v.Root, StringComparer.OrdinalIgnoreCase).ToList();
    }

    internal static string? ExistingAncestor(string path)
    {
        if (string.IsNullOrEmpty(path)) return null;
        var p = Path.GetFullPath(path);
        while (!Directory.Exists(p) && !File.Exists(p))
        {
            var parent = Path.GetDirectoryName(p);
            if (string.IsNullOrEmpty(parent) || parent == p) return null;
            p = parent;
        }
        return p;
    }

    static VolumeInfo Unix(string path)
    {
        var d = new DriveInfo(path);
        return new VolumeInfo
        {
            Root = d.RootDirectory.FullName, Name = d.VolumeLabel is { Length: > 0 } l ? l : d.Name,
            IsRemovable = d.DriveType == DriveType.Removable, IsNetwork = d.DriveType == DriveType.Network,
            IsFixed = d.DriveType == DriveType.Fixed, IsRoot = d.RootDirectory.FullName == "/",
            Available = d.AvailableFreeSpace, Total = d.TotalSize, Format = d.DriveFormat, Id = d.Name,
        };
    }

    /// <summary>Win32 volume queries (work for drive letters, mounted folders and UNC shares).</summary>
    internal static class Win
    {
        public static VolumeInfo Info(string path)
        {
            var sb = new StringBuilder(1024);
            var root = GetVolumePathNameW(path, sb, sb.Capacity) ? sb.ToString() : Path.GetPathRoot(path) ?? path;
            if (!root.EndsWith('\\')) root += "\\";
            var type = GetDriveTypeW(root);
            var label = new StringBuilder(261);
            var fs = new StringBuilder(261);
            GetVolumeInformationW(root, label, label.Capacity, out var serial, out _, out _, fs, fs.Capacity);
            GetDiskFreeSpaceExW(root, out var avail, out var total, out _);
            var sys = Path.GetPathRoot(Environment.SystemDirectory) ?? "C:\\";
            return new VolumeInfo
            {
                Root = root, Name = label.ToString(),
                IsRemovable = type == 2, IsFixed = type == 3, IsNetwork = type == 4,
                IsRoot = string.Equals(root, sys, StringComparison.OrdinalIgnoreCase),
                Available = (long)avail, Total = (long)total, Format = fs.Length > 0 ? fs.ToString() : null,
                Id = VolumeGuid(root) ?? (serial != 0 ? serial.ToString("X8") : null),
            };
        }

        /// <summary>"{xxxxxxxx-…}" for a volume root such as "C:\".</summary>
        public static string? VolumeGuid(string root)
        {
            var sb = new StringBuilder(64);
            if (!GetVolumeNameForVolumeMountPointW(root, sb, sb.Capacity)) return null;
            var s = sb.ToString();                      // \\?\Volume{GUID}\
            var a = s.IndexOf('{'); var b = s.IndexOf('}');
            return a >= 0 && b > a ? s[a..(b + 1)] : null;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool GetVolumePathNameW(string fileName, StringBuilder volumePathName, int bufferLength);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        static extern uint GetDriveTypeW(string rootPathName);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool GetVolumeInformationW(string rootPathName, StringBuilder volumeName, int volumeNameSize,
            out uint serialNumber, out uint maxComponentLength, out uint flags, StringBuilder fileSystemName, int fileSystemNameSize);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool GetDiskFreeSpaceExW(string directoryName, out ulong freeBytesAvailable, out ulong totalBytes, out ulong totalFreeBytes);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool GetVolumeNameForVolumeMountPointW(string mountPoint, StringBuilder volumeName, int bufferLength);
    }
}
