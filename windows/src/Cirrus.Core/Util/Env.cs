namespace Cirrus.Core;

/// <summary>
/// The only way Cirrus reads CIRRUS_* environment switches. Release builds of the app call <see cref="LockDown"/>
/// first thing, after which only the user-facing switches (demo mode, a separate profile) are honoured; test and
/// automation hooks (data folder redirection, fake iCloud folders, demo timing, verbose stderr) work only in
/// Debug builds and in the unit tests.
/// </summary>
public static class Env
{
    static volatile bool _locked;
    static readonly HashSet<string> UserFacing = new(StringComparer.Ordinal) { "CIRRUS_DEMO", "CIRRUS_PROFILE" };

    public static bool IsLockedDown => _locked;

    public static void LockDown() => _locked = true;

    /// <summary>Unit tests only.</summary>
    internal static void UnlockForTests() => _locked = false;

    public static string? Get(string name)
    {
        if (_locked && !UserFacing.Contains(name)) return null;
        var v = Environment.GetEnvironmentVariable(name);
        return string.IsNullOrEmpty(v) ? null : v;
    }

    public static bool Flag(string name) => Get(name) is { } v && v != "0";
}
