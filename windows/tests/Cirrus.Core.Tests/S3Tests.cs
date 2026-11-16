using System.Text;
using Cirrus.Fakes;

namespace Cirrus.Core.Tests;

/// <summary>The S3 connector (port of S3Tests.swift): SigV4 against AWS's published vectors, then everything against FakeS3Server.</summary>
[Collection(CloudGlobals.Name)]
public class S3Tests
{
    const string Key = FakeS3Server.AccessKey;
    const string Secret = FakeS3Server.SecretKey;

    // MARK: Helpers

    static string TempDir(string name) => TestEnv.TempDir("s3-" + name);

    static string SrcFile(byte[] data, string name = "upload.bin")
    {
        var p = Path.Combine(TempDir("src"), name);
        File.WriteAllBytes(p, data);
        return p;
    }

    static byte[] U(string s) => Encoding.UTF8.GetBytes(s);
    static byte[] Bytes(int n, int seed = 7) => Enumerable.Range(0, n).Select(i => unchecked((byte)(i * seed + (i >> 8)))).ToArray();
    static List<string> Sorted(IEnumerable<string> s) => s.Order(StringComparer.Ordinal).ToList();
    static string Opts(CloudAccountRecord r) => string.Join(",", (r.Options ?? []).OrderBy(kv => kv.Key, StringComparer.Ordinal).Select(kv => kv.Key + "=" + kv.Value));
    static string Nfc(string s) => s.Normalize(NormalizationForm.FormC);

    /// <summary>A bucket "cirrus-test": Documents/ (with a marker), Photos/ (no marker, only keys), Readme.txt, and a nested folder.</summary>
    static FakeS3Server.State TestState(int pageSize = 2)
    {
        var s = new FakeS3Server.State { PageSize = pageSize, MinPartSize = 64 * 1024 };
        const string b = "cirrus-test";
        s.AddBucket(b);
        s.Put(b, "Readme.txt", U("hello\n"));
        s.Put(b, "Documents/");
        s.Put(b, "Documents/a.txt", U("a"));
        s.Put(b, "Documents/b.txt", U("bb"));
        s.Put(b, "Documents/c.csv", U("c,c\n"));
        s.Put(b, "Documents/Sub/deep.txt", U("deep"));
        s.Put(b, "Photos/one.jpg", new byte[300]);
        s.Put(b, "Photos/two.jpg", new byte[400]);
        s.AddBucket("other-bucket");
        s.Put("other-bucket", "note.txt", U("other"));
        s.AddBucket("ireland", region: "eu-west-1");
        s.Put("ireland", "dublin.txt", U("eu"));
        return s;
    }

    static CloudAccountRecord Record(string endpoint = "https://s3.us-east-1.amazonaws.com", string? bucket = "cirrus-test", string region = "us-east-1",
        string? pathStyle = null, string key = Key)
    {
        var o = new Dictionary<string, string> { ["region"] = region };
        if (bucket is not null) o["bucket"] = bucket;
        if (pathStyle is not null) o["pathStyle"] = pathStyle;
        return new CloudAccountRecord(CloudProvider.S3, $"{bucket ?? key} @ test", endpoint, key, o, "cloud:s3:test");
    }

    static (FakeS3Server Fake, S3Backend D) Backend(FakeS3Server.State? s = null, CloudAccountRecord? r = null, string secret = Secret)
    {
        var fake = new FakeS3Server(s ?? TestState());
        var d = new S3Backend(r ?? Record(), secret, fake) { RetryBase = 0.001, Concurrency = 3 };
        return (fake, d);
    }

    static async Task<Exception?> Caught(Func<Task> op)
    {
        try { await op(); return null; } catch (Exception e) { return e; }
    }

    static string? DeniedMessage(Exception? e) => e is CloudException { Kind: CloudErrorKind.Denied } c ? c.Detail : null;
    static bool IsNotFound(Exception? e) => e is CloudException { Kind: CloudErrorKind.NotFound };

    static async Task<DriveNode> Node(S3Backend d, string folder, string name) =>
        (await d.ListAsync(folder)).FirstOrDefault(n => n.Name == Nfc(name)) ?? throw new Xunit.Sdk.XunitException($"{name} in {folder}");

    static async Task WaitFor(Func<bool> cond)
    {
        for (int i = 0; i < 300 && !cond(); i++) await Task.Delay(10);
    }

    sealed class ProgressBox
    {
        readonly object _l = new();
        (long, long) _last;
        public void Note(long a, long b) { lock (_l) _last = (a, b); }
        public (long Done, long Total) Last { get { lock (_l) return _last; } }
    }

    static async Task<string> Download(S3Backend d, DriveNode n, string name = "f", Action<long, long>? progress = null)
    {
        var dest = Path.Combine(TempDir("dl"), name);
        await d.DownloadAsync(n, dest, progress);
        return dest;
    }

    // MARK: SigV4 (AWS's published vectors)

    /// <summary>
    /// From AWS's SigV4 test suite (aws-sig-v4-test-suite / aws-c-auth): AKIDEXAMPLE, us-east-1, service "service",
    /// 2015-08-30T12:36:00Z, the empty body's hash.
    /// </summary>
    [Fact]
    public void SigV4TestSuiteVectors()
    {
        const string secret = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY";
        const string date = "20150830T123600Z";
        static S3Signer.Signed Sig(string method, string path, (string, string?)[]? query = null, (string, string)[]? extra = null) =>
            S3Signer.Sign(method, S3Signer.Encode(path, slash: false), S3Signer.CanonicalQuery(query ?? []),
                new[] { ("Host", "example.amazonaws.com"), ("X-Amz-Date", date) }.Concat(extra ?? []), S3Signer.EmptyHash,
                date, "us-east-1", "service", "AKIDEXAMPLE", secret);
        var vanilla = Sig("GET", "/");
        Assert.Equal("5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31", vanilla.Signature);
        Assert.Equal("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, "
            + "SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31", vanilla.Authorization);
        Assert.Equal("GET\n/\n\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\n" + S3Signer.EmptyHash, vanilla.CanonicalRequest);
        Assert.Equal("AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\n"
            + "bb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63", vanilla.StringToSign);
        // get-vanilla-query-order-key-case: parameters sorted by name.
        Assert.Equal("b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500", Sig("GET", "/", [("Param2", "value2"), ("Param1", "value1")]).Signature);
        Assert.Equal("5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b", Sig("POST", "/").Signature);
        // get-utf8: the path's UTF-8 bytes percent-encoded once.
        var utf8 = Sig("GET", "/ሴ");
        Assert.Equal("/%E1%88%B4", utf8.CanonicalRequest.Split('\n')[1]);
        Assert.Equal("8318018e0b0f223aa2bbf98705b62bb787dc9c0e678f255a891fd03141be5d85", utf8.Signature);
        Assert.Equal("07ef7494c76fa4850883e2b006601f940f8a34d404d0cfa977f52a65bbf5f24f",
            Sig("GET", "/-._~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz").Signature);
        Assert.Equal("2cdec8eed098649ff3a119c94853b13c643bcf08f8b0a1d91e12c9027818dd04", Sig("GET", "/", [("ሴ", "bar")]).Signature);
        // get-header-value-trim: values trimmed, inner runs of spaces collapsed (even inside quotes).
        var trim = Sig("GET", "/", extra: [("My-Header1", " value1"), ("My-Header2", " \"a   b   c\"")]);
        Assert.Equal("GET\n/\n\nhost:example.amazonaws.com\nmy-header1:value1\nmy-header2:\"a b c\"\nx-amz-date:20150830T123600Z\n\n"
            + "host;my-header1;my-header2;x-amz-date\n" + S3Signer.EmptyHash, trim.CanonicalRequest);
        Assert.Equal("acc3ed3afb60bb290fc8d2dd0098b9911fcaa05412b367055dee359757a9c736", trim.Signature);
        // The signing-key example from AWS's documentation (IAM, 2012-02-15).
        Assert.Equal("f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d", S3Signer.Hex(S3Signer.SigningKey(secret, "20120215", "us-east-1", "iam")));
    }

    /// <summary>
    /// The four worked examples in S3's "Signature Calculations for the Authorization Header (single chunk)":
    /// AKIAIOSFODNN7EXAMPLE, us-east-1, 2013-05-24, bucket "examplebucket" (virtual-hosted).
    /// </summary>
    [Fact]
    public void SigV4S3DocumentationExamples()
    {
        const string secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
        const string date = "20130524T000000Z";
        static S3Signer.Signed Sig(string method, string key, (string, string?)[]? query = null, (string, string)[]? extra = null, string hash = S3Signer.EmptyHash) =>
            S3Signer.Sign(method, "/" + S3Signer.Encode(key, slash: false), S3Signer.CanonicalQuery(query ?? []),
                new[] { ("Host", "examplebucket.s3.amazonaws.com"), ("x-amz-date", date), ("x-amz-content-sha256", hash) }.Concat(extra ?? []),
                hash, date, "us-east-1", "s3", "AKIAIOSFODNN7EXAMPLE", secret);
        // GET Object with a Range header.
        var get = Sig("GET", "test.txt", extra: [("Range", "bytes=0-9")]);
        Assert.Equal("7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972", S3Signer.Sha256Hex(U(get.CanonicalRequest)));
        Assert.Equal("f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41", get.Signature);
        // PUT Object: "$" in the key, a Date header, a storage class, and the body's hash.
        var hash = S3Signer.Sha256Hex(U("Welcome to Amazon S3."));
        Assert.Equal("44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072", hash);
        var put = Sig("PUT", "test$file.text", extra: [("Date", "Fri, 24 May 2013 00:00:00 GMT"), ("x-amz-storage-class", "REDUCED_REDUNDANCY")], hash: hash);
        Assert.StartsWith("PUT\n/test%24file.text\n\n", put.CanonicalRequest);
        Assert.Equal("date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class", put.SignedHeaders);
        Assert.Equal("98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd", put.Signature);
        // GET Bucket lifecycle: a sub-resource without a value is "lifecycle=".
        var lifecycle = Sig("GET", "", [("lifecycle", null)]);
        Assert.StartsWith("GET\n/\nlifecycle=\n", lifecycle.CanonicalRequest);
        Assert.Equal("fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543", lifecycle.Signature);
        // GET Bucket (list objects).
        Assert.Equal("34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7", Sig("GET", "", [("prefix", "J"), ("max-keys", "2")]).Signature);
    }

    [Fact]
    public void UriEncodingAndQueryRules()
    {
        Assert.Equal("a%20b/c%2Bd%25~%C3%A9", S3Signer.Encode("a b/c+d%~é", slash: false));
        Assert.Equal("a%2Fb", S3Signer.Encode("a/b", slash: true));
        Assert.Equal("%23%3F%26%3D%3B%3A%40%21%24%27%28%29%2A%2C", S3Signer.Encode("#?&=;:@!$'()*,", slash: false));
        Assert.Equal("uploads=", S3Signer.CanonicalQuery([("uploads", null)]));
        Assert.Equal("b=1&b=2&list-type=2&prefix=a%20b%2F", S3Signer.CanonicalQuery([("prefix", "a b/"), ("list-type", "2"), ("b", "2"), ("b", "1")]));
        Assert.Equal("a b+c+d", S3Signer.Decode("a%20b%2Bc+d"));
        Assert.Null(S3Signer.Decode("%FF%FE"));
        Assert.Equal(["uploads=nil", "x=a/b", "y="], S3Signer.QueryItems("uploads&x=a%2Fb&y=").Select(q => $"{q.Name}={q.Value ?? "nil"}"));
        Assert.Equal("20150830T123600Z", S3Signer.AmzDate(DateTimeOffset.FromUnixTimeSeconds(1_440_938_160)));
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1_440_938_160), S3Signer.ParseAmzDate("20150830T123600Z"));
        Assert.Null(S3Signer.ParseAmzDate("2015-08-30T12:36"));
        var p = S3Signer.Parse("AWS4-HMAC-SHA256 Credential=AK/20150830/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-date, Signature=abc");
        Assert.NotNull(p);
        Assert.Equal(("AK", "us-east-1", "abc"), (p.AccessKey, p.Region, p.Signature));
        Assert.Equal(["host", "x-amz-date"], p.SignedHeaders);
        // Keys are compared exactly: a decomposed "é" isn't a precomposed one, and "/" + combining mark still splits.
        Assert.False(S3Key.Same("Café", "Café"));
        Assert.True(S3Key.HasPrefix("Café/x", "Cafe"));
        Assert.Equal("́b", S3Key.LastSegment("a/́b/"));
        Assert.Equal("a/", S3Key.Parent("a/́b/"));
        Assert.Equal("a/b/", S3Key.ChildPrefix("a/b/c", "a/"));
        Assert.Null(S3Key.ChildPrefix("a/b", "a/"));
        // S3 orders keys by UTF-8 bytes (an emoji sorts after U+FFFD; UTF-16 ordinal order says the opposite).
        Assert.True(S3Key.Less("�", "\U0001F389"));
        Assert.True(string.CompareOrdinal("�", "\U0001F389") > 0);
    }

    [Fact]
    public void EndpointsAndRegions()
    {
        var b2 = S3Endpoint.Parse("s3.us-west-004.backblazeb2.com");
        Assert.Equal(("https://s3.us-west-004.backblazeb2.com", ""), (b2.Endpoint.Address, b2.Path));
        Assert.Equal("https://s3.example.com", S3Endpoint.Parse("HTTPS://S3.Example.com:443/").Endpoint.Address);
        Assert.Equal("http://localhost:9000", S3Endpoint.Parse("http://localhost:9000").Endpoint.Address);
        Assert.Equal("/r2 bucket", S3Endpoint.Parse("https://abc.r2.cloudflarestorage.com/r2%20bucket/").Path);
        Assert.Throws<CloudException>(() => S3Endpoint.Parse("http://minio.example.com:9000"));
        Assert.Throws<CloudException>(() => S3Endpoint.Parse("ftp://x.example.com"));
        Assert.Throws<CloudException>(() => S3Endpoint.Parse("  "));
        (string, string?)[] regions =
        [
            ("s3.amazonaws.com", "us-east-1"), ("s3.us-west-2.amazonaws.com", "us-west-2"), ("s3-eu-west-1.amazonaws.com", "eu-west-1"),
            ("s3.dualstack.ap-south-1.amazonaws.com", "ap-south-1"), ("photos.s3.eu-central-1.amazonaws.com", "eu-central-1"),
            ("s3-external-1.amazonaws.com", "us-east-1"), ("s3.us-west-004.backblazeb2.com", "us-west-004"),
            ("s3.eu-central-1.wasabisys.com", "eu-central-1"), ("s3.wasabisys.com", "us-east-1"), ("s3.fr-par.scw.cloud", "fr-par"),
            ("abc123.r2.cloudflarestorage.com", "auto"), ("abc123.eu.r2.cloudflarestorage.com", "auto"), ("minio.local", null),
        ];
        foreach (var (host, want) in regions) Assert.True(S3Endpoint.InferredRegion(host) == want, host);
        Assert.Equal("auto", S3Endpoint.SigningRegion("auto", "abc.r2.cloudflarestorage.com"));
        Assert.Equal("us-east-1", S3Endpoint.SigningRegion("auto", "127.0.0.1"));
        Assert.Equal("eu-west-1", S3Endpoint.SigningRegion("", "s3.eu-west-1.amazonaws.com"));
        Assert.Equal("eu-west-3", S3Endpoint.SigningRegion(" EU-West-3 ", "s3.amazonaws.com"));
        Assert.Equal(("photos", "s3.us-west-2.amazonaws.com"), S3Endpoint.SplitBucketHost("photos.s3.us-west-2.amazonaws.com"));
        Assert.Equal(("my.dotted.bucket", "s3.amazonaws.com"), S3Endpoint.SplitBucketHost("my.dotted.bucket.s3.amazonaws.com"));
        Assert.Null(S3Endpoint.SplitBucketHost("s3.us-west-2.amazonaws.com"));
        Assert.Null(S3Endpoint.SplitBucketHost("bucket.minio.local"));
        Assert.True(S3Endpoint.VirtualHostable("photos-2026"));
        Assert.False(S3Endpoint.VirtualHostable("my.bucket"));
        Assert.False(S3Endpoint.VirtualHostable("Upper"));
    }

    // MARK: Connect

    [Fact]
    public async Task ConnectAWSStyleUsesVirtualHostedAddresses()
    {
        var fake = new FakeS3Server(TestState());
        var c = await S3Cloud.ConnectAsync("https://s3.us-east-1.amazonaws.com", "us-east-1", "cirrus-test", $" {Key} ", Secret, fake);
        Assert.Equal(CloudProvider.S3, c.Record.Provider);
        Assert.Equal("cirrus-test @ s3.us-east-1.amazonaws.com", c.Record.Title);
        Assert.Equal("https://s3.us-east-1.amazonaws.com", c.Record.Server);
        Assert.Equal(Key, c.Record.Username);
        Assert.Equal("bucket=cirrus-test,pathStyle=0,region=us-east-1", Opts(c.Record));
        Assert.Equal(new CloudSecret { Password = Secret }, c.Secret);
        Assert.StartsWith("cloud:s3:", c.Record.Id);
        Assert.Equal("cirrus-test.s3.us-east-1.amazonaws.com", fake.S.Hosts[^1]);
        Assert.StartsWith("GET cirrus-test ?", fake.S.Calls[^1]);
        var d = Assert.IsType<S3Backend>(S3Cloud.Make(c.Record, c.Secret, fake));
        Assert.Equal("s3:/cirrus-test/", d.RootID);
        Assert.Contains(await d.ListAsync(d.RootID), n => n.Name == "Readme.txt");
        Assert.Equal("cirrus-test.s3.us-east-1.amazonaws.com", fake.S.Hosts[^1]);
        // The bucket written into the address, and no bucket at all (ListBuckets).
        var fromHost = await S3Cloud.ConnectAsync("cirrus-test.s3.us-east-1.amazonaws.com", "", null, Key, Secret, fake);
        Assert.Equal("cirrus-test", fromHost.Record.Option("bucket"));
        Assert.Equal("https://s3.us-east-1.amazonaws.com", fromHost.Record.Server);
        Assert.Equal("us-east-1", fromHost.Record.Option("region"));
        var all = await S3Cloud.ConnectAsync("s3.us-east-1.amazonaws.com", "", "  ", Key, Secret, fake);
        Assert.Equal("region=us-east-1", Opts(all.Record));
        Assert.Equal($"{Key} @ s3.us-east-1.amazonaws.com", all.Record.Title);
        Assert.Equal("GET - ", fake.S.Calls[^1]);
        Assert.Equal("s3:/", S3Cloud.Make(all.Record, all.Secret, fake).RootID);
        // A bucket in another region: found (learned from the x-amz-bucket-region answer), and saved with its region.
        var ireland = await S3Cloud.ConnectAsync("https://s3.us-east-1.amazonaws.com", "us-east-1", "ireland", Key, Secret, fake);
        Assert.Equal("eu-west-1", ireland.Record.Option("region"));
        Assert.Equal("ireland.s3.eu-west-1.amazonaws.com", fake.S.Hosts[^1]);
        Assert.Equal(1, fake.S.RegionRejections);
        var id = S3Cloud.Make(ireland.Record, ireland.Secret, fake);
        Assert.Equal(["dublin.txt"], (await id.ListAsync(id.RootID)).Select(n => n.Name));
        Assert.Equal(1, fake.S.RegionRejections);   // the saved region is right from the start
        Assert.Equal(0, fake.S.SignatureFailures);
    }

    [Fact]
    public async Task ConnectB2R2WasabiAndMinIOStyleEndpoints()
    {
        var s = TestState();
        foreach (var b in new[] { "b2-bucket", "r2-bucket", "wasabi-bucket", "minio-bucket" }) s.Put(b, "hello.txt", U(b));
        var fake = new FakeS3Server(s);
        // Backblaze B2: no scheme typed, region from the host, path-style.
        var b2 = await S3Cloud.ConnectAsync("s3.us-west-004.backblazeb2.com", "", "b2-bucket", Key, Secret, fake);
        Assert.Equal("https://s3.us-west-004.backblazeb2.com", b2.Record.Server);
        Assert.Equal("bucket=b2-bucket,pathStyle=1,region=us-west-004", Opts(b2.Record));
        Assert.Equal("b2-bucket @ s3.us-west-004.backblazeb2.com", b2.Record.Title);
        Assert.Equal("s3.us-west-004.backblazeb2.com", fake.S.Hosts[^1]);
        // Cloudflare R2: the address its dashboard shows (bucket in the path), region "auto".
        var r2 = await S3Cloud.ConnectAsync("https://fakeaccount0123.r2.cloudflarestorage.com/r2-bucket", "auto", null, Key, Secret, fake);
        Assert.Equal("https://fakeaccount0123.r2.cloudflarestorage.com", r2.Record.Server);
        Assert.Equal("bucket=r2-bucket,pathStyle=1,region=auto", Opts(r2.Record));
        // Wasabi and a MinIO on this PC (plain http is fine for localhost).
        var wasabi = await S3Cloud.ConnectAsync("https://s3.eu-central-1.wasabisys.com", "eu-central-1", "wasabi-bucket", Key, Secret, fake);
        Assert.Equal("1", wasabi.Record.Option("pathStyle"));
        var minio = await S3Cloud.ConnectAsync("http://127.0.0.1:9000/", "", "minio-bucket", Key, Secret, fake);
        Assert.Equal("http://127.0.0.1:9000", minio.Record.Server);
        Assert.Equal("minio-bucket @ 127.0.0.1:9000", minio.Record.Title);
        Assert.Equal("us-east-1", minio.Record.Option("region"));
        foreach (var (conn, name) in new[] { (b2, "b2-bucket"), (r2, "r2-bucket"), (wasabi, "wasabi-bucket"), (minio, "minio-bucket") })
        {
            var d = S3Cloud.Make(conn.Record, conn.Secret, fake);
            var hello = (await d.ListAsync(d.RootID)).Single(n => n.Name == "hello.txt");
            var dest = Path.Combine(TempDir("conn"), "h");
            await d.DownloadAsync(hello, dest, null);
            Assert.Equal(U(name), File.ReadAllBytes(dest));
        }
        Assert.Equal((0, 0), (fake.S.SignatureFailures, fake.S.RegionRejections));
        Assert.Contains("127.0.0.1:9000", fake.S.Hosts);
    }

    [Fact]
    public async Task ConnectGivesClearErrors()
    {
        var s = TestState();
        s.Credentials["SCOPEDKEY"] = new FakeS3Server.Credential("scoped-secret", CanListBuckets: false, Buckets: ["cirrus-test"]);
        var fake = new FakeS3Server(s);
        Task<Exception?> Connect(string? bucket, string key = Key, string secret = Secret, string endpoint = "https://s3.us-east-1.amazonaws.com") =>
            Caught(() => S3Cloud.ConnectAsync(endpoint, "us-east-1", bucket, key, secret, fake));
        var badSecret = await Connect("cirrus-test", secret: "wrong");
        Assert.Contains("secret access key doesn’t match", DeniedMessage(badSecret) ?? badSecret?.Message);
        var badKey = await Connect("cirrus-test", key: "AKIANOTKNOWN");
        Assert.Contains("doesn’t know the access key ID “AKIANOTKNOWN”", DeniedMessage(badKey) ?? badKey?.Message);
        var noBucket = await Connect("no-such-bucket");
        Assert.Equal(CloudErrorKind.NotConfigured, Assert.IsType<CloudException>(noBucket).Kind);
        Assert.Contains("no bucket named “no-such-bucket”", noBucket!.Message);
        var cantList = await Connect(null, key: "SCOPEDKEY", secret: "scoped-secret");
        Assert.Contains("Enter the name of the bucket", DeniedMessage(cantList) ?? cantList?.Message);
        Assert.Null(await Connect("cirrus-test", key: "SCOPEDKEY", secret: "scoped-secret"));
        var notAllowed = await Connect("other-bucket", key: "SCOPEDKEY", secret: "scoped-secret");
        Assert.Contains("aren’t allowed to list the bucket “other-bucket”", DeniedMessage(notAllowed) ?? notAllowed?.Message);
        var noKey = await Connect("cirrus-test", key: " ");
        Assert.Equal("Enter the access key ID (on B2 it’s the application key’s keyID).", Assert.IsType<CloudException>(noKey).Message);
        Assert.IsType<CloudException>(await Connect("cirrus-test", secret: ""));
        Assert.IsType<CloudException>(await Connect("a/b"));
        Assert.IsType<CloudException>(await Connect(null, endpoint: "https://s3.us-east-1.amazonaws.com/one/two"));
        // Unknown hosts fail without leaving the fake; plain http elsewhere is refused before any request.
        Assert.IsType<CloudException>(await Connect("cirrus-test", endpoint: "https://s3.nowhere.invalid"));
        fake.Update(st => st.Calls.Clear());
        var http = await Connect("cirrus-test", endpoint: "http://s3.us-east-1.amazonaws.com");
        Assert.Equal(CloudErrorKind.Unsupported, Assert.IsType<CloudException>(http).Kind);
        Assert.Contains("https://", http!.Message);
        Assert.Empty(fake.S.Calls);
        Assert.Equal(1, fake.S.SignatureFailures);
    }

    // MARK: Listing

    [Fact]
    public async Task ListingShowsPrefixesMarkersAndPages()
    {
        var (fake, d) = Backend();
        var top = await d.ListAsync(d.RootID);
        Assert.Equal(["Documents", "Photos", "Readme.txt"], Sorted(top.Select(n => n.Name)));
        foreach (var n in top)
        {
            Assert.Equal(d.RootID, n.ParentID);
            Assert.Equal("s3", n.Zone);
            Assert.Equal(n.Id.EndsWith('/'), n.IsFolder);
            Assert.Equal(n.IsFolder ? "FOLDER" : "FILE", n.Type);
        }
        var readme = top.Single(n => n.Name == "Readme.txt");
        var server = fake.S.Object("cirrus-test", "Readme.txt")!;
        Assert.Equal("s3:/cirrus-test/Readme.txt", readme.Id);
        Assert.Equal(6, readme.Size);
        Assert.Equal(server.Etag, readme.Etag);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(server.Modified.ToUnixTimeSeconds()), readme.Modified);
        // Documents has a marker (hidden as a file), Photos only keys; pages of two entries.
        var docs = await d.ListAsync("s3:/cirrus-test/Documents/");
        Assert.Equal(["Sub", "a.txt", "b.txt", "c.csv"], Sorted(docs.Select(n => n.Name)));
        Assert.All(docs, n => Assert.Equal("s3:/cirrus-test/Documents/", n.ParentID));
        Assert.Equal("s3:/cirrus-test/Documents/Sub/", docs.Single(n => n.Name == "Sub").Id);
        Assert.Equal(["one.jpg", "two.jpg"], Sorted((await d.ListAsync("s3:/cirrus-test/Photos/")).Select(n => n.Name)));
        Assert.True(fake.S.ListRequests >= 4);
        var many = await d.ListManyAsync(["s3:/cirrus-test/Documents/", "s3:/cirrus-test/Photos/", "s3:/cirrus-test/Documents/"]);
        Assert.Equal(["s3:/cirrus-test/Documents/", "s3:/cirrus-test/Photos/"], Sorted(many.Keys));
        var walked = await d.WalkAsync(d.RootID);
        Assert.Equal(["Documents", "Documents/Sub", "Documents/Sub/deep.txt", "Documents/a.txt", "Documents/b.txt", "Documents/c.csv",
            "Photos", "Photos/one.jpg", "Photos/two.jpg", "Readme.txt"], Sorted(walked.Select(w => w.Path)));
        // A folder with only its marker is empty; a folder with nothing at all is gone.
        fake.Update(st => st.Put("cirrus-test", "Empty/"));
        Assert.Empty(await d.ListAsync("s3:/cirrus-test/Empty/"));
        Assert.True(IsNotFound(await Caught(() => d.ListAsync("s3:/cirrus-test/Nothing/"))));
        // The deleted-items folder never shows in the bucket.
        fake.Update(st => st.Put("cirrus-test", ".cirrus-deleted/x.txt", U("x")));
        Assert.DoesNotContain(await d.ListAsync(d.RootID), n => n.Name == ".cirrus-deleted");
        // IDs of another bucket aren't this account's.
        Assert.True(IsNotFound(await Caught(() => d.ListAsync("s3:/other-bucket/"))));
    }

    static readonly string[] OddNames =
    [
        "a b.txt", "hash #1.txt", "100% done.txt", "what?.txt", "c++ & more.txt", "Café ünicode.txt", "Café nfc.txt",
        "日本語のファイル.txt", "semi;colon=eq,comma.txt", "it's (1) [x] {y}.txt", "  leading spaces.txt", "plus+sign+.txt",
        "trailing dot.", "emoji \U0001F389.txt", "tab\there.txt", "back\\slash.txt", "<angle> \"quotes\".txt",
    ];

    [Fact]
    public async Task OddKeysSurviveEveryStep()
    {
        foreach (var (endpoint, ps) in new (string, string?)[] { ("https://s3.us-east-1.amazonaws.com", null), ("https://s3.us-east-1.amazonaws.com", "1"), ("http://127.0.0.1:9000", null) })
        {
            var s = TestState(pageSize: 3);
            const string folder = "Odd #2 & Ünïcode%20 +folder?";
            foreach (var n in OddNames) s.Put("cirrus-test", folder + "/" + n, U(n));
            var (fake, d) = Backend(s, Record(endpoint, pathStyle: ps));
            var odd = await Node(d, d.RootID, folder);
            var items = await d.ListAsync(odd.Id);
            Assert.Equal(Sorted(OddNames.Select(Nfc)), Sorted(items.Select(n => n.Name)));
            Assert.Equal(OddNames.Length, items.Count);
            foreach (var item in items)
            {
                Assert.Equal(odd.Id, item.ParentID);
                var dest = await Download(d, item);
                Assert.Equal(S3Key.LastSegment(item.Id["s3:/cirrus-test/".Length..]), Encoding.UTF8.GetString(File.ReadAllBytes(dest)));
            }
            var up = await d.UploadAsync(SrcFile(U("new")), "new #?%+&=.txt", odd.Id, null, null);
            Assert.Equal("new #?%+&=.txt", up.Name);
            Assert.Equal(U("new"), fake.S.Object("cirrus-test", folder + "/new #?%+&=.txt")?.Data);
            var renamed = await d.RenameAsync(up, "renamed ü #2+.txt");
            Assert.Contains(await d.ListAsync(odd.Id), n => n.Id == renamed.Id && n.Name == "renamed ü #2+.txt");
            var sub = await d.CreateFolderAsync("sub & dir # +", odd.Id);
            await d.MoveAsync([renamed], sub.Id);
            Assert.Equal(["renamed ü #2+.txt"], (await d.ListAsync(sub.Id)).Select(n => n.Name));
            Assert.True(fake.S.SignatureFailures == 0, endpoint);
        }
    }

    /// <summary>S3 never normalizes paths: "./" and "../" in keys must reach the server exactly (and be signed that way).</summary>
    [Fact]
    public async Task DotSegmentKeysAreSentExactly()
    {
        var s = TestState();
        s.Put("cirrus-test", "Dots/./here.txt", U("here"));
        s.Put("cirrus-test", "Dots/../up.txt", U("up"));
        s.Put("cirrus-test", "Dots/%2F/encoded.txt", U("enc"));
        var (fake, d) = Backend(s, Record(pathStyle: "1"));
        foreach (var (key, want) in new[] { ("Dots/./here.txt", "here"), ("Dots/../up.txt", "up"), ("Dots/%2F/encoded.txt", "enc") })
        {
            var n = new DriveNode { Id = "s3:/cirrus-test/" + key, Name = S3Key.LastSegment(key), Type = "FILE", Size = want.Length };
            Assert.Equal(U(want), File.ReadAllBytes(await Download(d, n)));
        }
        Assert.Contains(fake.S.Calls, c => c == "GET cirrus-test Dots/../up.txt");
        Assert.Equal(["%2F", ".", ".."], Sorted((await d.ListAsync("s3:/cirrus-test/Dots/")).Select(n => n.Name)));
        Assert.Equal(0, fake.S.SignatureFailures);
    }

    [Fact]
    public async Task KeysXMLCannotCarryComeURLEncoded()
    {
        var s = TestState();
        s.Put("cirrus-test", "Weird/bell\u0007.txt", U("ding"));
        s.Put("cirrus-test", "Weird/plus+ and space.txt", U("p"));
        var (fake, d) = Backend(s);
        var items = await d.ListAsync("s3:/cirrus-test/Weird/");
        Assert.Equal(["bell\u0007.txt", "plus+ and space.txt"], Sorted(items.Select(n => n.Name)));
        Assert.Contains(fake.S.Calls, c => c.Contains("encoding-type", StringComparison.Ordinal));
        var bell = items.Single(n => n.Name.StartsWith("bell", StringComparison.Ordinal));
        Assert.Equal(U("ding"), File.ReadAllBytes(await Download(d, bell)));
    }

    [Fact]
    public async Task FailedListingsThrowInsteadOfLookingEmpty()
    {
        var s = TestState(pageSize: 1);
        s.TruncateListings.Add("Documents/");
        s.TokenlessListings.Add("Photos/");
        var (fake, d) = Backend(s);
        Assert.IsType<CloudException>(await Caught(() => d.ListAsync("s3:/cirrus-test/Documents/")));
        var cut = await Caught(() => d.ListAsync("s3:/cirrus-test/Photos/"));
        Assert.Contains("short", cut?.Message);
        Assert.NotNull(await Caught(() => d.ListManyAsync([d.RootID, "s3:/cirrus-test/Photos/"])));
        Assert.NotNull(await Caught(() => d.WalkAsync(d.RootID)));
        fake.Update(st => st.InternalErrorNext = 100);
        var busy = await Caught(() => d.ListAsync(d.RootID));
        Assert.Contains("busy", busy?.Message);
    }

    [Fact]
    public async Task BusyServersAndDroppedConnectionsAreRetried()
    {
        var (fake, d) = Backend();
        fake.Update(st => { st.SlowDownNext = 2; st.InternalErrorNext = 1; st.DropNext = 1; });
        Assert.Equal(3, (await d.ListAsync(d.RootID)).Count);
        fake.Update(st => { st.SlowDownNext = 1; st.DropNext = 1; });
        var up = await d.UploadAsync(SrcFile(U("retry")), "retried.txt", d.RootID, null, null);
        Assert.Equal(5, up.Size);
        Assert.Equal(U("retry"), fake.S.Object("cirrus-test", "retried.txt")?.Data);
    }

    // MARK: Transfers

    [Fact]
    public async Task SmallUploadAndDownloadKeepTheDate()
    {
        var (fake, d) = Backend();
        var data = Bytes(70_000);
        var mtime = DateTimeOffset.FromUnixTimeSeconds(1_700_000_123);
        var progress = new ProgressBox();
        var up = await d.UploadAsync(SrcFile(data), "photo.jpg", "s3:/cirrus-test/Photos/", mtime, progress.Note);
        Assert.Equal("s3:/cirrus-test/Photos/photo.jpg", up.Id);
        Assert.Equal("s3:/cirrus-test/Photos/", up.ParentID);
        Assert.Equal(70_000, up.Size);
        Assert.Equal(70_000, progress.Last.Done);
        var o = fake.S.Object("cirrus-test", "Photos/photo.jpg")!;
        Assert.Equal(data, o.Data);
        Assert.Equal("image/jpeg", o.ContentType);
        Assert.Equal("1700000123", o.Meta["x-amz-meta-mtime"]);
        Assert.Equal(o.Etag, up.Etag);
        Assert.StartsWith("Cirrus", fake.S.LastUserAgent);
        // The node it returns matches what a listing says.
        var listed = await Node(d, "s3:/cirrus-test/Photos/", "photo.jpg");
        Assert.Equal((up.Id, up.Size, up.Etag, up.Modified), (listed.Id, listed.Size, listed.Etag, listed.Modified));
        var dp = new ProgressBox();
        var dest = await Download(d, listed, "photo.jpg", dp.Note);
        Assert.Equal(data, File.ReadAllBytes(dest));
        Assert.Equal(70_000, dp.Last.Done);
        Assert.Equal(mtime.UtcDateTime, File.GetLastWriteTimeUtc(dest));
        Assert.Empty(Directory.GetFiles(Path.GetDirectoryName(dest)!, ".cirrus-dl-*"));
        // Without the note, the object's Last-Modified.
        var readme = await Node(d, d.RootID, "Readme.txt");
        var rd = await Download(d, readme, "r");
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1_790_000_000).UtcDateTime, File.GetLastWriteTimeUtc(rd));
        // A missing object is NotFound; a folder can't be downloaded.
        var gone = readme.Copy();
        gone.Id = "s3:/cirrus-test/gone.txt";
        Assert.True(IsNotFound(await Caught(() => d.DownloadAsync(gone, rd, null))));
        Assert.Equal(U("hello\n"), File.ReadAllBytes(rd));   // a failed download leaves the file alone
        var docs = await Node(d, d.RootID, "Documents");
        Assert.IsType<CloudException>(await Caught(() => d.DownloadAsync(docs, rd, null)));
        // Empty files work both ways.
        var e = await d.UploadAsync(SrcFile([]), "empty.txt", d.RootID, null, null);
        Assert.Equal(0, e.Size);
        Assert.Empty(File.ReadAllBytes(await Download(d, e, "e")));
    }

    [Fact]
    public async Task BigUploadsGoInPartsAndRetryAPart()
    {
        var s = TestState();
        s.MinPartSize = 256 * 1024;
        s.MaxPutSize = 300 * 1024;    // a single PUT this big would be refused
        s.FailParts[2] = 1;
        var (fake, d) = Backend(s);
        d.MultipartThreshold = 300 * 1024;
        d.PartSize = 256 * 1024;
        var data = Bytes(1_100_000, seed: 13);
        var mtime = DateTimeOffset.FromUnixTimeSeconds(1_750_000_000);
        var progress = new ProgressBox();
        var up = await d.UploadAsync(SrcFile(data, "big.bin"), "big.bin", "s3:/cirrus-test/Documents/", mtime, progress.Note);
        Assert.Equal(1_100_000, up.Size);
        var o = fake.S.Object("cirrus-test", "Documents/big.bin")!;
        Assert.Equal(data, o.Data);
        Assert.EndsWith("-5", o.Etag);
        Assert.Equal("1750000000", o.Meta["x-amz-meta-mtime"]);
        Assert.NotEmpty(o.ContentType);
        Assert.Equal((1, 5, 0), (fake.S.Completed, fake.S.PartPuts, fake.S.OpenUploads));
        Assert.Equal(0, fake.S.FailParts[2]);          // part 2 failed once and was sent again
        Assert.Equal(1_100_000, progress.Last.Done);
        var dest = await Download(d, up, "b");
        Assert.Equal(data, File.ReadAllBytes(dest));
        Assert.Equal(mtime.UtcDateTime, File.GetLastWriteTimeUtc(dest));
        // No overwrite at the end either: Complete carries If-None-Match.
        fake.Update(st => { st.GhostKeys.Add("Documents/big2.bin"); st.Put("cirrus-test", "Documents/big2.bin", U("someone else's")); });
        var clash = await Caught(() => d.UploadAsync(SrcFile(data, "big2.bin"), "big2.bin", "s3:/cirrus-test/Documents/", null, null));
        Assert.Contains("already", DeniedMessage(clash) ?? clash?.Message);
        await WaitFor(() => fake.Read(st => st.OpenUploads) == 0);
        Assert.Equal((0, 1), fake.Read(st => (st.OpenUploads, st.Aborted)));
        Assert.Equal(U("someone else's"), fake.S.Object("cirrus-test", "Documents/big2.bin")?.Data);
    }

    [Fact]
    public async Task FailedOrCancelledMultipartUploadsAreAborted()
    {
        var s = TestState();
        s.MinPartSize = 1;
        s.ForbiddenParts.Add(2);
        var (fake, d) = Backend(s);
        d.MultipartThreshold = 100_000;
        d.PartSize = 1 << 20;
        var data = Bytes(3 << 20);
        var e = await Caught(() => d.UploadAsync(SrcFile(data), "denied.bin", d.RootID, null, null));
        Assert.NotNull(DeniedMessage(e));
        await WaitFor(() => fake.Read(st => st.OpenUploads) == 0);
        Assert.Equal((0, 1), fake.Read(st => (st.OpenUploads, st.Aborted)));
        Assert.Null(fake.S.Object("cirrus-test", "denied.bin"));
        // Cancelled half-way.
        fake.Update(st => { st.ForbiddenParts.Clear(); st.Latency = 0.15; st.PartPuts = 0; });
        var src = SrcFile(data);
        using var cts = new CancellationTokenSource();
        var t = d.UploadAsync(src, "cancelled.bin", d.RootID, null, null, cts.Token);
        await WaitFor(() => fake.Read(st => st.PartPuts) >= 1);
        cts.Cancel();
        var ce = await Caught(() => t);
        Assert.IsAssignableFrom<OperationCanceledException>(ce);
        fake.Update(st => st.Latency = 0);
        await WaitFor(() => fake.Read(st => st.OpenUploads) == 0);
        Assert.Equal((0, 2), fake.Read(st => (st.OpenUploads, st.Aborted)));
        Assert.Null(fake.S.Object("cirrus-test", "cancelled.bin"));
        Assert.Equal(0, fake.S.Completed);
    }

    [Fact]
    public async Task CancellingADownloadStopsIt()
    {
        var (fake, d) = Backend();
        var readme = await Node(d, d.RootID, "Readme.txt");
        fake.Update(st => st.Latency = 0.5);
        using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(100));
        var dest = Path.Combine(TempDir("cancel"), "r");
        Assert.IsAssignableFrom<OperationCanceledException>(await Caught(() => d.DownloadAsync(readme, dest, null, cts.Token)));
        Assert.False(File.Exists(dest));
    }

    // MARK: Never overwrite

    [Fact]
    public async Task UploadsAndFoldersNeverReplaceAnything()
    {
        var (fake, d) = Backend();
        await d.CreateFolderAsync("Fine", d.RootID);
        var file = SrcFile(U("x"));
        var e1 = await Caught(() => d.UploadAsync(file, "Readme.txt", d.RootID, null, null));
        Assert.Equal("There’s already an item named “Readme.txt” in “cirrus-test”. Choose a different name.", DeniedMessage(e1));
        Assert.Equal(U("hello\n"), fake.S.Object("cirrus-test", "Readme.txt")?.Data);
        // A file named like a folder (and the other way round).
        Assert.NotNull(DeniedMessage(await Caught(() => d.UploadAsync(file, "Photos", d.RootID, null, null))));
        Assert.NotNull(DeniedMessage(await Caught(() => d.CreateFolderAsync("Readme.txt", d.RootID))));
        Assert.NotNull(DeniedMessage(await Caught(() => d.CreateFolderAsync("Documents", d.RootID))));
        Assert.NotNull(DeniedMessage(await Caught(() => d.CreateFolderAsync(".cirrus-deleted", d.RootID))));
        Assert.NotNull(await Caught(() => d.CreateFolderAsync("a/b", d.RootID)));
        // Someone else writes the same name between the check and the upload: If-None-Match stops it.
        fake.Update(st => { st.GhostKeys.Add("late.txt"); st.Put("cirrus-test", "late.txt", U("theirs")); });
        var e2 = await Caught(() => d.UploadAsync(file, "late.txt", d.RootID, null, null));
        Assert.Contains("already", DeniedMessage(e2));
        Assert.Equal(U("theirs"), fake.S.Object("cirrus-test", "late.txt")?.Data);
        Assert.True(d.ConditionalWrites);
    }

    [Fact]
    public async Task ServicesWithoutConditionalWritesStillNeverOverwrite()
    {
        // B2 answers 501 NotImplemented to If-None-Match: Cirrus drops the header and relies on its check.
        var s = TestState();
        s.Put("b2-bucket", "have.txt", U("old"));
        var (fake, b2) = Backend(s, Record("https://s3.us-west-004.backblazeb2.com", "b2-bucket", "us-west-004"));
        var up = await b2.UploadAsync(SrcFile(U("new")), "new.txt", b2.RootID, null, null);
        Assert.Equal(3, up.Size);
        Assert.False(b2.ConditionalWrites);
        await b2.CreateFolderAsync("Folder", b2.RootID);
        Assert.NotNull(DeniedMessage(await Caught(() => b2.UploadAsync(SrcFile(U("x")), "have.txt", b2.RootID, null, null))));
        Assert.Equal(U("old"), fake.S.Object("b2-bucket", "have.txt")?.Data);
        // Wasabi-style: the header is ignored, the existence check still holds.
        var w = TestState();
        w.Put("wasabi-bucket", "have.txt", U("old"));
        var (wf, wa) = Backend(w, Record("https://s3.eu-central-1.wasabisys.com", "wasabi-bucket", "eu-central-1"));
        Assert.NotNull(DeniedMessage(await Caught(() => wa.UploadAsync(SrcFile(U("x")), "have.txt", wa.RootID, null, null))));
        Assert.Equal(U("old"), wf.S.Object("wasabi-bucket", "have.txt")?.Data);
    }

    // MARK: Folders, rename, move

    [Fact]
    public async Task CreateFolderWritesAMarker()
    {
        var (fake, d) = Backend();
        var f = await d.CreateFolderAsync("New Folder", d.RootID);
        Assert.Equal(("s3:/cirrus-test/New Folder/", true, d.RootID, "New Folder"), (f.Id, f.IsFolder, f.ParentID, f.Name));
        var marker = fake.S.Object("cirrus-test", "New Folder/")!;
        Assert.Empty(marker.Data);
        Assert.Equal("application/x-directory", marker.ContentType);
        Assert.Contains(await d.ListAsync(d.RootID), n => n.Id == f.Id);
        Assert.Empty(await d.ListAsync(f.Id));
        // Inside a folder that is only keys.
        var inner = await d.CreateFolderAsync("Inner", "s3:/cirrus-test/Photos/");
        Assert.Equal(("s3:/cirrus-test/Photos/Inner/", "s3:/cirrus-test/Photos/"), (inner.Id, inner.ParentID));
        Assert.Equal(["Inner", "one.jpg", "two.jpg"], Sorted((await d.ListAsync("s3:/cirrus-test/Photos/")).Select(n => n.Name)));
        // Nothing can be added to the deleted items.
        var e = await Caught(() => d.CreateFolderAsync("x", "s3:/cirrus-test/.cirrus-deleted/"));
        Assert.Equal("Items can’t be added to Deleted Items.", e?.Message);
    }

    [Fact]
    public async Task RenameAndMoveFiles()
    {
        var (fake, d) = Backend();
        var a = await Node(d, "s3:/cirrus-test/Documents/", "a.txt");
        var renamed = await d.RenameAsync(a, "A renamed.txt");
        Assert.Equal(("s3:/cirrus-test/Documents/A renamed.txt", "A renamed.txt", "s3:/cirrus-test/Documents/"), (renamed.Id, renamed.Name, renamed.ParentID));
        Assert.Null(fake.S.Object("cirrus-test", "Documents/a.txt"));
        Assert.Equal(U("a"), fake.S.Object("cirrus-test", "Documents/A renamed.txt")?.Data);
        // Case-only renames are real renames in S3.
        var lower = await d.RenameAsync(renamed, "a renamed.txt");
        Assert.Equal("a renamed.txt", lower.Name);
        Assert.Null(fake.S.Object("cirrus-test", "Documents/A renamed.txt"));
        // Clashes are refused and change nothing.
        var b = await Node(d, "s3:/cirrus-test/Documents/", "b.txt");
        Assert.Contains("already", DeniedMessage(await Caught(() => d.RenameAsync(b, "c.csv"))));
        Assert.Contains("already", DeniedMessage(await Caught(() => d.RenameAsync(b, "Sub"))));
        Assert.NotNull(fake.S.Object("cirrus-test", "Documents/b.txt"));
        // Metadata (the date note) survives.
        var up = await d.UploadAsync(SrcFile(U("m")), "dated.txt", d.RootID, DateTimeOffset.FromUnixTimeSeconds(1_600_000_000), null);
        await d.MoveAsync([up], "s3:/cirrus-test/Photos/");
        Assert.Equal("1600000000", fake.S.Object("cirrus-test", "Photos/dated.txt")?.Meta["x-amz-meta-mtime"]);
        Assert.Null(fake.S.Object("cirrus-test", "dated.txt"));
        // Moving the last items out of a folder that is only keys keeps the folder (a marker is written).
        var one = await Node(d, "s3:/cirrus-test/Photos/", "one.jpg");
        var two = await Node(d, "s3:/cirrus-test/Photos/", "two.jpg");
        var dated = await Node(d, "s3:/cirrus-test/Photos/", "dated.txt");
        await d.MoveAsync([one, two, dated], d.RootID);
        Assert.Empty(await d.ListAsync("s3:/cirrus-test/Photos/"));
        Assert.NotNull(fake.S.Object("cirrus-test", "Photos/"));
        var topNames = (await d.ListAsync(d.RootID)).Select(n => n.Name).ToHashSet();
        Assert.Superset(new HashSet<string> { "one.jpg", "two.jpg", "dated.txt", "Photos" }, topNames);
        // Same folder: nothing to do. A clash: refused.
        var oneTop = await Node(d, d.RootID, "one.jpg");
        var copies = fake.S.Copies;
        await d.MoveAsync([oneTop], d.RootID);
        Assert.Equal(copies, fake.S.Copies);
        fake.Update(st => st.Put("cirrus-test", "Photos/one.jpg", U("another")));
        Assert.Contains("already", DeniedMessage(await Caught(() => d.MoveAsync([oneTop], "s3:/cirrus-test/Photos/"))));
        Assert.NotNull(fake.S.Object("cirrus-test", "one.jpg"));
    }

    [Fact]
    public async Task RenameAndMoveFoldersMoveEveryKey()
    {
        var s = TestState(pageSize: 2);
        for (int i = 0; i < 7; i++) s.Put("cirrus-test", $"Documents/Sub/more/{i}.txt", U(i.ToString()));
        var (fake, d) = Backend(s);
        var docs = await Node(d, d.RootID, "Documents");
        var before = fake.S.Buckets["cirrus-test"].Keys.Where(k => k.StartsWith("Documents/", StringComparison.Ordinal)).ToList();
        var renamed = await d.RenameAsync(docs, "Papers");
        Assert.Equal(("s3:/cirrus-test/Papers/", "Papers", true), (renamed.Id, renamed.Name, renamed.IsFolder));
        var after = fake.S.Buckets["cirrus-test"].Keys;
        Assert.DoesNotContain(after, k => k.StartsWith("Documents/", StringComparison.Ordinal));
        Assert.Equal(Sorted(before.Select(k => "Papers/" + k["Documents/".Length..])), Sorted(after.Where(k => k.StartsWith("Papers/", StringComparison.Ordinal))));
        Assert.Equal(U("6"), fake.S.Object("cirrus-test", "Papers/Sub/more/6.txt")?.Data);
        // Into another folder, and never into itself.
        var sub = await Node(d, renamed.Id, "Sub");
        await d.MoveAsync([sub], "s3:/cirrus-test/Photos/");
        Assert.Equal(["deep.txt", "more"], Sorted((await d.ListAsync("s3:/cirrus-test/Photos/Sub/")).Select(n => n.Name)));
        Assert.Equal(7, (await d.ListAsync("s3:/cirrus-test/Photos/Sub/more/")).Count);
        var photos = await Node(d, d.RootID, "Photos");
        Assert.Contains("into itself", DeniedMessage(await Caught(() => d.MoveAsync([photos], "s3:/cirrus-test/Photos/Sub/"))));
        // A copy that fails (inside a 200 answer) leaves the originals and no half copy.
        fake.Update(st => st.FailCopiesIn200.Add("Photos/Sub/more/3.txt"));
        var keysBefore = fake.Read(st => st.Buckets["cirrus-test"].Keys);
        Assert.NotNull(await Caught(() => d.RenameAsync(photos, "Pictures")));
        await WaitFor(() => !fake.Read(st => st.Buckets["cirrus-test"].Keys).Any(k => k.StartsWith("Pictures/", StringComparison.Ordinal)));
        Assert.Equal(keysBefore, fake.Read(st => st.Buckets["cirrus-test"].Keys));
    }

    [Fact]
    public async Task ObjectsOver5GBAreCopiedInParts()
    {
        var s = TestState();
        s.MaxCopySize = 100_000;
        s.MinPartSize = 1;
        var data = Bytes(250_000, seed: 3);
        s.Put("cirrus-test", "huge.bin", data, meta: new() { ["x-amz-meta-mtime"] = "1234567890" });
        var (fake, d) = Backend(s);
        d.MaxCopySize = 100_000;
        d.CopyPartSize = 64_000;
        var huge = await Node(d, d.RootID, "huge.bin");
        await d.RenameAsync(huge, "huge renamed.bin");
        var o = fake.S.Object("cirrus-test", "huge renamed.bin")!;
        Assert.Equal(data, o.Data);
        Assert.EndsWith("-4", o.Etag);
        Assert.Equal("1234567890", o.Meta["x-amz-meta-mtime"]);
        Assert.Equal((0, 1), (fake.S.Copies, fake.S.Completed));
        Assert.Null(fake.S.Object("cirrus-test", "huge.bin"));
        // And into the trash and back.
        await d.TrashAsync([await Node(d, d.RootID, "huge renamed.bin")]);
        var t = await d.ListTrashAsync();
        Assert.Equal(["huge renamed.bin"], t.Select(n => n.Name));
        await d.RestoreAsync(t);
        Assert.Equal(data, fake.S.Object("cirrus-test", "huge renamed.bin")?.Data);
        Assert.False(fake.S.Object("cirrus-test", "huge renamed.bin")!.Meta.ContainsKey(S3Backend.OriginalMeta));
    }

    // MARK: Trash

    [Fact]
    public async Task TrashListRestoreAndDeleteForever()
    {
        var (fake, d) = Backend();
        var readme = await Node(d, d.RootID, "Readme.txt");
        var a = await Node(d, "s3:/cirrus-test/Documents/", "a.txt");
        var sub = await Node(d, "s3:/cirrus-test/Documents/", "Sub");
        await d.TrashAsync([readme, a, sub]);
        Assert.DoesNotContain(await d.ListAsync(d.RootID), n => n.Name is "Readme.txt" or ".cirrus-deleted");
        Assert.DoesNotContain(await d.ListAsync("s3:/cirrus-test/Documents/"), n => n.Name is "a.txt" or "Sub");
        // Moved, never erased: the original key is noted on the object.
        var kept = fake.S.Object("cirrus-test", ".cirrus-deleted/Readme.txt")!;
        Assert.Equal(U("hello\n"), kept.Data);
        Assert.Equal("Readme.txt", kept.Meta[S3Backend.OriginalMeta]);
        Assert.Equal(U("deep"), fake.S.Object("cirrus-test", ".cirrus-deleted/Sub/deep.txt")?.Data);
        Assert.Equal("Documents/Sub/", fake.S.Object("cirrus-test", ".cirrus-deleted/Sub/")?.Meta[S3Backend.OriginalMeta]);
        // A second item with a name already in the trash gets its own name there, but shows its real one.
        var b = await Node(d, "s3:/cirrus-test/Documents/", "b.txt");
        var b2 = await d.RenameAsync(b, "a.txt");
        await d.TrashAsync([b2]);
        Assert.NotNull(fake.S.Object("cirrus-test", ".cirrus-deleted/a 2.txt"));
        var bin = await d.ListTrashAsync();
        Assert.Equal(["Readme.txt", "Sub", "a.txt", "a.txt"], Sorted(bin.Select(n => n.Name)));
        Assert.All(bin, n => { Assert.Equal(CloudConventions.TrashParent, n.ParentID); Assert.True(n.IsInTrash); });
        Assert.True(bin.Single(n => n.Name == "Sub").IsFolder);
        // Trash of deleted items, and recovering or erasing items that aren't deleted, are refused.
        Assert.NotNull(await Caught(() => d.TrashAsync([bin[0]])));
        var csv = await Node(d, "s3:/cirrus-test/Documents/", "c.csv");
        Assert.NotNull(await Caught(() => d.RestoreAsync([csv])));
        Assert.NotNull(await Caught(() => d.DeleteForeverAsync([csv])));
        var disguised = csv.Copy();
        disguised.ParentID = CloudConventions.TrashParent;   // in the trash by its parent, but not by its key
        Assert.NotNull(await Caught(() => d.DeleteForeverAsync([disguised])));
        Assert.NotNull(fake.S.Object("cirrus-test", "Documents/c.csv"));
        // Restore puts things back where they were; something new with the name meanwhile: keep both.
        await d.UploadAsync(SrcFile(U("new readme")), "Readme.txt", d.RootID, null, null);
        await d.RestoreAsync(bin.Where(n => n.Name is "Readme.txt" or "Sub" || n.Id.EndsWith("/a.txt", StringComparison.Ordinal)).ToList());
        Assert.Equal(U("hello\n"), fake.S.Object("cirrus-test", "Readme 2.txt")?.Data);
        Assert.Equal(U("new readme"), fake.S.Object("cirrus-test", "Readme.txt")?.Data);
        Assert.False(fake.S.Object("cirrus-test", "Readme 2.txt")!.Meta.ContainsKey(S3Backend.OriginalMeta));
        Assert.Equal(U("deep"), fake.S.Object("cirrus-test", "Documents/Sub/deep.txt")?.Data);
        Assert.Equal(U("a"), fake.S.Object("cirrus-test", "Documents/a.txt")?.Data);
        Assert.Superset(new HashSet<string> { "a.txt", "Sub" }, (await d.ListAsync("s3:/cirrus-test/Documents/")).Select(n => n.Name).ToHashSet());
        var left = await d.ListTrashAsync();
        Assert.Equal(["a.txt"], left.Select(n => n.Name));
        Assert.Equal("s3:/cirrus-test/.cirrus-deleted/a 2.txt", left[0].Id);
        // The item's origin is still there and taken: it comes back as "a 2.txt".
        await d.RestoreAsync(left);
        Assert.Equal(U("bb"), fake.S.Object("cirrus-test", "Documents/a 2.txt")?.Data);
        Assert.Empty(await d.ListTrashAsync());
        // Delete forever erases, only from the trash.
        await d.TrashAsync([await Node(d, "s3:/cirrus-test/Documents/", "Sub"), await Node(d, "s3:/cirrus-test/Documents/", "c.csv")]);
        var again = await d.ListTrashAsync();
        Assert.Equal(["Sub", "c.csv"], Sorted(again.Select(n => n.Name)));
        await d.DeleteForeverAsync(again);
        Assert.Empty(await d.ListTrashAsync());
        Assert.DoesNotContain(fake.S.Buckets["cirrus-test"].Keys, k => k.StartsWith(".cirrus-deleted/", StringComparison.Ordinal) && k != ".cirrus-deleted/");
        Assert.NotNull(fake.S.Object("cirrus-test", "Documents/"));   // the folder they left stays
        // Trashing what's already gone is fine.
        var ghost = readme.Copy();
        ghost.Id = "s3:/cirrus-test/never-there.txt";
        await d.TrashAsync([ghost]);
    }

    [Fact]
    public async Task ItemsOfUnknownOriginRestoreToTheTop()
    {
        var s = TestState();
        s.Put("cirrus-test", ".cirrus-deleted/stray.txt", U("s"));
        var (fake, d) = Backend(s);
        var bin = await d.ListTrashAsync();
        Assert.Equal(["stray.txt"], bin.Select(n => n.Name));
        await d.RestoreAsync(bin);
        Assert.Equal(U("s"), fake.S.Object("cirrus-test", "stray.txt")?.Data);
    }

    // MARK: Without a bucket

    [Fact]
    public async Task WithoutABucketTheTopListsBuckets()
    {
        var s = TestState();
        s.Put("other-bucket", ".cirrus-deleted/old.txt", U("o"), meta: new() { [S3Backend.OriginalMeta] = "Notes/old.txt" });
        var (fake, d) = Backend(s, Record(bucket: null));
        Assert.Equal("s3:/", d.RootID);
        var top = await d.ListAsync(d.RootID);
        Assert.Equal(["cirrus-test", "ireland", "other-bucket"], top.Select(n => n.Name));
        Assert.All(top, n => { Assert.True(n.IsFolder); Assert.Equal("s3:/", n.ParentID); Assert.Equal("s3:/" + n.Name + "/", n.Id); });
        Assert.Equal(["note.txt"], (await d.ListAsync("s3:/other-bucket/")).Select(n => n.Name));
        Assert.Equal("s3:/other-bucket/", (await d.ListAsync("s3:/other-bucket/"))[0].ParentID);
        // A bucket in another region is found there.
        Assert.Equal(["dublin.txt"], (await d.ListAsync("s3:/ireland/")).Select(n => n.Name));
        // Nothing can be added, renamed or deleted at the top.
        var up = await Caught(() => d.UploadAsync(SrcFile(U("x")), "x.txt", d.RootID, null, null));
        Assert.Equal(CloudErrorKind.Unsupported, Assert.IsType<CloudException>(up).Kind);
        Assert.Contains("Open a bucket first", up!.Message);
        Assert.IsType<CloudException>(await Caught(() => d.CreateFolderAsync("x", d.RootID)));
        Assert.IsType<CloudException>(await Caught(() => d.RenameAsync(top[0], "y")));
        Assert.IsType<CloudException>(await Caught(() => d.TrashAsync([top[0]])));
        // Inside a bucket everything works, across buckets too.
        var n = await d.UploadAsync(SrcFile(U("in")), "in.txt", "s3:/other-bucket/", null, null);
        await d.MoveAsync([n], "s3:/cirrus-test/Documents/");
        Assert.Equal(U("in"), fake.S.Object("cirrus-test", "Documents/in.txt")?.Data);
        Assert.Null(fake.S.Object("other-bucket", "in.txt"));
        // Deleted items from every bucket.
        await d.TrashAsync([await Node(d, "s3:/cirrus-test/", "Readme.txt")]);
        var bin = await d.ListTrashAsync();
        Assert.Equal(["s3:/cirrus-test/.cirrus-deleted/Readme.txt", "s3:/other-bucket/.cirrus-deleted/old.txt"], Sorted(bin.Select(x => x.Id)));
        Assert.Equal("old.txt", bin.Single(x => x.Id.StartsWith("s3:/other-bucket/", StringComparison.Ordinal)).Name);
        await d.RestoreAsync(bin.Where(x => x.Id.StartsWith("s3:/other-bucket/", StringComparison.Ordinal)).ToList());
        Assert.NotNull(fake.S.Object("other-bucket", "Notes/old.txt"));
    }

    // MARK: Errors

    [Fact]
    public async Task WrongKeysAndOtherRefusalsGiveClearErrors()
    {
        var (wf, wrong) = Backend(TestState(), Record(), secret: "not-the-secret");
        var e = await Caught(() => wrong.ListAsync(wrong.RootID));
        Assert.Contains("secret access key", DeniedMessage(e) ?? e?.Message);
        Assert.Equal(1, wf.S.SignatureFailures);    // not retried
        var (_, unknown) = Backend(TestState(), Record(key: "AKIAREVOKED"));
        var ue = Assert.IsType<CloudException>(await Caught(() => unknown.ListAsync(unknown.RootID)));
        Assert.Equal((CloudErrorKind.SignInNeeded, "S3 Storage (cirrus-test @ test)"), (ue.Kind, ue.Detail));
        Assert.Equal("S3 Storage (cirrus-test @ test) needs you to sign in again.", ue.Message);
        var s = TestState();
        s.Put("cirrus-test", "Archive/cold.bin", U("brr"), storageClass: "GLACIER");
        var (_, d) = Backend(s);
        var cold = await Node(d, "s3:/cirrus-test/Archive/", "cold.bin");
        var ce = await Caught(() => d.DownloadAsync(cold, Path.Combine(TempDir("cold"), "c"), null));
        Assert.Contains("archived", DeniedMessage(ce) ?? ce?.Message);
        var (_, gone) = Backend(TestState(), Record(bucket: "deleted-bucket"));
        Assert.Equal(CloudErrorKind.NotConfigured, Assert.IsType<CloudException>(await Caught(() => gone.ListAsync(gone.RootID))).Kind);
        // Make needs the secret, an S3 record and an endpoint.
        Assert.Equal(CloudErrorKind.SignInNeeded, Assert.Throws<CloudException>(() => S3Cloud.Make(Record(), new CloudSecret(), null)).Kind);
        var other = Record();
        other.Provider = CloudProvider.WebDAV;
        Assert.Throws<CloudException>(() => S3Cloud.Make(other, new CloudSecret { Password = "x" }, null));
        Assert.Throws<CloudException>(() => CloudBackends.Make(new CloudAccountRecord(CloudProvider.S3, "x", null, "k"), new CloudSecret { Password = "x" }));
        Assert.Throws<CloudException>(() => S3Cloud.Make(new CloudAccountRecord(CloudProvider.S3, "x", "https://s3.example.com", null), new CloudSecret { Password = "x" }, null));
    }

    [Fact]
    public async Task ASkewedClockIsCorrectedOnce()
    {
        var s = TestState();
        s.Skew = 3 * 3600;    // the server is three hours ahead
        var (fake, d) = Backend(s);
        Assert.Equal(3, (await d.ListAsync(d.RootID)).Count);
        Assert.Equal(1, fake.S.SkewRejections);
        Assert.InRange(d.Client.ClockOffset.TotalSeconds, 3 * 3600 - 5, 3 * 3600 + 5);
        await d.UploadAsync(SrcFile(U("t")), "timed.txt", d.RootID, null, null);
        Assert.Equal(1, fake.S.SkewRejections);
        // The other way round, at connect.
        fake.Update(st => st.Skew = -2 * 3600);
        await S3Cloud.ConnectAsync("https://s3.us-east-1.amazonaws.com", "us-east-1", "cirrus-test", Key, Secret, fake);
        Assert.Equal(2, fake.S.SkewRejections);
    }

    // MARK: Demo

    [Fact]
    public async Task DemoAccountWorks()
    {
        var fake = FakeS3Server.Demo();
        fake.Update(st => st.Latency = 0);
        var demo = Assert.Single(fake.DemoAccounts());
        Assert.Equal("cloud:s3:demo", demo.Record.Id);
        Assert.Equal(CloudProvider.S3, demo.Record.Provider);
        Assert.Equal("demo-files @ s3.example.com", demo.Record.Title);
        var d = S3Cloud.Make(demo.Record, demo.Secret, fake);
        Assert.Equal(CloudProvider.S3, d.Provider);
        Assert.True(d.CanListTrash);
        Assert.Equal(["Archive", "Backups", "Documents", "Photos", "Readme.txt"], Sorted((await d.ListAsync(d.RootID)).Select(n => n.Name)));
        Assert.Equal(["Old draft.txt"], (await d.ListTrashAsync()).Select(n => n.Name));
        Assert.Null(await d.QuotaAsync());
        var photos = await d.ListAsync("s3:/demo-files/Photos/");
        Assert.Equal(3, photos.Count);
        Assert.Null(await d.ThumbnailAsync(photos[0], 256));
        var dest = Path.Combine(TempDir("demo"), "p.png");
        await d.DownloadAsync(photos[0], dest, null);
        Assert.Equal(new byte[] { 0x89, (byte)'P', (byte)'N', (byte)'G' }, File.ReadAllBytes(dest)[..4]);
        var pdf = Path.Combine(TempDir("demo"), "brief.pdf");
        await d.DownloadAsync(await Node((S3Backend)d, "s3:/demo-files/Documents/", "Project brief.pdf"), pdf, null);
        Assert.StartsWith("%PDF-1.4", File.ReadAllText(pdf));
        Assert.True((await d.WalkAsync(d.RootID)).Count > 8);

        // Through the router (how Debug demo builds wire every cloud), and CloudBackends.Make with the router as transport.
        var router = new FakeCloudRouter(fake);
        Assert.True(fake.Handles(new Uri("https://s3.example.com/demo-files/Readme.txt")));
        Assert.False(fake.Handles(new Uri("https://cloud.example.com/remote.php/dav/")));
        Assert.Equal("cloud:s3:demo", Assert.Single(router.DemoAccounts()).Record.Id);
        var previous = CloudBackends.Transport;
        try
        {
            CloudBackends.Transport = router;
            var viaRouter = CloudBackends.Make(demo.Record, demo.Secret);
            Assert.Contains(await viaRouter.ListAsync(viaRouter.RootID), n => n.Name == "Readme.txt");
        }
        finally { CloudBackends.Transport = previous; }

        // With a storage folder, what's added in the demo is still there next time.
        var dir = TempDir("demo-store");
        var first = FakeS3Server.Demo(dir);
        first.Update(st => st.Latency = 0);
        var acct = first.DemoAccounts()[0];
        await S3Cloud.Make(acct.Record, acct.Secret, first).UploadAsync(SrcFile(U("kept")), "Kept.txt", "s3:/demo-files/", null, null);
        var second = FakeS3Server.Demo(dir);
        Assert.Equal(U("kept"), second.S.Object(FakeS3Server.DemoBucket, "Kept.txt")?.Data);
        Assert.NotNull(second.S.Object(FakeS3Server.DemoBucket, "Readme.txt"));
    }
}
