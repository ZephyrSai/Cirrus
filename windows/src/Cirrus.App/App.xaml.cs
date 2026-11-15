using System.Windows;
using System.Windows.Threading;
using Cirrus.App.Platform;
using Cirrus.App.UI;
using Cirrus.Core;

namespace Cirrus.App;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
#if !DEBUG
        // Release builds honour only the user-facing switches (CIRRUS_DEMO, CIRRUS_PROFILE): no test or automation hooks.
        Env.LockDown();
#endif
        base.OnStartup(e);
        DispatcherUnhandledException += OnUnhandled;
        AppDomain.CurrentDomain.UnhandledException += (_, a) => Log.Status("unhandled: " + (a.ExceptionObject as Exception)?.GetType().Name);
        TaskScheduler.UnobservedTaskException += (_, a) => { Log.Status("unobserved task: " + a.Exception.InnerException?.GetType().Name); a.SetObserved(); };

        // Safety first: the read-only switch is applied before any account or job exists.
        var settings = Settings.Load(BuildInfo.IsTester);
        Log.Status($"Cirrus {BuildInfo.Version} for Windows starting{(BuildInfo.IsTester ? " (tester build)" : "")}; read-only iCloud: {SafetyPolicy.ReadOnlyICloud}");

        Paths.CleanCaches();                                   // previews/relays/temp after a day, opened copies after two weeks
        ImageReencoder.ToJpeg = Services.Thumbnails.ToJpeg;    // originals used as large previews are cached as JPEG
        ISecretStore secrets = OperatingSystem.IsWindows()
            ? new FileSecretStore(Paths.SupportDir("Secrets"), new DpapiProtector())
            : new MemorySecretStore();
        AccountManager.Shared = new AccountManager(secrets, new WindowsPresence()) { DemoMode = BuildInfo.DemoMode };
        AccountManager.Shared.Load();
        SyncStore.Shared.Load();
        JobScheduler.Shared.Start();
        TransferManager.Shared.Changed += () => Dispatcher.InvokeAsync(() => KeepAwake.Set(TransferManager.Shared.IsBusy));
        JobEngine.Shared.Finished += (job, ok, msg) => Dispatcher.InvokeAsync(() => Notifier.JobFinished(job.Name, ok, msg));

        var main = new MainWindow();
        MainWindow = main;
        main.Show();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        JobScheduler.Shared.Dispose();
        KeepAwake.Set(false);
        base.OnExit(e);
    }

    void OnUnhandled(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        Log.Error("UI error: " + e.Exception.GetType().Name + ": " + e.Exception.Message);
        Log.Status("UI error: " + e.Exception.GetType().Name);
        Dialogs.Error(null, "Something went wrong", e.Exception.Message);
        e.Handled = true;
    }
}
