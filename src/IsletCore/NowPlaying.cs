namespace Islet.Core;

/// One observation of the system "Now Playing" state.
/// On Windows it comes from GlobalSystemMediaTransportControlsSession; `SourceApp` is the
/// session's SourceAppUserModelId (the Mac's bundle identifier).
public sealed record NowPlayingSnapshot
{
    public string Title { get; init; } = "";
    public string Artist { get; init; } = "";
    public string Album { get; init; } = "";
    /// Track length in seconds, 0 when unknown.
    public double Duration { get; init; }
    /// Playback position in seconds at `Timestamp`.
    public double Elapsed { get; init; }
    public DateTime Timestamp { get; init; } = DateTime.UtcNow;
    public double PlaybackRate { get; init; }
    public bool IsPlaying { get; init; }
    public string SourceApp { get; init; } = "";
    public byte[]? Artwork { get; init; }
    /// Increments whenever `Artwork` changes, so views can compare cheaply.
    public int ArtworkRevision { get; init; }
    public string? UniqueIdentifier { get; init; }

    /// A browser's stand-in for a page making sound: no artist or album, nothing to show or look up.
    public bool IsPlaceholder => string.IsNullOrWhiteSpace(Artist) && string.IsNullOrWhiteSpace(Album);

    /// Identity of the song; position and artwork updates do not change it.
    public string TrackKey => string.Join('\u001F', Title, Artist, Album);

    /// The playback clock: position, when it was observed, and how fast it advances.
    public PlaybackTiming Timing =>
        new(Elapsed, Timestamp, IsPlaying ? (PlaybackRate > 0 ? PlaybackRate : 1) : 0, Duration);

    /// Position extrapolated to `date`, clamped to the track bounds.
    public double ElapsedAt(DateTime date) => Timing.Position(date);

    /// A copy re-anchored at `date`, used for optimistic UI updates.
    public NowPlayingSnapshot Reanchored(DateTime date, double? elapsed = null, bool? isPlaying = null)
    {
        var copy = this with { Elapsed = elapsed ?? ElapsedAt(date), Timestamp = date };
        if (isPlaying is bool playing)
            copy = copy with { IsPlaying = playing, PlaybackRate = playing ? Math.Max(PlaybackRate, 1) : 0 };
        return copy;
    }

    // Artwork is compared by revision, not by bytes, like the Mac's Equatable use in views.
    public bool Equals(NowPlayingSnapshot? other) =>
        other is not null && Title == other.Title && Artist == other.Artist && Album == other.Album
        && Duration == other.Duration && Elapsed == other.Elapsed && Timestamp == other.Timestamp
        && PlaybackRate == other.PlaybackRate && IsPlaying == other.IsPlaying && SourceApp == other.SourceApp
        && ArtworkRevision == other.ArtworkRevision && UniqueIdentifier == other.UniqueIdentifier;

    public override int GetHashCode() => HashCode.Combine(TrackKey, Elapsed, Timestamp, IsPlaying, ArtworkRevision);
}

/// A playback clock: the position at `Timestamp`, advancing at `Rate` (0 while paused).
public readonly record struct PlaybackTiming(double Elapsed, DateTime Timestamp, double Rate, double Duration)
{
    /// Position at `date`, clamped to the track bounds.
    public double Position(DateTime date)
    {
        var position = Elapsed + (date - Timestamp).TotalSeconds * Rate;
        return Math.Min(Math.Max(position, 0), Duration > 0 ? Duration : double.MaxValue);
    }

    /// When playback reaches `position`; null while paused.
    public DateTime? DateReaching(double position) =>
        Rate > 0 ? Timestamp.AddSeconds((position - Elapsed) / Rate) : null;

    /// The next moment after `date` at which the position crosses a multiple of 1/`steps`
    /// second. Ticks fall on whole seconds, so time labels advance evenly; there are none
    /// while paused or once the track has ended. Views schedule one timer for this moment
    /// instead of ticking every frame, which is what keeps the island cheap on battery.
    public DateTime? NextTick(DateTime date, int steps)
    {
        if (Rate <= 0) return null;
        double perSecond = Math.Max(steps, 1);
        var position = Elapsed + (date - Timestamp).TotalSeconds * Rate;
        if (Duration > 0 && position >= Duration) return null;
        var target = (Math.Floor(position * perSecond + 1e-6) + 1) / perSecond;
        if (Duration > 0) target = Math.Min(target, Duration);
        if (target <= position || DateReaching(target) is not DateTime next) return null;
        return next > date ? next : null;
    }
}

/// Merges Now Playing reports with what the user just did, so nothing flickers.
///
/// Sources answer commands late: right after a seek or play/pause they can still report the
/// old state. A user's change therefore holds until the source confirms it (or a grace
/// period passes), and small clock corrections during steady playback are ignored, so the
/// position never jitters or steps backwards.
public sealed class PlaybackReconciler
{
    /// Corrections smaller than this keep the current clock.
    public double JitterTolerance { get; set; } = 0.3;
    /// A report this close to the seek target confirms the seek.
    public double SeekTolerance { get; set; } = 1.5;
    /// How long a user change wins against contrary reports.
    public double GracePeriod { get; set; } = 2.5;

    private DateTime? _seekUntil;
    private (bool Value, DateTime Until)? _playing;

    public void UserSeeked(DateTime date) => _seekUntil = date.AddSeconds(GracePeriod);

    public void UserSetPlaying(bool value, DateTime date) => _playing = (value, date.AddSeconds(GracePeriod));

    /// The state to show after `incoming` arrives while `current` is on screen.
    public NowPlayingSnapshot Reconcile(NowPlayingSnapshot incoming, NowPlayingSnapshot? current, DateTime date)
    {
        if (current is null || current.TrackKey != incoming.TrackKey)
        {
            _seekUntil = null;
            _playing = null;
            return incoming;
        }
        var keepClock = false;
        if (_playing is { } pending)
        {
            if (date >= pending.Until || incoming.IsPlaying == pending.Value) _playing = null;
            else keepClock = true;
        }
        var drift = Math.Abs(incoming.ElapsedAt(date) - current.ElapsedAt(date));
        if (_seekUntil is DateTime until)
        {
            if (date >= until || (drift <= SeekTolerance && !keepClock)) _seekUntil = null;
            else if (drift > SeekTolerance) keepClock = true;
        }
        if (!keepClock && incoming.Timing.Rate == current.Timing.Rate && drift < JitterTolerance) keepClock = true;
        if (!keepClock) return incoming;
        return incoming with
        {
            Elapsed = current.Elapsed, Timestamp = current.Timestamp,
            IsPlaying = current.IsPlaying, PlaybackRate = current.PlaybackRate,
        };
    }
}

public enum MediaCommand { Play, Pause, TogglePlayPause, Stop, NextTrack, PreviousTrack }
