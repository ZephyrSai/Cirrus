using System.Diagnostics;
using System.Net.Http;
using Cirrus.Core;

namespace Cirrus.App.Services;

/// <summary>
/// The app's side of each service's sign-in (port of CloudConnect in AddAccountSheet.swift). Kept apart from the window so
/// the demo wiring can stand in for the browser. Sign-ins happen in the browser wherever the service allows it, so Cirrus
/// never sees those passwords.
/// </summary>
static class CloudConnect
{
#if DEBUG
    /// <summary>Demo mode: completes a browser sign-in on the fake service instead of opening the browser.</summary>
    public static Func<CloudProvider, Uri, Task>? DemoApprove { get; set; }
    /// <summary>Demo mode: the fake services' own OneDrive client ID and Dropbox app key.</summary>
    public static Func<CloudProvider, string?>? DemoAppID { get; set; }
    /// <summary>Demo mode: the fake Google that serves the Google Drive cloud (signs in there too).</summary>
    public static Cirrus.Fakes.FakeGoogle? DemoGoogleDrive { get; set; }
#endif

    /// <summary>OneDrive needs a Microsoft app ID: one the user pasted, or Cirrus's own once it's registered.</summary>
    public static string OneDriveClientID
    {
        get
        {
#if DEBUG
            if (DemoAppID?.Invoke(CloudProvider.OneDrive) is { } demo) return demo;
#endif
            var s = Settings.Current.OneDriveClientID?.Trim();
            return string.IsNullOrEmpty(s) ? OneDriveCloud.DefaultClientID : s;
        }
        set { Settings.Current.OneDriveClientID = value.Trim(); Settings.Current.Save(); }
    }

    /// <summary>Dropbox needs an app key: one the user pasted, or Cirrus's own once it's registered.</summary>
    public static string DropboxAppKey
    {
        get
        {
#if DEBUG
            if (DemoAppID?.Invoke(CloudProvider.Dropbox) is { } demo) return demo;
#endif
            var s = Settings.Current.DropboxAppKey?.Trim();
            return string.IsNullOrEmpty(s) ? DropboxCloud.DefaultAppKey : s;
        }
        set { Settings.Current.DropboxAppKey = value.Trim(); Settings.Current.Save(); }
    }

    public static bool LooksLikeClientID(string s) => Guid.TryParse(s.Trim(), out _);

    /// <summary>Opens a sign-in page in the default browser (web pages only).</summary>
    public static void OpenInBrowser(Uri url)
    {
        if (url.Scheme != Uri.UriSchemeHttps && url.Scheme != Uri.UriSchemeHttp) return;
        try { Process.Start(new ProcessStartInfo(url.AbsoluteUri) { UseShellExecute = true }); }
        catch (Exception e) { Log.Status("couldn’t open the browser: " + e.GetType().Name); }
    }

    static Func<Uri, Task> Opener(CloudProvider p)
    {
#if DEBUG
        if (DemoApprove is { } approve) return u => approve(p, u);
#endif
        return u => { OpenInBrowser(u); return Task.CompletedTask; };
    }

    /// <summary>Opens a service's sign-in page (in demo mode, the fake answers it).</summary>
    public static Task OpenSignInPage(CloudProvider p, Uri url) => Opener(p)(url);

    static HttpMessageHandler? Transport => CloudBackends.Transport;

    public static async Task<CloudConnection> Nextcloud(string server, Action waiting, CancellationToken ct)
    {
        var pending = await NextcloudLoginFlow.BeginAsync(server, Transport, ct);
        await Opener(CloudProvider.Nextcloud)(pending.LoginURL);
        waiting();
        return await NextcloudLoginFlow.PollAsync(pending, null, Transport, ct);
    }

    public static Task<CloudConnection> OneDrive(CancellationToken ct)
    {
        var id = OneDriveClientID;
        if (id.Length == 0) throw CloudException.NotConfigured("Paste the Application (client) ID of your Microsoft app registration first.");
        return OneDriveCloud.SignInAsync(id, Opener(CloudProvider.OneDrive), Transport, ct);
    }

    public static Task<CloudConnection> GoogleDrive(CancellationToken ct)
    {
        if (GoogleAccounts.Shared.Client is not { LooksValid: true } client)
            throw CloudException.NotConfigured("Set up Google sign-in first (your own Google client, the same one “Move to or from Google” uses).");
        Func<Uri, Task> open = Opener(CloudProvider.GoogleDrive);
        var transport = GoogleAccounts.Shared.Transport;
#if DEBUG
        if (DemoGoogleDrive is { } fake)
        {
            open = u => fake.ApproveAsync(u);
            transport = fake;
            client = new GoogleOAuthClient(fake.S.ClientID, fake.S.ClientSecret);
        }
#endif
        return GoogleDriveCloud.SignInAsync(client, open, transport, null, ct);
    }

    public static Task<CloudConnection> Dropbox(CancellationToken ct)
    {
        var key = DropboxAppKey;
        if (key.Length == 0) throw CloudException.NotConfigured("Paste the App key of your Dropbox app first.");
        return DropboxCloud.SignInAsync(key, Opener(CloudProvider.Dropbox), Transport, ct);
    }

    public static Task<CloudConnection> WebDAV(string url, string user, string password, CancellationToken ct) =>
        WebDAVCloud.ConnectAsync(url, user, password, Transport, ct);

    public static Task<CloudConnection> S3(string endpoint, string region, string bucket, string accessKey, string secretKey, CancellationToken ct) =>
        S3Cloud.ConnectAsync(endpoint, region, bucket.Length == 0 ? null : bucket, accessKey, secretKey, Transport, ct);

    public static Task<CloudConnection> Immich(string server, string apiKey, CancellationToken ct) =>
        ImmichCloud.ConnectAsync(server, apiKey, Transport, ct);
}
