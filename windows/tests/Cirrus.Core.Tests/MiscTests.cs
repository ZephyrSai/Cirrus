using System.Text;

namespace Cirrus.Core.Tests;

public class MiscTests
{
    [Fact]
    public void JsonAccessorsMatchSwiftSemantics()
    {
        var j = J.Parse("{\"a\":{\"b\":[1,\"2\",true,null,1.5]},\"ms\":1700000000000,\"s\":1700000000,\"iso\":\"2026-01-02T03:04:05.123Z\",\"big\":50000000000}");
        Assert.Equal(1, j["a"]["b"][0].Int);
        Assert.Equal(2, j["a"]["b"][1].Int);
        Assert.Equal("1", j["a"]["b"][0].Str);
        Assert.Equal("true", j["a"]["b"][2].Str);
        Assert.True(j["a"]["b"][2].Bool);
        Assert.True(j["a"]["b"][3].IsNull);
        Assert.Equal("1.5", j["a"]["b"][4].Str);
        Assert.True(j["missing"]["deeper"][3].IsNull);
        Assert.Equal(50_000_000_000, j["big"].Int64);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1_700_000_000), j["ms"].Date);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1_700_000_000), j["s"].Date);
        Assert.Equal(new DateTimeOffset(2026, 1, 2, 3, 4, 5, 123, TimeSpan.Zero), j["iso"].Date);
        Assert.True(J.Parse("not json").IsNull);
    }

    [Fact]
    public void LogRedactsAppleIDsTokensAndPasswords()
    {
        var s = Log.Redact("signed in as Someone.Else+tag@icloud.com with password=hunter2 cookie: X-APPLE-WEBAUTH-TOKEN=\"v=2:t=AAAA\" scnt=AbCdEf123 " +
                           "token AbCdEfGhIjKlMnOpQrStUvWxYz0123456789AbCdEfGh phone +1 415 555 0123 sms 4155550123");
        Assert.DoesNotContain("Someone.Else", s);
        Assert.DoesNotContain("hunter2", s);
        Assert.DoesNotContain("AAAA", s);
        Assert.DoesNotContain("AbCdEf123", s);
        Assert.DoesNotContain("AbCdEfGhIjKlMnOpQrStUvWxYz0123456789", s);
        Assert.DoesNotContain("555", s);
        // Ordinary diagnostics survive.
        Assert.Equal("http POST p01-drivews.icloud.com/retrieveItemDetailsInFolders → 421", Log.Redact("http POST p01-drivews.icloud.com/retrieveItemDetailsInFolders → 421"));
        Assert.Equal("copied 12 files (3.4 MB) on 2026-11-15", Log.Redact("copied 12 files (3.4 MB) on 2026-11-15"));
    }

    [Fact]
    public void SecretStoreEncryptsAndHidesAppleIDs()
    {
        var dir = TestEnv.TempDir("secrets");
        var store = new FileSecretStore(dir, new XorProtector());
        store.Set(SecretServices.Password, "Person@Example.com", Encoding.UTF8.GetBytes("pa55word"));
        Assert.Equal("pa55word", Encoding.UTF8.GetString(store.Get(SecretServices.Password, "person@example.com")!));
        var files = Directory.GetFiles(dir);
        Assert.Single(files);
        Assert.DoesNotContain("person", Path.GetFileName(files[0]), StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("pa55word", File.ReadAllText(files[0]));
        Assert.Null(store.Get(SecretServices.Session, "person@example.com"));   // bound to the service
        store.Delete(SecretServices.Password, "person@example.com");
        Assert.Empty(Directory.GetFiles(dir));
    }

    sealed class Presence(bool answer) : IUserPresence
    {
        public int Asked;
        public Task<bool> VerifyAsync(string reason, CancellationToken ct) { Asked++; return Task.FromResult(answer); }
    }

    [Fact]
    public async Task SavedPasswordNeedsWindowsHelloFirst()
    {
        var store = new MemorySecretStore();
        store.Set(SecretServices.Password, "a@b.com", Encoding.UTF8.GetBytes("pw"));
        var no = new Presence(false);
        Assert.Null(await new CredentialGate(store, no, () => true).PasswordAsync("a@b.com", "test"));
        Assert.Equal(1, no.Asked);
        Assert.Null(await new CredentialGate(store, null, () => true).PasswordAsync("a@b.com", "test"));   // no verifier → never released
        var yes = new Presence(true);
        var gate = new CredentialGate(store, yes, () => true);
        Assert.Equal("pw", await gate.PasswordAsync("A@B.com", "test"));
        Assert.Equal("pw", await gate.PasswordAsync("a@b.com", "test"));
        Assert.Equal(1, yes.Asked);   // unlocked once per run
        gate.Forget("a@b.com");
        await gate.PasswordAsync("a@b.com", "test");
        Assert.Equal(2, yes.Asked);
    }

    [Fact]
    public void GlobAndNaturalOrder()
    {
        Assert.True(Glob.Matches("._foo", "._*"));
        Assert.True(Glob.Matches("THUMBS.DB", "Thumbs.db"));
        Assert.True(Glob.Matches("a1.txt", "a[0-9].txt"));
        Assert.False(Glob.Matches("ab.txt", "a[0-9].txt"));
        Assert.True(Glob.Excluded("x/.DS_Store", [".DS_Store"]));
        Assert.True(Glob.Excluded("Icon\r", new SyncOptions().Excludes));
        Assert.False(Glob.Excluded("docs/readme.md", new SyncOptions().Excludes));
        Assert.True(NaturalComparer.Instance.Compare("file 2", "file 10") < 0);
        Assert.True(NaturalComparer.Instance.Compare("B", "a") > 0);
    }

    [Fact]
    public void PhotoParsingBuildsCompanionsLikeIcloudpd()
    {
        static J Rec(string json) => J.Parse(json);
        var master = Rec("""
        {"recordName":"M1","recordType":"CPLMaster","fields":{
          "filenameEnc":{"value":"SU1HXzAwMDEuSEVJQw==","type":"ENCRYPTED_BYTES"},
          "resOriginalRes":{"value":{"downloadURL":"https://x/orig","size":2000}},
          "resOriginalFileType":{"value":"public.heic"},
          "resOriginalVidComplRes":{"value":{"downloadURL":"https://x/mov","size":900}},
          "resOriginalAltRes":{"value":{"downloadURL":"https://x/raw","size":5000}},
          "resOriginalAltFileType":{"value":"com.adobe.raw-image"},
          "resJPEGThumbRes":{"value":{"downloadURL":"https://x/thumb","size":10}},
          "resOriginalWidth":{"value":4032},"resOriginalHeight":{"value":3024}}}
        """);
        var asset = Rec("""
        {"recordName":"A1","recordType":"CPLAsset","recordChangeTag":"ct","fields":{
          "masterRef":{"value":{"recordName":"M1"}},"assetDate":{"value":1700000000000},
          "adjustmentType":{"value":"com.apple.photo"},
          "resJPEGFullRes":{"value":{"downloadURL":"https://x/edit","size":1500}},
          "resJPEGFullFileType":{"value":"public.jpeg"},
          "isFavorite":{"value":1}}}
        """);
        var list = WebPhotos.Parse([master, asset], "PrimarySync");
        var a = Assert.Single(list);
        Assert.Equal("IMG_0001.HEIC", a.Filename);
        Assert.True(a.IsLive && a.IsEdited && a.IsFavorite);
        Assert.Equal("IMG_0001.MOV", a.Resource(PhotoResourceKind.LiveVideo)!.Filename);
        Assert.Equal("IMG_0001-edited.jpg", a.Resource(PhotoResourceKind.Edited)!.Filename);
        Assert.Equal("IMG_0001.dng", a.Resource(PhotoResourceKind.Alternate)!.Filename);
        Assert.Equal(2000 + 900 + 1500 + 5000, a.ExportSize(true, true, true));
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1_700_000_000), a.Created);
    }

    [Fact]
    public void ListQueryPartitionsAndSmartAlbumFilters()
    {
        var q = WebPhotos.ListQuery(new PhotoAlbum("smart:Favorites", "Favorites", PhotoAlbumKind.Smart), new PhotoLibraryRef("PrimarySync", "P", false), 300);
        var s = q.ToJsonString();
        Assert.Contains("\"recordType\":\"CPLAssetAndMasterInSmartAlbumByAssetDate\"", s);
        Assert.Contains("\"value\":300", s);
        Assert.Contains("\"value\":\"FAVORITE\"", s);
        Assert.Contains("\"resultsLimit\":200", s);
    }

    [Fact]
    public void ByteStringsUseDecimalUnits()
    {
        Assert.Equal("Zero bytes", 0L.ByteString());
        Assert.Equal("512 bytes", 512L.ByteString());
        Assert.Equal("50 GB", 50_000_000_000L.ByteString());
        Assert.Equal("4.29 GB", Limits.Fat32Max.ByteString());
    }

    [Fact]
    public void DemoArtIsAValidPng()
    {
        var png = DemoArt.Png(64, 48, 0.3, "Test 1");
        var f = Path.Combine(TestEnv.TempDir("png"), "a.png");
        File.WriteAllBytes(f, png);
        Assert.Equal((64, 48), ImageInfo.Size(f));
    }
}
