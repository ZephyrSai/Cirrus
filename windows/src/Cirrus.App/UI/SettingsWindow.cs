using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Cirrus.Core;

namespace Cirrus.App.UI;

/// <summary>Settings: Safety (read-only iCloud, Windows Hello for saved passwords), browsing, Photos, transfers, accounts, about.</summary>
sealed class SettingsWindow : Window
{
    public SettingsWindow()
    {
        Title = "Settings";
        Width = 600;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;
        var s = Settings.Current;

        var ro = Ui.Check("Read-only iCloud — never upload, rename, move or delete anything in iCloud (Drive, Photos, or the iCloud for Windows folders)", s.ReadOnlyICloud);
        ro.Checked += (_, _) => { s.ReadOnlyICloud = true; };
        ro.Unchecked += (_, _) =>
        {
            if (!Dialogs.Confirm(this, "Allow changes in iCloud?", "Uploads, renames, moves and deletions will reach iCloud and all your devices. Deletions still go to Recently Deleted (recoverable for 30 days).", "Allow Changes"))
            { ro.IsChecked = true; return; }
            s.ReadOnlyICloud = false;
        };
        var hello = Ui.Check("Require Windows Hello (or your Windows password) before Cirrus uses a saved Apple ID password", s.RequireAuthForSavedPassword,
            v => { s.RequireAuthForSavedPassword = v; s.Save(); });

        var hidden = Ui.Check("Show hidden and system files", s.ShowHidden, v => { s.ShowHidden = v; s.Save(); });
        var foldersTop = Ui.Check("Keep folders on top when sorting", s.FoldersOnTop, v => { s.FoldersOnTop = v; s.Save(); });
        var live = Ui.Check("Include Live Photo videos (.MOV) when downloading photos", s.ExportLive, v => { s.ExportLive = v; s.Save(); });
        var edited = Ui.Check("Download edited versions of photos when they exist", s.ExportEdited, v => { s.ExportEdited = v; s.Save(); });
        var byMonth = Ui.Check("Group photos by month", s.GroupPhotosByMonth, v => { s.GroupPhotosByMonth = v; s.Save(); });

        var maxT = new ComboBox { ItemsSource = new[] { 1, 2, 3, 4, 6, 8 }, SelectedItem = s.MaxTransfers, Width = 80, HorizontalAlignment = HorizontalAlignment.Left };
        maxT.SelectionChanged += (_, _) => { if (maxT.SelectedItem is int n) { s.MaxTransfers = n; TransferManager.Shared.MaxConcurrent = n; s.Save(); } };
        var tile = new Slider { Minimum = 80, Maximum = 240, Value = s.PhotoSize, Width = 220, HorizontalAlignment = HorizontalAlignment.Left, TickFrequency = 20, IsSnapToTickEnabled = true };
        tile.ValueChanged += (_, _) => { s.PhotoSize = tile.Value; s.Save(); };

        var photosFolder = new TextBox { Text = s.NativePhotosFolder ?? AccountManager.NativePhotosRoot ?? "", MinWidth = 300 };
        var browse = Ui.Button("Choose…", () =>
        {
            var d = new Microsoft.Win32.OpenFolderDialog { Title = "iCloud Photos folder" };
            if (d.ShowDialog(this) == true) photosFolder.Text = d.FolderName;
        });
        photosFolder.LostFocus += (_, _) => SavePhotosFolder(photosFolder.Text);
        browse.Click += (_, _) => SavePhotosFolder(photosFolder.Text);

        var accounts = new StackPanel();
        foreach (var a in AccountManager.Shared.WebAccounts)
        {
            var row = new DockPanel { Margin = new Thickness(0, 2, 0, 2) };
            var signOut = Ui.Button("Sign Out…", () =>
            {
                if (Dialogs.Confirm(this, $"Sign out of {a.AppleID}?", "Cirrus forgets this session and any saved password. Nothing in iCloud changes.", "Sign Out"))
                { AccountManager.Shared.SignOut(a); Close(); }
            });
            var forget = Ui.Button("Forget Saved Password", () => { AccountManager.Shared.Gate.Delete(a.AppleID!); Dialogs.Info(this, "Forgotten", "The saved password was removed from this PC."); });
            forget.IsEnabled = AccountManager.Shared.Gate.HasSavedPassword(a.AppleID!);
            DockPanel.SetDock(signOut, Dock.Right); DockPanel.SetDock(forget, Dock.Right);
            row.Children.Add(signOut); row.Children.Add(forget);
            row.Children.Add(new TextBlock { Text = $"{a.Title} ({a.AppleID}) — {a.Status}", VerticalAlignment = VerticalAlignment.Center });
            accounts.Children.Add(row);
        }
        if (accounts.Children.Count == 0) accounts.Children.Add(Ui.Text("No Apple IDs signed in to Cirrus.", 12, opacity: 0.7));
        var native = AccountManager.Shared.NativeAccount;
        accounts.Children.Add(Ui.Text(native is null
            ? "iCloud for Windows isn’t set up on this PC (no iCloudDrive folder found)."
            : $"iCloud for Windows folders: {native.DriveRoot ?? "no iCloud Drive"}; {native.PhotosRoot ?? "no iCloud Photos folder"}", 12, opacity: 0.7));

        var logs = Ui.Button("Open Logs Folder", () => { try { Process.Start(new ProcessStartInfo(Paths.SupportDir("Logs")) { UseShellExecute = true }); } catch { } });
        logs.Margin = new Thickness(0);
        logs.HorizontalAlignment = HorizontalAlignment.Left;

        var safetyCard = Ui.Card(Ui.Stack(ro, hello,
            Ui.Text("Cirrus never deletes permanently: local removals go to the Recycle Bin (or a .cirrus\\Removed folder on drives without one), iCloud removals go to Recently Deleted. The only exception is Delete Immediately inside iCloud Drive’s Recently Deleted, which always asks first.", 12, opacity: 0.7)));
        if (BuildInfo.IsTester) ((StackPanel)safetyCard.Child).Children.Insert(0, Ui.Text("Tester build: read-only mode is on by default.", 12, bold: true));

        var root = Ui.Stack(
            Ui.Header("Safety"), safetyCard,
            Ui.Header("Browsing"), Ui.Card(Ui.Stack(hidden, foldersTop, Ui.Labeled("Photo tile size", tile))),
            Ui.Header("Photos"), Ui.Card(Ui.Stack(live, edited, byMonth, Ui.Labeled("iCloud Photos folder", Ui.Row(photosFolder, browse)))),
            Ui.Header("Transfers"), Ui.Card(Ui.Labeled("At the same time", maxT)),
            Ui.Header("Accounts"), Ui.Card(accounts),
            Ui.Header("About"), Ui.Card(Ui.Stack(Ui.Text($"Cirrus {BuildInfo.Version} for Windows{(BuildInfo.IsTester ? " (tester build)" : "")}. Inspired by rclone and icloudpd.", 12),
                Ui.Text("Logs never contain passwords, cookies, tokens or Apple IDs.", 12, opacity: 0.7), logs)),
            Ui.Buttons(Ui.Button("Done", Close, accent: true, isDefault: true, isCancel: true)));
        root.Margin = new Thickness(22, 6, 22, 18);
        Content = new ScrollViewer { Content = root, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MaxHeight = SystemParameters.WorkArea.Height - 60 };
    }

    static void SavePhotosFolder(string text)
    {
        var s = Settings.Current;
        var v = text.Trim();
        var chosen = v.Length > 0 && Directory.Exists(v) ? v : null;
        if (chosen == s.NativePhotosFolder) return;
        s.NativePhotosFolder = chosen;
        SafetyPolicy.ExtraNativeRoot = s.NativePhotosFolder;
        s.Save();
        AccountManager.Shared.Load();
    }
}
