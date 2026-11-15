using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Windows.Media;
using Cirrus.App.Platform;
using Cirrus.Core;

namespace Cirrus.App.Model;

public enum LocKind { Computer, Local, Drive, DriveTrash, Photos, Album }

/// <summary>Everything a tab can show. Value equality, so it works for history and tab de-duplication.</summary>
public sealed record Location(LocKind Kind, string? Path = null, string? Account = null, string? Id = null, string? Library = null)
{
    public static Location Computer { get; } = new(LocKind.Computer);
    public static Location Local(string path) => new(LocKind.Local, Normalize(path));
    public static Location Drive(string account, string folderID) => new(LocKind.Drive, Account: account, Id: folderID);
    public static Location DriveTrash(string account) => new(LocKind.DriveTrash, Account: account);
    /// <summary>A Photos library's home (albums), or an album folder inside it.</summary>
    public static Location Photos(string account, string library, string? folderID = null) => new(LocKind.Photos, Account: account, Library: library, Id: folderID);
    public static Location Album(string account, string library, string albumID) => new(LocKind.Album, Account: account, Library: library, Id: albumID);

    public static Location Home() => Local(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));

    static string Normalize(string p)
    {
        try
        {
            var full = System.IO.Path.GetFullPath(p);
            var root = System.IO.Path.GetPathRoot(full);
            return full.Length > (root?.Length ?? 0) ? full.TrimEnd(System.IO.Path.DirectorySeparatorChar) : full;
        }
        catch { return p; }
    }

    public bool IsPhotoGrid => Kind == LocKind.Album;
    public bool IsRemote => Kind is LocKind.Drive or LocKind.DriveTrash or LocKind.Photos or LocKind.Album;
    public Account? AccountRef => Account is null ? null : AccountManager.Shared.Account(Account);
}

/// <summary>A row/tile in a tab: local file, iCloud Drive item, photo, album or drive.</summary>
public sealed class Item : INotifyPropertyChanged
{
    public required string Key { get; init; }
    public required string Name { get; init; }
    public bool IsContainer { get; init; }
    public long? Size { get; init; }
    public DateTimeOffset? Modified { get; init; }
    public DateTimeOffset? Created { get; init; }
    public string? LocalPath { get; init; }
    public DriveNode? Node { get; init; }
    public PhotoAsset? Photo { get; set; }
    public PhotoAlbum? Album { get; init; }
    public VolumeInfo? Volume { get; init; }
    /// <summary>Where double-click goes for containers.</summary>
    public Location? Target { get; init; }
    public string? AccountID { get; init; }
    public int? Count { get; init; }
    public bool IsHiddenFile { get; init; }
    public LocalFiles.CloudState Cloud { get; init; }
    public string Glyph { get; init; } = "";

    string? _kind;
    public string KindText
    {
        get
        {
            if (_kind is not null) return _kind;
            if (Album is { } a) return _kind = a.Kind switch { PhotoAlbumKind.Folder => "Album Folder", PhotoAlbumKind.Smart => "Smart Album", _ => "Album" };
            if (Volume is { } v) return _kind = v.IsRemovable ? "Removable Disk" : v.IsNetwork ? "Network Drive" : "Local Disk";
            if (Photo is { IsVideo: true }) return _kind = "Video";
            if (Photo is not null) return _kind = "Photo";
            return _kind = ShellIcons.TypeName(Name, IsContainer);
        }
    }

    public string SizeText => IsContainer
        ? (Count is int c ? $"{c} item{(c == 1 ? "" : "s")}" : Volume is { } v ? $"{v.Available.ByteString()} free of {v.Total.ByteString()}" : "")
        : Size is long s ? s.ByteString() : "";

    public string DateText => (Modified ?? Created) is { } d ? d.ToLocalTime().ToString("g", CultureInfo.CurrentCulture) : "";

    public string CloudText => Cloud switch
    {
        LocalFiles.CloudState.CloudOnly => "Available when online",
        LocalFiles.CloudState.Downloaded => "Available on this device",
        LocalFiles.CloudState.Pinned => "Always available",
        _ => Node is not null || Photo is not null ? "In iCloud" : "",
    };

    public bool IsPhoto => Photo is not null;
    public bool IsVideo => Photo?.IsVideo ?? Mime.IsVideo(Name);
    public bool IsImage => Photo is not null || Mime.IsImage(Name);
    public bool IsFavorite => Photo?.IsFavorite ?? false;
    public bool IsLive => Photo?.IsLive ?? false;
    public string DurationText => Photo?.Duration is double d && d > 0 ? TimeSpan.FromSeconds(d).ToString(d >= 3600 ? @"h\:mm\:ss" : @"m\:ss") : "";

    ImageSource? _icon, _thumb;
    bool _selected;
    public ImageSource? Icon { get => _icon; set { _icon = value; On(); On(nameof(Picture)); } }
    public ImageSource? Thumbnail { get => _thumb; set { _thumb = value; On(); On(nameof(Picture)); On(nameof(HasPicture)); } }
    /// <summary>Thumbnail when loaded, otherwise the type icon.</summary>
    public ImageSource? Picture => _thumb ?? _icon;
    public bool HasPicture => _thumb is not null;
    public bool IsSelected { get => _selected; set { if (_selected == value) return; _selected = value; On(); } }

    /// <summary>Bytes a full copy needs (folders unknown).</summary>
    public long TransferSize => Size ?? 0;

    public TransferItem AsTransferItem() => new(Name, Size, IsContainer, Node, AccountManager.Shared.Account(AccountID)?.Drive, Photo, Album);

    public event PropertyChangedEventHandler? PropertyChanged;
    void On([CallerMemberName] string? p = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(p));
    public void Refresh() { _kind = null; On(nameof(IsFavorite)); On(nameof(KindText)); }
}

/// <summary>What a location allows.</summary>
public sealed record LocationCaps(bool CanCreateFolder = false, string NewFolderTitle = "New Folder", bool AcceptsDrops = false, bool CanRename = false,
    bool CanTrash = false, bool IsTrash = false, bool CanDeleteForever = false, bool IsICloud = false);

/// <summary>A month header or a row of photo tiles in the photo grid (rows keep the grid virtualised).</summary>
public sealed class PhotoRow
{
    public string? Header { get; init; }
    public List<Item> Cells { get; init; } = [];
    public bool IsHeader => Header is not null;
}
