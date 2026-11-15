namespace Cirrus.Core;

public enum ICloudErrorKind
{
    BadCredentials, NeedsSignIn, TwoFactorRequired, Http, Server, WebAccessDisabled, ApprovalTimedOut,
    ServiceUnavailable, NotFound, Conflict, Cancelled,
}

/// <summary>Errors from iCloud web services, with the same user-facing wording as the Mac app.</summary>
public sealed class ICloudException : Exception
{
    public ICloudErrorKind Kind { get; }
    public int StatusCode { get; }
    public string? Detail { get; }

    public ICloudException(ICloudErrorKind kind, int statusCode = 0, string? detail = null) : base(Describe(kind, statusCode, detail))
    {
        Kind = kind; StatusCode = statusCode; Detail = detail;
    }

    public static ICloudException Http(int code, string? message) => new(ICloudErrorKind.Http, code, message);
    public static ICloudException Server(string message) => new(ICloudErrorKind.Server, 0, message);
    public static ICloudException Unavailable(string service) => new(ICloudErrorKind.ServiceUnavailable, 0, service);
    public static ICloudException NeedsSignIn() => new(ICloudErrorKind.NeedsSignIn);
    public static ICloudException NotFound() => new(ICloudErrorKind.NotFound);
    public static ICloudException Conflict() => new(ICloudErrorKind.Conflict);

    static string Describe(ICloudErrorKind kind, int code, string? detail) => kind switch
    {
        ICloudErrorKind.BadCredentials => "Incorrect Apple ID or password.",
        ICloudErrorKind.NeedsSignIn => "Your iCloud session expired. Sign in again to continue.",
        ICloudErrorKind.TwoFactorRequired => "Enter the verification code to finish signing in.",
        ICloudErrorKind.Http => detail is not null ? $"{detail} (HTTP {code})" : $"iCloud returned HTTP {code}.",
        ICloudErrorKind.Server => detail ?? "iCloud returned an error.",
        ICloudErrorKind.WebAccessDisabled =>
            "Advanced Data Protection is on and web access is off. On your iPhone, open Settings › [your name] › iCloud and turn on “Access iCloud Data on the Web”.",
        ICloudErrorKind.ApprovalTimedOut => "Timed out waiting for approval on your Apple device.",
        ICloudErrorKind.ServiceUnavailable => $"{detail} isn’t available for this Apple ID.",
        ICloudErrorKind.NotFound => "The item no longer exists in iCloud.",
        ICloudErrorKind.Conflict => "The item changed in iCloud. Refresh and try again.",
        ICloudErrorKind.Cancelled => "Cancelled.",
        _ => "iCloud error.",
    };
}

public enum SyncErrorKind { DeleteGuard, NotEnoughSpace, Unavailable }

public sealed class SyncException : Exception
{
    public SyncErrorKind Kind { get; }
    public SyncException(SyncErrorKind kind, string message) : base(message) { Kind = kind; }

    public static SyncException DeleteGuard(int n, int total) => new(SyncErrorKind.DeleteGuard,
        $"Stopped: this run would move {n} of {total} items to the Recycle Bin. Review the preview and choose “Run Anyway” if that’s intended.");

    public static SyncException NotEnoughSpace(long need, long free) => new(SyncErrorKind.NotEnoughSpace,
        $"Not enough space on the destination: needs {need.ByteString()}, {free.ByteString()} available.");

    public static SyncException Unavailable(string s) => new(SyncErrorKind.Unavailable, s);
}
