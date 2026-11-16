using System.Net;
using System.Net.Http;
using Cirrus.Core;

namespace Cirrus.Fakes;

/// <summary>
/// A fake cloud service (WebDAV/Nextcloud, Microsoft Graph, Google, Dropbox, S3, Immich), served as an HttpMessageHandler.
/// Unit tests use one directly; Debug builds of the app in demo mode route every cloud request through
/// <see cref="FakeCloudRouter"/>. Fakes compile into Debug app builds, so they use only Cirrus.Core and the BCL (no xunit).
/// Never part of a Release build.
/// </summary>
public interface IFakeCloud
{
    /// <summary>Whether this fake answers requests for <paramref name="uri"/> (by host, and path where hosts are shared).</summary>
    bool Handles(Uri uri);
    /// <summary>The demo-mode accounts this fake serves (records + secrets its seeded content accepts).</summary>
    IReadOnlyList<CloudConnection> DemoAccounts();
}

/// <summary>Sends each request to the first fake that handles it; anything else fails without touching the network.</summary>
public sealed class FakeCloudRouter : HttpMessageHandler
{
    readonly List<(IFakeCloud Fake, HttpMessageInvoker Invoker)> _fakes = [];

    public FakeCloudRouter(params HttpMessageHandler[] fakes)
    {
        foreach (var f in fakes)
        {
            if (f is not IFakeCloud c) throw new ArgumentException(f.GetType().Name + " isn’t an IFakeCloud.");
            _fakes.Add((c, new HttpMessageInvoker(f, disposeHandler: false)));
        }
    }

    public IEnumerable<IFakeCloud> Fakes => _fakes.Select(f => f.Fake);

    public IReadOnlyList<CloudConnection> DemoAccounts() => _fakes.SelectMany(f => f.Fake.DemoAccounts()).ToList();

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        foreach (var (fake, invoker) in _fakes)
            if (request.RequestUri is { } u && fake.Handles(u)) return invoker.SendAsync(request, ct);
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.BadGateway)
        {
            RequestMessage = request,
            Content = new StringContent("No fake server answers " + request.RequestUri?.Host),
        });
    }
}
