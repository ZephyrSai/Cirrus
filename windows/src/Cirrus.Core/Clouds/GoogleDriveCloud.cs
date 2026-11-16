using System.Net.Sockets;

namespace Cirrus.Core;

/// <summary>
/// Google Drive as a browsable account beside iCloud (port of GoogleDriveCloud.swift). Each user signs in with their
/// own OAuth client ("Desktop app" client in their Google Cloud project, the same one the iCloud ⇄ Google move uses) and
/// grants the full <see cref="GoogleScopes.Drive"/> scope; Cirrus ships no client, so it needs no restricted-scope
/// review from Google. The backend is <see cref="GoogleDriveBackend"/>.
/// </summary>
public static class GoogleDriveCloud
{
    /// <summary>What a Google Drive account asks for on Google's consent page.</summary>
    public static readonly IReadOnlyList<string> Scopes = [GoogleScopes.Drive];
    internal static string ServiceName => CloudProvider.GoogleDrive.DisplayName();
    public const string NotConfiguredMessage =
        "Google Drive needs the client ID from your own Google Cloud project. Set up Google access, then sign in to Google Drive again.";

    /// <summary>
    /// The backend for a saved account. For real accounts (no <paramref name="transport"/>), a refresh token Google rotates
    /// is saved back to the secret store while the account is still saved; set
    /// <see cref="GoogleDriveBackend.OnNewRefreshToken"/> to handle it yourself.
    /// </summary>
    public static ICloudDriveBackend Make(CloudAccountRecord record, CloudSecret secret, HttpMessageHandler? transport) =>
        MakeBackend(record, secret, transport);

    /// <summary><see cref="Make"/>, typed: for <see cref="GoogleDriveBackend.ExportFormat"/>, capabilities and <see cref="GoogleDriveBackend.ItemsNamedAsync"/>.</summary>
    public static GoogleDriveBackend MakeBackend(CloudAccountRecord record, CloudSecret secret, HttpMessageHandler? transport)
    {
        if (record.Provider != CloudProvider.GoogleDrive) throw CloudException.Unsupported("This account isn’t a Google Drive account.");
        if (secret.ClientID is not { Length: > 0 } id) throw CloudException.NotConfigured(NotConfiguredMessage);
        var client = new GoogleOAuthClient(id, secret.ClientSecret);
        if (!client.LooksValid) throw CloudException.NotConfigured(NotConfiguredMessage);
        if (secret.RefreshToken is not { Length: > 0 } refresh) throw CloudException.SignInNeeded(ServiceName);
        var backend = new GoogleDriveBackend(record.Id, client, refresh, transport);
        if (transport is null)
        {
            var accountID = record.Id;
            backend.OnNewRefreshToken = t =>
            {
                if (CloudStore.Secret(accountID) is { } saved) CloudStore.SetSecret(accountID, saved with { RefreshToken = t });
            };
        }
        return backend;
    }

    /// <summary>
    /// Browser sign-in with the user's own Google OAuth client and the full <see cref="GoogleScopes.Drive"/> scope: opens
    /// Google's consent page (through <paramref name="open"/>, e.g. the default browser), waits for the loopback redirect
    /// and returns the new account (titled with the Google account's email) and its secret (refresh token + client).
    /// <paramref name="loginHint"/> (an email) preselects the account when signing in again.
    /// </summary>
    public static async Task<CloudConnection> SignInAsync(GoogleOAuthClient client, Func<Uri, Task> open, HttpMessageHandler? transport = null,
        string? loginHint = null, CancellationToken ct = default)
    {
        if (!client.LooksValid) throw CloudException.NotConfigured(NotConfiguredMessage);
        try
        {
            var oauth = new GoogleOAuth(client, transport);
            var tokens = await oauth.AuthorizeAsync(open, Scopes, loginHint, ct: ct).ConfigureAwait(false);
            if (!tokens.Has(GoogleScopes.Drive))
                throw CloudException.Denied("Google didn’t give Cirrus access to your files. Sign in again and tick “See, edit, create and delete all of your Google Drive files” on Google’s page.");
            if (tokens.RefreshToken is not { Length: > 0 } refresh)
                throw CloudException.Server("Google didn’t give Cirrus lasting access. Remove Cirrus under myaccount.google.com › Security › Your connections to third-party apps, then sign in again.");
            var probe = new GoogleApi("new", oauth, tokens.Scopes, _ => Task.FromResult(refresh), transport, tokens);
            var (user, _) = await new GoogleDrive(probe).AboutAsync(ct).ConfigureAwait(false);
            var title = user.Email.Length > 0 ? user.Email : user.Name.Length > 0 ? user.Name : ServiceName;
            return new CloudConnection(new CloudAccountRecord(CloudProvider.GoogleDrive, title),
                new CloudSecret { RefreshToken = refresh, ClientID = client.ClientID, ClientSecret = client.ClientSecret });
        }
        catch (Exception e) when (CloudError(e, ct) is var mapped && !ReferenceEquals(mapped, e)) { throw mapped; }
    }

    /// <summary>Google's errors as <see cref="CloudException"/>s (cancellation stays <see cref="OperationCanceledException"/>).</summary>
    internal static Exception CloudError(Exception error, CancellationToken ct = default)
    {
        switch (error)
        {
            case CloudException or OperationCanceledException:
                return error;
            case GoogleException e:
                return e.Kind switch
                {
                    GoogleErrorKind.Reconnect or GoogleErrorKind.MissingScope => CloudException.SignInNeeded(ServiceName),
                    GoogleErrorKind.NotConfigured => CloudException.NotConfigured(NotConfiguredMessage),
                    GoogleErrorKind.AccessDenied => CloudException.Denied("Google Drive access wasn’t allowed. Sign in again and choose Allow on Google’s page."),
                    GoogleErrorKind.StorageFull => CloudException.QuotaExceeded(ServiceName),
                    GoogleErrorKind.DailyLimit => CloudException.Denied("Google Drive’s daily upload limit (about 750 GB a day) has been reached. Try again tomorrow."),
                    GoogleErrorKind.RateLimited => CloudException.Server("Google Drive is limiting how fast Cirrus can work. Wait a few minutes, then try again."),
                    GoogleErrorKind.Cancelled => ct.IsCancellationRequested ? new OperationCanceledException(ct) : CloudException.Cancelled(),
                    GoogleErrorKind.Http when e.Status == 404 => CloudException.NotFound(),
                    GoogleErrorKind.Http when e.Status == 403 => CloudException.Denied(e.Detail.Length == 0 ? "Google Drive didn’t allow that." : e.Detail),
                    GoogleErrorKind.UploadExpired => CloudException.Server("Google Drive ended the upload before it finished. Try again."),
                    GoogleErrorKind.BadResponse when e.Detail.Contains("client ID or secret", StringComparison.Ordinal) || e.Detail.Contains("client secret", StringComparison.Ordinal)
                        => CloudException.NotConfigured(e.Detail),
                    _ => CloudException.Server(e.Message.Length > 0 ? e.Message : "Google Drive didn’t answer as expected."),
                };
            case HttpRequestException or TimeoutException or SocketException:
                return CloudException.Server("Couldn’t reach Google Drive: " + error.Message);
            default:
                return CloudException.Server(error.Message);
        }
    }
}
