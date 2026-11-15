using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace Cirrus.Core;

/// <summary>Where session state and (optionally) the Apple ID password are kept. The Windows app uses DPAPI.</summary>
public interface ISecretStore
{
    byte[]? Get(string service, string account);
    void Set(string service, string account, byte[] data);
    void Delete(string service, string account);
}

public static class SecretServices
{
    public const string Session = "Cirrus iCloud Session";
    public const string Password = "Cirrus Apple ID Password";
    public const string AccountList = "Cirrus Accounts";
}

/// <summary>Encrypts and decrypts secrets for the current Windows user.</summary>
public interface ISecretProtector
{
    byte[] Protect(byte[] data, byte[] entropy);
    byte[] Unprotect(byte[] data, byte[] entropy);
}

/// <summary>
/// Files under %LOCALAPPDATA%\Cirrus\Secrets, one per item, named by a hash (no Apple IDs in file names),
/// encrypted with an <see cref="ISecretProtector"/> (DPAPI, current user) and bound to the service + account.
/// </summary>
public sealed class FileSecretStore : ISecretStore
{
    readonly string _dir;
    readonly ISecretProtector _protector;
    readonly object _lock = new();

    public FileSecretStore(string dir, ISecretProtector protector) { _dir = dir; _protector = protector; Directory.CreateDirectory(dir); }

    static string Prefix => Environment.GetEnvironmentVariable("CIRRUS_PROFILE") is { Length: > 0 } p ? $"[{p}] " : "";

    static byte[] Entropy(string service, string account) => SHA256.HashData(Encoding.UTF8.GetBytes("Cirrus/v1|" + Prefix + service + "|" + account.ToLowerInvariant()));

    string FileFor(string service, string account) =>
        Path.Combine(_dir, Convert.ToHexStringLower(Entropy(service, account))[..32] + ".bin");

    public byte[]? Get(string service, string account)
    {
        lock (_lock)
        {
            var f = FileFor(service, account);
            if (!File.Exists(f)) return null;
            try { return _protector.Unprotect(File.ReadAllBytes(f), Entropy(service, account)); }
            catch (Exception e) { Log.Error("couldn’t unlock a saved secret: " + e.GetType().Name); return null; }
        }
    }

    public void Set(string service, string account, byte[] data)
    {
        lock (_lock) AtomicFile.Write(FileFor(service, account), _protector.Protect(data, Entropy(service, account)));
    }

    public void Delete(string service, string account)
    {
        lock (_lock)
        {
            var f = FileFor(service, account);
            if (!File.Exists(f)) return;
            // Overwrite before removing: this is Cirrus' own encrypted secret, not user data.
            try { var len = new FileInfo(f).Length; File.WriteAllBytes(f, RandomNumberGenerator.GetBytes((int)Math.Min(len, 1 << 20))); } catch { }
            File.Delete(f);
        }
    }
}

/// <summary>Windows DPAPI (CryptProtectData, current-user scope, no UI) with per-item entropy.</summary>
public sealed class DpapiProtector : ISecretProtector
{
    const int CRYPTPROTECT_UI_FORBIDDEN = 0x1;

    [StructLayout(LayoutKind.Sequential)]
    struct DATA_BLOB { public int cbData; public IntPtr pbData; }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CryptProtectData(ref DATA_BLOB pDataIn, string? szDataDescr, ref DATA_BLOB pOptionalEntropy, IntPtr pvReserved, IntPtr pPromptStruct, int dwFlags, out DATA_BLOB pDataOut);

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CryptUnprotectData(ref DATA_BLOB pDataIn, IntPtr ppszDataDescr, ref DATA_BLOB pOptionalEntropy, IntPtr pvReserved, IntPtr pPromptStruct, int dwFlags, out DATA_BLOB pDataOut);

    [DllImport("kernel32.dll")]
    static extern IntPtr LocalFree(IntPtr hMem);

    public byte[] Protect(byte[] data, byte[] entropy) => Run(data, entropy, protect: true);
    public byte[] Unprotect(byte[] data, byte[] entropy) => Run(data, entropy, protect: false);

    static byte[] Run(byte[] data, byte[] entropy, bool protect)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("DPAPI is only available on Windows.");
        var hData = GCHandle.Alloc(data, GCHandleType.Pinned);
        var hEnt = GCHandle.Alloc(entropy, GCHandleType.Pinned);
        try
        {
            var inBlob = new DATA_BLOB { cbData = data.Length, pbData = hData.AddrOfPinnedObject() };
            var entBlob = new DATA_BLOB { cbData = entropy.Length, pbData = hEnt.AddrOfPinnedObject() };
            bool ok = protect
                ? CryptProtectData(ref inBlob, "Cirrus", ref entBlob, IntPtr.Zero, IntPtr.Zero, CRYPTPROTECT_UI_FORBIDDEN, out var outBlob)
                : CryptUnprotectData(ref inBlob, IntPtr.Zero, ref entBlob, IntPtr.Zero, IntPtr.Zero, CRYPTPROTECT_UI_FORBIDDEN, out outBlob);
            if (!ok) throw new CryptographicException(Marshal.GetLastWin32Error());
            try
            {
                var result = new byte[outBlob.cbData];
                Marshal.Copy(outBlob.pbData, result, 0, outBlob.cbData);
                return result;
            }
            finally { LocalFree(outBlob.pbData); }
        }
        finally { hData.Free(); hEnt.Free(); }
    }
}

/// <summary>In-memory store (tests and platforms without DPAPI): nothing is written to disk.</summary>
public sealed class MemorySecretStore : ISecretStore
{
    readonly Dictionary<string, byte[]> _items = [];
    readonly object _lock = new();
    public byte[]? Get(string service, string account) { lock (_lock) return _items.TryGetValue(service + "|" + account.ToLowerInvariant(), out var v) ? v.ToArray() : null; }
    public void Set(string service, string account, byte[] data) { lock (_lock) _items[service + "|" + account.ToLowerInvariant()] = data.ToArray(); }
    public void Delete(string service, string account) { lock (_lock) _items.Remove(service + "|" + account.ToLowerInvariant()); }
}

/// <summary>Proves the person at the PC is the Windows user (Windows Hello, or the Windows password).</summary>
public interface IUserPresence
{
    Task<bool> VerifyAsync(string reason, CancellationToken ct);
}

/// <summary>
/// Saved Apple ID passwords are only released after Windows Hello or the Windows password
/// (unless the user turned that off). Unlocked passwords stay in memory for this run only.
/// </summary>
public sealed class CredentialGate
{
    readonly ISecretStore _store;
    readonly IUserPresence? _presence;
    readonly Func<bool> _requireAuth;
    readonly Dictionary<string, string> _unlocked = [];
    readonly SemaphoreSlim _prompt = new(1, 1);

    public CredentialGate(ISecretStore store, IUserPresence? presence, Func<bool> requireAuth)
    {
        _store = store; _presence = presence; _requireAuth = requireAuth;
    }

    public bool HasSavedPassword(string appleID) => _store.Get(SecretServices.Password, appleID.ToLowerInvariant()) is not null;

    public void Save(string appleID, string password)
    {
        var id = appleID.ToLowerInvariant();
        _store.Set(SecretServices.Password, id, Encoding.UTF8.GetBytes(password));
        lock (_unlocked) _unlocked[id] = password;
    }

    public void Delete(string appleID)
    {
        var id = appleID.ToLowerInvariant();
        _store.Delete(SecretServices.Password, id);
        Forget(id);
    }

    public void Forget(string appleID) { lock (_unlocked) _unlocked.Remove(appleID.ToLowerInvariant()); }

    /// <summary>The saved password after the user proves presence (null if none, declined or timed out after 2 minutes).</summary>
    public async Task<string?> PasswordAsync(string appleID, string reason, CancellationToken ct = default)
    {
        var id = appleID.ToLowerInvariant();
        lock (_unlocked) if (_unlocked.TryGetValue(id, out var p)) return p;
        if (_store.Get(SecretServices.Password, id) is not { } data) return null;
        await _prompt.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            lock (_unlocked) if (_unlocked.TryGetValue(id, out var p2)) return p2;
            if (_requireAuth())
            {
                if (_presence is null) return null;
                using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                cts.CancelAfter(TimeSpan.FromMinutes(2));   // don't hang an unattended (scheduled) run forever
                bool ok;
                try { ok = await _presence.VerifyAsync(reason, cts.Token).ConfigureAwait(false); }
                catch (OperationCanceledException) { ok = false; }
                catch (Exception e) { Log.Error("user verification failed: " + e.GetType().Name); ok = false; }
                if (!ok) return null;
            }
            var pw = Encoding.UTF8.GetString(data);
            lock (_unlocked) _unlocked[id] = pw;
            return pw;
        }
        finally { _prompt.Release(); }
    }
}
