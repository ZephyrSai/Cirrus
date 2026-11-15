using System.Text.Json;
using System.Text.Json.Serialization;

namespace Cirrus.Core;

/// <summary>User preferences (settings.json in the Cirrus data folder). Port of Prefs.swift plus Windows bits.</summary>
public sealed class Settings
{
    public static Settings Current { get; private set; } = new();

    public bool ShowHidden { get; set; }
    public bool FoldersOnTop { get; set; } = true;
    public bool ExportLive { get; set; } = true;
    public bool ExportEdited { get; set; }
    public int MaxTransfers { get; set; } = 4;
    public bool GroupPhotosByMonth { get; set; } = true;
    public bool ShowStatusBar { get; set; } = true;
    public bool ShowPathBar { get; set; } = true;
    public bool SquarePhotoGrid { get; set; } = true;
    public double IconSize { get; set; } = 64;
    public double PhotoSize { get; set; } = 120;
    public string ViewMode { get; set; } = "details";
    /// <summary>Saved passwords need Windows Hello / the Windows password before Cirrus may use them.</summary>
    public bool RequireAuthForSavedPassword { get; set; } = true;
    /// <summary>null until the user changes it; then the default (on for TESTER builds) no longer applies.</summary>
    public bool? ReadOnlyICloudSetting { get; set; }
    public string? NativePhotosFolder { get; set; }
    public List<string> Favorites { get; set; } = DefaultFavorites();
    public List<string> RecentTabs { get; set; } = [];

    [JsonIgnore] public bool TesterBuild { get; private set; }

    [JsonIgnore]
    public bool ReadOnlyICloud
    {
        get => ReadOnlyICloudSetting ?? TesterBuild;
        set { ReadOnlyICloudSetting = value; SafetyPolicy.ReadOnlyICloud = value; Save(); }
    }

    static List<string> DefaultFavorites()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var list = new List<string> { home };
        foreach (var f in new[] { Environment.SpecialFolder.DesktopDirectory, Environment.SpecialFolder.MyDocuments, Environment.SpecialFolder.MyPictures })
            if (Environment.GetFolderPath(f) is { Length: > 0 } p) list.Add(p);
        list.Add(Path.Combine(home, "Downloads"));
        return list.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
    }

    static string FilePath => Path.Combine(Paths.AppSupport, "settings.json");
    static readonly JsonSerializerOptions Opts = new() { WriteIndented = true };

    /// <summary>Loads settings and applies the engine-level safety switch (read-only defaults on for TESTER builds).</summary>
    public static Settings Load(bool testerBuild)
    {
        Settings s;
        try { s = File.Exists(FilePath) ? JsonSerializer.Deserialize<Settings>(File.ReadAllBytes(FilePath), Opts) ?? new() : new(); }
        catch { s = new(); }
        s.TesterBuild = testerBuild;
        SafetyPolicy.ReadOnlyICloud = s.ReadOnlyICloud;
        SafetyPolicy.ExtraNativeRoot = s.NativePhotosFolder;
        TransferManager.Shared.MaxConcurrent = Math.Clamp(s.MaxTransfers, 1, 12);
        Current = s;
        return s;
    }

    public void Save() => AtomicFile.Write(FilePath, JsonSerializer.SerializeToUtf8Bytes(this, Opts));
}
