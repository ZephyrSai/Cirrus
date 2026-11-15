using System.IO.Compression;
using System.Text;
using Cirrus.Fakes;

namespace Cirrus.Core.Tests;

/// <summary>Windows-side safety and privacy rules of the Google move.</summary>
public class GoogleSafetyTests
{
    // MARK: Capture-date probe (iCloud → Google decides whether to put the date in the description)

    static byte[] Tiff(bool withDate, bool bigEndian = false)
    {
        // IFD0 with one entry: ExifIFD pointer → Exif IFD with DateTimeOriginal (ASCII, 20 bytes) when asked.
        var ms = new MemoryStream();
        void U16(int v) { if (bigEndian) { ms.WriteByte((byte)(v >> 8)); ms.WriteByte((byte)v); } else { ms.WriteByte((byte)v); ms.WriteByte((byte)(v >> 8)); } }
        void U32(uint v) { var b = BitConverter.GetBytes(v); if (bigEndian) Array.Reverse(b); ms.Write(b); }
        ms.Write(bigEndian ? "MM"u8 : "II"u8); U16(42); U32(8);
        U16(1); U16(0x8769); U16(4); U32(1); U32(26); U32(0);              // IFD0 at 8, Exif IFD at 26
        U16(1); U16(withDate ? 0x9003 : 0x9286); U16(2); U32(20); U32(44); U32(0);   // Exif IFD at 26, value at 44
        ms.Write(Encoding.ASCII.GetBytes(withDate ? "2023:05:02 10:11:12\0" : "                   \0"));
        return ms.ToArray();
    }

    static byte[] Jpeg(byte[]? tiff)
    {
        var ms = new MemoryStream();
        ms.Write([0xFF, 0xD8]);
        ms.Write([0xFF, 0xE0, 0x00, 0x10]); ms.Write("JFIF\0"u8); ms.Write(new byte[9]);
        if (tiff is not null)
        {
            var len = tiff.Length + 8;
            ms.Write([0xFF, 0xE1, (byte)(len >> 8), (byte)len]); ms.Write("Exif\0\0"u8); ms.Write(tiff);
        }
        ms.Write([0xFF, 0xDA, 0x00, 0x02, 0x11, 0x22, 0xFF, 0xD9]);
        return ms.ToArray();
    }

    static byte[] Mov(uint created)
    {
        var mvhd = new byte[108];
        "mvhd"u8.CopyTo(mvhd.AsSpan(4));
        mvhd[3] = 108;
        var c = BitConverter.GetBytes(created); Array.Reverse(c); c.CopyTo(mvhd, 12);
        var moov = new byte[8 + mvhd.Length];
        moov[3] = (byte)moov.Length; "moov"u8.CopyTo(moov.AsSpan(4)); mvhd.CopyTo(moov, 8);
        byte[] ftyp = [0, 0, 0, 16, (byte)'f', (byte)'t', (byte)'y', (byte)'p', (byte)'q', (byte)'t', (byte)' ', (byte)' ', 0, 0, 0, 0];
        return [.. ftyp, .. moov];
    }

    [Fact]
    public void CaptureDateProbeReadsExifPngHeicAndMovieHeaders()
    {
        var dir = TestEnv.TempDir("probe");
        string F(string name, byte[] data) { var p = Path.Combine(dir, name); File.WriteAllBytes(p, data); return p; }
        Assert.True(MediaDates.HasEmbeddedDate(F("dated.jpg", Jpeg(Tiff(true))), false));
        Assert.True(MediaDates.HasEmbeddedDate(F("dated-be.jpg", Jpeg(Tiff(true, bigEndian: true))), false));
        Assert.False(MediaDates.HasEmbeddedDate(F("blank-date.jpg", Jpeg(Tiff(false))), false));
        Assert.False(MediaDates.HasEmbeddedDate(F("plain.jpg", Jpeg(null)), false));
        // PNG with an eXIf chunk before the image data, and a plain PNG.
        var png = DemoArt.Png(10, 10, 0.2, "");
        var exif = Tiff(true);
        var chunk = new byte[12 + exif.Length];
        BitConverter.GetBytes(exif.Length).Reverse().ToArray().CopyTo(chunk, 0);
        "eXIf"u8.CopyTo(chunk.AsSpan(4));
        exif.CopyTo(chunk, 8);
        var withExif = png[..33].Concat(chunk).Concat(png[33..]).ToArray();   // after the 8-byte signature + 25-byte IHDR
        Assert.True(MediaDates.HasEmbeddedDate(F("dated.png", withExif), false));
        Assert.False(MediaDates.HasEmbeddedDate(F("plain.png", png), false));
        // HEIC-style: ftyp box, then somewhere an Exif item.
        byte[] heic = [0, 0, 0, 24, .. "ftypheic"u8, 0, 0, 0, 0, .. "mif1heic"u8, .. new byte[100], 0, 0, 0, 6, .. "Exif\0\0"u8, .. Tiff(true)];
        Assert.True(MediaDates.HasEmbeddedDate(F("dated.heic", heic), false));
        // Movies: a creation time in the movie header (seconds since 1904).
        Assert.True(MediaDates.HasEmbeddedDate(F("dated.mov", Mov(3_700_000_000)), true));
        Assert.False(MediaDates.HasEmbeddedDate(F("undated.mov", Mov(0)), true));
        // Garbage never throws.
        Assert.False(MediaDates.HasEmbeddedDate(F("junk.jpg", [0xFF, 0xD8, 0xFF, 0xE1, 0xFF, 0xFF, 1, 2]), false));
        Assert.False(MediaDates.HasEmbeddedDate(Path.Combine(dir, "missing.jpg"), false));
    }

    // MARK: Tokens and logs

    [Fact]
    public void AccessTokenGoesOnlyToGoogleHosts()
    {
        var req = new GoogleRequest { Url = "https://www.googleapis.com/drive/v3/about" };
        using (var m = req.Build("ya29.secret", null, () => { })) Assert.Equal("ya29.secret", m.Headers.Authorization?.Parameter);
        foreach (var url in new[] { "https://example.com/x", "https://googleapis.com.evil.example/x", "https://evilgoogleapis.com/x", "http://127.0.0.1:9/x" })
        {
            using var m = new GoogleRequest { Url = url }.Build("ya29.secret", null, () => { });
            Assert.Null(m.Headers.Authorization);
        }
        Assert.True(GoogleHttp.IsGoogleHost("lh3.googleusercontent.com") && GoogleHttp.IsGoogleHost("photoslibrary.googleapis.com") && GoogleHttp.IsGoogleHost("docs.google.com"));
        Assert.False(GoogleHttp.IsGoogleHost("google.com.evil.example"));
    }

    [Fact]
    public async Task LogsNeverCarryTokensSecretsOrTheGoogleAddress()
    {
        using var log = new LogCapture();
        var (g, api) = await G.Connect(new FakeGoogle.State { AccessTTL = 1 }, GoogleScopes.Import);
        await new GoogleDrive(api).AboutAsync();
        g.Update(s => s.RevokeAllRefreshTokens());
        await Assert.ThrowsAsync<GoogleException>(() => new GoogleDrive(api).AboutAsync());
        var text = log.Text;
        Assert.Contains("google token →", text);
        Assert.DoesNotContain("ya29.", text);
        Assert.DoesNotContain("1//fake-refresh", text);
        Assert.DoesNotContain("demo-secret", text);
        Assert.DoesNotContain("demo.person@gmail.example", text);
        Assert.DoesNotContain("4/fake-", text);   // authorization codes
    }

    [Fact]
    public void TransientRulesSeparateNotSentFromAmbiguous()
    {
        var notSent = new HttpRequestException(HttpRequestError.ConnectionError, "refused");
        var dropped = new HttpRequestException(HttpRequestError.ResponseEnded, "lost", new IOException());
        Assert.True(GoogleHttp.IsTransient(notSent, ambiguousOK: false));
        Assert.False(GoogleHttp.IsTransient(dropped, ambiguousOK: false));   // a create may have happened: not retried
        Assert.True(GoogleHttp.IsTransient(dropped, ambiguousOK: true));
        Assert.True(GoogleHttp.IsTransient(new TimeoutException(), ambiguousOK: true));
        Assert.False(GoogleHttp.IsTransient(new TimeoutException(), ambiguousOK: false));
    }

    // MARK: Credentials

    [Fact]
    public void RefreshTokensAreStoredEncryptedUnderHashedNames()
    {
        var dir = TestEnv.TempDir("gsecrets");
        var store = new SecretGoogleStore(new FileSecretStore(dir, new XorProtector()));
        store.SetClient(new GoogleOAuthClient("123-abc.apps.googleusercontent.com", "GOCSPX-secret"));
        store.Save(new GoogleAccountInfo("4242", "someone@gmail.example", "Someone", GoogleScopes.All), "1//refresh-token-value");
        Assert.Equal("GOCSPX-secret", store.Client()?.ClientSecret);
        Assert.Equal("1//refresh-token-value", store.RefreshToken("4242"));
        Assert.Equal("someone@gmail.example", store.Accounts().Single().Email);
        foreach (var f in Directory.EnumerateFiles(dir))
        {
            var name = Path.GetFileName(f);
            Assert.DoesNotContain("someone", name);
            Assert.DoesNotContain("4242", name);
            var bytes = File.ReadAllBytes(f);
            Assert.DoesNotContain("refresh-token-value", Encoding.UTF8.GetString(bytes));
            Assert.DoesNotContain("someone@gmail", Encoding.UTF8.GetString(bytes));
        }
        store.Remove("4242");
        Assert.Null(store.RefreshToken("4242"));
        Assert.Empty(store.Accounts());
    }

    sealed class Presence(bool answer) : IUserPresence
    {
        public int Asked;
        public Task<bool> VerifyAsync(string reason, CancellationToken ct) { Asked++; return Task.FromResult(answer); }
    }

    [Fact]
    public async Task RefreshTokensNeedWindowsHelloLikeSavedPasswords()
    {
        var store = new MemoryGoogleStore();
        store.Save(new GoogleAccountInfo("1", "", "", GoogleScopes.All), "tok");
        var no = new Presence(false);
        Assert.Null(await new GoogleTokenGate(store, no, () => true).RefreshTokenAsync("1", "test"));
        Assert.Equal(1, no.Asked);
        Assert.Null(await new GoogleTokenGate(store, null, () => true).RefreshTokenAsync("1", "test"));   // no way to ask → not released
        var yes = new Presence(true);
        var gate = new GoogleTokenGate(store, yes, () => true);
        Assert.Equal("tok", await gate.RefreshTokenAsync("1", "test"));
        Assert.Equal("tok", await gate.RefreshTokenAsync("1", "test"));
        Assert.Equal(1, yes.Asked);                                                                   // once per run
        var off = new Presence(false);
        Assert.Equal("tok", await new GoogleTokenGate(store, off, () => false).RefreshTokenAsync("1", "test"));   // the user turned the check off
        Assert.Equal(0, off.Asked);
    }

    // MARK: Takeout archives are only read, and never decide where files land

    [Fact]
    public async Task HostileArchiveNamesStayInsideTheBatchFolder()
    {
        var dir = TestEnv.TempDir("hostile");
        var zip = Path.Combine(dir, "takeout-001.zip");
        var img = DemoArt.Png(20, 20, 0.1, "x");
        TakeoutFixture.WriteArchive(zip, [
            ("Takeout/Google Photos/Photos from 2023/../../../../escaped.jpg", img),
            ("Takeout/Google Photos/Photos from 2023/ok.jpg", img),
            ("Takeout/Google Photos/Photos from 2023/ok.jpg.json", TakeoutFixture.Sidecar("..\\..\\evil.jpg", DateTimeOffset.FromUnixTimeSeconds(1_683_000_000))),
        ], "zip");
        var tgz = Path.Combine(dir, "takeout-002.tgz");
        TakeoutFixture.WriteArchive(tgz, [("Takeout/Google Photos/Photos from 2024/../../../../escaped2.jpg", img)], "tgz");
        var reader = new TakeoutReader([zip, tgz]);
        var r = await reader.ScanAsync(null);
        Assert.Equal(["ok.jpg"], r.Items.Select(i => i.FileName));   // members that climb out of the export are left out
        Assert.False(TakeoutReader.SafeMember("/etc/x.jpg") || TakeoutReader.SafeMember("C:\\x.jpg") || TakeoutReader.SafeMember("a/./b.jpg"));
        Assert.True(TakeoutReader.SafeMember("Takeout/Google Photos/a..b.jpg"));
        // A sidecar title with path parts never becomes the name.
        Assert.DoesNotContain(r.Items, i => i.FileName.Contains('\\') || i.FileName.Contains('/'));
        var batch = Path.Combine(dir, "staging", "batch");
        var files = await reader.ExtractAsync(r.Items, batch);
        Assert.Single(files);
        Assert.All(files.Values, f => Assert.Equal(Path.GetFullPath(batch), Path.GetDirectoryName(Path.GetFullPath(f))));
        Assert.False(File.Exists(Path.Combine(dir, "escaped.jpg")) || File.Exists(Path.Combine(dir, "escaped2.jpg")) || File.Exists(Path.Combine(Path.GetDirectoryName(dir)!, "escaped.jpg")));
        Assert.True(File.Exists(zip) && File.Exists(tgz));   // the export is only read
    }

    [Fact]
    public async Task UnreadableArchivesAreExplainedNotGuessed()
    {
        var dir = TestEnv.TempDir("broken");
        var bad = Path.Combine(dir, "takeout-001.zip");
        File.WriteAllBytes(bad, Encoding.UTF8.GetBytes("this is not a zip"));
        var e = await Assert.ThrowsAsync<SyncException>(() => new TakeoutReader([bad]).ScanAsync(null));
        Assert.Contains("download that part again", e.Message);
        var bz = Path.Combine(dir, "takeout-001.tbz");
        File.WriteAllBytes(bz, [0x42, 0x5A, 0x68]);
        var e2 = await Assert.ThrowsAsync<SyncException>(() => new TakeoutReader([bz]).ScanAsync(null));
        Assert.Contains(".zip or .tgz", e2.Message);
    }

    // MARK: Staging stays bounded and is Cirrus's own

    [Fact]
    public async Task StagingIsReleasedAfterEveryRunAndNeverHoldsTheUsersFiles()
    {
        var (_, api) = await G.Connect(scopes: GoogleScopes.Import);
        var src = TestEnv.TempDir("staging-src");
        TestEnv.Write("hello", Path.Combine(src, "a.txt"));
        var state = TestEnv.TempDir("staging-state");
        var e = G.Engine(api, state, src);
        var ev = await e.EvaluateAsync(null);
        Assert.True(ev.StagingNeeded == 0, "native iCloud Drive files upload in place, nothing is staged");
        await e.RunAsync(ev, null);
        Assert.False(Directory.Exists(Path.Combine(state, "staging")));
        Assert.True(File.Exists(Path.Combine(src, "a.txt")));   // the source file itself is never moved or removed
    }
}
