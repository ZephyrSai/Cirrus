using System.Text;
using System.Text.Json;

namespace Cirrus.Core;

/// <summary>A connected Google account (no secrets). <see cref="Id"/> is Google's stable permission ID for the user.</summary>
public sealed class GoogleAccountInfo
{
    public string Id { get; set; } = "";
    public string Email { get; set; } = "";
    public string Name { get; set; } = "";
    public List<string> Scopes { get; set; } = [];
    public DateTimeOffset Connected { get; set; } = DateTimeOffset.UtcNow;

    public GoogleAccountInfo() { }
    public GoogleAccountInfo(string id, string email, string name, IEnumerable<string> scopes) { Id = id; Email = email; Name = name; Scopes = scopes.ToList(); }

    public bool Has(string scope) => Scopes.Contains(scope);
    public string Label => Email.Length == 0 ? (Name.Length == 0 ? "Google account" : Name) : (Name.Length == 0 || Name == Email ? Email : $"{Name} ({Email})");
}

/// <summary>Where the OAuth client, the account list and refresh tokens live.</summary>
public interface IGoogleCredentialStore
{
    GoogleOAuthClient? Client();
    void SetClient(GoogleOAuthClient? c);
    List<GoogleAccountInfo> Accounts();
    void Save(GoogleAccountInfo account, string refreshToken);
    /// <summary>Raw read; callers go through <see cref="GoogleTokenGate"/> so Windows Hello guards it.</summary>
    string? RefreshToken(string id);
    void Remove(string id);
}

/// <summary>
/// The same encrypted store as saved Apple ID passwords (DPAPI, current Windows user, one file per item under
/// %LOCALAPPDATA%\Cirrus\Secrets, names hashed). Nothing here is synced or readable by other Windows accounts.
/// </summary>
public sealed class SecretGoogleStore : IGoogleCredentialStore
{
    public const string ClientService = "Cirrus Google OAuth Client";
    public const string AccountsService = "Cirrus Google Accounts";
    public const string TokenService = "Cirrus Google Refresh Token";
    readonly ISecretStore _store;
    readonly object _lock = new();

    public SecretGoogleStore(ISecretStore store) { _store = store; }

    sealed record ClientRecord(string ClientID, string? ClientSecret);

    public GoogleOAuthClient? Client()
    {
        if (_store.Get(ClientService, "default") is not { } d) return null;
        try { return JsonSerializer.Deserialize<ClientRecord>(d) is { } r ? new GoogleOAuthClient(r.ClientID, r.ClientSecret) : null; } catch { return null; }
    }

    public void SetClient(GoogleOAuthClient? c)
    {
        if (c is null) _store.Delete(ClientService, "default");
        else _store.Set(ClientService, "default", JsonSerializer.SerializeToUtf8Bytes(new ClientRecord(c.ClientID, c.ClientSecret)));
    }

    List<GoogleAccountInfo> ReadList()
    {
        if (_store.Get(AccountsService, "index") is not { } d) return [];
        try { return JsonSerializer.Deserialize<List<GoogleAccountInfo>>(d) ?? []; } catch { return []; }
    }

    public List<GoogleAccountInfo> Accounts() { lock (_lock) return ReadList(); }

    public void Save(GoogleAccountInfo account, string refreshToken)
    {
        lock (_lock)
        {
            _store.Set(TokenService, account.Id, Encoding.UTF8.GetBytes(refreshToken));
            var list = ReadList();
            list.RemoveAll(a => a.Id == account.Id);
            list.Add(account);
            _store.Set(AccountsService, "index", JsonSerializer.SerializeToUtf8Bytes(list));
        }
    }

    public string? RefreshToken(string id) => _store.Get(TokenService, id) is { } d ? Encoding.UTF8.GetString(d) : null;

    public void Remove(string id)
    {
        lock (_lock)
        {
            _store.Delete(TokenService, id);
            var list = ReadList();
            list.RemoveAll(a => a.Id == id);
            _store.Set(AccountsService, "index", JsonSerializer.SerializeToUtf8Bytes(list));
        }
    }
}

/// <summary>In-memory store for tests and the Debug demo (nothing reaches the disk).</summary>
public sealed class MemoryGoogleStore : IGoogleCredentialStore
{
    readonly object _lock = new();
    GoogleOAuthClient? _client;
    readonly List<GoogleAccountInfo> _list = [];
    readonly Dictionary<string, string> _tokens = [];

    public MemoryGoogleStore(GoogleOAuthClient? client = null) { _client = client; }
    public GoogleOAuthClient? Client() { lock (_lock) return _client; }
    public void SetClient(GoogleOAuthClient? c) { lock (_lock) _client = c; }
    public List<GoogleAccountInfo> Accounts() { lock (_lock) return _list.ToList(); }
    public void Save(GoogleAccountInfo account, string refreshToken)
    {
        lock (_lock) { _list.RemoveAll(a => a.Id == account.Id); _list.Add(account); _tokens[account.Id] = refreshToken; }
    }
    public string? RefreshToken(string id) { lock (_lock) return _tokens.TryGetValue(id, out var t) ? t : null; }
    public void Remove(string id) { lock (_lock) { _list.RemoveAll(a => a.Id == id); _tokens.Remove(id); } }
}

/// <summary>
/// Refresh tokens are released only after Windows Hello or the Windows password — the same rule (and the same Settings
/// switch) as saved Apple ID passwords. Unlocked tokens stay in memory for this run; one prompt at a time, and an
/// unanswered prompt gives up after two minutes so an unattended run never hangs.
/// </summary>
public sealed class GoogleTokenGate
{
    readonly IGoogleCredentialStore _store;
    readonly IUserPresence? _presence;
    readonly Func<bool> _requireAuth;
    readonly Dictionary<string, string> _unlocked = [];
    readonly SemaphoreSlim _prompt = new(1, 1);

    public GoogleTokenGate(IGoogleCredentialStore store, IUserPresence? presence, Func<bool> requireAuth)
    {
        _store = store; _presence = presence; _requireAuth = requireAuth;
    }

    public async Task<string?> RefreshTokenAsync(string id, string reason, CancellationToken ct = default)
    {
        lock (_unlocked) if (_unlocked.TryGetValue(id, out var t)) return t;
        await _prompt.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            lock (_unlocked) if (_unlocked.TryGetValue(id, out var t2)) return t2;
            if (_store.RefreshToken(id) is not { } token) return null;
            if (_requireAuth())
            {
                if (_presence is null) return null;
                using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                cts.CancelAfter(TimeSpan.FromMinutes(2));
                bool ok;
                try { ok = await _presence.VerifyAsync(reason, cts.Token).ConfigureAwait(false); }
                catch (OperationCanceledException) { ok = false; }
                catch (Exception e) { Log.Status("user verification failed: " + e.GetType().Name); ok = false; }
                if (!ok) return null;
            }
            lock (_unlocked) _unlocked[id] = token;
            return token;
        }
        finally { _prompt.Release(); }
    }

    /// <summary>A token the user just granted doesn't need another prompt in this run.</summary>
    public void Remember(string id, string token) { lock (_unlocked) _unlocked[id] = token; }
    public void Forget(string id) { lock (_unlocked) _unlocked.Remove(id); }
}
