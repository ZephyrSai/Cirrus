using System.Windows;
using System.Windows.Threading;
using Cirrus.App.Platform;
using Cirrus.App.UI;
using Cirrus.Core;

namespace Cirrus.App;

public partial class App : Application
{
    SingleInstance? _instance;
    bool _activatePending;

    protected override void OnStartup(StartupEventArgs e)
    {
#if !DEBUG
        // Release builds honour only the user-facing switches (CIRRUS_DEMO, CIRRUS_PROFILE): no test or automation hooks.
        Env.LockDown();
#endif
        // One Cirrus at a time, whatever the build, flavour or profile: decided before any window, setting or account
        // exists. A second launch brings the running one forward and quits. There is no override.
        _instance = SingleInstance.Claim();
        if (!_instance.IsFirst)
        {
            Foreground.AllowAny();   // the running Cirrus may take the foreground from this (foreground) process
            _instance.SignalFirst(TimeSpan.FromSeconds(3));
            _instance.Dispose();
            Shutdown(0);
            return;
        }
        if (SingleInstance.OtherRunningCirrus() is { } older)
        {
            // A Cirrus from before the lock existed: bring it forward the old way, and leave it running alone.
            using (older) Foreground.Bring(older.MainWindowHandle);
            Shutdown(0);
            return;
        }
        _instance.Listen(() => Dispatcher.InvokeAsync(BringToFront));
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
        Services.GoogleAccounts.Shared = new Services.GoogleAccounts(secrets, new WindowsPresence());
#if DEBUG
        if (AccountManager.Shared.DemoMode) Services.DemoClouds.Install();   // fake clouds (Debug builds only)
#endif
        AccountManager.Shared.Load();
        SyncStore.Shared.Load();
        JobScheduler.Shared.Start();
        TransferManager.Shared.Changed += () => Dispatcher.InvokeAsync(() => KeepAwake.Set(TransferManager.Shared.IsBusy));
        JobEngine.Shared.Finished += (job, ok, msg) => Dispatcher.InvokeAsync(() => Notifier.JobFinished(job.Name, ok, msg));

        var main = new MainWindow();
        MainWindow = main;
        main.Show();
        if (_activatePending) BringToFront();
    }

    /// <summary>A later launch asked for us: restore and focus the main window.</summary>
    void BringToFront()
    {
        if (MainWindow is not { IsLoaded: true } w) { _activatePending = true; return; }
        _activatePending = false;
        if (w.WindowState == WindowState.Minimized) w.WindowState = WindowState.Normal;
        w.Show();
        w.Activate();
        w.Topmost = true;   // the documented nudge past the foreground lock; undone at once
        w.Topmost = false;
        w.Focus();
        Foreground.Bring(new System.Windows.Interop.WindowInteropHelper(w).Handle);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        if (_instance is { IsFirst: true })
        {
            JobScheduler.Shared.Dispose();
            KeepAwake.Set(false);
        }
        _instance?.Dispose();
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
