import AppKit
import IsletCore

/// Fallback Now Playing source that talks to Music.app over AppleScript.
///
/// Used only if the MediaRemote adapter is unavailable. Requires the Automation
/// permission (NSAppleEventsUsageDescription); scripts run in `osascript` so a pending
/// permission prompt never blocks the UI.
@MainActor
final class MusicAppSource {
    var onEvent: ((AdapterEvent) -> Void)?

    private var timer: Timer?
    private var interval: TimeInterval = 1.5
    private var observer: DistributedObserver?
    private var polling = false
    private var pollAgain = false
    private var lastPersistentID: String?
    private var artwork: Data?
    private var artworkRevision = 10_000
    private let artworkFile = FileManager.default.temporaryDirectory.appending(path: "islet-artwork.bin")

    /// Asks Music itself whether it's running (without launching it): a freshly launched
    /// Islet's running-apps list can briefly come back empty, which used to clear the song.
    private static let stateScript = """
    if application "Music" is not running then return "STOPPED"
    tell application "Music"
        if player state is stopped then return "STOPPED"
        set t to current track
        return (player state as text) & tab & (player position as text) & tab & (name of t) & tab & (artist of t) & tab & (album of t) & tab & (duration of t as text) & tab & (persistent ID of t)
    end tell
    """

    /// Music announces changes itself; the timer is only a safety net for drift while a song
    /// plays (slow when Music is the chosen source, quicker as the emergency fallback). Each
    /// look starts an `osascript`, so none while paused: Music says when it plays again.
    func start(pollInterval: TimeInterval = 1.5) {
        interval = pollInterval
        // Started again (to hold Music on screen): one timer, at the new pace.
        timer?.invalidate()
        timer = nil
        observer = DistributedObserver("com.apple.Music.playerInfo") { [weak self] note in
            // Music's last word as it quits is "Stopped"; asking it anything then relaunches it.
            if note.userInfo?["Player State"] as? String == "Stopped" { self?.handle("STOPPED") } else { self?.poll() }
        }
        poll()
    }

    /// Reads the state shortly after a command (seeks aren't announced).
    func refreshSoon() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observer?.cancel()
        observer = nil
    }

    func send(_ command: MediaCommand) async -> Bool {
        await Self.send(command, to: "Music")
    }

    func seek(to seconds: TimeInterval) async -> Bool {
        await Self.seek(to: seconds, in: "Music")
    }

    /// Music and Spotify share these AppleScript verbs, so either can be driven directly
    /// when the system Now Playing channel fails.
    nonisolated static func send(_ command: MediaCommand, to app: String) async -> Bool {
        let verb = switch command {
        case .play: "play"
        case .pause: "pause"
        case .togglePlayPause: "playpause"
        case .stop: app == "Spotify" ? "pause" : "stop"
        case .nextTrack: "next track"
        case .previousTrack: "previous track"
        }
        return await osascript("tell application \"\(app)\" to \(verb)") != nil
    }

    nonisolated static func seek(to seconds: TimeInterval, in app: String) async -> Bool {
        await osascript("tell application \"\(app)\" to set player position to \(max(0, seconds))") != nil
    }

    /// Spotify's artwork link for the current track (an https URL on its image CDN).
    nonisolated static func spotifyArtworkURL() async -> URL? {
        guard let text = await osascript("tell application \"Spotify\" to artwork url of current track"),
              let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https" else { return nil }
        return url
    }

    // MARK: - Polling

    private var musicIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    private func poll() {
        // Asked again mid-read (Music announced a change): read once more afterwards, or a
        // play announced during a "paused" read would be missed and nothing would poll.
        guard !polling else { pollAgain = true; return }
        // Never launch Music just to ask what it is playing. When the running-apps list says
        // it's gone but a song is showing, the script confirms (that list can lag at launch).
        guard musicIsRunning || lastPersistentID != nil else {
            setPlaying(false)
            onEvent?(.nothingPlaying)
            return
        }
        polling = true
        Task {
            let output = await Self.osascript(Self.stateScript)
            self.polling = false
            self.handle(output)
            if self.pollAgain {
                self.pollAgain = false
                self.poll()
            }
        }
    }

    private func handle(_ output: String?) {
        // No answer (Music busy, or Islet not allowed to ask it) says nothing about what's
        // playing; only "STOPPED" means nothing is.
        guard let output else { return }
        guard output != "STOPPED" else {
            lastPersistentID = nil
            setPlaying(false)
            onEvent?(.nothingPlaying)
            return
        }
        let fields = output.components(separatedBy: "\t")
        guard fields.count >= 7 else { return }
        let number = { (text: String) in Double(text.replacing(",", with: ".")) ?? 0 }
        let persistentID = fields[6]
        if persistentID != lastPersistentID {
            lastPersistentID = persistentID
            fetchArtwork()
        }
        let playing = fields[0] == "playing"
        setPlaying(playing)
        onEvent?(.update(NowPlayingSnapshot(
            title: fields[2], artist: fields[3], album: fields[4],
            duration: number(fields[5]), elapsed: number(fields[1]), timestamp: Date(),
            playbackRate: playing ? 1 : 0, isPlaying: playing,
            bundleIdentifier: "com.apple.Music",
            artwork: artwork, artworkRevision: artworkRevision,
            uniqueIdentifier: persistentID
        )))
    }

    /// The drift check runs only while music plays.
    private func setPlaying(_ playing: Bool) {
        if !playing {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            timer?.tolerance = interval * 0.2
        }
    }

    private func fetchArtwork() {
        let path = artworkFile.path
        let script = """
        tell application "Music"
            try
                set d to raw data of artwork 1 of current track
            on error
                return "NONE"
            end try
        end tell
        set f to open for access (POSIX file "\(path)") with write permission
        set eof f to 0
        write d to f
        close access f
        return "OK"
        """
        Task {
            let result = await Self.osascript(script)
            self.artwork = result == "OK" ? try? Data(contentsOf: self.artworkFile) : nil
            self.artworkRevision += 1
            self.poll()
        }
    }

    /// Runs one AppleScript in a separate `osascript` process and returns trimmed stdout.
    nonisolated static func osascript(_ source: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let succeeded: Bool = await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
            }
        }
        guard succeeded else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
