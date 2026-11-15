using Cirrus.Fakes;
using Xunit.Abstractions;

namespace Cirrus.Core.Tests;

/// <summary>
/// Headless demo of both directions: the demo iCloud (its own Drive and Photos library in a temp folder) and the demo
/// Google account (fake server with its own Drive files and photos to pick), driven through the same engines the window
/// uses. Run with <c>dotnet test --filter GoogleDemoTests --logger "console;verbosity=detailed"</c> to see the transcript.
/// </summary>
public class GoogleDemoTests(ITestOutputHelper output)
{
    void Say(string s) => output.WriteLine(s);

    static async Task<Dictionary<string, long>> Tree(IDriveBackend d) =>
        (await d.WalkAsync(d.RootID)).ToDictionary(x => x.Path, x => x.Node.IsFolder ? -1 : x.Node.Size);

    [Fact]
    public async Task BothDirectionsRunEndToEndInDemoMode()
    {
        var root = TestEnv.TempDir("google-demo");
        var fake = new FakeGoogle();
        fake.StartDemo(Path.Combine(root, "google"));
        fake.Update(s => s.Latency = 0);
        var oauth = new GoogleOAuth(G.Client, fake);
        var tokens = await oauth.AuthorizeAsync(u => fake.ApproveAsync(u), GoogleScopes.Import);
        var refresh = tokens.RefreshToken!;
        var api = new GoogleApi(fake.S.UserID, oauth, tokens.Scopes, _ => Task.FromResult(refresh), fake, tokens) { RetryBase = 0.001, BatchCreateMinBackoff = 0 };
        Say($"Connected Google (fake) with {tokens.Scopes.Count} permissions.");

        var drive = new DemoDrive(Path.Combine(root, "icloud"));
        var photos = new DemoPhotos(Path.Combine(root, "icloud", "photos"));
        var state = Path.Combine(root, "state");
        var staging = Path.Combine(root, "staging");
        var driveBefore = await Tree(drive);
        var lib = (await photos.LibrariesAsync())[0];
        var photosBefore = (await photos.AssetsAsync(new PhotoAlbum("smart:All Photos", "All Photos", PhotoAlbumKind.Smart), lib, null)).Count;

        // iCloud → Google
        var fwd = new MigrationEngine(new MigrationEngine.Sources("demo", "Demo iCloud", drive, null, photos), new MigrationEngine.Target(api),
            new MigrationOptions(), state, staging);
        var fev = await fwd.EvaluateAsync(null);
        Say($"iCloud → Google check: {fev.DrivePending.Count} files ({fev.DrivePendingBytes.ByteString()}), {fev.PhotoPending.Count} photo files, {fev.Albums.Count} albums; fits: {fev.Fits}");
        foreach (var w in fev.Warnings) Say("  ⚠ " + w);
        var fr = await fwd.RunAsync(fev, null);
        Say("iCloud → Google run: " + fr.Summary + (fr.Failed.Count > 0 ? " | failed: " + string.Join("; ", fr.Failed) : ""));
        Assert.True(fr.Failed.Count == 0 && fr.Stopped is null, string.Join("; ", fr.Failed));
        Assert.True(fr.DriveCopied > 0 && fr.PhotosCreated > 0);
        Assert.Equal(driveBefore, await Tree(drive));   // iCloud isn't changed by the move to Google

        // Google → iCloud: My Drive, a Takeout export and two photos picked in Google Photos.
        var picker = new GooglePicker(api);
        var session = await picker.CreateAsync();
        fake.Pick(GooglePicker.BrowserURL(session), 2);
        await picker.WaitForPickAsync(session);
        var picked = await picker.ItemsAsync(session.Id);
        var takeout = TakeoutFixture.Make(Path.Combine(root, "takeout"), "zip");
        var back = new ImportEngine(new ImportEngine.SourceSpec(api, takeout, picked),
            new ImportEngine.TargetSpec("demo", "Demo iCloud", drive, null, photos, null, IsWeb: false), new ImportOptions(), state, staging, () => false);
        var bev = await back.EvaluateAsync(null);
        Say($"Google → iCloud check: {bev.DrivePending.Count} Drive files ({bev.Docs} Google Docs), {bev.PhotoPending.Count} photos ({bev.TakeoutItems} from Takeout, {bev.PickedItems} picked), {bev.Albums.Count} albums; fits: {bev.Fits}");
        foreach (var w in bev.Warnings) Say("  ⚠ " + w);
        foreach (var s in bev.Skipped) Say($"  skipped: {s.Name} — {s.Reason}");
        var br = await back.RunAsync(bev, null);
        Say("Google → iCloud run: " + br.Summary + (br.Failed.Count > 0 ? " | failed: " + string.Join("; ", br.Failed) : ""));
        Assert.True(br.Failed.Count == 0 && br.Stopped is null, string.Join("; ", br.Failed));
        Assert.Contains(bev.Warnings, w => w.Contains("“From iCloud” in Google Drive is left out"));
        var after = await Tree(drive);
        foreach (var p in new[] { "From Google Drive/Résumé.pdf", "From Google Drive/Notes.txt", "From Google Drive/Lisbon Trip/Itinerary.pdf",
                     "From Google Drive/Meeting notes.docx", "From Google Drive/Budget 2026.xlsx", "From Google Drive/Lisbon Trip/Pitch deck.pptx" })
            Assert.True(after.ContainsKey(p), p);
        Assert.DoesNotContain(after.Keys, k => k.Contains("Someone else", StringComparison.Ordinal) || k.Contains("RSVP", StringComparison.Ordinal));
        Assert.All(driveBefore, kv => Assert.Equal(kv.Value, after[kv.Key]));   // only added to
        var albums = await photos.AlbumsAsync(lib);
        Assert.Contains(albums, a => a.Name == "From Google Photos");
        Assert.Contains(albums, a => a.Name == "Lisbon trip");
        var all = await photos.AssetsAsync(new PhotoAlbum("smart:All Photos", "All Photos", PhotoAlbumKind.Smart), lib, null);
        Assert.Equal(photosBefore + br.PhotosImported, all.Count);
        Say($"Demo iCloud now: {after.Count(kv => kv.Key.StartsWith("From Google Drive/", StringComparison.Ordinal) && kv.Value >= 0)} files in “From Google Drive”, {all.Count} photos (was {photosBefore}).");

        // Both again: nothing left to do, and neither direction picks up the other's output.
        var fev2 = await new MigrationEngine(new MigrationEngine.Sources("demo", "Demo iCloud", drive, null, photos), new MigrationEngine.Target(api),
            new MigrationOptions(), state, staging).EvaluateAsync(null);
        var bev2 = await new ImportEngine(new ImportEngine.SourceSpec(api, takeout, picked),
            new ImportEngine.TargetSpec("demo", "Demo iCloud", drive, null, photos, null, IsWeb: false), new ImportOptions(), state, staging, () => false).EvaluateAsync(null);
        Say($"Second check: iCloud → Google up to date: {fev2.IsUpToDate}; Google → iCloud up to date: {bev2.IsUpToDate}.");
        Assert.True(fev2.IsUpToDate, string.Join(", ", fev2.DrivePending.Select(d => d.Rel).Concat(fev2.PhotoPending.Select(p => p.FileName))));
        Assert.True(bev2.IsUpToDate);
        Assert.Equal(0, fake.S.PermanentDeletes);
        Assert.Empty(fake.S.TokensSentElsewhere);
        await picker.DeleteAsync(session.Id);
    }
}
