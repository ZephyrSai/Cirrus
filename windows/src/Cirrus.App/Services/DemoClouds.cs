#if DEBUG
using Cirrus.Core;

namespace Cirrus.App.Services;

/// <summary>
/// Debug demo mode (CIRRUS_DEMO=1): every other cloud is a fake server from the unit tests, seeded with demo content, so the
/// whole app runs without real accounts. Release builds never contain this or the fakes.
/// </summary>
static class DemoClouds
{
    public static void Install()
    {
        // Filled in once the connectors' fakes land.
    }
}
#endif
