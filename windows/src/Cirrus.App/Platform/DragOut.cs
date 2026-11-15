using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Threading;
using Cirrus.App.Model;
using Cirrus.App.Services;
using Cirrus.Core;

namespace Cirrus.App.Platform;

/// <summary>
/// Drag source for Cirrus items. Inside Cirrus it carries the items themselves. Towards Explorer it offers a
/// file list whose iCloud items are downloaded lazily: only when the drop actually happens (mouse button
/// released) does it fetch them into a staging folder, then hands Explorer the real paths.
/// </summary>
sealed class CirrusDataObject : IDataObject
{
    public const string InternalFormat = "Cirrus.Items";
    public sealed record Payload(IReadOnlyList<Item> Items, Location Source);

    readonly Payload _payload;
    readonly string _staging = Path.Combine(Paths.CacheDir("dragout"), Guid.NewGuid().ToString("N"));
    string[]? _paths;
    bool _materialized, _failed;

    public CirrusDataObject(IReadOnlyList<Item> items, Location source) { _payload = new Payload(items, source); }

    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vKey);
    static bool MouseButtonDown => (GetAsyncKeyState(0x01) & 0x8000) != 0 || (GetAsyncKeyState(0x02) & 0x8000) != 0;

    string[] PlannedPaths()
    {
        if (_paths is not null) return _paths;
        var taken = new HashSet<string>();
        _paths = _payload.Items.Select(i =>
        {
            if (i.LocalPath is { } lp) return lp;
            var name = Ops.UniqueName(Ops.OutputName(i), taken);
            taken.Add(name.ToLowerInvariant());
            return Path.Combine(_staging, name);
        }).ToArray();
        return _paths;
    }

    string[]? FilesForDrop()
    {
        var paths = PlannedPaths();
        if (_payload.Items.All(i => i.LocalPath is not null) || _materialized) return paths;
        if (MouseButtonDown) return paths;   // still dragging: Explorer is only looking
        if (_failed) return null;
        // The drop is happening: download now, keeping the window responsive.
        Directory.CreateDirectory(_staging);
        var remote = _payload.Items.Select((item, idx) => (item, path: paths[idx])).Where(x => x.item.LocalPath is null).ToList();
        var transfer = TransferManager.Shared.Enqueue(remote.Count == 1 ? remote[0].item.Name : $"{remote.Count} items for Explorer", async (t, ct) =>
        {
            long done = 0;
            foreach (var (item, path) in remote)
            {
                var b = done;
                await Task.Run(() => Ops.Materialize(item, _staging, Settings.Current.ExportLive, Path.GetFileName(path), (d, _) => t.Report(b + d, 0), ct), ct);
                done += item.TransferSize;
            }
        }, "Downloading for drag and drop", TransferDirection.Download, remote.Sum(r => r.item.TransferSize), quotaKey: Preflight.VolumeKey(_staging));
        Wait(TransferManager.Shared.WaitFor(transfer));
        if (transfer.State != TransferState.Done)
        {
            _failed = true;
            Log.Error("drag-out download failed: " + transfer.Error);
            return null;
        }
        _materialized = true;
        return paths;
    }

    static void Wait(Task task)
    {
        try
        {
            var frame = new DispatcherFrame();
            task.ContinueWith(_ => frame.Continue = false, TaskScheduler.Default);
            Dispatcher.PushFrame(frame);
        }
        catch (InvalidOperationException) { task.Wait(); }   // dispatcher suspended: block (work runs on the thread pool)
    }

    public void Finish()
    {
        // Leave the staging copy for Explorer (it may still be copying); old staging folders are cleared at startup.
    }

    public object? GetData(string format) => GetData(format, true);
    public object? GetData(Type format) => GetData(format.FullName ?? "", true);
    public object? GetData(string format, bool autoConvert)
    {
        if (format == InternalFormat) return _payload;
        if (format == DataFormats.FileDrop) return FilesForDrop();
        return null;
    }

    public bool GetDataPresent(string format) => format == InternalFormat || format == DataFormats.FileDrop;
    public bool GetDataPresent(Type format) => false;
    public bool GetDataPresent(string format, bool autoConvert) => GetDataPresent(format);
    public string[] GetFormats() => [InternalFormat, DataFormats.FileDrop];
    public string[] GetFormats(bool autoConvert) => GetFormats();
    public void SetData(object data) { }
    public void SetData(string format, object data) { }
    public void SetData(Type format, object data) { }
    public void SetData(string format, object data, bool autoConvert) { }

    /// <summary>Clears Cirrus' own scratch copies (drag-out staging, relays, temp downloads) older than a day.</summary>
    public static void CleanupOldStaging()
    {
        foreach (var name in new[] { "dragout", "relay", "tmp", "open" })
        {
            try
            {
                foreach (var d in Directory.EnumerateDirectories(Paths.CacheDir(name)))
                    if (Directory.GetLastWriteTimeUtc(d) < DateTime.UtcNow.AddDays(-1)) Directory.Delete(d, true);
            }
            catch { }
        }
    }
}
