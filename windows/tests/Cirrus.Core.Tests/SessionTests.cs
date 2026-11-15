using System.Net;
using System.Numerics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

namespace Cirrus.Core.Tests;

/// <summary>
/// End-to-end sign-in against a fake idmsa/setup/drivews server. The server side of SRP is written
/// independently here (verifier v = g^x, B = kv + g^b, S = (A·v^u)^b) so it checks the client's math.
/// </summary>
public class SessionTests
{
    const string AppleID = "someone@example.com";
    const string Password = "hunter2-correct-horse";
    const string SessionToken = "SESSION-TOKEN-1234567890abcdefGHIJKLMNOPQRSTUVWXYZ";
    const string CookieValue = "\"v=1:s=0:d=987654321\"";

    sealed class FakeApple : HttpMessageHandler
    {
        public readonly List<string> Calls = [];
        public readonly List<HttpRequestMessage> Requests = [];
        readonly byte[] _salt = RandomNumberGenerator.GetBytes(16);
        readonly BigInteger _b = new(RandomNumberGenerator.GetBytes(32), isUnsigned: true, isBigEndian: true);
        BigInteger _v, _B, _A;
        public bool ExpireOnce = true;
        public bool BusyOnce = true;
        public int ProtectedCalls;
        public string? LastCookie;

        static byte[] H(params byte[][] p) => AppleSRPClient.H(p);
        static BigInteger N => AppleSRPClient.N;
        static BigInteger Num(byte[] b) => new(b, isUnsigned: true, isBigEndian: true);
        static byte[] Pad(BigInteger v) => AppleSRPClient.Pad(v);

        static HttpResponseMessage Json(HttpStatusCode code, JsonNode? body = null)
        {
            var r = new HttpResponseMessage(code) { Content = new StringContent(body?.ToJsonString() ?? "{}", Encoding.UTF8, "application/json") };
            return r;
        }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage req, CancellationToken ct)
        {
            var path = req.RequestUri!.AbsolutePath;
            var body = req.Content is null ? "" : await req.Content.ReadAsStringAsync(ct);
            Calls.Add($"{req.Method} {req.RequestUri.Host}{path}");
            Requests.Add(req);
            Assert.Contains("Safari", req.Headers.UserAgent.ToString());
            var j = body.Length > 0 && body.TrimStart().StartsWith('{') ? JsonNode.Parse(body) : null;
            switch (path)
            {
                case "/appleauth/auth/authorize/signin":
                    Assert.Contains("client_id=" + ICloudSession.WidgetKey, req.RequestUri.Query);
                    return Json(HttpStatusCode.OK);
                case "/appleauth/auth/federate":
                {
                    Assert.Equal(AppleID, j!["accountName"]!.GetValue<string>());
                    var r = Json(HttpStatusCode.OK);
                    r.Headers.Add("scnt", "SCNT-1");
                    r.Headers.Add("X-Apple-ID-Session-Id", "SID-1");
                    return r;
                }
                case "/appleauth/auth/signin/init":
                {
                    Assert.Equal("SCNT-1", req.Headers.GetValues("scnt").Single());
                    Assert.Equal(ICloudSession.WidgetKey, req.Headers.GetValues("X-Apple-Widget-Key").Single());
                    _A = Num(Convert.FromBase64String(j!["a"]!.GetValue<string>()));
                    // Independent server: x from s2k (PBKDF2 over SHA-256 of the password), username not in x.
                    var key = Rfc2898DeriveBytes.Pbkdf2(SHA256.HashData(Encoding.UTF8.GetBytes(Password)), _salt, 1000, HashAlgorithmName.SHA256, 32);
                    var x = Num(H(_salt, H(Encoding.UTF8.GetBytes(":"), key)));
                    _v = BigInteger.ModPow(2, x, N);
                    var k = Num(H(AppleSRPClient.Serialize(N), Pad(2)));
                    _B = (k * _v + BigInteger.ModPow(2, _b, N)) % N;
                    return Json(HttpStatusCode.OK, new JsonObject
                    {
                        ["iteration"] = 1000, ["salt"] = Convert.ToBase64String(_salt), ["protocol"] = "s2k",
                        ["b"] = Convert.ToBase64String(Pad(_B)), ["c"] = "challenge-c",
                    });
                }
                case "/appleauth/auth/signin/complete":
                {
                    Assert.Equal("challenge-c", j!["c"]!.GetValue<string>());
                    var u = Num(H(Pad(_A), Pad(_B)));
                    var S = BigInteger.ModPow(_A * BigInteger.ModPow(_v, u, N) % N, _b, N);
                    var K = H(Pad(S));
                    var hn = H(AppleSRPClient.Serialize(N)); var hg = H(Pad(2));
                    var m1 = H(hn.Zip(hg, (p, q) => (byte)(p ^ q)).ToArray(), H(Encoding.UTF8.GetBytes(AppleID)), _salt, Pad(_A), Pad(_B), K);
                    var m2 = H(Pad(_A), m1, K);
                    if (j["m1"]!.GetValue<string>() != Convert.ToBase64String(m1)) return Json(HttpStatusCode.Unauthorized);
                    Assert.Equal(Convert.ToBase64String(m2), j["m2"]!.GetValue<string>());
                    return Json(HttpStatusCode.Conflict);   // two-factor required
                }
                case "/appleauth/auth":
                    return Json(HttpStatusCode.OK, new JsonObject
                    {
                        ["trustedPhoneNumbers"] = new JsonArray(new JsonObject { ["id"] = 1, ["numberWithDialCode"] = "+1 (•••) •••-••12", ["pushMode"] = "sms" }),
                        ["noTrustedDevices"] = false,
                    });
                case "/appleauth/auth/verify/trusteddevice/securitycode":
                    if (req.Method == HttpMethod.Put) { Assert.Equal(0, req.Content!.Headers.ContentLength); return new HttpResponseMessage(HttpStatusCode.Accepted); }
                    Assert.Equal("123456", j!["securityCode"]!["code"]!.GetValue<string>());
                    {
                        // Mid-2026 idmsa: 409 even for an accepted code, with a session token.
                        var r = Json(HttpStatusCode.Conflict);
                        r.Headers.Add("X-Apple-Session-Token", SessionToken);
                        return r;
                    }
                case "/appleauth/auth/2sv/trust":
                {
                    var r = new HttpResponseMessage(HttpStatusCode.NoContent);
                    r.Headers.Add("X-Apple-TwoSV-Trust-Token", "TRUST-TOKEN-xyz");
                    r.Headers.Add("X-Apple-Session-Token", SessionToken);
                    return r;
                }
                case "/setup/ws/1/accountLogin":
                {
                    Assert.Equal(SessionToken, j!["dsWebAuthToken"]!.GetValue<string>());
                    Assert.Equal("TRUST-TOKEN-xyz", j["trustToken"]!.GetValue<string>());
                    Assert.False(req.Headers.Contains("Cookie"));
                    var r = Json(HttpStatusCode.OK, new JsonObject
                    {
                        ["dsInfo"] = new JsonObject { ["dsid"] = "987654321", ["fullName"] = "Test Person", ["hsaVersion"] = 2 },
                        ["hsaChallengeRequired"] = false,
                        ["webservices"] = new JsonObject
                        {
                            ["drivews"] = new JsonObject { ["url"] = "https://p01-drivews.icloud.com:443", ["status"] = "active" },
                            ["docws"] = new JsonObject { ["url"] = "https://p01-docws.icloud.com:443", ["status"] = "active" },
                        },
                    });
                    r.Headers.Add("Set-Cookie", "X-APPLE-WEBAUTH-USER=" + CookieValue + "; Domain=.icloud.com; Path=/; Secure; HttpOnly");
                    r.Headers.Add("Set-Cookie", "X-APPLE-WEBAUTH-TOKEN=tok123; Domain=.icloud.com; Path=/; Expires=Wed, 01 Jan 2099 00:00:00 GMT");
                    r.Headers.Add("Set-Cookie", "X-APPLE-OLD=; Domain=.icloud.com; Expires=Thu, 01-Jan-1970 00:00:01 GMT");
                    return r;
                }
                case "/retrieveItemDetailsInFolders":
                {
                    ProtectedCalls++;
                    LastCookie = req.Headers.TryGetValues("Cookie", out var c) ? c.Single() : null;
                    if (ExpireOnce) { ExpireOnce = false; return Json(HttpStatusCode.Unauthorized); }   // session expired → silent re-auth
                    if (BusyOnce) { BusyOnce = false; var busy = Json(HttpStatusCode.ServiceUnavailable); busy.Headers.Add("Retry-After", "0"); return busy; }
                    return Json(HttpStatusCode.OK, new JsonArray(new JsonObject
                    {
                        ["drivewsid"] = "FOLDER::com.apple.CloudDocs::root", ["status"] = "OK",
                        ["items"] = new JsonArray(
                            new JsonObject { ["drivewsid"] = "FILE::com.apple.CloudDocs::DOC1", ["docwsid"] = "DOC1", ["name"] = "Café notes", ["extension"] = "txt",
                                ["type"] = "FILE", ["size"] = 42, ["dateModified"] = "2026-03-01T10:00:00Z", ["etag"] = "e1" },
                            new JsonObject { ["drivewsid"] = "FOLDER::com.apple.CloudDocs::F1", ["name"] = "Folder", ["type"] = "FOLDER", ["directChildrenCount"] = 3 }),
                    }));
                }
                case "/redirect-me":
                {
                    var r = new HttpResponseMessage((HttpStatusCode)330);
                    r.Headers.Location = new Uri("https://cvws.icloud-content.com/final");
                    return r;
                }
                case "/final":
                    return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(Encoding.UTF8.GetBytes("file body")) };
                default:
                    return Json(HttpStatusCode.NotFound);
            }
        }
    }

    [Fact]
    public async Task SignInTwoFactorTrustAccountLoginReauthAndBackoff()
    {
        using var log = new LogCapture();
        var fake = new FakeApple();
        SessionState? persisted = null;
        var session = new ICloudSession(new SessionState(AppleID.ToUpperInvariant()), fake) { Persister = s => persisted = s };
        session.Delay = (_, _) => Task.CompletedTask;

        var outcome = await session.SignInAsync(Password);
        var needs = Assert.IsType<SignInOutcome.NeedsCode>(outcome);
        Assert.True(needs.DeviceAvailable);
        Assert.Single(needs.Phones);
        Assert.Contains("PUT idmsa.apple.com/appleauth/auth/verify/trusteddevice/securitycode", fake.Calls);

        await session.SubmitCodeAsync("123456");   // 409 + session token = accepted
        Assert.True(session.HasSession);
        Assert.Equal("987654321", session.Dsid);
        Assert.Equal("Test Person", session.FullName);
        Assert.NotNull(persisted);
        Assert.Equal("TRUST-TOKEN-xyz", persisted!.TrustToken);
        Assert.Equal(2, persisted.Cookies.Count);                 // expired cookie dropped
        Assert.Contains(persisted.Cookies, c => c.Name == "X-APPLE-WEBAUTH-USER" && c.Value == CookieValue);

        // Drive listing: 401 → silent accountLogin with the stored token → 503 → back-off → OK.
        var drive = new WebDrive(session);
        var items = await drive.ListAsync(drive.RootID);
        Assert.Equal(3, fake.ProtectedCalls);
        Assert.Equal(2, fake.Calls.Count(c => c.EndsWith("/accountLogin")));
        Assert.Contains("X-APPLE-WEBAUTH-USER=" + CookieValue, fake.LastCookie);
        Assert.Contains("X-APPLE-WEBAUTH-TOKEN=tok123", fake.LastCookie);
        Assert.DoesNotContain("X-APPLE-OLD", fake.LastCookie);
        var file = Assert.Single(items, n => !n.IsFolder);
        Assert.Equal("Café notes.txt", file.Name);             // NFC + extension
        Assert.Equal(42, file.Size);
        Assert.Equal(new DateTimeOffset(2026, 3, 1, 10, 0, 0, TimeSpan.Zero), file.Modified);
        Assert.Equal(3, items.Single(n => n.IsFolder).ChildCount);

        // Downloads follow Apple's 330 by hand (the handler never auto-redirects).
        var dest = Path.Combine(TestEnv.TempDir("dl"), "out.txt");
        long last = 0;
        await session.DownloadAsync("https://p01-docws.icloud.com/redirect-me", dest, 9, (d, _) => last = d);
        Assert.Equal("file body", File.ReadAllText(dest));
        Assert.Equal(9, last);

        // Nothing secret reached the log.
        var text = log.Text;
        Assert.DoesNotContain(Password, text);
        Assert.DoesNotContain(AppleID, text, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(SessionToken, text);
        Assert.DoesNotContain("tok123", text);
        Assert.DoesNotContain("987654321", text);
        Assert.Contains("→ 401", text);   // status lines are kept for diagnosis
    }

    [Fact]
    public async Task WrongPasswordIsReportedAsBadCredentials()
    {
        var fake = new FakeApple();
        var session = new ICloudSession(new SessionState(AppleID), fake);
        var e = await Assert.ThrowsAsync<ICloudException>(() => session.SignInAsync("wrong password"));
        Assert.Equal(ICloudErrorKind.BadCredentials, e.Kind);
        Assert.Equal("Incorrect Apple ID or password.", e.Message);
    }

    [Fact]
    public async Task ExpiredSessionWithoutSavedPasswordAsksForSignIn()
    {
        var fake = new FakeApple { ExpireOnce = true };
        var state = new SessionState(AppleID)
        {
            AccountInfoData = Encoding.UTF8.GetBytes("{\"webservices\":{\"drivews\":{\"url\":\"https://p01-drivews.icloud.com\"}}}"),
            Cookies = [new StoredCookie { Name = "X-APPLE-WEBAUTH-USER", Value = "x" }],
        };
        var session = new ICloudSession(state, fake);
        var events = new List<SessionEvent>();
        session.Event += (e, _) => events.Add(e);
        var e = await Assert.ThrowsAsync<ICloudException>(() => new WebDrive(session).ListAsync("FOLDER::com.apple.CloudDocs::root"));
        Assert.Equal(ICloudErrorKind.NeedsSignIn, e.Kind);
        Assert.Contains(SessionEvent.NeedsSignIn, events);
    }

    [Fact]
    public void CookieParsingHandlesAppleFormats()
    {
        var c = ICloudSession.ParseSetCookie("X-APPLE-WEBAUTH-HSA-TRUST=\"abc=def\"; Expires=Tue, 15-Dec-2026 10:00:00 GMT; Path=/; Domain=.icloud.com; Secure", new Uri("https://setup.icloud.com/"))!;
        Assert.Equal("X-APPLE-WEBAUTH-HSA-TRUST", c.Name);
        Assert.Equal("\"abc=def\"", c.Value);
        Assert.Equal("icloud.com", c.Domain);
        Assert.Equal(new DateTimeOffset(2026, 12, 15, 10, 0, 0, TimeSpan.Zero), c.Expires);
        var m = ICloudSession.ParseSetCookie("a=b; Max-Age=60", null)!;
        Assert.True(m.Expires > DateTimeOffset.UtcNow);
        Assert.Null(ICloudSession.ParseSetCookie("garbage", null));
    }

    [Fact]
    public void SessionStateRoundTripsWithoutLosingTokens()
    {
        var s = new SessionState("Me@Example.com") { TrustToken = "t", SessionToken = "s", Cookies = [new StoredCookie { Name = "n", Value = "v" }], AccountInfoData = [1, 2, 3] };
        var back = SessionState.Deserialize(s.Serialize())!;
        Assert.Equal("me@example.com", back.AppleID);
        Assert.Equal("t", back.TrustToken);
        Assert.Equal([1, 2, 3], back.AccountInfoData);
        Assert.Equal(ICloudSession.WidgetKey, back.ClientID);
        Assert.Equal(s.FrameID, back.FrameID);
    }
}
