using System.Diagnostics;
using System.IO.Pipes;
using System.Text;

namespace Cirrus.Core;

/// <summary>
/// One Cirrus at a time, whatever the build, flavour (tester) or <c>CIRRUS_PROFILE</c>: a per-user named mutex
/// (<c>Local\Cirrus.SingleInstance.&lt;user SID&gt;</c>) decides, and a second launch asks the running one to come forward
/// through a named pipe only the same Windows user can open, then exits. There is no override.
/// </summary>
public sealed class SingleInstance : IDisposable
{
    const string Prefix = "Cirrus.SingleInstance.";
    const string ActivateMessage = "activate";

    readonly Mutex _mutex;
    readonly CancellationTokenSource _stop = new();
    readonly int _ownerThread;
    bool _disposed;

    /// <summary>True when this process holds the lock (it's the one Cirrus that may run).</summary>
    public bool IsFirst { get; }
    public string Name { get; }

    SingleInstance(Mutex mutex, bool owned, string name)
    {
        _mutex = mutex; IsFirst = owned; Name = name; _ownerThread = Environment.CurrentManagedThreadId;
    }

    /// <summary>The same for every build and profile of this Windows user (never a profile folder or a file).</summary>
    public static string DefaultName => Prefix + UserKey;

    static string UserKey
    {
        get
        {
            if (OperatingSystem.IsWindows())
            {
                try { if (System.Security.Principal.WindowsIdentity.GetCurrent().User?.Value is { Length: > 0 } sid) return sid; } catch { }
            }
            var u = Environment.UserName;
            return new string(u.Select(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' ? c : '_').ToArray());
        }
    }

    /// <summary>Takes the lock if nobody holds it. Call it before any window or other state exists.</summary>
    public static SingleInstance Claim(string? name = null)
    {
        name ??= DefaultName;
        var m = new Mutex(false, @"Local\" + name);
        bool owned;
        try { owned = m.WaitOne(0); }
        catch (AbandonedMutexException) { owned = true; }   // the previous Cirrus ended without letting go
        return new SingleInstance(m, owned, name);
    }

    /// <summary>First instance: waits (in the background) for later launches asking it to come forward.</summary>
    public void Listen(Action onActivate)
    {
        if (!IsFirst) throw new InvalidOperationException("Only the running Cirrus listens.");
        var ct = _stop.Token;
        _ = Task.Run(async () =>
        {
            while (!ct.IsCancellationRequested)
            {
                try
                {
                    await using var server = new NamedPipeServerStream(Name, PipeDirection.In, 1, PipeTransmissionMode.Byte,
                        PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                    await server.WaitForConnectionAsync(ct).ConfigureAwait(false);
                    using var read = CancellationTokenSource.CreateLinkedTokenSource(ct);
                    read.CancelAfter(TimeSpan.FromSeconds(2));
                    var buf = new byte[64];
                    var n = await server.ReadAsync(buf, read.Token).ConfigureAwait(false);
                    if (Encoding.ASCII.GetString(buf, 0, n).Trim() == ActivateMessage)
                        try { onActivate(); } catch (Exception e) { Log.Status("bringing Cirrus forward failed: " + e.GetType().Name); }
                }
                catch (OperationCanceledException) when (ct.IsCancellationRequested) { return; }
                catch (Exception e)
                {
                    Log.Status("single-instance listener: " + e.GetType().Name);
                    try { await Task.Delay(500, ct).ConfigureAwait(false); } catch (OperationCanceledException) { return; }
                }
            }
        }, CancellationToken.None);
    }

    /// <summary>A later launch: asks the running Cirrus to come forward. False when it didn't answer in time.</summary>
    public bool SignalFirst(TimeSpan timeout)
    {
        try
        {
            using var client = new NamedPipeClientStream(".", Name, PipeDirection.Out, PipeOptions.CurrentUserOnly);
            client.Connect((int)Math.Max(1, timeout.TotalMilliseconds));
            client.Write(Encoding.ASCII.GetBytes(ActivateMessage + "\n"));
            client.Flush();
            return true;
        }
        catch (Exception e) when (e is TimeoutException or IOException or UnauthorizedAccessException) { return false; }
    }

    /// <summary>
    /// Another Cirrus.exe of this user's session (for example a build from before the lock existed). Windows only: on
    /// other systems the name belongs to other programs.
    /// </summary>
    public static Process? OtherRunningCirrus()
    {
        if (!OperatingSystem.IsWindows()) return null;
        using var me = Process.GetCurrentProcess();
        foreach (var p in Process.GetProcessesByName("Cirrus"))
        {
            try
            {
                if (p.Id == me.Id || p.SessionId != me.SessionId) { p.Dispose(); continue; }
                if (p.MainModule?.FileVersionInfo.ProductName is { } product && product != "Cirrus") { p.Dispose(); continue; }
                return p;
            }
            catch { p.Dispose(); }   // another user's process, or it just ended
        }
        return null;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _stop.Cancel();
        // A mutex is released by the thread that took it; at process exit Windows releases it in any case.
        if (IsFirst && Environment.CurrentManagedThreadId == _ownerThread) { try { _mutex.ReleaseMutex(); } catch (ApplicationException) { } }
        _mutex.Dispose();
        _stop.Dispose();
    }
}
