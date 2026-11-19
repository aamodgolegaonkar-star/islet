using Islet.Core;
using Windows.Media.Control;
using Windows.Storage.Streams;
using Session = Windows.Media.Control.GlobalSystemMediaTransportControlsSession;

namespace Islet.Media;

/// Windows' system Now Playing (the media sessions behind the volume flyout and the lock
/// screen): what every player, browser tab and app reports. Event-driven: nothing here
/// polls, so a paused or idle PC costs Islet nothing.
///
/// Like the Mac's "what's playing comes first", the session shown is the one actually
/// playing; a browser's "A site is playing media" never replaces a paused song.
internal sealed class MediaSessions
{
    private GlobalSystemMediaTransportControlsSessionManager? _manager;
    private Session? _session;
    private readonly HashSet<Session> _watched = [];
    private string? _artworkKey;
    private byte[]? _artwork;
    private int _artworkRevision;

    /// A new snapshot, or null when nothing plays. Raised on a background thread.
    public event Action<NowPlayingSnapshot?>? Changed;

    public async Task StartAsync()
    {
        try
        {
            _manager = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
        }
        catch (Exception e)
        {
            Log.Error("media", e);
            return;
        }
        _manager.SessionsChanged += (_, _) => Rewatch();
        _manager.CurrentSessionChanged += (_, _) => _ = PublishAsync();
        Rewatch();
    }

    private void Rewatch()
    {
        if (_manager is null) return;
        IReadOnlyList<Session> sessions;
        try { sessions = _manager.GetSessions(); } catch { return; }
        lock (_watched)
        {
            foreach (var session in sessions)
            {
                if (!_watched.Add(session)) continue;
                session.MediaPropertiesChanged += (s, args) => { _ = PublishAsync(s); };
                session.PlaybackInfoChanged += (s, args) => { _ = PublishAsync(s); };
                session.TimelinePropertiesChanged += (s, args) => { _ = PublishAsync(s); };
            }
            _watched.RemoveWhere(s => !sessions.Contains(s));
        }
        _ = PublishAsync();
    }

    /// The session to show: the one playing (not a browser placeholder), else the one
    /// already on screen while it's still there, else Windows' current one.
    private Session? Pick()
    {
        if (_manager is null) return null;
        IReadOnlyList<Session> sessions;
        try { sessions = _manager.GetSessions(); } catch { return null; }
        bool Playing(Session s)
        {
            try { return s.GetPlaybackInfo().PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing; }
            catch { return false; }
        }
        bool Placeholder(Session s)
        {
            try
            {
                var props = s.TryGetMediaPropertiesAsync().AsTask().GetAwaiter().GetResult();
                var title = props.Title?.ToLowerInvariant() ?? "";
                return string.IsNullOrWhiteSpace(props.Artist) && string.IsNullOrWhiteSpace(props.AlbumTitle)
                       && (WebPlayers.IsBrowser(s.SourceAppUserModelId) || title.Contains("is playing media") || title.Contains("is playing audio"));
            }
            catch { return false; }
        }
        var current = _manager.GetCurrentSession();
        var playing = sessions.Where(Playing).ToList();
        var real = playing.FirstOrDefault(s => s == current && !Placeholder(s)) ?? playing.FirstOrDefault(s => !Placeholder(s));
        if (real is not null) return real;
        if (_session is not null && sessions.Contains(_session)) return _session;
        return current ?? playing.FirstOrDefault();
    }

    private readonly SemaphoreSlim _gate = new(1, 1);

    private async Task PublishAsync(Session? from = null)
    {
        await _gate.WaitAsync();
        try
        {
            var session = Pick();
            // A report from a session that isn't (and shouldn't become) the shown one changes nothing.
            if (from is not null && session != from && session == _session) return;
            _session = session;
            Changed?.Invoke(session is null ? null : await SnapshotAsync(session));
        }
        catch (Exception e) { Log.Error("media", e); }
        finally { _gate.Release(); }
    }

    private async Task<NowPlayingSnapshot?> SnapshotAsync(Session session)
    {
        var props = await session.TryGetMediaPropertiesAsync();
        if (props is null || string.IsNullOrEmpty(props.Title)) return null;
        var playback = session.GetPlaybackInfo();
        var timeline = session.GetTimelineProperties();
        var key = $"{session.SourceAppUserModelId}\u001F{props.Title}\u001F{props.Artist}\u001F{props.AlbumTitle}";
        if (key != _artworkKey || _artwork is null)
        {
            var bytes = await ReadAsync(props.Thumbnail);
            if (key != _artworkKey || bytes is not null)
            {
                _artworkKey = key;
                if (!(_artwork is not null && bytes is not null && _artwork.AsSpan().SequenceEqual(bytes)))
                {
                    _artwork = bytes;
                    _artworkRevision++;
                }
            }
        }
        var duration = (timeline.EndTime - timeline.StartTime).TotalSeconds;
        var position = (timeline.Position - timeline.StartTime).TotalSeconds;
        var updated = timeline.LastUpdatedTime.UtcDateTime;
        // Some apps never stamp their timeline: treat the report as fresh.
        if (updated < DateTime.UtcNow.AddDays(-1)) updated = DateTime.UtcNow;
        return new NowPlayingSnapshot
        {
            Title = props.Title,
            Artist = props.Artist ?? "",
            Album = props.AlbumTitle ?? "",
            Duration = Math.Max(duration, 0),
            Elapsed = Math.Max(position, 0),
            Timestamp = updated,
            PlaybackRate = playback.PlaybackRate ?? 1,
            IsPlaying = playback.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing,
            SourceApp = session.SourceAppUserModelId ?? "",
            Artwork = _artwork,
            ArtworkRevision = _artworkRevision,
        };
    }

    private static async Task<byte[]?> ReadAsync(IRandomAccessStreamReference? reference)
    {
        if (reference is null) return null;
        try
        {
            using var stream = await reference.OpenReadAsync();
            if (stream.Size == 0 || stream.Size > 16 << 20) return null;
            using var reader = new DataReader(stream);
            await reader.LoadAsync((uint)stream.Size);
            var bytes = new byte[stream.Size];
            reader.ReadBytes(bytes);
            return bytes;
        }
        catch { return null; }
    }

    // Commands go to the session on screen.
    public Task<bool> SendAsync(MediaCommand command)
    {
        if (_session is not { } s) return Task.FromResult(false);
        return Try(command switch
        {
            MediaCommand.Play => s.TryPlayAsync().AsTask(),
            MediaCommand.Pause => s.TryPauseAsync().AsTask(),
            MediaCommand.TogglePlayPause => s.TryTogglePlayPauseAsync().AsTask(),
            MediaCommand.Stop => s.TryStopAsync().AsTask(),
            MediaCommand.NextTrack => s.TrySkipNextAsync().AsTask(),
            MediaCommand.PreviousTrack => s.TrySkipPreviousAsync().AsTask(),
            _ => Task.FromResult(false),
        });
    }

    public Task<bool> SeekAsync(double seconds)
    {
        if (_session is not { } s) return Task.FromResult(false);
        var start = s.GetTimelineProperties().StartTime;
        return Try(s.TryChangePlaybackPositionAsync((start + TimeSpan.FromSeconds(seconds)).Ticks).AsTask());
    }

    /// Shuffle and repeat, when the player offers them (null: it doesn't).
    public (bool? Shuffle, RepeatMode? Repeat) PlaybackOptions()
    {
        if (_session is not { } s) return (null, null);
        try
        {
            var info = s.GetPlaybackInfo();
            bool? shuffle = info.Controls.IsShuffleEnabled ? info.IsShuffleActive ?? false : null;
            RepeatMode? repeat = info.Controls.IsRepeatEnabled
                ? info.AutoRepeatMode switch
                {
                    Windows.Media.MediaPlaybackAutoRepeatMode.List => RepeatMode.All,
                    Windows.Media.MediaPlaybackAutoRepeatMode.Track => RepeatMode.One,
                    _ => RepeatMode.Off,
                }
                : null;
            return (shuffle, repeat);
        }
        catch { return (null, null); }
    }

    public Task<bool> SetShuffleAsync(bool on) =>
        _session is { } s ? Try(s.TryChangeShuffleActiveAsync(on).AsTask()) : Task.FromResult(false);

    public Task<bool> SetRepeatAsync(RepeatMode mode) =>
        _session is { } s
            ? Try(s.TryChangeAutoRepeatModeAsync(mode switch
            {
                RepeatMode.All => Windows.Media.MediaPlaybackAutoRepeatMode.List,
                RepeatMode.One => Windows.Media.MediaPlaybackAutoRepeatMode.Track,
                _ => Windows.Media.MediaPlaybackAutoRepeatMode.None,
            }).AsTask())
            : Task.FromResult(false);

    private static async Task<bool> Try(Task<bool> task)
    {
        try { return await task; }
        catch (Exception e) { Log.Error("media", e); return false; }
    }
}

public enum RepeatMode { Off, All, One }

/// Browsers and the web players inside them.
internal static class WebPlayers
{
    private static readonly string[] Browsers = ["chrome", "msedge", "firefox", "opera", "brave", "vivaldi", "arc", "zen"];

    public static bool IsBrowser(string? app)
    {
        var a = app?.ToLowerInvariant() ?? "";
        return Browsers.Any(a.Contains);
    }

    /// The web player a browser tab is playing, recognised from the title the page reports.
    public static string? Service(NowPlayingSnapshot track)
    {
        if (!IsBrowser(track.SourceApp)) return null;
        var t = track.Title + " " + track.Album;
        if (t.Contains("YouTube Music", StringComparison.OrdinalIgnoreCase)) return "YouTube Music";
        if (t.Contains("YouTube", StringComparison.OrdinalIgnoreCase)) return "YouTube";
        if (t.Contains("SoundCloud", StringComparison.OrdinalIgnoreCase)) return "SoundCloud";
        return null;
    }
}
