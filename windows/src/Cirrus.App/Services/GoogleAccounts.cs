using System.IO;
using System.Net.Http;
using System.Diagnostics;
using Cirrus.Core;

namespace Cirrus.App.Services;

/// <summary>
/// Connected Google accounts (port of GoogleAccounts.swift). The client ID/secret, the account list and refresh tokens
/// are DPAPI-encrypted for the current Windows user in the same store as saved Apple ID passwords; refresh tokens are
/// released through Windows Hello or the Windows password under the same Settings switch. Debug builds in demo mode
/// (CIRRUS_DEMO=1) talk to a built-in fake Google instead; Release builds never contain it.
/// </summary>
sealed class GoogleAccounts
{
    public static GoogleAccounts Shared { get; set; } = new(new MemorySecretStore(), null);

    /// <summary>Raised on any thread when the client or the account list changes.</summary>
    public event Action? Changed;

    readonly IGoogleCredentialStore _store;
    readonly GoogleTokenGate _gate;
    readonly HttpMessageHandler? _handler;
    readonly Dictionary<string, GoogleApi> _apis = [];
    readonly object _lock = new();
#if DEBUG
    readonly Cirrus.Fakes.FakeGoogle? _fake;
#endif
    public bool IsDemo { get; }

    public GoogleAccounts(ISecretStore secrets, IUserPresence? presence)
    {
#if DEBUG
        if (AccountManager.Shared.DemoMode)
        {
            _fake = new Cirrus.Fakes.FakeGoogle();
            _fake.StartDemo(Path.Combine(Paths.CacheDir("demo"), "google"));
            var st = _fake.S;
            _store = new MemoryGoogleStore(new GoogleOAuthClient(st.ClientID, st.ClientSecret));
            _handler = _fake;
            _gate = new GoogleTokenGate(_store, null, () => false);
            IsDemo = true;
            return;
        }
#endif
        _store = new SecretGoogleStore(secrets);
        _handler = null;   // the real Google, over the default HTTPS handler
        _gate = new GoogleTokenGate(_store, presence, () => Settings.Current.RequireAuthForSavedPassword);
    }

    public GoogleOAuthClient? Client => _store.Client();
    public bool IsConfigured => Client?.LooksValid ?? false;
    public List<GoogleAccountInfo> Accounts => _store.Accounts().OrderBy(a => a.Connected).ToList();

    public void SetClient(GoogleOAuthClient? c)
    {
        _store.SetClient(c);
        lock (_lock) _apis.Clear();
        Changed?.Invoke();
    }

    /// <summary>Opens a URL in the default browser (only ever Google's own https pages).</summary>
    public static void OpenInBrowser(Uri url)
    {
        if (url.Scheme != Uri.UriSchemeHttps) return;
        try { Process.Start(new ProcessStartInfo(url.AbsoluteUri) { UseShellExecute = true }); }
        catch (Exception e) { Log.Status("couldn’t open the browser: " + e.GetType().Name); }
    }

    /// <summary>Opens Google's consent page in the default browser and waits for the answer.</summary>
    public async Task<GoogleAccountInfo> ConnectAsync(IReadOnlyList<string> scopes, string? loginHint, CancellationToken ct)
    {
        if (Client is not { LooksValid: true } c) throw GoogleException.NotConfigured();
        var oauth = new GoogleOAuth(c, _handler);
        var tokens = await oauth.AuthorizeAsync(url =>
        {
#if DEBUG
            if (_fake is not null) return _fake.ApproveAsync(url);
#endif
            OpenInBrowser(url);
            return Task.CompletedTask;
        }, scopes, loginHint, ct: ct).ConfigureAwait(false);
        if (tokens.RefreshToken is not { } refresh)
            throw GoogleException.BadResponse("Google didn’t give Cirrus lasting access. Remove Cirrus under myaccount.google.com › Security › Your connections to third-party apps, then connect again.");
        var probe = new GoogleApi("new", oauth, tokens.Scopes, _ => Task.FromResult(refresh), _handler, tokens);
        GoogleAccountInfo info;
        if (tokens.Has(GoogleScopes.DriveFile) || tokens.Has(GoogleScopes.DriveReadonly))
        {
            var (user, _) = await new GoogleDrive(probe).AboutAsync(ct).ConfigureAwait(false);
            info = new GoogleAccountInfo(user.Id.Length == 0 ? "google-" + Pkce.Random(9) : user.Id, user.Email, user.Name, tokens.Scopes);
        }
        else info = new GoogleAccountInfo("google-" + Pkce.Random(9), "", "Google Photos only", tokens.Scopes);
        // Reconnecting replaces the saved token. The old one isn't revoked: revoking ends the whole grant, which would cut
        // off the new token too. Google retires unused tokens on its own.
        _store.Save(info, refresh);
        _gate.Remember(info.Id, refresh);
        lock (_lock) _apis.Remove(info.Id);
        Changed?.Invoke();
        return info;
    }

    /// <summary>API client for a connected account; the first call in a run asks for Windows Hello.</summary>
    public GoogleApi Api(string id)
    {
        lock (_lock) if (_apis.TryGetValue(id, out var a)) return a;
        if (Client is not { LooksValid: true } c) throw GoogleException.NotConfigured();
        if (Accounts.FirstOrDefault(x => x.Id == id) is not { } info) throw GoogleException.Reconnect("Connect your Google account again.");
        var label = info.Email.Length == 0 ? "your Google account" : info.Email;   // shown in Windows' own prompt only, never logged
        var gate = _gate;
        var api = new GoogleApi(id, new GoogleOAuth(c, _handler), info.Scopes, async ct =>
            await gate.RefreshTokenAsync(id, $"Use the saved Google access for {label}", ct).ConfigureAwait(false)
                ?? throw GoogleException.Reconnect("Cirrus needs Windows Hello or your Windows password to use the saved Google access. Try again, or connect Google again."),
            _handler);
        var store = _store;
        api.OnNewRefreshToken = t => store.Save(info, t);
        lock (_lock) _apis[id] = api;
        return api;
    }

    /// <summary>Revokes Cirrus's access at Google and forgets the account (nothing in Google is removed).</summary>
    public async Task DisconnectAsync(string id)
    {
        if (Client is { } c && _store.RefreshToken(id) is { } t) await new GoogleOAuth(c, _handler).RevokeAsync(t).ConfigureAwait(false);
        _store.Remove(id);
        _gate.Forget(id);
        lock (_lock) _apis.Remove(id);
        Changed?.Invoke();
    }

    /// <summary>Debug demo only: plays the user in Google Photos' picker.</summary>
    public bool DemoPick(Uri pickerURL)
    {
#if DEBUG
        if (_fake is not null) { _ = Task.Delay(300).ContinueWith(_ => _fake.Pick(pickerURL), TaskScheduler.Default); return true; }
#endif
        return false;
    }

    public static string StateDir => Paths.SupportDir("migration");
    public static string StagingDir => Path.Combine(Paths.CacheDir("migration-staging"), "run");
}
