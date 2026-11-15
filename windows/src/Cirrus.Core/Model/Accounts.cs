using System.Text;
using System.Text.Json;

namespace Cirrus.Core;

public enum AccountKind { Native, Web, Demo }
public enum AccountStatus { Ready, NeedsSignIn, WaitingForApproval, Error }

/// <summary>
/// One place Cirrus reads iCloud from: this PC's iCloud for Windows folders, an Apple ID signed in inside
/// Cirrus (web services), or the built-in demo.
/// </summary>
public sealed class Account
{
    public string Id { get; }
    public AccountKind Kind { get; }
    public string? AppleID { get; set; }
    public string Title { get; set; }
    /// <summary>iCloud for Windows' iCloud Drive folder (%USERPROFILE%\iCloudDrive), native account only.</summary>
    public string? DriveRoot { get; set; }
    /// <summary>iCloud for Windows' iCloud Photos folder (%USERPROFILE%\Pictures\iCloud Photos), native account only.</summary>
    public string? PhotosRoot { get; set; }
    public IDriveBackend? Drive { get; set; }
    public IPhotosBackend? Photos { get; set; }
    public ICloudSession? Session { get; set; }
    public AccountStatus Status { get; set; } = AccountStatus.Ready;
    public string? StatusDetail { get; set; }

    public Account(string id, AccountKind kind, string title) { Id = id; Kind = kind; Title = title; }

    public bool HasDrive => Drive is not null || DriveRoot is not null;

    public async Task<StorageUsage?> StorageUsageAsync()
    {
        if (Session is null) return null;
        try { return await Session.StorageUsageAsync().ConfigureAwait(false); } catch { return null; }
    }

    /// <summary>Library id of the main Photos library for this account.</summary>
    public string PrimaryLibraryID => Kind == AccountKind.Demo ? "demo" : "PrimarySync";
}

/// <summary>Accounts shown in the sidebar, multiple Apple IDs included.</summary>
public sealed class AccountManager
{
    public static AccountManager Shared { get; set; } = new(new MemorySecretStore(), null);

    readonly ISecretStore _secrets;
    readonly object _lock = new();
    List<Account> _accounts = [];
    public CredentialGate Gate { get; }
    public bool DemoMode { get; set; } = Env.Flag("CIRRUS_DEMO");
    /// <summary>Raised on any thread when accounts or their status change.</summary>
    public event Action? Changed;

    public AccountManager(ISecretStore secrets, IUserPresence? presence)
    {
        _secrets = secrets;
        Gate = new CredentialGate(secrets, presence, () => Settings.Current.RequireAuthForSavedPassword);
    }

    public IReadOnlyList<Account> Accounts { get { lock (_lock) return _accounts.ToList(); } }
    public Account? NativeAccount => Accounts.FirstOrDefault(a => a.Kind == AccountKind.Native);
    public IReadOnlyList<Account> WebAccounts => Accounts.Where(a => a.Kind == AccountKind.Web).ToList();
    public Account? Account(string? id) => id is null ? null : Accounts.FirstOrDefault(a => a.Id == id);

    /// <summary>iCloud for Windows' iCloud Drive folder, when installed and signed in.</summary>
    public static string? NativeDriveRoot
    {
        get
        {
            if (Env.Get("CIRRUS_NATIVE_DRIVE") is { } o) return Directory.Exists(o) ? o : null;
            if (!OperatingSystem.IsWindows()) return null;
            var p = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "iCloudDrive");
            return Directory.Exists(p) ? p : null;
        }
    }

    /// <summary>iCloud for Windows' iCloud Photos folder (or the one chosen in Settings).</summary>
    public static string? NativePhotosRoot
    {
        get
        {
            if (Env.Get("CIRRUS_NATIVE_PHOTOS") is { } o) return Directory.Exists(o) ? o : null;
            if (Settings.Current.NativePhotosFolder is { Length: > 0 } s && Directory.Exists(s)) return s;
            if (!OperatingSystem.IsWindows()) return null;
            var p = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "iCloud Photos");
            return Directory.Exists(p) ? p : null;
        }
    }

    List<string> LoadIDs()
    {
        var data = _secrets.Get(SecretServices.AccountList, "list");
        if (data is null) return [];
        try { return JsonSerializer.Deserialize<List<string>>(data) ?? []; } catch { return []; }
    }

    void SaveIDs(List<string> ids) => _secrets.Set(SecretServices.AccountList, "list", JsonSerializer.SerializeToUtf8Bytes(ids));

    public void Load()
    {
        var list = new List<Account>();
        var driveRoot = NativeDriveRoot;
        var photosRoot = NativePhotosRoot;
        if (driveRoot is not null || photosRoot is not null)
            list.Add(new Account("native", AccountKind.Native, "iCloud for Windows") { DriveRoot = driveRoot, PhotosRoot = photosRoot });
        List<Account> previous;
        lock (_lock) previous = _accounts;
        // Reuse live web accounts so a reload never drops a session that transfers are using.
        foreach (var appleID in LoadIDs())
            list.Add(previous.FirstOrDefault(p => p.Id == "web:" + appleID.ToLowerInvariant()) ?? MakeWebAccount(appleID, LoadState(appleID)));
        if (DemoMode)
            list.Add(previous.FirstOrDefault(p => p.Kind == AccountKind.Demo)
                ?? new Account("demo", AccountKind.Demo, "Demo iCloud") { AppleID = "demo@example.com", Drive = DemoDrive.Shared, Photos = DemoPhotos.Shared });
        lock (_lock) _accounts = list;
        ThumbnailDiskCache.PruneOldVersions(list.Select(a => a.Photos?.CacheKey).OfType<string>());
        ListingCache.Shared.PruneAccounts(list.Select(a => a.Id));
        Changed?.Invoke();
    }

    SessionState LoadState(string appleID) =>
        SessionState.Deserialize(_secrets.Get(SecretServices.Session, appleID.ToLowerInvariant())) ?? new SessionState(appleID);

    void SaveState(SessionState s) => _secrets.Set(SecretServices.Session, s.AppleID, s.Serialize());

    Account MakeWebAccount(string appleID, SessionState state)
    {
        var id = appleID.ToLowerInvariant();
        var a = new Account("web:" + id, AccountKind.Web, id) { AppleID = id };
        var session = new ICloudSession(state) { Persister = SaveState };
        a.Session = session;
        a.Drive = new WebDrive(session);
        a.Photos = new WebPhotos(session, id);
        if (state.AccountInfo["dsInfo"]["fullName"].Str is { } full && string.Join(' ', full.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)) is { Length: > 0 } name) a.Title = name;
        if (state.Cookies.Count == 0) a.Status = AccountStatus.NeedsSignIn;
        session.PasswordProvider = () => Gate.PasswordAsync(id, "Sign back in to iCloud with your saved Apple ID password");
        session.Event += (e, detail) =>
        {
            switch (e)
            {
                case SessionEvent.NeedsSignIn: a.Status = AccountStatus.NeedsSignIn; break;
                case SessionEvent.WaitingForApproval: a.Status = AccountStatus.WaitingForApproval; a.StatusDetail = detail; break;
                case SessionEvent.ApprovalFinished:
                case SessionEvent.StateChanged:
                    if (a.Status == AccountStatus.WaitingForApproval) a.Status = AccountStatus.Ready;
                    if (a.Status == AccountStatus.NeedsSignIn && session.HasSession && e == SessionEvent.StateChanged) a.Status = AccountStatus.Ready;
                    break;
            }
            Changed?.Invoke();
        };
        return a;
    }

    /// <summary>A fresh session for the sign-in dialog (not yet listed as an account).</summary>
    public ICloudSession PendingSession(string appleID)
    {
        var state = LoadState(appleID);
        state.Cookies = [];
        return new ICloudSession(state);
    }

    /// <summary>Called by the sign-in dialog once Apple accepted the login.</summary>
    public Account FinishSignIn(string appleID, ICloudSession session, string? rememberPassword)
    {
        var id = appleID.ToLowerInvariant();
        if (rememberPassword is not null) Gate.Save(id, rememberPassword); else Gate.Delete(id);
        var state = session.State;
        SaveState(state);
        var ids = LoadIDs();
        if (!ids.Contains(id)) { ids.Add(id); SaveIDs(ids); }
        ListingCache.Shared.Revive("web:" + id);
        var account = MakeWebAccount(id, state);
        account.Status = AccountStatus.Ready;
        lock (_lock)
        {
            var old = _accounts.FirstOrDefault(x => x.Id == account.Id);
            old?.Session?.Dispose();
            _accounts.RemoveAll(x => x.Id == account.Id);
            var demo = _accounts.FindIndex(x => x.Kind == AccountKind.Demo);
            if (demo >= 0) _accounts.Insert(demo, account); else _accounts.Add(account);
        }
        session.Dispose();
        Changed?.Invoke();
        return account;
    }

    public void SignOut(Account account)
    {
        if (account.Kind != AccountKind.Web || account.AppleID is not { } id) return;
        _secrets.Delete(SecretServices.Session, id);
        Gate.Delete(id);
        var ids = LoadIDs();
        ids.Remove(id);
        SaveIDs(ids);
        lock (_lock) _accounts.RemoveAll(a => a.Id == account.Id);
        account.Session?.Dispose();
        WipeCaches(account);
        Changed?.Invoke();
    }

    /// <summary>
    /// Sign-out forgets everything cached for the account: listings and thumbnails (deleted: Cirrus' own cache), preview
    /// copies (deleted) and opened copies (to the Recycle Bin, since they may hold the user's edits).
    /// </summary>
    static void WipeCaches(Account account)
    {
        ListingCache.Shared.WipeAccount(account.Id);
        if (account.Photos is { } p) ThumbnailDiskCache.Wipe(p.CacheKey);
        // Preview and opened copies are kept per account (other accounts' copies, relays and drags are left alone).
        try { var d = Paths.AccountCacheDir("preview", account.Id); if (Directory.Exists(d)) Directory.Delete(d, true); } catch { }
        try { var d = Paths.AccountCacheDir("open", account.Id); if (Directory.Exists(d)) LocalFiles.SafeTrash(d, Paths.CacheDir("open")); }
        catch (Exception e) { Log.Status("couldn’t clear opened copies at sign-out: " + e.GetType().Name); }
    }

    public void NotifyChanged() => Changed?.Invoke();
}
