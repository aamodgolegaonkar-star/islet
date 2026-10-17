import Foundation

/// One observation of the system "Now Playing" state.
public struct NowPlayingSnapshot: Sendable, Equatable {
    public var title: String
    public var artist: String
    public var album: String
    /// Track length in seconds, 0 when unknown.
    public var duration: TimeInterval
    /// Playback position in seconds at `timestamp`.
    public var elapsed: TimeInterval
    public var timestamp: Date
    public var playbackRate: Double
    public var isPlaying: Bool
    public var bundleIdentifier: String
    public var artwork: Data?
    /// Increments whenever `artwork` changes, so views can compare cheaply.
    public var artworkRevision: Int
    public var uniqueIdentifier: String?

    public init(
        title: String,
        artist: String = "",
        album: String = "",
        duration: TimeInterval = 0,
        elapsed: TimeInterval = 0,
        timestamp: Date = Date(),
        playbackRate: Double = 0,
        isPlaying: Bool = false,
        bundleIdentifier: String = "",
        artwork: Data? = nil,
        artworkRevision: Int = 0,
        uniqueIdentifier: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.elapsed = elapsed
        self.timestamp = timestamp
        self.playbackRate = playbackRate
        self.isPlaying = isPlaying
        self.bundleIdentifier = bundleIdentifier
        self.artwork = artwork
        self.artworkRevision = artworkRevision
        self.uniqueIdentifier = uniqueIdentifier
    }

    /// Identity of the song; position and artwork updates do not change it.
    public var trackKey: String {
        [title, artist, album].joined(separator: "\u{1F}")
    }

    /// The playback clock: position, when it was observed, and how fast it advances.
    public var timing: PlaybackTiming {
        PlaybackTiming(elapsed: elapsed, timestamp: timestamp,
                       rate: isPlaying ? (playbackRate > 0 ? playbackRate : 1) : 0, duration: duration)
    }

    /// Position extrapolated to `date`, clamped to the track bounds.
    public func elapsed(at date: Date) -> TimeInterval {
        timing.position(at: date)
    }

    /// Returns a copy re-anchored at `date`, used for optimistic UI updates.
    public func reanchored(at date: Date, elapsed newElapsed: TimeInterval? = nil, isPlaying newPlaying: Bool? = nil) -> NowPlayingSnapshot {
        var copy = self
        copy.elapsed = newElapsed ?? elapsed(at: date)
        copy.timestamp = date
        if let newPlaying {
            copy.isPlaying = newPlaying
            copy.playbackRate = newPlaying ? max(playbackRate, 1) : 0
        }
        return copy
    }
}

/// A playback clock: the position at `timestamp`, advancing at `rate` (0 while paused).
public struct PlaybackTiming: Sendable, Equatable {
    public var elapsed: TimeInterval
    public var timestamp: Date
    public var rate: Double
    /// Track length in seconds, 0 when unknown.
    public var duration: TimeInterval

    public init(elapsed: TimeInterval, timestamp: Date, rate: Double, duration: TimeInterval) {
        self.elapsed = elapsed
        self.timestamp = timestamp
        self.rate = rate
        self.duration = duration
    }

    /// Position at `date`, clamped to the track bounds.
    public func position(at date: Date) -> TimeInterval {
        let position = elapsed + date.timeIntervalSince(timestamp) * rate
        return min(max(position, 0), duration > 0 ? duration : .greatestFiniteMagnitude)
    }

    /// When playback reaches `position`; nil while paused.
    public func date(reaching position: TimeInterval) -> Date? {
        rate > 0 ? timestamp.addingTimeInterval((position - elapsed) / rate) : nil
    }

    /// The next moment after `date` at which the position crosses a multiple of 1/`steps`
    /// second. Ticks fall on whole seconds, so time labels advance evenly; there are none
    /// while paused or once the track has ended.
    public func nextTick(after date: Date, steps: Int) -> Date? {
        guard rate > 0 else { return nil }
        let perSecond = Double(max(steps, 1))
        let position = elapsed + date.timeIntervalSince(timestamp) * rate
        if duration > 0, position >= duration { return nil }
        var target = (floor(position * perSecond + 1e-6) + 1) / perSecond
        if duration > 0 { target = min(target, duration) }
        guard target > position, let next = self.date(reaching: target) else { return nil }
        return next > date ? next : nil
    }
}

/// Merges Now Playing reports with what the user just did, so nothing flickers.
///
/// Sources answer commands late: right after a seek or play/pause they can still report the
/// old state. A user's change therefore holds until the source confirms it (or a grace
/// period passes), and small clock corrections during steady playback are ignored, so the
/// position never jitters or steps backwards.
public struct PlaybackReconciler: Sendable {
    /// Corrections smaller than this keep the current clock.
    public var jitterTolerance: TimeInterval = 0.3
    /// A report this close to the seek target confirms the seek.
    public var seekTolerance: TimeInterval = 1.5
    /// How long a user change wins against contrary reports.
    public var gracePeriod: TimeInterval = 2.5

    private var seekUntil: Date?
    private var playing: (value: Bool, until: Date)?

    public init() {}

    public mutating func userSeeked(at date: Date) {
        seekUntil = date.addingTimeInterval(gracePeriod)
    }

    public mutating func userSetPlaying(_ value: Bool, at date: Date) {
        playing = (value, date.addingTimeInterval(gracePeriod))
    }

    /// The state to show after `incoming` arrives while `current` is on screen.
    public mutating func reconcile(_ incoming: NowPlayingSnapshot, with current: NowPlayingSnapshot?,
                                   at date: Date) -> NowPlayingSnapshot {
        guard let current, current.trackKey == incoming.trackKey else {
            seekUntil = nil
            playing = nil
            return incoming
        }
        var keepClock = false
        if let pending = playing {
            if date >= pending.until || incoming.isPlaying == pending.value {
                playing = nil
            } else {
                keepClock = true
            }
        }
        let drift = abs(incoming.elapsed(at: date) - current.elapsed(at: date))
        if let until = seekUntil {
            if date >= until || (drift <= seekTolerance && !keepClock) {
                seekUntil = nil
            } else if drift > seekTolerance {
                keepClock = true
            }
        }
        if !keepClock, incoming.timing.rate == current.timing.rate, drift < jitterTolerance {
            keepClock = true
        }
        guard keepClock else { return incoming }
        var merged = incoming
        merged.elapsed = current.elapsed
        merged.timestamp = current.timestamp
        merged.isPlaying = current.isPlaying
        merged.playbackRate = current.playbackRate
        return merged
    }
}

/// Playback commands; raw values match the MediaRemote command IDs used by mediaremote-adapter.
public enum MediaCommand: Int, Sendable {
    case play = 0
    case pause = 1
    case togglePlayPause = 2
    case stop = 3
    case nextTrack = 4
    case previousTrack = 5
}
