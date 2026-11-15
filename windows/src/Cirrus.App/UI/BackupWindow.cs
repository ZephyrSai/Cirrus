using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Cirrus.Core;

namespace Cirrus.App.UI;

/// <summary>
/// Back up a whole iCloud account (Drive + every Photos library) to a folder or drive: Check Space shows
/// what's needed against free space (with FAT32, system-drive and ADP warnings) before anything is copied.
/// Backups only ever read from iCloud.
/// </summary>
sealed class BackupWindow : Window
{
    readonly ComboBox _account = new() { MinWidth = 260 };
    readonly TextBox _dest = new() { MinWidth = 260 };
    readonly ComboBox _drives = new() { MinWidth = 260, Margin = new Thickness(0, 4, 0, 0) };
    readonly CheckBox _drive, _photos, _live, _edited, _raw, _hidden, _shared, _albums, _archive, _verify;
    readonly TextBlock _summary = Ui.Text("Choose a destination, then Check Space.", 13);
    readonly StackPanel _warnings = new();
    readonly Button _check, _run, _save;
    readonly ProgressBar _spinner = new() { IsIndeterminate = true, Height = 3, Visibility = Visibility.Hidden, Margin = new Thickness(0, 6, 0, 6) };
    BackupEngine.Evaluation? _ev;
    CancellationTokenSource? _cts;

    public BackupWindow(string? accountID)
    {
        Title = "Back Up iCloud";
        Width = 620;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var o = new SyncOptions();
        _drive = Ui.Check("iCloud Drive — all files and folders", o.IncludeDrive, _ => Invalidate());
        _photos = Ui.Check("Photos and videos — original files", o.IncludePhotos, _ => Invalidate());
        _live = Ui.Check("Live Photo videos (.MOV)", o.IncludeLive, _ => Invalidate());
        _edited = Ui.Check("Edited versions too (-edited)", o.IncludeEdited, _ => Invalidate());
        _raw = Ui.Check("RAW files of RAW+JPEG pairs", o.IncludeRAW, _ => Invalidate());
        _hidden = Ui.Check("Hidden album", o.IncludeHidden, _ => Invalidate());
        _shared = Ui.Check("Shared Library", o.IncludeSharedLibrary, _ => Invalidate());
        _albums = Ui.Check("Album folders (links, no extra space; NTFS with Developer Mode)", o.AlbumFolders, _ => Invalidate());
        _archive = Ui.Check("Keep files that were deleted from iCloud (recommended)", o.KeepDeleted, _ => Invalidate());
        _verify = Ui.Check("Verify each download’s size", o.Verify);
        foreach (var c in new[] { _live, _edited, _raw, _hidden, _shared, _albums }) c.Margin = new Thickness(22, 2, 0, 2);

        var accounts = AccountManager.Shared.Accounts.Where(a => a.HasDrive || a.Photos is not null || a.PhotosRoot is not null).ToList();
        _account.ItemsSource = accounts.Select(a => a.Kind switch { AccountKind.Demo => "Demo iCloud", AccountKind.Native => "iCloud for Windows (this PC’s folders)", _ => $"{a.Title} ({a.AppleID})" }).ToList();
        _account.Tag = accounts;
        _account.SelectedIndex = Math.Max(0, accounts.FindIndex(a => a.Id == accountID));
        _account.SelectionChanged += (_, _) => Invalidate();

        var browse = Ui.Button("Choose…", Browse);
        var destRow = new DockPanel();
        DockPanel.SetDock(browse, Dock.Right);
        destRow.Children.Add(browse);
        destRow.Children.Add(_dest);
        _dest.TextChanged += (_, _) => Invalidate();
        var vols = VolumeInfo.All().Where(v => !v.IsRoot).ToList();
        _drives.ItemsSource = new[] { "Pick a drive…" }.Concat(vols.Select(v => $"{v.DisplayName} — {v.Available.ByteString()} free ({v.Format})")).ToList();
        _drives.SelectedIndex = 0;
        _drives.SelectionChanged += (_, _) => { if (_drives.SelectedIndex > 0) _dest.Text = vols[_drives.SelectedIndex - 1].Root; };
        if (vols.FirstOrDefault(v => v.IsRemovable || !v.IsFixed) is { } ext) _dest.Text = ext.Root;

        _check = Ui.Button("Check Space", Check);
        _run = Ui.Button("Back Up Now", Run, accent: true);
        _run.IsEnabled = false;
        _save = Ui.Button("Save as Automatic Backup…", SaveJob);
        var close = Ui.Button("Close", Close, isCancel: true);

        var root = Ui.Stack(
            Ui.Text("Copies everything Cirrus can read from iCloud to a folder or drive you choose, as ordinary files. Nothing in iCloud is changed or removed.", 12, opacity: 0.75),
            Ui.Labeled("Account", _account),
            Ui.Labeled("Back up to", Ui.Stack(destRow, _drives)),
            Ui.Header("Include"),
            _drive, _photos, _live, _edited, _raw, _hidden, _shared, _albums, _archive, _verify,
            Ui.Header("Space"),
            Ui.Card(Ui.Stack(_summary, _spinner, _warnings)),
            Ui.Buttons(_save, _check, _run, close));
        root.Margin = new Thickness(24, 16, 24, 18);
        Content = new ScrollViewer { Content = root, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MaxHeight = SystemParameters.WorkArea.Height - 60 };
        Closed += (_, _) => _cts?.Cancel();
    }

    Account? SelectedAccount => _account.Tag is List<Account> l && _account.SelectedIndex >= 0 && _account.SelectedIndex < l.Count ? l[_account.SelectedIndex] : null;

    SyncOptions Options() => new()
    {
        IncludeDrive = _drive.IsChecked == true, IncludePhotos = _photos.IsChecked == true, IncludeLive = _live.IsChecked == true,
        IncludeEdited = _edited.IsChecked == true, IncludeRAW = _raw.IsChecked == true, IncludeHidden = _hidden.IsChecked == true,
        IncludeSharedLibrary = _shared.IsChecked == true, AlbumFolders = _albums.IsChecked == true, KeepDeleted = _archive.IsChecked == true,
        Verify = _verify.IsChecked == true,
    };

    void Invalidate()
    {
        _ev = null;
        _run.IsEnabled = false;
        foreach (var c in new[] { _live, _edited, _raw, _hidden, _shared, _albums }) c.IsEnabled = _photos.IsChecked == true;
    }

    void Browse()
    {
        var dlg = new Microsoft.Win32.OpenFolderDialog { Title = "Back up to" };
        if (Directory.Exists(_dest.Text)) dlg.InitialDirectory = _dest.Text;
        if (dlg.ShowDialog(this) == true) _dest.Text = dlg.FolderName;
    }

    SyncJob? Job()
    {
        if (SelectedAccount is not { } a) { Dialogs.Error(this, "Choose an account", "Pick the iCloud account to back up."); return null; }
        var dest = _dest.Text.Trim();
        if (dest.Length == 0 || !Directory.Exists(dest)) { Dialogs.Error(this, "Choose a destination", "Pick a folder or drive that exists."); return null; }
        if (SafetyPolicy.IsICloudPath(dest)) { Dialogs.Error(this, "Choose a place outside iCloud", "A backup inside the iCloud for Windows folders would be uploaded back to iCloud. Pick another folder or an external drive."); return null; }
        return new SyncJob($"Back up {(a.Kind == AccountKind.Demo ? "Demo iCloud" : a.Title)}", JobKind.Backup, SyncEndpoint.ForAccount(a.Id), SyncEndpoint.Local(dest)) { Options = Options() };
    }

    async void Check()
    {
        if (Job() is not { } job) return;
        _cts?.Cancel();
        _cts = new CancellationTokenSource();
        _check.IsEnabled = false; _run.IsEnabled = false;
        _spinner.Visibility = Visibility.Visible;
        _warnings.Children.Clear();
        try
        {
            var preview = await JobEngine.Shared.PreviewAsync(job, s => Dispatcher.InvokeAsync(() => _summary.Text = s), _cts.Token);
            var ev = preview.Backup!;
            _ev = ev;
            var lines = new List<string>
            {
                $"iCloud Drive: {ev.DriveFiles:N0} files, {ev.DriveBytes.ByteString()}",
                $"Photos: {ev.PhotoCount:N0} items, {ev.PhotosBytes.ByteString()}",
                ev.PendingBytes == 0 ? "Everything is already backed up." : $"To copy now: {ev.PendingBytes.ByteString()} (of {ev.TotalBytes.ByteString()})",
                $"Free on “{ev.Volume?.DisplayName ?? _dest.Text}”: {ev.Free.ByteString()} — needs {ev.RequiredFree.ByteString()} with headroom",
            };
            if (ev.Storage is { } st) lines.Add($"iCloud storage in use: {st.Used.ByteString()} of {st.Total.ByteString()}");
            _summary.Text = string.Join("\n", lines);
            foreach (var w in ev.Warnings)
            {
                var t = Ui.Text("⚠ " + w, 12);
                t.Foreground = Brushes.DarkOrange;
                _warnings.Children.Add(t);
            }
            _run.IsEnabled = ev.Fits && !ev.DestinationIsICloud;
        }
        catch (OperationCanceledException) { }
        catch (Exception e) { _summary.Text = "Couldn’t check: " + e.Message; }
        finally { _check.IsEnabled = true; _spinner.Visibility = Visibility.Hidden; }
    }

    void Run()
    {
        if (_ev is not { Fits: true } || Job() is not { } job) return;
        if (_ev.Volume?.IsRoot == true && !Dialogs.Confirm(this, "Back up to the system drive?", "If this PC fails, the backup goes with it. An external drive is safer.", "Back Up Anyway")) return;
        if (JobEngine.Shared.Run(job) is null) return;
        if (Owner is MainWindow mw) mw.SetTransfersVisible(true);
        _summary.Text = "Backing up — follow the progress in Transfers. You can close this window.";
        _run.IsEnabled = false;
    }

    void SaveJob()
    {
        if (Job() is not { } job) return;
        var vol = VolumeInfo.Info(job.Destination.Path!);
        var external = vol is { IsRoot: false } && vol.Id is not null;
        var choice = Dialogs.Ask(this, "Save as an automatic backup",
            external ? $"Run this backup whenever “{vol!.DisplayName}” is connected (at most twice a day), or every night at 2:00?" : "Run this backup every night at 2:00 while Cirrus is open?",
            external ? ["When Connected", "Nightly", "Cancel"] : ["Nightly", "Cancel"], 0, external ? 2 : 1);
        if (external && choice == 0) job.Schedule = JobSchedule.WhenConnected(vol!.Id!);
        else if ((external && choice == 1) || (!external && choice == 0)) job.Schedule = JobSchedule.Daily(2);
        else return;
        SyncStore.Shared.Upsert(job);
        Dialogs.Info(this, "Saved", $"“{job.Name}” will run {job.Schedule.Title.ToLowerInvariant()}. Manage it in Sync Jobs.");
    }
}
