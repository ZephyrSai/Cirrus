using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Cirrus.App.Model;
using Cirrus.Core;

namespace Cirrus.App.UI;

/// <summary>Sync jobs: folder sync (copy / mirror / two-way), Photos export and import, backups; preview before running.</summary>
sealed class SyncJobsWindow : Window
{
    readonly ListBox _list = new() { Height = 300, BorderThickness = new Thickness(1) };
    readonly TextBlock _detail = Ui.Text("", 12, opacity: 0.8);
    readonly Button _edit, _remove, _preview, _run;

    public SyncJobsWindow()
    {
        Title = "Sync Jobs";
        Width = 720;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        _edit = Ui.Button("Edit…", Edit);
        _remove = Ui.Button("Remove…", Remove);
        _preview = Ui.Button("Preview", Preview);
        _run = Ui.Button("Run Now", () => RunSelected(false), accent: true);
        var add = Ui.Button("New Job…", Add);
        add.Margin = new Thickness(0);
        var bar = new DockPanel { Margin = new Thickness(0, 12, 0, 0) };
        DockPanel.SetDock(add, Dock.Left);
        bar.Children.Add(add);
        var right = Ui.Row(_edit, _remove, _preview, _run, Ui.Button("Close", Close, isCancel: true));
        right.HorizontalAlignment = HorizontalAlignment.Right;
        bar.Children.Add(right);
        var root = Ui.Stack(
            Ui.Text("Jobs run in the background while Cirrus is open: manually, on a schedule, or when a backup drive is plugged in. Removals only ever go to the Recycle Bin or iCloud’s Recently Deleted, and a run that would remove a large share of the files stops for review.", 12, opacity: 0.75),
            _list, Ui.Card(_detail), bar);
        root.Margin = new Thickness(20);
        Content = root;
        _list.SelectionChanged += (_, _) => Sync();
        _list.MouseDoubleClick += (_, _) => Edit();
        SyncStore.Shared.Changed += Reload;
        Closed += (_, _) => SyncStore.Shared.Changed -= Reload;
        Reload();
    }

    SyncJob? Selected => _list.SelectedItem is ListBoxItem { Tag: SyncJob j } ? j : null;

    void Reload()
    {
        Dispatcher.InvokeAsync(() =>
        {
            var keep = Selected?.Id;
            _list.Items.Clear();
            foreach (var j in SyncStore.Shared.Jobs)
            {
                var running = SyncStore.Shared.IsRunning(j.Id);
                var head = Ui.Text(j.Name + (running ? "  — running…" : j.Enabled ? "" : "  — paused"), 13, bold: true);
                var sub = Ui.Text($"{Kind(j)}: {Describe(j.Source)} → {Describe(j.Destination)} · {j.Schedule.Title}", 12, opacity: 0.75);
                var last = Ui.Text(j.LastRun is { } lr ? $"Last run {lr.LocalDateTime:g}: {j.LastResult}" : "Never run", 11, opacity: 0.6);
                if (j.LastSuccess == false) last.Foreground = Brushes.IndianRed;
                var item = new ListBoxItem { Content = Ui.Stack(head, sub, last), Tag = j, Padding = new Thickness(8, 6, 8, 6) };
                _list.Items.Add(item);
                if (j.Id == keep) _list.SelectedItem = item;
            }
            if (_list.Items.Count == 0) _list.Items.Add(new ListBoxItem { Content = Ui.Text("No jobs yet. Choose New Job… to keep a folder in sync or export Photos on a schedule.", 12, opacity: 0.7), IsEnabled = false });
            Sync();
        });
    }

    void Sync()
    {
        var j = Selected;
        _edit.IsEnabled = _remove.IsEnabled = _preview.IsEnabled = _run.IsEnabled = j is not null;
        if (j is not null) _run.IsEnabled = !SyncStore.Shared.IsRunning(j.Id);
        _detail.Text = j is null ? "Select a job to preview or run it." : $"{(j.Kind == JobKind.FolderSync ? j.Mode.Title() : Kind(j))}. Excludes: {string.Join(", ", j.Options.Excludes.Take(6))}{(j.Options.Excludes.Count > 6 ? "…" : "")}";
    }

    internal static string Kind(SyncJob j) => j.Kind switch
    {
        JobKind.FolderSync => j.Mode switch { SyncMode.Mirror => "Mirror", SyncMode.TwoWay => "Two-way sync", _ => "Copy" },
        JobKind.PhotosExport => "Photos export",
        JobKind.PhotosImport => "Photos import",
        _ => "Backup",
    };

    internal static string Describe(SyncEndpoint e) => e.Kind switch
    {
        EndpointKind.Local => e.Path ?? "",
        EndpointKind.Account => AccountManager.Shared.Account(e.Account) is { } a ? (a.Kind == AccountKind.Demo ? "Demo iCloud" : a.IsICloud ? a.Title : $"{a.DriveTitle} ({a.Title})") : "(signed out account)",
        _ => e.Title,
    };

    void Add() { var ed = new JobEditor(null) { Owner = this }; if (ed.ShowDialog() == true && ed.Result is { } j) SyncStore.Shared.Upsert(j); }
    void Edit() { if (Selected is { } s) { var ed = new JobEditor(s) { Owner = this }; if (ed.ShowDialog() == true && ed.Result is { } j) SyncStore.Shared.Upsert(j); } }

    void Remove()
    {
        if (Selected is not { } j) return;
        if (Dialogs.Confirm(this, $"Remove “{j.Name}”?", "Only the job is removed. Files on both sides stay exactly as they are.", "Remove"))
            SyncStore.Shared.Remove(j);
    }

    async void Preview()
    {
        if (Selected is not { } j) return;
        _preview.IsEnabled = false;
        _detail.Text = "Scanning…";
        try
        {
            var p = await JobEngine.Shared.PreviewAsync(j, s => Dispatcher.InvokeAsync(() => _detail.Text = s));
            var body = p.Summary;
            if (p.Plan is { } plan && plan.Actions.Count > 0)
                body += "\n\n" + string.Join("\n", plan.Actions.Where(a => a.Kind != SyncActionKind.Skip).Take(14).Select(a => $"• {Verb(a)} {a.Path}"))
                    + (plan.Actions.Count > 14 ? $"\n• …and {plan.Actions.Count - 14} more" : "");
            if (p.Backup is { } b && b.Warnings.Count > 0) body += "\n\n" + string.Join("\n", b.Warnings.Select(w => "⚠ " + w));
            if (p.GuardTripped)
            {
                body += $"\n\nThis would move {p.Plan!.RemovedItems} items to the Recycle Bin / Recently Deleted, more than the {j.Options.MaxDeletePercent}% limit. A normal run stops here.";
                if (Dialogs.Ask(this, "Preview — check the removals", body, ["Run Anyway", "Cancel"], 1, 1, PreflightSeverity.Warning) == 0) RunSelected(true);
            }
            else if (Dialogs.Ask(this, "Preview", body, ["Run Now", "Close"], 0, 1) == 0) RunSelected(false);
            Sync();
        }
        catch (Exception e) { _detail.Text = "Preview failed: " + e.Message; }
        finally { _preview.IsEnabled = Selected is not null; }
    }

    static string Verb(SyncAction a) => a.Kind switch
    {
        SyncActionKind.CopyAB => "Copy", SyncActionKind.CopyBA => "Copy back", SyncActionKind.MkdirA or SyncActionKind.MkdirB => "Create folder",
        SyncActionKind.TrashA or SyncActionKind.TrashB => "Remove (recoverable)", SyncActionKind.Conflict => "Keep both", _ => "Skip",
    };

    void RunSelected(bool force)
    {
        if (Selected is not { } j) return;
        if (JobEngine.Shared.Run(j, force) is not null && Owner is MainWindow mw) mw.SetTransfersVisible(true);
        Sync();
    }
}

/// <summary>New / edit job dialog.</summary>
sealed class JobEditor : Window
{
    readonly TextBox _name = new();
    readonly ComboBox _kind = new() { ItemsSource = new[] { "Folder sync", "Photos export", "Photos import", "Backup" } };
    readonly ComboBox _mode = new() { ItemsSource = Enum.GetValues<SyncMode>().Select(m => m.Title()).ToList() };
    readonly TextBlock _src = Ui.Text("", 12), _dst = Ui.Text("", 12);
    readonly ComboBox _schedule = new() { ItemsSource = new[] { "Manually", "Every 15 minutes", "Every hour", "Every 6 hours", "Daily at 2:00", "When the destination drive is connected" } };
    readonly TextBox _excludes = new() { AcceptsReturn = true, Height = 70, TextWrapping = TextWrapping.Wrap, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    readonly TextBox _maxDelete = new() { Width = 60, HorizontalAlignment = HorizontalAlignment.Left };
    readonly Grid _modeRow;
    SyncEndpoint _source, _destination;
    readonly SyncJob _job;
    public SyncJob? Result { get; private set; }

    public JobEditor(SyncJob? existing)
    {
        Title = existing is null ? "New Job" : "Edit Job";
        Width = 600;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;
        _job = existing?.Clone() ?? new SyncJob("New job", JobKind.FolderSync, new SyncEndpoint(), new SyncEndpoint());
        _source = _job.Source; _destination = _job.Destination;
        _name.Text = _job.Name;
        _kind.SelectedIndex = (int)_job.Kind;
        _mode.SelectedIndex = (int)_job.Mode;
        _excludes.Text = string.Join(Environment.NewLine, _job.Options.Excludes.Select(e => e.Replace("\r", "\\r")));
        _maxDelete.Text = _job.Options.MaxDeletePercent.ToString();
        _schedule.SelectedIndex = _job.Schedule.Kind switch
        {
            ScheduleKind.Every when _job.Schedule.Minutes <= 15 => 1, ScheduleKind.Every when _job.Schedule.Minutes <= 60 => 2, ScheduleKind.Every => 3,
            ScheduleKind.Daily => 4, ScheduleKind.WhenConnected => 5, _ => 0,
        };
        _modeRow = Ui.Labeled("Mode", _mode);
        var cloudLabel = AccountManager.Shared.CloudAccounts.Count > 0 ? "Cloud…" : "iCloud…";
        var srcButtons = Ui.Row(Ui.Button("Folder…", () => PickLocal(true)), Ui.Button(cloudLabel, () => PickCloud(true)));
        var dstButtons = Ui.Row(Ui.Button("Folder…", () => PickLocal(false)), Ui.Button(cloudLabel, () => PickCloud(false)));
        _kind.SelectionChanged += (_, _) => Refresh();
        var root = Ui.Stack(
            Ui.Labeled("Name", _name),
            Ui.Labeled("Kind", _kind),
            _modeRow,
            Ui.Labeled("Source", Ui.Stack(_src, srcButtons)),
            Ui.Labeled("Destination", Ui.Stack(_dst, dstButtons)),
            Ui.Labeled("Run", _schedule),
            Ui.Labeled("Exclude", _excludes),
            Ui.Labeled("Stop if removing more than", Ui.Row(_maxDelete, Ui.Text("  % of the items (and more than 20)", 12))),
            Ui.Buttons(Ui.Button("Save", Save, accent: true, isDefault: true), Ui.Button("Cancel", () => DialogResult = false, isCancel: true)));
        root.Margin = new Thickness(20);
        Content = root;
        Refresh();
    }

    JobKind Kind => (JobKind)Math.Max(0, _kind.SelectedIndex);

    void Refresh()
    {
        _modeRow.Visibility = Kind == JobKind.FolderSync ? Visibility.Visible : Visibility.Collapsed;
        _src.Text = _source.Kind == EndpointKind.Local && string.IsNullOrEmpty(_source.Path) ? "(not chosen)" : SyncJobsWindow.Describe(_source);
        _dst.Text = _destination.Kind == EndpointKind.Local && string.IsNullOrEmpty(_destination.Path) ? "(not chosen)" : SyncJobsWindow.Describe(_destination);
    }

    void PickLocal(bool source)
    {
        var dlg = new Microsoft.Win32.OpenFolderDialog { Title = source ? "Source folder" : "Destination folder" };
        if (dlg.ShowDialog(this) != true) return;
        if (source) _source = SyncEndpoint.Local(dlg.FolderName); else _destination = SyncEndpoint.Local(dlg.FolderName);
        Refresh();
    }

    void PickCloud(bool source)
    {
        var needPhotos = (Kind == JobKind.PhotosExport && source) || (Kind == JobKind.PhotosImport && !source);
        if (Kind == JobKind.Backup && source)
        {
            var accts = AccountManager.Shared.Accounts.Where(a => a.IsICloud && (a.Kind != AccountKind.Native || a.DriveRoot is not null)).ToList();
            var names = accts.Select(a => a.Kind == AccountKind.Demo ? "Demo iCloud" : a.Title).Append("Cancel").ToArray();
            var i = Dialogs.Ask(this, "Back up which account?", "", names, 0, names.Length - 1);
            if (i >= 0 && i < accts.Count) { _source = SyncEndpoint.ForAccount(accts[i].Id); Refresh(); }
            return;
        }
        var picker = new LocationPicker(source ? "Choose the source" : "Choose the destination", "Choose", null, foldersOnly: !needPhotos, includePhotos: needPhotos, anyLocation: source) { Owner = this };
        if (picker.ShowDialog() != true || picker.Chosen is not { } loc) return;
        SyncEndpoint e = loc.Kind switch
        {
            LocKind.Local => SyncEndpoint.Local(loc.Path!),
            LocKind.Drive => SyncEndpoint.Drive(loc.Account!, loc.Id!, string.Join("/", Catalog.Shared.Breadcrumbs(loc).Skip(1).Select(Catalog.Shared.Title))),
            LocKind.Album => SyncEndpoint.Photos(loc.Account!, loc.Library!, loc.Id == "smart:All Photos" ? null : loc.Id, loc.Id == "smart:All Photos" ? null : Catalog.Shared.Title(loc)),
            _ => new SyncEndpoint(),
        };
        if (source) _source = e; else _destination = e;
        Refresh();
    }

    void Save()
    {
        var kind = Kind;
        string? err = kind switch
        {
            JobKind.FolderSync when !(_source.Kind is EndpointKind.Local or EndpointKind.Drive) || !(_destination.Kind is EndpointKind.Local or EndpointKind.Drive) => "Folder sync needs a folder on each side.",
            JobKind.PhotosExport when _source.Kind != EndpointKind.Photos || _destination.Kind != EndpointKind.Local => "A Photos export goes from a Photos library or album to a folder.",
            JobKind.PhotosImport when _source.Kind != EndpointKind.Local || _destination.Kind != EndpointKind.Photos => "A Photos import goes from a folder into Photos.",
            JobKind.Backup when _source.Kind != EndpointKind.Account || _destination.Kind != EndpointKind.Local => "A backup goes from an iCloud account to a folder or drive.",
            _ => null,
        };
        if (_source.Kind == EndpointKind.Local && string.IsNullOrEmpty(_source.Path) || _destination.Kind == EndpointKind.Local && string.IsNullOrEmpty(_destination.Path)) err = "Choose both sides.";
        if (err is null && _source.Equals(_destination)) err = "Source and destination are the same.";
        if (err is null && (kind is JobKind.Backup or JobKind.PhotosExport) && _destination.LocalPath is { } d && SafetyPolicy.IsICloudPath(d))
            err = "Backups and exports must go outside iCloud.";
        static string Norm(string x) => Path.GetFullPath(x).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (err is null && _source.LocalPath is { } sp && _destination.LocalPath is { } dp && (Norm(dp).StartsWith(Norm(sp), StringComparison.OrdinalIgnoreCase) || Norm(sp).StartsWith(Norm(dp), StringComparison.OrdinalIgnoreCase)))
            err = "One folder is inside the other (or they're the same); choose separate folders.";
        if (err is not null) { Dialogs.Error(this, "Can’t save this job", err); return; }
        _job.Name = _name.Text.Trim().Length > 0 ? _name.Text.Trim() : "Job";
        var newMode = (SyncMode)Math.Max(0, _mode.SelectedIndex);
        // The two-way baseline only describes the old pair of folders: never reuse it for a different pair or mode.
        if (newMode != _job.Mode || kind != _job.Kind || !_source.Equals(_job.Source) || !_destination.Equals(_job.Destination)) SyncState.Forget(_job.Id);
        _job.Kind = kind;
        _job.Mode = newMode;
        _job.Source = _source;
        _job.Destination = _destination;
        _job.Options.Excludes = _excludes.Text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).Select(s => s.Trim().Replace("\\r", "\r")).Where(s => s.Length > 0).ToList();
        _job.Options.MaxDeletePercent = int.TryParse(_maxDelete.Text, out var pct) ? Math.Clamp(pct, 1, 100) : 50;
        _job.Schedule = _schedule.SelectedIndex switch
        {
            1 => JobSchedule.Every(15), 2 => JobSchedule.Every(60), 3 => JobSchedule.Every(360), 4 => JobSchedule.Daily(2),
            5 => _destination.LocalPath is { } p && VolumeInfo.Info(p)?.Id is { } vid ? JobSchedule.WhenConnected(vid) : JobSchedule.Manual,
            _ => JobSchedule.Manual,
        };
        Result = _job;
        DialogResult = true;
    }
}
