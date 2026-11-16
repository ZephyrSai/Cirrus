using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using Cirrus.App.Services;
using Cirrus.Core;

namespace Cirrus.App.UI;

/// <summary>
/// "Move to or from Google" (port of MigrationWindow*.swift and ImportPanel.swift). iCloud → Google copies iCloud Drive
/// into a "From iCloud" folder in Google Drive and photos (with albums) into Google Photos; Google → iCloud copies My
/// Drive into "From Google Drive" and Google Photos — from a Takeout export or the Google Photos picker — into iCloud
/// Photos. Check Space first; runs are incremental, and neither direction changes or removes anything at its source.
/// </summary>
sealed class MigrationWindow : Window
{
    static MigrationWindow? _shared;

    public static void Present(Window? owner)
    {
        if (_shared is null)
        {
            _shared = new MigrationWindow();
            if (owner is not null) _shared.Owner = owner;
            _shared.Closed += (_, _) => _shared = null;
        }
        _shared.Show();
        _shared.Activate();
    }

    const string ForwardIntro = "Cirrus copies your iCloud Drive into a “From iCloud” folder in Google Drive, and your photos and videos — original files, with their albums — into Google Photos. iCloud isn’t changed, and later runs only send what’s new.";
    const string ImportIntro = "Cirrus copies your Google Drive into a “From Google Drive” folder in iCloud Drive (Docs, Sheets and Slides as Office files), and your Google Photos — from a Google Takeout export or picked in Google Photos — into iCloud Photos with their dates, albums and favorites. Google isn’t changed, and later runs only bring what’s new.";
    const string IdleText = "Choose what to move, then select Check Space. Nothing in iCloud is changed.";
    const string ImportIdleText = "Choose what to copy, then select Check Space. Nothing in Google is changed.";

    readonly RadioButton _toGoogle = new() { Content = "iCloud → Google", IsChecked = true, Margin = new Thickness(0, 0, 16, 0), GroupName = "dir" };
    readonly RadioButton _fromGoogle = new() { Content = "Google → iCloud", GroupName = "dir" };
    readonly TextBlock _intro = Ui.Text(ForwardIntro, 12, opacity: 0.75);
    readonly ComboBox _account = new() { MinWidth = 380 };
    readonly ComboBox _google = new() { MinWidth = 380 };
    readonly Button _connect, _setup, _disconnect;

    readonly StackPanel _forward;
    readonly CheckBox _fDrive, _fPhotos, _fAlbums, _fFavorites, _fLive, _fEdited, _fRaw, _fHidden, _fShared, _fUpdate;

    readonly StackPanel _import;
    readonly CheckBox _iDrive, _iPhotos, _iAlbums, _iFavorites, _iLive, _iEdited, _iUpdate;
    readonly ComboBox _docFormat = new() { MinWidth = 220, ItemsSource = new[] { "Word, Excel and PowerPoint files", "PDF files" }, SelectedIndex = 0 };
    readonly StackPanel _driveAccess;
    readonly Button _allowDrive, _takeoutButton, _takeoutFolder, _getTakeout, _pick;
    readonly TextBlock _takeoutLabel = Ui.Text("No export chosen", 12, opacity: 0.7, wrap: false);
    readonly TextBlock _pickLabel = Ui.Text("For a few photos without an export", 12, opacity: 0.7, wrap: false);

    readonly StackPanel _bars = new();
    readonly TextBlock _summary = Ui.Text(IdleText, 13);
    readonly StackPanel _warnings = new();
    readonly TextBlock _detailsLabel = Ui.Text("", 12, bold: true);
    readonly TextBox _details = new() { IsReadOnly = true, TextWrapping = TextWrapping.Wrap, Height = 110, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, FontSize = 11.5 };
    readonly ProgressBar _spinner = new() { IsIndeterminate = true, Height = 3, Visibility = Visibility.Hidden, Margin = new Thickness(0, 6, 0, 6) };
    readonly ProgressBar _progress = new() { Height = 6, Minimum = 0, Maximum = 1, Visibility = Visibility.Collapsed, Margin = new Thickness(0, 6, 0, 0) };
    readonly Button _openDrive, _openPhotos, _check, _run;

    List<Account> _accounts = [];
    List<GoogleAccountInfo> _googles = [];
    MigrationEngine? _engine;
    MigrationEngine.Evaluation? _ev;
    MigrationEngine.Report? _lastReport;
    ImportEngine? _importEngine;
    ImportEngine.Evaluation? _iev;
    ImportEngine.Report? _lastImportReport;
    List<string> _takeout = [];
    List<GooglePickedItem> _picked = [];
    string? _pickerSession;
    DateTimeOffset? _pickedAt;
    CancellationTokenSource? _evalCts, _waitCts;
    Window? _wait;
    Transfer? _running;
    bool _runningIsImport;

    bool IsImport => _fromGoogle.IsChecked == true;

    MigrationWindow()
    {
        Title = "Move to Google";
        Width = 680;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.CanMinimize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var o = new MigrationOptions();
        _fDrive = Ui.Check("iCloud Drive → Google Drive, into a “From iCloud” folder", o.IncludeDrive, _ => OptionsChanged());
        _fPhotos = Ui.Check("Photos and videos → Google Photos (original files)", o.IncludePhotos, _ => OptionsChanged());
        _fAlbums = Ui.Check("Recreate my albums", o.Albums, _ => OptionsChanged());
        _fFavorites = Ui.Check("Favorites as an album (“Favorites from iCloud”)", o.FavoritesAlbum, _ => OptionsChanged());
        _fLive = Ui.Check("Live Photos: the video part too, as a separate clip", o.IncludeLive, _ => OptionsChanged());
        _fEdited = Ui.Check("Edited versions too, as separate photos", o.IncludeEdited, _ => OptionsChanged());
        _fRaw = Ui.Check("RAW files of RAW+JPEG pairs", o.IncludeRAW, _ => OptionsChanged());
        _fHidden = Ui.Check("Hidden photos (they won’t be hidden in Google Photos)", o.IncludeHidden, _ => OptionsChanged());
        _fShared = Ui.Check("Shared Library", o.IncludeSharedLibrary, _ => OptionsChanged());
        _fUpdate = Ui.Check("Update files changed in iCloud since the last run (the old copy goes to Google Drive’s trash)", o.UpdateChanged, _ => OptionsChanged());
        foreach (var c in new[] { _fAlbums, _fFavorites, _fLive, _fEdited, _fRaw, _fHidden, _fShared }) c.Margin = new Thickness(22, 2, 0, 2);
        _forward = Ui.Stack(Ui.Header("Include"), _fDrive, _fPhotos, _fAlbums, _fFavorites, _fLive, _fEdited, _fRaw, _fHidden, _fShared, Ui.Header("Options"), _fUpdate);

        var io = new ImportOptions();
        _iDrive = Ui.Check("Google Drive (My Drive) → iCloud Drive, into a “From Google Drive” folder", io.IncludeDrive, _ => OptionsChanged());
        _iPhotos = Ui.Check("Google Photos → iCloud Photos, into a “From Google Photos” album", io.IncludePhotos, _ => OptionsChanged());
        _iAlbums = Ui.Check("Recreate my albums", io.Albums, _ => OptionsChanged());
        _iFavorites = Ui.Check("Mark my Google favorites as favorites", io.Favorites, _ => OptionsChanged());
        _iLive = Ui.Check("Live Photo and motion-photo videos too", io.IncludeLive, _ => OptionsChanged());
        _iEdited = Ui.Check("Edited copies too, as separate photos", io.IncludeEdited, _ => OptionsChanged());
        _iUpdate = Ui.Check("Update files changed in Google since the last run (the old iCloud copy goes to the Recycle Bin or Recently Deleted)", io.UpdateChanged, _ => OptionsChanged());
        foreach (var c in new[] { _iAlbums, _iFavorites, _iLive, _iEdited }) c.Margin = new Thickness(22, 2, 0, 2);
        _docFormat.SelectionChanged += (_, _) => OptionsChanged();
        _allowDrive = Ui.Button("Allow Reading Google Drive…", () => StartConnect(GoogleScopes.Import, SelectedGoogle?.Email));
        _driveAccess = Indented(Ui.Text("Reading your Google Drive needs one more permission from Google.", 12, opacity: 0.75), _allowDrive);
        _takeoutButton = Ui.Button("Takeout archive…", ChooseTakeout);
        _takeoutFolder = Ui.Button("Unpacked folder…", ChooseTakeoutFolder);
        _getTakeout = Ui.Button("Get an Export…", GetTakeout);
        _pick = Ui.Button("Pick in Google Photos…", StartPicking);
        foreach (var b in new[] { _takeoutButton, _takeoutFolder, _getTakeout, _pick, _allowDrive }) { b.Margin = new Thickness(0, 0, 8, 0); b.MinWidth = 0; }
        _import = Ui.Stack(Ui.Header("Include"), _iDrive, Indented(Ui.Text("Google Docs, Sheets and Slides as:", 12), _docFormat), _driveAccess,
            _iPhotos, Indented(_takeoutButton, _takeoutFolder, _getTakeout), Indented(_takeoutLabel), Indented(_pick, _pickLabel),
            _iAlbums, _iFavorites, _iLive, _iEdited, Ui.Header("Options"), _iUpdate);

        _connect = Ui.Button("Connect Google…", ConnectGoogle);
        _setup = Ui.Button("Set Up Google Access…", () => PresentSetup(false));
        _disconnect = Ui.Button("Disconnect", DisconnectGoogle);
        foreach (var b in new[] { _connect, _setup, _disconnect }) { b.Margin = new Thickness(0, 0, 8, 0); b.MinWidth = 0; }
        _openDrive = Ui.Button("Open in Google Drive", () => { if (_lastReport?.DriveFolderURL is { } u) GoogleAccounts.OpenInBrowser(u); });
        _openPhotos = Ui.Button("Open Google Photos", () => GoogleAccounts.OpenInBrowser(new Uri("https://photos.google.com/albums")));
        _openDrive.Visibility = _openPhotos.Visibility = Visibility.Collapsed;
        _check = Ui.Button("Check Space", Evaluate);
        _run = Ui.Button("Move to Google", RunNow, accent: true);
        _run.IsEnabled = false;
        var close = Ui.Button("Close", Close, isCancel: true);
        _detailsLabel.Visibility = _details.Visibility = Visibility.Collapsed;

        _toGoogle.Checked += (_, _) => DirectionChanged();
        _fromGoogle.Checked += (_, _) => DirectionChanged();
        _account.SelectionChanged += (_, _) => OptionsChanged();
        _google.SelectionChanged += (_, _) => { _disconnect.IsEnabled = SelectedGoogle is not null; OptionsChanged(); };

        var root = Ui.Stack(
            _intro,
            Ui.Labeled("Direction", Ui.Row(_toGoogle, _fromGoogle)),
            Ui.Labeled("iCloud", _account),
            Ui.Labeled("Google", _google),
            Ui.Labeled("", Ui.Row(_connect, _setup, _disconnect)),
            _forward, _import,
            Ui.Header("Space"),
            Ui.Card(Ui.Stack(_bars, _summary, _spinner, _warnings, _detailsLabel, _details, _progress)),
            Ui.Buttons(_openDrive, _openPhotos, _check, _run, close));
        root.Margin = new Thickness(24, 16, 24, 18);
        Content = new ScrollViewer { Content = root, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MaxHeight = SystemParameters.WorkArea.Height - 60 };

        void Accounts() => Dispatcher.InvokeAsync(ReloadAccounts);
        void Google() => Dispatcher.InvokeAsync(() => ReloadGoogle());
        void Transfers() => Dispatcher.InvokeAsync(UpdateRunProgress);
        AccountManager.Shared.Changed += Accounts;
        GoogleAccounts.Shared.Changed += Google;
        TransferManager.Shared.Changed += Transfers;
        Closed += (_, _) =>
        {
            AccountManager.Shared.Changed -= Accounts;
            GoogleAccounts.Shared.Changed -= Google;
            TransferManager.Shared.Changed -= Transfers;
            _evalCts?.Cancel();
            _waitCts?.Cancel();
        };
        ApplyDirection();
        ReloadAccounts();
        ReloadGoogle();
    }

    static StackPanel Indented(params UIElement[] children)
    {
        var r = Ui.Row(children);
        r.Margin = new Thickness(22, 3, 0, 3);
        foreach (var c in children) if (c is FrameworkElement fe) fe.VerticalAlignment = VerticalAlignment.Center;
        return r;
    }

    // MARK: Accounts

    void ReloadAccounts()
    {
        var previous = SelectedAccount?.Id;
        _accounts = AccountManager.Shared.Accounts.Where(a => a.IsICloud && (a.HasDrive || a.Photos is not null)).ToList();
        var titles = _accounts.Select(a => a.Kind switch
        {
            AccountKind.Native => "iCloud for Windows (this PC’s iCloud Drive folder)",
            AccountKind.Demo => "Demo iCloud",
            _ => (a.AppleID ?? a.Title) + (a.Status == AccountStatus.NeedsSignIn ? " — sign in needed" : ""),
        }).ToList();
        if (titles.Count == 0) titles.Add("No iCloud account — sign in first");
        _account.ItemsSource = titles;
        var i = _accounts.FindIndex(a => a.Id == previous);
        if (i < 0) i = _accounts.FindIndex(a => a.Kind is AccountKind.Web or AccountKind.Demo);
        _account.SelectedIndex = Math.Max(0, i);
        OptionsChanged();
    }

    void ReloadGoogle(string? select = null)
    {
        var previous = select ?? SelectedGoogle?.Id;
        _googles = GoogleAccounts.Shared.Accounts;
        var titles = _googles.Select(g => g.Label + (!g.Has(GoogleScopes.DriveFile) ? " — Photos only" : !g.Has(GoogleScopes.PhotosAppend) ? " — Drive only" : "")).ToList();
        var configured = GoogleAccounts.Shared.IsConfigured;
        if (titles.Count == 0) titles.Add(configured ? "No Google account connected" : "Google access isn’t set up yet");
        _google.ItemsSource = titles;
        _google.SelectedIndex = Math.Max(0, _googles.FindIndex(g => g.Id == previous));
        _connect.Content = _googles.Count == 0 ? "Connect Google…" : "Connect Another…";
        _connect.IsEnabled = _waitCts is null;
        _setup.Content = configured ? "Google Client…" : "Set Up Google Access…";
        _disconnect.IsEnabled = SelectedGoogle is not null;
        OptionsChanged();
    }

    Account? SelectedAccount => _account.SelectedIndex >= 0 && _account.SelectedIndex < _accounts.Count ? _accounts[_account.SelectedIndex] : null;
    GoogleAccountInfo? SelectedGoogle => _google.SelectedIndex >= 0 && _google.SelectedIndex < _googles.Count ? _googles[_google.SelectedIndex] : null;

    void DirectionChanged() { ApplyDirection(); OptionsChanged(); }

    void ApplyDirection()
    {
        var imp = IsImport;
        _forward.Visibility = imp ? Visibility.Collapsed : Visibility.Visible;
        _import.Visibility = imp ? Visibility.Visible : Visibility.Collapsed;
        _intro.Text = imp ? ImportIntro : ForwardIntro;
        Title = imp ? "Copy from Google" : "Move to Google";
        _openDrive.Visibility = _openPhotos.Visibility = Visibility.Collapsed;
        _bars.Children.Clear();
        ShowDetails(null, []);
    }

    void OptionsChanged()
    {
        if (_fAlbums is null || _iAlbums is null) return;   // still building
        var photosOn = _fPhotos.IsChecked == true;
        foreach (var c in new[] { _fAlbums, _fFavorites, _fLive, _fEdited, _fRaw, _fHidden, _fShared }) c.IsEnabled = photosOn;
        _fShared.IsEnabled = photosOn && SelectedAccount?.Kind == AccountKind.Web;
        _fFavorites.IsEnabled = photosOn && _fAlbums.IsChecked == true;
        var g = SelectedGoogle;
        _driveAccess.Visibility = g is null || g.Has(GoogleScopes.DriveReadonly) ? Visibility.Collapsed : Visibility.Visible;
        var iPhotosOn = _iPhotos.IsChecked == true;
        foreach (var c in new UIElement[] { _takeoutButton, _takeoutFolder, _getTakeout, _pick, _iAlbums, _iFavorites, _iLive, _iEdited }) c.IsEnabled = iPhotosOn;
        _docFormat.IsEnabled = _allowDrive.IsEnabled = _iDrive.IsChecked == true;
        RefreshImportLabels();
        _ev = null; _engine = null; _iev = null; _importEngine = null;
        _run.IsEnabled = false;
        _run.Content = IsImport ? "Copy to iCloud" : "Move to Google";
        _warnings.Children.Clear();
        if (_evalCts is null && _running is null)
            _summary.Text = g is null
                ? (GoogleAccounts.Shared.IsConfigured ? $"Connect a Google account to {(IsImport ? "copy from" : "move to")}." : "First, set up Google access (about five minutes, once), then connect your Google account.")
                : IsImport ? ImportIdleText : IdleText;
    }

    MigrationOptions ForwardOptions => new()
    {
        IncludeDrive = _fDrive.IsChecked == true, IncludePhotos = _fPhotos.IsChecked == true, Albums = _fAlbums.IsChecked == true,
        FavoritesAlbum = _fFavorites.IsChecked == true && _fAlbums.IsChecked == true, IncludeLive = _fLive.IsChecked == true, IncludeEdited = _fEdited.IsChecked == true,
        IncludeRAW = _fRaw.IsChecked == true, IncludeHidden = _fHidden.IsChecked == true, IncludeSharedLibrary = _fShared.IsChecked == true, UpdateChanged = _fUpdate.IsChecked == true,
    };

    ImportOptions BackOptions => new()
    {
        IncludeDrive = _iDrive.IsChecked == true, IncludePhotos = _iPhotos.IsChecked == true, DocFormat = _docFormat.SelectedIndex == 1 ? GoogleDocFormat.Pdf : GoogleDocFormat.Office,
        Albums = _iAlbums.IsChecked == true, Favorites = _iFavorites.IsChecked == true, IncludeLive = _iLive.IsChecked == true, IncludeEdited = _iEdited.IsChecked == true,
        UpdateChanged = _iUpdate.IsChecked == true,
    };

    // MARK: Google setup and sign-in

    void PresentSetup(bool thenConnect)
    {
        var s = new GoogleSetupWindow(this);
        s.ShowDialog();
        ReloadGoogle();
        if (s.Saved && (s.ConnectAfter || thenConnect)) StartConnect(IsImport ? GoogleScopes.Import : GoogleScopes.All, null);
    }

    void ConnectGoogle()
    {
        if (!GoogleAccounts.Shared.IsConfigured) { PresentSetup(true); return; }
        StartConnect(IsImport ? GoogleScopes.Import : GoogleScopes.All, null);
    }

    Window ShowWait(string title, string text)
    {
        var w = Ui.Window(title, 440, this);
        var cancel = Ui.Button("Cancel", () => _waitCts?.Cancel(), isCancel: true);
        w.Content = new StackPanel
        {
            Margin = new Thickness(24, 18, 24, 16),
            Children = { Ui.Text(title, 15, bold: true), Ui.Text(text, 12, opacity: 0.8), new ProgressBar { IsIndeterminate = true, Height = 3, Margin = new Thickness(0, 8, 0, 0) }, Ui.Buttons(cancel) },
        };
        w.Closing += (_, _) => _waitCts?.Cancel();
        ((FrameworkElement)Content).IsEnabled = false;
        w.Show();
        return w;
    }

    void EndWait()
    {
        ((FrameworkElement)Content).IsEnabled = true;
        var w = _wait;
        _wait = null;
        _waitCts = null;
        w?.Close();
    }

    /// <summary>Signs in (again) asking for <paramref name="scopes"/>; reconnecting the selected account adds permissions to it.</summary>
    async void StartConnect(IReadOnlyList<string> scopes, string? hint, Action? then = null)
    {
        if (_waitCts is not null) return;
        _waitCts = new CancellationTokenSource();
        var ct = _waitCts.Token;
        _wait = ShowWait("Finish in your browser",
            "Google’s page opened in your browser. Choose your account, select Continue on the “Google hasn’t verified this app” page (it’s your own project), and tick every permission Cirrus asks for.");
        _connect.IsEnabled = false;
        try
        {
            var info = await GoogleAccounts.Shared.ConnectAsync(scopes, string.IsNullOrEmpty(hint) ? null : hint, ct);
            EndWait();
            ReloadGoogle(info.Id);
            var names = new Dictionary<string, string>
            {
                [GoogleScopes.DriveFile] = "adding to Google Drive", [GoogleScopes.PhotosAppend] = "adding to Google Photos",
                [GoogleScopes.DriveReadonly] = "reading Google Drive", [GoogleScopes.PhotosPicker] = "picking from Google Photos",
            };
            var missing = scopes.Where(s => !info.Has(s)).Select(s => names.GetValueOrDefault(s)).OfType<string>().ToList();
            if (missing.Count > 0) _summary.Text = $"Connected, but Google didn’t allow {string.Join(" or ", missing)}. Connect again and tick every box on Google’s page to include it.";
            else then?.Invoke();
        }
        catch (Exception e) when (MigrationEngine.IsCancel(e)) { EndWait(); _summary.Text = "Connecting to Google was cancelled."; }
        catch (Exception e) { EndWait(); _summary.Text = e.Message; }
        finally { _connect.IsEnabled = true; }
    }

    async void DisconnectGoogle()
    {
        if (SelectedGoogle is not { } g) return;
        if (!Dialogs.Confirm(this, $"Disconnect {(g.Email.Length == 0 ? "this Google account" : g.Email)}?",
                "Cirrus’s access is revoked at Google and its saved sign-in is removed from this PC. Nothing in Google Drive or Google Photos is removed, and connecting again later continues where the move stopped.",
                "Disconnect")) return;
        await GoogleAccounts.Shared.DisconnectAsync(g.Id);
    }

    // MARK: Google → iCloud sources

    void RefreshImportLabels()
    {
        if (_takeout.Count == 0) _takeoutLabel.Text = "No export chosen";
        else if (_takeout.Count == 1 && Directory.Exists(_takeout[0])) _takeoutLabel.Text = $"Folder “{System.IO.Path.GetFileName(_takeout[0].TrimEnd('\\', '/'))}”";
        else _takeoutLabel.Text = $"{_takeout.Count} part{(_takeout.Count == 1 ? "" : "s")}, {_takeout.Where(File.Exists).Sum(f => new FileInfo(f).Length).ByteString()}";
        _takeoutLabel.ToolTip = _takeout.Count == 0 ? null : string.Join("\n", _takeout);
        _pickLabel.Text = _picked.Count == 0 ? "For a few photos without an export" : $"{_picked.Count} picked";
    }

    void ChooseTakeout()
    {
        var dlg = new Microsoft.Win32.OpenFileDialog
        {
            Title = "Choose every part of your Google Takeout export", Multiselect = true,
            Filter = "Google Takeout export (*.zip;*.tgz;*.tar.gz;*.tar)|*.zip;*.tgz;*.gz;*.tar|All files (*.*)|*.*",
        };
        if (dlg.ShowDialog(this) != true) return;
        _takeout = dlg.FileNames.OrderBy(f => System.IO.Path.GetFileName(f), new NaturalComparer()).ToList();
        OptionsChanged();
    }

    void ChooseTakeoutFolder()
    {
        var dlg = new Microsoft.Win32.OpenFolderDialog { Title = "Choose the folder you unpacked your Google Takeout export into" };
        if (dlg.ShowDialog(this) != true) return;
        _takeout = [dlg.FolderName];
        OptionsChanged();
    }

    void GetTakeout()
    {
        if (!Dialogs.Confirm(this, "Get your Google Photos from Google Takeout",
                "On the page that opens, keep only Google Photos selected, choose Next step, pick “Export once”, .zip, and a part size (2 GB is fine), then Create export. Google emails you when it’s ready — download every part, then come back and choose Takeout archive…. Download links expire after about a week.",
                "Open Google Takeout")) return;
        GoogleAccounts.OpenInBrowser(new Uri("https://takeout.google.com/settings/takeout/custom/photos"));
    }

    /// <summary>Google Photos picker: Google's page opens in the browser, the user picks, Cirrus polls for the result.</summary>
    async void StartPicking()
    {
        if (SelectedGoogle is not { } g) { _summary.Text = "Connect a Google account first."; return; }
        if (!g.Has(GoogleScopes.PhotosPicker)) { StartConnect(GoogleScopes.Import, g.Email, StartPicking); return; }
        if (_waitCts is not null) return;
        GoogleApi api;
        try { api = GoogleAccounts.Shared.Api(g.Id); } catch (Exception e) { _summary.Text = e.Message; return; }
        _waitCts = new CancellationTokenSource();
        var ct = _waitCts.Token;
        _wait = ShowWait("Pick photos in your browser",
            "Google Photos opened in your browser. Select the photos and videos to copy (up to 2,000), then choose Done. Cirrus is waiting here.");
        var picker = new GooglePicker(api);
        GooglePicker.Session? session = null;
        try
        {
            session = await picker.CreateAsync(ct: ct);
            var url = GooglePicker.BrowserURL(session);
            if (!GoogleAccounts.Shared.DemoPick(url)) GoogleAccounts.OpenInBrowser(url);
            var done = await picker.WaitForPickAsync(session, ct);
            var items = await picker.ItemsAsync(done.Id, ct);
            if (_pickerSession is { } old && old != session.Id) await picker.DeleteAsync(old);
            _pickerSession = session.Id;
            _pickedAt = DateTimeOffset.UtcNow;
            _picked = items;
            EndWait();
            OptionsChanged();
            _summary.Text = items.Count == 0 ? "Nothing was picked." : $"{items.Count} picked. Select Check Space to see what will be copied.";
        }
        catch (Exception e)
        {
            if (session is not null) await picker.DeleteAsync(session.Id);
            EndWait();
            _summary.Text = MigrationEngine.IsCancel(e) ? "Picking was cancelled." : e.Message;
        }
    }

    // MARK: Evaluate

    MigrationEngine MakeEngine()
    {
        if (SelectedAccount is not { } a) throw SyncException.Unavailable("Sign in to an iCloud account first (Add Apple ID… in the menu).");
        if (a.Status == AccountStatus.NeedsSignIn) throw ICloudException.NeedsSignIn();
        if (SelectedGoogle is not { } g) throw GoogleAccounts.Shared.IsConfigured ? GoogleException.Reconnect("Connect a Google account first.") : GoogleException.NotConfigured();
        var api = GoogleAccounts.Shared.Api(g.Id);
        Func<Task<StorageUsage?>>? storage = a.Session is not null ? a.StorageUsageAsync : null;
        var src = new MigrationEngine.Sources(a.Id, a.Kind == AccountKind.Native ? "This PC" : a.AppleID ?? a.Title, a.Drive, a.Drive is null ? a.DriveRoot : null, a.Photos, storage);
        return new MigrationEngine(src, new MigrationEngine.Target(api), ForwardOptions, GoogleAccounts.StateDir, GoogleAccounts.StagingDir);
    }

    ImportEngine MakeImportEngine()
    {
        if (SelectedAccount is not { } a) throw SyncException.Unavailable("Sign in to an iCloud account first (Add Apple ID… in the menu).");
        if (a.Status == AccountStatus.NeedsSignIn) throw ICloudException.NeedsSignIn();
        if (SelectedGoogle is not { } g) throw GoogleAccounts.Shared.IsConfigured ? GoogleException.Reconnect("Connect a Google account first.") : GoogleException.NotConfigured();
        var api = GoogleAccounts.Shared.Api(g.Id);
        Func<Task<StorageUsage?>>? storage = a.Session is not null ? a.StorageUsageAsync : null;
        var target = new ImportEngine.TargetSpec(a.Id, a.Kind == AccountKind.Native ? "This PC" : a.AppleID ?? a.Title, a.Drive, a.Drive is null ? a.DriveRoot : null,
            a.Photos, storage, a.Kind == AccountKind.Web);
        return new ImportEngine(new ImportEngine.SourceSpec(api, _takeout.ToList(), _picked.ToList()), target, BackOptions, GoogleAccounts.StateDir, GoogleAccounts.StagingDir);
    }

    async void Evaluate()
    {
        if (IsImport ? !(BackOptions.IncludeDrive || BackOptions.IncludePhotos) : !(ForwardOptions.IncludeDrive || ForwardOptions.IncludePhotos))
        {
            _summary.Text = IsImport ? "Pick at least one thing to copy." : "Pick at least one thing to move.";
            return;
        }
        MigrationEngine? e = null;
        ImportEngine? ie = null;
        try { if (IsImport) ie = MakeImportEngine(); else e = MakeEngine(); }
        catch (Exception ex)
        {
            _summary.Text = ex.Message;
            if (ex is GoogleException { Kind: GoogleErrorKind.NotConfigured }) PresentSetup(true);
            return;
        }
        _evalCts?.Cancel();
        var cts = _evalCts = new CancellationTokenSource();
        _spinner.Visibility = Visibility.Visible;
        _check.IsEnabled = false;
        _warnings.Children.Clear();
        _bars.Children.Clear();
        ShowDetails(null, []);
        _summary.Text = "Measuring…";
        _openDrive.Visibility = _openPhotos.Visibility = Visibility.Collapsed;
        void Progress(string s) => Dispatcher.InvokeAsync(() => { if (!cts.IsCancellationRequested) _summary.Text = s; });
        try
        {
            if (ie is not null)
            {
                var ev = await Task.Run(() => ie.EvaluateAsync(Progress, cts.Token));
                if (cts.IsCancellationRequested) return;
                _importEngine = ie;
                ShowImport(ev);
            }
            else if (e is not null)
            {
                var ev = await Task.Run(() => e.EvaluateAsync(Progress, cts.Token));
                if (cts.IsCancellationRequested) return;
                _engine = e;
                ShowForward(ev);
            }
        }
        catch (Exception ex) when (MigrationEngine.IsCancel(ex)) { }
        catch (Exception ex) { _summary.Text = ex.Message; }
        finally
        {
            if (ReferenceEquals(_evalCts, cts)) _evalCts = null;
            _spinner.Visibility = Visibility.Hidden;
            _check.IsEnabled = true;
        }
    }

    void Warn(IEnumerable<string> list)
    {
        _warnings.Children.Clear();
        foreach (var w in list)
        {
            var t = Ui.Text("⚠ " + w, 12);
            t.Foreground = Brushes.DarkOrange;
            _warnings.Children.Add(t);
        }
    }

    void Bar(string label, StorageUsage? u)
    {
        if (u is not { Total: > 0 }) return;
        _bars.Children.Add(Ui.Text(label, 11, bold: true, opacity: 0.8));
        var g = new Grid { Height = 14, Margin = new Thickness(0, 0, 0, 4) };
        var back = new Border { CornerRadius = new CornerRadius(3), Opacity = 0.25 };
        back.SetResourceReference(Border.BackgroundProperty, "ControlStrongFillColorDefaultBrush");
        g.Children.Add(back);
        var row = new Grid();
        long shown = 0;
        foreach (var c in u.Categories.Where(c => c.Bytes > 0))
        {
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(0.001, c.Bytes), GridUnitType.Star) });
            var color = (Color)ColorConverter.ConvertFromString("#" + (c.Color ?? "8E8E93"));
            var r = new Rectangle { Fill = new SolidColorBrush(color), ToolTip = $"{c.Label}: {c.Bytes.ByteString()}" };
            Grid.SetColumn(r, row.ColumnDefinitions.Count - 1);
            row.Children.Add(r);
            shown += c.Bytes;
        }
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(0.001, u.Total - Math.Min(u.Total, Math.Max(shown, u.Used))), GridUnitType.Star) });
        g.Children.Add(row);
        _bars.Children.Add(g);
        _bars.Children.Add(Ui.Text($"{u.Used.ByteString()} of {u.Total.ByteString()} · " + string.Join(" · ", u.Categories.Where(c => c.Bytes > 0).Select(c => $"{c.Label} {c.Bytes.ByteString()}")), 11, opacity: 0.7));
    }

    void ShowDetails(string? title, List<string> lines)
    {
        _detailsLabel.Visibility = _details.Visibility = title is null ? Visibility.Collapsed : Visibility.Visible;
        _detailsLabel.Text = title ?? "";
        var shown = lines.Take(2000).ToList();
        _details.Text = string.Join("\n", shown) + (lines.Count > shown.Count ? $"\n… and {lines.Count - shown.Count:N0} more" : "");
    }

    void ShowForward(MigrationEngine.Evaluation ev)
    {
        _ev = ev;
        _bars.Children.Clear();
        Bar("iCloud", ev.ICloud);
        Bar($"Google ({ev.User?.Email ?? "storage"}) — after this move", ev.Quota?.UsageBar(ev.PendingBytes));
        string Left(int count, long b) => count == 0 ? "already in Google" : $"{count:N0} to send ({b.ByteString()})";
        var lines = new List<string>();
        if (ev.DriveEnabled) lines.Add($"iCloud Drive: {ev.DriveFiles:N0} files, {ev.DriveBytes.ByteString()} — {Left(ev.DrivePending.Count, ev.DrivePendingBytes)}.");
        if (ev.PhotosEnabled)
        {
            lines.Add($"Photos: {ev.AssetCount:N0} items ({ev.PhotoFiles:N0} files, {ev.PhotoBytes.ByteString()}) — {Left(ev.PhotoPending.Count, ev.PhotoPendingBytes)}.");
            if (ev.Albums.Count > 0)
                lines.Add(ev.AlbumAddsPending > 0 ? $"Albums: {ev.Albums.Count}, with {ev.AlbumAddsPending:N0} photo{(ev.AlbumAddsPending == 1 ? "" : "s")} to add." : $"Albums: {ev.Albums.Count} — already in Google.");
        }
        if (ev.Quota is { } q)
            lines.Add(q.Free is { } free
                ? (ev.PendingBytes == 0 ? $"Google storage: {free.ByteString()} free." : $"Google storage: {free.ByteString()} free; this move needs {ev.RequiredGoogle.ByteString()} with headroom.")
                : "Google storage: unlimited.");
        else if (ev.PhotosEnabled) lines.Add("Google storage: not reported (Drive access wasn’t granted) — make sure your Google account has room.");
        if (ev.LocalNeeded > 0) lines.Add($"This PC: {ev.LocalFree.ByteString()} free; iCloud for Windows downloads about {ev.LocalNeeded.ByteString()} to send the files that are only in iCloud.");
        _summary.Text = lines.Count == 0 ? "Nothing to move with these choices." : string.Join("\n", lines);
        Warn(ev.Warnings);
        ShowDetails(ev.Skipped.Count == 0 ? null : "Skipped — Google can’t store these", ev.Skipped.Select(s => $"{s.Name} ({s.Size.ByteString()}): {s.Reason}").ToList());
        _run.IsEnabled = ev.Fits && (ev.DriveEnabled || ev.PhotosEnabled) && _running is null;
        _run.Content = ev.IsUpToDate ? "Move to Google (up to date)" : $"Move {ev.PendingBytes.ByteString()} to Google";
    }

    void ShowImport(ImportEngine.Evaluation ev)
    {
        _iev = ev;
        _bars.Children.Clear();
        if (ev.ICloud is { Total: > 0 } u) Bar("iCloud — after this copy", u.Adding(ev.PendingBytes, "This copy"));
        var lines = new List<string>();
        if (ev.DriveEnabled)
        {
            var left = ev.DrivePending.Count == 0 ? "already in iCloud" : $"{ev.DrivePending.Count:N0} to copy ({ev.DrivePendingBytes.ByteString()}{(ev.DrivePending.Any(d => d.Export is not null) ? " or so" : "")})";
            lines.Add($"Google Drive: {ev.DriveFiles:N0} files, {ev.DriveBytes.ByteString()}" + (ev.Docs > 0 ? $" plus {ev.Docs:N0} Google Docs" : "") + $" — {left}.");
        }
        if (ev.PhotosEnabled)
        {
            var sources = new List<string>();
            if (ev.TakeoutItems > 0 || _takeout.Count > 0)
                sources.Add(ev.TakeoutParts > 0 ? $"{ev.TakeoutItems:N0} from the Takeout export ({ev.TakeoutParts} part{(ev.TakeoutParts == 1 ? "" : "s")})" : $"{ev.TakeoutItems:N0} from the Takeout folder");
            if (ev.PickedItems > 0) sources.Add($"{ev.PickedItems:N0} picked");
            var about = ev.PhotoPending.Any(p => p.SizeIsEstimate) ? "about " : "";
            lines.Add("Google Photos: " + string.Join(", ", sources) + " — " + (ev.PhotoPending.Count == 0 ? "already in iCloud." : $"{ev.PhotoPending.Count:N0} to copy ({about}{ev.PhotoPendingBytes.ByteString()})."));
            if (ev.Albums.Count > 0)
                lines.Add(ev.AlbumAddsPending > 0 ? $"Albums: {ev.Albums.Count}, with {ev.AlbumAddsPending:N0} photo{(ev.AlbumAddsPending == 1 ? "" : "s")} to add." : $"Albums: {ev.Albums.Count} — already in iCloud.");
            if (ev.FavoritesPending > 0) lines.Add($"Favorites: {ev.FavoritesPending:N0} to mark.");
        }
        if (ev.TargetNeeded > 0) lines.Add($"This PC: {ev.TargetFree.ByteString()} free; the copy writes about {ev.TargetNeeded.ByteString()} into the iCloud for Windows folder.");
        if (ev.ICloudFree is { } free)
            lines.Add(ev.PendingBytes == 0 ? $"iCloud storage: {free.ByteString()} free." : $"iCloud storage: {free.ByteString()} free; this copy needs about {ev.RequiredICloud.ByteString()} with headroom.");
        var warns = ev.Warnings.ToList();
        if (_pickedAt is { } at && _picked.Count > 0 && DateTimeOffset.UtcNow - at > TimeSpan.FromMinutes(50))
            warns.Add("Google’s links to the photos you picked expire after an hour. Pick them again before copying.");
        _summary.Text = lines.Count == 0 ? "Nothing to copy with these choices." : string.Join("\n", lines);
        Warn(warns);
        ShowDetails(ev.Skipped.Count == 0 ? null : "Skipped — these can’t be copied", ev.Skipped.Select(s => $"{s.Name}{(s.Size > 0 ? $" ({s.Size.ByteString()})" : "")}: {s.Reason}").ToList());
        _run.IsEnabled = ev.Fits && (ev.DriveEnabled || ev.PhotosEnabled) && _running is null;
        _run.Content = ev.IsUpToDate ? "Copy to iCloud (up to date)" : $"Copy {(ev.SizesEstimated ? "about " : "")}{ev.PendingBytes.ByteString()} to iCloud";
    }

    // MARK: Run

    void RunNow()
    {
        if (_running is not null) return;
        // One run per account pair: a move started before this window was reopened may still be going.
        if ((IsImport ? _importEngine?.IsRunning : _engine?.IsRunning) == true)
        {
            Dialogs.Info(this, "Already running", "A move between these two accounts is still running. Follow it in Transfers; when it’s done, select Check Space to see what’s left.");
            return;
        }
        if (IsImport)
        {
            if (_iev is not { Fits: true } iev || _importEngine is not { } ie) return;
            // Read-only mode stops an iCloud-bound run before anything is written (the engine checks again).
            if (SafetyPolicy.ReadOnlyICloud)
            {
                Dialogs.Error(this, "Read-only mode is on", "Cirrus won’t add anything to iCloud. Turn it off in Settings › Safety to copy from Google.");
                return;
            }
            _runningIsImport = true;
            _lastImportReport = null;
            var label = SelectedGoogle is { Email.Length: > 0 } g ? g.Email : "Google";
            _running = TransferManager.Shared.Enqueue($"Copy {label} to iCloud", async (t, ct) =>
            {
                var report = await ie.RunAsync(iev, p =>
                {
                    t.Report(p.BytesDone, p.BytesTotal);
                    t.SetDetail(p.FilesTotal > 0 ? $"{p.Phase} — {p.FilesDone} of {p.FilesTotal}" : p.Phase);
                }, ct).ConfigureAwait(false);
                await Dispatcher.InvokeAsync(() => _lastImportReport = report);
                t.SetDetail(report.Summary);
                if (report.Stopped is { } s) throw GoogleException.BadResponse("Stopped: " + s);
                if (report.Failed.Count > 0) throw GoogleException.BadResponse($"{report.Failed.Count} item{(report.Failed.Count == 1 ? "" : "s")} failed: {report.Failed[0]}");
            }, "Starting…", TransferDirection.Download, iev.PendingBytes * 2, "migration");
        }
        else
        {
            if (_ev is not { Fits: true } ev || _engine is not { } e) return;
            _runningIsImport = false;
            _lastReport = null;
            _running = TransferManager.Shared.Enqueue($"Move {e.Source.Title} to Google", async (t, ct) =>
            {
                var report = await e.RunAsync(ev, p =>
                {
                    t.Report(p.BytesDone, p.BytesTotal);
                    t.SetDetail(p.FilesTotal > 0 ? $"{p.Phase} — {p.FilesDone} of {p.FilesTotal}" : p.Phase);
                }, ct).ConfigureAwait(false);
                await Dispatcher.InvokeAsync(() => _lastReport = report);
                t.SetDetail(report.Summary);
                if (report.Stopped is { } s) throw GoogleException.BadResponse("Stopped: " + s);
                if (report.Failed.Count > 0) throw GoogleException.BadResponse($"{report.Failed.Count} item{(report.Failed.Count == 1 ? "" : "s")} failed: {report.Failed[0]}");
            }, "Starting…", TransferDirection.Upload, ev.PendingBytes * 2, "migration");
        }
        _run.IsEnabled = false;
        _check.IsEnabled = false;
        _progress.Value = 0;
        _progress.Visibility = Visibility.Visible;
        if (Owner is MainWindow mw) mw.SetTransfersVisible(true);
        UpdateRunProgress();
    }

    void UpdateRunProgress()
    {
        if (_running is not { } t) return;
        _progress.Value = t.Fraction;
        if (!t.IsFinished)
        {
            _summary.Text = t.Detail + (t.Total > 0 ? $"\n{t.Completed.ByteString()} of {t.Total.ByteString()} moved through this PC" + (t.EtaText is { } eta ? " — " + eta : "") : "");
            return;
        }
        _progress.Visibility = Visibility.Collapsed;
        _running = null;
        _check.IsEnabled = true;
        _run.IsEnabled = false;
        if (_runningIsImport) FinishImport(t); else FinishForward(t);
        _ev = null; _engine = null; _iev = null; _importEngine = null;
    }

    void FinishForward(Transfer t)
    {
        _run.Content = "Move to Google";
        var r = _lastReport;
        var lines = new List<string>();
        if (t.State == TransferState.Cancelled) lines.Add("The move was stopped. Select Check Space and Move to Google to continue where it stopped.");
        else if (r is not null)
        {
            lines.Add((r.Stopped is null && r.Failed.Count == 0 ? "Done: " : "Finished with problems: ") + r.Summary + ".");
            if (r.FoldersCreated > 0) lines.Add($"{r.FoldersCreated} folder{(r.FoldersCreated == 1 ? "" : "s")} created in Google Drive.");
            if (r.AlbumAdds > 0) lines.Add($"{r.AlbumAdds} photo{(r.AlbumAdds == 1 ? "" : "s")} added to albums.");
            if (r.Resumed > 0) lines.Add($"{r.Resumed} interrupted upload{(r.Resumed == 1 ? "" : "s")} resumed.");
            if (r.Stopped is { } s) lines.Add("Stopped early: " + s);
            lines.Add("Run it again any time: only new and changed items are sent.");
        }
        else if (t.State == TransferState.Failed) lines.Add("The move stopped: " + t.Error);
        _summary.Text = string.Join("\n", lines);
        _warnings.Children.Clear();
        if (r is not null)
        {
            ShowDetails(r.Failed.Count == 0 && r.Skipped.Count == 0 ? null : "Report", r.Failed.Select(f => "Failed — " + f).Concat(r.Skipped.Select(s => $"Skipped — {s.Name}: {s.Reason}")).ToList());
            _openDrive.Visibility = r.DriveFolderURL is null ? Visibility.Collapsed : Visibility.Visible;
            _openPhotos.Visibility = r.PhotosCreated == 0 && r.AlbumsCreated == 0 ? Visibility.Collapsed : Visibility.Visible;
        }
    }

    void FinishImport(Transfer t)
    {
        _run.Content = "Copy to iCloud";
        var r = _lastImportReport;
        var lines = new List<string>();
        if (t.State == TransferState.Cancelled) lines.Add("The copy was stopped. Select Check Space and Copy to iCloud to continue where it stopped.");
        else if (r is not null)
        {
            lines.Add((r.Stopped is null && r.Failed.Count == 0 ? "Done: " : "Finished with problems: ") + r.Summary + ".");
            if (r.AlbumAdds > 0) lines.Add($"{r.AlbumAdds} photo{(r.AlbumAdds == 1 ? "" : "s")} added to albums; everything copied is also in “From Google Photos”.");
            if (r.Stopped is { } s) lines.Add("Stopped early: " + s);
            lines.Add("Run it again any time: only new and changed items are copied.");
        }
        else if (t.State == TransferState.Failed) lines.Add("The copy stopped: " + t.Error);
        _summary.Text = string.Join("\n", lines);
        _warnings.Children.Clear();
        if (r is not null)
            ShowDetails(r.Failed.Count == 0 && r.Skipped.Count == 0 ? null : "Report", r.Failed.Select(f => "Failed — " + f).Concat(r.Skipped.Select(s => $"Skipped — {s.Name}: {s.Reason}")).ToList());
        // The picker session has served its purpose.
        if (_pickerSession is { } sid && SelectedGoogle is { } g)
        {
            _pickerSession = null;
            try { var api = GoogleAccounts.Shared.Api(g.Id); _ = new GooglePicker(api).DeleteAsync(sid); } catch { }
        }
    }
}
