using System.Net;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Cirrus.Core;

// Other cloud services beside iCloud (port of CloudCore.swift). Each one is an ICloudDriveBackend: the same
// IDriveBackend that iCloud Drive uses (so browsing, the transfer queue, drag and drop, sync and copy between services
// all work as they do for iCloud), plus a few optional extras. Immich is a photo library: an IPhotosBackend instead.
// iCloud stays the main account; these are added from "Add Account…".

/// <summary>The services Cirrus can connect to beside iCloud.</summary>
[JsonConverter(typeof(CloudProviderJsonConverter))]
public enum CloudProvider { Nextcloud, WebDAV, OneDrive, GoogleDrive, Dropbox, S3, Immich }

public static class CloudProviders
{
    /// <summary>The order "Add Account…" lists them in.</summary>
    public static readonly IReadOnlyList<CloudProvider> MenuOrder =
        [CloudProvider.Nextcloud, CloudProvider.OneDrive, CloudProvider.GoogleDrive, CloudProvider.Dropbox, CloudProvider.Immich, CloudProvider.S3, CloudProvider.WebDAV];

    /// <summary>Same raw values as the Mac app ("nextcloud", "googleDrive"…): used in account ids and saved records.</summary>
    public static string Raw(this CloudProvider p) => p switch
    {
        CloudProvider.Nextcloud => "nextcloud",
        CloudProvider.WebDAV => "webdav",
        CloudProvider.OneDrive => "onedrive",
        CloudProvider.GoogleDrive => "googleDrive",
        CloudProvider.Dropbox => "dropbox",
        CloudProvider.S3 => "s3",
        _ => "immich",
    };

    public static CloudProvider? FromRaw(string? raw) =>
        Enum.GetValues<CloudProvider>().Cast<CloudProvider?>().FirstOrDefault(p => p!.Value.Raw() == raw);

    /// <summary>A photo library (Immich) rather than files: it gets Cirrus's Photos views, not the file browser.</summary>
    public static bool IsPhotoLibrary(this CloudProvider p) => p == CloudProvider.Immich;

    public static string DisplayName(this CloudProvider p) => p switch
    {
        CloudProvider.Nextcloud => "Nextcloud",
        CloudProvider.WebDAV => "WebDAV",
        CloudProvider.OneDrive => "OneDrive",
        CloudProvider.GoogleDrive => "Google Drive",
        CloudProvider.Dropbox => "Dropbox",
        CloudProvider.S3 => "S3 Storage",
        _ => "Immich",
    };

    /// <summary>Segoe Fluent Icons glyph for the sidebar and breadcrumbs (no brand artwork).</summary>
    public static string Glyph(this CloudProvider p) => p switch
    {
        CloudProvider.Nextcloud => "",    // Cloud
        CloudProvider.WebDAV => "",       // Network
        CloudProvider.OneDrive => "",     // Cloud
        CloudProvider.GoogleDrive => "",  // Folder
        CloudProvider.Dropbox => "",      // Package
        CloudProvider.S3 => "",           // Database
        _ => "",                          // Photo
    };

    /// <summary>The largest file the service documents (self-hosted servers set their own: null).</summary>
    public static long? MaxFileSize(this CloudProvider p) => p switch
    {
        CloudProvider.OneDrive => 250_000_000_000,
        CloudProvider.GoogleDrive => 5_000_000_000_000,
        CloudProvider.Dropbox => 2_000_000_000_000,
        CloudProvider.S3 => 5_000_000_000_000,
        _ => null,
    };

    /// <summary>What the service calls the place deleted items go.</summary>
    public static string DeletedTitle(this CloudProvider p) => p switch
    {
        CloudProvider.Nextcloud => "Deleted Files",
        CloudProvider.WebDAV => "Deleted Items",
        CloudProvider.OneDrive => "Recycle Bin",
        CloudProvider.GoogleDrive => "Trash",
        CloudProvider.Dropbox => "Deleted Files",
        CloudProvider.S3 => "Deleted Items",
        _ => "Trash",
    };
}

sealed class CloudProviderJsonConverter : JsonConverter<CloudProvider>
{
    public override CloudProvider Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        CloudProviders.FromRaw(reader.GetString()) ?? throw new JsonException("Unknown cloud provider.");
    public override void Write(Utf8JsonWriter writer, CloudProvider value, JsonSerializerOptions options) => writer.WriteStringValue(value.Raw());
}

/// <summary>One connected account (no secrets: those are kept DPAPI-encrypted as a <see cref="CloudSecret"/>).</summary>
public sealed class CloudAccountRecord
{
    /// <summary>"cloud:&lt;provider raw&gt;:&lt;uuid&gt;".</summary>
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("provider")] public CloudProvider Provider { get; set; }
    /// <summary>Shown in the sidebar: the email or user name, plus the server for self-hosted ones.</summary>
    [JsonPropertyName("title")] public string Title { get; set; } = "";
    /// <summary>Nextcloud: the server's base URL. WebDAV: the full WebDAV folder URL. S3: the endpoint. Immich: the server.</summary>
    [JsonPropertyName("server")] public string? Server { get; set; }
    /// <summary>Nextcloud / WebDAV login name; S3 access key ID.</summary>
    [JsonPropertyName("username")] public string? Username { get; set; }
    [JsonPropertyName("added")] public DateTimeOffset Added { get; set; } = DateTimeOffset.UtcNow;
    /// <summary>Service-specific settings that aren't secret (S3: "region", "bucket", "pathStyle" = "1"/"0").</summary>
    [JsonPropertyName("options")] public Dictionary<string, string>? Options { get; set; }

    public CloudAccountRecord() { }

    public CloudAccountRecord(CloudProvider provider, string title, string? server = null, string? username = null,
        Dictionary<string, string>? options = null, string? id = null)
    {
        Id = string.IsNullOrEmpty(id) ? NewID(provider) : id;
        Provider = provider; Title = title; Server = server; Username = username; Options = options;
    }

    public static string NewID(CloudProvider p) => "cloud:" + p.Raw() + ":" + Guid.NewGuid().ToString().ToLowerInvariant();

    public string? Option(string key) => Options is { } o && o.TryGetValue(key, out var v) ? v : null;

    public CloudAccountRecord Copy() => new()
    {
        Id = Id, Provider = Provider, Title = Title, Server = Server, Username = Username, Added = Added,
        Options = Options is null ? null : new Dictionary<string, string>(Options),
    };
}

/// <summary>What a cloud account needs to sign back in. Kept only in the secret store (DPAPI on Windows).</summary>
public sealed record CloudSecret
{
    /// <summary>Nextcloud / WebDAV: an app password. S3: the secret access key. Immich: the API key.</summary>
    [JsonPropertyName("password")] public string? Password { get; init; }
    /// <summary>OAuth services (OneDrive, Google Drive, Dropbox).</summary>
    [JsonPropertyName("refreshToken")] public string? RefreshToken { get; init; }
    /// <summary>The OAuth client / app key the account signed in with.</summary>
    [JsonPropertyName("clientID")] public string? ClientID { get; init; }
    [JsonPropertyName("clientSecret")] public string? ClientSecret { get; init; }
}

/// <summary>A finished sign-in or connect: what to save and show.</summary>
public sealed record CloudConnection(CloudAccountRecord Record, CloudSecret Secret);

/// <summary>Saved cloud accounts: the record list and each account's secret, both in the (DPAPI) secret store.</summary>
public static class CloudStore
{
    public const string RecordsService = "Cirrus Cloud Accounts";
    public const string SecretService = "Cirrus Cloud Account";
    static readonly object Lock = new();
    static ISecretStore _store = new MemorySecretStore();

    /// <summary>Set once at startup (the app's DPAPI store). Demo mode and tests keep a memory store.</summary>
    public static ISecretStore Store { get { lock (Lock) return _store; } set { lock (Lock) _store = value; } }

    static readonly JsonSerializerOptions Options = new() { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };

    public static List<CloudAccountRecord> Records()
    {
        var d = Store.Get(RecordsService, "list");
        if (d is null) return [];
        try { return JsonSerializer.Deserialize<List<CloudAccountRecord>>(d, Options) ?? []; } catch { return []; }
    }

    static void Write(List<CloudAccountRecord> list) => Store.Set(RecordsService, "list", JsonSerializer.SerializeToUtf8Bytes(list, Options));

    public static void Save(CloudAccountRecord r, CloudSecret secret)
    {
        lock (Lock)
        {
            SetSecret(r.Id, secret);
            var list = Records().Where(x => x.Id != r.Id).ToList();
            list.Add(r);
            Write(list);
        }
    }

    public static void Update(CloudAccountRecord r)
    {
        lock (Lock) Write(Records().Select(x => x.Id == r.Id ? r : x).ToList());
    }

    public static CloudSecret? Secret(string id)
    {
        var d = Store.Get(SecretService, id);
        if (d is null) return null;
        try { return JsonSerializer.Deserialize<CloudSecret>(d, Options); } catch { return null; }
    }

    public static void SetSecret(string id, CloudSecret s) => Store.Set(SecretService, id, JsonSerializer.SerializeToUtf8Bytes(s, Options));

    public static void Remove(string id)
    {
        lock (Lock)
        {
            Store.Delete(SecretService, id);
            Write(Records().Where(x => x.Id != id).ToList());
        }
    }
}

public enum CloudErrorKind { SignInNeeded, Denied, Server, NotFound, QuotaExceeded, Unsupported, NotConfigured, Cancelled }

/// <summary>Errors from other cloud services, with the same wording as the Mac app.</summary>
public sealed class CloudException : Exception
{
    public CloudErrorKind Kind { get; }
    /// <summary>SignInNeeded / QuotaExceeded: the service name; otherwise the sentence shown.</summary>
    public string Detail { get; }

    public CloudException(CloudErrorKind kind, string detail = "") : base(Describe(kind, detail)) { Kind = kind; Detail = detail; }

    /// <summary>The saved sign-in no longer works (token revoked, app password deleted…).</summary>
    public static CloudException SignInNeeded(string service) => new(CloudErrorKind.SignInNeeded, service);
    /// <summary>The service refused (permissions, locked file…).</summary>
    public static CloudException Denied(string message) => new(CloudErrorKind.Denied, message);
    public static CloudException Server(string message) => new(CloudErrorKind.Server, message);
    public static CloudException NotFound() => new(CloudErrorKind.NotFound);
    public static CloudException QuotaExceeded(string service) => new(CloudErrorKind.QuotaExceeded, service);
    public static CloudException Unsupported(string message) => new(CloudErrorKind.Unsupported, message);
    public static CloudException NotConfigured(string message) => new(CloudErrorKind.NotConfigured, message);
    public static CloudException Cancelled() => new(CloudErrorKind.Cancelled);

    static string Describe(CloudErrorKind k, string d) => k switch
    {
        CloudErrorKind.SignInNeeded => $"{d} needs you to sign in again.",
        CloudErrorKind.NotFound => "The item no longer exists on the server.",
        CloudErrorKind.QuotaExceeded => $"There isn’t enough space in {d}.",
        CloudErrorKind.Cancelled => "Cancelled.",
        _ => d,
    };
}

/// <summary>
/// A connected cloud's files, as Cirrus browses them. Rules every implementation follows:
/// <list type="bullet">
/// <item>folders have <c>Type == "FOLDER"</c>, files <c>"FILE"</c>; sizes in bytes, dates as the server reports them;</item>
/// <item>children of the top folder have <c>ParentID == RootID</c> (normalize server aliases such as "root");</item>
/// <item>items listed by <c>ListTrashAsync</c> have <c>ParentID == CloudConventions.TrashParent</c>, so
///   <see cref="DriveNode.IsInTrash"/> holds and Delete Immediately is allowed only for them;</item>
/// <item><c>TrashAsync</c> never deletes permanently: it uses the service's own trash / recycle bin, or (plain WebDAV
///   servers and S3 without one) a "Deleted by Cirrus" folder; only <c>DeleteForeverAsync</c> deletes for good, and it
///   refuses nodes that aren't in the trash (<c>DriveBackendExtensions.GuardTrashOnly</c>);</item>
/// <item>safe to call from any thread and from many tasks at once;</item>
/// <item>errors are <see cref="CloudException"/> (or <see cref="OperationCanceledException"/>), with sentences a user can act on.</item>
/// </list>
/// Not subject to <see cref="SafetyPolicy.ReadOnlyICloud"/>: that switch protects iCloud only.
/// </summary>
public interface ICloudDriveBackend : IDriveBackend
{
    CloudProvider Provider { get; }
    /// <summary>Can deleted items be listed (and restored) from Cirrus? OneDrive's and Dropbox's can't.</summary>
    bool CanListTrash { get; }
    /// <summary>Space used and available, if the service tells.</summary>
    Task<StorageUsage?> QuotaAsync(CancellationToken ct = default);
    /// <summary>A server-made thumbnail (JPEG/PNG bytes), or null when the service has none for this file.</summary>
    Task<byte[]?> ThumbnailAsync(DriveNode node, int maxPixel, CancellationToken ct = default);
}

/// <summary>OAuth backends whose refresh token can change (Microsoft and others rotate them): the app stores each new one.</summary>
public interface ICloudTokenRotating
{
    Action<string>? OnNewRefreshToken { get; set; }
}

public static class CloudConventions
{
    /// <summary>ParentID of every item a cloud's <c>ListTrashAsync</c> returns (matches <see cref="DriveNode.IsInTrash"/>).</summary>
    public const string TrashParent = "TRASH_ROOT";
    /// <summary>Google Docs, Sheets… keep their Google MIME type in <see cref="DriveNode.Zone"/> (they have no size).</summary>
    public const string GoogleNativePrefix = "application/vnd.google-apps.";
    public static bool IsGoogleNative(this DriveNode n) => !n.IsFolder && n.Zone.StartsWith(GoogleNativePrefix, StringComparison.Ordinal);
}

/// <summary>Builds the backend for a saved account. <see cref="Transport"/> swaps in fake servers (tests, Debug demo mode).</summary>
public static class CloudBackends
{
    static HttpMessageHandler? _transport;
    /// <summary>A fake server for every cloud request (tests and Debug demo builds). Null: the real network.</summary>
    public static HttpMessageHandler? Transport { get => Volatile.Read(ref _transport); set => Volatile.Write(ref _transport, value); }

    /// <summary>
    /// An HttpClient for a cloud connector: <paramref name="handler"/> (or <see cref="Transport"/>) when set, otherwise the
    /// network with no proxy surprises, HTTP/2 where offered and no overall timeout (connectors time out stalls themselves).
    /// The fake handler is shared and never disposed by the client.
    /// </summary>
    public static HttpClient Http(HttpMessageHandler? handler = null)
    {
        var fake = handler ?? Transport;
        if (fake is not null) return new HttpClient(fake, disposeHandler: false) { Timeout = Timeout.InfiniteTimeSpan };
        var h = new SocketsHttpHandler
        {
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate | DecompressionMethods.Brotli,
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
            ConnectTimeout = TimeSpan.FromSeconds(30),
            AllowAutoRedirect = false,
        };
        return new HttpClient(h, disposeHandler: true) { Timeout = Timeout.InfiniteTimeSpan };
    }

    public static ICloudDriveBackend Make(CloudAccountRecord r, CloudSecret secret) => r.Provider switch
    {
        CloudProvider.Nextcloud or CloudProvider.WebDAV => WebDAVCloud.Make(r, secret, Transport),
        CloudProvider.OneDrive => OneDriveCloud.Make(r, secret, Transport),
        CloudProvider.GoogleDrive => GoogleDriveCloud.Make(r, secret, Transport),
        CloudProvider.Dropbox => DropboxCloud.Make(r, secret, Transport),
        CloudProvider.S3 => S3Cloud.Make(r, secret, Transport),
        _ => throw CloudException.Unsupported("Immich is a photo library, not a file drive."),
    };

    /// <summary>Photo-library services (<see cref="CloudProviders.IsPhotoLibrary"/>).</summary>
    public static IPhotosBackend MakePhotos(CloudAccountRecord r, CloudSecret secret) => r.Provider switch
    {
        CloudProvider.Immich => ImmichCloud.Make(r, secret, Transport),
        _ => throw CloudException.Unsupported($"{r.Provider.DisplayName()} isn’t a photo library."),
    };
}
