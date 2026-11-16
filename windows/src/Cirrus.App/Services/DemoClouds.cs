#if DEBUG
using System.IO;
using Cirrus.Core;
using Cirrus.Fakes;

namespace Cirrus.App.Services;

/// <summary>
/// Debug demo mode (CIRRUS_DEMO=1): every other cloud is a fake server from the unit tests, seeded with demo content, so the
/// whole app (browsing, transfers, Add Account sign-ins) runs without real accounts. Release builds never contain this or
/// the fakes. Demo changes to the file clouds are kept in the demo cache folder between runs.
/// </summary>
static class DemoClouds
{
    public static FakeCloudRouter? Router { get; private set; }

    public static void Install()
    {
        var dir = Path.Combine(Paths.CacheDir("demo"), "clouds");
        var graph = FakeGraphServer.Demo();
        var google = FakeGoogle.DriveDemo(Path.Combine(dir, "googledrive"));
        var dropbox = FakeDropboxServer.Demo();
        var dav = FakeWebDAVServer.Demo(Path.Combine(dir, "webdav"));
        var s3 = FakeS3Server.Demo(Path.Combine(dir, "s3"));
        var immich = FakeImmichServer.Demo(Path.Combine(dir, "immich"));
        // Sidebar order as on the Mac: OneDrive, Google Drive, Dropbox, Nextcloud, WebDAV, S3, then Immich.
        var router = new FakeCloudRouter(graph, google, dropbox, dav, s3, immich);
        Router = router;
        CloudBackends.Transport = router;
        AccountManager.Shared.DemoClouds = router.DemoAccounts;
        CloudConnect.DemoGoogleDrive = google;
        CloudConnect.DemoAppID = p => p switch
        {
            CloudProvider.OneDrive => graph.S.ClientID,
            CloudProvider.Dropbox => dropbox.S.AppKey,
            _ => null,
        };
        CloudConnect.DemoApprove = (p, url) =>
        {
            switch (p)
            {
                case CloudProvider.OneDrive: return graph.ApproveAsync(url);
                case CloudProvider.Dropbox: return dropbox.ApproveAsync(url);
                case CloudProvider.Nextcloud: dav.Approve(url); return Task.CompletedTask;
                default: return Task.CompletedTask;
            }
        };
    }
}
#endif
