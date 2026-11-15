namespace Cirrus.Core;

public enum TransferState { Queued, Running, Done, Failed, Cancelled }
public enum TransferDirection { Download, Upload, Copy, Other }

/// <summary>One row in the Transfers panel: a download, upload, export, copy or job run.</summary>
public sealed class Transfer
{
    public Guid Id { get; } = Guid.NewGuid();
    public string Title { get; }
    public TransferDirection Direction { get; }
    public string? Group { get; }
    /// <summary>Capacity bucket this transfer consumes ("icloud:&lt;account&gt;" or "vol:&lt;root&gt;") for preflight checks.</summary>
    public string? QuotaKey { get; init; }
    readonly object _lock = new();
    string _detail;
    long _total, _completed;
    TransferState _state = TransferState.Queued;
    string? _error;
    double _speed;
    (DateTimeOffset At, long Bytes)? _lastSample;
    string? _resultPath;
    internal readonly Func<Transfer, CancellationToken, Task> Work;
    internal CancellationTokenSource Cts { get; } = new();
    internal TransferManager? Manager;

    public DateTimeOffset? StartedAt { get; private set; }
    public DateTimeOffset? FinishedAt { get; private set; }

    internal Transfer(string title, string detail, TransferDirection direction, long total, string? group, Func<Transfer, CancellationToken, Task> work)
    {
        Title = title; _detail = detail; Direction = direction; _total = total; Group = group; Work = work;
    }

    public string Detail { get { lock (_lock) return _detail; } }
    public long Total { get { lock (_lock) return _total; } }
    public long Completed { get { lock (_lock) return _completed; } }
    public TransferState State { get { lock (_lock) return _state; } }
    public string? Error { get { lock (_lock) return _error; } }
    public double Speed { get { lock (_lock) return _speed; } }
    /// <summary>Where the result landed (for "Show in Explorer"). Thread-safe: parallel workers set it.</summary>
    public string? ResultPath { get { lock (_lock) return _resultPath; } set { lock (_lock) _resultPath = value; } }
    public double Fraction { get { var t = Total; return t > 0 ? Math.Min(1, (double)Completed / t) : (State == TransferState.Done ? 1 : 0); } }
    public bool IsFinished => State is TransferState.Done or TransferState.Failed or TransferState.Cancelled;

    /// <summary>Progress from any thread: bytes done of total (0 = unknown).</summary>
    public void Report(long done, long total)
    {
        lock (_lock)
        {
            _completed = done;
            if (total > 0) _total = total;
            var now = DateTimeOffset.UtcNow;
            if (_lastSample is { } s)
            {
                var dt = (now - s.At).TotalSeconds;
                if (dt > 0.4)
                {
                    var inst = (done - s.Bytes) / dt;
                    _speed = _speed == 0 ? inst : _speed * 0.7 + inst * 0.3;
                    _lastSample = (now, done);
                }
            }
            else _lastSample = (now, done);
        }
        Manager?.SetNeedsNotify();
    }

    public void SetDetail(string s) { lock (_lock) _detail = s; Manager?.SetNeedsNotify(); }

    internal void SetState(TransferState s, string? error = null)
    {
        lock (_lock)
        {
            _state = s;
            _error = error;
            if (s == TransferState.Running) StartedAt = DateTimeOffset.UtcNow;
            if (s is TransferState.Done or TransferState.Cancelled or TransferState.Failed) FinishedAt = DateTimeOffset.UtcNow;
            if (s == TransferState.Done && _total > 0) _completed = _total;
        }
    }

    public string SpeedText => Speed > 1 && State == TransferState.Running ? ((long)Speed).ByteString() + "/s" : "";

    public string? EtaText
    {
        get
        {
            var s = Speed; var remaining = Total - Completed;
            if (s <= 1 || remaining <= 0 || State != TransferState.Running) return null;
            var t = TimeSpan.FromSeconds(remaining / s);
            if (t.TotalHours >= 1) return $"{(int)t.TotalHours} hr {t.Minutes} min left";
            if (t.TotalMinutes >= 1) return $"{(int)t.TotalMinutes} min {t.Seconds} s left";
            return $"{Math.Max(1, t.Seconds)} s left";
        }
    }

    public string StatusText => State switch
    {
        TransferState.Queued => "Waiting…",
        TransferState.Running => Total > 0 ? $"{Completed.ByteString()} of {Total.ByteString()}" + (SpeedText.Length > 0 ? $" — {SpeedText}" : "") + (EtaText is { } e ? $" — {e}" : "") : Detail,
        TransferState.Done => Total > 0 ? $"Done — {Total.ByteString()}" : "Done",
        TransferState.Failed => Error ?? "Failed",
        _ => "Cancelled",
    };
}

/// <summary>Queue for downloads, uploads, exports and copies with bounded concurrency.</summary>
public sealed class TransferManager
{
    public static TransferManager Shared { get; } = new();
    readonly object _lock = new();
    readonly List<Transfer> _transfers = [];
    int _notifyPending;
    readonly HashSet<Guid> _runningJobs = [];

    /// <summary>Raised (throttled to ~7 per second) on any thread; the app marshals to the UI thread.</summary>
    public event Action? Changed;
    public int MaxConcurrent { get; set; } = 4;

    public IReadOnlyList<Transfer> Transfers { get { lock (_lock) return _transfers.ToList(); } }
    public IReadOnlyList<Transfer> Active => Transfers.Where(t => !t.IsFinished).ToList();
    public bool IsBusy { get { lock (_lock) return _transfers.Any(t => !t.IsFinished) || _runningJobs.Count > 0; } }

    public void JobStarted(Guid id) { lock (_lock) _runningJobs.Add(id); Post(); }
    public void JobFinished(Guid id) { lock (_lock) _runningJobs.Remove(id); Post(); }

    public Transfer Enqueue(string title, Func<Transfer, CancellationToken, Task> work, string detail = "", TransferDirection direction = TransferDirection.Other,
        long total = 0, string? group = null, string? quotaKey = null)
    {
        var t = new Transfer(title, detail, direction, total, group, work) { QuotaKey = quotaKey, Manager = this };
        lock (_lock) _transfers.Add(t);
        Pump();
        Post();
        return t;
    }

    /// <summary>Bytes still to be written into a capacity bucket by queued/running transfers.</summary>
    public long PendingBytes(string quotaKey) => Active.Where(t => t.QuotaKey == quotaKey).Sum(t => Math.Max(0, t.Total - t.Completed));

    public (long Done, long Total, int Count) Overall
    {
        get { var a = Active; return (a.Sum(t => t.Completed), a.Sum(t => Math.Max(t.Total, t.Completed)), a.Count); }
    }

    void Pump()
    {
        List<Transfer> start = [];
        lock (_lock)
        {
            var running = _transfers.Count(t => t.State == TransferState.Running);
            foreach (var t in _transfers)
            {
                if (running >= Math.Max(1, MaxConcurrent)) break;
                if (t.State != TransferState.Queued) continue;
                t.SetState(TransferState.Running);
                running++;
                start.Add(t);
            }
        }
        foreach (var t in start)
        {
            _ = Task.Run(async () =>
            {
                try
                {
                    await t.Work(t, t.Cts.Token).ConfigureAwait(false);
                    t.SetState(TransferState.Done);
                }
                catch (OperationCanceledException) { t.SetState(TransferState.Cancelled); }
                catch (ICloudException e) when (e.Kind == ICloudErrorKind.Cancelled) { t.SetState(TransferState.Cancelled); }
                catch (Exception e)
                {
                    if (t.Cts.IsCancellationRequested) t.SetState(TransferState.Cancelled);
                    else t.SetState(TransferState.Failed, e.Message);
                    Log.Error("transfer failed: " + e.Message);
                }
                Pump();
                Post();
            });
        }
    }

    public void Cancel(Transfer t)
    {
        if (t.State == TransferState.Queued) t.SetState(TransferState.Cancelled);
        t.Cts.Cancel();
        Post();
    }

    public void CancelAll() { foreach (var t in Active) Cancel(t); }

    public void Retry(Transfer t)
    {
        if (t.State is not (TransferState.Failed or TransferState.Cancelled)) return;
        var n = new Transfer(t.Title, t.Detail, t.Direction, t.Total, t.Group, t.Work) { QuotaKey = t.QuotaKey, Manager = this };
        lock (_lock)
        {
            var i = _transfers.FindIndex(x => x.Id == t.Id);
            if (i >= 0) _transfers[i] = n; else _transfers.Add(n);
        }
        Pump(); Post();
    }

    /// <summary>Clears finished rows but keeps failures visible.</summary>
    public void ClearFinished() { lock (_lock) _transfers.RemoveAll(t => t.State is TransferState.Done or TransferState.Cancelled); Post(); }
    public void ClearAllFinished() { lock (_lock) _transfers.RemoveAll(t => t.IsFinished); Post(); }

    internal void SetNeedsNotify()
    {
        if (Interlocked.Exchange(ref _notifyPending, 1) == 1) return;
        _ = Task.Delay(150).ContinueWith(_ => { Interlocked.Exchange(ref _notifyPending, 0); Post(); }, TaskScheduler.Default);
    }

    void Post() { try { Changed?.Invoke(); } catch (Exception e) { Log.Error("transfer listener failed: " + e.GetType().Name); } }

    /// <summary>Wait until every transfer in a group has finished (used by relays, sync and backup runs).</summary>
    public async Task WaitForGroup(string group, CancellationToken ct = default)
    {
        while (Transfers.Any(t => t.Group == group && !t.IsFinished)) await Task.Delay(200, ct).ConfigureAwait(false);
    }

    public async Task WaitFor(Transfer t, CancellationToken ct = default)
    {
        while (!t.IsFinished) await Task.Delay(150, ct).ConfigureAwait(false);
    }
}
