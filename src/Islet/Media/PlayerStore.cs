using System.ComponentModel;
using System.IO;
using System.Net.Http;
using System.Runtime.CompilerServices;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Islet.Core;
using Islet.Settings;

namespace Islet.Media;

public abstract record LyricsState
{
    public sealed record Idle : LyricsState;
    public sealed record Loading : LyricsState;
    public sealed record Synced(IReadOnlyList<LyricLine> Lines) : LyricsState;
    public sealed record Plain(string Text) : LyricsState;
    public sealed record Instrumental : LyricsState;
    public sealed record Unavailable : LyricsState;
}

/// Single source of truth for what is playing, shared by every surface of the app.
/// Lives on the UI thread; sources report from anywhere and are marshalled here.
public sealed class PlayerStore : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    /// Every song change; drives the island's "bump".
    public event Action? TrackChanged;

    public NowPlayingSnapshot? Snapshot { get; private set; }
    /// Artwork delivered by the player (often 300 px on Windows).
    public BitmapSource? Artwork { get; private set; }
    /// Catalog artwork (1400 px) for large surfaces, when the album is found.
    public BitmapSource? HiResArtwork { get; private set; }
    public BitmapSource? DisplayArtwork => HiResArtwork ?? Artwork;
    public Palette Palette { get; private set; } = Palette.Fallback;
    public LyricsState Lyrics { get; private set; } = new LyricsState.Idle();
    public WordStream WordStream { get; private set; } = new([]);
    public bool? Shuffle { get; private set; }
    public RepeatMode? Repeat { get; private set; }
    public string? WebService { get; private set; }
    public int TrackChangeCount { get; private set; }

    public bool HasTrack => Snapshot is not null;
    public bool IsPlaying => Snapshot?.IsPlaying ?? false;
    public double Duration => Snapshot?.Duration ?? 0;
    public string Title => Snapshot?.Title ?? "Not Playing";
    public string Artist => Snapshot?.Artist ?? "";
    /// The artist, plus the web player's name when the music comes from a browser.
    public string Subtitle => WebService is null ? Artist : Artist.Length == 0 ? WebService : $"{Artist} · {WebService}";
    public Color Accent => Color.FromRgb(Byte(Palette.Accent.R), Byte(Palette.Accent.G), Byte(Palette.Accent.B));

    private readonly AppSettings _settings;
    private readonly Dispatcher _dispatcher;
    private readonly MediaSessions _sessions = new();
    private readonly PlaybackReconciler _reconciler = new();
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(15) };
    private readonly LRCLIBClient _lrclib;
    private readonly AppleMusicLyricsClient _appleLyrics;
    private readonly ITunesLookup _lookup;
    private AppleMusicLyricsClient.Credentials? _refused;
    private string? _lastTrackKey;
    private int _lastArtworkRevision = -1;
    private CancellationTokenSource? _trackWork;

    public PlayerStore(AppSettings settings)
    {
        _settings = settings;
        _dispatcher = Dispatcher.CurrentDispatcher;
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("Islet/2.2 (personal Windows now-playing app)");
        var lyricsCache = Path.Combine(AppSettings.CacheFolder, "Lyrics");
        _lrclib = new LRCLIBClient(_http, "Islet/2.2 (personal Windows now-playing app)", lyricsCache);
        _appleLyrics = new AppleMusicLyricsClient(_http, lyricsCache);
        _lookup = new ITunesLookup(_http);
    }

    public Task StartAsync()
    {
        _sessions.Changed += snapshot => _dispatcher.BeginInvoke(() => Present(snapshot));
        return _sessions.StartAsync();
    }

    public double Elapsed(DateTime date) => Snapshot?.ElapsedAt(date) ?? 0;
    public double LyricsPosition(DateTime date) => Elapsed(date) + _settings.LyricsOffset;

    // MARK: Commands (optimistic, then sent to the source)

    public void TogglePlayPause()
    {
        if (Snapshot is not { } current) return;
        var now = DateTime.UtcNow;
        SetSnapshot(current.Reanchored(now, isPlaying: !current.IsPlaying));
        _reconciler.UserSetPlaying(!current.IsPlaying, now);
        _ = _sessions.SendAsync(MediaCommand.TogglePlayPause);
    }

    public void Next() => _ = _sessions.SendAsync(MediaCommand.NextTrack);
    public void Previous() => _ = _sessions.SendAsync(MediaCommand.PreviousTrack);

    public void Seek(double seconds)
    {
        if (Snapshot is not { } current) return;
        var target = Math.Clamp(seconds, 0, current.Duration > 0 ? current.Duration : Math.Max(seconds, 0));
        var now = DateTime.UtcNow;
        SetSnapshot(current.Reanchored(now, elapsed: target));
        _reconciler.UserSeeked(now);
        _ = _sessions.SeekAsync(target);
    }

    public void ToggleShuffle()
    {
        if (Shuffle is not bool on) return;
        Shuffle = !on;
        Notify(nameof(Shuffle));
        _ = _sessions.SetShuffleAsync(!on);
    }

    public void CycleRepeat()
    {
        if (Repeat is not { } mode) return;
        Repeat = mode switch { RepeatMode.Off => RepeatMode.All, RepeatMode.All => RepeatMode.One, _ => RepeatMode.Off };
        Notify(nameof(Repeat));
        _ = _sessions.SetRepeatAsync(Repeat.Value);
    }

    // MARK: Source events

    private void Present(NowPlayingSnapshot? incoming)
    {
        if (incoming is null)
        {
            if (Snapshot is not null) SetSnapshot(null);
            _lastTrackKey = null;
            return;
        }
        var next = _reconciler.Reconcile(incoming, Snapshot, DateTime.UtcNow);
        var trackChanged = next.TrackKey != _lastTrackKey;
        SetSnapshot(next);
        (Shuffle, Repeat) = _sessions.PlaybackOptions();
        Notify(nameof(Shuffle));
        Notify(nameof(Repeat));
        if (next.ArtworkRevision != _lastArtworkRevision)
        {
            _lastArtworkRevision = next.ArtworkRevision;
            SetArtwork(next.Artwork);
        }
        if (!trackChanged) return;
        _lastTrackKey = next.TrackKey;
        TrackChangeCount++;
        WebService = WebPlayers.Service(next);
        HiResArtwork = null;
        Notify(nameof(WebService));
        Notify(nameof(Subtitle));
        Notify(nameof(HiResArtwork));
        Notify(nameof(DisplayArtwork));
        Notify(nameof(TrackChangeCount));
        TrackChanged?.Invoke();
        _trackWork?.Cancel();
        _trackWork = new CancellationTokenSource();
        var token = _trackWork.Token;
        if (next.IsPlaceholder)
        {
            SetLyrics(new LyricsState.Unavailable());
            return;
        }
        _ = LoadLyricsAsync(next, token);
        _ = LoadHiResAsync(next, token);
    }

    private void SetSnapshot(NowPlayingSnapshot? value)
    {
        var hadTrack = HasTrack;
        var wasPlaying = IsPlaying;
        Snapshot = value;
        Notify(nameof(Snapshot));
        Notify(nameof(Title));
        Notify(nameof(Artist));
        Notify(nameof(Subtitle));
        Notify(nameof(Duration));
        if (hadTrack != HasTrack) Notify(nameof(HasTrack));
        if (wasPlaying != IsPlaying) Notify(nameof(IsPlaying));
        if (value is null)
        {
            SetArtwork(null);
            SetLyrics(new LyricsState.Idle());
            _lastArtworkRevision = -1;
        }
    }

    private void SetArtwork(byte[]? bytes)
    {
        Artwork = bytes is null ? null : Decode(bytes, 600);
        Notify(nameof(Artwork));
        Notify(nameof(DisplayArtwork));
        Palette = Artwork is null ? Palette.Fallback : ExtractPalette(Artwork);
        Notify(nameof(Palette));
        Notify(nameof(Accent));
    }

    private void SetLyrics(LyricsState state)
    {
        if (Lyrics == state) return;
        Lyrics = state;
        WordStream = state is LyricsState.Synced synced ? new WordStream(synced.Lines) : new WordStream([]);
        Notify(nameof(Lyrics));
        Notify(nameof(WordStream));
    }

    private async Task LoadLyricsAsync(NowPlayingSnapshot track, CancellationToken token)
    {
        SetLyrics(new LyricsState.Loading());
        LyricsState result = new LyricsState.Unavailable();
        try
        {
            // Apple Music's word timing first, with the user's own tokens; LRCLIB otherwise.
            if (AppleCredentials is { } credentials && credentials != _refused)
            {
                try
                {
                    if (await _appleLyrics.TtmlAsync(track.Title, track.Artist, track.Duration, credentials, token) is string ttml)
                    {
                        var lines = TTMLParser.Parse(ttml);
                        if (lines.Count > 0) result = new LyricsState.Synced(Annotate(lines));
                    }
                }
                catch (AppleMusicLyricsClient.UnauthorizedException) { _refused = credentials; }
                catch (Exception e) when (e is not OperationCanceledException) { Log.Error("lyrics", e); }
            }
            if (result is LyricsState.Unavailable)
            {
                result = await _lrclib.LyricsAsync(track.Title, track.Artist, track.Album, track.Duration, token) switch
                {
                    LyricsContent.Synced s => new LyricsState.Synced(Annotate(LRCParser.Parse(s.Lrc, track.Duration))),
                    LyricsContent.Plain p => new LyricsState.Plain(p.Text),
                    LyricsContent.Instrumental => new LyricsState.Instrumental(),
                    _ => new LyricsState.Unavailable(),
                };
            }
        }
        catch (OperationCanceledException) { return; }
        catch (Exception e) { Log.Error("lyrics", e); }
        if (token.IsCancellationRequested) return;
        await _dispatcher.InvokeAsync(() => { if (!token.IsCancellationRequested) SetLyrics(result); });
    }

    private IReadOnlyList<LyricLine> Annotate(List<LyricLine> lines) =>
        _settings.LyricWordIcons ? WordSymbols.System.Annotate(lines) : lines;

    private AppleMusicLyricsClient.Credentials? AppleCredentials =>
        _settings.AppleMusicDeveloperToken is { Length: > 0 } dev && _settings.AppleMusicUserToken is { Length: > 0 } user
            ? new(dev, user, _settings.AppleMusicStorefront)
            : null;

    /// Player thumbnails on Windows are often small; the catalog has the full-size cover.
    private async Task LoadHiResAsync(NowPlayingSnapshot track, CancellationToken token)
    {
        try
        {
            var country = RegionInfo.CurrentRegion.TwoLetterISORegionName.ToLowerInvariant();
            var album = await _lookup.AlbumAsync(track.Title, track.Artist, track.Album, country);
            if (album?.ArtworkUrl(1400) is not Uri url || token.IsCancellationRequested) return;
            var bytes = await _http.GetByteArrayAsync(url, token);
            await _dispatcher.InvokeAsync(() =>
            {
                if (token.IsCancellationRequested) return;
                HiResArtwork = Decode(bytes, 1400);
                Notify(nameof(HiResArtwork));
                Notify(nameof(DisplayArtwork));
                // Players that send no cover at all get the catalog's, and its colors.
                if (Artwork is null && HiResArtwork is not null)
                {
                    Artwork = Decode(bytes, 600);
                    Palette = ExtractPalette(Artwork!);
                    Notify(nameof(Artwork));
                    Notify(nameof(Palette));
                    Notify(nameof(Accent));
                }
            });
        }
        catch (OperationCanceledException) { }
        catch (Exception e) { Log.Debug("artwork", e.Message); }
    }

    private static BitmapSource? Decode(byte[] bytes, int maxPixels)
    {
        try
        {
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.StreamSource = new MemoryStream(bytes);
            // Decode at display size: a 3000 px cover would otherwise sit in memory at full size.
            image.DecodePixelWidth = maxPixels;
            image.EndInit();
            image.Freeze();
            return image;
        }
        catch { return null; }
    }

    /// A 32×32 sample of the cover for the k-means palette, the same size the Mac samples.
    private static Palette ExtractPalette(BitmapSource image)
    {
        var small = new TransformedBitmap(image, new ScaleTransform(32.0 / image.PixelWidth, 32.0 / image.PixelHeight));
        var converted = new FormatConvertedBitmap(small, PixelFormats.Bgra32, null, 0);
        int w = converted.PixelWidth, h = converted.PixelHeight;
        var pixels = new byte[w * h * 4];
        converted.CopyPixels(pixels, w * 4, 0);
        var rgb = new List<RGB>(w * h);
        for (var i = 0; i < pixels.Length; i += 4)
            if (pixels[i + 3] > 128) rgb.Add(new RGB(pixels[i + 2] / 255.0, pixels[i + 1] / 255.0, pixels[i] / 255.0));
        return PaletteExtractor.FromPixels(rgb);
    }

    private static byte Byte(double v) => (byte)Math.Round(Math.Clamp(v, 0, 1) * 255);

    private void Notify([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
