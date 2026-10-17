import AppKit
import IsletCore

/// Follows the Spotify app directly, without the system Now Playing service.
///
/// Spotify broadcasts `com.spotify.client.PlaybackStateChanged` on every track change and
/// play/pause; each one triggers a single AppleScript read of the full state (position,
/// track ID, artwork link). While playing, a slow check corrects drift after seeks, which
/// Spotify doesn't announce. Spotify is never launched just to be asked what it plays.
@MainActor
final class SpotifySource {
    static let bundleID = "com.spotify.client"

    var onEvent: ((AdapterEvent) -> Void)?

    private var observer: DistributedObserver?
    private var timer: Timer?
    private var interval: TimeInterval = 10
    private var reading = false
    private var trackID: String?
    private var artwork: Data?
    private var artworkRevision = 20_000
    private var playing = false

    private static let stateScript = """
    tell application "Spotify"
        if player state is stopped then return "STOPPED"
        set t to current track
        return (player state as text) & tab & (player position as text) & tab & (name of t) & tab & (artist of t) & tab & (album of t) & tab & ((duration of t) as text) & tab & (id of t) & tab & (artwork url of t)
    end tell
    """

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    func start(pollInterval: TimeInterval) {
        interval = pollInterval
        observer = DistributedObserver("com.spotify.client.PlaybackStateChanged") { [weak self] _ in
            self?.read()
        }
        read()
    }

    func stop() {
        observer?.cancel()
        observer = nil
        timer?.invalidate()
        timer = nil
    }

    /// Reads the state now and again shortly, after a command (seeks aren't announced).
    func refreshSoon() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            self?.read()
        }
    }

    private func read() {
        guard !reading else { return }
        guard isRunning else {
            setPlaying(false)
            onEvent?(.nothingPlaying)
            return
        }
        reading = true
        Task {
            let output = await MusicAppSource.osascript(Self.stateScript)
            self.reading = false
            self.handle(output)
        }
    }

    private func handle(_ output: String?) {
        // No answer (Spotify busy, or Islet not allowed to ask it) isn't "stopped".
        guard let output else { return }
        guard output != "STOPPED" else {
            setPlaying(false)
            onEvent?(.nothingPlaying)
            return
        }
        let fields = output.components(separatedBy: "\t")
        guard fields.count >= 8 else { return }
        let number = { (text: String) in Double(text.replacing(",", with: ".")) ?? 0 }
        let id = fields[6]
        if id != trackID {
            trackID = id
            artwork = nil
            fetchArtwork(URL(string: fields[7]), for: id)
        }
        let isPlaying = fields[0] == "playing"
        setPlaying(isPlaying)
        onEvent?(.update(NowPlayingSnapshot(
            title: fields[2], artist: fields[3], album: fields[4],
            // Spotify reports duration in milliseconds.
            duration: number(fields[5]) / 1000, elapsed: number(fields[1]), timestamp: Date(),
            playbackRate: isPlaying ? 1 : 0, isPlaying: isPlaying,
            bundleIdentifier: Self.bundleID,
            artwork: artwork, artworkRevision: artworkRevision,
            uniqueIdentifier: id
        )))
    }

    private func fetchArtwork(_ url: URL?, for id: String) {
        guard let url, url.scheme == "https" else { return }
        Task {
            guard let data = try? await URLSession.shared.data(from: url).0, self.trackID == id else { return }
            self.artwork = data
            self.artworkRevision += 1
            self.read()
        }
    }

    /// The drift check runs only while music plays.
    private func setPlaying(_ value: Bool) {
        guard value != playing || (value && timer == nil) else { return }
        playing = value
        timer?.invalidate()
        timer = nil
        guard value else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        timer?.tolerance = interval * 0.2
    }
}
