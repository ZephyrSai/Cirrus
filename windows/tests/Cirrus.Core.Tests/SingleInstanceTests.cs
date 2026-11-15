namespace Cirrus.Core.Tests;

/// <summary>
/// The one-Cirrus-at-a-time guard. Each "launch" holds its lock on its own thread (a mutex belongs to the thread that took
/// it), and every test uses a private name, so the tests never touch a real Cirrus's lock and never start Cirrus.exe.
/// </summary>
public class SingleInstanceTests
{
    sealed class Launch : IDisposable
    {
        readonly Thread _thread;
        readonly ManualResetEventSlim _ready = new(), _quit = new();
        public SingleInstance? Instance;

        public Launch(string name, Action? onActivate = null, bool exitWithoutRelease = false)
        {
            _thread = new Thread(() =>
            {
                Instance = SingleInstance.Claim(name);
                if (Instance.IsFirst && onActivate is not null) Instance.Listen(onActivate);
                _ready.Set();
                if (exitWithoutRelease) return;   // like a Cirrus that crashed
                _quit.Wait();
                Instance.Dispose();
            }) { IsBackground = true };
            _thread.Start();
            Assert.True(_ready.Wait(TimeSpan.FromSeconds(10)));
            if (exitWithoutRelease) _thread.Join(TimeSpan.FromSeconds(10));
        }

        public bool IsFirst => Instance!.IsFirst;
        public void Dispose() { _quit.Set(); _thread.Join(TimeSpan.FromSeconds(10)); }
    }

    static string TestName() => "Cirrus.SingleInstance.test-" + Guid.NewGuid().ToString("N")[..12];

    [Fact]
    public void OnlyOneLaunchHoldsTheLock()
    {
        var name = TestName();
        using (var first = new Launch(name))
        {
            Assert.True(first.IsFirst);
            using var second = new Launch(name);
            Assert.False(second.IsFirst);
        }
        using var later = new Launch(name);   // once the first has quit, the next launch may run
        Assert.True(later.IsFirst);
    }

    [Fact]
    public void ALaterLaunchBringsTheRunningOneForward()
    {
        var name = TestName();
        using var activated = new ManualResetEventSlim();
        using var first = new Launch(name, () => activated.Set());
        Assert.True(first.IsFirst);
        using var second = SingleInstance.Claim(name);
        Assert.False(second.IsFirst);
        Assert.True(second.SignalFirst(TimeSpan.FromSeconds(5)));
        Assert.True(activated.Wait(TimeSpan.FromSeconds(5)));
        // Nobody listening: the signal gives up quickly instead of hanging the launch.
        using var lonely = SingleInstance.Claim(TestName());
        Assert.False(lonely.SignalFirst(TimeSpan.FromMilliseconds(200)));
    }

    [Fact]
    public void ACrashedCirrusDoesNotBlockTheNextLaunch()
    {
        var name = TestName();
        using (new Launch(name, exitWithoutRelease: true)) { }
        using var next = new Launch(name);
        Assert.True(next.IsFirst);
    }

    [Fact]
    public void TheLockIsPerUserNotPerProfileOrBuild()
    {
        var before = SingleInstance.DefaultName;
        var old = Environment.GetEnvironmentVariable("CIRRUS_PROFILE");
        try
        {
            Environment.SetEnvironmentVariable("CIRRUS_PROFILE", "qa");
            Assert.Equal(before, SingleInstance.DefaultName);
        }
        finally { Environment.SetEnvironmentVariable("CIRRUS_PROFILE", old); }
        Assert.StartsWith("Cirrus.SingleInstance.", before);
        Assert.DoesNotContain(Path.DirectorySeparatorChar, before);
        Assert.DoesNotContain('/', before);
        Assert.True(before.Length > "Cirrus.SingleInstance.".Length);
        Assert.Null(OperatingSystem.IsWindows() ? null : SingleInstance.OtherRunningCirrus());   // the process scan is Windows-only
    }
}
