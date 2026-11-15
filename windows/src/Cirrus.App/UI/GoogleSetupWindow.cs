using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using Cirrus.App.Services;
using Cirrus.Core;

namespace Cirrus.App.UI;

/// <summary>
/// Guided, one-time setup of the user's own Google OAuth client ("Desktop app"), port of GoogleSetupSheet.swift. Cirrus
/// can't ship a shared client without Google's app verification, so each person uses their own Cloud project.
/// </summary>
sealed class GoogleSetupWindow : Window
{
    public sealed record Step(string Title, string Detail, string Link, string LinkTitle);

    public static readonly Step[] Steps =
    [
        new("Create a Google Cloud project",
            "Sign in with the Google account you’re moving to. Name the project “Cirrus” (any name works) and select Create.",
            "https://console.cloud.google.com/projectcreate", "Open Projects"),
        new("Turn on the Google Drive API",
            "Check that your new project is selected at the top, then select Enable.",
            "https://console.cloud.google.com/apis/library/drive.googleapis.com", "Open Drive API"),
        new("Turn on the Photos Library API",
            "Select Enable.",
            "https://console.cloud.google.com/apis/library/photoslibrary.googleapis.com", "Open Photos API"),
        new("Only for Google → iCloud: turn on the Photos Picker API",
            "Lets you pick photos in Google Photos to copy into iCloud. Select Enable. (Skip this if you only move to Google.)",
            "https://console.cloud.google.com/apis/library/photospicker.googleapis.com", "Open Picker API"),
        new("Set up the consent screen",
            "Select Get started. App name: Cirrus. User support email: your address. Audience: External. Contact email: your address. Agree to the policy and select Create.",
            "https://console.developers.google.com/auth/branding", "Open Branding"),
        new("Add yourself as a test user",
            "Under Test users, select Add users, enter the Google address you’re moving to, and select Save. Leave the publishing status on Testing.",
            "https://console.developers.google.com/auth/audience", "Open Audience"),
        new("Add the permissions",
            "Select Add or remove scopes. Under “Manually add scopes”, paste these lines, select Add to table, then Update and Save.\n"
            + GoogleScopes.DriveFile + "\n" + GoogleScopes.PhotosAppend
            + "\nTo copy from Google into iCloud too, also add (Google calls reading Drive “restricted” — fine for your own project):\n"
            + GoogleScopes.DriveReadonly + "\n" + GoogleScopes.PhotosPicker,
            "https://console.developers.google.com/auth/scopes", "Open Data Access"),
        new("Create the client",
            "Select Create client. Application type: Desktop app. Name: Cirrus for Windows. Select Create, then copy the Client ID and Client secret into the boxes below — Google shows the secret in full only this once.",
            "https://console.developers.google.com/auth/clients", "Open Clients"),
    ];

    readonly TextBox _client = new() { MinWidth = 380 };
    readonly PasswordBox _secret = new() { MinWidth = 380 };
    readonly TextBlock _error = Ui.Text("", 12);
    readonly Button _save, _saveConnect;
    readonly GoogleOAuthClient? _saved;
    public bool Saved { get; private set; }
    public bool ConnectAfter { get; private set; }

    public GoogleSetupWindow(Window owner)
    {
        Title = "Set Up Google Access";
        Width = 680;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;
        Owner = owner;
        _error.Foreground = Brushes.IndianRed;
        _error.Visibility = Visibility.Collapsed;
        var steps = new StackPanel();
        for (int i = 0; i < Steps.Length; i++) steps.Children.Add(StepRow(i + 1, Steps[i]));
        _save = Ui.Button("Save", () => Finish(true, false));
        _saveConnect = Ui.Button("Save and Connect", () => Finish(true, true), accent: true, isDefault: true);
        var cancel = Ui.Button("Cancel", () => Finish(false, false), isCancel: true);
        // The saved secret is never shown again; leaving the box empty keeps it.
        _saved = GoogleAccounts.Shared.Client;
        if (_saved is { } c) _client.Text = c.ClientID;
        _client.TextChanged += (_, _) => Validate();
        _secret.PasswordChanged += (_, _) => Validate();
        var root = Ui.Stack(
            Ui.Text("Connect Cirrus to Google", 18, bold: true),
            Ui.Text("Google lets apps like Cirrus copy into your account only through a “client” you create in your own Google Cloud project. It’s free and takes about five minutes, once. Each button opens the right page in your browser.", 12, opacity: 0.75),
            Ui.Card(steps),
            Ui.Labeled("Client ID", _client),
            Ui.Labeled("Client secret", _secret),
            _saved?.ClientSecret is null ? new TextBlock() : Ui.Text("A client secret is saved. Leave the box empty to keep it, or paste a new one.", 11, opacity: 0.7),
            _error,
            Ui.Text("While the project is in Testing, Google ends Cirrus’s access after 7 days; select Connect Google again when asked and the move continues where it stopped. Cirrus asks only to add files it creates in your Drive and to add photos to your library — it can’t read anything else in your Google account unless you also allow Google → iCloud. The client ID and secret are encrypted for your Windows account on this PC.", 11, opacity: 0.7),
            Ui.Buttons(cancel, _save, _saveConnect));
        root.Margin = new Thickness(24, 16, 24, 18);
        Content = new ScrollViewer { Content = root, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MaxHeight = SystemParameters.WorkArea.Height - 60 };
        Validate();
    }

    static UIElement StepRow(int n, Step s)
    {
        var g = new Grid { Margin = new Thickness(0, 6, 0, 6) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var badge = new Grid { Width = 22, Height = 22, Margin = new Thickness(0, 1, 10, 0), VerticalAlignment = VerticalAlignment.Top };
        var circle = new Ellipse();
        circle.SetResourceReference(Shape.FillProperty, "AccentFillColorDefaultBrush");
        badge.Children.Add(circle);
        badge.Children.Add(new TextBlock { Text = n.ToString(), Foreground = Brushes.White, FontWeight = FontWeights.Bold, FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
        g.Children.Add(badge);
        var body = Ui.Stack(Ui.Text(s.Title, 13, bold: true),
            new TextBox { Text = s.Detail, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, BorderThickness = new Thickness(0), Background = Brushes.Transparent, Padding = new Thickness(0), Opacity = 0.8, FontSize = 12 });
        Grid.SetColumn(body, 1);
        g.Children.Add(body);
        var open = Ui.Button(s.LinkTitle, () => GoogleAccounts.OpenInBrowser(new Uri(s.Link)));
        open.VerticalAlignment = VerticalAlignment.Top;
        Grid.SetColumn(open, 2);
        g.Children.Add(open);
        return g;
    }

    GoogleOAuthClient Entered
    {
        get
        {
            var c = new GoogleOAuthClient(_client.Text, _secret.Password);
            return c.ClientSecret is null && _saved is { ClientSecret: { } kept } && _saved.ClientID == c.ClientID ? c with { ClientSecret = kept } : c;
        }
    }

    bool Validate()
    {
        var c = Entered;
        var ok = c.LooksValid;
        var msg = c.ClientID.Length == 0 || ok ? "" : "That doesn’t look like a client ID: it ends in “.apps.googleusercontent.com”.";
        if (ok && c.ClientSecret is null) msg = "Paste the client secret too — Google asks desktop apps for it when connecting.";
        _error.Text = msg;
        _error.Visibility = msg.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        _save.IsEnabled = ok;
        _saveConnect.IsEnabled = ok;
        return ok;
    }

    void Finish(bool save, bool connect)
    {
        if (save && !Validate()) return;
        if (save) GoogleAccounts.Shared.SetClient(Entered);
        Saved = save;
        ConnectAfter = connect;
        _secret.Clear();
        DialogResult = save;
    }
}
