using System.Reflection;

namespace Cirrus.App;

static class BuildInfo
{
#if TESTER
    /// <summary>Tester builds start in read-only iCloud mode so nothing in iCloud changes until the tester opts in.</summary>
    public static readonly bool IsTester = true;
#else
    public static readonly bool IsTester = false;
#endif

    public static string Version =>
        typeof(BuildInfo).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion?.Split('+')[0]
        ?? typeof(BuildInfo).Assembly.GetName().Version?.ToString(3) ?? "1.0.0";

    public static bool DemoMode => Cirrus.Core.Env.Flag("CIRRUS_DEMO");
}
