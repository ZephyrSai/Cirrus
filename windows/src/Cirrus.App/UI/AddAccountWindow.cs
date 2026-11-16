using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Cirrus.App.Services;
using Cirrus.Core;

namespace Cirrus.App.UI;

/// <summary>
/// "Add Account…": connect another cloud beside iCloud (port of AddAccountSheet.swift). Sign-ins happen in the browser
/// wherever the service allows it, so Cirrus never sees those passwords.
/// </summary>
sealed class AddAccountWindow : Window
{
    static AddAccountWindow? _current;

    /// <summary>Shows the window (one at a time). <paramref name="reconnecting"/>: Sign In Again for that account.</summary>
    public static void Show(Window? owner, CloudProvider? provider = null, CloudAccountRecord? reconnecting = null)
    {
        if (_current is { } c) { c.Activate(); return; }
        var w = new AddAccountWindow(owner, provider ?? reconnecting?.Provider ?? CloudProvider.Nextcloud, reconnecting);
        _current = w;
        w.Closed += (_, _) => { if (_current == w) _current = null; };
        w.Show();
    }

    /// <summary>The account just added (the main window opens it).</summary>
    public static event Action<Account>? Added;

    readonly CloudAccountRecord? _reconnecting;
    CloudProvider _provider;
    readonly ComboBox _picker = new() { MinWidth = 340 };
    readonly TextBox _info = new() { IsReadOnly = true, TextWrapping = TextWrapping.Wrap, BorderThickness = new Thickness(0), Background = Brushes.Transparent, Padding = new Thickness(0), Opacity = 0.75, FontSize = 12 };
    readonly TextBox _server = new(), _user = new(), _client = new(), _region = new(), _bucket = new(), _code = new();
    /// <summary>Dropbox's fallback when its sign-in ports are taken: the user pastes the code Dropbox shows.</summary>
    DropboxCodeSignIn? _dropboxCode;
    readonly PasswordBox _pass = new();
    readonly StackPanel _form = new();
    readonly TextBlock _status = Ui.Text("", 12);
    readonly ProgressBar _spinner = new() { IsIndeterminate = true, Width = 64, Height = 4, Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed };
    readonly Button _primary, _cancel;
    CancellationTokenSource? _work;

    AddAccountWindow(Window? owner, CloudProvider provider, CloudAccountRecord? reconnecting)
    {
        _reconnecting = reconnecting;
        _provider = provider;
        Title = reconnecting is null ? "Add Account" : "Sign In Again";
        Width = 580;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner;
        if (owner is not null) Owner = owner;

        foreach (var p in CloudProviders.MenuOrder)
            _picker.Items.Add(new ComboBoxItem { Content = Ui.Row(Ui.Glyph(p.Glyph(), 14), Ui.Text(MenuTitle(p), wrap: false)), Tag = p });
        _picker.SelectionChanged += (_, _) => { if (_picker.SelectedItem is ComboBoxItem { Tag: CloudProvider p }) Select(p); };
        foreach (var t in new[] { _server, _user, _client, _region, _bucket, _code }) t.TextChanged += (_, _) => Validate();
        _pass.PasswordChanged += (_, _) => Validate();
        _status.Visibility = Visibility.Collapsed;

        _cancel = Ui.Button("Cancel", CancelClicked, isCancel: true);
        _primary = Ui.Button("Continue", PrimaryClicked, accent: true, isDefault: true);
        var sub = reconnecting is null
            ? "Browse, move, sync and copy between your other clouds the same way as iCloud. Nothing changes on a service until you move files there."
            : $"Reconnect {reconnecting.Provider.DisplayName()} ({reconnecting.Title}). Your files and Cirrus’s jobs stay as they are.";
        var root = Ui.Stack(
            Ui.Text(reconnecting is null ? "Add an Account" : "Sign In Again", 18, bold: true),
            Ui.Text(sub, 12, opacity: 0.75),
            Ui.Labeled("Service", _picker),
            _info,
            _form,
            Ui.Row(_spinner, _status),
            Ui.Buttons(_cancel, _primary));
        root.Margin = new Thickness(24, 16, 24, 18);
        Content = root;

        if (reconnecting is { } r)
        {
            _server.Text = r.Provider == CloudProvider.Nextcloud && Uri.TryCreate(r.Server, UriKind.Absolute, out var u) ? u.Host : r.Server ?? "";
            _user.Text = r.Username ?? "";
            _region.Text = r.Option("region") ?? "";
            _bucket.Text = r.Option("bucket") ?? "";
            _picker.IsEnabled = false;
        }
        Select(provider);
        Closed += (_, _) => _work?.Cancel();
    }

    static string MenuTitle(CloudProvider p) => p switch
    {
        CloudProvider.WebDAV => "Other WebDAV server",
        CloudProvider.S3 => "S3-compatible storage (B2, R2, Wasabi, MinIO, AWS)",
        CloudProvider.Immich => "Immich (photos)",
        _ => p.DisplayName(),
    };

    readonly Dictionary<Control, TextBlock> _hints = [];

    /// <summary>A labeled field with a grey hint while it's empty (WPF has none built in). Fields are reused across services.</summary>
    void Field(string label, Control f, string? placeholder = null)
    {
        f.MinWidth = 360;
        if (!_hints.TryGetValue(f, out var hint))
        {
            hint = new TextBlock { Opacity = 0.45, Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false };
            _hints[f] = hint;
            void Update() => hint.Visibility = (f is TextBox t ? t.Text.Length : ((PasswordBox)f).Password.Length) == 0 ? Visibility.Visible : Visibility.Collapsed;
            if (f is TextBox tb) tb.TextChanged += (_, _) => Update(); else if (f is PasswordBox pb) pb.PasswordChanged += (_, _) => Update();
            Update();
        }
        hint.Text = placeholder ?? "";
        // Detach from the previous service's layout before placing them again.
        if (f.Parent is Panel oldF) oldF.Children.Remove(f);
        if (hint.Parent is Panel oldH) oldH.Children.Remove(hint);
        var cell = new Grid();
        cell.Children.Add(f);
        cell.Children.Add(hint);
        _form.Children.Add(Ui.Labeled(label, cell));
    }

    void Select(CloudProvider p)
    {
        _provider = p;
        _dropboxCode = null;
        var idx = CloudProviders.MenuOrder.ToList().IndexOf(p);
        if (_picker.SelectedIndex != idx) _picker.SelectedIndex = idx;
        _form.Children.Clear();
        SetStatus(null);
        switch (p)
        {
            case CloudProvider.Nextcloud:
                _info.Text = "Cirrus opens your Nextcloud in the browser. Approve Cirrus there and it gets an app password of its own, which you can revoke any time under Settings › Security. Cirrus never sees your Nextcloud password.";
                Field("Server", _server, "cloud.example.com");
                _primary.Content = "Continue in Browser";
                break;
            case CloudProvider.OneDrive:
                _info.Text = "Sign in with your Microsoft account in the browser (personal, work or school). Cirrus gets access to your OneDrive files, nothing else, and keeps the sign-in encrypted for your Windows account on this PC.";
                if (CloudConnect.OneDriveClientID.Length == 0)
                {
                    _info.Text += "\n\nThis copy of Cirrus has no Microsoft app ID yet. Register a free one at entra.microsoft.com › App registrations › New registration: supported accounts “Accounts in any organizational directory and personal Microsoft accounts”, redirect URI platform “Public client/native (mobile & desktop)” with http://localhost. Then paste its Application (client) ID here. No client secret is needed.";
                    Field("App (client) ID", _client, "00000000-0000-0000-0000-000000000000");
                }
                _primary.Content = "Sign In with Microsoft";
                break;
            case CloudProvider.GoogleDrive:
                _info.Text = "Uses your own Google sign-in setup, the same one “Move to or from Google” uses, so it’s free and private to you. Google warns that the app isn’t verified because it’s your own setup: choose Continue.";
                _primary.Content = GoogleAccounts.Shared.IsConfigured ? "Sign In with Google" : "Set Up Google Sign-In…";
                break;
            case CloudProvider.WebDAV:
                _info.Text = "For ownCloud, OpenCloud, Synology, QNAP, Apache and other WebDAV servers. Use an app password if your server offers them. Cirrus keeps it encrypted for your Windows account on this PC. (Nextcloud servers are detected and connected as Nextcloud.)";
                Field("WebDAV address", _server, "https://files.example.com/remote.php/webdav/");
                Field("User name", _user);
                Field("Password", _pass, "App password");
                _primary.Content = "Connect";
                break;
            case CloudProvider.Dropbox:
                _info.Text = "Sign in to Dropbox in the browser. Cirrus gets access to your Dropbox files and keeps the sign-in encrypted for your Windows account on this PC.";
                if (CloudConnect.DropboxAppKey.Length == 0)
                {
                    _info.Text += "\n\nThis copy of Cirrus has no Dropbox app key yet. Create a free app at dropbox.com/developers/apps: Scoped access, Full Dropbox. Under Settings › OAuth 2, allow public clients and add the redirect URIs "
                        + string.Join(", ", DropboxCloud.RedirectURIs) + ". Under Permissions, tick account_info.read and files.metadata/files.content read and write, then Submit. Paste its App key here (no secret needed).";
                    Field("App key", _client, "App key");
                }
                _primary.Content = "Sign In with Dropbox";
                break;
            case CloudProvider.S3:
                _info.Text = "Backblaze B2, Cloudflare R2, Wasabi, MinIO, AWS and other S3-compatible storage. Use a key limited to the buckets Cirrus should see. Leave the bucket empty to browse every bucket the key can list.";
                Field("Endpoint", _server, "https://s3.us-west-004.backblazeb2.com");
                Field("Region", _region, "us-east-1 (or auto)");
                Field("Bucket", _bucket, "Optional: one bucket");
                Field("Access key ID", _user);
                Field("Secret key", _pass, "Secret access key");
                _primary.Content = "Connect";
                break;
            case CloudProvider.Immich:
                _info.Text = "Your Immich photo library, with its timeline, albums and favorites, in Cirrus’s Photos views. Create an API key in Immich under Account Settings › API Keys and paste it here.";
                Field("Server", _server, "https://photos.example.com");
                Field("API key", _pass, "API key");
                _primary.Content = "Connect";
                break;
        }
        Validate();
        Dispatcher.InvokeAsync(() =>
        {
            foreach (var f in _hints.Keys.Where(f => f.IsVisible && (f is TextBox { Text.Length: 0 } || f is PasswordBox { Password.Length: 0 })).OrderBy(f => _form.Children.IndexOf((UIElement)((FrameworkElement)f.Parent).Parent)))
            { f.Focus(); break; }
        });
    }

    void Validate()
    {
        if (_work is not null) { _primary.IsEnabled = false; return; }
        var s = _server.Text.Trim();
        _primary.IsEnabled = _provider switch
        {
            CloudProvider.Nextcloud => s.Length > 0,
            CloudProvider.WebDAV => s.Length > 0 && _user.Text.Length > 0 && _pass.Password.Length > 0,
            CloudProvider.OneDrive => CloudConnect.OneDriveClientID.Length > 0 || CloudConnect.LooksLikeClientID(_client.Text),
            CloudProvider.GoogleDrive => true,
            CloudProvider.Dropbox => _dropboxCode is not null ? _code.Text.Trim().Length > 0 : CloudConnect.DropboxAppKey.Length > 0 || _client.Text.Trim().Length >= 8,
            CloudProvider.S3 => s.Length > 0 && _user.Text.Length > 0 && _pass.Password.Length > 0,
            _ => s.Length > 0 && _pass.Password.Length > 0,
        };
    }

    void SetStatus(string? text, bool busy = false, bool error = false)
    {
        _status.Text = text ?? "";
        _status.Visibility = text is null ? Visibility.Collapsed : Visibility.Visible;
        if (error) _status.Foreground = Brushes.IndianRed; else _status.ClearValue(TextBlock.ForegroundProperty);
        _spinner.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
    }

    void CancelClicked()
    {
        if (_work is { } w)
        {
            w.Cancel();
            _work = null;
            SetStatus(null);
            _picker.IsEnabled = _reconnecting is null;
            Validate();
            return;
        }
        Close();
    }

    async void PrimaryClicked()
    {
        if (_work is not null) return;
        if (_provider == CloudProvider.GoogleDrive && !GoogleAccounts.Shared.IsConfigured)
        {
            var setup = new GoogleSetupWindow(this);
            var saved = setup.ShowDialog() == true;
            Select(CloudProvider.GoogleDrive);
            if (!(saved && setup.ConnectAfter)) return;
        }
        var p = _provider;
        var server = _server.Text.Trim();
        var user = _user.Text.Trim();
        var pass = _pass.Password;
        var client = _client.Text.Trim();
        var region = _region.Text.Trim();
        var bucket = _bucket.Text.Trim();
        _picker.IsEnabled = false;
        var cts = new CancellationTokenSource();
        _work = cts;
        Validate();
        try
        {
            CloudConnection result;
            switch (p)
            {
                case CloudProvider.Nextcloud:
                    SetStatus($"Opening {server} in your browser…", busy: true);
                    result = await CloudConnect.Nextcloud(server, () => Dispatcher.Invoke(() =>
                        SetStatus("Approve Cirrus in the browser window that just opened. Waiting…", busy: true)), cts.Token);
                    break;
                case CloudProvider.OneDrive:
                    if (client.Length > 0) CloudConnect.OneDriveClientID = client;
                    SetStatus("Sign in with Microsoft in your browser. Waiting…", busy: true);
                    result = await CloudConnect.OneDrive(cts.Token);
                    break;
                case CloudProvider.GoogleDrive:
                    SetStatus("Sign in with Google in your browser. Waiting…", busy: true);
                    result = await CloudConnect.GoogleDrive(cts.Token);
                    break;
                case CloudProvider.WebDAV:
                    SetStatus("Connecting to the server…", busy: true);
                    result = await CloudConnect.WebDAV(server, user, pass, cts.Token);
                    break;
                case CloudProvider.Dropbox when _dropboxCode is { } codeSignIn:
                    SetStatus("Checking the code…", busy: true);
                    result = await codeSignIn.FinishAsync(_code.Text.Trim(), CloudBackends.Transport, cts.Token);
                    break;
                case CloudProvider.Dropbox:
                    if (client.Length > 0) CloudConnect.DropboxAppKey = client;
                    SetStatus("Sign in to Dropbox in your browser. Waiting…", busy: true);
                    result = await CloudConnect.Dropbox(cts.Token);
                    break;
                case CloudProvider.S3:
                    SetStatus("Checking the keys…", busy: true);
                    result = await CloudConnect.S3(server, region, bucket, user, pass, cts.Token);
                    break;
                default:
                    SetStatus("Connecting to Immich…", busy: true);
                    result = await CloudConnect.Immich(server, pass, cts.Token);
                    break;
            }
            cts.Token.ThrowIfCancellationRequested();
            var record = result.Record;
            if (_reconnecting is { } r) record.Id = r.Id;
            else if (AccountManager.Shared.ExistingCloud(record) is { } existing) record.Id = existing.Id;
            var a = AccountManager.Shared.AddCloud(result with { Record = record });
            _work = null;
            _pass.Clear();
            Activate();
            Close();
            Added?.Invoke(a);
        }
        catch (CloudException e) when (p == CloudProvider.Dropbox && _dropboxCode is null && e.Message == DropboxCloud.PortsBusyMessage)
        {
            // Another app holds Dropbox's redirect ports: sign in with a code Dropbox shows instead.
            if (_work == cts) _work = null;
            try
            {
                _dropboxCode = DropboxCloud.BeginCodeSignIn(CloudConnect.DropboxAppKey);
                Field("Code", _code, "The code Dropbox shows after you allow Cirrus");
                _primary.Content = "Finish Sign-In";
                SetStatus("Another app is using Cirrus’s Dropbox sign-in ports, so Dropbox will show a code instead. Allow Cirrus in the browser, then paste the code here.");
                _ = CloudConnect.OpenSignInPage(CloudProvider.Dropbox, _dropboxCode.AuthorizationURL);
            }
            catch (Exception e2) { SetStatus(e2.Message, error: true); }
            Validate();
            Activate();
        }
        catch (OperationCanceledException) { if (_work == cts) _work = null; }
        catch (CloudException e) when (e.Kind == CloudErrorKind.Cancelled) { if (_work == cts) _work = null; }
        catch (Exception e)
        {
            if (_work == cts) _work = null;
            _picker.IsEnabled = _reconnecting is null;
            SetStatus(e.Message, error: true);
            Validate();
            Activate();
        }
    }
}
